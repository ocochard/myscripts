/*
 * hammer-llinfo-delete: the zebra_nhg_check panic without FRR.
 *
 * Panic: GPF in lltable_delete_addr(llt=0xdeadc0de...) <- lla_rt_output <-
 * rts_send, zebra doing an RTM_DELETE of an RTF_LLINFO entry. in_ifdetach()
 * (ifnet_departure_event) frees ifp->if_inet and its lltable without clearing
 * the pointer or waiting for the net epoch, while the ifnet stays reachable by
 * index until if_free(). lla_rt_output() looks the interface up with
 * ifnet_byindex(sdl_index) and dereferences if_inet under the epoch only, so a
 * delete aimed at an interface being destroyed reads freed memory. No ARP entry
 * needs to exist: lltable_delete_addr() locks the table before the lookup.
 *
 * One thread clones and destroys interfaces (epair by default) and publishes
 * the indexes of the live pair; -w workers send RTM_DELETE | RTF_LLDATA
 * aimed at those indexes as fast as the routing socket takes them.
 *
 * Expected on an INVARIANTS kernel: unpatched panics in lltable_delete_addr
 * (or lltable_get/in_lltable_get); with in_ifdetach-epoch.patch the deletes
 * fail with ESRCH once if_inet is NULL and the kernel survives. A NODEBUG
 * kernel does not trash freed memory and will usually survive either way.
 *
 *   cc -O2 -o hammer-llinfo-delete hammer-llinfo-delete.c -lpthread
 *   ./hammer-llinfo-delete [-d seconds] [-i ifkind] [-w workers]
 *
 * Prints one line of counters per second; the last line before a panic is in
 * the console log.
 */

#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>

#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <err.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Routing socket sockaddrs are padded to a long, as in route(8). */
#define	ROUNDUP(a)	((a) > 0 ? (1 + (((a) - 1) | (sizeof(long) - 1))) : \
			    sizeof(long))

static _Atomic u_short	target[2];	/* live a/b ifindex, 0: none yet */
static _Atomic unsigned long long cycles, sent, esrch, einval, other;
static _Atomic int	stop;

static void
usage(void)
{
	fprintf(stderr, "usage: hammer-llinfo-delete [-d seconds] "
	    "[-i ifkind] [-w workers]\n");
	exit(2);
}

static void *
deleter(void *arg)
{
	struct {
		struct rt_msghdr	rtm;