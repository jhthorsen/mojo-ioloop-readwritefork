use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

plan tests => 10;

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $output = '';
  my $closed = 0;
  my $read;

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
    $run->write("line one\n") unless $read;
    memory_cycle_ok $run, 'no cycle inside read' unless $read++;
  });
  memory_cycle_ok $run, 'no cycle after on()';

  eval { $run->start({ program_args => [] }) };
  like $@, qr{program is required input}, 'program is required';
  $run->start(
    program => sub {
      print join(" ", @_), "\n";
      my $input = <STDIN>;
      print $input;
      print "line two\n";
    },
    program_args => [qw( some args )],
  );

  memory_cycle_ok $run, 'no cycle after start()';
  is $run->pid, 0, 'no pid' or diag $run->pid;
  Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;
  memory_cycle_ok $run, 'no cycle after Mojo::IOLoop->start';

  like $run->pid, qr{^[1-9]\d+$}, 'got pid' or diag $run->pid;
  like $output, qr/^some args\nline one\nline two\n/, 'got stdout from callback' or diag $output;
  is $closed, 1, "got close event";
}
