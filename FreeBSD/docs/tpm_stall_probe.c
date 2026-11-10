/*
 * Detect system-wide stalls: one thread per CPU reads CLOCK_REALTIME in a
 * tight loop and logs every gap longer than a threshold.  A stall that hits
 * all CPUs at once (AMD fTPM advisory PA-410) shows up as gaps on every CPU
 * at the same time; ordinary preemption hits one CPU at a time.
 *
 * Build: cc -O2 -Wall -pthread -o tpm_stall_probe tpm_stall_probe.c
 * Run:   ./tpm_stall_probe SECONDS THRESHOLD_US > gaps.txt  (no rtprio: it
 *        would starve the kernel threads, the TPM harvest task included)
 * Output: one line per gap: <realtime start, ns> <cpu> <gap, us>
 */
#include <sys/param.h>
#include <sys/cpuset.h>

#include <err.h>
#include <pthread.h>
#include <pthread_np.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define	MAXGAPS	100000

struct gap {
	int64_t	start_ns;
	int64_t	len_ns;
};

struct worker {
	pthread_t	thr;
	int		cpu;
	int		ngaps;
	struct gap	*gaps;
};

static int64_t	end_ns, threshold_ns;

static int64_t
now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_REALTIME, &ts);
	return ((int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec);
}

static void *
spin(void *arg)
{
	struct worker *w = arg;
	cpuset_t set;
	int64_t prev, t;

	CPU_ZERO(&set);
	CPU_SET(w->cpu, &set);
	if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0)
		errx(1, "cannot pin to CPU %d", w->cpu);
	prev = now_ns();
	while (prev < end_ns) {
		t = now_ns();
		if (t - prev > threshold_ns && w->ngaps < MAXGAPS) {
			w->gaps[w->ngaps].start_ns = prev;
			w->gaps[w->ngaps].len_ns = t - prev;
			w->ngaps++;
		}
		prev = t;
	}
	return (NULL);
}

int
main(int argc, char **argv)
{
	struct worker *w;
	int i, j, ncpu;

	if (argc != 3)
		errx(1, "usage: tpm_stall_probe SECONDS THRESHOLD_US");
	ncpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
	threshold_ns = strtoll(argv[2], NULL, 10) * 1000;
	end_ns = now_ns() + strtoll(argv[1], NULL, 10) * 1000000000;
	if ((w = calloc(ncpu, sizeof(*w))) == NULL)
		err(1, "calloc");
	for (i = 0; i < ncpu; i++) {
		w[i].cpu = i;
		if ((w[i].gaps = calloc(MAXGAPS, sizeof(struct gap))) == NULL)
			err(1, "calloc");
		if (pthread_create(&w[i].thr, NULL, spin, &w[i]) != 0)
			errx(1, "pthread_create");
	}
	for (i = 0; i < ncpu; i++) {
		pthread_join(w[i].thr, NULL);
		for (j = 0; j < w[i].ngaps; j++)
			printf("%jd %d %jd\n", (intmax_t)w[i].gaps[j].start_ns, i,
			    (intmax_t)(w[i].gaps[j].len_ns / 1000));
		if (w[i].ngaps == MAXGAPS)
			fprintf(stderr, "CPU %d: gap log full\n", i);
	}
	return (0);
}
