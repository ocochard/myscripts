# KTLS + sendfile corruption reproducer (FreeBSD 15.0)

Minimal C reproducer for a corruption bug reported against FreeBSD 15.0 when
serving static files larger than ~128 KiB over HTTPS with kTLS-accelerated
`sendfile(2)`. Originally seen with `lighttpd 1.4.82 + mod_openssl`
(both base OpenSSL 3.5.4 and ports `security/openssl35` 3.5.6 affected).
FreeBSD 14.4 is reportedly **not** affected; lighttpd with `mod_wolfssl` is
also not affected.

Bug: https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=295942

Server log signature when it goes wrong:

```
SSL: ... ssl_err:5 ret:-1 errno:35: Resource temporarily unavailable
```

The bug is triggered when `SSL_sendfile()` (which uses `sendfile(2)` on a
socket with `TCP_TXTLS_ENABLE`) returns a short / failed write and the
application's resume path produces a TLS record whose plaintext does not
match what was on disk — client-side `sha256` of the downloaded file then
differs from the source file.

The reproducer is a deliberately tiny TLS 1.3 server (~200 lines) that
mirrors what `lighttpd`'s static-file path does: TLS handshake → enable
KTLS_TX → `SSL_sendfile()` the file → close.

## Build

```sh
cd FreeBSD/ktls_sendfile
make
```

Uses BSD `make` and the base OpenSSL in `/usr/lib`. To link against
`security/openssl35` from ports instead:

```sh
make CFLAGS="-I/usr/local/include" \
     LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
```

## Run

The quickest way is `make test`, which builds the server and then runs
`ktls_sendfile_test.sh` against it (self-signed cert + 4 MiB random file
+ 50 curl fetches, exits non-zero on any hash mismatch):

```sh
make test                          # default: 50 iterations, 4 MiB, KTLS on
make test ITERATIONS=200 SIZE_MB=8 # tweak the workload
make test KTLS=0                   # control run, KTLS disabled
```

Or drive it by hand:

```sh
# 1. self-signed cert
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
            -days 1 -nodes -subj /CN=localhost

# 2. > 128 KiB test file (random data so any single-bit corruption
#    will show up in the hash)
dd if=/dev/urandom of=test.bin bs=1m count=4

# 3. expected hash
sha256 -q test.bin > test.bin.sha256

# 4. start the server (KTLS enabled by default)
./ktls_sendfile_server -c cert.pem -k key.pem -f test.bin

# 5. from another shell, hammer it and look for mismatches:
EXPECT=$(cat test.bin.sha256)
for i in $(jot 50); do
    curl -sk https://server:4443/ -o out.bin
    GOT=$(sha256 -q out.bin)
    [ "$GOT" = "$EXPECT" ] || echo "MISMATCH on attempt $i: $GOT"
done
```

The server prints `KTLS_TX=yes` per connection when the kernel actually
took over the TX path. If it prints `KTLS_TX=no`, the kernel refused KTLS
(check `sysctl kern.ipc.tls.enable` and the cipher) — in that case the
test is meaningless.

## Verification: disable KTLS

Re-run with `-n` to force the OpenSSL software path (no `sendfile`, no
`TCP_TXTLS_ENABLE`). The mismatches should disappear:

```sh
./ktls_sendfile_server -n -c cert.pem -k key.pem -f test.bin
```

This is the equivalent of the reported lighttpd workaround:

```
ssl.openssl.ssl-conf-cmd += ("Options" => "-KTLS")
```

## Cross-check matrix from the original report

| OS / SSL                     | mod          | result   |
|------------------------------|--------------|----------|
| 14.4-RELEASE-p5 / openssl35  | mod_openssl  | OK       |
| 15.0-RELEASE-p9 / openssl35  | mod_openssl  | BROKEN   |
| 15.0-RELEASE-p9 / base       | mod_openssl  | BROKEN   |
| 15.0-RELEASE-p9 / openssl35  | mod_wolfssl  | OK       |

`sysctl kern.ipc.tls.stats` on the broken host shows non-zero
`ocf.tls13_gcm_encrypts` and `ocf.separate_output`, confirming the SW KTLS
path is in use (no NIC offload involved — `igb(4)` does not advertise
`TXTLS4`).
