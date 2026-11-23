/*
 * Drive /dev/lkpi_fault (lkpi_fault.ko) through each fault handler mode and
 * report what user space sees: the byte read, a signal, or a hang.
 * Each scenario runs in a child under a watchdog; run as root.
 */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

#include <err.h>
#include <setjmp.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define	NPAGES	4

static sigjmp_buf env;

static void
on_signal(int sig)
{
	siglongjmp(env, sig);
}

static void
touch(volatile unsigned char *p, int page)
{
	unsigned char v;
	int sig;

	printf("  read page %d ...\n", page);
	fflush(stdout);
	if ((sig = sigsetjmp(env, 1)) != 0) {
		printf("    -> signal %d (%s)\n", sig, sig == SIGBUS ? "SIGBUS" :
		    sig == SIGSEGV ? "SIGSEGV" : "other");
		return;
	}
	v = p[(size_t)page * getpagesize()];
	printf("    -> 0x%02x (%s)\n", v, v == 0xa5 ? "driver page" :
	    v == 0 ? "ZERO page, not from the driver" : "unexpected");
	fflush(stdout);
}

static void
scenario(const char *name, int mode, const int *pages, int npages)
{
	pid_t pid;
	int fd, i, status;
	char cmd[128];

	if (sysctlbyname("debug.lkpi_fault.mode", NULL, NULL, &mode,
	    sizeof(mode)) != 0)
		err(1, "sysctl mode");
	printf("== %s (mode %d)\n", name, mode);
	fflush(stdout);
	pid = fork();
	if (pid == 0) {
		volatile unsigned char *p;

		signal(SIGBUS, on_signal);
		signal(SIGSEGV, on_signal);
		fd = open("/dev/lkpi_fault", O_RDWR);
		if (fd < 0)
			err(1, "open");
		p = mmap(NULL, NPAGES * getpagesize(), PROT_READ | PROT_WRITE,
		    MAP_SHARED, fd, 0);
		if (p == MAP_FAILED)
			err(1, "mmap");
		for (i = 0; i < npages; i++)
			touch(p, pages[i]);
		_exit(0);
	}
	for (i = 0; i < 10; i++) {
		sleep(1);
		if (waitpid(pid, &status, WNOHANG) == pid) {
			printf("  child exit status %d\n", WIFEXITED(status) ?
			    WEXITSTATUS(status) : -WTERMSIG(status));
			return;
		}
	}
	printf("  child HUNG after 10 s; kernel stack:\n");
	fflush(stdout);
	snprintf(cmd, sizeof(cmd), "procstat -kk %d | tail -n +2", pid);
	system(cmd);
	kill(pid, SIGKILL);
	for (i = 0; i < 5; i++) {
		sleep(1);
		if (waitpid(pid, &status, WNOHANG) == pid) {
			printf("  child gone %d s after SIGKILL\n", i + 1);
			return;
		}
	}
	printf("  child still alive 5 s after SIGKILL\n");
	fflush(stdout);
}

int
main(void)
{
	static const int p0[] = { 0 };
	static const int p30[] = { 3, 0 };

	setvbuf(stdout, NULL, _IONBF, 0);
	scenario("control: handler inserts the page", 0, p0, 1);
	scenario("#3: handler returns VM_FAULT_SIGBUS", 1, p0, 1);
	scenario("#4: handler inserts pages 0-1, then SIGBUS on page 3; "
	    "then read page 0", 2, p30, 2);
	return (0);
}
