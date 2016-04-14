use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;

my $fork   = Mojo::IOLoop::ReadWriteFork->new;
my $output = '';

$fork->on(error => sub { my ($fork, $error) = @_; diag $error; });
$fork->on(close => sub { my ($fork, $exit_value, $signal) = @_; Mojo::IOLoop->stop; });
$fork->on(read => sub { my ($fork, $buf) = @_; $output .= $buf });
$fork->run(sub { say join ',', @_ }, 1, 2, 3);

is $fork->pid, 0, 'no pid' or diag $fork->pid;
Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop });    # guard
Mojo::IOLoop->start;
like $fork->pid, qr{^[1-9]\d+$}, 'got pid' or diag $fork->pid;
like $output, qr/1,2,3/, 'ran code' or diag $output;

done_testing;
