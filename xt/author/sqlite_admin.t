use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

use Mojolicious::Lite;
use Mojo::SQLite;
use Test::Mojo;

my $sql = Mojo::SQLite->new;
plugin Minion => {SQLite => $sql};

app->minion->add_task(test => sub { });
my $finished = app->minion->enqueue('test');
app->minion->perform_jobs;
my $inactive = app->minion->enqueue('test');
get '/home' => 'test_home';

plugin 'Minion::Admin';

my $t = Test::Mojo->new;

subtest 'Dashboard' => sub {
  $t->get_ok('/minion')->status_is(200)->content_like(qr/Dashboard/)->element_exists('a[href=/]');
};

subtest 'Stats' => sub {
  $t->get_ok('/minion/stats')->status_is(200)->json_is('/active_jobs' => 0)
    ->json_is('/active_locks'  => 0)->json_is('/active_workers'   => 0)
    ->json_is('/delayed_jobs'  => 0)->json_is('/enqueued_jobs'    => 2)
    ->json_is('/failed_jobs'   => 0)->json_is('/finished_jobs'    => 1)
    ->json_is('/inactive_jobs' => 1)->json_is('/inactive_workers' => 0)
    ->json_has('/uptime');
};

subtest 'Jobs' => sub {
  $t->get_ok('/minion/jobs?state=inactive')->status_is(200)
    ->text_like('tbody td a' => qr/$inactive/)->text_unlike('tbody td a' => qr/$finished/);
  $t->get_ok('/minion/jobs?state=finished')->status_is(200)
    ->text_like('tbody td a' => qr/$finished/)->text_unlike('tbody td a' => qr/$inactive/);
};

subtest 'Workers' => sub {
  $t->get_ok('/minion/workers')->status_is(200)->element_exists_not('tbody td a');
  my $worker = app->minion->worker->register;
  $t->get_ok('/minion/workers')->status_is(200)->element_exists('tbody td a')
    ->text_like('tbody td a' => qr/@{[$worker->id]}/);
  $worker->unregister;
  $t->get_ok('/minion/workers')->status_is(200)->element_exists_not('tbody td a');
};

subtest 'Locks' => sub {
  $t->app->minion->lock('foo', 3600);
  $t->app->minion->lock('bar', 3600);
  $t->ua->max_redirects(5);
  $t->get_ok('/minion/locks')->status_is(200)->text_like('tbody td a' => qr/bar/);
  $t->get_ok('/minion/locks?name=foo')->status_is(200)->text_like('tbody td a' => qr/foo/);
  $t->post_ok('/minion/locks?_method=DELETE&name=bar')->status_is(200)
    ->text_like('tbody td a' => qr/foo/)
    ->text_like('.alert-success', qr/All selected named locks released/);
  is $t->tx->previous->res->code, 302, 'right status';
  like $t->tx->previous->res->headers->location, qr/locks/, 'right "Location" value';
  $t->post_ok('/minion/locks?_method=DELETE&name=foo')->status_is(200)
    ->element_exists_not('tbody td a')
    ->text_like('.alert-success', qr/All selected named locks released/);
  is $t->tx->previous->res->code, 302, 'right status';
  like $t->tx->previous->res->headers->location, qr/locks/, 'right "Location" value';
};

subtest 'Manage jobs' => sub {
  is app->minion->job($finished)->info->{state}, 'finished', 'right state';
  $t->post_ok('/minion/jobs?_method=PATCH' => form => {id => $finished, do => 'retry'})
    ->text_like('.alert-success', qr/All selected jobs retried/);
  is $t->tx->previous->res->code, 302, 'right status';
  like $t->tx->previous->res->headers->location, qr/id=$finished/, 'right "Location" value';
  is app->minion->job($finished)->info->{state}, 'inactive', 'right state';
  $t->post_ok('/minion/jobs?_method=PATCH' => form => {id => $finished, do => 'stop'})
    ->text_like('.alert-info', qr/Trying to stop all selected jobs/);
  is $t->tx->previous->res->code, 302, 'right status';
  like $t->tx->previous->res->headers->location, qr/id=$finished/, 'right "Location" value';
  $t->post_ok('/minion/jobs?_method=PATCH' => form => {id => $finished, do => 'remove'})
    ->text_like('.alert-success', qr/All selected jobs removed/);
  is $t->tx->previous->res->code, 302, 'right status';
  like $t->tx->previous->res->headers->location, qr/id=$finished/, 'right "Location" value';
  is app->minion->job($finished), undef, 'job has been removed';
};

subtest 'Bundled static files' => sub {
  $t->get_ok('/minion/bootstrap/bootstrap.js')->status_is(200)->content_type_is('application/javascript');
  $t->get_ok('/minion/bootstrap/bootstrap.css')->status_is(200)->content_type_is('text/css');
  $t->get_ok('/minion/d3/d3.js')->status_is(200)->content_type_is('application/javascript');
  $t->get_ok('/minion/epoch/epoch.js')->status_is(200)->content_type_is('application/javascript');
  $t->get_ok('/minion/epoch/epoch.css')->status_is(200)->content_type_is('text/css');
  $t->get_ok('/minion/fontawesome/fontawesome.css')->status_is(200)->content_type_is('text/css');
  $t->get_ok('/minion/webfonts/fa-brands-400.eot')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-brands-400.svg')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-brands-400.ttf')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-brands-400.woff')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-brands-400.woff2')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-regular-400.eot')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-regular-400.svg')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-regular-400.ttf')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-regular-400.woff')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-regular-400.woff2')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-solid-900.eot')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-solid-900.svg')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-solid-900.ttf')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-solid-900.woff')->status_is(200);
  $t->get_ok('/minion/webfonts/fa-solid-900.woff2')->status_is(200);
  $t->get_ok('/minion/moment/moment.js')->status_is(200)->content_type_is('application/javascript');
  $t->get_ok('/minion/app.js')->status_is(200)->content_type_is('application/javascript');
  $t->get_ok('/minion/app.css')->status_is(200)->content_type_is('text/css');
  $t->get_ok('/minion/logo-black-2x.png')->status_is(200)->content_type_is('image/png');
  $t->get_ok('/minion/logo-black.png')->status_is(200)->content_type_is('image/png');
};

subtest 'Different prefix and return route' => sub {
  plugin 'Minion::Admin' => {route => app->routes->any('/also_minion'), return_to => 'test_home'};
  $t->get_ok('/also_minion')->status_is(200)->content_like(qr/Dashboard/)->element_exists('a[href=/home]');
};

done_testing();
