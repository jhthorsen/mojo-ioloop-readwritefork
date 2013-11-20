use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

$ENV{PATH} ||= '';
plan skip_all => 'bash is missing' unless grep { -x "$_/bash" } split /:/, $ENV{PATH};
plan tests => 4;

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $output = '';
  my $n = 0;
  my $closed = 0;

  $run->on(error => sub {
    my($run, $error) = @_;
    diag $error;
    $n++ > 20 and exit;
  });
  $run->on(close => sub {
    $closed++;
    Mojo::IOLoop->stop;
  });
  $run->on(read => sub {
    my($run, $buffer, $writer) = @_;
    $output .= $buffer;
    $n++ > 20 and exit;
  });

  {
    local $ENV{YIKES} = 'too cool';
    $run->start(
      program => 'bash',
      program_args => [ -c => 'echo $YIKES foo bar baz' ],
      conduit => 'pipe',
    );
  }

  is $run->pid, 0, 'no pid' or diag $run->pid;
  Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;
  like $run->pid, qr{^[1-9]\d+$}, 'got pid' or diag $run->pid;
  like $output, qr/^too cool foo bar baz\W{1,2}$/, 'got stdout from "echo"' or diag $output;
  is $closed, 1, "got close event";
}
