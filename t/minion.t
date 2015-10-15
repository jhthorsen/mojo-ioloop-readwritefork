BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::EV' }
use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use Test::Mojo;
use Test::More;
use Time::HiRes qw( ualarm usleep );

plan skip_all => 'EV need to be installed to run this test'
  unless eval { Mojo::IOLoop->singleton->reactor->isa('Mojo::Reactor::EV') };
plan skip_all => 'Minion need to be installed to run this test' unless eval 'require Minion;1';

my $tmpdir = tempdir CLEANUP => 1;
my $file = catfile $tmpdir, 'minion.db';

use Mojolicious::Lite;
plugin Minion => {File => $file};
app->minion->add_task(
  rwf => sub {
    my $job       = shift;
    my $fork      = Mojo::IOLoop::ReadWriteFork->new;
    my $exit_code = 0;

    $fork->on(close => sub { $exit_code = $_[1]; Mojo::IOLoop->stop; });
    $fork->run(sub { print "I am $$.\n"; $! = 42; });
    Mojo::IOLoop->start;
    $job->finish($exit_code);
  }
);
app->minion->enqueue('rwf');

require Minion::Command::minion::worker;
my $worker = Minion::Command::minion::worker->new(app => app);

$SIG{ALRM} = sub { kill TERM => $$ };    # graceful exit
ualarm 100e3;
$worker->run;

my $jobs = app->minion->backend->list_jobs(0, 10);
is $jobs->[0]{result}, 42, 'exit_code from child';

done_testing();
