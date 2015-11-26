package Minion::Backend::SQLite;
use Mojo::Base 'Minion::Backend';

use DBI ':sql_types';
use Mojo::JSON qw(decode_json encode_json);
use Mojo::SQLite;
use Sys::Hostname 'hostname';
use Time::HiRes 'usleep';

our $VERSION = '0.004';

has 'sqlite';

sub new {
  my $self = shift->SUPER::new(sqlite => Mojo::SQLite->new(@_));
  my $sqlite = $self->sqlite->max_connections(1);
  $sqlite->migrations->name('minion')->from_data;
  $sqlite->once(connection => sub { shift->migrations->migrate });
  return $self;
}

sub dequeue {
  my ($self, $id, $wait, $options) = @_;
  usleep($wait * 1000000) unless my $job = $self->_try($id, $options);
  return $job || $self->_try($id, $options);
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  my $db = $self->sqlite->db;
  return $db->query(
    q{insert into minion_jobs (args, attempts, delayed, priority, queue, task)
      values (?, ?, (datetime('now', ? || ' seconds')), ?, ?, ?)},
    {type => SQL_BLOB, value => encode_json($args)}, $options->{attempts} // 1,
    $options->{delay} // 0, $options->{priority} // 0,
    $options->{queue} // 'default', $task
  )->last_insert_id;
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub job_info {
  my $info = shift->sqlite->db->query(
    q{select id, args, attempts, strftime('%s',created) as created,
        strftime('%s',delayed) as delayed,
        strftime('%s',finished) as finished, priority, queue, result,
        strftime('%s',retried) as retried, retries,
        strftime('%s',started) as started, state, task, worker
      from minion_jobs where id = ?}, shift
  )->hash // return undef;
  $info->{$_} = decode_json $info->{$_} for grep { defined $info->{$_} } qw(args result);
  return $info;
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  return $self->sqlite->db->query(
    'select id from minion_jobs
     where (state = :1 or :1 is null) and (task = :2 or :2 is null)
     order by id desc
     limit :3
     offset :4', @$options{qw(state task)}, $limit, $offset
  )->arrays->map(sub { $self->job_info($_->[0]) })->to_array;
}

sub list_workers {
  my ($self, $offset, $limit) = @_;

  my $sql = 'select id from minion_workers order by id desc limit ? offset ?';
  return $self->sqlite->db->query($sql, $limit, $offset)
    ->arrays->map(sub { $self->worker_info($_->[0]) })->to_array;
}

sub register_worker {
  my ($self, $id) = @_;

  my $sql
    = q{update minion_workers set notified = datetime('now') where id = ?};
  return $id if $id && $self->sqlite->db->query($sql, $id)->rows;

  $sql = 'insert into minion_workers (host, pid) values (?, ?)';
  return $self->sqlite->db->query($sql, hostname, $$)->last_insert_id;
}

sub remove_job {
  !!shift->sqlite->db->query(
    q{delete from minion_jobs
      where id = ? and state in ('inactive', 'failed', 'finished')}, shift
  )->rows;
}

sub repair {
  my $self = shift;

  # Check worker registry
  my $db     = $self->sqlite->db;
  my $minion = $self->minion;
  $db->query(
    q{delete from minion_workers
      where notified < datetime('now', '-' || ? || ' seconds')}, $minion->missing_after
  );

  # Abandoned jobs
  my $fail = $db->query(
    q{select id, retries from minion_jobs as j
      where state = 'active'
        and not exists(select 1 from minion_workers where id = j.worker)}
  )->hashes;
  $fail->each(sub { $self->fail_job(@$_{qw(id retries)}, 'Worker went away') });

  # Old jobs
  $db->query(
    q{delete from minion_jobs
      where state = 'finished' and finished < datetime('now', '-' || ? || ' seconds')},
    $minion->remove_after
  );
}

sub reset {
  my $db = shift->sqlite->db;
  $db->query('delete from minion_jobs');
  $db->query('delete from minion_workers');
}

sub retry_job {
  my ($self, $id, $retries) = (shift, shift, shift);
  my $options = shift // {};

  return !!$self->sqlite->db->query(
    q{update minion_jobs
      set priority = coalesce(?, priority), queue = coalesce(?, queue),
        retried = datetime('now'), retries = retries + 1, state = 'inactive',
        delayed = (datetime('now', ? || ' seconds'))
      where id = ? and retries = ? and state in ('failed', 'finished', 'inactive')},
    @$options{qw(priority queue)}, $options->{delay} // 0, $id, $retries
  )->rows;
}

sub stats {
  my $self = shift;

  my $db  = $self->sqlite->db;
  my $all = $db->query('select count(*) from minion_workers')->array->[0];
  my $sql
    = q{select count(distinct worker) from minion_jobs where state = 'active'};
  my $active = $db->query($sql)->array->[0];

  $sql = 'select state, count(state) from minion_jobs group by 1';
  my $states
    = $db->query($sql)->arrays->reduce(sub { $a->{$b->[0]} = $b->[1]; $a }, {});

  return {
    active_jobs      => $states->{active} || 0,
    active_workers   => $active,
    failed_jobs      => $states->{failed} || 0,
    finished_jobs    => $states->{finished} || 0,
    inactive_jobs    => $states->{inactive} || 0,
    inactive_workers => $all - $active,
  };
}

sub unregister_worker {
  shift->sqlite->db->query('delete from minion_workers where id = ?', shift);
}

sub worker_info {
  my $info = shift->sqlite->db->query(
    q{select w.id, strftime('%s',w.notified) as notified, group_concat(j.id) as jobs,
      w.host, w.pid, strftime('%s',w.started) as started
      from minion_workers as w
      left join minion_jobs as j on j.worker = w.id and j.state = 'active'
      where w.id = ? group by w.id}, shift
  )->hash // return undef;
  $info->{jobs} = [split /,/, ($info->{jobs} // '')];
  return $info;
}

sub _try {
  my ($self, $id, $options) = @_;

  my $db = $self->sqlite->db;
  my $queues = $options->{queues} || ['default'];
  my $tasks = [keys %{$self->minion->tasks}];
  return undef unless @$queues and @$tasks;
  my $queues_in = join ',', ('?')x@$queues;
  my $tasks_in = join ',', ('?')x@$tasks;
  
  my $tx = $db->begin;
  my $res = $db->query(
    qq{select id from minion_jobs
       where delayed <= datetime('now') and queue in ($queues_in)
         and state = 'inactive' and task in ($tasks_in)
       order by priority desc, created
       limit 1}, @$queues, @$tasks
  );
  my $job_id = ($res->arrays->first // [])->[0] // return undef;
  $db->query(
    q{update minion_jobs
      set started = datetime('now'), state = 'active', worker = ?
      where id = ?}, $id, $job_id
  );
  $tx->commit;
  
  my $info = $db->query(
    'select id, args, retries, task from minion_jobs where id = ?', $job_id
  )->hash // return undef;
  $info->{args} = decode_json($info->{args});
  
  return $info;
}

sub _update {
  my ($self, $fail, $id, $retries, $result) = @_;

  my $db = $self->sqlite->db;
  return undef unless $db->query(
    q{update minion_jobs
      set finished = datetime('now'), result = ?, state = ?
      where id = ? and retries = ? and state = 'active'},
    {type => SQL_BLOB, value => encode_json($result)},
    $fail ? 'failed' : 'finished', $id, $retries
  )->rows > 0;
  
  my $row = $db->query('select attempts from minion_jobs where id = ?', $id)->array;
  return 1 if !$fail || (my $attempts = $row->[0]) == 1;
  return 1 if $retries >= ($attempts - 1);
  my $delay = $self->minion->backoff->($retries);
  return $self->retry_job($id, $retries, {delay => $delay});
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::SQLite - SQLite backend for Minion job queue

=head1 SYNOPSIS

  use Minion::Backend::SQLite;
  my $backend = Minion::Backend::SQLite->new('sqlite:test.db');

  # Minion
  use Minion;
  my $minion = Minion->new(SQLite => 'sqlite:test.db');

  # Mojolicious::Lite (via Mojolicious::Plugin::Minion)
  plugin Minion => { SQLite => 'sqlite:test.db' };

=head1 DESCRIPTION

L<Minion::Backend::SQLite> is a backend for L<Minion> based on L<Mojo::SQLite>.
All necessary tables will be created automatically with a set of migrations
named C<minion>. If no connection string or C<:temp:> is provided, the database
will be created in a temporary directory.

=head1 ATTRIBUTES

L<Minion::Backend::SQLite> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 sqlite

  my $sqlite = $backend->sqlite;
  $backend   = $backend->sqlite(Mojo::SQLite->new);

L<Mojo::SQLite> object used to store all data.

=head1 METHODS

L<Minion::Backend::SQLite> inherits all methods from L<Minion::Backend> and
implements the following new ones.

=head2 new

  my $backend = Minion::Backend::SQLite->new;
  my $backend = Minion::Backend::SQLite->new(':temp:');
  my $backend = Minion::Backend::SQLite->new('sqlite:test.db');
  my $backend = Minion::Backend::SQLite->new->tap(sub { $_->sqlite->from_filename('C:\\foo\\bar.db') });

Construct a new L<Minion::Backend::SQLite> object.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait for job, dequeue it and transition from C<inactive> to C<active> state or
return C<undef> if queues were empty.

These options are currently available:

=over 2

=item queues

  queues => ['important']

One or more queues to dequeue jobs from, defaults to C<default>.

=back

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item id

  id => '10023'

Job ID.

=item retries

  retries => 3

Number of times job has been retried.

=item task

  task => 'foo'

Task name.

=back

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state.

These options are currently available:

=over 2

=item attempts

  attempts => 25

Number of times performing this job will be attempted, defaults to C<1>.

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority, defaults to C<0>.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id, $retries);
  my $bool = $backend->fail_job($job_id, $retries, 'Something went wrong!');
  my $bool = $backend->fail_job(
    $job_id, $retries, {msg => 'Something went wrong!'});

Transition from C<active> to C<failed> state, and if there are attempts
remaining, transition back to C<inactive> with an exponentially increasing
delay based on L<Minion/"backoff">.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job($job_id, $retries, {msg => 'All went well!'});

Transition from C<active> to C<finished> state.

=head2 job_info

  my $job_info = $backend->job_info($job_id);

Get information about a job or return C<undef> if job does not exist.

  # Check job state
  my $state = $backend->job_info($job_id)->{state};

  # Get job result
  my $result = $backend->job_info($job_id)->{result};

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item attempts

  attempts => 25

Number of times performing this job will be attempted, defaults to C<1>.

=item created

  created => 784111777

Time job was created.

=item delayed

  delayed => 784111777

Time job was delayed to.

=item finished

  finished => 784111777

Time job was finished.

=item priority

  priority => 3

Job priority.

=item queue

  queue => 'important'

Queue name.

=item result

  result => 'All went well!'

Job result.

=item retried

  retried => 784111777

Time job has been retried.

=item retries

  retries => 3

Number of times job has been retried.

=item started

  started => 784111777

Time job was started.

=item state

  state => 'inactive'

Current job state, usually C<active>, C<failed>, C<finished> or C<inactive>.

=item task

  task => 'foo'

Task name.

=item worker

  worker => '154'

Id of worker that is processing the job.

=back

=head2 list_jobs

  my $batch = $backend->list_jobs($offset, $limit);
  my $batch = $backend->list_jobs($offset, $limit, {state => 'inactive'});

Returns the same information as L</"job_info"> but in batches.

These options are currently available:

=over 2

=item state

  state => 'inactive'

List only jobs in this state.

=item task

  task => 'test'

List only jobs for this task.

=back

=head2 list_workers

  my $batch = $backend->list_workers($offset, $limit);

Returns the same information as L</"worker_info"> but in batches.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);

Register worker or send heartbeat to show that this worker is still alive.

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $backend->reset;

Reset job queue.

=head2 retry_job

  my $bool = $backend->retry_job($job_id, $retries);
  my $bool = $backend->retry_job($job_id, $retries, {delay => 10});

Transition from C<failed> or C<finished> state back to C<inactive>, already
C<inactive> jobs may also be retried to change options.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority.

=item queue

  queue => 'important'

Queue to put job in.

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

These fields are currently available:

=over 2

=item active_jobs

  active_jobs => 100

Number of jobs in C<active> state.

=item active_workers

  active_workers => 100

Number of workers that are currently processing a job.

=item failed_jobs

  failed_jobs => 100

Number of jobs in C<failed> state.

=item finished_jobs

  finished_jobs => 100

Number of jobs in C<finished> state.

=item inactive_jobs

  inactive_jobs => 100

Number of jobs in C<inactive> state.

=item inactive_workers

  inactive_workers => 100

Number of workers that are currently not processing a job.

=back

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $worker_info = $backend->worker_info($worker_id);

Get information about a worker or return C<undef> if worker does not exist.

  # Check worker host
  my $host = $backend->worker_info($worker_id)->{host};

These fields are currently available:

=over 2

=item host

  host => 'localhost'

Worker host.

=item jobs

  jobs => ['10023', '10024', '10025', '10029']

Ids of jobs the worker is currently processing.

=item notified

  notified => 784111777

Last time worker sent a heartbeat.

=item pid

  pid => 12345

Process id of worker.

=item started

  started => 784111777

Time worker was started.

=back

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book <dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2015 by Dan Book.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 SEE ALSO

L<Minion>, L<Mojo::SQLite>

=cut

__DATA__

@@ minion
-- 1 up
create table if not exists minion_jobs (
  id       integer not null primary key autoincrement,
  args     blob not null,
  created  text not null default current_timestamp,
  delayed  text not null,
  finished text,
  priority integer not null,
  result   blob,
  retried  text,
  retries  integer not null default 0,
  started  text,
  state    text not null default 'inactive',
  task     text not null,
  worker   integer,
  queue    text not null default 'default'
);
create index if not exists minion_jobs_priority_created on minion_jobs (priority desc, created);
create index if not exists minion_jobs_state on minion_jobs (state);
create table if not exists minion_workers (
  id       integer not null primary key autoincrement,
  host     text not null,
  pid      integer not null,
  started  text not null default current_timestamp,
  notified text not null default current_timestamp
);

-- 1 down
drop table if exists minion_jobs;
drop table if exists minion_workers;

-- 2 up
alter table minion_jobs add column attempts integer not null default 1;
