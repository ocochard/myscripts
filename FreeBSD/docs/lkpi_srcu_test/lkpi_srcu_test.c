/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Olivier Cochard <olivier@FreeBSD.org>
 *
 * LinuxKPI SRCU test: kldload runs three checks and prints PASS/FAIL.
 *  1. synchronize_srcu(&b) inside a read section of &a returns
 *     (one global epoch made this a self-deadlock).
 *  2. synchronize_srcu(&a) waits for a reader of &a holding 500 ms.
 *  3. Stress: readers dereference a shared object under srcu, a writer
 *     replaces it, calls synchronize_srcu() and poisons the old one; a
 *     reader seeing poison means the grace period ended too early.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/kthread.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/time.h>

#include <linux/srcu.h>
#include <linux/slab.h>

#define	NREADERS	8
#define	STRESS_SEC	5
#define	MAGIC		0x5eed5eedU
#define	POISON		0xdeadbeefU

static struct srcu_struct a, b;
DEFINE_STATIC_SRCU(s3);

struct obj {
	volatile u_int	val;
};

static struct obj *volatile shared;
static int skip_sync;		/* mutant: tunable debug.lkpi_srcu_test_skip */
static volatile int stop, running;
static volatile u_long reads, bad;

static void
hold_reader(void *arg __unused)
{
	int idx;

	idx = srcu_read_lock(&a);
	atomic_store_rel_int(&running, 1);
	pause("srcuhold", hz / 2);
	srcu_read_unlock(&a, idx);
	atomic_store_rel_int(&running, 0);
	kthread_exit();
}

static void
stress_reader(void *arg __unused)
{
	struct obj *o;
	int idx;

	atomic_add_int(&running, 1);
	while (!stop) {
		idx = srcu_read_lock(&s3);
		o = shared;
		if (o->val != MAGIC)
			atomic_add_long(&bad, 1);
		cpu_spinwait();
		if (o->val != MAGIC)
			atomic_add_long(&bad, 1);
		srcu_read_unlock(&s3, idx);
		atomic_add_long(&reads, 1);
	}
	atomic_subtract_int(&running, 1);
	kthread_exit();
}

static int
srcu_test(void)
{
	struct obj *o, *old;
	sbintime_t t0, dt;
	u_long swaps;
	int fail, i, idx;

	fail = 0;
	TUNABLE_INT_FETCH("debug.lkpi_srcu_test_skip", &skip_sync);
	init_srcu_struct(&a);
	init_srcu_struct(&b);

	/* 1. Independent domains. */
	t0 = getsbinuptime();
	idx = srcu_read_lock(&a);
	synchronize_srcu(&b);
	srcu_read_unlock(&a, idx);
	dt = getsbinuptime() - t0;
	printf("srcu test 1 (sync b inside read a): %s, %jd us\n",
	    dt < SBT_1S ? "PASS" : "FAIL", (intmax_t)(dt / SBT_1US));
	fail |= dt >= SBT_1S;

	/* 2. Waits for a reader of the same domain. */
	kthread_add(hold_reader, NULL, NULL, NULL, 0, 0, "srcuhold");
	while (atomic_load_acq_int(&running) == 0)
		pause("srcuw", 1);
	t0 = getsbinuptime();
	synchronize_srcu(&a);
	dt = getsbinuptime() - t0;
	printf("srcu test 2 (sync a waits for 500 ms reader): %s, %jd ms\n",
	    dt >= 400 * SBT_1MS ? "PASS" : "FAIL", (intmax_t)(dt / SBT_1MS));
	fail |= dt < 400 * SBT_1MS;
	while (atomic_load_acq_int(&running) != 0)
		pause("srcuw", 1);

	/* 3. Stress. */
	o = malloc(sizeof(*o), M_TEMP, M_WAITOK);
	o->val = MAGIC;
	shared = o;
	stop = 0;
	for (i = 0; i < NREADERS; i++)
		kthread_add(stress_reader, NULL, NULL, NULL, 0, 0, "srcurd%d",
		    i);
	while (atomic_load_acq_int(&running) != NREADERS)
		pause("srcuw", 1);
	swaps = 0;
	t0 = getsbinuptime();
	while (getsbinuptime() - t0 < STRESS_SEC * SBT_1S) {
		o = malloc(sizeof(*o), M_TEMP, M_WAITOK);
		o->val = MAGIC;
		old = shared;
		atomic_store_rel_ptr((volatile uintptr_t *)&shared,
		    (uintptr_t)o);
		if (!skip_sync)
			synchronize_srcu(&s3);
		old->val = POISON;
		free(old, M_TEMP);
		swaps++;
	}
	stop = 1;
	while (atomic_load_acq_int(&running) != 0)
		pause("srcuw", 1);
	free(shared, M_TEMP);
	printf("srcu test 3 (stress %d readers, %d s%s): %s, %lu swaps, "
	    "%lu reads, %lu bad\n", NREADERS, STRESS_SEC,
	    skip_sync ? ", MUTANT no synchronize" : "",
	    bad == 0 ? "PASS" : "FAIL", swaps, reads, bad);
	fail |= bad != 0;

	cleanup_srcu_struct(&a);
	cleanup_srcu_struct(&b);
	printf("srcu test: %s\n", fail ? "FAIL" : "PASS");
	return (0);
}

static int
srcu_test_modevent(module_t mod __unused, int type, void *data __unused)
{
	switch (type) {
	case MOD_LOAD:
		return (srcu_test());
	case MOD_UNLOAD:
		return (0);
	default:
		return (EOPNOTSUPP);
	}
}

static moduledata_t srcu_test_mod = {
	"lkpi_srcu_test",
	srcu_test_modevent,
	NULL
};
DECLARE_MODULE(lkpi_srcu_test, srcu_test_mod, SI_SUB_LAST, SI_ORDER_ANY);
MODULE_DEPEND(lkpi_srcu_test, linuxkpi, 1, 1, 1);
