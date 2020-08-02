package Minion::Backend::SQLite;
use Mojo::Base 'Minion::Backend';

use Carp 'croak';
use List::Util 'min';
use Mojo::SQLite;
use Mojo::Util 'steady_time';
use Sys::Hostname 'hostname';
use Time::HiRes 'usleep';

our $VERSION = 'v5.0.3';

has dequeue_interval => 0.5;
has 'sqlite';

sub new {
  my $self = shift->SUPER::new(sqlite => Mojo::SQLite->new(@_));
  $self->sqlite->auto_migrate(1)->migrations->name('minion')->from_data;
  return $self;
}

sub broadcast {
  my ($self, $command, $args, $ids) = (shift, shift, shift || [], shift || []);
  my $ids_in = join ',', ('?')x@$ids;
  return !!$self->sqlite->db->query(
    q{update minion_workers set inbox =
      json_set(inbox, '$[' || json_array_length(inbox) || ']', json(?))} .
      (@$ids ? " where id in ($ids_in)" : ''),
      {json => [$command, @$args]}, @$ids
  )->rows;
}

sub dequeue {
  my ($self, $id, $wait, $options) = @_;
  my $job = $self->_try($id, $options);
  unless ($job) {
    my $int = $self->dequeue_interval;
    my $end = steady_time + $wait;
    my $remaining = $wait;
    usleep(min($int, $remaining) * 1000000)
      until ($remaining = $end - steady_time) <= 0
      or $job = $self->_try($id, $options);
  }
  return $job || $self->_try($id, $options);
}

sub enqueue {
  my ($self, $task, $args, $options) = (shift, shift, shift || [], shift || {});

  return $self->sqlite->db->query(
    q{insert into minion_jobs
       (args, attempts, delayed, expires, lax, notes, parents, priority, queue, task)
      values (?, ?, datetime('now', ? || ' seconds'),
      case when ? is not null then datetime('now', ? || ' seconds') end,
      ?, ?, ?, ?, ?, ?)},
    {json => $args}, $options->{attempts} // 1, $options->{delay} // 0,
    @$options{qw(expire expire)}, $options->{lax} ? 1 : 0, {json => $options->{notes} || {}},
    {json => ($options->{parents} || [])}, $options->{priority} // 0,
    $options->{queue} // 'default', $task
  )->last_insert_id;
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub history {
  my $self = shift;

  my $db = $self->sqlite->db;
  my $steps = $db->query(
    q{with recursive generate_series(ts) as (
        select datetime('now','-23 hours')
        union all
        select datetime(ts,'+1 hour') from generate_series
        where datetime(ts,'+1 hour') <= datetime('now')
      ) select ts, strftime('%s',ts) as epoch,
        strftime('%d',ts,'localtime') as day,
        strftime('%H',ts,'localtime') as hour
      from generate_series order by epoch})->hashes;

  my $counts = $db->query(
    q{select strftime('%d',finished,'localtime') as day,
        strftime('%H',finished,'localtime') as hour,
        count(case state when 'failed' then 1 end) as failed_jobs,
        count(case state when 'finished' then 1 end) as finished_jobs
      from minion_jobs
      where finished > ? group by day, hour}, $steps->first->{ts})->hashes;

  my %daily = map { ("$_->{day}-$_->{hour}" => $_) } @$counts;
  my @daily_ordered;
  foreach my $step (@$steps) {
    my $hour_counts = $daily{"$step->{day}-$step->{hour}"} // {};
    push @daily_ordered, {
      epoch => $step->{epoch},
      failed_jobs => $hour_counts->{failed_jobs} // 0,
      finished_jobs => $hour_counts->{finished_jobs} // 0,
    };
  }

  return {daily => \@daily_ordered};
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  my (@where, @where_params);
  if (defined(my $before = $options->{before})) {
    push @where, 'id < ?';
    push @where_params, $before;
  }
  if (defined(my $ids = $options->{ids})) {
    my $ids_in = join ',', ('?')x@$ids;
    push @where, @$ids ? "id in ($ids_in)" : 'id is null';
    push @where_params, @$ids;
  }
  if (defined(my $notes = $options->{notes})) {
    croak 'Listing jobs by existence of notes is unimplemented';
  }
  if (defined(my $queues = $options->{queues})) {
    my $queues_in = join ',', ('?')x@$queues;
    push @where, @$queues ? "queue in ($queues_in)" : 'queue is null';
    push @where_params, @$queues;
  }
  if (defined(my $states = $options->{states})) {
    my $states_in = join ',', ('?')x@$states;
    push @where, @$states ? "state in ($states_in)" : 'state is null';
    push @where_params, @$states;
  }
  if (defined(my $tasks = $options->{tasks})) {
    my $tasks_in = join ',', ('?')x@$tasks;
    push @where, @$tasks ? "task in ($tasks_in)" : 'task is null';
    push @where_params, @$tasks;
  }
  push @where, q{(state != 'inactive' or expires is null or expires > datetime('now'))};

  my $where_str = @where ? 'where ' . join(' and ', @where) : '';

  my $jobs = $self->sqlite->db->query(
    qq{select id, args, attempts,
       (select json_group_array(distinct child.id)
         from minion_jobs as child, json_each(child.parents) as parent_id
         where j.id = parent_id.value) as children,
       strftime('%s',created) as created, strftime('%s',delayed) as delayed,
       strftime('%s',expires) as expires, strftime('%s',finished) as finished,
       lax, notes, parents, priority, queue, result,
       strftime('%s',retried) as retried, retries,
       strftime('%s',started) as started, state, task,
       strftime('%s','now') as time, worker
       from minion_jobs as j
       $where_str order by id desc limit ? offset ?},
    @where_params, $limit, $offset
  )->expand(json => [qw(args children notes parents result)])->hashes->to_array;

  my $total = $self->sqlite->db->query(qq{select count(*) from minion_jobs as j
    $where_str}, @where_params)->arrays->first->[0];
  
  return {jobs => $jobs, total => $total};
}

sub list_locks {
  my ($self, $offset, $limit, $options) = @_;
  
  my (@where, @where_params);
  push @where, q{expires > datetime('now')};
  if (defined(my $names = $options->{names})) {
    my $names_in = join ',', ('?')x@$names;
    push @where, @$names ? "name in ($names_in)" : 'name is null';
    push @where_params, @$names;
  }
  
  my $where_str = 'where ' . join(' and ', @where);
  
  my $locks = $self->sqlite->db->query(
    qq{select name, strftime('%s',expires) as expires from minion_locks
       $where_str order by id desc limit ? offset ?},
    @where_params, $limit, $offset
  )->hashes->to_array;
  
  my $total = $self->sqlite->db->query(qq{select count(*) from minion_locks
    $where_str}, @where_params)->arrays->first->[0];
  
  return {locks => $locks, total => $total};
}

sub list_workers {
  my ($self, $offset, $limit, $options) = @_;

  my (@where, @where_params);
  if (defined(my $before = $options->{before})) {
    push @where, 'w.id < ?';
    push @where_params, $before;
  }
  if (defined(my $ids = $options->{ids})) {
    my $ids_in = join ',', ('?')x@$ids;
    push @where, @$ids ? "w.id in ($ids_in)" : 'w.id is null';
    push @where_params, @$ids;
  }

  my $where_str = @where ? 'where ' . join(' and ', @where) : '';
  my $workers = $self->sqlite->db->query(
    qq{select w.id, strftime('%s',w.notified) as notified,
       group_concat(j.id) as jobs, w.host, w.pid, w.status,
       strftime('%s',w.started) as started
       from minion_workers as w
       left join minion_jobs as j on j.worker = w.id and j.state = 'active'
       $where_str group by w.id order by w.id desc limit ? offset ?},
    @where_params, $limit, $offset
  )->expand(json => 'status')->hashes->to_array;
  $_->{jobs} = [split /,/, ($_->{jobs} // '')] for @$workers;

  my $total = $self->sqlite->db->query(qq{select count(*)
    from minion_workers as w $where_str}, @where_params)->arrays->first->[0];

  return {total => $total, workers => $workers};
}

sub lock {
  my ($self, $name, $duration, $options) = (shift, shift, shift, shift // {});
  my $db = $self->sqlite->db;
  $db->query(q{delete from minion_locks where expires < datetime('now')});
  my $tx = $db->begin('exclusive');
  my $locks = $db->query(q{select count(*) from minion_locks where name = ?},
    $name)->arrays->first->[0];
  return !!0 if defined $locks and $locks >= ($options->{limit} || 1);
  if (defined $duration and $duration > 0) {
    $db->query(q{insert into minion_locks (name, expires)
      values (?, datetime('now', ? || ' seconds'))}, $name, $duration);
    $tx->commit;
  }
  return !!1;
}

sub note {
  my ($self, $id, $merge) = @_;
  my (@set, @set_params, @remove, @remove_params);
  foreach my $key (keys %$merge) {
    croak qq{Invalid note key '$key'; must not contain '.', '[', or ']'}
      if $key =~ m/[\[\].]/;
    if (defined $merge->{$key}) {
      push @set, q{'$.' || ?}, 'json(?)';
      push @set_params, $key, {json => $merge->{$key}};
    } else {
      push @remove, q{'$.' || ?};
      push @remove_params, $key;
    }
  }
  my $json_set = join ', ', @set;
  my $json_remove = join ', ', @remove;
  my $set_to = 'notes';
  $set_to = "json_set($set_to, $json_set)" if @set;
  $set_to = "json_remove($set_to, $json_remove)" if @remove;
  return !!$self->sqlite->db->query(
    qq{update minion_jobs set notes = $set_to where id = ?},
    @set_params, @remove_params, $id
  )->rows;
}

sub receive {
  my ($self, $id) = @_;
  my $db = $self->sqlite->db;
  my $tx = $db->begin;
  my $array = $db->query(q{select inbox from minion_workers where id = ?}, $id)
    ->expand(json => 'inbox')->array;
  $db->query(q{update minion_workers set inbox = '[]' where id = ?}, $id)
    if $array;
  $tx->commit;
  return $array ? $array->[0] : [];
}

sub register_worker {
  my ($self, $id, $options) = (shift, shift, shift || {});

  return $id if $id && $self->sqlite->db->query(
    q{update minion_workers set notified = datetime('now'), status = ?
      where id = ?}, {json => $options->{status} // {}}, $id)->rows;

  return $self->sqlite->db->query(
    q{insert into minion_workers (host, pid, status) values (?, ?, ?)},
    hostname, $$, {json => $options->{status} // {}})->last_insert_id;
}

sub remove_job {
  !!shift->sqlite->db->query(
    q{delete from minion_jobs
      where id = ? and state in ('inactive', 'failed', 'finished')}, shift
  )->rows;
}

sub repair {
  my $self = shift;

  # Workers without heartbeat
  my $db     = $self->sqlite->db;
  my $minion = $self->minion;
  $db->query(
    q{delete from minion_workers
      where notified < datetime('now', '-' || ? || ' seconds')}, $minion->missing_after
  );

  # Old jobs with no unresolved dependencies and expired jobs
  $db->query(
    q{delete from minion_jobs
      where (finished <= datetime('now', '-' || ? || ' seconds')
      and state = 'finished' and id not in (select distinct parent_id.value
        from minion_jobs as child, json_each(child.parents) as parent_id
        where child.state <> 'finished'))
      or (expires <= datetime('now') and state = 'inactive')}, $minion->remove_after);

  # Jobs with missing worker (can be retried)
  my $fail = $db->query(
    q{select id, retries from minion_jobs as j
      where state = 'active' and queue != 'minion_foreground'
        and not exists (select 1 from minion_workers where id = j.worker)}
  )->hashes;
  $fail->each(sub { $self->fail_job(@$_{qw(id retries)}, 'Worker went away') });

  # Jobs in queue without workers or not enough workers (cannot be retried and requires admin attention)
  $db->query(
    q{update minion_jobs set state = 'failed', result = json_quote('Job appears stuck in queue')
      where state = 'inactive' and delayed < datetime('now', '-' || ? || ' seconds')},
    $minion->stuck_after);
}

sub reset {
  my ($self, $options) = (shift, shift // {});
  my $db = $self->sqlite->db;
  if ($options->{all}) {
    my $tx = $db->begin;
    $db->query('delete from minion_jobs');
    $db->query('delete from minion_locks');
    $db->query('delete from minion_workers');
    $db->query(q{delete from sqlite_sequence
      where name in ('minion_jobs','minion_locks','minion_workers')});
    $tx->commit;
  } elsif ($options->{locks}) {
    $db->query('delete from minion_locks');
  }
}

sub retry_job {
  my ($self, $id, $retries, $options) = (shift, shift, shift, shift || {});

  my $parents = defined $options->{parents}
    ? {json => $options->{parents}} : undef;
  return !!$self->sqlite->db->query(
    q{update minion_jobs
      set attempts = coalesce(?, attempts),
        delayed = datetime('now', ? || ' seconds'),
        expires = case when ? is not null then datetime('now', ? || ' seconds') else expires end,
        lax = coalesce(?, lax), parents = coalesce(?, parents), priority = coalesce(?, priority),
        queue = coalesce(?, queue), retried = datetime('now'),
        retries = retries + 1, state = 'inactive'
      where id = ? and retries = ?},
    $options->{attempts}, $options->{delay} // 0, @$options{qw(expire expire)},
    exists $options->{lax} ? $options->{lax} ? 1 : 0 : undef,
    $parents, @$options{qw(priority queue)}, $id, $retries
  )->rows;
}

sub stats {
  my $self = shift;

  my $stats = $self->sqlite->db->query(
    q{select count(case when state = 'inactive' and (expires is null or expires > datetime('now'))
        then 1 end) as inactive_jobs,
      count(case state when 'active' then 1 end) as active_jobs,
      count(case state when 'failed' then 1 end) as failed_jobs,
      count(case state when 'finished' then 1 end) as finished_jobs,
      count(case when state = 'inactive' and delayed > datetime('now')
        then 1 end) as delayed_jobs,
      (select count(*) from minion_locks where expires > datetime('now'))
        as active_locks,
      count(distinct case when state = 'active' then worker end)
        as active_workers,
      ifnull((select seq from sqlite_sequence where name = 'minion_jobs'), 0)
        as enqueued_jobs,
      (select count(*) from minion_workers) as inactive_workers, null as uptime
      from minion_jobs}
  )->hash;
  $stats->{inactive_workers} -= $stats->{active_workers};

  return $stats;
}

sub unlock {
  !!shift->sqlite->db->query(
    q{delete from minion_locks where id = (
      select id from minion_locks
      where expires > datetime('now') and name = ?
      order by expires limit 1)}, shift
  )->rows;
}

sub unregister_worker {
  shift->sqlite->db->query('delete from minion_workers where id = ?', shift);
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
    qq{select id from minion_jobs as j
       where delayed <= datetime('now') and id = coalesce(?, id)
       and (json_array_length(parents) = 0 or not exists (
         select 1 from minion_jobs as parent, json_each(j.parents) as parent_id
         where parent.id = parent_id.value and case parent.state
           when 'active' then 1
           when 'failed' then not j.lax
           when 'inactive' then (parent.expires is null or parent.expires > datetime('now'))
         end
       )) and queue in ($queues_in) and state = 'inactive' and task in ($tasks_in)
       and (expires is null or expires > datetime('now'))
       order by priority desc, id
       limit 1}, $options->{id}, @$queues, @$tasks
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
  )->expand(json => 'args')->hash // return undef;
  
  return $info;
}

sub _update {
  my ($self, $fail, $id, $retries, $result) = @_;

  my $db = $self->sqlite->db;
  return undef unless $db->query(
    q{update minion_jobs
      set finished = datetime('now'), result = ?, state = ?
      where id = ? and retries = ? and state = 'active'},
    {json => $result}, $fail ? 'failed' : 'finished', $id, $retries
  )->rows > 0;
  
  my $row = $db->query('select attempts from minion_jobs where id = ?', $id)->array;
  return $fail ? $self->auto_retry_job($id, $retries, $row->[0]) : 1;
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

  # Mojolicious (via Mojolicious::Plugin::Minion)
  $self->plugin(Minion => { SQLite => 'sqlite:test.db' });

  # Mojolicious::Lite (via Mojolicious::Plugin::Minion)
  plugin Minion => { SQLite => 'sqlite:test.db' };

  # Share the database connection cache
  helper sqlite => sub { state $sqlite = Mojo::SQLite->new('sqlite:test.db') };
  plugin Minion => { SQLite => app->sqlite };

=head1 DESCRIPTION

L<Minion::Backend::SQLite> is a backend for L<Minion> based on L<Mojo::SQLite>.
All necessary tables will be created automatically with a set of migrations
named C<minion>. If no connection string or C<:temp:> is provided, the database
will be created in a temporary directory.

=head1 ATTRIBUTES

L<Minion::Backend::SQLite> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 dequeue_interval

  my $seconds = $backend->dequeue_interval;
  $backend    = $backend->dequeue_interval($seconds);

Interval in seconds between L</"dequeue"> attempts. Defaults to C<0.5>.

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
  my $backend = Minion::Backend::SQLite->new(Mojo::SQLite->new);

Construct a new L<Minion::Backend::SQLite> object.

=head2 broadcast

  my $bool = $backend->broadcast('some_command');
  my $bool = $backend->broadcast('some_command', [@args]);
  my $bool = $backend->broadcast('some_command', [@args], [$id1, $id2, $id3]);

Broadcast remote control command to one or more workers.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait a given amount of time in seconds for a job, dequeue it and transition
from C<inactive> to C<active> state, or return C<undef> if queues were empty.
Jobs will be checked for in intervals defined by L</"dequeue_interval"> until
the timeout is reached.

These options are currently available:

=over 2

=item id

  id => '10023'

Dequeue a specific job.

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

Number of times performing this job will be attempted, with a delay based on
L<Minion/"backoff"> after the first attempt, defaults to C<1>.

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item expire

  expire => 300

Job is valid for this many seconds (from now) before it expires. Note that this
option is B<EXPERIMENTAL> and might change without warning!

=item lax

  lax => 1

Existing jobs this job depends on may also have transitioned to the C<failed>
state to allow for it to be processed, defaults to C<false>. Note that this
option is B<EXPERIMENTAL> and might change without warning!

=item notes

  notes => {foo => 'bar', baz => [1, 2, 3]}

Hash reference with arbitrary metadata for this job.

=item parents

  parents => [$id1, $id2, $id3]

One or more existing jobs this job depends on, and that need to have
transitioned to the state C<finished> before it can be processed.

=item priority

  priority => 5

Job priority, defaults to C<0>. Jobs with a higher priority get performed first.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id, $retries);
  my $bool = $backend->fail_job($job_id, $retries, 'Something went wrong!');
  my $bool = $backend->fail_job(
    $job_id, $retries, {msg => 'Something went wrong!'});

Transition from C<active> to C<failed> state with or without a result, and if
there are attempts remaining, transition back to C<inactive> with an
exponentially increasing delay based on L<Minion/"backoff">.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job($job_id, $retries, {msg => 'All went well!'});

Transition from C<active> to C<finished> state with or without a result.

=head2 history

  my $history = $backend->history;

Get history information for job queue.

These fields are currently available:

=over 2

=item daily

  daily => [{epoch => 12345, finished_jobs => 95, failed_jobs => 2}, ...]

Hourly counts for processed jobs from the past day.

=back

=head2 list_jobs

  my $results = $backend->list_jobs($offset, $limit);
  my $results = $backend->list_jobs($offset, $limit, {states => ['inactive']});

Returns the information about jobs in batches.

  # Get the total number of results (without limit)
  my $num = $backend->list_jobs(0, 100, {queues => ['important']})->{total};

  # Check job state
  my $results = $backend->list_jobs(0, 1, {ids => [$job_id]});
  my $state = $results->{jobs}[0]{state};

  # Get job result
  my $results = $backend->list_jobs(0, 1, {ids => [$job_id]});
  my $result = $results->{jobs}[0]{result};

These options are currently available:

=over 2

=item before

  before => 23

List only jobs before this id.

=item ids

  ids => ['23', '24']

List only jobs with these ids.

=item queues

  queues => ['important', 'unimportant']

List only jobs in these queues.

=item states

  states => ['inactive', 'active']

List only jobs in these states.

=item tasks

  tasks => ['foo', 'bar']

List only jobs for these tasks.

=back

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item attempts

  attempts => 25

Number of times performing this job will be attempted.

=item children

  children => ['10026', '10027', '10028']

Jobs depending on this job.

=item created

  created => 784111777

Epoch time job was created.

=item delayed

  delayed => 784111777

Epoch time job was delayed to.

=item expires

  expires => 784111777

Epoch time job is valid until before it expires.

=item finished

  finished => 784111777

Epoch time job was finished.

=item id

  id => 10025

Job id.

=item lax

  lax => 0

Existing jobs this job depends on may also have failed to allow for it to be
processed.

=item notes

  notes => {foo => 'bar', baz => [1, 2, 3]}

Hash reference with arbitrary metadata for this job.

=item parents

  parents => ['10023', '10024', '10025']

Jobs this job depends on.

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

Epoch time job has been retried.

=item retries

  retries => 3

Number of times job has been retried.

=item started

  started => 784111777

Epoch time job was started.

=item state

  state => 'inactive'

Current job state, usually C<active>, C<failed>, C<finished> or C<inactive>.

=item task

  task => 'foo'

Task name.

=item time

  time => 78411177

Current time.

=item worker

  worker => '154'

Id of worker that is processing the job.

=back

=head2 list_locks

  my $results = $backend->list_locks($offset, $limit);
  my $results = $backend->list_locks($offset, $limit, {names => ['foo']});

Returns information about locks in batches.

  # Get the total number of results (without limit)
  my $num = $backend->list_locks(0, 100, {names => ['bar']})->{total};

  # Check expiration time
  my $results = $backend->list_locks(0, 1, {names => ['foo']});
  my $expires = $results->{locks}[0]{expires};

These options are currently available:

=over 2

=item names

  names => ['foo', 'bar']

List only locks with these names.

=back

These fields are currently available:

=over 2

=item expires

  expires => 784111777

Epoch time this lock will expire.

=item name

  name => 'foo'

Lock name.

=back

=head2 list_workers

  my $results = $backend->list_workers($offset, $limit);
  my $results = $backend->list_workers($offset, $limit, {ids => [23]});

Returns information about workers in batches.

  # Get the total number of results (without limit)
  my $num = $backend->list_workers(0, 100)->{total};

  # Check worker host
  my $results = $backend->list_workers(0, 1, {ids => [$worker_id]});
  my $host    = $results->{workers}[0]{host};

These options are currently available:

=over 2

=item before

  before => 23

List only workers before this id.

=item ids

  ids => ['23', '24']

List only workers with these ids.

=back

These fields are currently available:

=over 2

=item id

  id => 22

Worker id.

=item host

  host => 'localhost'

Worker host.

=item jobs

  jobs => ['10023', '10024', '10025', '10029']

Ids of jobs the worker is currently processing.

=item notified

  notified => 784111777

Epoch time worker sent the last heartbeat.

=item pid

  pid => 12345

Process id of worker.

=item started

  started => 784111777

Epoch time worker was started.

=item status

  status => {queues => ['default', 'important']}

Hash reference with whatever status information the worker would like to share.

=back

=head2 lock

  my $bool = $backend->lock('foo', 3600);
  my $bool = $backend->lock('foo', 3600, {limit => 20});

Try to acquire a named lock that will expire automatically after the given
amount of time in seconds. An expiration time of C<0> can be used to check if a
named lock already exists without creating one.

These options are currently available:

=over 2

=item limit

  limit => 20

Number of shared locks with the same name that can be active at the same time,
defaults to C<1>.

=back

=head2 note

  my $bool = $backend->note($job_id, {mojo => 'rocks', minion => 'too'});

Change one or more metadata fields for a job. Setting a value to C<undef> will
remove the field. It is currently an error to attempt to set a metadata field
with a name containing the characters C<.>, C<[>, or C<]>.

=head2 receive

  my $commands = $backend->receive($worker_id);

Receive remote control commands for worker.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);
  my $worker_id = $backend->register_worker(
    $worker_id, {status => {queues => ['default', 'important']}});

Register worker or send heartbeat to show that this worker is still alive.

These options are currently available:

=over 2

=item status

  status => {queues => ['default', 'important']}

Hash reference with whatever status information the worker would like to share.

=back

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $backend->reset({all => 1});

Reset job queue.

These options are currently available:

=over 2

=item all

  all => 1

Reset everything.

=item locks

  locks => 1

Reset only locks.

=back

=head2 retry_job

  my $bool = $backend->retry_job($job_id, $retries);
  my $bool = $backend->retry_job($job_id, $retries, {delay => 10});

Transition job back to C<inactive> state, already C<inactive> jobs may also be
retried to change options.

These options are currently available:

=over 2

=item attempts

  attempts => 25

Number of times performing this job will be attempted.

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item expire

  expire => 300

Job is valid for this many seconds (from now) before it expires. Note that this
option is B<EXPERIMENTAL> and might change without warning!

=item lax

  lax => 1

Existing jobs this job depends on may also have transitioned to the C<failed>
state to allow for it to be processed, defaults to C<false>. Note that this
option is B<EXPERIMENTAL> and might change without warning!

=item parents

  parents => [$id1, $id2, $id3]

Jobs this job depends on.

=item priority

  priority => 5

Job priority.

=item queue

  queue => 'important'

Queue to put job in.

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for the job queue.

These fields are currently available:

=over 2

=item active_jobs

  active_jobs => 100

Number of jobs in C<active> state.

=item active_locks

  active_locks => 100

Number of active named locks.

=item active_workers

  active_workers => 100

Number of workers that are currently processing a job.

=item delayed_jobs

  delayed_jobs => 100

Number of jobs in C<inactive> state that are scheduled to run at specific time
in the future.

=item enqueued_jobs

  enqueued_jobs => 100000

Rough estimate of how many jobs have ever been enqueued.

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

=item uptime

  uptime => undef

Uptime in seconds. Always undefined for SQLite.

=back

=head2 unlock

  my $bool = $backend->unlock('foo');

Release a named lock.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

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

-- 3 up
create table minion_jobs_NEW (
  id       integer not null primary key autoincrement,
  args     text not null,
  created  text not null default current_timestamp,
  delayed  text not null,
  finished text,
  priority integer not null,
  result   text,
  retried  text,
  retries  integer not null default 0,
  started  text,
  state    text not null default 'inactive',
  task     text not null,
  worker   integer,
  queue    text not null default 'default',
  attempts integer not null default 1
);
insert into minion_jobs_NEW select * from minion_jobs;
drop table minion_jobs;
alter table minion_jobs_NEW rename to minion_jobs;

-- 4 up
alter table minion_jobs add column parents text not null default '[]';

-- 5 up
alter table minion_workers add column inbox text not null
  check(json_valid(inbox) and json_type(inbox) = 'array') default '[]';

-- 6 up
drop index if exists minion_jobs_priority_created;
drop index if exists minion_jobs_state;
create index if not exists minion_jobs_state_priority_id on minion_jobs (state, priority desc, id);

-- 7 up
alter table minion_workers add column status text not null
  check(json_valid(status) and json_type(status) = 'object') default '{}';

-- 8 up
create table if not exists minion_locks (
  id integer not null primary key autoincrement,
  name text not null,
  expires text not null
);
create index if not exists minion_locks_name_expires on minion_locks (name, expires);
alter table minion_jobs add column notes text not null
  check(json_valid(notes) and json_type(notes) = 'object') default '{}';

-- 8 down
drop table if exists minion_locks;

-- 9 up
alter table minion_jobs add column sequence text;
alter table minion_jobs add column next integer;
create unique index minion_jobs_next on minion_jobs (next);
create index minion_jobs_sequence_next on minion_jobs (sequence, next);

-- 10 up
create table minion_jobs_NEW (
  id       integer not null primary key autoincrement,
  args     text not null,
  created  text not null default current_timestamp,
  delayed  text not null,
  finished text,
  priority integer not null,
  result   text,
  retried  text,
  retries  integer not null default 0,
  started  text,
  state    text not null default 'inactive',
  task     text not null,
  worker   integer,
  queue    text not null default 'default',
  attempts integer not null default 1,
  parents  text not null default '[]',
  notes    text not null
    check(json_valid(notes) and json_type(notes) = 'object') default '{}',
  expires  text,
  lax      boolean not null default 0
);
insert into minion_jobs_NEW
  (id,args,created,delayed,finished,priority,result,retried,retries,
  started,state,task,worker,queue,attempts,parents,notes)
  select id,args,created,delayed,finished,priority,result,retried,retries,
  started,state,task,worker,queue,attempts,parents,notes from minion_jobs;
drop table minion_jobs;
alter table minion_jobs_NEW rename to minion_jobs;
create index if not exists minion_jobs_state_priority_id on minion_jobs (state, priority desc, id);
create index minion_jobs_expires on minion_jobs (expires);
