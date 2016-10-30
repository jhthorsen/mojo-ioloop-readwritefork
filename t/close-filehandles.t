use Mojo::Base -strict;
use Mojo::IOLoop::ReadWriteFork;
use Test::Mojo;
use Test::More;

plan skip_all => 'uptime is missing' unless grep { -x "$_/uptime" } split /:/, $ENV{PATH};

use Mojolicious::Lite;

get '/' => sub {
  my $c    = shift->render_later;
  my $fork = Mojo::IOLoop::ReadWriteFork->new;
  my $out  = '';

  $c->stash(fork => $fork);
  $fork->on(
    close => sub {
      my ($fork, $exit_value, $signal) = @_;
      $c->render(json => {output => $out, exit_value => $exit_value});
      delete $c->stash->{fork};    # <--- prevent leaks
    }
  );

  $fork->on(
    read => sub {
      my ($fork, $buffer) = @_;
      $out .= $buffer;
    }
  );

  $fork->run('uptime');
};

my $t = Test::Mojo->new;

$t->get_ok('/')->status_is(200);

my $before = count_fh();
is count_fh(), $before, 'first run';

$t->get_ok('/')->status_is(200);
is count_fh(), $before, 'second run';

$t->get_ok('/')->status_is(200);
is count_fh(), $before, 'third run';

done_testing;

sub count_fh {
  use Scalar::Util 'openhandle';
  return int grep {
    open my $fh, '<&=', $_;
    openhandle($fh);
  } 0 .. 1023;
}
