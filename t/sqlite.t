use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

use Config;
use Minion;
use Mojo::IOLoop;
use Sys::Hostname 'hostname';
use Time::HiRes qw(time usleep);

use constant HAS_PSEUDOFORK => $Config{d_pseudofork};

my $minion = Minion->new('SQLite');

my $worker;
SKIP: { skip 'Minion workers do not support fork emulation', 1 if HAS_PSEUDOFORK;
# Nothing to repair
$worker = $minion->repair->worker;
isa_ok $worker->minion->app, 'Mojolicious', 'has default application';
} # end SKIP

# Migrate up and down
is $minion->backend->sqlite->migrations->active, 8, 'active version is 8';
is $minion->backend->sqlite->migrations->migrate(0)->active, 0,
  'active version is 0';
is $minion->backend->sqlite->migrations->migrate->active, 8,
  'active version is 8';

my ($id, $host);
SKIP: { skip 'Minion workers do not support fork emulation', 7 if HAS_PSEUDOFORK;
# Register and unregister
$worker->register;
like $worker->info->{started}, qr/^[\d.]+$/, 'has timestamp';
my $notified = $worker->info->{notified};
like $notified, qr/^[\d.]+$/, 'has timestamp';
$id = $worker->id;
is $worker->register->id, $id, 'same id';
is $worker->unregister->info, undef, 'no information';
$host = hostname;
is $worker->register->info->{host}, $host, 'right host';
is $worker->info->{pid}, $$, 'right pid';
is $worker->unregister->info, undef, 'no information';
} # end SKIP

my ($worker2, $job);
SKIP: { skip 'Minion workers do not support fork emulation', 9 if HAS_PSEUDOFORK;
# Repair missing worker
$minion->add_task(test => sub { });
$worker2 = $minion->worker->register;
isnt $worker2->id, $worker->id, 'new id';
$id = $minion->enqueue('test');
$job = $worker2->dequeue(0);
is $job->id, $id, 'right id';
is $worker2->info->{jobs}[0], $job->id, 'right id';
$id = $worker2->id;
undef $worker2;
is $job->info->{state}, 'active', 'job is still active';
ok !!$minion->backend->list_workers(0, 1, {ids => [$id]})->{workers}[0],
  'is registered';
$minion->backend->sqlite->db->query(
  q{update minion_workers
    set notified = datetime('now', '-' || ? || ' seconds') where id = ?},
  $minion->missing_after + 1, $id
);
$minion->repair;
ok !$minion->backend->list_workers(0, 1, {ids => [$id]})->{workers}[0],
  'not registered';
like $job->info->{finished}, qr/^[\d.]+$/,       'has finished timestamp';
is $job->info->{state},      'failed',           'job is no longer active';
is $job->info->{result},     'Worker went away', 'right result';
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 3 if HAS_PSEUDOFORK;
# Repair abandoned job
$worker->register;
$id  = $minion->enqueue('test');
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
$worker->unregister;
$minion->repair;
is $job->info->{state},  'failed',           'job is no longer active';
is $job->info->{result}, 'Worker went away', 'right result';
} # end SKIP

my ($id2, $id3, $finished);
SKIP: { skip 'Minion workers do not support fork emulation', 3 if HAS_PSEUDOFORK;
# Repair old jobs
$worker->register;
$id = $minion->enqueue('test');
$id2 = $minion->enqueue('test');
$id3 = $minion->enqueue('test');
$worker->dequeue(0)->perform for 1 .. 3;
$finished = $minion->backend->sqlite->db->query(
  q{select strftime('%s',finished) as finished
    from minion_jobs
    where id = ?}, $id2
)->hash->{finished};
$minion->backend->sqlite->db->query(
  q{update minion_jobs set finished = datetime(?,'unixepoch') where id = ?},
  $finished - ($minion->remove_after + 1), $id2);
$finished = $minion->backend->sqlite->db->query(
  q{select strftime('%s',finished) as finished
    from minion_jobs
    where id = ?}, $id3
)->hash->{finished};
$minion->backend->sqlite->db->query(
  q{update minion_jobs set finished = datetime(?,'unixepoch') where id = ?},
  $finished - ($minion->remove_after + 1), $id3);
$worker->unregister;
$minion->repair;
ok $minion->job($id), 'job has not been cleaned up';
ok !$minion->job($id2), 'job has been cleaned up';
ok !$minion->job($id3), 'job has been cleaned up';
} # end SKIP

my ($results, $batch);
SKIP: { skip 'Minion workers do not support fork emulation', 15 if HAS_PSEUDOFORK;
# List workers
$worker = $minion->worker->register;
$worker2 = $minion->worker->status({whatever => 'works!'})->register;
$results = $minion->backend->list_workers(0, 10);
is $results->{total}, 2, 'two workers total';
$batch = $results->{workers};
ok $batch->[0]{id},        'has id';
is $batch->[0]{host},      $host, 'right host';
is $batch->[0]{pid},       $$, 'right pid';
like $batch->[0]{started}, qr/^[\d.]+$/, 'has timestamp';
is $batch->[1]{host},      $host, 'right host';
is $batch->[1]{pid},       $$, 'right pid';
ok !$batch->[2], 'no more results';
$results = $minion->backend->list_workers(0, 1);
$batch = $results->{workers};
is $results->{total}, 2, 'two workers total';
is $batch->[0]{id}, $worker2->id, 'right id';
is_deeply $batch->[0]{status}, {whatever => 'works!'}, 'right status';
ok !$batch->[1], 'no more results';
$worker2->status({whatever => 'works too!'})->register;
$batch = $minion->backend->list_workers(0, 1)->{workers};
is_deeply $batch->[0]{status}, {whatever => 'works too!'}, 'right status';
$batch = $minion->backend->list_workers(1, 1)->{workers};
is $batch->[0]{id}, $worker->id, 'right id';
ok !$batch->[1], 'no more results';
$worker->unregister;
$worker2->unregister;
} # end SKIP

# Exclusive lock
ok $minion->lock('foo', 3600), 'locked';
ok !$minion->lock('foo', 3600), 'not locked again';
ok $minion->unlock('foo'), 'unlocked';
ok !$minion->unlock('foo'), 'not unlocked again';
ok $minion->lock('foo', -3600), 'locked';
ok $minion->lock('foo', 3600),  'locked again';
ok !$minion->lock('foo', -3600), 'not locked again';
ok !$minion->lock('foo', 3600),  'not locked again';
ok $minion->unlock('foo'), 'unlocked';
ok !$minion->unlock('foo'), 'not unlocked again';
ok $minion->lock('yada', 3600, {limit => 1}), 'locked';
ok !$minion->lock('yada', 3600, {limit => 1}), 'not locked again';

# Shared lock
ok $minion->lock('bar', 3600,  {limit => 3}), 'locked';
ok $minion->lock('bar', 3600,  {limit => 3}), 'locked again';
ok $minion->lock('bar', -3600, {limit => 3}), 'locked again';
ok $minion->lock('bar', 3600,  {limit => 3}), 'locked again';
ok !$minion->lock('bar', 3600, {limit => 2}), 'not locked again';
ok $minion->lock('baz', 3600, {limit => 3}), 'locked';
ok $minion->unlock('bar'), 'unlocked';
ok $minion->lock('bar', 3600, {limit => 3}), 'locked again';
ok $minion->unlock('bar'), 'unlocked again';
ok $minion->unlock('bar'), 'unlocked again';
ok $minion->unlock('bar'), 'unlocked again';
ok !$minion->unlock('bar'), 'not unlocked again';
ok $minion->unlock('baz'), 'unlocked';
ok !$minion->unlock('baz'), 'not unlocked again';

# List locks
is $minion->stats->{active_locks}, 1, 'one active lock';
$results = $minion->backend->list_locks(0, 2);
is $results->{locks}[0]{name},      'yada',       'right name';
like $results->{locks}[0]{expires}, qr/^[\d.]+$/, 'expires';
is $results->{locks}[1], undef, 'no more locks';
is $results->{total}, 1, 'one result';
$minion->unlock('yada');
$minion->lock('yada', 3600, {limit => 2});
$minion->lock('test', 3600, {limit => 1});
$minion->lock('yada', 3600, {limit => 2});
is $minion->stats->{active_locks}, 3, 'three active locks';
$results = $minion->backend->list_locks(1, 1);
is $results->{locks}[0]{name},      'test',       'right name';
like $results->{locks}[0]{expires}, qr/^[\d.]+$/, 'expires';
is $results->{locks}[1], undef, 'no more locks';
is $results->{total}, 3, 'three results';
$results = $minion->backend->list_locks(0, 10, {names => ['yada']});
is $results->{locks}[0]{name},      'yada',       'right name';
like $results->{locks}[0]{expires}, qr/^[\d.]+$/, 'expires';
is $results->{locks}[1]{name},      'yada',       'right name';
like $results->{locks}[1]{expires}, qr/^[\d.]+$/, 'expires';
is $results->{locks}[2], undef, 'no more locks';
is $results->{total}, 2, 'two results';
$minion->backend->sqlite->db->query(
  q{update minion_locks set expires = datetime('now', '-1 second')
    where name = 'yada'},
);
is $minion->backend->list_locks(0, 10, {names => ['yada']})->{total}, 0,
  'no results';
$minion->unlock('test');
is $minion->backend->list_locks(0, 10)->{total}, 0, 'no results';

# Lock with guard
ok my $guard = $minion->guard('foo', 3600, {limit => 1}), 'locked';
ok !$minion->guard('foo', 3600, {limit => 1}), 'not locked again';
undef $guard;
ok $guard = $minion->guard('foo', 3600), 'locked';
ok !$minion->guard('foo', 3600), 'not locked again';
undef $guard;
ok $minion->guard('foo', 3600, {limit => 1}), 'locked again';
ok $minion->guard('foo', 3600, {limit => 1}), 'locked again';
ok $guard     = $minion->guard('bar', 3600, {limit => 2}), 'locked';
ok my $guard2 = $minion->guard('bar', 0,    {limit => 2}), 'locked';
ok my $guard3 = $minion->guard('bar', 3600, {limit => 2}), 'locked';
undef $guard2;
ok !$minion->guard('bar', 3600, {limit => 2}), 'not locked again';
undef $guard;
undef $guard3;

# Reset
$minion->reset->repair;
ok !$minion->backend->sqlite->db->query(
  'select count(id) as count from minion_jobs')->hash->{count}, 'no jobs';
ok !$minion->backend->sqlite->db->query(
  'select count(id) as count from minion_locks')->hash->{count}, 'no locks';
ok !$minion->backend->sqlite->db->query(
  'select count(id) as count from minion_workers')->hash->{count}, 'no workers';

SKIP: { skip 'Minion workers do not support fork emulation', 2 if HAS_PSEUDOFORK;
# Wait for job
my $before = time;
$worker = $minion->worker->register;
is $worker->dequeue(0.5), undef, 'no jobs yet';
ok !!(($before + 0.4) <= time), 'waited for jobs';
$worker->unregister;
} # end SKIP

my $job2;
# Stats
$minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    $job->finish({added => $first + $second});
  }
);
$minion->add_task(fail => sub { die "Intentional failure!\n" });
my $stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{enqueued_jobs},    0, 'no enqueued jobs';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    0, 'no finished jobs';
is $stats->{inactive_jobs},    0, 'no inactive jobs';
is $stats->{delayed_jobs},     0, 'no delayed jobs';
is $stats->{active_locks},     0, 'no active locks';
is $stats->{uptime}, undef, 'uptime is undefined';
SKIP: { skip 'Minion workers do not support fork emulation', 1 if HAS_PSEUDOFORK;
$worker = $minion->worker->register;
is $minion->stats->{inactive_workers}, 1, 'one inactive worker';
} # end SKIP
$minion->enqueue('fail');
is $minion->stats->{enqueued_jobs}, 1, 'one enqueued job';
$minion->enqueue('fail');
is $minion->stats->{enqueued_jobs}, 2, 'two enqueued jobs';
is $minion->stats->{inactive_jobs}, 2, 'two inactive jobs';
SKIP: { skip 'Minion workers do not support fork emulation', 3 if HAS_PSEUDOFORK;
$job   = $worker->dequeue(0);
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    1, 'one active job';
is $stats->{inactive_jobs},  1, 'one inactive job';
} # end SKIP
$minion->enqueue('fail');
SKIP: { skip 'Minion workers do not support fork emulation', 18 if HAS_PSEUDOFORK;
$job2 = $worker->dequeue(0);
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    2, 'two active jobs';
is $stats->{inactive_jobs},  1, 'one inactive job';
ok $job2->finish, 'job finished';
ok $job->finish,  'job finished';
is $minion->stats->{finished_jobs}, 2, 'two finished jobs';
$job = $worker->dequeue(0);
ok $job->fail, 'job failed';
is $minion->stats->{failed_jobs}, 1, 'one failed job';
ok $job->retry, 'job retried';
is $minion->stats->{failed_jobs}, 0, 'no failed jobs';
ok $worker->dequeue(0)->finish(['works']), 'job finished';
$worker->unregister;
$stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    3, 'three finished jobs';
is $stats->{inactive_jobs},    0, 'no inactive jobs';
is $stats->{delayed_jobs},     0, 'no delayed jobs';
} # end SKIP

# History
SKIP: { skip 'Minion workers do not support fork emulation', 15 if HAS_PSEUDOFORK;
$minion->enqueue('fail');
$worker = $minion->worker->register;
$job    = $worker->dequeue(0);
ok $job->fail, 'job failed';
$worker->unregister;
my $history = $minion->history;
is $#{$history->{daily}}, 23, 'data for 24 hours';
is $history->{daily}[-1]{finished_jobs} + $history->{daily}[-2]{finished_jobs},
  3, 'one failed job in the last hour';
is $history->{daily}[-1]{failed_jobs} + $history->{daily}[-2]{failed_jobs}, 1,
  'three finished jobs in the last hour';
is $history->{daily}[0]{finished_jobs}, 0, 'no finished jobs 24 hours ago';
is $history->{daily}[0]{failed_jobs},   0, 'no failed jobs 24 hours ago';
ok defined $history->{daily}[0]{epoch},  'has date value';
ok defined $history->{daily}[0]{hour},   'has hour value';
ok defined $history->{daily}[1]{epoch},  'has date value';
ok defined $history->{daily}[1]{hour},   'has hour value';
ok defined $history->{daily}[12]{epoch}, 'has date value';
ok defined $history->{daily}[12]{hour},  'has hour value';
ok defined $history->{daily}[-1]{epoch}, 'has date value';
ok defined $history->{daily}[-1]{hour},  'has hour value';
$job->remove;
} # end SKIP

# List jobs
$id      = $minion->enqueue('add');
$results = $minion->backend->list_jobs(0, 10);
$batch   = $results->{jobs};
is $results->{total}, 4, 'four jobs total';
ok $batch->[0]{id},        'has id';
is $batch->[0]{task},      'add', 'right task';
is $batch->[0]{state},     'inactive', 'right state';
is $batch->[0]{retries},   0, 'job has not been retried';
like $batch->[0]{created}, qr/^[\d.]+$/, 'has created timestamp';
is $batch->[1]{task},      'fail', 'right task';
is_deeply $batch->[1]{args}, [], 'right arguments';
is_deeply $batch->[1]{notes}, {}, 'right metadata';
SKIP: { skip 'Minion workers do not support fork emulation', 2 if HAS_PSEUDOFORK;
is_deeply $batch->[1]{result}, ['works'], 'right result';
is $batch->[1]{state},    'finished', 'right state';
} # end SKIP
is $batch->[1]{priority}, 0,          'right priority';
is_deeply $batch->[1]{parents},  [], 'right parents';
is_deeply $batch->[1]{children}, [], 'right children';
SKIP: { skip 'Minion workers do not support fork emulation', 1 if HAS_PSEUDOFORK;
is $batch->[1]{retries},    1,            'job has been retried';
} # end SKIP
like $batch->[1]{created},  qr/^[\d.]+$/, 'has created timestamp';
like $batch->[1]{delayed},  qr/^[\d.]+$/, 'has delayed timestamp';
SKIP: { skip 'Minion workers do not support fork emulation', 3 if HAS_PSEUDOFORK;
like $batch->[1]{finished}, qr/^[\d.]+$/, 'has finished timestamp';
like $batch->[1]{retried},  qr/^[\d.]+$/, 'has retried timestamp';
like $batch->[1]{started},  qr/^[\d.]+$/, 'has started timestamp';
} # end SKIP
is $batch->[2]{task},       'fail',       'right task';
SKIP: { skip 'Minion workers do not support fork emulation', 1 if HAS_PSEUDOFORK;
is $batch->[2]{state},      'finished',   'right state';
} # end SKIP
is $batch->[2]{retries},    0,            'job has not been retried';
is $batch->[3]{task},       'fail',       'right task';
SKIP: { skip 'Minion workers do not support fork emulation', 1 if HAS_PSEUDOFORK;
is $batch->[3]{state},      'finished',   'right state';
} # end SKIP
is $batch->[3]{retries},    0,            'job has not been retried';
ok !$batch->[4], 'no more results';
$batch = $minion->backend->list_jobs(0, 10, {states => ['inactive']})->{jobs};
is $batch->[0]{state},   'inactive', 'right state';
is $batch->[0]{retries}, 0,          'job has not been retried';
SKIP: { skip 'Minion workers do not support fork emulation', 1 if HAS_PSEUDOFORK;
ok !$batch->[1], 'no more results';
} # end SKIP
$batch = $minion->backend->list_jobs(0, 10, {tasks => ['add']})->{jobs};
is $batch->[0]{task},    'add', 'right task';
is $batch->[0]{retries}, 0,     'job has not been retried';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(0, 10, {tasks => ['add', 'fail']})->{jobs};
is $batch->[0]{task}, 'add',  'right task';
is $batch->[1]{task}, 'fail', 'right task';
is $batch->[2]{task}, 'fail', 'right task';
is $batch->[3]{task}, 'fail', 'right task';
ok !$batch->[4], 'no more results';
$batch = $minion->backend->list_jobs(0, 10, {queues => ['default']})->{jobs};
is $batch->[0]{queue}, 'default', 'right queue';
is $batch->[1]{queue}, 'default', 'right queue';
is $batch->[2]{queue}, 'default', 'right queue';
is $batch->[3]{queue}, 'default', 'right queue';
ok !$batch->[4], 'no more results';
$batch
  = $minion->backend->list_jobs(0, 10, {queues => ['does_not_exist']})->{jobs};
is_deeply $batch, [], 'no results';
$results = $minion->backend->list_jobs(0, 1);
$batch = $results->{jobs};
is $results->{total}, 4, 'four jobs total';
is $batch->[0]{state},   'inactive', 'right state';
is $batch->[0]{retries}, 0,          'job has not been retried';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(1, 1)->{jobs};
SKIP: { skip 'Minion workers do not support fork emulation', 2 if HAS_PSEUDOFORK;
is $batch->[0]{state},   'finished', 'right state';
is $batch->[0]{retries}, 1,          'job has been retried';
} # end SKIP
ok !$batch->[1], 'no more results';
ok $minion->job($id)->remove, 'job removed';

# Enqueue, dequeue and perform
is $minion->job(12345), undef, 'job does not exist';
$id = $minion->enqueue(add => [2, 2]);
ok $minion->job($id), 'job does exist';
my $info = $minion->job($id)->info;
is_deeply $info->{args}, [2, 2], 'right arguments';
is $info->{priority}, 0,          'right priority';
is $info->{state},    'inactive', 'right state';
SKIP: { skip 'Minion workers do not support fork emulation', 19 if HAS_PSEUDOFORK;
$worker = $minion->worker;
is $worker->dequeue(0), undef, 'not registered';
ok !$minion->job($id)->info->{started}, 'no started timestamp';
$job = $worker->register->dequeue(0);
is $worker->info->{jobs}[0], $job->id, 'right job';
like $job->info->{created}, qr/^[\d.]+$/, 'has created timestamp';
like $job->info->{started}, qr/^[\d.]+$/, 'has started timestamp';
is_deeply $job->args, [2, 2], 'right arguments';
is $job->info->{state}, 'active', 'right state';
is $job->task,    'add', 'right task';
is $job->retries, 0,     'job has not been retried';
$id = $job->info->{worker};
is $minion->backend->list_workers(0, 1, {ids => [$id]})->{workers}[0]{pid}, $$,
  'right worker';
ok !$job->info->{finished}, 'no finished timestamp';
$job->perform;
is $worker->info->{jobs}[0], undef, 'no jobs';
like $job->info->{finished}, qr/^[\d.]+$/, 'has finished timestamp';
is_deeply $job->info->{result}, {added => 4}, 'right result';
is $job->info->{state}, 'finished', 'right state';
$worker->unregister;
$job = $minion->job($job->id);
is_deeply $job->args, [2, 2], 'right arguments';
is $job->retries, 0, 'job has not been retried';
is $job->info->{state}, 'finished', 'right state';
is $job->task, 'add', 'right task';
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 29 if HAS_PSEUDOFORK;
# Retry and remove
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue(0);
is $job->info->{attempts}, 1, 'job will be attempted once';
is $job->info->{retries}, 0, 'job has not been retried';
is $job->id, $id, 'right id';
ok $job->finish, 'job finished';
ok !$worker->dequeue(0), 'no more jobs';
$job = $minion->job($id);
ok !$job->info->{retried}, 'no retried timestamp';
ok $job->retry, 'job retried';
like $job->info->{retried}, qr/^[\d.]+$/, 'has retried timestamp';
is $job->info->{state},     'inactive',   'right state';
is $job->info->{retries},   1,            'job has been retried once';
$job = $worker->dequeue(0);
is $job->retries, 1, 'job has been retried once';
ok $job->retry, 'job retried';
is $job->id, $id, 'right id';
is $job->info->{retries}, 2, 'job has been retried twice';
$job = $worker->dequeue(0);
is $job->info->{state}, 'active', 'right state';
ok $job->finish, 'job finished';
ok $job->remove, 'job has been removed';
ok !$job->retry, 'job not retried';
is $job->info, undef, 'no information';
$id = $minion->enqueue(add => [6, 5]);
$job = $minion->job($id);
is $job->info->{state},   'inactive', 'right state';
is $job->info->{retries}, 0,          'job has not been retried';
ok $job->retry, 'job retried';
is $job->info->{state},   'inactive', 'right state';
is $job->info->{retries}, 1,          'job has been retried once';
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
ok $job->fail,   'job failed';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$id = $minion->enqueue(add => [5, 5]);
$job = $minion->job("$id");
ok $job->remove, 'job has been removed';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 17 if HAS_PSEUDOFORK;
# Jobs with priority
$minion->enqueue(add => [1, 2]);
$id = $minion->enqueue(add => [2, 4], {priority => 1});
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
isnt $worker->dequeue(0)->id, $id, 'different id';
$id = $minion->enqueue(add => [2, 5]);
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{priority}, 0, 'right priority';
ok $job->finish, 'job finished';
ok $job->retry({priority => 100}), 'job retried with higher priority';
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{retries},  1,   'job has been retried once';
is $job->info->{priority}, 100, 'high priority';
ok $job->finish, 'job finished';
ok $job->retry({priority => 0}), 'job retried with lower priority';
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{retries},  2, 'job has been retried twice';
is $job->info->{priority}, 0, 'low priority';
ok $job->finish, 'job finished';
$worker->unregister;
} # end SKIP

# Delayed jobs
$id = $minion->enqueue(add => [2, 1] => {delay => 100});
is $minion->stats->{delayed_jobs}, 1, 'one delayed job';
SKIP: { skip 'Minion workers do not support fork emulation', 15 if HAS_PSEUDOFORK;
is $worker->register->dequeue(0), undef, 'too early for job';
ok $minion->job($id)->info->{delayed} > time, 'delayed timestamp';
$minion->backend->sqlite->db->query(
  q{update minion_jobs set delayed = datetime('now','-1 day') where id = ?},
  $id);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
like $job->info->{delayed}, qr/^[\d.]+$/, 'has delayed timestamp';
ok $job->finish, 'job finished';
ok $job->retry,  'job retried';
ok $minion->job($id)->info->{delayed} < time, 'no delayed timestamp';
ok $job->remove, 'job removed';
ok !$job->retry, 'job not retried';
$id = $minion->enqueue(add => [6, 9]);
$job = $worker->dequeue(0);
ok $job->info->{delayed} < time, 'no delayed timestamp';
ok $job->fail, 'job failed';
ok $job->retry({delay => 100}), 'job retried with delay';
is $job->info->{retries}, 1, 'job has been retried once';
ok $job->info->{delayed} > time, 'delayed timestamp';
ok $minion->job($id)->remove, 'job has been removed';
$worker->unregister;
} # end SKIP

my $pid;
SKIP: { skip 'Minion workers do not support fork emulation', 15 if HAS_PSEUDOFORK;
# Events
my $failed = 0;
$finished = 0;
$minion->once(
  worker => sub {
    my ($minion, $worker) = @_;
    $worker->on(
      dequeue => sub {
        my ($worker, $job) = @_;
        $job->on(failed   => sub { $failed++ });
        $job->on(finished => sub { $finished++ });
        $job->on(spawn    => sub { $pid = pop });
        $job->on(
          start => sub {
            my $job = shift;
            return unless $job->task eq 'switcheroo';
            $job->task('add')->args->[-1] += 1;
          }
        );
        $job->on(
          finish => sub {
            my $job = shift;
            return unless defined(my $old = $job->info->{notes}{finish_count});
            $job->note(finish_count => $old + 1, pid => $$);
          }
        );
      }
    );
  }
);
$worker = $minion->worker->register;
$minion->enqueue(add => [3, 3]);
$minion->enqueue(add => [4, 3]);
$job = $worker->dequeue(0);
is $failed,   0, 'failed event has not been emitted';
is $finished, 0, 'finished event has not been emitted';
my $result;
$job->on(finished => sub { $result = pop });
ok $job->finish('Everything is fine!'), 'job finished';
$job->perform;
is $result,   'Everything is fine!', 'right result';
is $failed,   0,                     'failed event has not been emitted';
is $finished, 1,                     'finished event has been emitted once';
isnt $pid, $$, 'new process id';
$job = $worker->dequeue(0);
my $err;
$job->on(failed => sub { $err = pop });
$job->fail("test\n");
$job->fail;
is $err,      "test\n", 'right error';
is $failed,   1,        'failed event has been emitted once';
is $finished, 1,        'finished event has been emitted once';
$minion->add_task(switcheroo => sub { });
$minion->enqueue(
  switcheroo => [5, 3] => {notes => {finish_count => 0, before => 23}});
$job = $worker->dequeue(0);
$job->perform;
is_deeply $job->info->{result}, {added => 9}, 'right result';
is $job->info->{notes}{finish_count}, 1, 'finish event has been emitted once';
ok $job->info->{notes}{pid},    'has a process id';
isnt $job->info->{notes}{pid},  $$, 'different process id';
is $job->info->{notes}{before}, 23, 'value still exists';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 12 if HAS_PSEUDOFORK;
# Queues
$id = $minion->enqueue(add => [100, 1]);
is $worker->register->dequeue(0 => {queues => ['test1']}), undef, 'wrong queue';
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{queue}, 'default', 'right queue';
ok $job->finish, 'job finished';
$id = $minion->enqueue(add => [100, 3] => {queue => 'test1'});
is $worker->dequeue(0), undef, 'wrong queue';
$job = $worker->dequeue(0 => {queues => ['test1']});
is $job->id, $id, 'right id';
is $job->info->{queue}, 'test1', 'right queue';
ok $job->finish, 'job finished';
ok $job->retry({queue => 'test2'}), 'job retried';
$job = $worker->dequeue(0 => {queues => ['default', 'test2']});
is $job->id, $id, 'right id';
is $job->info->{queue}, 'test2', 'right queue';
ok $job->finish, 'job finished';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 13 if HAS_PSEUDOFORK;
# Failed jobs
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{result}, undef, 'no result';
ok $job->fail, 'job failed';
ok !$job->finish, 'job not finished';
is $job->info->{state},  'failed',        'right state';
is $job->info->{result}, 'Unknown error', 'right result';
$id = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
ok $job->fail('Something bad happened!'), 'job failed';
is $job->info->{state}, 'failed', 'right state';
is $job->info->{result}, 'Something bad happened!', 'right result';
$id  = $minion->enqueue('fail');
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{result}, "Intentional failure!\n", 'right result';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 5 if HAS_PSEUDOFORK;
# Nested data structures
$minion->add_task(
  nested => sub {
    my ($job, $hash, $array) = @_;
    $job->note(bar => {baz => [1, 2, 3]});
    $job->note(baz => 'yada');
    $job->finish([{23 => $hash->{first}[0]{second} x $array->[0][0]}]);
  }
);
$minion->enqueue(
  'nested',
  [{first => [{second => 'test'}]}, [[3]]],
  {notes => {foo => [4, 5, 6]}}
);
$job = $worker->register->dequeue(0);
$job->perform;
is $job->info->{state}, 'finished', 'right state';
ok $job->note(yada => ['works']), 'added metadata';
ok !$minion->backend->note(-1, {yada => ['failed']}), 'not added metadata';
my $notes = {
  foo => [4, 5, 6],
  bar  => {baz => [1, 2, 3]},
  baz  => 'yada',
  yada => ['works']
};
is_deeply $job->info->{notes}, $notes, 'right metadata';
is_deeply $job->info->{result}, [{23 => 'testtesttest'}], 'right structure';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 2 if HAS_PSEUDOFORK;
# Perform job in a running event loop
$id = $minion->enqueue(add => [8, 9]);
Mojo::IOLoop->delay(sub { $minion->perform_jobs })->wait;
is $minion->job($id)->info->{state}, 'finished', 'right state';
is_deeply $minion->job($id)->info->{result}, {added => 17}, 'right result';
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 3 if HAS_PSEUDOFORK;
# Non-zero exit status
$minion->add_task(exit => sub { exit 1 });
$id  = $minion->enqueue('exit');
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{result}, 'Non-zero exit status (1)', 'right result';
$worker->unregister;
} # end SKIP

# Multiple attempts while processing
is $minion->backoff->(0),  15,     'right result';
is $minion->backoff->(1),  16,     'right result';
is $minion->backoff->(2),  31,     'right result';
is $minion->backoff->(3),  96,     'right result';
is $minion->backoff->(4),  271,    'right result';
is $minion->backoff->(5),  640,    'right result';
is $minion->backoff->(25), 390640, 'right result';
SKIP: { skip 'Minion workers do not support fork emulation', 16 if HAS_PSEUDOFORK;
$id = $minion->enqueue(exit => [] => {attempts => 2});
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->retries, 0, 'job has not been retried';
$job->perform;
$info = $job->info;
is $info->{attempts}, 2,                          'job will be attempted twice';
is $info->{state},    'inactive',                 'right state';
is $info->{result},   'Non-zero exit status (1)', 'right result';
ok $info->{retried} < $info->{delayed}, 'delayed timestamp';
$minion->backend->sqlite->db->query(
  q{update minion_jobs set delayed = datetime('now') where id = ?}, $id);
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->retries, 1, 'job has been retried once';
$job->perform;
$info = $job->info;
is $info->{attempts}, 2,                          'job will be attempted twice';
is $info->{state},    'failed',                   'right state';
is $info->{result},   'Non-zero exit status (1)', 'right result';
ok $job->retry({attempts => 3}), 'job retried';
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
$job->perform;
$info = $job->info;
is $info->{attempts}, 3,        'job will be attempted three times';
is $info->{state},    'failed', 'right state';
is $info->{result}, 'Non-zero exit status (1)', 'right result';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 11 if HAS_PSEUDOFORK;
# Multiple attempts during maintenance
$id = $minion->enqueue(exit => [] => {attempts => 2});
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->retries, 0, 'job has not been retried';
is $job->info->{attempts}, 2,        'job will be attempted twice';
is $job->info->{state},    'active', 'right state';
$worker->unregister;
$minion->repair;
is $job->info->{state},  'inactive',         'right state';
is $job->info->{result}, 'Worker went away', 'right result';
ok $job->info->{retried} < $job->info->{delayed}, 'delayed timestamp';
$minion->backend->sqlite->db->query(
  q{update minion_jobs set delayed = datetime('now') where id = ?}, $id);
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->retries, 1, 'job has been retried once';
$worker->unregister;
$minion->repair;
is $job->info->{state},  'failed',           'right state';
is $job->info->{result}, 'Worker went away', 'right result';
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 12 if HAS_PSEUDOFORK;
# A job needs to be dequeued again after a retry
$minion->add_task(restart => sub { });
$id  = $minion->enqueue('restart');
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
ok $job->finish, 'job finished';
is $job->info->{state}, 'finished', 'right state';
ok $job->retry, 'job retried';
is $job->info->{state}, 'inactive', 'right state';
$job2 = $worker->dequeue(0);
is $job->info->{state}, 'active', 'right state';
ok !$job->finish, 'job not finished';
is $job->info->{state}, 'active', 'right state';
is $job2->id, $id, 'right id';
ok $job2->finish, 'job finished';
ok !$job->retry, 'job not retried';
is $job->info->{state}, 'finished', 'right state';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 8 if HAS_PSEUDOFORK;
# Perform jobs concurrently
$id  = $minion->enqueue(add => [10, 11]);
$id2 = $minion->enqueue(add => [12, 13]);
$id3 = $minion->enqueue('test');
my $id4 = $minion->enqueue('exit');
$worker = $minion->worker->register;
$job    = $worker->dequeue(0);
$job2   = $worker->dequeue(0);
my $job3 = $worker->dequeue(0);
my $job4 = $worker->dequeue(0);
$pid = $job->start;
my $pid2 = $job2->start;
my $pid3 = $job3->start;
my $pid4 = $job4->start;
my ($first, $second, $third, $fourth);
usleep 50000
  until $first ||= $job->is_finished
  and $second  ||= $job2->is_finished
  and $third   ||= $job3->is_finished
  and $fourth  ||= $job4->is_finished;
is $minion->job($id)->info->{state}, 'finished', 'right state';
is_deeply $minion->job($id)->info->{result}, {added => 21}, 'right result';
is $minion->job($id2)->info->{state}, 'finished', 'right state';
is_deeply $minion->job($id2)->info->{result}, {added => 25}, 'right result';
is $minion->job($id3)->info->{state},  'finished', 'right state';
is $minion->job($id3)->info->{result}, undef,      'no result';
is $minion->job($id4)->info->{state},  'failed',   'right state';
is $minion->job($id4)->info->{result}, 'Non-zero exit status (1)',
  'right result';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 4 if HAS_PSEUDOFORK;
# Stopping jobs
$minion->add_task(long_running => sub { sleep 1000 });
$worker = $minion->worker->register;
$minion->enqueue('long_running');
$job = $worker->dequeue(0);
ok $job->start->pid, 'has a process id';
ok !$job->is_finished, 'job is not finished';
$job->stop;
usleep 5000 until $job->is_finished;
is $job->info->{state}, 'failed', 'right state';
like $job->info->{result}, qr/Non-zero exit status/, 'right result';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 30 if HAS_PSEUDOFORK;
# Job dependencies
$worker = $minion->remove_after(0)->worker->register;
is $minion->repair->stats->{finished_jobs}, 0, 'no finished jobs';
$id  = $minion->enqueue('test');
$id2 = $minion->enqueue('test');
$id3 = $minion->enqueue(test => [] => {parents => [$id, $id2]});
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is_deeply $job->info->{children}, [$id3], 'right children';
is_deeply $job->info->{parents}, [], 'right parents';
$job2 = $worker->dequeue(0);
is $job2->id, $id2, 'right id';
is_deeply $job2->info->{children}, [$id3], 'right children';
is_deeply $job2->info->{parents}, [], 'right parents';
ok !$worker->dequeue(0), 'parents are not ready yet';
ok $job->finish, 'job finished';
ok !$worker->dequeue(0), 'parents are not ready yet';
ok $job2->fail, 'job failed';
ok !$worker->dequeue(0), 'parents are not ready yet';
ok $job2->retry, 'job retried';
$job2 = $worker->dequeue(0);
is $job2->id, $id2, 'right id';
ok $job2->finish, 'job finished';
$job = $worker->dequeue(0);
is $job->id, $id3, 'right id';
is_deeply $job->info->{children}, [], 'right children';
is_deeply $job->info->{parents}, [$id, $id2], 'right parents';
is $minion->stats->{finished_jobs}, 2, 'two finished jobs';
is $minion->repair->stats->{finished_jobs}, 2, 'two finished jobs';
ok $job->finish, 'job finished';
is $minion->stats->{finished_jobs}, 3, 'three finished jobs';
is $minion->repair->stats->{finished_jobs}, 0, 'no finished jobs';
$id = $minion->enqueue(test => [] => {parents => [-1]});
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
ok $job->finish, 'job finished';
$id = $minion->enqueue(test => [] => {parents => [-1]});
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is_deeply $job->info->{parents}, [-1], 'right parents';
$job->retry({parents => [-1, -2]});
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
is_deeply $job->info->{parents}, [-1, -2], 'right parents';
ok $job->finish, 'job finished';
$worker->unregister;
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 25 if HAS_PSEUDOFORK;
# Foreground
$id  = $minion->enqueue(test => [] => {attempts => 2});
$id2 = $minion->enqueue('test');
$id3 = $minion->enqueue(test => [] => {parents => [$id, $id2]});
ok !$minion->foreground($id3 + 1), 'job does not exist';
ok !$minion->foreground($id3), 'job is not ready yet';
$info = $minion->job($id)->info;
is $info->{attempts}, 2,          'job will be attempted twice';
is $info->{state},    'inactive', 'right state';
is $info->{queue},    'default',  'right queue';
ok $minion->foreground($id), 'performed first job';
$info = $minion->job($id)->info;
is $info->{attempts}, 1,                   'job will be attempted once';
is $info->{retries},  1,                   'job has been retried';
is $info->{state},    'finished',          'right state';
is $info->{queue},    'minion_foreground', 'right queue';
ok $minion->foreground($id2), 'performed second job';
$info = $minion->job($id2)->info;
is $info->{retries}, 1,                   'job has been retried';
is $info->{state},   'finished',          'right state';
is $info->{queue},   'minion_foreground', 'right queue';
ok $minion->foreground($id3), 'performed third job';
$info = $minion->job($id3)->info;
is $info->{retries}, 2,                   'job has been retried twice';
is $info->{state},   'finished',          'right state';
is $info->{queue},   'minion_foreground', 'right queue';
$id = $minion->enqueue('fail');
eval { $minion->foreground($id) };
like $@, qr/Intentional failure!/, 'right error';
$info = $minion->job($id)->info;
ok $info->{worker}, 'has worker';
ok !$minion->backend->list_workers(0, 1, {ids => [$info->{worker}]})
  ->{workers}[0], 'not registered';
is $info->{retries}, 1,                        'job has been retried';
is $info->{state},   'failed',                 'right state';
is $info->{queue},   'minion_foreground',      'right queue';
is $info->{result},  "Intentional failure!\n", 'right result';
} # end SKIP

SKIP: { skip 'Minion workers do not support fork emulation', 9 if HAS_PSEUDOFORK;
# Worker remote control commands
$worker  = $minion->worker->register->process_commands;
$worker2 = $minion->worker->register;
my @commands;
$_->add_command(test_id => sub { push @commands, shift->id })
  for $worker, $worker2;
$worker->add_command(test_args => sub { shift and push @commands, [@_] })
  ->register;
ok $minion->backend->broadcast('test_id', [], [$worker->id]), 'sent command';
ok $minion->backend->broadcast('test_id', [], [$worker->id, $worker2->id]),
  'sent command';
$worker->process_commands->register;
$worker2->process_commands;
is_deeply \@commands, [$worker->id, $worker->id, $worker2->id],
  'right structure';
@commands = ();
ok $minion->backend->broadcast('test_id'),       'sent command';
ok $minion->backend->broadcast('test_whatever'), 'sent command';
ok $minion->backend->broadcast('test_args', [23], []), 'sent command';
ok $minion->backend->broadcast('test_args', [1, [2], {3 => 'three'}],
  [$worker->id]),
  'sent command';
$_->process_commands for $worker, $worker2;
is_deeply \@commands,
  [$worker->id, [23], [1, [2], {3 => 'three'}], $worker2->id],
  'right structure';
$_->unregister for $worker, $worker2;
ok !$minion->backend->broadcast('test_id', []), 'command not sent';
} # end SKIP

$minion->reset;

done_testing();
