/*
 * hammer-epoch-drain: clone and destroy an interface in a tight loop.
 *
 * if_detach_internal() calls NET_EPOCH_DRAIN_CALLBACKS() -- the function the
 * epair/vnet wedge is stuck in -- and if_detach_internal() runs on EVERY
 * interface destroy, not only on a vnet move.  So no jail, no epair, no
 * routing daemon is needed to reach it: SIOCIFCREATE2 + SIOCIFDESTROY in a
 * loop hits the same drain thousands of times a second, where a topotest run
 * hits it a few times a second.
 *
 * Like the real thing, the drain here runs with ifnet_detach_sxlock held, so
 * a wedge stalls every interface operation on the machine.  Run it in the VM,
 * not on a workstation.
 *
 *   cc -O2 -o hammer-epoch-drain hammer-epoch-drain.c
 *   ./hammer-epoch-drain [-i ifkind] [-f heartbeat] [-n iterations]
 *
 * -f writes "<iteration> <ifname> <unix-time> <pid>" to a file BEFORE the
 *    destroy ioctl, so a watchdog can see which drain stopped returning.
 * -i defaults to "lo" (cheapest ifnet).  "epair" is what the bug report used;
 *    it creates two ifnets per clone, so it drains twice as often.
 */

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>

#include <net/if.h>

#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void
usage(void)
{
	fprintf(stderr,
	    "usage: hammer-epoch-drain [-i ifkind] [-f heartbeat] "
	    "[-n iterations]\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	struct ifreq ifr;
	char beat[80];
	const char *kind = "lo", *hbpath = NULL;
	unsigned long long n, iters = 0;	/* 0: forever */
	int c, s, hbfd = -1, len;

	while ((c = getopt(argc, argv, "f:i:n:")) != -1) {
		switch (c) {
		case 'f':
			hbpath = optarg;
			break;
		case 'i':
			kind = optarg;
			break;
		case 'n':
			iters = strtoull(optarg, NULL, 0);
			break;
		default:
			usage();
		}
	}

	if ((s = socket(AF_LOCAL, SOCK_DGRAM, 0)) < 0)
		err(1, "socket");
	if (hbpath != NULL &&
	    (hbfd = open(hbpath, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0)
		err(1, "%s", hbpath);

	for (n = 0; iters == 0 || n < iters; n++) {
		memset(&ifr, 0, sizeof(ifr));
		strlcpy(ifr.ifr_name, kind, sizeof(ifr.ifr_name));
		if (ioctl(s, SIOCIFCREATE2, &ifr) < 0)
			err(1, "SIOCIFCREATE2 %s (root?)", kind);
		if (hbfd >= 0) {
			/* Fixed width: the watchdog reads this as we write. */
			len = snprintf(beat, sizeof(beat),
			    "%020llu %-15s %012lld %7d\n", n, ifr.ifr_name,
			    (long long)time(NULL), (int)getpid());
			(void)pwrite(hbfd, beat, (size_t)len, 0);
		}
		/* The drain under test happens inside this ioctl. */
		if (ioctl(s, SIOCIFDESTROY, &ifr) < 0)
			err(1, "SIOCIFDESTROY %s", ifr.ifr_name);
	}
	printf("%llu create/destroy cycles completed\n", n);
	return (0);
}
