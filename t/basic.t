use Test::More;

use Net::Async::Ping;
use IO::Async::Loop;

my $p = Net::Async::Ping->new('tcp');
my $l = IO::Async::Loop->new;

my @r = $p->ping($l, 'localhost')->get;
ok($r[0], 'successfully pinged localhost!');

done_testing;
