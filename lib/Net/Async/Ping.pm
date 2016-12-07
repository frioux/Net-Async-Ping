package Net::Async::Ping;

use strict;
use warnings;

# ABSTRACT: asyncronously check remote host for reachability

use Module::Runtime 'use_module';
use namespace::clean;

my %method_map = (
   tcp  => 'TCP',
   icmp => 'ICMP',
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

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::Ping;

 my $p = Net::Async::Ping->new;
 my $loop = IO::Async::Loop->new;

 my $future = $p->ping($loop, 'myrealbox.com');

 $future->on_done(sub {
    say "good job the host is running!"
 });
 $future->on_fail(sub {
    say "the host is down!!!";
 });

=head1 DESCRIPTION

This module's goal is to eventually be able to test remote hosts
on a network with a number of different socket types and protocols.
Currently it only supports TCP, but UDP, ICMP, and Syn are planned.
If you need one of those feel free to work up a patch.

This module was originally forked off of L<Net::Ping>, so it shares B<some> of it's interface, but only where it makes sense.

=method new

 my $p = Net::Async::Ping->new(
   $proto, $def_timeout, $bytes, $device, $tos, $ttl,
 );

All arguments to new are optional, but if you want to provide one in the
middle you must provide all the ones to the left of it.  The default (and
currently only) protocol is C<tcp>.  The default timeout is 5 seconds.
bytes does not apply to C<tcp>.  C<device> is what host to bind the
socket to, ie what to ping B<from>.  Neither tos nor ttl apply to C<tcp>
currently.

Alternately, you can use a new constructor:

 my $p = Net::Async::Ping->new(
   tcp => {
      default_timeout => 10,
      bind            => '192.168.1.1',
      port_number     => 80,
      service_check   => 1,
   },
 );

All of the above arguments are optional.  Service check, which is off
by default, will cause ping to fail if the host refuses connection to
the selected port (7 by default.)  Bind is the same as device from before.
=method ping

 my $future = $p->ping($loop, $host, $timeout);

Returns a L<Future> representing the ping.  C<loop> should be an L<IO::Async::Loop>, host is the host, and timeout is optional and defaults to the default set above.

The future will always terminate with the hi resolution time it took to
check for liveness.  The success or failure is checked by introspecting
the future itself.

