use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

plan tests => 10;

my $fork   = Mojo::IOLoop::ReadWriteFork->new;
my $output = '';
my $closed = 0;
my $read;

memory_cycle_ok $fork, 'no cycle after new()';
$fork->on(
  error => sub {
    my ($fork, $error) = @_;
    diag $error;
  }
);
$fork->on(
  close => sub {
    $closed++;
    Mojo::IOLoop->stop;
  }
);
$fork->on(
  read => sub {
    my ($fork, $buffer, $writer) = @_;
    $output .= $buffer;
    $fork->write("line one\n") unless $read;
    memory_cycle_ok $fork, 'no cycle inside read' unless $read++;
  }
);
memory_cycle_ok $fork, 'no cycle after on()';

eval { $fork->start({program_args => []}) };
like $@, qr{program is required input}, 'program is required';
$fork->start(
  program => sub {
    print join(" ", @_), "\n";
    my $input = <STDIN>;
    print $input;
    print "line two\n";
  },
  program_args => [qw( some args )],
);

memory_cycle_ok $fork, 'no cycle after start()';
is $fork->pid, 0, 'no pid' or diag $fork->pid;
Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop });    # guard
Mojo::IOLoop->start;
memory_cycle_ok $fork, 'no cycle after Mojo::IOLoop->start';

like $fork->pid, qr{^[1-9]\d+$}, 'got pid' or diag $fork->pid;
like $output, qr/^some args\nline one\nline two\n/, 'got stdout from callback' or diag $output;
is $closed, 1, "got close event";
