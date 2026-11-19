/*
 * sudtrace: log the system calls of a program, including the ones it makes
 * without going through libc (Go programs, static binaries, inline asm).
 *
 * LD_PRELOAD=./sudtrace.so program [args]
 *
 * It uses procctl(PROC_SYSCALL_DISPATCH_CTL) (procctl_syscall_dispatch.patch
 * in FreeBSD/docs): every system call made from outside a small stub of this
 * library raises SIGSYS instead of running.  The SIGSYS handler logs it,
 * runs it through the stub and puts the result back in the interrupted
 * registers.  Unlike ptrace(2) there is no second process, and unlike a
 * libc hook nothing is missed.
 *
 * Environment:
 *   SUDTRACE_ALL=1	log every system call, not only open/connect/execve
 *   SUDTRACE_OUT=file	append the log to file instead of stderr
 *
 * Limits of this demo: the system calls made by signal handlers are not
 * seen (the kernel lets them through, as for Wine), a SIGSYS handler the
 * program installs is recorded but never called, and rfork(RFMEM) is not
 * handled.
 */
#include <sys/types.h>
#include <sys/procctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/thr.h>
#include <sys/un.h>
#include <machine/psl.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <fcntl.h>
#include <link.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sysdecode.h>
#include <ucontext.h>
#include <unistd.h>

#ifndef PROC_SYSCALL_DISPATCH_CTL
#define	PROC_SYSCALL_DISPATCH_CTL	25
#define	PROC_SYSCALL_DISPATCH_ON	1
#define	PROC_SYSCALL_DISPATCH_BLOCK	1
struct procctl_syscall_dispatch {
	int		sd_mode;
	int		sd_pad0;
	uintptr_t	sd_start;
	size_t		sd_len;
	char		*sd_selector;
	u_int		sd_pad1[8];
};
#endif

#define	MAX_THREADS	1024

/* Where a system call came from. */
enum { FROM_LIBSYS, FROM_PROGRAM, FROM_OTHER, FROM_MAX };
static const char *from_name[FROM_MAX] = { "libsys", "program", "other" };

struct sud_regs {
	long	rax, rdi, rsi, rdx, r10, r8, r9;
	long	err;		/* out: -1 if the carry flag was set */
};

/*
 * The only code allowed to make system calls.  It lives in its own section,
 * and the linker's __start_/__stop_ symbols give the range for the kernel.
 */
void sud_syscall(struct sud_regs *) __attribute__((visibility("hidden")));
void sud_in_place(void) __attribute__((visibility("hidden")));
extern char __start_sud_text[], __stop_sud_text[];
__asm__(
"	.pushsection sud_text,\"ax\",@progbits\n"
"	.hidden sud_syscall\n"
"	.type sud_syscall,@function\n"
"sud_syscall:\n"
"	pushq	%rbx\n"
"	movq	%rdi, %rbx\n"
"	movq	0(%rbx), %rax\n"
"	movq	8(%rbx), %rdi\n"
"	movq	16(%rbx), %rsi\n"
"	movq	24(%rbx), %rdx\n"
"	movq	32(%rbx), %r10\n"
"	movq	40(%rbx), %r8\n"
"	movq	48(%rbx), %r9\n"
"	syscall\n"
"	movq	%rax, 0(%rbx)\n"
"	movq	%rdx, 24(%rbx)\n"
"	sbbq	%rcx, %rcx\n"
"	movq	%rcx, 56(%rbx)\n"
"	popq	%rbx\n"
"	ret\n"
"	.size sud_syscall, .-sud_syscall\n"
/*
 * Run a trapped system call back in the program's context: the handler
 * pushes the return address below the red zone and resumes here.
 */
"	.hidden sud_in_place\n"
"	.type sud_in_place,@function\n"
"sud_in_place:\n"
"	syscall\n"
"	ret	$128\n"
"	.size sud_in_place, .-sud_in_place\n"
"	.popsection\n");

static long
sys4(long nr, long a1, long a2, long a3, long a4)
{
	struct sud_regs r = { .rax = nr, .rdi = a1, .rsi = a2, .rdx = a3,
	    .r10 = a4 };

	sud_syscall(&r);
	return (r.err ? -1 : r.rax);
}

#define	sys(nr, a1, a2, a3)	sys4(nr, a1, a2, a3, 0)

/* One selector byte per thread, and what a new thread must start. */
static char selectors[MAX_THREADS];
static struct {
	void	(*func)(void *);
	void	*arg;
} slots[MAX_THREADS];
static u_int nslots = 1;		/* slot 0: the main thread */

static uintptr_t range_start[FROM_MAX], range_end[FROM_MAX];
static int logfd = -1, log_all;
static u_long counts[FROM_MAX][SYS_MAXSYSCALL];
static struct sigaction app_sigsys;	/* what the program thinks it set */

/* Small async-signal-safe log line builder. */
struct line {
	char	b[512];
	size_t	n;
};

static void
lstr(struct line *l, const char *s)
{
	while (*s != '\0' && l->n < sizeof(l->b) - 1)
		l->b[l->n++] = *s++;
}

static void
lnum(struct line *l, long v)
{
	char t[24];
	int i = sizeof(t) - 1;
	u_long u = v < 0 ? -(u_long)v : (u_long)v;

	t[i] = '\0';
	do
		t[--i] = '0' + u % 10;
	while ((u /= 10) != 0);
	if (v < 0)
		t[--i] = '-';
	lstr(l, &t[i]);
}

static void
lpath(struct line *l, long p)
{
	char t[200];

	if (p < 4096) {
		lstr(l, "?");
		return;
	}
	strlcpy(t, (const char *)p, sizeof(t));
	lstr(l, t);
}

static void
laddr(struct line *l, const struct sockaddr *sa, long len)
{
	char host[INET6_ADDRSTRLEN];

	if ((long)sa < 4096 || len < 2) {
		lstr(l, "?");
		return;
	}
	switch (sa->sa_family) {
	case AF_INET: {
		const struct sockaddr_in *sin = (const void *)sa;

		inet_ntop(AF_INET, &sin->sin_addr, host, sizeof(host));
		lstr(l, host);
		lstr(l, ":");
		lnum(l, ntohs(sin->sin_port));
		break;
	}
	case AF_INET6: {
		const struct sockaddr_in6 *sin6 = (const void *)sa;

		inet_ntop(AF_INET6, &sin6->sin6_addr, host, sizeof(host));
		lstr(l, "[");
		lstr(l, host);
		lstr(l, "]:");
		lnum(l, ntohs(sin6->sin6_port));
		break;
	}
	case AF_UNIX:
		lstr(l, "unix:");
		lpath(l, (long)((const struct sockaddr_un *)sa)->sun_path);
		break;
	default:
		lstr(l, "family ");
		lnum(l, sa->sa_family);
	}
}

static void
lout(struct line *l)
{
	l->b[l->n++] = '\n';
	sys(SYS_write, logfd, (long)l->b, l->n);
}

static void
lhead(struct line *l, int from)
{
	l->n = 0;
	lstr(l, "sudtrace[");
	lnum(l, sys(SYS_getpid, 0, 0, 0));
	lstr(l, "] ");
	lstr(l, from_name[from]);
	lstr(l, from == FROM_LIBSYS ? ":  " : ": ");
}

static void
summary(void)
{
	struct line l;
	u_long tot[FROM_MAX] = { 0 }, best;
	int f, i, k, top;
	const char *name;

	for (f = 0; f < FROM_MAX; f++)
		for (i = 0; i < SYS_MAXSYSCALL; i++)
			tot[f] += counts[f][i];
	l.n = 0;
	lstr(&l, "sudtrace[");
	lnum(&l, sys(SYS_getpid, 0, 0, 0));
	lstr(&l, "] summary: ");
	lnum(&l, tot[FROM_LIBSYS]);
	lstr(&l, " via libsys (a libc hook can see these), ");
	lnum(&l, tot[FROM_PROGRAM] + tot[FROM_OTHER]);
	lstr(&l, " bypassing it (");
	lnum(&l, tot[FROM_PROGRAM]);
	lstr(&l, " from the program itself)");
	lout(&l);

	/* The most frequent system calls made by the program itself. */
	l.n = 0;
	lstr(&l, "sudtrace  program's own:");
	for (k = 0; k < 12; k++) {
		best = 0;
		top = -1;
		for (i = 0; i < SYS_MAXSYSCALL; i++)
			if (counts[FROM_PROGRAM][i] > best) {
				best = counts[FROM_PROGRAM][i];
				top = i;
			}
		if (top < 0)
			break;
		name = sysdecode_syscallname(SYSDECODE_ABI_FREEBSD, top);
		lstr(&l, " ");
		lstr(&l, name != NULL ? name : "?");
		lstr(&l, "=");
		lnum(&l, best);
		counts[FROM_PROGRAM][top] = 0;
	}
	lout(&l);
}

static void sud_enable(char *);

/* A new thread turns dispatch on for itself, then runs its real entry. */
static void
sud_thread_start(void *arg)
{
	u_int slot = (u_int)(uintptr_t)arg;

	sud_enable(&selectors[slot]);
	slots[slot].func(slots[slot].arg);
}

static void
sigsys(int sig, siginfo_t *si, void *ctx)
{
	ucontext_t *uc = ctx;
	mcontext_t *mc = &uc->uc_mcontext;
	struct sud_regs r = { mc->mc_rax, mc->mc_rdi, mc->mc_rsi, mc->mc_rdx,
	    mc->mc_r10, mc->mc_r8, mc->mc_r9, 0 };
	struct thr_param tp;
	struct line l;
	sigset_t old, *set;
	long nr = r.rax, a1 = r.rdi, a2 = r.rsi, a3 = r.rdx;
	int from, i;
	u_int slot;

	(void)sig;
	(void)si;
	/* syscall(2) and __syscall(2) pass the real number first. */
	if (nr == SYS_syscall || nr == SYS___syscall) {
		nr = a1;
		a1 = a2;
		a2 = a3;
		a3 = r.r10;
	}
	for (from = 0; from < FROM_OTHER; from++)
		if (mc->mc_rip >= (long)range_start[from] &&
		    mc->mc_rip < (long)range_end[from])
			break;
	if (nr >= 0 && nr < SYS_MAXSYSCALL)
		__atomic_add_fetch(&counts[from][nr], 1, __ATOMIC_RELAXED);

	lhead(&l, from);
	switch (nr) {
	case SYS_open:
	case SYS_openat:
		lstr(&l, nr == SYS_open ? "open(" : "openat(");
		lpath(&l, nr == SYS_open ? a1 : a2);
		lstr(&l, ")");
		break;
	case SYS_connect:
		lstr(&l, "connect(");
		laddr(&l, (const struct sockaddr *)a2, a3);
		lstr(&l, ")");
		break;
	case SYS_execve:
		lstr(&l, "execve(");
		lpath(&l, a1);
		lstr(&l, ")");
		lout(&l);
		l.n = 0;
		break;
	case SYS_exit:
		summary();
		l.n = 0;
		break;
	default:
		if (log_all) {
			const char *name = sysdecode_syscallname(
			    SYSDECODE_ABI_FREEBSD, nr);
			lstr(&l, name != NULL ? name : "?");
			lstr(&l, "()");
		} else
			l.n = 0;
	}

	/* System calls that must not simply run from the handler. */
	switch (nr) {
	case SYS_sigaltstack:
		/*
		 * The handler may be running on the alternate stack, where
		 * sigaltstack fails with EPERM.  syscall(2) reads its seventh
		 * argument from the stack, so only direct calls move.
		 */
		if (nr != (long)mc->mc_rax)
			break;
		mc->mc_rsp -= 128 + sizeof(long);
		*(long *)mc->mc_rsp = mc->mc_rip;
		mc->mc_rip = (long)sud_in_place;
		if (l.n != 0) {
			lstr(&l, " (run in place)");
			lout(&l);
		}
		return;
	case SYS_sigaction:
		/* Keep our SIGSYS handler; remember what the program wanted. */
		if (a1 == SIGSYS) {
			if (a3 != 0)
				*(struct sigaction *)a3 = app_sigsys;
			if (a2 != 0)
				app_sigsys = *(struct sigaction *)a2;
			r.rax = 0;
			goto done;
		}
		break;
	case SYS_sigprocmask:
		/*
		 * sigreturn will install uc_sigmask, so change that one, and
		 * never block SIGSYS: a blocked trap would kill the process.
		 */
		old = uc->uc_sigmask;
		set = (sigset_t *)a2;
		if (set != NULL) {
			for (i = 0; i < _SIG_WORDS; i++) {
				if (a1 == SIG_BLOCK)
					uc->uc_sigmask.__bits[i] |=
					    set->__bits[i];
				else if (a1 == SIG_UNBLOCK)
					uc->uc_sigmask.__bits[i] &=
					    ~set->__bits[i];
				else if (a1 == SIG_SETMASK)
					uc->uc_sigmask.__bits[i] =
					    set->__bits[i];
			}
			sigdelset(&uc->uc_sigmask, SIGSYS);
		}
		if (a3 != 0)
			*(sigset_t *)a3 = old;
		r.rax = 0;
		goto done;
	case SYS_setcontext:
		/* Load it through sigreturn, which restores the selector. */
		*uc = *(ucontext_t *)a1;
		sigdelset(&uc->uc_sigmask, SIGSYS);
		if (l.n != 0)
			lout(&l);
		return;
	case SYS_vfork:
		/* A vfork child would return through our shared stack. */
		r.rax = SYS_fork;
		break;
	case SYS_thr_new:
		/* Start the new thread in sud_thread_start. */
		slot = __atomic_fetch_add(&nslots, 1, __ATOMIC_RELAXED);
		if (slot < MAX_THREADS && (size_t)a2 <= sizeof(tp)) {
			memset(&tp, 0, sizeof(tp));
			memcpy(&tp, (void *)a1, a2);
			slots[slot].func = tp.start_func;
			slots[slot].arg = tp.arg;
			tp.start_func = sud_thread_start;
			tp.arg = (void *)(uintptr_t)slot;
			r.rdi = (long)&tp;
		}
		break;
	}
	sud_syscall(&r);
done:
	if (l.n != 0) {
		lstr(&l, " = ");
		lnum(&l, r.err ? -1 : r.rax);
		if (r.err) {
			lstr(&l, " errno ");
			lnum(&l, r.rax);
		}
		lout(&l);
	}
	mc->mc_rax = r.rax;
	mc->mc_rdx = r.rdx;
	if (r.err)
		mc->mc_rflags |= PSL_C;
	else
		mc->mc_rflags &= ~PSL_C;
}

/*
 * Unblock SIGSYS (rtld and libthr may hold every signal blocked here, and a
 * blocked trap kills the process), then trap the thread's system calls.
 */
static void
sud_enable(char *selector)
{
	struct procctl_syscall_dispatch sd;
	sigset_t set;

	sigemptyset(&set);
	sigaddset(&set, SIGSYS);
	sys(SYS_sigprocmask, SIG_UNBLOCK, (long)&set, 0);

	memset(&sd, 0, sizeof(sd));
	sd.sd_mode = PROC_SYSCALL_DISPATCH_ON;
	sd.sd_start = (uintptr_t)__start_sud_text;
	sd.sd_len = __stop_sud_text - __start_sud_text;
	sd.sd_selector = selector;
	*selector = PROC_SYSCALL_DISPATCH_BLOCK;
	sys4(SYS_procctl, P_PID, 0, PROC_SYSCALL_DISPATCH_CTL, (long)&sd);
}

static int
find_ranges(struct dl_phdr_info *info, size_t size, void *arg)
{
	int *first = arg, from, i;

	(void)size;
	if (*first) {
		from = FROM_PROGRAM;
		*first = 0;
	} else if (strstr(info->dlpi_name, "/libsys.so") != NULL)
		from = FROM_LIBSYS;
	else
		return (0);
	for (i = 0; i < info->dlpi_phnum; i++)
		if (info->dlpi_phdr[i].p_type == PT_LOAD &&
		    (info->dlpi_phdr[i].p_flags & PF_X) != 0) {
			range_start[from] = info->dlpi_addr +
			    info->dlpi_phdr[i].p_vaddr;
			range_end[from] = range_start[from] +
			    info->dlpi_phdr[i].p_memsz;
		}
	return (0);
}

static void __attribute__((constructor))
sudtrace_init(void)
{
	struct sigaction sa;
	const char *out;
	int first = 1;

	dl_iterate_phdr(find_ranges, &first);
	log_all = getenv("SUDTRACE_ALL") != NULL;
	out = getenv("SUDTRACE_OUT");
	if (out != NULL)
		logfd = sys4(SYS_openat, AT_FDCWD, (long)out,
		    O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (logfd < 0)
		logfd = sys(SYS_fcntl, STDERR_FILENO, F_DUPFD_CLOEXEC, 100);

	/* Straight to the kernel: libthr's sigaction would wrap the handler. */
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = sigsys;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sys(SYS_sigaction, SIGSYS, (long)&sa, 0);
	sud_enable(&selectors[0]);
}
