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
  return $self->{ev}{$pid} ||= EV::child($pid, 0, sub { $self->_exit($pid, shift->rstatus) })
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
  delete $self->{ev}{$pid};
  for my $cb (@$listeners) { $cb->($status, $pid) }
}

1;

=head1 NAME

Mojo::IOLoop::ReadWriteFork::SIGCHLD - Non-blocking waitpid for Mojolicious

=head1 DESCRIPTION

L<Mojo::IOLoop::ReadWriteFork::SIGCHLD> is a module that can wait for a child
process to exit. This is currently done either with L<EV/child> or a recurring
timer and C<waitpid>.

=head1 METHODS

=head2 is_waiting

  $bool = $sigchld->is_waiting;

Returns true if C<$sigchld> is still waiting for a process to exit.

=head2 singleton

  $sigchld = Mojo::IOLoop::ReadWriteFork::SIGCHLD->singleton;

Returns a shared L<Mojo::IOLoop::ReadWriteFork::SIGCHLD> object.

=head2 waitpid

  $sigchld->waitpid($pid, sub { my ($exit_value) = @_ });

Will call the provided callback with C<$?> when the C<$pid> is no longer running.

=head1 SEE ALSO

L<Mojo::IOLoop::ReadWriteFork>.

=cut
