use Test::More;

use Net::Async::Ping;
use IO::Async::Loop;

my $p = Net::Async::Ping->new('tcp');
my $l = IO::Async::Loop->new;

my $f = $p->ping($l, 'localhost');
$f->on_done(sub { ok 'successfully pinged localhost!' });

$f->get;

done_testing;
