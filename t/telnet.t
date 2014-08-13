use Mojo::Base -strict;
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

$ENV{PATH} ||= '';
plan skip_all => 'telnet is missing' unless grep { -x "$_/telnet" } split /:/, $ENV{PATH};

my $address = '127.0.0.1';
my $port = Mojo::IOLoop::Server->generate_port;

# echo server
Mojo::IOLoop->server({ address => $address, port => $port }, sub {
  my ($ioloop, $stream) = @_;
  $stream->on(read => sub { $_[0]->write("I heard you say: $_[1]"); });
});

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $output = '';
  my $drain = 0;

  $run->on(close => sub { Mojo::IOLoop->stop; });
  $run->on(read => sub {
    my ($run, $chunk) = @_;
    $run->write("hey\n", sub { $drain++; }) if $chunk =~ /Connected/;
    $run->kill if $chunk =~ /I heard you say: hey/;
    $output .= $chunk;
  });

  $run->start(
    program => 'telnet',
    program_args => [$address => $port],
    conduit => 'pty',
  );

  #Mojo::IOLoop->timer(2 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;
  like $output, qr{Connected}, 'Connected';
  like $output, qr{I heard you say: hey}, 'got echo';
  is $drain, 1, 'got drain event';
}

done_testing;
