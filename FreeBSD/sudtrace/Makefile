# BSD make.  The kernel needs procctl_syscall_dispatch.patch (FreeBSD/docs).
CFLAGS+=	-O2 -Wall -Wextra -fPIC

all: sudtrace.so hooktrace.so

# -z now: bind everything at load time, so the SIGSYS handler never enters
# the run-time linker (which may hold its lock when it makes a syscall).
sudtrace.so: sudtrace.c
	${CC} ${CFLAGS} -shared -Wl,-z,now -o ${.TARGET} sudtrace.c -lsysdecode

hooktrace.so: hooktrace.c
	${CC} ${CFLAGS} -shared -o ${.TARGET} hooktrace.c

clean:
	rm -f sudtrace.so hooktrace.so
