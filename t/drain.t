use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $drain = 0;
  my $output = '';

  $run->on(close => sub { Mojo::IOLoop->stop; });
  $run->on(read => sub { $output .= $_[1]; });
  $run->write("line one\n", sub { $drain++; });
  $run->start(program => sub {
    print sysread STDIN, my $buf, 1024;
    print "\n$buf";
    print "line two\n";
  });

  Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;
  memory_cycle_ok $run, 'no cycle after run';

  like $output, qr/^9\nline one\nline two\n/, 'can write() before start()' or diag $output;
  is $drain, 1, 'drain callback was called';
}

done_testing;
