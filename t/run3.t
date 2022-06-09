use Mojo::Base -strict;
use Mojo::Run3;
use Test::More;

subtest 'stdout' => sub {
  my $run3   = Mojo::Run3->new;
  my $stdout = '';
  $run3->on(stderr => sub { diag "STDERR <<< $_[1]" });
  $run3->on(stdout => sub { $stdout .= $_[1]; shift->kill(15) });
  $run3->run_p(sub { print STDOUT "cool beans\n" })->wait;
  is $stdout,       "cool beans\n", 'read';
  is $run3->status, 0,              'status';
};

subtest 'stderr' => sub {
  my $run3   = Mojo::Run3->new;
  my $stdout = '';
  $run3->on(stderr => sub { $stdout .= $_[1]; shift->kill(15) });
  $run3->run_p(sub { print STDERR "cool beans\n" })->wait;
  is $stdout,       "cool beans\n", 'read';
  is $run3->status, 0,              'status';
};

subtest 'stdin' => sub {
  my $run3   = Mojo::Run3->new;
  my $stdout = '';
  $run3->on(stderr => sub { diag "STDERR <<< $_[1]" });
  $run3->on(stdout => sub { $stdout .= $_[1]; shift->kill(9) });
  $run3->on(spawn  => sub { shift->write("cool beans\n") });
  $run3->run_p(sub { print scalar <STDIN> })->wait;
  is $stdout,       "cool beans\n", 'read';
  is $run3->status, 0,              'status';
};

done_testing;
