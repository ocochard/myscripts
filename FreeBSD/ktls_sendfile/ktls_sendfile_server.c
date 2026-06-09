/*
 * Minimal reproducer for FreeBSD 15.0 kTLS + sendfile corruption bug.
 *
 * Reported symptom (lighttpd 1.4.82, FreeBSD 15.0-RELEASE-p9, OpenSSL 3.x):
 *   Files larger than ~128 KiB served over HTTPS arrive corrupted on the
 *   client, while plain HTTP and HTTPS with KTLS disabled are fine.
 *   The server log shows:
 *     SSL: ... ssl_err:5 ret:-1 errno:35: Resource temporarily unavailable
 *
 * Strategy: do a TLS 1.3 handshake with OpenSSL, then call SSL_sendfile()
 * which transparently uses TCP_TXTLS_ENABLE + sendfile(2) when OpenSSL is
 * built with KTLS support (the case for FreeBSD's base libssl and the
 * security/openssl35 port).
 *
 * Usage:
 *   1. Generate a self-signed cert (once):
 *        openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
 *                    -days 1 -nodes -subj /CN=localhost
 *   2. Create a > 128 KiB test file:
 *        dd if=/dev/urandom of=test.bin bs=1m count=4
 *   3. Run the server (binds 0.0.0.0:4443 by default):
 *        ./ktls_sendfile_server -c cert.pem -k key.pem -f test.bin
 *   4. From a client (loop a few times, the corruption is intermittent):
 *        for i in $(jot 10); do
 *          curl -sk https://server:4443/ -o out.$i
 *          sha256 -q out.$i
 *        done
 *        sha256 -q test.bin
 *
 * Build:  make
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <unistd.h>

#include <openssl/ssl.h>
#include <openssl/err.h>

static void usage(void) {
	fprintf(stderr,
	    "Usage: ktls_sendfile_server -c cert.pem -k key.pem -f file "
	    "[-p port] [-n]\n"
	    "  -n  disable KTLS (for comparison)\n");
	exit(EX_USAGE);
}

static SSL_CTX *make_ctx(const char *cert, const char *key, int ktls) {
	SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
	if (!ctx)
		errx(1, "SSL_CTX_new");

	/* Force TLS 1.3 to match the user's report (mod_openssl default). */
	SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
	SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);

	if (ktls) {
		/* KTLS is opt-in in OpenSSL via SSL_OP_ENABLE_KTLS. */
		SSL_CTX_set_options(ctx, SSL_OP_ENABLE_KTLS);
	}

	if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) <= 0)
		errx(1, "load cert %s: %s", cert,
		    ERR_error_string(ERR_get_error(), NULL));
	if (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) <= 0)
		errx(1, "load key %s: %s", key,
		    ERR_error_string(ERR_get_error(), NULL));
	return ctx;
}

static int listen_on(int port) {
	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0)
		err(1, "socket");
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in sin = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_ANY),
		.sin_port = htons(port),
	};
	if (bind(s, (struct sockaddr *)&sin, sizeof(sin)) < 0)
		err(1, "bind :%d", port);
	if (listen(s, 16) < 0)
		err(1, "listen");
	return s;
}

/*
 * Read and discard the HTTP request (we don't actually care what was asked
 * for, we always serve the same file). Just consume up to the blank line.
 */
static void drain_request(SSL *ssl) {
	char buf[4096];
	int n;
	for (;;) {
		n = SSL_read(ssl, buf, sizeof(buf));
		if (n <= 0)
			return;
		if (memmem(buf, n, "\r\n\r\n", 4) || memmem(buf, n, "\n\n", 2))
			return;
	}
}

static void serve_one(SSL_CTX *ctx, int cs, const char *file) {
	SSL *ssl = SSL_new(ctx);
	if (!ssl) {
		close(cs);
		return;
	}
	SSL_set_fd(ssl, cs);

	if (SSL_accept(ssl) <= 0) {
		warnx("SSL_accept: %s",
		    ERR_error_string(ERR_get_error(), NULL));
		goto out;
	}

	/* Report whether KTLS was actually negotiated on the TX side. */
	int ktls_tx = BIO_get_ktls_send(SSL_get_wbio(ssl));
	fprintf(stderr, "connection: TLS=%s, cipher=%s, KTLS_TX=%s\n",
	    SSL_get_version(ssl), SSL_get_cipher(ssl),
	    ktls_tx ? "yes" : "no");

	drain_request(ssl);

	int fd = open(file, O_RDONLY);
	if (fd < 0) {
		warn("open %s", file);
		goto out;
	}
	struct stat st;
	if (fstat(fd, &st) < 0) {
		warn("fstat");
		close(fd);
		goto out;
	}

	/* Minimal HTTP/1.0 response so curl/fetch/wget are happy. */
	char hdr[256];
	int hlen = snprintf(hdr, sizeof(hdr),
	    "HTTP/1.0 200 OK\r\n"
	    "Content-Type: application/octet-stream\r\n"
	    "Content-Length: %lld\r\n"
	    "Connection: close\r\n"
	    "\r\n",
	    (long long)st.st_size);
	if (SSL_write(ssl, hdr, hlen) <= 0) {
		warnx("SSL_write header: %s",
		    ERR_error_string(ERR_get_error(), NULL));
		close(fd);
		goto out;
	}

	/*
	 * SSL_sendfile() requires KTLS_TX. When KTLS is active it dispatches
	 * to sendfile(2) under the hood; this is exactly the path lighttpd
	 * exercises and where the corruption is observed.
	 */
	off_t off = 0;
	size_t remaining = st.st_size;
	while (remaining > 0) {
		ossl_ssize_t sent;
		if (ktls_tx) {
			sent = SSL_sendfile(ssl, fd, off, remaining, 0);
		} else {
			/* Fallback path: plain SSL_write of file contents. */
			char buf[65536];
			ssize_t r = pread(fd, buf, sizeof(buf), off);
			if (r <= 0) {
				if (r < 0)
					warn("pread");
				break;
			}
			sent = SSL_write(ssl, buf, r);
		}
		if (sent <= 0) {
			int e = SSL_get_error(ssl, sent);
			warnx("send failed at off=%lld remaining=%zu: "
			    "ssl_err=%d errno=%d (%s)",
			    (long long)off, remaining, e, errno,
			    strerror(errno));
			break;
		}
		off += sent;
		remaining -= sent;
	}
	close(fd);

out:
	SSL_shutdown(ssl);
	SSL_free(ssl);
	close(cs);
}

int main(int argc, char **argv) {
	const char *cert = NULL, *key = NULL, *file = NULL;
	int port = 4443;
	int ktls = 1;
	int opt;

	while ((opt = getopt(argc, argv, "c:k:f:p:n")) != -1) {
		switch (opt) {
		case 'c': cert = optarg; break;
		case 'k': key = optarg; break;
		case 'f': file = optarg; break;
		case 'p': port = atoi(optarg); break;
		case 'n': ktls = 0; break;
		default: usage();
		}
	}
	if (!cert || !key || !file)
		usage();

	/* Avoid dying on client disconnects mid-write. */
	signal(SIGPIPE, SIG_IGN);

	SSL_CTX *ctx = make_ctx(cert, key, ktls);
	int ls = listen_on(port);
	fprintf(stderr, "listening on :%d (KTLS %s), serving %s\n",
	    port, ktls ? "enabled" : "disabled", file);

	for (;;) {
		int cs = accept(ls, NULL, NULL);
		if (cs < 0) {
			if (errno == EINTR)
				continue;
			err(1, "accept");
		}
		serve_one(ctx, cs, file);
	}
	/* NOTREACHED */
}
