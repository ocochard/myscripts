/*
 * Test for the PROC_SYSCALL_DISPATCH_CTL procctl(2) draft
 * (procctl_syscall_dispatch.patch).
 *
 * A raw "syscall" instruction made while the selector byte says BLOCK must
 * raise SIGSYS without running the system call; the handler emulates it by
 * setting a fake return value.  With the selector at ALLOW the same
 * instruction must run normally.
 *
 * cc -Wall -o procctl_syscall_dispatch_test procctl_syscall_dispatch_test.c
 */
#include <sys/types.h>
#include <sys/procctl.h>
#include <sys/time.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <machine/psl.h>

#include <err.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#ifndef PROC_SYSCALL_DISPATCH_CTL
#define	PROC_SYSCALL_DISPATCH_CTL	25
#define	PROC_SYSCALL_DISPATCH_STATUS	26
#define	PROC_SYSCALL_DISPATCH_OFF	0
#define	PROC_SYSCALL_DISPATCH_ON	1
#define	PROC_SYSCALL_DISPATCH_ALLOW	0
#define	PROC_SYSCALL_DISPATCH_BLOCK	1
#define	PROC_SYSCALL_DISPATCH_ALLOW_SIGNAL 2
struct procctl_syscall_dispatch {
	int		sd_mode;
	int		sd_pad0;
	uintptr_t	sd_start;
	size_t		sd_len;
	char		*sd_selector;
	u_int		sd_pad1[8];
};
#endif
#ifndef SYS_USER_DISPATCH
#define	SYS_USER_DISPATCH	2
#endif

#define	FAKE_RET	4242
#define	ARG4		0x1234567890abcdefL

static volatile char selector = PROC_SYSCALL_DISPATCH_ALLOW;
static volatile int got_code, got_syscall;
static volatile long got_rax, got_r10, got_rcx, got_rip;
static volatile int alrm_selector = -1;

static void
sigalrm_handler(int sig)
{
	(void)sig;
	alrm_selector = selector;	/* the kernel must have set ALLOW_SIGNAL */
}

static void
sigsys_handler(int sig, siginfo_t *si, void *ctx)
{
	ucontext_t *uc = ctx;

	(void)sig;
	/* Native code from here on: let our own system calls through. */
	selector = PROC_SYSCALL_DISPATCH_ALLOW;
	got_code = si->si_code;
	got_syscall = si->si_syscall;
	got_rax = uc->uc_mcontext.mc_rax;
	got_r10 = uc->uc_mcontext.mc_r10;
	got_rcx = uc->uc_mcontext.mc_rcx;
	got_rip = uc->uc_mcontext.mc_rip;
	/* Emulate the call: return FAKE_RET with no error. */
	uc->uc_mcontext.mc_rax = FAKE_RET;
	uc->uc_mcontext.mc_rflags &= ~PSL_C;
}

static long
raw_getpid(void)
{
	register long r10 __asm__("r10") = ARG4;
	long ret;

	/* getpid ignores %r10; it is there to check what the handler sees. */
	__asm__ volatile("syscall" : "=a"(ret), "+r"(r10)
	    : "a"((long)SYS_getpid) : "rcx", "r11", "rdx", "memory");
	return (ret);
}

static int
check(const char *what, int ok)
{
	printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
	return (ok ? 0 : 1);
}

int
main(void)
{
	struct procctl_syscall_dispatch sd, st;
	struct sigaction sa;
	long ret;
	pid_t child;
	int after, failed, status;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = sigsys_handler;
	sa.sa_flags = SA_SIGINFO;
	if (sigaction(SIGSYS, &sa, NULL) != 0)
		err(1, "sigaction");

	memset(&sd, 0, sizeof(sd));
	sd.sd_mode = PROC_SYSCALL_DISPATCH_ON;
	sd.sd_selector = (char *)&selector;
	sd.sd_pad1[0] = 1;
	if (procctl(P_PID, 0, PROC_SYSCALL_DISPATCH_CTL, &sd) == 0 ||
	    errno != EINVAL)
		errx(1, "non-zero padding was accepted");
	sd.sd_pad1[0] = 0;
	if (procctl(P_PID, 0, PROC_SYSCALL_DISPATCH_CTL, &sd) != 0)
		err(1, "procctl(PROC_SYSCALL_DISPATCH_CTL): kernel without "
		    "the patch?");
	failed = 0;

	memset(&st, 0, sizeof(st));
	failed += check("status reports ON with our selector",
	    procctl(P_PID, 0, PROC_SYSCALL_DISPATCH_STATUS, &st) == 0 &&
	    st.sd_mode == PROC_SYSCALL_DISPATCH_ON &&
	    st.sd_selector == (char *)&selector);

	selector = PROC_SYSCALL_DISPATCH_BLOCK;
	ret = raw_getpid();
	after = selector;
	failed += check("blocked syscall is emulated by the SIGSYS handler",
	    ret == FAKE_RET);
	failed += check("the handler's ALLOW survives sigreturn",
	    after == PROC_SYSCALL_DISPATCH_ALLOW);
	failed += check("si_code is SYS_USER_DISPATCH",
	    got_code == SYS_USER_DISPATCH);
	failed += check("si_syscall and rax hold the syscall number",
	    got_syscall == SYS_getpid && got_rax == SYS_getpid);
	failed += check("r10 holds the fourth argument, rcx the return address",
	    got_r10 == ARG4 && got_rcx == got_rip);

	ret = raw_getpid();
	failed += check("selector ALLOW runs the real syscall",
	    ret == getpid());

	/*
	 * A signal arriving while the selector says BLOCK: the busy loop
	 * makes no system call, and libthr's wrapper runs before our handler.
	 */
	sa.sa_handler = sigalrm_handler;
	sa.sa_flags = 0;
	if (sigaction(SIGALRM, &sa, NULL) != 0)
		err(1, "sigaction");
	{
		struct itimerval it = { .it_value = { .tv_usec = 10000 } };

		if (setitimer(ITIMER_REAL, &it, NULL) != 0)
			err(1, "setitimer");
	}
	selector = PROC_SYSCALL_DISPATCH_BLOCK;
	while (alrm_selector == -1)
		;
	after = selector;
	selector = PROC_SYSCALL_DISPATCH_ALLOW;
	failed += check("signal delivery sets the selector to ALLOW_SIGNAL",
	    alrm_selector == PROC_SYSCALL_DISPATCH_ALLOW_SIGNAL);
	failed += check("sigreturn restores BLOCK the handler left alone",
	    after == PROC_SYSCALL_DISPATCH_BLOCK);

	child = fork();
	if (child == 0) {
		memset(&st, 0, sizeof(st));
		_exit(procctl(P_PID, 0, PROC_SYSCALL_DISPATCH_STATUS,
		    &st) == 0 && st.sd_mode == PROC_SYSCALL_DISPATCH_OFF ?
		    0 : 1);
	}
	failed += check("fork(2) child starts with the setting off",
	    child > 0 && waitpid(child, &status, 0) == child &&
	    WIFEXITED(status) && WEXITSTATUS(status) == 0);

	memset(&sd, 0, sizeof(sd));
	sd.sd_mode = PROC_SYSCALL_DISPATCH_OFF;
	failed += check("OFF is accepted",
	    procctl(P_PID, 0, PROC_SYSCALL_DISPATCH_CTL, &sd) == 0);
	selector = PROC_SYSCALL_DISPATCH_BLOCK;
	ret = raw_getpid();
	selector = PROC_SYSCALL_DISPATCH_ALLOW;
	failed += check("after OFF, BLOCK no longer traps", ret == getpid());

	return (failed != 0);
}
