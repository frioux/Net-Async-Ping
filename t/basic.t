use Test::More tests => 3;

use Net::Async::Ping;
use IO::Async::Loop;

use Test::Fatal;

my $p = Net::Async::Ping->new('tcp', 1);
my $l = IO::Async::Loop->new;

$p->ping($l, 'localhost')
   ->then(sub {
      pass 'pinged localhost!';
      Future->done
   })->else(sub {
      fail 'pinged localhost!';
      Future->fail('failed to ping localhost!')
   })->get;

# http://en.wikipedia.org/wiki/Reserved_IP_addresses
my $f = $p->ping($l, '192.0.2.0')
   ->then(sub {
      fail q(couldn't reach 192.0.2.0);
      Future->done
   })->else(sub {
      pass q(couldn't reach 192.0.2.0);
      Future->fail('expected failure')
   });

like exception { $f->get }, qr/expected failure/, 'expected failure';
