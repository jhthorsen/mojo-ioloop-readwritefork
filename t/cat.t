use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

$ENV{PATH} ||= '';
plan skip_all => 'cat is missing' unless grep { -x "$_/cat" } split /:/, $ENV{PATH};
plan tests => 10;

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $output = '';
  my $closed = 0;
  my $cycled;

  memory_cycle_ok $run, 'no cycle after new()';
  $run->on(error => sub {
    my($run, $error) = @_;
    diag $error;
  });
  $run->on(close => sub {
    $closed++;
    Mojo::IOLoop->stop;
  });
  $run->on(read => sub {
    my($run, $buffer, $writer) = @_;
    $output .= $buffer;
    memory_cycle_ok $run, 'no cycle inside read' unless $cycled++;
  });
  memory_cycle_ok $run, 'no cycle after on()';

  eval { $run->start({ program_args => [] }) };
  like $@, qr{program is required input}, 'program is required';
  $run->start(
    program => 'cat',
    program_args => [ '-' ],
    conduit => 'pty',
  );

  memory_cycle_ok $run, 'no cycle after start()';
  is $run->pid, 0, 'no pid' or diag $run->pid;
  Mojo::IOLoop->timer(0.1, sub { $run->write("hello world\n\x04") });
  Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;
  memory_cycle_ok $run, 'no cycle after Mojo::IOLoop->start';

  like $run->pid, qr{^[1-9]\d+$}, 'got pid' or diag $run->pid;
  like $output, qr/^hello world\W{1,2}hello world\W{1,2}$/, 'got stdout from "cat -"' or diag $output;
  is $closed, 1, "got close event";
}
