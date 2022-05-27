use Mojo::Base -strict;
use Test::More;
use Mojo::File qw(path);
use Mojo::IOLoop::ReadWriteFork;

plan skip_all => 'READWRITEFORK_SSH=host is not set' unless $ENV{READWRITEFORK_SSH};

my $password ||= -e '.readwritefork_ssh_password' ? path('.readwritefork_ssh_password')->slurp : 's3cret';
chomp $password;

my @ssh_options = (
  -o => 'IdentitiesOnly=no',
  -o => 'NumberOfPasswordPrompts=1',
  -o => 'PreferredAuthentications=keyboard-interactive,password'
);

my $fork = Mojo::IOLoop::ReadWriteFork->new->conduit({type => 'pty3'});
my %out  = map { ($_ => '') } qw(pty stderr stdout);

$fork->on(
  pty => sub {
    my ($fork, $chunk) = @_;
    $out{pty} .= $chunk;
    $fork->write("$password\n", "pty") if $chunk =~ m![Pp]assword:!;
  }
);

$fork->on(
  stderr => sub {
    my ($fork, $chunk) = @_;
    $out{stderr} .= $chunk;
  }
);

$fork->on(
  stdout => sub {
    my ($fork, $chunk) = @_;
    $out{stdout} .= $chunk;
  }
);

$fork->run_p(ssh => @ssh_options, $ENV{READWRITEFORK_SSH}, qw(ls -l /))->wait;
like $out{pty},    qr{password:\s+$}s, 'pty';
like $out{stdout}, qr{\sroot\s}s,      'stdout';
is $out{stderr}, '', 'stderr';

done_testing;
