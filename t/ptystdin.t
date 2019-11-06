use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;

$ENV{PATH} ||= '';
plan skip_all => 'cat is missing' unless grep { -x "$_/cat" } split /:/, $ENV{PATH};

my $fork   = Mojo::IOLoop::ReadWriteFork->new;
my $output = '';
my $n      = 0;
my $closed = 0;
my $testdata = "testing one two three";

$fork->on(
  error => sub {
    my ($fork, $error) = @_;
    diag $error;
    $n++ > 20 and exit;
  }
);
$fork->on(
  close => sub {
    my ($fork, $exit_value, $signal) = @_;
    $closed++;
    Mojo::IOLoop->stop;
  }
);
$fork->on(
  read => sub {
    my ($fork, $buffer, $writer) = @_;
    $output .= $buffer;
    $n++ > 20 and exit;
  }
);

### NOTES:
#  With the below test, there are two problems with 0.37 ReadWriteFork
#
#  1) Cat isn't getting the write data.
#  2) The close event isn't being detected properly.
#
# I've patched both of these by a) using the below timer hack and b) the patch
# around line 125 of ReadWriteFork.pm. See more notes there.

$fork->on(
  fork => sub {
    $fork->write("testing one two three", sub {
      Mojo::IOLoop->timer( 1 => sub {
        $fork->close("stdin");
      });
    });
  }
);



$fork->start(program => 'cat', conduit => 'pty');
is $fork->pid, 0, 'no pid' or diag $fork->pid;
Mojo::IOLoop->timer(5 => sub { Mojo::IOLoop->stop });    # guard
Mojo::IOLoop->start;

like $fork->pid, qr{^[1-9]\d+$}, 'got pid' or diag $fork->pid;
like $output, qr/^$testdata/, 'got stdout from "cat"' or diag $output;
is $closed, 1, 'got close event';
ok !$fork->{stdin_write}, 'stdin_write handle was cleaned up';
ok !$fork->{stdout_read}, 'stdout_read handle was cleaned up';

done_testing;
