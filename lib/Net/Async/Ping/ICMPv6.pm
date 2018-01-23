package Net::Async::Ping::ICMPv6;

use Moo;
use warnings NONFATAL => 'all';

use Future;
use Time::HiRes;
use Carp qw( croak );
use Net::Ping qw();
use IO::Socket;
use IO::Async::Socket;
use Scalar::Util qw( blessed );
use Socket qw(
    SOCK_RAW SOCK_DGRAM AF_INET6 IPPROTO_ICMPV6 NI_NUMERICHOST NIx_NOSERV
    inet_pton pack_sockaddr_in6 unpack_sockaddr_in6 getnameinfo inet_ntop
);
use Net::Frame::Layer::IPv6 qw(:consts);

use constant ICMPv6_UNREACHABLE     => 1;
use constant ICMPv6_TIME_EXCEEDED   => 3;
use constant ICMPv6_ECHO            => 128;
use constant ICMPv6_ECHOREPLY       => 129;
use constant ICMP_STRUCT            => "C2 n3 A"; # Structure of a minimal ICMP
                                                  # and ICMPv6 packet
use constant SUBCODE                => 0; # No ICMP subcode for ECHO and ECHOREPLY
use constant ICMPv6_FLAGS           => 0; # No special flags for send or recv

extends 'IO::Async::Notifier';

use namespace::clean;

has default_timeout => (
   is => 'ro',
   default => 5,
);

has bind => ( is => 'rw' );

has _is_raw_socket_setup_done => (
    is => 'rw',
    default => 0,
);

has _raw_socket => (
    is => 'lazy',
);

sub _build__raw_socket {
    my $self = shift;

    my $fh = IO::Socket->new;
    $fh->socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6) ||
        croak("Unable to create raw socket ($!). Are you running as root?"
          ." If not, and your system supports ping sockets, try setting"
          ." /proc/sys/net/ipv4/ping_group_range");
    #TODO: IPv6 sockets support filtering, should we?
    #$fh->setsockopt($proto_num, 1, NF_ICMPv6_TYPE_ECHO_REQUEST);
    #print "SOCKOPT: '" . $fh->getsockopt($proto_num, 1) . "'\n";

    if ( $self->bind ) {
        $fh->bind(pack_sockaddr_in6(0, inet_pton(AF_INET6, $self->bind)))
            or croak "Failed to bind to " . $self->bind;
    }

    my $on_recv = $self->_capture_weakself(sub {
        my $self = shift or return; # weakref, may have disappeared
        my ( $ioasock, $recv_msg, $from_saddr ) = @_;

        my $from_data = $self->_parse_icmpv6_packet($recv_msg, $from_saddr);
        return
            unless defined $from_data && ref $from_data eq 'HASH';

        # ignore received packets which are not a response to one of
        # our echo requests
        my $f = $self->_raw_socket_queue->{$from_data->{ip}};
        return
            unless defined $f
                && $from_data->{id} == $self->_pid
                && $from_data->{seq} == $self->seq;

        if ($from_data->{type} == ICMPv6_ECHOREPLY) {
            $f->done;
        }
        elsif ($from_data->{type} == ICMPv6_UNREACHABLE) {
            $f->fail('ICMP Unreachable');
        }
        elsif ($from_data->{type} == ICMPv6_TIME_EXCEEDED) {
            $f->fail('ICMP Timeout');
        }
    });

    my $socket = IO::Async::Socket->new(
        handle => $fh,
        on_recv_error => sub {
            my ( $self, $errno ) = @_;
            warn "Receive error: $errno";
        },
        on_recv => $on_recv,
    );

    return $socket;
}

has _raw_socket_queue => (
    is => 'rw',
    default => sub { {} },
);

has _pid => (
    is => 'lazy',
);

sub _build__pid
{   my $self = shift;
    $$ & 0xffff;
}

has seq => (
    is      => 'ro',
    default => 1,
);

# Whether to try and use ping sockets. This option used in tests
# to force normal ping to be used
has use_ping_socket => (
    is      => 'ro',
    default => 1,
);

sub _parse_icmpv6_packet {
    my ( $self, $recv_msg, $from_saddr ) = @_;
    # IPv6 raw sockets never return the IPv6 header so they are identical to
    # what a ping socket returns
    my $offset = 0;

    my $from_ip  = -1;
    my $from_pid = -1;
    my $from_seq = -1;

    my ($from_type, $from_subcode) =
        unpack("C2", substr($recv_msg, $offset, 2));

    # extract source ip, identifier and sequence depending on
    # packet type
    if ($from_type == ICMPv6_ECHOREPLY) {
        (my $err, $from_ip) = getnameinfo($from_saddr,
            NI_NUMERICHOST, NIx_NOSERV);
        croak "getnameinfo: $err"
            if $err;
        ($from_pid, $from_seq) =
            unpack("n2", substr($recv_msg, $offset + 4, 4))
            if length $recv_msg >= $offset + 8;
    }
    # an ICMPv6 error message includes the original header
    # IPv6 + ICMPv6 + ICMPv6::Echo
    elsif ($from_type == ICMPv6_UNREACHABLE) {
        my $ipv6 = Net::Frame::Layer::IPv6->new(
            # 8 byte is the length of the ICMPv6 destination
            # unreachable header
            raw => substr($recv_msg, $offset + 8)
        );
        # skip if contained packet isn't an ICMPv6 packet
        return
            if $ipv6->protocol != NF_IPv6_PROTOCOL_ICMPv6;

        # skip if contained packet isn't an icmp echo request packet
        my ($to_type, $to_subcode) =
            unpack("C2", substr($ipv6->payload, 0, 2));
        return
            if $to_type != ICMPv6_ECHO;

        $from_ip = $ipv6->dst;
        ($from_pid, $from_seq) =
            unpack("n2", substr($ipv6->payload, 4, 4));
    }
    # no packet we care about, raw sockets receive broadcasts,
    # multicasts etc, ours is only limited to IPv6 containing ICMPv6
    else {
        return;
    }

    return {
        type => $from_type,
        ip => $from_ip,
        id => $from_pid,
        seq => $from_seq,
    };
}

# Overrides method in IO::Async::Notifier to allow specific options in this class
sub configure_unknown
{   my $self = shift;
    my %params = @_;
    delete $params{$_}
        for qw( default_timeout bind seq use_ping_socket );
    return
        unless keys %params;
    my $class = ref $self;
    croak "Unrecognised configuration keys for $class - " .
        join( " ", keys %params );

}

sub ping {
    my $self = shift;
    # Maintain compat with old API
    my $legacy = blessed $_[0] and $_[0]->isa('IO::Async::Loop');
    my $loop   = $legacy ? shift : $self->loop;

    my ($host, $timeout) = @_;
    $timeout //= $self->default_timeout;

    my $t0 = [Time::HiRes::gettimeofday];

    $loop->resolver->getaddrinfo(
       host     => $host,
       protocol => IPPROTO_ICMPV6,
       family   => AF_INET6,
    )->then( sub {
        my $saddr  = $_[0]->{addr};
        my ($err, $dst_ip) = getnameinfo($saddr, NI_NUMERICHOST, NIx_NOSERV);
        croak "getnameinfo: $err"
            if $err;
        my $f = $loop->new_future;

        # Let's try a ping socket (unprivileged ping) first. See
        # https://github.com/torvalds/linux/commit/6d0bfe22611602f36617bc7aa2ffa1bbb2f54c67
        my ($socket, $ping_socket, $ident);
        if ( $self->use_ping_socket) {
            my $ping_fh = IO::Socket->new;
            if ($ping_fh->socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)) {
                ($ident) = unpack_sockaddr_in6 getsockname($ping_fh);

                if ($self->bind) {
                    $ping_fh->bind(pack_sockaddr_in6(0,
                        inet_pton(AF_INET6, $self->bind)))
                    or croak "Failed to bind to ".$self->bind;
                }

                my $on_recv = $self->_capture_weakself(
                    sub {
                        my $self = shift or return; # weakref, may have disappeared
                        my ( undef, $recv_msg, $from_saddr ) = @_;

                        my $from_data = $self->_parse_icmpv6_packet($recv_msg,
                            $from_saddr);

                        # ignore received packets which are not a response to one of
                        # our echo requests
                        return
                            unless $from_data->{ip} eq $dst_ip
                                && $from_data->{seq} == $self->seq;

                        if ($from_data->{type} == ICMPv6_ECHOREPLY) {
                            $f->done;
                        }
                        elsif ($from_data->{type} == ICMPv6_UNREACHABLE) {
                            $f->fail('ICMP Unreachable');
                        }
                        elsif ($from_data->{type} == ICMPv6_TIME_EXCEEDED) {
                            $f->fail('ICMP Timeout');
                        }
                    },
                );

                $socket = IO::Async::Socket->new(
                    handle => $ping_fh,
                    on_recv_error => sub {
                        my ( $self, $errno ) = @_;
                        $f->fail('Receive error');
                    },
                    on_recv => $on_recv,
                );
                $legacy ? $loop->add($socket) : $self->add_child($socket);
                $ping_socket = 1;
            }
        }

        # fallback to raw socket or if no ping socket was requested
        if (not defined $socket) {
            $socket = $self->_raw_socket;
            $ident = $self->_pid;
            if (!$self->_is_raw_socket_setup_done) {
                $legacy ? $loop->add($socket) : $self->add_child($socket);
                $self->_is_raw_socket_setup_done(1);
            }
        }

        # remember raw socket requests
        if (!$ping_socket) {
            if (exists $self->_raw_socket_queue->{$dst_ip}) {
                warn "$dst_ip already in raw queue, $host probably duplicate\n";
            }
            $self->_raw_socket_queue->{$dst_ip} = $f;
        }
        $socket->send( $self->_msg($ident), ICMPv6_FLAGS, $saddr );

        Future->wait_any(
           $f,
           $loop->timeout_future(after => $timeout)
        )
        ->then( sub {
            Future->done(Time::HiRes::tv_interval($t0));
        })
        ->followed_by( sub {
            my $f = shift;

            if ($ping_socket) {
                $socket->remove_from_parent;
            }
            else {
                # remove from raw socket queue
                delete $self->_raw_socket_queue->{$dst_ip};
            }

            return $f;
        })
    });
}

sub _msg {
    my ($self, $ident) = @_;

    # data_size to be implemented later
    my $data_size = 0;
    my $data      = '';
    my $checksum  = 0;
    my $msg = pack(ICMP_STRUCT . $data_size, ICMPv6_ECHO, SUBCODE,
        $checksum, $ident, $self->seq, $data);
    $checksum = Net::Ping->checksum($msg);
    $msg = pack(ICMP_STRUCT . $data_size, ICMPv6_ECHO, SUBCODE,
        $checksum, $ident, $self->seq, $data);
    return $msg;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Net::Async::Ping::ICMPv6

=head1 DESCRIPTION

This is the ICMPv6 part of L<Net::Async::Ping>. See that documentation for full
details.

=head2 ICMPv6 methods

This module will first attempt to use a ping socket to send its ICMPv6 packets,
which does not need root privileges. These are only supported on Linux, and
only when the group is stipulated in C</proc/sys/net/ipv4/ping_group_range>
(yes, the IPv4 setting also controls the IPv6 socket).
Failing that, the module will use a raw socket limited to the ICMPv6 protocol,
which will fail if attempted from a non-privileged account.

=head3 ping socket advantages

=over

=item doesn't require root/admin privileges

=item better performance, as the kernel is handling the reply to request
packet matching

=back

=head3 raw socket advantages

=over

=item supports echo replies, no icmp error messages

=back

=head2 Additional options

To disable the attempt to send from a ping socket, set C<use_ping_socket> to
0 when initiating the object:

 my $p = Net::Async::Ping->new(
   icmpv6 => {
      use_ping_socket => 0,
   },
 );

=head2 Return value

L<Net::Async::Ping::ICMPv6> will return the hires time on success. On failure, it
will return the future from L<IO::Async::Resolver> if that failed. Otherwise,
it will return as a future failure:

=over 4

=item "ICMPv6 Unreachable"

ICMPv6 response was ICMPv6_UNREACHABLE

=item "ICMPv6 Timeout"

ICMPv6 response was ICMPv6_TIME_EXCEEDED

=item "Receive error"

An error was received from L<IO::Async::Socket>.

=back

=cut
