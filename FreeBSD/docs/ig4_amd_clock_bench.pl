#!/usr/bin/perl
# ig4bench.pl <label> <dev>: time 200 successful 1024-byte reads, report median per read
use strict; use Time::HiRes qw(time);
my ($label, $dev) = @ARGV; my (@t, $fail);
while (@t < 200) {
	my $s = time;
	my $rc = system("i2c -f $dev -a 0x30 -o 0 -w 8 -m tr -d r -c 1024 -b >/dev/null 2>&1");
	my $d = time - $s;
	if ($rc == 0) { push @t, $d } else { $fail++ }
}
@t = sort { $a <=> $b } @t;
my $med = $t[100];
printf "%s: median %.2f ms, min %.2f ms per 1 KB read, effective %.0f kHz (median), %d NACKed reads skipped\n",
    $label, $med * 1000, $t[0] * 1000, 1024 * 9 / $med / 1000, $fail // 0;
