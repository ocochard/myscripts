/*
 * hammer-rt-mpath-race: race a multipath route append against a delete of
 * the same prefix, to reproduce the rtentry use-after-free behind
 * BUG-rtsock-rn_match-panic.md.
 *
 * add_route_flags() finds the prefix, drops the RIB lock and appends the new
 * next hop through add_route_flags_mpath(rnh, rt_orig, ...). If a delete
 * removes the prefix in that window, the retry re-inserts rt_orig -- already
 * scheduled for freeing -- and once the epoch ends the tree links freed
 * memory. The next rtentry allocated from that UMA item is zeroed, and the
 * next lookup faults in rn_match(). On an affected kernel this panics.
 *
 * Everything happens in a VNET jail of its own: an epair with 10.77.0.1/24
 * makes 10.77.0.2 and up valid on-link gateways. Adders append one of -g
 * gateways as a next hop to 110.0.19.1/32 (RTM_ADD with a gateway is
 * RTM_F_APPEND); deleters remove one of them (RTM_DELETE with a gateway). A
 * multipath prefix cannot be deleted without naming a gateway, so the prefix
 * itself disappears only when its last path goes: the window is a prefix
 * with one path A, an adder appending B, and a deleter removing A. A small
 * -g (default 2) keeps the prefix in that state most of the time.
 *
 *   cc -O2 -Wall -o hammer-rt-mpath-race hammer-rt-mpath-race.c -ljail -lpthread
 *   ./hammer-rt-mpath-race [-a adders] [-r deleters] [-g gateways] [-d seconds]
 *
 * Run it in the VM. On an affected kernel it panics the machine.
 */

#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/jail.h>
#include <sys/socket.h>
#include <sys/sockio.h>

#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet/in_var.h>
#include <arpa/inet.h>

#include <err.h>
#include <errno.h>
#include <jail.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define	DST	"110.0.19.1"
static int ngw = 2;

static atomic_ulong nadd, ndel, nadd_ok, ndel_ok;
static volatile int stop;

static struct sockaddr_in
sin4(in_addr_t a)
{
	struct sockaddr_in sin;

	memset(&sin, 0, sizeof(sin));
	sin.sin_len = sizeof(sin);
	sin.sin_family = AF_INET;
	sin.sin_addr.s_addr = a;
	return (sin);
}

static int
rtsock(void)
{
	int rs, off = 0;

	if ((rs = socket(PF_ROUTE, SOCK_RAW, AF_INET)) < 0)
		err(1, "PF_ROUTE");
	/* Nobody reads replies; do not queue our own. */
	if (setsockopt(rs, SOL_SOCKET, SO_USELOOPBACK, &off, sizeof(off)) < 0)
		err(1, "SO_USELOOPBACK");
	return (rs);
}

static int
rtmsg(int rs, int type, in_addr_t gw, int seq)
{
	struct {
		struct rt_msghdr	hdr;
		struct sockaddr_in	dst, gw;
	} m;

	memset(&m, 0, sizeof(m));
	m.hdr.rtm_version = RTM_VERSION;
	m.hdr.rtm_type = type;
	m.hdr.rtm_flags = RTF_UP | RTF_HOST | RTF_STATIC;
	m.hdr.rtm_addrs = RTA_DST;
	m.hdr.rtm_seq = seq;
	m.dst = sin4(inet_addr(DST));
	m.hdr.rtm_msglen = sizeof(m.hdr) + sizeof(m.dst);
	if (gw != 0) {
		m.hdr.rtm_flags |= RTF_GATEWAY;
		m.hdr.rtm_addrs |= RTA_GATEWAY;
		m.gw = sin4(gw);
		m.hdr.rtm_msglen += sizeof(m.gw);
	}
	return (write(rs, &m, m.hdr.rtm_msglen) < 0 ? errno : 0);
}

static void *
adder(void *arg)
{
	int rs = rtsock(), i = (int)(intptr_t)arg, seq = 0;

	while (!stop) {
		in_addr_t gw = htonl(0x0a4d0002 + (unsigned)(i++ % ngw));

		atomic_fetch_add(&nadd, 1);
		if (rtmsg(rs, RTM_ADD, gw, seq++) == 0)
			atomic_fetch_add(&nadd_ok, 1);
	}
	return (NULL);
}

static void *
deleter(void *arg)
{
	int rs = rtsock(), i = (int)(intptr_t)arg, seq = 0;

	while (!stop) {
		in_addr_t gw = htonl(0x0a4d0002 + (unsigned)(i++ % ngw));

		atomic_fetch_add(&ndel, 1);
		if (rtmsg(rs, RTM_DELETE, gw, seq++) == 0)
			atomic_fetch_add(&ndel_ok, 1);
	}
	return (NULL);
}

static void
ifreq_up(int s, const char *name)
{
	struct ifreq ifr;

	memset(&ifr, 0, sizeof(ifr));
	strlcpy(ifr.ifr_name, name, sizeof(ifr.ifr_name));
	if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0)
		err(1, "SIOCGIFFLAGS %s", name);
	ifr.ifr_flags |= IFF_UP;
	if (ioctl(s, SIOCSIFFLAGS, &ifr) < 0)
		err(1, "SIOCSIFFLAGS %s", name);
}

int
main(int argc, char **argv)
{
	struct in_aliasreq ia;
	struct ifreq ifr;
	pthread_t *t;
	char jname[32], epb[IFNAMSIZ];
	int c, s, nadders = 8, ndeleters = 4, secs = 600, i;

	while ((c = getopt(argc, argv, "a:d:g:r:")) != -1) {
		switch (c) {
		case 'a':
			nadders = atoi(optarg);
			break;
		case 'd':
			secs = atoi(optarg);
			break;
		case 'g':
			ngw = atoi(optarg);
			break;
		case 'r':
			ndeleters = atoi(optarg);
			break;
		default:
			fprintf(stderr, "usage: hammer-rt-mpath-race [-a adders] "
			    "[-r deleters] [-g gateways] [-d seconds]\n");
			exit(2);
		}
	}

	/* A VNET jail of our own; it dies with this process. */
	snprintf(jname, sizeof(jname), "hrt%d", (int)getpid());
	if (jail_setv(JAIL_CREATE | JAIL_ATTACH, "name", jname, "path", "/",
	    "vnet", "new", NULL) < 0)
		errx(1, "jail_setv: %s", jail_errmsg);

	if ((s = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
		err(1, "socket");
	ifreq_up(s, "lo0");
	memset(&ifr, 0, sizeof(ifr));
	strlcpy(ifr.ifr_name, "epair", sizeof(ifr.ifr_name));
	if (ioctl(s, SIOCIFCREATE2, &ifr) < 0)
		err(1, "SIOCIFCREATE2 epair");
	strlcpy(epb, ifr.ifr_name, sizeof(epb));
	epb[strlen(epb) - 1] = 'b';
	ifreq_up(s, ifr.ifr_name);
	ifreq_up(s, epb);

	memset(&ia, 0, sizeof(ia));
	strlcpy(ia.ifra_name, ifr.ifr_name, sizeof(ia.ifra_name));
	ia.ifra_addr = sin4(inet_addr("10.77.0.1"));
	ia.ifra_mask = sin4(inet_addr("255.255.255.0"));
	if (ioctl(s, SIOCAIFADDR, &ia) < 0)
		err(1, "SIOCAIFADDR 10.77.0.1/24 on %s", ia.ifra_name);

	if ((t = calloc(nadders + ndeleters, sizeof(*t))) == NULL)
		err(1, "calloc");
	for (i = 0; i < nadders; i++)
		pthread_create(&t[i], NULL, adder, (void *)(intptr_t)(i * 7));
	for (; i < nadders + ndeleters; i++)
		pthread_create(&t[i], NULL, deleter, (void *)(intptr_t)(i * 3));

	printf("jail %s, %s 10.77.0.1/24, %d adders, %d deleters, %d gateways "
	    "on %s/32\n", jname, ifr.ifr_name, nadders, ndeleters, ngw, DST);
	for (i = 1; i <= secs; i++) {
		sleep(1);
		if (i % 10 == 0) {
			printf("%4ds: add %lu (ok %lu), delete %lu (ok %lu)\n", i,
			    atomic_load(&nadd), atomic_load(&nadd_ok),
			    atomic_load(&ndel), atomic_load(&ndel_ok));
			fflush(stdout);
		}
	}
	stop = 1;
	for (i = 0; i < nadders + ndeleters; i++)
		pthread_join(t[i], NULL);
	printf("survived %ds\n", secs);
	return (0);
}
