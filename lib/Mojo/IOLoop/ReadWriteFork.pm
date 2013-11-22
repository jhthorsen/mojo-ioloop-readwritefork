package Mojo::IOLoop::ReadWriteFork;

=head1 NAME

Mojo::IOLoop::ReadWriteFork - Fork a process and read/write from it

=head1 VERSION

0.03

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

  $fork->start(
    program => 'cat',
    program_args => [ '-' ],
    conduit => 'pty',
  );

=head2 In a Mojolicios::Controller

See L<https://github.com/jhthorsen/mojo-ioloop-readwritefork/tree/master/example/tail.pl>.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use IO::Pty;
use Mojo::Util 'url_escape';
use POSIX ':sys_wait_h';
use Scalar::Util ();
use constant CHUNK_SIZE => $ENV{MOJO_CHUNK_SIZE} || 131072;
use constant DEBUG => $ENV{MOJO_READWRITE_FORK_DEBUG} || 0;
use constant WAIT_PID_INTERVAL => $ENV{WAIT_PID_INTERVAL} || 0.01;

our $VERSION = '0.03';

=head1 EVENTS

=head2 close

Emitted when the child process exit.

=head2 error

Emitted when when the there is an issue with creating, writing or reading
from the child process.

=head2 read

Emitted when the child has written a chunk of data to STDOUT or STDERR.

=head1 ATTRIBUTES

=head2 pid

Holds the child process ID.

=cut

has pid => 0;

=head2 reactor

Holds a L<Mojo::Reactor> object. Default is:

  Mojo::IOLoop->singleton->reactor;

=cut

has reactor => sub {
  require Mojo::IOLoop;
  Mojo::IOLoop->singleton->reactor;
};

=head1 METHODS

=head2 start

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

  $args->{env} = { %ENV };
  $args->{program} or die 'program is required input';
  $args->{conduit} ||= 'pipe';
  $args->{program_args} ||= [];
  ref $args->{program_args} eq 'ARRAY' or die 'program_args need to be an array';
  Scalar::Util::weaken($self);
  $self->{delay} = $self->reactor->timer(0 => sub { $self->_start($args) });
  $self;
}

sub _start {
  local($?, $!);
  my($self, $args) = @_;
  my($stdout_read, $stdout_write);
  my($stdin_read, $stdin_write);
  my $pid;

  if($args->{conduit} eq 'pipe') {
    pipe $stdout_read, $stdout_write or return $self->emit_safe(error => "pipe: $!");
    pipe $stdin_read, $stdin_write or return $self->emit_safe(error => "pipe: $!");
    select +(select($stdout_write), $| = 1)[0];
    select +(select($stdin_write), $| = 1)[0];
  }
  elsif($args->{conduit} eq 'pty') {
    $stdin_write = $stdout_read = IO::Pty->new
  }
  else {
    warn "Invalid conduit ($args->{conduit})\n" if DEBUG;
    return $self->emit_safe(error => "Invalid conduit ($args->{conduit})");
  }

  $pid = fork;

  if(!defined $pid) {
    warn "Could not fork $!\n" if DEBUG;
    $self->emit_safe(error => "Couldn't fork ($!)");
  }
  elsif($pid) { # parent ===================================================
    warn "[$pid] Child starting ($args->{program} @{$args->{program_args}})\n" if DEBUG;
    $self->{pid} = $pid;
    $self->{stdin_write} = $stdin_write;
    $self->{stdout_read} = $stdout_read;
    $stdout_read->close_slave if defined $stdout_read and UNIVERSAL::isa($stdout_read, 'IO::Pty');

    Scalar::Util::weaken($self);
    $self->reactor->io($stdout_read => sub {
      $self->{stop} and return;
      local($?, $!);
      my $reactor = shift;

      $self->_read;

      # 5 = Input/output error
      if($! == 5) {
        warn "[$pid] Ignoring child after $!\n" if DEBUG;
        $self->kill;
        $self->{stop}++;
      }
      elsif($!) {
        warn "[$pid] Child $!\n" if DEBUG;
        $self->emit_safe(error => "Read error: $!");
      }
    });
    $self->reactor->watch($stdout_read, 1, 0);
    $self->_setup_recurring_child_alive_check($pid);
  }
  else { # child ===========================================================
    if($args->{conduit} eq 'pty') {
      $stdin_write->make_slave_controlling_terminal;
      $stdin_read = $stdout_write = $stdin_write->slave;
      $stdin_read->set_raw if $args->{raw};
      $stdin_read->clone_winsize_from($args->{clone_winsize_from}) if $args->{clone_winsize_from};
    }

    warn "[$$] Starting $args->{program} @{ $args->{program_args} }\n" if DEBUG;
    close $stdin_write;
    close $stdout_read;
    close STDIN;
    close STDOUT;
    close STDERR;
    open STDIN, '<&' . fileno $stdin_read or die $!;
    open STDOUT, '>&' . fileno $stdout_write or die $!;
    open STDERR, '>&' . fileno $stdout_write or die $!;
    select STDERR; $| = 1;
    select STDOUT; $| = 1;

    $ENV{$_} = $args->{env}{$_} for keys %{ $args->{env} };

    if(ref $args->{program} eq 'CODE') {
      $args->{program}->(@{ $args->{program_args} });
    }
    else {
      exec $args->{program}, @{ $args->{program_args} };
    }
  }
}

sub _setup_recurring_child_alive_check {
  my($self, $pid) = @_;
  my $reactor = $self->reactor;

  $reactor->{forks}{$pid} = $self;
  Scalar::Util::weaken($reactor->{forks}{$pid});
  $reactor->{fork_watcher} ||= $reactor->recurring(WAIT_PID_INTERVAL, sub {
    my $reactor = shift;

    for my $pid (keys %{ $reactor->{forks} }) {
      local($?, $!);
      local $SIG{CHLD} = 'DEFAULT'; # no idea why i need to do this, but it seems like waitpid() below return -1 if not
      my $obj = $reactor->{forks}{$pid} || {};

      if(waitpid($pid, WNOHANG) <= 0) {
        # NOTE: cannot use kill() to check if the process is alive, since
        # the process might be owned by another user.
        -d "/proc/$pid" and next;
      }

      my($exit_value, $signal) = ($? >> 8, $? & 127);
      warn "[$pid] Child is dead $exit_value/$signal\n" if DEBUG;
      delete $reactor->{forks}{$pid} or next; # SUPER DUPER IMPORTANT THAT THIS next; IS NOT BEFORE waitpid; ABOVE!
      $obj->_read; # flush the rest
      $obj->emit_safe(close => $exit_value, $signal);
      $obj->_cleanup;
    }
  });
}

=head2 write

  $self->write($buffer);

Used to write data to the child process.

=cut

sub write {
  my($self, $buffer) = @_;

  $self->{stdin_write} or return;
  warn "[${ \$self->pid }] Write buffer (" .url_escape($buffer) .")\n" if DEBUG;
  print { $self->{stdin_write} } $buffer;
}

=head2 kill

  $bool = $self->kill;
  $bool = $self->kill(15); # default

Used to signal the child.

=cut

sub kill {
  my $self = shift;
  my $signal = shift // 15;
  my $pid = $self->{pid} or return;

  warn "[$pid] Kill $signal\n" if DEBUG;
  kill $signal, $pid;
}


sub _cleanup {
  my $self = shift;
  my $reactor = $self->{reactor} or return;

  $reactor->watch($self->{stdout_read}, 0, 0) if $self->{stdout_read};
  $reactor->remove(delete $self->{stdout_read}) if $self->{stdout_read};
  $reactor->remove(delete $self->{delay}) if $self->{delay};
  $reactor->remove(delete $self->{stdin_write}) if $self->{stdin_write};
}

sub _read {
  my $self = shift;
  my $stdout_read = $self->{stdout_read} or return;
  my $read = $stdout_read->sysread(my $buffer, CHUNK_SIZE, 0);

  return unless defined $read;
  return unless $read;
  warn "[$self->{pid}] Got buffer (" .url_escape($buffer) .")\n" if DEBUG;
  $self->emit_safe(read => $buffer);
}

sub DESTROY { shift->_cleanup }

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
