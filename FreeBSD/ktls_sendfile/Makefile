# BSD make
PROG=		ktls_sendfile_server
SRCS=		ktls_sendfile_server.c
MAN=
WARNS?=		3

# Link against base OpenSSL (libssl/libcrypto in /usr/lib).
# To use security/openssl35 from ports instead, build with:
#   make CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
LDADD+=		-lssl -lcrypto

.include <bsd.prog.mk>

# Build the server and run the end-to-end repro script against it.
# Override knobs from the command line, e.g.:
#   make test ITERATIONS=200 SIZE_MB=8
#   make test KTLS=0                # control run with KTLS disabled
test: ${PROG}
	@sh ${.CURDIR}/ktls_sendfile_test.sh

