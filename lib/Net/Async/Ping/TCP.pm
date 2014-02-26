package Net::Async::Ping::TCP;

use Moo;
use warnings NONFATAL => 'all';

use Future;
use POSIX 'ECONNREFUSED';
use Time::HiRes;

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

sub ping {
   my ($self, $loop, $host, $timeout) = @_;
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
      sub { Future->wrap(1, Time::HiRes::tv_interval($t0)) },
      sub {
         my ($human, $layer) = @_;
         my $ex    = pop;
         if ($layer eq 'connect') {
            return Future->wrap(1, Time::HiRes::tv_interval($t0))
               if !$service_check && $ex == ECONNREFUSED;
         }
         Future->wrap(0, Time::HiRes::tv_interval($t0))
      },
   )
}

1;
