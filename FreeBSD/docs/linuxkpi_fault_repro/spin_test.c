/*
 * Touch a /dev/lkpi_fault page while the handler is in mode 3 (NOPAGE with
 * nothing inserted), so the faulting thread spins in the LinuxKPI populate
 * loop.  The caller then sends SIGKILL and watches whether the process ends.
 *
 *   spin_test st         the only thread faults
 *   spin_test mt-worker  a second thread faults, the main thread sleeps
 *   spin_test mt-main    the main thread faults, a second thread sleeps
 */
#include <sys/types.h>
#include <sys/mman.h>

#include <err.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static volatile unsigned char *page;

static void *
toucher(void *arg)
{
	(void)arg;
	(void)page[0];
	return (NULL);
}

static void *
sleeper(void *arg)
{
	(void)arg;
	for (;;)
		pause();
	return (NULL);
}

int
main(int argc, char **argv)
{
	pthread_t t;
	int fd;

	if (argc != 2)
		errx(1, "usage: spin_test st|mt-worker|mt-main");
	fd = open("/dev/lkpi_fault", O_RDWR);
	if (fd < 0)
		err(1, "open");
	page = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE, MAP_SHARED,
	    fd, 0);
	if (page == MAP_FAILED)
		err(1, "mmap");
	if (strcmp(argv[1], "st") == 0) {
		toucher(NULL);
	} else if (strcmp(argv[1], "mt-worker") == 0) {
		if (pthread_create(&t, NULL, toucher, NULL) != 0)
			errx(1, "pthread_create");
		sleeper(NULL);
	} else if (strcmp(argv[1], "mt-main") == 0) {
		if (pthread_create(&t, NULL, sleeper, NULL) != 0)
			errx(1, "pthread_create");
		sleep(1);
		toucher(NULL);
	} else
		errx(1, "unknown case %s", argv[1]);
	printf("touch returned\n");
	return (0);
}
