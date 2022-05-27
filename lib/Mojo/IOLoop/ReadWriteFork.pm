package Mojo::IOLoop::ReadWriteFork;
use Mojo::Base 'Mojo::EventEmitter';

use Errno qw(EAGAIN ECONNRESET EINTR EPIPE EWOULDBLOCK EIO);
use IO::Handle;
use IO::Pty;
use Mojo::Asset::Memory;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::IOLoop::ReadWriteFork::SIGCHLD;
use Mojo::Promise;
use Mojo::Util qw(term_escape);
use Scalar::Util qw(blessed);

use constant CHUNK_SIZE => $ENV{MOJO_CHUNK_SIZE} || 131072;
use constant DEBUG      => $ENV{MOJO_READWRITEFORK_DEBUG} && 1;

our $VERSION = '2.00';

our @SAFE_SIG
  = grep { !m!^(NUM\d+|__[A-Z0-9]+__|ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE|RTMAX|RTMIN|SEGV|SETS)$! } keys %SIG;

my $SIGCHLD = Mojo::IOLoop::ReadWriteFork::SIGCHLD->singleton;

has conduit => sub { +{type => 'pipe'} };
sub pid { shift->{pid} || 0; }
has ioloop => sub { Mojo::IOLoop->singleton }, weak => 1;

sub close {
  my $self = shift;
  my $what = $_[0] eq 'stdout' ? 'stdout_read' : 'stdin_write';    # stdout_read is EXPERIMENTAL
  my $fh   = delete $self->{$what} or return $self;
  $fh->close or $self->emit(error => $!);
  $self;
}

sub run {
  my $args = ref $_[-1] eq 'HASH' ? pop : {};
  my ($self, $program, @program_args) = @_;
  return $self->start({%$args, program => $program, program_args => \@program_args});
}

sub run_and_capture_p {
  my $self    = shift;
  my $asset   = Mojo::Asset::Memory->new(auto_upgrade => 1);
  my $read_cb = $self->on(read => sub { $asset->add_chunk($_[1]) });
  $asset->once(upgrade => sub { $asset = $_[1]; $self->emit(asset => $asset) });
  return $self->emit(asset => $asset)->run_p(@_)->then(sub {$asset})
    ->finally(sub { $self->unsubscribe(read => $read_cb) });
}

sub run_p {
  my $self = shift;
  my $p    = Mojo::Promise->new;
  my @cb;
  push @cb, $self->once(error  => sub { shift->unsubscribe(finish => $cb[1]); $p->reject(@_) });
  push @cb, $self->once(finish => sub { shift->unsubscribe(error  => $cb[0]); $p->resolve(@_) });
  $self->run(@_);
  return $p;
}

sub start {
  my $self    = shift;
  my $args    = ref $_[0] ? $_[0] : {@_};
  my $conduit = $self->conduit;

  $args->{$_} //= $conduit->{$_} for keys %$conduit;
  $args->{conduit} ||= delete $args->{type};
  $args->{env}     ||= {%ENV};
  $self->{errno} = 0;
  $args->{program} or die 'program is required input';
  $self->ioloop->next_tick(sub { $self->_start($args) });
  return $self;
}

sub _start {
  my ($self, $args) = @_;
  my %fh;

  if ($args->{conduit} eq 'pipe') {
    @fh{qw(stdin_read stdin_write)}   = $self->_pipe;
    @fh{qw(stdout_read stdout_write)} = $self->_pipe;
  }
  elsif ($args->{conduit} eq 'pty') {
    $fh{stdin_write} = $fh{stdout_read} = IO::Pty->new;
  }
  elsif ($args->{conduit} eq 'pty3') {
    $args->{$_} //= 1 for qw(stdin stdout stderr);
    @fh{qw(stdin_read stdin_write)}   = $self->_pipe;
    @fh{qw(stdout_read stdout_write)} = $self->_pipe;
    $fh{pty}                          = IO::Pty->new;
  }
  else {
    warn "[RWF] Invalid conduit ($args->{conduit})\n" if DEBUG;
    return $self->emit(error => "Invalid conduit ($args->{conduit})");
  }

  @fh{qw(stderr_read stderr_write)} = $self->_pipe if $args->{stderr};

  $self->emit(before_fork => \%fh);    # LEGACY
  $self->emit(prepare     => \%fh);

  return $self->emit(error => "Couldn't fork ($!)") unless defined($self->{pid} = fork);
  return $self->{pid} ? $self->_start_parent($args, \%fh) : $self->_start_child($args, \%fh);
}

sub _start_child {
  my ($self, $args, $fh) = @_;

  if (my $pty = $fh->{pty}) {
    $pty->make_slave_controlling_terminal;
    $fh->{tty} = $pty->slave;
    $fh->{tty}->set_raw                                         if $args->{raw};
    $fh->{tty}->clone_winsize_from($args->{clone_winsize_from}) if $args->{clone_winsize_from};
  }
  elsif ($pty = blessed $fh->{stdin_write} && $fh->{stdin_write}->isa('IO::Pty') && $fh->{stdin_write}) {
    $pty->make_slave_controlling_terminal;
    $fh->{stdin_read} = $pty->slave;
    $fh->{stdin_read}->set_raw                                         if $args->{raw};
    $fh->{stdin_read}->clone_winsize_from($args->{clone_winsize_from}) if $args->{clone_winsize_from};
    $fh->{stdout_write} = $fh->{stdin_read};
  }

  my $stdout_no = ($args->{stdout} // 1) && fileno($fh->{stdout_write});
  my $stderr_no = ($args->{stderr} // 1) && fileno($fh->{stderr_write} || $fh->{stdout_write});
  open STDIN,  '<&' . fileno($fh->{stdin_read}) or exit $!;
  open STDOUT, '>&' . $stdout_no or exit $! if $stdout_no;
  open STDERR, '>&' . $stderr_no or exit $! if $stderr_no;
  $stdout_no ? STDOUT->autoflush(1) : STDOUT->close;
  $stderr_no ? STDERR->autoflush(1) : STDERR->close;

  $fh->{stdin_write}->close;
  $fh->{stdout_read}->close;
  $fh->{stderr_read}->close if $fh->{stderr_read};

  %ENV = %{$args->{env}};

  my $errno;
  if (ref $args->{program} eq 'CODE') {
    $! = 0;
    @SIG{@SAFE_SIG} = ('DEFAULT') x @SAFE_SIG;
    eval { $args->{program}->(@{$args->{program_args} || []}); };
    $errno = $@ ? 255 : $!;
    print STDERR $@ if length $@;
  }
  else {
    exec $args->{program}, @{$args->{program_args} || []};
  }

  eval { POSIX::_exit($errno // $!); };
  exit($errno // $!);
}

sub _start_parent {
  my ($self, $args, $fh) = @_;

  $self->_d("Forked $args->{program} @{$args->{program_args} || []}") if DEBUG;
  @$self{qw(pty_write stdin_write stdout_read stderr_read)} = @$fh{qw(pty stdin_write stdout_read stderr_read)};
  @$self{qw(wait_eof wait_sigchld)}                         = (1, 1);

  $fh->{stdout_read}->close_slave if blessed $fh->{stdout_read} and $fh->{stdout_read}->isa('IO::Pty');
  $self->_stream(pty    => $fh->{pty})         if $fh->{pty};
  $self->_stream(stderr => $fh->{stderr_read}) if $fh->{stderr_read};
  $self->_stream(stdout => $fh->{stdout_read}) if !$fh->{stderr_read} or $args->{stdout};

  $SIGCHLD->waitpid($self->{pid} => sub { $self->_sigchld(@_) });
  $self->emit('fork');    # LEGACY
  $self->emit('spawn');
  $self->_write;
}

sub write {
  my ($self, $chunk, $conduit, $cb) = @_;
  ($cb, $conduit) = ($conduit, 'stdin') if !$conduit or ref $conduit eq 'CODE';

  my $fh_name = "${conduit}_write";
  push @{$self->{buffer}}, [$fh_name => $chunk];
  $self->once(drain => $cb) if $cb;
  $self->_write             if $self->{$fh_name};
  $self;
}

sub kill {
  my $self   = shift;
  my $signal = shift // 15;
  return undef unless my $pid = $self->{pid};
  $self->_d("kill $signal $pid") if DEBUG;
  return kill $signal, $pid;
}

sub _error {
  return if $! == EAGAIN || $! == EINTR || $! == EWOULDBLOCK;
  return $_[0]->kill if $! == ECONNRESET || $! == EPIPE;
  return $_[0]->emit(error => $!)->kill;
}

sub _d { warn "-- [$_[0]->{pid}] $_[1]\n" }

sub _maybe_terminate {
  my ($self, $pending_event) = @_;
  delete $self->{$pending_event};
  return if $self->{wait_eof} or $self->{wait_sigchld};

  delete $self->{stdin_write};
  delete $self->{stdout_read};

  my @errors;
  for my $cb (@{$self->subscribers('close')}, @{$self->subscribers('finish')}) {
    push @errors, $@ unless eval { $self->$cb(@$self{qw(exit_value signal)}); 1 };
  }

  $self->emit(error => $_) for @errors;
}

sub _pipe {
  my $self = shift;
  pipe my $read, my $write or return $self->emit(error => "pipe: $!");
  $write->autoflush(1);
  return $read, $write;
}

sub _sigchld {
  my ($self, $status, $pid) = @_;
  my ($exit_value, $signal) = ($status >> 8, $status & 127);
  $self->_d("Exit exit_value=$exit_value, signal=$signal") if DEBUG;
  @$self{qw(exit_value signal)} = ($exit_value, $signal);
  $self->_maybe_terminate('wait_sigchld');
}

sub _stream {
  my ($self, $conduit, $handle) = @_;
  my $stream = Mojo::IOLoop::Stream->new($handle)->timeout(0);

  my $event_name = $self->{stderr_read} ? $conduit : 'read';
  my $read_cb    = sub {
    $self->_d(sprintf ">>> RWF:%s ($event_name)\n%s", uc $conduit, term_escape $_[1]) if DEBUG;
    $self->emit($event_name => $_[1]);
  };

  $stream->on(error => sub { $! != EIO && $self->emit(error => "Read error: $_[1]") });
  $stream->on(close => sub { $self->_maybe_terminate('wait_eof') });
  $stream->on(read  => $read_cb);
  $self->ioloop->stream($stream);
}

sub _write {
  my $self = shift;
  return unless my $buffer = delete $self->{buffer};

  my @again;
  for my $i (@$buffer) {
    my $fh      = $self->{$i->[0]};
    my $written = $fh->syswrite($i->[1]);
    $self->_d(sprintf "<<< RWF:%s\n%s", uc($i->[0]) =~ s/_WRITE$//r, term_escape $i->[1]) if DEBUG;
    return $self->_error unless defined $written;

    substr $i->[1], 0, $written, '';
    push @again, $i if length $i->[1];
  }

  if (@again) {

    # This is one ugly hack because it does not seem like IO::Pty play
    # nice with Mojo::Reactor(::EV) ->io(...) and ->watch(...)
    $self->{buffer} = \@again;
    $self->ioloop->timer(0.01 => sub { $self and $self->_write });
  }
  else {
    $self->emit('drain');
  }
}

1;

=encoding utf8

=head1 NAME

Mojo::IOLoop::ReadWriteFork - Fork a process and read/write from it

=head1 VERSION

2.00

=head1 SYNOPSIS

  my $fork = Mojo::IOLoop::ReadWriteFork->new;

  # Emitted if something terrible happens
  $fork->on(error => sub { my ($fork, $error) = @_; warn $error; });

  # Emitted when the child completes
  $fork->on(finish => sub { my ($fork, $exit_value, $signal) = @_; Mojo::IOLoop->stop; });

  # Emitted when the child prints to STDOUT or STDERR
  $fork->on(read => sub {
    my ($fork, $buf) = @_;
    print qq(Child process sent us "$buf");
  });

  # Need to set "conduit" for bash, ssh, and other programs that require a pty
  $fork->conduit({type => 'pty'});

  # Start the application
  $fork->run('bash', -c => q(echo $YIKES foo bar baz));

  # Using promises
  $fork->on(read => sub { ... });
  $fork->run_p('bash', -c => q(echo $YIKES foo bar baz))->wait;

See also
L<https://github.com/jhthorsen/mojo-ioloop-readwritefork/tree/master/examples/tail.pl>
for an example usage from a L<Mojo::Controller>.

=head1 DESCRIPTION

L<Mojo::IOLoop::ReadWriteFork> enable you to fork a child process and L</read>
and L</write> data to. You can also L<send signals|/kill> to the child and see
when the process ends. The child process can be an external program (bash,
telnet, ffmpeg, ...) or a CODE block running perl.

=head2 Conduits

L<Mojo::IOLoop::ReadWriteFork> can write to STDIN or a L<IO::Pty> object, and
read from STDOUT or STDERR, depending on the "type" given to L</conduit>.

Here is an overview of the different conduits:

=over 2

=item * pipe

The "pipe" type will create a STDIN and a STDOUT conduit using a plain pipe.
Passing in C<stderr> will also create a seperate pipe for STDERR.

  $fork->conduit({type => 'pipe'});
  $fork->conduit({type => 'pipe', stderr => 1});
  $fork->write('some data');        # write to STDIN
  $fork->on(read   => sub { ... }); # STDOUT and STDERR
  $fork->on(stdout => sub { ... }); # STDOUT
  $fork->on(stderr => sub { ... }); # STDERR

This is useful if you want to run a program like "cat" that simply read/write
from STDIN, STDERR or STDOUT.

=item * pty

The "pty" type will create a STDIN and a STDOUT conduit using L<IO::Pty>.
Passing in "stderr" will also create a seperate pipe for STDERR.

  $fork->conduit({type => 'pty'});
  $fork->conduit({type => 'pty', stderr => 1});
  $fork->write('some data');        # write to STDIN
  $fork->on(read   => sub { ... }); # STDOUT and STDERR
  $fork->on(stdout => sub { ... }); # STDOUT
  $fork->on(stderr => sub { ... }); # STDERR

The difference between "pipe" and "pty" is that a L<IO::Pty> object will be
used for STDIN and STDOUT instead of a plain pipe. In addition, it is possible
to pass in C<clone_winsize_from> and C<raw>:

  $fork->conduit({type => 'pty', clone_winsize_from => \*STDOUT, raw => 1});

This is useful if you want to run "bash" or another program that requires a
pseudo terminal.

=item * pty3

The "pty3" type will create a STDIN, a STDOUT, a STDERR and a PTY conduit.

  $fork->conduit({type => 'pty3'});
  $fork->write('some data', 'pty');   # write to PTY
  $fork->write('some data', 'stdin'); # write to STDIN
  $fork->on(pty    => sub { ... });   # PTY
  $fork->on(stdout => sub { ... });   # STDOUT
  $fork->on(stderr => sub { ... });   # STDERR

The difference between "pty" and "pty3" is that there will be a different
L</read> event for bytes coming from the pseudo TTY and it is also possible to
write to the PTY instead of STDIN. This type also supports "clone_winsize_from"
and "raw".

  $fork->conduit({type => 'pty3', clone_winsize_from => \*STDOUT, raw => 1});

This is useful if you want to run "ssh" or another program that sends password
prompts (or other output) on the PTY channel. See
L<https://github.com/jhthorsen/mojo-ioloop-readwritefork/tree/master/examples/sshpass>
for an example application.

=back

=head1 EVENTS

=head2 asset

  $fork->on(asset => sub { my ($fork, $asset) = @_; });

Emitted at least once when calling L</run_and_capture_p>. C<$asset> can be
either a L<Mojo::Asset::Memory> or L<Mojo::Asset::File> object.

  $fork->on(asset => sub {
    my ($fork, $asset) = @_;
    # $asset->auto_upgrade(1) is set by default
    $asset->max_memory_size(1) if $asset->can('max_memory_size');
  });

=head2 drain

  $fork->on(drain => sub { my ($fork) = @_; });

Emitted when the buffer has been written to the sub process.

=head2 error

  $fork->on(error => sub { my ($fork, $str) = @_; });

Emitted when when the there is an issue with creating, writing or reading
from the child process.

=head2 finish

  $fork->on(finish => sub { my ($fork, $exit_value, $signal) = @_; });

Emitted when the child process exit.

=head2 pty

  $fork->on(pty => sub { my ($fork, $buf) = @_; });

Emitted when the child has written a chunk of data to a pty and L</conduit> has
"type" set to "pty3".

=head2 prepare

  $fork->on(prepare => sub { my ($fork, $fh) = @_; });

Emitted right before the child process is forked. C<$fh> can contain the
example hash below or a subset:

  $fh = {
    pty          => $io_pty_object,
    stderr_read  => $pipe_fh_w_or_pty_object,
    stderr_read  => $stderr_fh_r,
    stdin_read   => $pipe_fh_r,
    stdin_write  => $pipe_fh_r_or_pty_object,
    stdin_write  => $stderr_fh_w,
    stdout_read  => $pipe_fh_w_or_pty_object,
    stdout_read  => $stderr_fh_r,
    stdout_write => $pipe_fh_w,
  };

=head2 read

  $fork->on(read => sub { my ($fork, $buf) = @_; });

Emitted when the child has written a chunk of data to STDOUT or STDERR, and
neither "stderr" nor "stdout" is set in the L</conduit>.

=head2 spawn

  $fork->on(spawn => sub { my ($fork) = @_; });

Emitted after C<fork()> has been called. Note that the child process might not yet have
been started. The order of things is impossible to say, but it's something like this:

            .------.
            | fork |
            '------'
               |
           ___/ \_______________
          |                     |
          | (parent)            | (child)
    .--------------.            |
    | emit "spawn" |   .--------------------.
    '--------------'   | set up filehandles |
                       '--------------------'
                                |
                         .---------------.
                         | exec $program |
                         '---------------'

See also L</pid> for example usage of this event.

=head2 stderr

  $fork->on(stderr => sub { my ($fork, $buf) = @_; });

Emitted when the child has written a chunk of data to STDERR and L</conduit>
has the "stderr" key set to a true value or "type" is set to "pty3".

=head2 stdout

  $fork->on(stdout => sub { my ($fork, $buf) = @_; });

Emitted when the child has written a chunk of data to STDOUT and L</conduit>
has the "stdout" key set to a true value or "type" is set to "pty3".

=head1 ATTRIBUTES

=head2 conduit

  $hash = $fork->conduit;
  $fork = $fork->conduit(\%options);

Used to set the conduit options. Possible values are:

=over 2

=item * clone_winsize_from

See L<IO::Pty/clone_winsize_from>. This only makes sense if L</conduit> is set
to "pty". This can also be specified by using the L</conduit> attribute.

=item * raw

See L<IO::Pty/set_raw>. This only makes sense if L</conduit> is set to "pty".
This can also be specified by using the L</conduit> attribute.

=item * stderr

This will make L<Mojo::IOLoop::ReadWriteFork> emit "stderr" events, instead of
"read" events. Setting this to "0" will close STDERR in the child.

=item * stdout

This will make L<Mojo::IOLoop::ReadWriteFork> emit "stdout" events, instead of
"read" events. Setting this to "0" will close STDOUT in the child.

=item * type

"type" can be either "pipe", "pty" or "pty3". Default value is "pipe".

See also L</Conduits>

=back

=head2 ioloop

  $ioloop = $fork->ioloop;
  $fork = $fork->ioloop(Mojo::IOLoop->singleton);

Holds a L<Mojo::IOLoop> object.

=head2 pid

  $int = $fork->pid;

Holds the child process ID. Note that L</start> will start the process after
the IO loop is started. This means that the code below will not work:

  $fork->run("bash", -c => q(echo $YIKES foo bar baz));
  warn $fork->pid; # pid() is not yet set

This will work though:

  $fork->on(fork => sub { my $fork = shift; warn $fork->pid });
  $fork->run("bash", -c => q(echo $YIKES foo bar baz));

=head1 METHODS

=head2 close

  $fork = $fork->close('stdin');

Close STDIN stream to the child process immediately.

=head2 run

  $fork = $fork->run($program, @program_args);
  $fork = $fork->run(\&Some::Perl::function, @function_args);

Simpler version of L</start>. Can either start an application or run a perl
function.

=head2 run_and_capture_p

  $p = $fork->run_and_capture_p(...)->then(sub { my $asset = shift });

L</run_and_capture_p> takes the same arguments as L</run_p>, but the
fullfillment callback will receive a L<Mojo::Asset> object that holds the
output from the command.

See also the L</asset> event.

=head2 run_p

  $p = $fork->run_p($program, @program_args);
  $p = $fork->run_p(\&Some::Perl::function, @function_args);

Promise based version of L</run>. The L<Mojo::Promise> will be resolved on
L</finish> and rejected on L</error>.

=head2 start

  $fork = $fork->start(\%args);

Used to fork and exec a child process. C<%args> can have:

=over 2

=item * program

Either an application or a CODE ref.

=item * program_args

A list of options passed on to L</program> or as input to the CODE ref.

Note that this module will start L</program> with this code:

  exec $program, @$program_args;

This means that the code is subject for
L<shell injection|https://en.wikipedia.org/wiki/Code_injection#Shell_injection>
unless invoked with more than one argument. This is considered a feature, but
something you should be avare of. See also L<perlfunc/exec> for more details.

=item * env

Passing in C<env> will override the default set of environment variables,
stored in C<%ENV>.

=back

=head2 write

  $fork = $fork->write($chunk);
  $fork = $fork->write($chunk, $cb);
  $fork = $fork->write($chunk, $conduit, $cb);

Used to write data to the child process C<$conduit>. An optional callback will
be called once the C<$chunk> is written.

Example:

  $fork->write("some data\n", sub { shift->close });

C<$conduit> defaults to "stdin", but can also be "pty" if the L</pty3> conduit
type is specified.

=head2 kill

  $bool = $fork->kill;
  $bool = $fork->kill(15); # default

Used to signal the child.

=head1 SEE ALSO

L<Mojo::IOLoop::ForkCall>.

L<https://github.com/jhthorsen/mojo-ioloop-readwritefork/tree/master/examples/tail.pl>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013-2016, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut
