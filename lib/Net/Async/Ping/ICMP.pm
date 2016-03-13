package Net::Async::Ping::ICMP;
$Net::Async::Ping::ICMP::VERSION = '0.001001';
use Moo;
use warnings NONFATAL => 'all';

use Future;
use POSIX 'ECONNREFUSED';
use Time::HiRes;
use Carp;
use Net::Ping;
use IO::Async::Socket;

use Socket qw( SOCK_RAW PF_INET NI_NUMERICHOST inet_aton sockaddr_in getnameinfo);

use constant ICMP_ECHOREPLY   => 0; # ICMP packet types
use constant ICMP_UNREACHABLE => 3; # ICMP packet types
use constant ICMP_ECHO        => 8;
use constant ICMP_TIME_EXCEEDED => 11; # ICMP packet types
use constant ICMP_PARAMETER_PROBLEM => 12; # ICMP packet types
use constant ICMP_STRUCT      => "C2 n3 A"; # Structure of a minimal ICMP packet
use constant SUBCODE          => 0; # No ICMP subcode for ECHO and ECHOREPLY
use constant ICMP_FLAGS       => 0; # No special flags for send or recv
use constant ICMP_PORT        => 0; # No port with ICMP

use namespace::clean;

has default_timeout => (
   is => 'ro',
   default => 5,
);

has service_check => ( is => 'rw' );

has bind => ( is => 'rw' );

sub ping {
    my ($self, $loop, $host, $timeout) = @_;
    $timeout ||= $self->default_timeout;

    my $service_check = $self->service_check;

    my $t0 = [Time::HiRes::gettimeofday];

    my $fh = IO::Socket->new;
    my $proto_num = (getprotobyname('icmp'))[2] ||
        croak("Can't get icmp protocol by name");
    socket($fh, PF_INET, SOCK_RAW, $proto_num) ||
        croak("icmp socket error - $!");

    # data_size to be implemented later
    my $data_size = 0;
    my $data = '';
    my $checksum = 0;
    my $pid = $$ & 0xffff;
    my $seq = 1;
    my $msg = pack(ICMP_STRUCT . $data_size, ICMP_ECHO, SUBCODE,
        $checksum, $pid, $seq, $data);
    $checksum = Net::Ping->checksum($msg); # Subroutine could be copied from module
    $msg = pack(ICMP_STRUCT . $data_size, ICMP_ECHO, SUBCODE,
        $checksum, $pid, $seq, $data);

    my $ip = inet_aton($host);
    my $saddr = sockaddr_in(ICMP_PORT, $ip);

    my $f = $loop->new_future;

    my $socket = IO::Async::Socket->new(
        handle => $fh,
        on_recv => sub {
            my ( $self, $recv_msg, $from_saddr ) = @_;

            my $from_pid = -1;
            my $from_seq = -1;
            my ($from_port, $from_ip) = sockaddr_in($from_saddr);
            my ($from_type, $from_subcode) = unpack("C2", substr($recv_msg, 20, 2));

            if ($from_type == ICMP_ECHOREPLY) {
                ($from_pid, $from_seq) = unpack("n3", substr($recv_msg, 24, 4))
                    if length $recv_msg >= 28;
            } else {
                ($from_pid, $from_seq) = unpack("n3", substr($recv_msg, 52, 4))
                    if length $recv_msg >= 56;
            }
            return if ($from_pid != $pid);
            return if ($from_seq != $seq);

            my $ip = inet_aton($host);
            if ( (ntop($from_ip) eq ntop($ip))) { # Does the packet check out?
                if ($from_type == ICMP_ECHOREPLY) {
                    $f->done;
                } elsif ($from_type == ICMP_UNREACHABLE) {
                    $f->fail('ICMP Unreachable');
                } elsif ($from_type == ICMP_TIME_EXCEEDED) {
                    $f->fail('ICMP Timeout');
                }
                $loop->remove($self);
            }
        },
        on_recv_error => sub {
            my ( $self, $errno ) = @_;
            $f->fail('Receive error');
        },
    );

    # XXX Using add() here can't be right, especially as it has
    # to be removed above. What's the correct solution though?
    # The on_recv code is not called otherwise.
    $loop->add($socket);
    $socket->send( $msg, ICMP_FLAGS, $saddr );

    return Future->wait_any(
       $f,
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

# Copied straight from Net::Ping
sub ntop {
    my($ip) = @_;
 
    # Vista doesn't define a inet_ntop.  It has InetNtop instead.
    # Not following ANSI... priceless.  getnameinfo() is defined
    # for Windows 2000 and later, so that may be the choice.
 
    # Any port will work, even undef, but this will work for now.
    # Socket warns when undef is passed in, but it still works.
    my $port = getservbyname('echo', 'udp');
    my $sockaddr = sockaddr_in $port, $ip;
    my ($error, $address) = getnameinfo($sockaddr, NI_NUMERICHOST);
    if($error) {
      croak $error;
    }
    return $address;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Net::Async::Ping::ICMP

=head1 VERSION

version 0.001001

=head1 AUTHOR

Andy Beverley <andy@andybev.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by Arthur Axel "fREW" Schmidt.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
