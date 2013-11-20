use ExtUtils::MakeMaker;
WriteMakefile(
  NAME => 'Mojo::IOLoop::ReadWriteFork',
  ABSTRACT_FROM => 'lib/Mojo/IOLoop/ReadWriteFork.pm',
  VERSION_FROM => 'lib/Mojo/IOLoop/ReadWriteFork.pm',
  AUTHOR => 'Jan Henning Thorsen <jhthorsen@cpan.org>',
  LICENSE => 'perl',
  PREREQ_PM => {
    'Mojolicious' => '4.30',
    'IO::Pty' => '1.10',
  },
  BUILD_REQUIRES => {
    'Test::Memory::Cycle' => '1.04',
    'Test::More' => '0.90',
  },
  META_MERGE => {
    resources => {
      license => 'http://dev.perl.org/licenses/',
      homepage => 'https://metacpan.org/release/Mojo-IOLoop-ReadWriteFork',
      bugtracker => 'https://github.com/jhthorsen/mojo-ioloop-readwritefork/issues',
      repository => 'https://github.com/jhthorsen/mojo-ioloop-readwritefork',
    },
  },
  test => {
    TESTS => 't/*.t',
  },
);
