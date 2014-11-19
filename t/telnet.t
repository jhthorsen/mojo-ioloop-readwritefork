use Mojo::Base -strict;
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

$ENV{PATH} ||= '';
plan skip_all => 'telnet is missing' unless grep { -x "$_/telnet" } split /:/, $ENV{PATH};

my $address = 'localhost';
my $port = Mojo::IOLoop::Server->generate_port;
my $connected = 0;

# echo server
Mojo::IOLoop->server({ address => $address, port => $port }, sub {
  my ($ioloop, $stream) = @_;
  $stream->on(read => sub {
    my ($stream, $chunk) = @_;
    diag "server<<<($chunk)";
    $stream->write("I heard you say: $chunk"); });
});

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $output = '';
  my $drain = 0;

  $run->on(close => sub { Mojo::IOLoop->stop; });
  $run->on(read => sub {
    my ($run, $chunk) = @_;
    diag "client<<<($chunk)";
    $run->write("open $address $port\r\n") unless $connected++;
    $run->write("hey\r\n", sub { $drain++; }) if $chunk =~ /Connected/;
    $run->kill if $chunk =~ /I heard you say/;
    $output .= $chunk;
  });

  $run->start(
    program => 'telnet',
    program_args => [],
    conduit => 'pty',
  );

  Mojo::IOLoop->timer(2 => sub { Mojo::IOLoop->stop }); # guard
  Mojo::IOLoop->start;
  like $output, qr{Connected}, 'Connected';
  like $output, qr{I heard you say:.*hey}s, 'got echo';
  is $drain, 1, 'got drain event';
}

done_testing;
