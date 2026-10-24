Summary: netinet: in_ifdetach() frees if_inet and its lltable without an epoch wait; RTM_DELETE of an RTF_LLDATA entry panics (use-after-free)

Component: kern (net / netinet)
Version: 16.0-CURRENT (main-n290121-84f790e5b6cc, also main-n290139-c30a321a61ce)
Regression from: 0d469d23715d "net: attach IPv4 and IPv6 stacks to an interface with EVENTHANDLER(9)"

## Symptom

A routing socket RTM_DELETE with RTF_LLDATA for an
interface that is being destroyed panics an INVARIANTS kernel:

    Fatal trap 9: general protection fault while in kernel mode
    current thread = 6484/104841 (zebra/zebra)
    rdi: deadc0dedeadc11e  rdx: deadc0dedeadc106  rax: deadc0dedeadc0de
    panic: general protection fault
    __mtx_lock_flags() at __mtx_lock_flags+0x49
    lltable_delete_addr() at lltable_delete_addr+0x2e
    rts_send() at rts_send+0x8d1        (lla_rt_output() inlined)
    sosend_generic_locked() / sosend_generic() / sousrsend()
    dofilewrite() / sys_write()

kgdb on the original report (main-n290121-84f790e5b6cc GENERIC):

    #8  lltable_delete_addr (llt=0xdeadc0dedeadc0de, ...) at sys/net/if_llatbl.c:725
    #9  lla_rt_output (rtm=..., info=...)                 at sys/net/if_llatbl.c:1056
    #10 rts_send (...)                                    at sys/net/rtsock.c:1142
        rtm_flags = 0xC04 (RTF_HOST|RTF_LLDATA|RTF_STATIC), AF_INET, RTM_DELETE

The lltable pointer itself is 0xdeadc0de...: the in_ifinfo that held it was
already freed. On a kernel without INVARIANTS the same race silently reads
freed memory.

It was first hit by the FRR topotests on FreeBSD (zebra_nhg_check) with a
zebra that programs ARP entries through the routing socket. The panic comes
from the kernel, though: any root process that sends this message while the
interface is going away can trigger it; the netlink RTM_DELNEIGH handler
used by arp -d follows the same path (not tested).

## Cause

in_ifdetach() (sys/netinet/in.c, an ifnet_departure_event handler) ends with:

    igmp_domifdetach(ifp);
    lltable_free(ii->ii_llt);
    free(ii, M_IFADDR);

It frees ifp->if_inet and its lltable immediately, without clearing
ifp->if_inet and without waiting for the network epoch. The ifnet stays
reachable by index until if_free(), so a concurrent reader in the epoch still
gets to the freed memory:

    rts_send() [NET_EPOCH_ENTER]
      lla_rt_output()
        ifp = ifnet_byindex(dl->sdl_index)      /* still valid */
        llt = lltable_get(ifp, AF_INET)         /* in_lltable_get(): ifp->if_inet->ii_llt, freed */
        lltable_delete_addr(llt, ...)           /* LLTABLE lock on freed memory => GPF */

Before 0d469d23715d, if_detach_internal() cleared if_afdata[] and did a
NET_EPOCH_WAIT() before calling dom_ifdetach (added by b5c46895fddd
"ifnet: Defer detaching address family dependent data", with the comment
"at least we can make a guarantee that threads those enter net epoch will
see NULL address family dependent data"). 0d469d23715d moved the per-AF
detach to ifnet_departure_event handlers and dropped that clear-and-wait, so
the IPv4 handler now frees data that epoch readers can still reach.

The IPv6 handler got f3de667137e9 (free in6_ifextra with epoch_call(9)), but
see "IPv6" below.

## Fix

Hide if_inet from new readers and wait out current ones before freeing, and
make in_lltable_get() tolerate the NULL (lla_rt_output() already returns
ESRCH when lltable_get() returns NULL):

    --- sys/netinet/in.c
    +++ sys/netinet/in.c
    @@ -1405,6 +1405,16 @@ in_ifdetach(void *arg __unused, struct ifnet *ifp)
     	}
     
     	igmp_domifdetach(ifp);
    +
    +	/*
    +	 * The ifnet is still reachable by index, and threads in the network
    +	 * epoch, e.g. a routing socket RTM_DELETE of an RTF_LLINFO entry,
    +	 * dereference if_inet and its lltable without a reference.  Hide
    +	 * if_inet from new readers and wait out the current ones before
    +	 * freeing.
    +	 */
    +	atomic_store_ptr(&ifp->if_inet, NULL);
    +	NET_EPOCH_WAIT();
     	lltable_free(ii->ii_llt);
     	free(ii, M_IFADDR);
     }
    @@ -1923,9 +1933,12 @@ in_lltattach(struct ifnet *ifp)
     struct lltable *
     in_lltable_get(struct ifnet *ifp)
     {
    -	/* XXXGL: ??? */
    -	if (ifp->if_inet == NULL)
    +	struct in_ifinfo *ii;
    +
    +	/* NULL once in_ifdetach() has started tearing the interface down. */
    +	ii = atomic_load_ptr(&ifp->if_inet);
    +	if (ii == NULL)
     		return (NULL);
     
    -	return (((struct in_ifinfo *)ifp->if_inet)->ii_llt);
    +	return (ii->ii_llt);
     }

An epoch callback cannot replace the NET_EPOCH_WAIT(): lltable_free() calls
lltable_unlink(), which needs curvnet for V_lltables.

Other if_inet readers (igmp input, LLTABLE() users in if_ether.c, in.c,
in_mcast.c) do not check for NULL either. They did not check
if_afdata[AF_INET] before the regression, and the old code cleared it the
same way, so this restores the pre-regression behaviour rather than adding a
new state for them.

## How to reproduce

Every run, in a bhyve guest (12 vCPUs, 42 GB) with a GENERIC (INVARIANTS)
kernel:

1. FRR built from https://github.com/FRRouting/frr/pull/23475 (commit
   afe9d6bcb3) plus a zebra patch that implements kernel_neigh_update() on
   BSD with RTF_LLDATA routing messages (the reporter's patch; stock FRR
   never sends RTF_LLDATA).
2. cd tests/topotests && python3 -m pytest zebra_nhg_check
3. During teardown the 128 epair interfaces of the test are destroyed in
   parallel while zebra is still running. zebra reacts to each interface
   going away with an RTM_DELETE for 169.254.0.1 on that interface
   (if_nbr_ipv6ll_to_ipv4ll_neigh_del_all()), whether or not the entry
   exists. One of those lands between in_ifdetach() and if_free().

Results (zebra_nhg_check, FRR afe9d6bcb3 + neighbor patch):

    kernel                                   iterations   panics
    main-n290139-c30a321a61ce GENERIC        1            1 (iteration 1)   reporter's FRR patch
    main-n290139-c30a321a61ce GENERIC        1            1 (iteration 1)   equivalent FRR patch
    same + fix above                         30           0                 reporter's FRR patch
    same + fix above                         30           0                 equivalent FRR patch

With stock FRR (no RTF_LLDATA messages) the same test ran 512 times on
unpatched kernels without a panic, which matches the analysis: the trigger is
the RTF_LLDATA delete, not the interface churn alone.

Crash dumps and the original core.txt are available on request.

## IPv6 (not reproduced)

in6_ifdeparture() frees in6_ifextra with NET_EPOCH_CALL() but still calls
lltable_free(ext->lltable) immediately, and its own XXXGL comment notes the
table itself is not epoch protected. An RTF_LLDATA RTM_DELETE for an AF_INET6
neighbor racing with interface destruction should hit the same use-after-free
through in6_lltable_get(). Not reproduced here: zebra does not send IPv6
neighbor deletes on interface removal.
