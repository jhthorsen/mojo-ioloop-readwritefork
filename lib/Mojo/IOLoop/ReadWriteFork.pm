package Mojo::IOLoop::ReadWriteFork;

=head1 NAME

Mojo::IOLoop::ReadWriteFork - Fork a process and read/write from it

=head1 VERSION

0.16

=head1 DESCRIPTION

This class enable you to fork children which you can write data to
and emit events when the child prints to STDERR or STDOUT.

Patches that enable the L</read> event to see the difference between STDERR
and STDOUT are more than welcome.

=head1 SYNOPSIS

=head2 Standalone

  my $fork = Mojo::IOLoop::ReadWriteFork->new;
  my $cat_result = '';

  $fork->on(error => sub {
    my($fork, $error) = @_;
    warn $error;
  });
  $fork->on(close => sub {
    my($fork, $exit_value, $signal) = @_;
    warn "got close event";
    Mojo::IOLoop->stop;
  });
  $fork->on(read => sub {
    my($fork, $buffer) = @_; # $buffer = both STDERR and STDOUT
    $cat_result .= $buffer;
  });

  $fork->on(read_timeout => sub {
    my $fork = shift;
    $fork->kill(9);
  });

  $fork->start(
    program => 'bash',
    program_args => [ -c => 'echo $YIKES foo bar baz' ],
    conduit => 'pty',
  );

=head2 In a Mojolicios::Controller

See L<https://github.com/jhthorsen/mojo-ioloop-readwritefork/tree/master/example/tail.pl>.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::Util;
use Errno qw( EAGAIN ECONNRESET EINTR EPIPE EWOULDBLOCK );
use IO::Pty;
use POSIX ':sys_wait_h';
use Scalar::Util ();
use constant CHUNK_SIZE        => $ENV{MOJO_CHUNK_SIZE}           || 131072;
use constant DEBUG             => $ENV{MOJO_READWRITE_FORK_DEBUG} || $ENV{MOJO_READWRITEFORK_DEBUG} || 0;
use constant WAIT_PID_INTERVAL => $ENV{WAIT_PID_INTERVAL}         || 0.01;

my %ESC = ("\0" => '\0', "\a" => '\a', "\b" => '\b', "\f" => '\f', "\n" => '\n', "\r" => '\r', "\t" => '\t');

sub ESC {
  local $_ = shift;
  s/([\x00-\x1f\x7f\x80-\x9f])/$ESC{$1} || sprintf "\\x%02x", ord $1/ge;
  $_;
}

our $VERSION = '0.16';

our @SAFE_SIG = grep {
  not /^(
     NUM\d+
    |__[A-Z0-9]+__
    |ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE|RTMAX|RTMIN|SEGV|SETS
    |
  )$/x
} keys %SIG;

=head1 EVENTS

=head2 close

  $self->emit(close => sub { my($self, $exit_value, $signal) = @_; });

Emitted when the child process exit.

=head2 error

  $self->emit(error => sub { my($self, $str) = @_; });

Emitted when when the there is an issue with creating, writing or reading
from the child process.

=head2 read

  $self->emit(read => sub { my($self, $chunk) = @_; });

Emitted when the child has written a chunk of data to STDOUT or STDERR.

=head2 timeout

  $self->emit(read_timeout => sub { my($self) = @_;});

Emitted when the read event is not triggered for more the $self->read_timeout seconds.

=head1 ATTRIBUTES

=head2 ioloop

  $ioloop = $self->ioloop;
  $self = $self->ioloop(Mojo::IOLoop->singleton);

Holds a L<Mojo::IOLoop> object.

=head2 pid

  $int = $self->pid;

Holds the child process ID.

=head2 read_timeout

a read_timeout event is triggered if no read events happen for more than read_timeout seconds.

=head2 reactor

DEPRECATED.

=cut

has 'read_timeout';

sub pid { shift->{pid} || 0; }
has ioloop => sub { Mojo::IOLoop->singleton; };
sub reactor { warn "DEPRECATED! Use \$self->ioloop->reactor; instead"; shift->ioloop->reactor; }

=head1 METHODS

=head2 close

  $self = $self->close("stdin");

Close STDIN stream to the child process immediately.

=cut

sub close {
  my $self = shift;
  my $what = $_[0] eq 'stdout' ? 'stdout_read' : 'stdin_write';    # stdout_read is EXPERIMENTAL
  my $fh   = delete $self->{$what} or return $self;
  CORE::close($fh) or $self->emit(error => $!);
  $self;
}

=head2 run

  $self = $self->run($program, @program_args);

Simpler version of L</start>.

=cut

sub run {
  my ($self, $program, @program_args) = @_;

  $self->start(program => $program, program_args => \@program_args);
  $self;
}

=head2 start

  $self->start(
    program => sub { my @program_args = @_; ... },
    program_args => [ @data ],
  );

  $self->start(
    program => $str,
    program_args => [@str],
    conduit => $str, # pipe or pty
    raw => $bool,
    clone_winsize_from => \*STDIN,
  );

Used to fork and exec a child process.

L<raw|IO::Pty> and C<clone_winsize_from|IO::Pty> only makes sense if
C<conduit> is "pty".

=cut

sub start {
  my $self = shift;
  my $args = ref $_[0] ? $_[0] : {@_};

  $args->{env}   = {%ENV};
  $self->{errno} = 0;
  $args->{program} or die 'program is required input';
  $args->{conduit} ||= 'pipe';
  $args->{program_args} ||= [];
  ref $args->{program_args} eq 'ARRAY' or die 'program_args need to be an array';
  Scalar::Util::weaken($self);
  $self->{delay} = $self->ioloop->timer(0 => sub { $self->_start($args) });
  $self;
}

has '_read_timeout_id';

sub _start {
  local ($?, $!);
  my ($self, $args) = @_;
  my ($stdout_read, $stdout_write);
  my ($stdin_read,  $stdin_write);
  my ($errno,       $pid);

  if ($args->{conduit} eq 'pipe') {
    pipe $stdout_read, $stdout_write or return $self->emit(error => "pipe: $!");
    pipe $stdin_read,  $stdin_write  or return $self->emit(error => "pipe: $!");
    select +(select($stdout_write), $| = 1)[0];
    select +(select($stdin_write),  $| = 1)[0];
  }
  elsif ($args->{conduit} eq 'pty') {
    $stdin_write = $stdout_read = IO::Pty->new;
  }
  else {
    warn "Invalid conduit ($args->{conduit})\n" if DEBUG;
    return $self->emit(error => "Invalid conduit ($args->{conduit})");
  }

  $pid = fork;

  if (!defined $pid) {
    warn "Could not fork $!\n" if DEBUG;
    $self->emit(error => "Couldn't fork ($!)");
  }
  elsif ($pid) {    # parent ===================================================
    warn "[$pid] Child starting ($args->{program} @{$args->{program_args}})\n" if DEBUG;
    $self->{pid}         = $pid;
    $self->{stdout_read} = $stdout_read;
    $self->{stdin_write} = $stdin_write;
    $stdout_read->close_slave if defined $stdout_read and UNIVERSAL::isa($stdout_read, 'IO::Pty');

    Scalar::Util::weaken($self);
    $self->ioloop->reactor->io(
      $stdout_read => sub {
        local ($?, $!);
        my $reactor = shift;

        $self->_read;

        # 5 = Input/output error
        if ($self->{errno} == 5) {
          if (my $handle = delete $self->{stdout_read}) {
            warn "[$pid] Ignoring child after $self->{errno}\n" if DEBUG;
            $reactor->watch($handle, 0, 0);
          }
        }
        elsif ($self->{errno}) {
          warn "[$pid] Child $self->{errno}\n" if DEBUG;
          $self->emit(error => "Read error: $self->{errno}");
        }
      }
    );
    if (my $timeout = $self->read_timeout){
        $self->_read_timeout_id(
            $self->ioloop->timer($timeout => sub {
                $self->emit('read_timeout');
                $self->_read_timeout_id(undef);
            })
        );
    };
    $self->ioloop->reactor->watch($stdout_read, 1, 0);
    $self->_watch_pid($pid);
    $self->_write;
  }
  else {    # child ===========================================================
    if ($args->{conduit} eq 'pty') {
      $stdin_write->make_slave_controlling_terminal;
      $stdin_read = $stdout_write = $stdin_write->slave;
      $stdin_read->set_raw if $args->{raw};
      $stdin_read->clone_winsize_from($args->{clone_winsize_from}) if $args->{clone_winsize_from};
    }

    warn "[$$] Starting $args->{program} @{ $args->{program_args} }\n" if DEBUG;
    CORE::close($stdin_write);
    CORE::close($stdout_read);
    open STDIN,  '<&' . fileno $stdin_read   or exit $!;
    open STDOUT, '>&' . fileno $stdout_write or exit $!;
    open STDERR, '>&' . fileno $stdout_write or exit $!;
    select STDERR;
    $| = 1;
    select STDOUT;
    $| = 1;

    $ENV{$_} = $args->{env}{$_} for keys %{$args->{env}};

    if (ref $args->{program} eq 'CODE') {
      $! = 0;
      @SIG{@SAFE_SIG} = ('DEFAULT') x @SAFE_SIG;
      eval { $args->{program}->(@{$args->{program_args}}); };
      $errno = $@ ? 255 : $!;
      print STDERR $@ if length $@;
    }
    else {
      exec $args->{program}, @{$args->{program_args}};
    }

    eval { POSIX::_exit($errno // $!); };
    exit($errno // $!);
  }
}

=head2 write

  $self = $self->write($chunk);
  $self = $self->write($chunk, $cb);

Used to write data to the child process STDIN. An optional callback will be
called once STDIN is drained.

Example:

  $self->write("some data\n", sub {
    my ($self) = @_;
    $self->close;
  });

=cut

sub write {
  my ($self, $chunk, $cb) = @_;

  $self->once(drain => $cb) if $cb;
  $self->{stdin_buffer} .= $chunk;
  $self->_write if $self->{stdin_write};
  $self;
}

=head2 kill

  $bool = $self->kill;
  $bool = $self->kill(15); # default

Used to signal the child.

=cut

sub kill {
  my $self   = shift;
  my $signal = shift // 15;
  my $pid    = $self->{pid} or return;

  warn "[$pid] Kill $signal\n" if DEBUG;
  kill $signal, $pid;
}

sub _error {
  return if $! == EAGAIN || $! == EINTR || $! == EWOULDBLOCK;
  return $_[0]->kill if $! == ECONNRESET || $! == EPIPE;
  return $_[0]->emit(error => $!)->kill;
}

sub _cleanup {
  my $self = shift;
  my $reactor = $self->{ioloop}{reactor} or return;

  $reactor->remove(delete $self->{stdout_read}) if $self->{stdout_read};
  $reactor->remove(delete $self->{delay})       if $self->{delay};
}


sub _read {
  my $self        = shift;
  my $stdout_read = $self->{stdout_read} or return;
  my $read        = $stdout_read->sysread(my $buffer, CHUNK_SIZE, 0);

  $self->{errno} = $! // 0;

  return unless defined $read;
  return unless $read;
  warn "[$self->{pid}] >>> @{[ESC($buffer)]}\n" if DEBUG;
  if (my $timer = $self->_read_timeout_id){
    $self->ioloop->reactor->again($timer);
  }
  elsif (my $timeout = $self->read_timeout){
      Scalar::Util::weaken($self);
      $self->_read_timeout_id(
          $self->ioloop->timer($timeout => sub {
              $self->emit('read_timeout');
              $self->_read_timeout_id(undef);
          })
      );
  }
  $self->emit(read => $buffer);
}

sub _sigchld {
  my $self = shift;
  my ($exit_value, $signal) = ($_[1] >> 8, $_[1] & 127);
  warn "[$_[0]] Child is dead ($?/$!) $exit_value/$signal\n" if DEBUG;
  $self or return;    # maybe $self has already gone out of scope
  $self->_read;       # flush the rest
  $self->emit(close => $exit_value, $signal);
  $self->_cleanup;
}

sub _watch_pid {
  my ($self, $pid) = @_;
  my $chld = $SIG{CHLD} || '';
  my $reactor = $self->ioloop->reactor;

  # The $chld test is for code, such as Minion::Command::minion::worker
  # where SIGCHLD is set up to DEFAULT for manual waitpid() checks.
  # See https://github.com/kraih/minion/issues/15 for details.
  if ($chld eq 'DEFAULT' or !$reactor->isa('Mojo::Reactor::EV')) {
    $reactor->{fork_watcher} ||= $reactor->recurring(WAIT_PID_INTERVAL, \&_watch_forks);
    Scalar::Util::weaken($reactor->{forks}{$pid} = $self);
  }
  else {
    Scalar::Util::weaken($self);
    $self->{ev_child} = EV::child($pid, 0, sub { _sigchld($self, $pid, $_[0]->rstatus); });
  }
}

sub _watch_forks {
  my $reactor = shift;

  for my $pid (keys %{$reactor->{forks}}) {
    local ($?, $!);
    my $kid = waitpid $pid, WNOHANG or next;
    warn "waitpid $pid, WNOHANG failed: $! ($kid, $?)" unless $kid == $pid;
    _sigchld(delete $reactor->{forks}{$pid}, $pid, $?);
  }
}

sub _write {
  my $self = shift;

  return unless length $self->{stdin_buffer};
  my $stdin_write = $self->{stdin_write};
  my $written     = $stdin_write->syswrite($self->{stdin_buffer});
  return $self->_error unless defined $written;
  my $chunk = substr $self->{stdin_buffer}, 0, $written, '';
  warn "[${ \$self->pid }] <<< @{[ESC($chunk)]}\n" if DEBUG;

  if (length $self->{stdin_buffer}) {

    # This is one ugly hack because it does not seem like IO::Pty play
    # nice with Mojo::Reactor(::EV) ->io(...) and ->watch(...)
    $self->ioloop->timer(0.01 => sub { $self and $self->_write });
  }
  else {
    $self->emit('drain');
  }
}

sub DESTROY { shift->_cleanup }

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
