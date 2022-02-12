use Mojo::Base -strict;
use Test::More;
use Mojo::IOLoop::ReadWriteFork;

plan skip_all => 'READWRITEFORK_SSH=host is not set' unless $ENV{READWRITEFORK_SSH} or -e '.readwritefork_ssh';

$ENV{READWRITEFORK_SSH} ||= Mojo::File->new('.readwritefork_ssh')->slurp;
chomp $ENV{READWRITEFORK_SSH};

my $columns = int(300 * rand);
my $fork    = Mojo::IOLoop::ReadWriteFork->new;
my (@pipe_names, @pipe_ref);
$fork->on(
  prepare => sub {
    my ($fork, $pipes) = @_;
    @pipe_names = sort keys %$pipes;
    @pipe_ref   = map { ref $pipes->{$_} } sort keys %$pipes;
    $pipes->{stdout_read}->set_winsize(40, $columns);
  }
);

my ($stdout, $stderr) = ('', '');
$fork->on(stdout => sub { $stdout .= pop });
$fork->on(stderr => sub { $stderr .= pop });
$fork->conduit({stderr => 1, stdout => 1, type => 'pty'})->run_p(ssh => $ENV{READWRITEFORK_SSH}, -t => q(tput cols))
  ->wait;

is_deeply \@pipe_names, [qw(stderr_read stderr_write stdin_read stdin_write stdout_read stdout_write)], 'pipe names';
is_deeply \@pipe_ref,   ['GLOB', 'GLOB', '', 'IO::Pty', 'IO::Pty', ''],                                 'pipe types';
like $stdout, qr{$columns\r\n}s, 'changed columns';
like $stderr, qr{closed},        'stderr';

done_testing;
