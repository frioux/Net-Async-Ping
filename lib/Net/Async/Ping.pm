package Net::Async::Ping;

use Module::Runtime 'use_module';
use namespace::clean;

my %method_map = (
   tcp => 'TCP',
);

sub new {
   my $class = shift;

   my $method = shift || 'tcp';

   die "The '$method' proto of Net::Ping not ported yet"
      unless $method_map{$method};

   my @args;
   if (ref $_[0]) {
      @args = ($_[0])
   } else {
      my ($default_timeout, $bytes, $device, $tos, $ttl) = @_;

      @args = (
         (@_ >= 1 ? (default_timeout => $default_timeout) : ()),
         (@_ >= 2 ? (bytes => $bytes) : ()),
         (@_ >= 3 ? (device => $device) : ()),
         (@_ >= 4 ? (tos => $tos) : ()),
         (@_ >= 5 ? (ttl => $ttl) : ()),
      )
   }
   use_module('Net::Async::Ping::' . $method_map{$method})->new(@args)
}

1;

