use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::More;
use Test::Memory::Cycle;

$ENV{PATH} ||= '';
plan skip_all => 'bash is missing' unless grep { -x "$_/bash" } split /:/, $ENV{PATH};

{
  my $run = Mojo::IOLoop::ReadWriteFork->new;
  my $err;

  $run->on(close => sub { Mojo::IOLoop->stop });
  $run->on(error => sub { $err = "$_[1]" });
  $run->on(read => sub { $! = 2 });

  $run->start(
    program => 'bash',
    program_args => [ -c => 'echo test123' ],
    conduit => 'pty',
  );

  Mojo::IOLoop->start;
  is $err, undef, 'no error when callback change ERRNO';
}

done_testing;
