package Net::Async::Ping::TCP;

use Moo;
use warnings NONFATAL => 'all';

use Carp qw/croak/;
use Future;
use POSIX 'ECONNREFUSED';
use Time::HiRes;

extends 'IO::Async::Notifier';

use namespace::clean;

has default_timeout => (
   is => 'ro',
   default => 5,
);

has service_check => ( is => 'rw' );

has bind => ( is => 'rw' );

has port_number => (
   is => 'rw',
   default => 7,
);

# Overrides method in IO::Async::Notifier to allow specific options in this class
sub configure_unknown
{   my $self = shift;
    my %params = @_;
    delete $params{$_} foreach qw/default_timeout service_check bind/;
    return unless keys %params;
    my $class = ref $self;
    croak "Unrecognised configuration keys for $class - " . join( " ", keys %params );

}

sub ping {
    my $self = shift;
    # Maintain compat with old API
    my $legacy = ref $_[0] eq 'IO::Async::Loop::Poll';
    my $loop   = $legacy ? shift : $self->loop;

   my ($host, $timeout) = @_;
   $timeout ||= $self->default_timeout;

   my $service_check = $self->service_check;

   my $t0 = [Time::HiRes::gettimeofday];

   return Future->wait_any(
      $loop->connect(
         host     => $host,
         service  => $self->port_number,
         socktype => 'stream',
         ($self->bind ? (
            local_host => $self->bind,
         ) : ()),
      ),
      $loop->timeout_future(after => $timeout)
   )
   ->then(
      sub { Future->done(Time::HiRes::tv_interval($t0)) },
      sub {
         my ($human, $layer) = @_;
         my $ex    = pop;
         if ($layer && $layer eq 'connect') {
            return Future->done(Time::HiRes::tv_interval($t0))
               if !$service_check && $ex == ECONNREFUSED;
         }
         Future->fail(Time::HiRes::tv_interval($t0))
      },
   )
}

1;
