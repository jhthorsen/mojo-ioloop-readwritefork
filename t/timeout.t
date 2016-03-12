use Mojo::Base -strict;
use Test::More tests => 3;
use Mojo::IOLoop::ReadWriteFork;



my $fork = Mojo::IOLoop::ReadWriteFork->new;
my $exit_value;

$fork->on(read => sub {
    like $_[1], qr{hello|bye}, 'read test';
});
my $start = time;
$fork->on(read_timeout => sub {
    is time-$start, 3, 'read_timeout with one reset';
});
$fork->on(close => sub { Mojo::IOLoop->stop; });
$fork->read_timeout(2);
$fork->start(program => 'bash', program_args => ['-c','sleep 1;echo hello;sleep 3;echo bye']);
Mojo::IOLoop->start;


done_testing;
