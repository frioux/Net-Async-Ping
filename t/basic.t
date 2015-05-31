use Test::More tests => 3;

use Net::Async::Ping;
use IO::Async::Loop;

use Test::Fatal;

my $p = Net::Async::Ping->new('tcp', 1);
my $l = IO::Async::Loop->new;

$p->ping($l, 'localhost')
   ->then(sub {
      pass 'pinged localhost!';
      note("success future: @_");
      Future->done
   })->else(sub {
      fail 'pinged localhost!';
      note("failure future: @_");
      Future->fail('failed to ping localhost!')
   })->get;

# http://en.wikipedia.org/wiki/Reserved_IP_addresses
my $f = $p->ping($l, '192.0.2.0')
   ->then(sub {
      fail q(couldn't reach 192.0.2.0);
      note("success future: @_");
      Future->done
   })->else(sub {
      pass q(couldn't reach 192.0.2.0);
      note("failure future: @_");
      Future->fail('expected failure')
   });

like exception { $f->get }, qr/expected failure/, 'expected failure';
