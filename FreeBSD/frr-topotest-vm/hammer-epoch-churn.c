/*
 * hammer-epoch-churn: queue net-epoch callbacks as fast as possible.
 *
 * The three wedge hammers queue NET_EPOCH_CALL() work only through their own
 * operations, in lockstep with their own drains. In the FRR topotests, other
 * code queues it independently: zebra installing and withdrawing routes,
 * pimd joining and leaving groups, bridges, tcpdump. This probe is that
 * background, one producer per worker, meant to run alongside
 * hammer-vnet-move or hammer-epoch-drain (hammer-run.sh -c).
 *
 *   ifa     add + delete a /32 alias on lo0      -> ifa_destroy, plus the
 *           loopback host route                     (rtentry, nhop)
 *   mcast   join + leave a fresh group on lo0    -> if_destroymulti
 *   route   RTM_ADD + RTM_DELETE a host route    -> destroy_rtentry, nhop
 *   bpf     open /dev/bpf, BIOCSETIF lo0, close  -> bpfd_free
 *   bridge  addm + deletem an epair on a bridge  -> bridge_delete_member_cb
 *
 * -j runs the worker inside a fresh VNET jail of its own, so the callbacks
 * come from a vnet other than vnet0, as munet's do. The jail dies with the
 * worker.
 *
 *   cc -O2 -Wall -o hammer-epoch-churn hammer-epoch-churn.c -ljail
 *   ./hammer-epoch-churn -m mode [-k index] [-j] [-f heartbeat] [-n iterations]
 *
 * -k makes addresses and names unique per worker (0..255).
 * -f writes "<iteration> <mode> <unix-time> <pid>" about once a second; it is
 * a progress counter, not a stall detector: a churn worker never takes
 * ifnet_detach_sx, so hammer-run.sh does not count it towards a wedge.
 */

#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/jail.h>
#include <sys/socket.h>
#include <sys/sockio.h>

#include <net/bpf.h>
#include <net/if.h>
#include <net/if_bridgevar.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet/in_var.h>
#include <arpa/inet.h>

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <jail.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t done;
static int s, k;
static char brname[IFNAMSIZ], epname[IFNAMSIZ];

static void
onsig(int sig __unused)
{
	done = 1;
}

static void
usage(void)
{
	fprintf(stderr, "usage: hammer-epoch-churn -m ifa|mcast|route|bpf|bridge "
	    "[-k index] [-j] [-f heartbeat] [-n iterations]\n");
	exit(2);
}

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

/* 10.net.k.1-254 */
static in_addr_t
addr(unsigned long long n, int net)
{
	return (htonl((10U << 24) | ((unsigned)net << 16) |
	    ((unsigned)k << 8) | (unsigned)(n % 254 + 1)));
}

static void
ifup(const char *name)
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

static void
ifa(unsigned long cmd, in_addr_t a)
{
	struct in_aliasreq ia;

	memset(&ia, 0, sizeof(ia));
	strlcpy(ia.ifra_name, "lo0", sizeof(ia.ifra_name));
	ia.ifra_addr = sin4(a);
	ia.ifra_mask = sin4(htonl(cmd == SIOCAIFADDR && a ==
	    htonl(INADDR_LOOPBACK) ? IN_CLASSA_NET : 0xffffffff));
	if (ioctl(s, cmd, &ia) < 0)
		err(1, "%s %s", cmd == SIOCAIFADDR ? "SIOCAIFADDR" :
		    "SIOCDIFADDR", inet_ntoa(ia.ifra_addr.sin_addr));
}

static void
mcast(int rs, unsigned long long n)
{
	struct ip_mreq mr;

	mr.imr_multiaddr.s_addr = htonl((239U << 24) | (1U << 16) |
	    ((unsigned)k << 8) | (unsigned)(n % 254 + 1));
	mr.imr_interface.s_addr = htonl(INADDR_LOOPBACK);
	if (setsockopt(rs, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mr, sizeof(mr)) < 0)
		err(1, "IP_ADD_MEMBERSHIP");
	if (setsockopt(rs, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mr, sizeof(mr)) < 0)
		err(1, "IP_DROP_MEMBERSHIP");
}

static void
route(int rs, int type, in_addr_t dst, int seq)
{
	struct {
		struct rt_msghdr	hdr;
		struct sockaddr_in	dst, gw;
	} m;

	memset(&m, 0, sizeof(m));
	m.hdr.rtm_msglen = sizeof(m);
	m.hdr.rtm_version = RTM_VERSION;
	m.hdr.rtm_type = type;
	m.hdr.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC;
	m.hdr.rtm_addrs = RTA_DST | RTA_GATEWAY;
	m.hdr.rtm_pid = getpid();
	m.hdr.rtm_seq = seq;
	m.dst = sin4(dst);
	m.gw = sin4(htonl(INADDR_LOOPBACK));
	if (write(rs, &m, sizeof(m)) < 0)
		err(1, "%s", type == RTM_ADD ? "RTM_ADD" : "RTM_DELETE");
}

static void
bpf(void)
{
	struct ifreq ifr;
	int fd;

	if ((fd = open("/dev/bpf", O_RDONLY)) < 0)
		err(1, "/dev/bpf");
	memset(&ifr, 0, sizeof(ifr));
	strlcpy(ifr.ifr_name, "lo0", sizeof(ifr.ifr_name));
	if (ioctl(fd, BIOCSETIF, &ifr) < 0)
		err(1, "BIOCSETIF lo0");
	close(fd);
}

static void
ifclone(char *name, const char *kind)
{
	struct ifreq ifr;

	memset(&ifr, 0, sizeof(ifr));
	strlcpy(ifr.ifr_name, kind, sizeof(ifr.ifr_name));
	if (ioctl(s, SIOCIFCREATE2, &ifr) < 0)
		err(1, "SIOCIFCREATE2 %s", kind);
	strlcpy(name, ifr.ifr_name, IFNAMSIZ);
}

static void
destroy(const char *name)
{
	struct ifreq ifr;

	memset(&ifr, 0, sizeof(ifr));
	strlcpy(ifr.ifr_name, name, sizeof(ifr.ifr_name));
	(void)ioctl(s, SIOCIFDESTROY, &ifr);
}

static void
bridge(unsigned long cmd)
{
	struct ifbreq req;
	struct ifdrv ifd;

	memset(&req, 0, sizeof(req));
	strlcpy(req.ifbr_ifsname, epname, sizeof(req.ifbr_ifsname));
	memset(&ifd, 0, sizeof(ifd));
	strlcpy(ifd.ifd_name, brname, sizeof(ifd.ifd_name));
	ifd.ifd_cmd = cmd;
	ifd.ifd_len = sizeof(req);
	ifd.ifd_data = &req;
	if (ioctl(s, SIOCSDRVSPEC, &ifd) < 0)
		err(1, "%s %s %s", cmd == BRDGADD ? "addm" : "deletem",
		    brname, epname);
}

int
main(int argc, char **argv)
{
	char beat[80], jname[64];
	const char *hbpath = NULL, *mode = NULL;
	unsigned long long n, iters = 0;	/* 0: forever */
	time_t last = 0, now;
	int c, jid, rs = -1, hbfd = -1, injail = 0, len;

	while ((c = getopt(argc, argv, "f:jk:m:n:")) != -1) {
		switch (c) {
		case 'f':
			hbpath = optarg;
			break;
		case 'j':
			injail = 1;
			break;
		case 'k':
			k = atoi(optarg) & 0xff;
			break;
		case 'm':
			mode = optarg;
			break;
		case 'n':
			iters = strtoull(optarg, NULL, 0);
			break;
		default:
			usage();
		}
	}
	if (mode == NULL)
		usage();

	if (hbpath != NULL &&
	    (hbfd = open(hbpath, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0)
		err(1, "%s", hbpath);

	if (injail) {
		snprintf(jname, sizeof(jname), "hch%d", (int)getpid());
		jid = jail_setv(JAIL_CREATE | JAIL_ATTACH, "name", jname,
		    "host.hostname", jname, "path", "/", "vnet", "new",
		    "allow.raw_sockets", "true", NULL);
		if (jid < 0)
			errx(1, "jail_setv: %s", jail_errmsg);
	}

	if ((s = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
		err(1, "socket");
	/* A new vnet has lo0 down with no address. */
	if (injail) {
		ifup("lo0");
		ifa(SIOCAIFADDR, htonl(INADDR_LOOPBACK));
	}

	if (strcmp(mode, "mcast") == 0)
		rs = s;
	else if (strcmp(mode, "route") == 0) {
		if ((rs = socket(PF_ROUTE, SOCK_RAW, AF_INET)) < 0)
			err(1, "PF_ROUTE");
		/*
		 * Nothing reads this socket: skip our own echoes. Other
		 * workers' messages are dropped once the buffer is full.
		 */
		c = 0;
		if (setsockopt(rs, SOL_SOCKET, SO_USELOOPBACK, &c,
		    sizeof(c)) < 0)
			err(1, "SO_USELOOPBACK");
	} else if (strcmp(mode, "bridge") == 0) {
		ifclone(brname, "bridge");
		ifclone(epname, "epair");
		ifup(brname);
		ifup(epname);
	} else if (strcmp(mode, "ifa") != 0 && strcmp(mode, "bpf") != 0)
		usage();

	signal(SIGTERM, onsig);
	signal(SIGINT, onsig);

	for (n = 0; !done && (iters == 0 || n < iters); n++) {
		if (hbfd >= 0 && (now = time(NULL)) != last) {
			last = now;
			len = snprintf(beat, sizeof(beat),
			    "%020llu %-15s %012lld %7d\n", n, mode,
			    (long long)now, (int)getpid());
			(void)pwrite(hbfd, beat, (size_t)len, 0);
		}
		switch (mode[0]) {
		case 'i':
			ifa(SIOCAIFADDR, addr(n, 200));
			ifa(SIOCDIFADDR, addr(n, 200));
			break;
		case 'm':
			mcast(rs, n);
			break;
		case 'r':
			route(rs, RTM_ADD, addr(n, 210), (int)n);
			route(rs, RTM_DELETE, addr(n, 210), (int)n);
			break;
		case 'b':
			if (mode[1] == 'p')
				bpf();
			else {
				bridge(BRDGADD);
				bridge(BRDGDEL);
			}
			break;
		}
	}

	if (brname[0] != '\0') {
		destroy(epname);
		destroy(brname);
	}
	printf("%s: %llu iterations\n", mode, n);
	return (0);
}
