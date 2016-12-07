use strict;
use warnings;

use Test::More tests => 32;

use Net::Async::Ping;
use IO::Async::Loop;

use Test::Fatal;

foreach my $type (qw/tcp icmp icmp_ps/) # Normal ICMP and ICMP with ping socket
{
    SKIP: {

        # Horribly hacky. We guess what might be an unreachable address, and
        # see whether it actually is with a call to the external ping command.
        # We do this now, so we know how many tests we need to skip.
        my $unreach         = '192.168.0.197';
        my $return          = qx(ping -c 1 $unreach);
        my $has_unreachable = $return =~ /Destination Host Unreachable/;

        my %options;
        if ($type eq 'icmp') {
            my $skip = $has_unreachable ? 12 : 10;
            skip "Not running as root: skipping ICMP raw socket pings", $skip if $>;
            %options = (use_ping_socket => 0);
        }
        elsif ($type eq 'icmp_ps') {
            # Tricky: try and see if this user can use ping sockets
            my $skip = 10;
            skip "Not Linux: skipping ping socket tests", $skip unless $^O =~ /linux/;
            my $proc = '/proc/sys/net/ipv4/ping_group_range';
            open(my $fh, '<', $proc)
                or skip "Cannot open $proc ($!): skipping ping socket tests", $skip;
            my $groups = <$fh>;
            defined $groups
                or skip "/proc/sys/net/ipv4/ping_group_range is empty: skipping ping socket tests", $skip;
            $groups =~ /^([0-9]+)\h+([0-9]+)$/
                or skip "Cannot parse /proc/sys/net/ipv4/ping_group_range: skipping ping socket tests", $skip;
            $1 <= $) && $2 >= $)
                or skip "Current user's group is not allowed to use ping sockets: skipping ping socket tests", $skip;
            %options = (use_ping_socket => 1); # default
        }

        # Test old and new API (with and without $loop)
        foreach my $legacy (0..1)
        {
            my $t = $type eq 'icmp_ps' ? 'icmp' : $type;
            my $p = Net::Async::Ping->new($t => { default_timeout => 1, %options });
            my $l = IO::Async::Loop->new;
            $l->add($p) if !$legacy;

            my @params = $legacy ? ($l, 'localhost') : ('localhost');
            $p->ping(@params)
               ->then(sub {
                  pass "type: $type, legacy: $legacy, pinged localhost!";
                  note("success future: @_");
                  Future->done
               })->else(sub {
                  fail "type: $type, legacy: $legacy, pinged localhost!";
                  note("failure future: @_");
                  Future->fail('failed to ping localhost!')
               })->get;

            # http://en.wikipedia.org/wiki/Reserved_IP_addresses
            @params = $legacy ? ($l, '192.0.2.0') : ('192.0.2.0');
            my $f = $p->ping(@params)
               ->then(sub {
                  fail qq(type: $type, legacy: $legacy, couldn't reach 192.0.2.0);
                  note("success future: @_");
                  Future->done
               })->else(sub {
                  pass qq(type: $type, legacy: $legacy, couldn't reach 192.0.2.0);
                  note("failure future: @_");
                  Future->fail('expected failure')
               });
            like exception { $f->get }, qr/expected failure/, 'expected failure';

            if ($type eq 'icmp') # Unreachable replies do not seem to work with ping sockets
            {
                SKIP: {
                    skip "$unreach is not unreachable: skipping unreachable IP address tests", 2 
                        unless $has_unreachable;
                    @params = $legacy ? ($l, $unreach) : ($unreach);
                    my $f = $p->ping(@params, 5); # Longer timeout needed for unreachable packets
                    like exception { $f->get }, qr/ICMP Unreachable/, "type: $type, legacy: $legacy, expected failure";
                }
            }

            # RFC6761, invalid domain to check resolver failure
            @params = $legacy ? ($l, 'nothing.invalid') : ('nothing.invalid');
            $f = $p->ping(@params)
               ->then(sub {
                  fail qq(type: $type, legacy: $legacy, couldn't reach nothing.invalid);
                  note("success future: @_");
                  Future->done
               })->else(sub {
                  pass qq(type: $type, legacy: $legacy, couldn't reach nothing.invalid);
                  note("failure future: @_");
                  Future->fail('expected failure')
               });

            like exception { $f->get }, qr/expected failure/, "type: $type, legacy: $legacy, expected failure";
        }
    }
}
