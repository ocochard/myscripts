/*
 * hammer-sched-bind: drive sched_bind(9) from userland, as fast as possible.
 *
 * The epair/vnet wedge parks a thread inside sched_bind() called from
 * epoch_drain_callbacks(): runnable, pinned to a CPU, never scheduled there.
 * Nothing in that picture is specific to epoch or to the network stack, so
 * this probe removes both of them and exercises only the bind path.
 *
 * cpuctl(4) binds the calling thread to a target CPU for the duration of one
 * ioctl: cpuctl_do_cpuid() -> set_cpu() -> thread_lock(); sched_bind(); and
 * restore_cpu() -> sched_unbind() on the way out.  CPUCTL_CPUID is read-only
 * and does nothing else of consequence, so a loop over /dev/cpuctl0..N is a
 * bind/unbind hammer that holds no kernel lock a bystander could block on.
 *
 * If this wedges, only this process is stuck and the machine stays usable for
 * procstat(1) and DDB -- unlike the ifnet path, which wedges every interface
 * operation behind ifnet_detach_sxlock.
 *
 *   cc -O2 -o hammer-sched-bind hammer-sched-bind.c
 *   kldload cpuctl
 *   ./hammer-sched-bind [-f heartbeat] [-n iterations] [-r]
 *
 * -f writes "<iteration> <cpu> <unix-time> <pid>" to a file BEFORE each ioctl,
 *    so a watchdog can see which bind stopped returning, where, and when.
 * -r picks CPUs at random instead of round robin.
 */

#include <sys/types.h>
#include <sys/cpuctl.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>

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
	    "usage: hammer-sched-bind [-f heartbeat] [-n iterations] [-r]\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	cpuctl_cpuid_args_t args;
	char path[32], beat[64];
	const char *hbpath = NULL;
	unsigned long long n, iters = 0;	/* 0: forever */
	int *fd, c, cpu, hbfd = -1, len, ncpu;
	size_t sz = sizeof(ncpu);
	int random_cpu = 0;

	while ((c = getopt(argc, argv, "f:n:r")) != -1) {
		switch (c) {
		case 'f':
			hbpath = optarg;
			break;
		case 'n':
			iters = strtoull(optarg, NULL, 0);
			break;
		case 'r':
			random_cpu = 1;
			break;
		default:
			usage();
		}
	}

	if (sysctlbyname("hw.ncpu", &ncpu, &sz, NULL, 0) != 0 || ncpu < 1)
		err(1, "hw.ncpu");
	if ((fd = calloc(ncpu, sizeof(*fd))) == NULL)
		err(1, "calloc");
	for (cpu = 0; cpu < ncpu; cpu++) {
		snprintf(path, sizeof(path), "/dev/cpuctl%d", cpu);
		if ((fd[cpu] = open(path, O_RDONLY)) < 0)
			err(1, "%s (kldload cpuctl? root?)", path);
	}
	if (hbpath != NULL &&
	    (hbfd = open(hbpath, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0)
		err(1, "%s", hbpath);
	srandom((unsigned)(getpid() ^ time(NULL)));

	for (n = 0; iters == 0 || n < iters; n++) {
		cpu = random_cpu ? (int)(random() % ncpu) : (int)(n % ncpu);
		if (hbfd >= 0) {
			/* Fixed width: the watchdog reads this while we write. */
			len = snprintf(beat, sizeof(beat),
			    "%020llu %4d %012lld %7d\n", n, cpu,
			    (long long)time(NULL), (int)getpid());
			(void)pwrite(hbfd, beat, (size_t)len, 0);
		}
		memset(&args, 0, sizeof(args));
		args.level = 0;
		/* The bind under test happens inside this ioctl. */
		if (ioctl(fd[cpu], CPUCTL_CPUID, &args) < 0)
			err(1, "CPUCTL_CPUID on cpu %d", cpu);
	}
	printf("%llu binds completed\n", n);
	return (0);
}
