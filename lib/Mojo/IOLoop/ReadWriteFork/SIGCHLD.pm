package Mojo::IOLoop::ReadWriteFork::SIGCHLD;
use Mojo::Base -base;

use POSIX ':sys_wait_h';
use Scalar::Util qw(weaken);

use constant WAIT_PID_INTERVAL => $ENV{WAIT_PID_INTERVAL} || 0.05;

sub is_waiting {
  my $self = shift;
  return !!(%{$self->{pids} || {}} || $self->{tid});
}

sub singleton { state $singleton = Mojo::IOLoop::ReadWriteFork::SIGCHLD->new }

sub waitpid {
  my ($self, $pid, $cb) = @_;

  my $pids = $self->{pids} //= {};
  push @{$pids->{$pid}}, $cb;

  # The CHLD test is for code, such as Minion::Command::minion::worker
  # where SIGCHLD is set up for manual waitpid() checks.
  # See https://github.com/kraih/minion/issues/15 and
  # https://github.com/jhthorsen/mojo-ioloop-readwritefork/issues/9 for details.
  my $reactor = Mojo::IOLoop->singleton->reactor;
  return EV::child($pid, 0, sub { $self->_exit($pid, $_->rstatus) })
    if !$SIG{CHLD} and $reactor->isa('Mojo::Reactor::EV');

  weaken $self;
  $self->{tid} ||= Mojo::IOLoop->recurring(
    WAIT_PID_INTERVAL,
    sub {
      for my $pid (keys %$pids) {
        local ($?, $!);
        $self->_exit($pid, $?) if $pid == CORE::waitpid($pid, WNOHANG);
      }

      $reactor->remove(delete $self->{tid}) unless %$pids;
    }
  );
}

sub _exit {
  my ($self, $pid, $status) = @_;
  my $listeners = delete $self->{pids}{$pid};
  for my $cb (@$listeners) { $cb->($status, $pid) }
}

1;
