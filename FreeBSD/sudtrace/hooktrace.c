/*
 * hooktrace: the classic LD_PRELOAD approach, for comparison with sudtrace.
 * It replaces the libc functions connect(), open(), openat() and execve()
 * and logs each call.  A program that makes these system calls without
 * going through libc (Go programs, static binaries) is invisible to it.
 *
 * LD_PRELOAD=./hooktrace.so program [args]
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

static void
log_addr(const char *fn, const struct sockaddr *sa)
{
	char host[INET6_ADDRSTRLEN] = "?";
	int port = 0;

	if (sa->sa_family == AF_INET) {
		const struct sockaddr_in *sin = (const void *)sa;
		inet_ntop(AF_INET, &sin->sin_addr, host, sizeof(host));
		port = ntohs(sin->sin_port);
	} else if (sa->sa_family == AF_INET6) {
		const struct sockaddr_in6 *sin6 = (const void *)sa;
		inet_ntop(AF_INET6, &sin6->sin6_addr, host, sizeof(host));
		port = ntohs(sin6->sin6_port);
	}
	dprintf(STDERR_FILENO, "hooktrace[%d] %s(%s:%d)\n", getpid(), fn, host,
	    port);
}

int
connect(int s, const struct sockaddr *sa, socklen_t len)
{
	static int (*real)(int, const struct sockaddr *, socklen_t);

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "connect");
	log_addr("connect", sa);
	return (real(s, sa, len));
}

int
open(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, ...);
	va_list ap;
	int mode;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "open");
	va_start(ap, flags);
	mode = (flags & O_CREAT) ? va_arg(ap, int) : 0;
	va_end(ap);
	dprintf(STDERR_FILENO, "hooktrace[%d] open(%s)\n", getpid(), path);
	return (real(path, flags, mode));
}

int
openat(int fd, const char *path, int flags, ...)
{
	static int (*real)(int, const char *, int, ...);
	va_list ap;
	int mode;

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "openat");
	va_start(ap, flags);
	mode = (flags & O_CREAT) ? va_arg(ap, int) : 0;
	va_end(ap);
	dprintf(STDERR_FILENO, "hooktrace[%d] openat(%s)\n", getpid(), path);
	return (real(fd, path, flags, mode));
}

int
execve(const char *path, char *const argv[], char *const envp[])
{
	static int (*real)(const char *, char *const[], char *const[]);

	if (real == NULL)
		real = dlsym(RTLD_NEXT, "execve");
	dprintf(STDERR_FILENO, "hooktrace[%d] execve(%s)\n", getpid(), path);
	return (real(path, argv, envp));
}
