/*
 * Reproducer: the IPv6 multicast "wrong MIF" upcall corrupts the IPv6 header
 * of the packet it was made from.
 *
 * ip6_mdq() copies the header with m_copym(), relies on m_pullup() to make
 * that copy private, then writes an mrt6msg over it (bytes 0-3: mbz,
 * msgtype, mif). Since m_pullup() became an inline that returns early when
 * the bytes are already contiguous, the copy shares the receive cluster with
 * the original, so the original's version, traffic class and flow label are
 * overwritten. ip6_input() then delivers that original to local members:
 * a local receiver sees the wrong traffic class.
 *
 * Topology: two hosts on one link, the router has a second interface.
 *
 *   sender  ---- link ---- [ifB] router [ifA]
 *
 * Router (needs root, no other multicast routing daemon running):
 *   mroute6_wrongmif_tclass router <ifA> <ifB> <sender-addr> <group>
 *   It declares the (sender, group) cache entry with ifA as parent, so
 *   traffic arriving on ifB takes the wrong-MIF path, and receives the
 *   group itself on ifB with IPV6_RECVTCLASS.
 *
 * Sender:
 *   mroute6_wrongmif_tclass send <if> <group> [count]
 *   Sends 1000-byte UDP datagrams with traffic class 0xb8.
 *
 * Expected on the router: "tclass 0xb8". With the bug: another value (0x02
 * on a bhyve vtnet router), and the wrong-MIF upcall counter increases.
 * Run it on real NICs (e.g. vtnet in bhyve): the received header must sit in
 * a cluster. With epair(4) the header usually stays in a small private mbuf,
 * m_copym() copies it, and the bug does not show.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>

#include <net/if.h>
#include <netinet/in.h>
#include <netinet/icmp6.h>
#include <netinet6/ip6_mroute.h>
#include <arpa/inet.h>

#include <err.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define	PORT	9999
#define	TCLASS	0xb8
#define	PAYLOAD	1000

static void
usage(void)
{
	fprintf(stderr,
	    "usage: mroute6_wrongmif_tclass router ifA ifB sender group\n"
	    "       mroute6_wrongmif_tclass send if group [count]\n");
	exit(2);
}

static unsigned int
ifindex(const char *name)
{
	unsigned int idx;

	if ((idx = if_nametoindex(name)) == 0)
		errx(1, "unknown interface %s", name);
	return (idx);
}

static void
parse_addr(const char *s, struct sockaddr_in6 *sin6)
{
	memset(sin6, 0, sizeof(*sin6));
	sin6->sin6_len = sizeof(*sin6);
	sin6->sin6_family = AF_INET6;
	if (inet_pton(AF_INET6, s, &sin6->sin6_addr) != 1)
		errx(1, "bad IPv6 address %s", s);
}

static void
add_mif(int s, mifi_t mifi, unsigned int pifi)
{
	struct mif6ctl mc;

	memset(&mc, 0, sizeof(mc));
	mc.mif6c_mifi = mifi;
	mc.mif6c_pifi = pifi;
	if (setsockopt(s, IPPROTO_IPV6, MRT6_ADD_MIF, &mc, sizeof(mc)) < 0)
		err(1, "MRT6_ADD_MIF %d", mifi);
}

static int
router(const char *ifa, const char *ifb, const char *src, const char *grp)
{
	struct mf6cctl mfc;
	struct ipv6_mreq mreq;
	struct sockaddr_in6 sin6;
	struct pollfd pfd[2];
	unsigned char buf[2048], cbuf[CMSG_SPACE(sizeof(int))];
	int mr, rx, on = 1, received = 0, upcalls = 0;
	unsigned int idx_b = ifindex(ifb);

	/* Become the IPv6 multicast router, with PIM processing on. */
	if ((mr = socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)) < 0)
		err(1, "raw socket");
	if (setsockopt(mr, IPPROTO_IPV6, MRT6_INIT, &on, sizeof(on)) < 0)
		err(1, "MRT6_INIT (multicast routing in kernel? daemon running?)");
	if (setsockopt(mr, IPPROTO_IPV6, MRT6_PIM, &on, sizeof(on)) < 0)
		err(1, "MRT6_PIM");
	add_mif(mr, 0, ifindex(ifa));
	add_mif(mr, 1, idx_b);

	/* (src, grp) is expected on mif 0: arriving on mif 1 is wrong. */
	memset(&mfc, 0, sizeof(mfc));
	parse_addr(src, &mfc.mf6cc_origin);
	parse_addr(grp, &mfc.mf6cc_mcastgrp);
	mfc.mf6cc_parent = 0;
	IF_ZERO(&mfc.mf6cc_ifset);
	if (setsockopt(mr, IPPROTO_IPV6, MRT6_ADD_MFC, &mfc, sizeof(mfc)) < 0)
		err(1, "MRT6_ADD_MFC");

	/* Local member of the group on ifB, reporting the traffic class. */
	if ((rx = socket(AF_INET6, SOCK_DGRAM, 0)) < 0)
		err(1, "udp socket");
	parse_addr("::", &sin6);
	sin6.sin6_port = htons(PORT);
	if (bind(rx, (struct sockaddr *)&sin6, sizeof(sin6)) < 0)
		err(1, "bind");
	memset(&mreq, 0, sizeof(mreq));
	parse_addr(grp, &sin6);
	mreq.ipv6mr_multiaddr = sin6.sin6_addr;
	mreq.ipv6mr_interface = idx_b;
	if (setsockopt(rx, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq,
	    sizeof(mreq)) < 0)
		err(1, "IPV6_JOIN_GROUP");
	if (setsockopt(rx, IPPROTO_IPV6, IPV6_RECVTCLASS, &on, sizeof(on)) < 0)
		err(1, "IPV6_RECVTCLASS");

	printf("router ready: expecting tclass 0x%02x on %s\n", TCLASS, ifb);
	fflush(stdout);

	pfd[0].fd = rx;
	pfd[0].events = POLLIN;
	pfd[1].fd = mr;
	pfd[1].events = POLLIN;
	/* Stop after 5 datagrams or 30 s of silence. */
	while (received < 5 && poll(pfd, 2, 30000) > 0) {
		if (pfd[1].revents & POLLIN) {
			/* Kernel upcalls arrive as mrt6msg, im6_mbz == 0. */
			ssize_t n = recv(mr, buf, sizeof(buf), 0);
			struct mrt6msg *im = (struct mrt6msg *)buf;

			if (n >= (ssize_t)sizeof(*im) && im->im6_mbz == 0 &&
			    im->im6_msgtype == MRT6MSG_WRONGMIF)
				upcalls++;
		}
		if (pfd[0].revents & POLLIN) {
			struct msghdr msg;
			struct iovec iov = { buf, sizeof(buf) };
			struct cmsghdr *cm;
			int tclass = -1;

			memset(&msg, 0, sizeof(msg));
			msg.msg_iov = &iov;
			msg.msg_iovlen = 1;
			msg.msg_control = cbuf;
			msg.msg_controllen = sizeof(cbuf);
			if (recvmsg(rx, &msg, 0) < 0)
				err(1, "recvmsg");
			for (cm = CMSG_FIRSTHDR(&msg); cm != NULL;
			    cm = CMSG_NXTHDR(&msg, cm))
				if (cm->cmsg_level == IPPROTO_IPV6 &&
				    cm->cmsg_type == IPV6_TCLASS)
					memcpy(&tclass, CMSG_DATA(cm),
					    sizeof(tclass));
			received++;
			printf("datagram %d: tclass 0x%02x (%s), "
			    "wrong-MIF upcalls so far %d\n", received, tclass,
			    tclass == TCLASS ? "intact" : "CORRUPTED", upcalls);
			fflush(stdout);
		}
	}
	if (received == 0)
		errx(1, "no datagram received (wrong-MIF upcalls: %d)",
		    upcalls);
	return (0);
}

static int
sender(const char *ifname, const char *grp, int count)
{
	struct sockaddr_in6 dst;
	char payload[PAYLOAD];
	unsigned int idx = ifindex(ifname);
	int s, tclass = TCLASS, hops = 8;

	if ((s = socket(AF_INET6, SOCK_DGRAM, 0)) < 0)
		err(1, "udp socket");
	if (setsockopt(s, IPPROTO_IPV6, IPV6_MULTICAST_IF, &idx,
	    sizeof(idx)) < 0)
		err(1, "IPV6_MULTICAST_IF");
	if (setsockopt(s, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops,
	    sizeof(hops)) < 0)
		err(1, "IPV6_MULTICAST_HOPS");
	if (setsockopt(s, IPPROTO_IPV6, IPV6_TCLASS, &tclass,
	    sizeof(tclass)) < 0)
		err(1, "IPV6_TCLASS");
	parse_addr(grp, &dst);
	dst.sin6_port = htons(PORT);
	memset(payload, 'x', sizeof(payload));
	for (int i = 0; i < count; i++) {
		if (sendto(s, payload, sizeof(payload), 0,
		    (struct sockaddr *)&dst, sizeof(dst)) < 0)
			err(1, "sendto");
		usleep(200000);
	}
	printf("sent %d datagrams to %s on %s, tclass 0x%02x\n", count, grp,
	    ifname, TCLASS);
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc >= 6 && strcmp(argv[1], "router") == 0)
		return (router(argv[2], argv[3], argv[4], argv[5]));
	if (argc >= 4 && strcmp(argv[1], "send") == 0)
		return (sender(argv[2], argv[3],
		    argc >= 5 ? atoi(argv[4]) : 10));
	usage();
}
