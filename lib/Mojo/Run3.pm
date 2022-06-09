package Mojo::Run3;
use Mojo::Base 'Mojo::EventEmitter';

use Carp qw(croak);
use Errno qw(EAGAIN ECONNRESET EINTR EPIPE EWOULDBLOCK EIO);
use IO::Handle;
use IO::Pty;
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteFork;
use Mojo::IOLoop::ReadWriteFork::SIGCHLD;
use Mojo::Promise;
use Mojo::Util qw(term_escape);
use Scalar::Util qw(blessed weaken);

our $VERSION = '2.02';

has conduit => 'pipe';
has ioloop  => sub { Mojo::IOLoop->singleton }, weak => 1;
has pid     => 0;
has status  => 0;

sub close {
  my ($self, $name) = @_;
  my $fh = delete $self->{fh}{stdin_write} or return $self;

  #if (blessed $fh and $fh->isa('IO::Pty')) {
  #  for my $name (qw(pty stdout)) {
  #    my $stream = $self->{stream}{$name} && $self->ioloop->stream($self->{stream}{$name});
  #    $stream->close if $stream and $stream->handle eq $fh;
  #  }
  #}

  croak "Cannot close stdin: $!" unless $fh->close;
  return $self;
}

sub kill {
  my ($self, $signal) = (@_, 15);
  return $self->pid ? kill $signal, $self->pid : -1;
}

sub run_p {
  my ($self, $code) = @_;
  my $p = Mojo::Promise->new;
  $self->on(finish => sub { $p->resolve($_[1]) });
  $self->start($code);
  return $p;
}

sub start {
  my ($self, $code) = @_;

  $self->ioloop->next_tick(sub {
    return $self->_finish($@, $!) unless my $fh = eval { $self->_prepare_filehandles };
    $self->emit(prepare => $self->{fh} || {});
    return $self->_finish("Can't fork: $!", $!) unless defined($self->{pid} = fork);
    return $self->{pid} ? $self->_start_parent($fh) : $self->_start_child($fh, $code);
  });

  return $self;
}

sub write {
  my ($self, $chunk, $cb) = @_;
  $self->once(drain => $cb) if $cb;
  $self->{stdin_buffer} .= $chunk;
  $self->_write if $self->{fh}{stdin_write};
  return $self;
}

sub _finish {
  my ($self, $err, $errno) = @_;
  $self->{status} = $errno;
  $self->emit(error => $err)->emit(finish => $errno);
}

sub _prepare_filehandles {
  my ($self) = @_;
  my %fh;

  if ($self->conduit eq 'pipe') {
    @fh{qw(stdin_read stdin_write)}   = $self->_make_pipe;
    @fh{qw(stdout_read stdout_write)} = $self->_make_pipe;
    @fh{qw(stderr_read stderr_write)} = $self->_make_pipe;
  }
  elsif ($self->conduit eq 'pty') {
    @fh{qw(pty)}                      = IO::Pty->new;
    @fh{qw(stdin_read stdin_write)}   = $self->_make_pipe;
    @fh{qw(stdout_read stdout_write)} = $self->_make_pipe;
    @fh{qw(stderr_read stderr_write)} = $self->_make_pipe;
  }
  else {
    croak "Unsupported conduit";
  }

  return \%fh;
}

sub _cleanup {
  my ($self) = @_;
  delete $self->{fh}{stdin_write};

  my $reactor = $self->ioloop->reactor;
  for my $name (qw(stderr_read stdout_read)) {
    my $h = delete $self->{fh}{$name};
    $reactor->remove($h) if $h;
  }
}

sub _make_pipe {
  my ($self) = @_;
  pipe my $read, my $write or die $!;
  $write->autoflush(1);
  return $read, $write;
}

sub _maybe_terminate {
  my ($self, $pending_event) = @_;
  $self->{$pending_event} = 0;
  return if $self->{wait_eof} or $self->{wait_sigchld};

  $self->_cleanup;
  for my $cb (@{$self->subscribers('finish')}) {
    $self->emit(error => $@) unless eval { $self->$cb($self->{status} // -1); 1 };
  }
}

sub _read {
  my ($self, $name, $handle) = @_;

  my $read = $handle->sysread(my $buf, 131072, 0);
  unless (defined $read) {
    return undef                    if $! == EAGAIN || $! == EINTR || $! == EWOULDBLOCK;    # Retry
    return $self->emit(error => $!) if $! != ECONNRESET and $! != EIO;                      # Closed (maybe real error)
  }

  return $read ? $self->emit($name => $buf) : $self->_maybe_terminate('wait_eof');
}

sub _start_child {
  my ($self, $fh, $code) = @_;
  $fh->{pty}->make_slave_controlling_terminal if $fh->{pty};

  open STDIN,  '<&' . fileno($fh->{stdin_read})   or die "Could not dup stdin: $!";
  open STDOUT, '>&' . fileno($fh->{stdout_write}) or die "Could not dup stdout: $!";
  open STDERR, '>&' . fileno($fh->{stderr_write}) or die "Could not dup stderr: $!";
  STDOUT->autoflush(1);
  STDERR->autoflush(1);

  delete($fh->{$_})->close for (qw(stdin_write stdout_read stderr_read));
  @SIG{@Mojo::IOLoop::ReadWriteFork::SAFE_SIG} = ('DEFAULT') x @Mojo::IOLoop::ReadWriteFork::SAFE_SIG;
  ($@, $!) = ('', 0);

  eval { $self->$code($fh) };
  my ($err, $errno) = ($@, $@ ? 255 : $! || 0);
  print STDERR $@ if length $@;
  POSIX::_exit($errno) || exit $errno;
}

sub _start_parent {
  my ($self, $fh) = @_;

  weaken $self;
  my $reactor = $self->ioloop->reactor;
  for my $name (qw(stderr stdout)) {
    my $h = $fh->{"${name}_read"};
    $reactor->io($h, sub { $self ? $self->_read($name => $h) : $_[0]->remove($h) })->watch($h, 1, 0);
  }

  delete($fh->{$_})->close for (qw(stdin_read stdout_write stderr_write));
  $self->{fh} = $fh;

  @$self{qw(wait_eof wait_sigchld)} = (1, 1);
  Mojo::IOLoop::ReadWriteFork::SIGCHLD->singleton->waitpid(
    $self->{pid} => sub {
      $self->{status} = $_[0];
      $self->_maybe_terminate('wait_sigchld');
    }
  );

  $self->_write;
  $self->emit(spawn => $fh);
}

sub _write {
  my $self = shift;
  return unless length $self->{stdin_buffer};

  my $stdin_write = $self->{fh}{stdin_write};
  my $written     = $stdin_write->syswrite($self->{stdin_buffer});
  unless (defined $written) {
    return if $! == EAGAIN || $! == EINTR || $! == EWOULDBLOCK;
    return $self->kill if $! == ECONNRESET || $! == EPIPE;
    return $self->emit(error => $!);
  }

  substr $self->{stdin_buffer}, 0, $written, '';
  return $self->emit('drain') unless length $self->{stdin_buffer};
  return $self->ioloop->next_tick(sub { $self->_write });
}

1;
