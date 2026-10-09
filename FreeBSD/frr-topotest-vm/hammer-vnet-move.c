/*
 * hammer-vnet-move: the reported operation itself, in a loop.
 *
 * Per iteration: create a VNET jail, clone an epair, move the a side into
 * the jail with SIOCSIFVNET (-> if_vmove_loan(), the frame the bug report
 * names), remove the jail, destroy the epair. That is what the FRR topotests
 * do when munet wires a topology, minus the routing daemons -- and what
 * epair-vnet-hang.sh did serially, except this one is meant to be run as N
 * parallel workers by hammer-run.sh.
 *
 * Use it when hammer-epoch-drain (cheaper, an order of magnitude faster)
 * does not wedge: this one is slower but it is the real path, vnet teardown
 * included.
 *
 *   cc -O2 -o hammer-vnet-move hammer-vnet-move.c -ljail
 *   ./hammer-vnet-move [-f heartbeat] [-n iterations]
 *
 * -f writes "<iteration> <ifname> <unix-time> <pid>" BEFORE the vnet move.
 */

#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/jail.h>
#include <sys/socket.h>
#include <sys/sockio.h>

#include <net/if.h>

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <jail.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void
usage(void)
{
	fprintf(stderr, "usage: hammer-vnet-move [-f heartbeat] "
	    "[-n iterations]\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	struct ifreq ifr;
	char beat[80], jname[64], ifname[IFNAMSIZ];
	const char *hbpath = NULL;
	unsigned long long n, iters = 0;	/* 0: forever */
	int c, s, jid, hbfd = -1, len;

	while ((c = getopt(argc, argv, "f:n:")) != -1) {
		switch (c) {
		case 'f':
			hbpath = optarg;
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
		snprintf(jname, sizeof(jname), "hvm%d_%llu", (int)getpid(), n);
		jid = jail_setv(JAIL_CREATE, "name", jname, "host.hostname",
		    jname, "path", "/", "vnet", "new", "persist", "true",
		    NULL);
		if (jid < 0)
			errx(1, "jail_setv: %s", jail_errmsg);

		memset(&ifr, 0, sizeof(ifr));
		strlcpy(ifr.ifr_name, "epair", sizeof(ifr.ifr_name));
		if (ioctl(s, SIOCIFCREATE2, &ifr) < 0)
			err(1, "SIOCIFCREATE2 epair (root?)");
		strlcpy(ifname, ifr.ifr_name, sizeof(ifname));

		if (hbfd >= 0) {
			/* Fixed width: the watchdog reads this as we write. */
			len = snprintf(beat, sizeof(beat),
			    "%020llu %-15s %012lld %7d\n", n, ifname,
			    (long long)time(NULL), (int)getpid());
			(void)pwrite(hbfd, beat, (size_t)len, 0);
		}

		/* The reported operation: if_vmove_loan() via ifioctl(). */
		ifr.ifr_jid = jid;
		if (ioctl(s, SIOCSIFVNET, &ifr) < 0)
			err(1, "SIOCSIFVNET %s -> jid %d", ifname, jid);

		/* Tears the vnet down and hands the interface back. */
		if (jail_remove(jid) < 0)
			err(1, "jail_remove %d", jid);

		/*
		 * Destroying either end destroys the pair. Use the b side: it
		 * never left vnet0, while the a side may not be back yet if
		 * the vnet teardown is deferred, and missing it leaks a pair.
		 */
		memset(&ifr, 0, sizeof(ifr));
		strlcpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name));
		ifr.ifr_name[strlen(ifr.ifr_name) - 1] = 'b';
		if (ioctl(s, SIOCIFDESTROY, &ifr) < 0)
			err(1, "SIOCIFDESTROY %s", ifr.ifr_name);
	}
	printf("%llu vnet moves completed\n", n);
	return (0);
}
