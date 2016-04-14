use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;

$ENV{PATH} ||= '';
plan skip_all => 'bash is missing' unless grep { -x "$_/bash" } split /:/, $ENV{PATH};

my $fork   = Mojo::IOLoop::ReadWriteFork->new;
my $output = '';

$fork->on(error => sub { my ($fork, $error) = @_; diag $error; });
$fork->on(close => sub { my ($fork, $exit_value, $signal) = @_; Mojo::IOLoop->stop; });
$fork->on(read => sub { my ($fork, $buf) = @_; $output .= $buf });
$fork->conduit({type => "pty"});

{
  local $ENV{YIKES} = 'too cool';
  $fork->run("bash", -c => q(echo $YIKES foo bar baz));
}

is $fork->pid, 0, 'no pid' or diag $fork->pid;
Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop });    # guard
Mojo::IOLoop->start;
like $fork->pid, qr{^[1-9]\d+$}, 'got pid' or diag $fork->pid;
like $output, qr/too cool foo bar baz\W{1,2}/, 'got stdout from "echo"' or diag $output;

done_testing;
