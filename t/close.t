use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $output = '';

  $run->on(close => sub { Mojo::IOLoop->stop; });
  $run->on(read => sub { $output .= $_[1]; });
  $run->write("line one\nline two\n", sub { shift->close('stdin'); });
  $run->run(sub { print while <>; print "FORCE\n"; });

  Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;

  like $output, qr/line one\nline two\nFORCE\n/, 'close' or diag $output;
}

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $output = '';

  $run->on(close => sub { Mojo::IOLoop->stop; });
  $run->on(read => sub { $output .= $_[1]; shift->close_gracefully('stdin'); });
  $run->write("line one\nline two\n");
  $run->run(sub { print while <>; print "GRACEFUL\n" });

  Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;

  like $output, qr/line one\nline two\nGRACEFUL\n/, 'close_gracefully' or diag $output;
}

done_testing;