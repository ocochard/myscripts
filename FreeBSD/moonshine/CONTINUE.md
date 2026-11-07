# Continue prompt for next Claude session

Copy the block below verbatim into a fresh Claude session as the
first user message.

---

I'm continuing verification of a moonshine (Sunshine-alternative Moonlight
streaming host, FreeBSD port) bug fix. Full bug report:
`bigone:~/moonshine.bug.md` (also mirrored locally — ask to re-fetch via
`ssh bigone cat ~/moonshine.bug.md` if the mirror is stale).

## What was wrong

`moonshine`'s HTTP, HTTPS, and RTSP accept loops all propagated *any*
`listener.accept()` error with `?`, and each loop runs inside
`shutdown.wrap_trigger_shutdown(ShutdownReason::X, ...)` against a single
shared `ShutdownManager<ShutdownReason>`. So a single transient
`ECONNABORTED` ("Software caused connection abort", os error 53) — which
FreeBSD legitimately returns for a connection reset before `accept()`
completes (e.g. a port scan, or any half-open TCP attempt) — triggered a
**global** shutdown that killed the entire process, all three listeners
included. No crash supervision in `/usr/local/etc/rc.d/moonshine` means it
then stayed dead until someone manually ran `service moonshine start`.

This was the actual root cause of "macOS Moonlight client can't connect to
FreeBSD host over IPv6" — IPv6 bind itself was fine; the server was just
dying within seconds of any connection probe, including the client's own
handshake attempts.

Bad code (pre-fix), three call sites:
- `moonshine-core/src/webserver/mod.rs:178` (HTTP)
- `moonshine-core/src/webserver/mod.rs:264` (HTTPS)
- `moonshine-core/src/rtsp.rs:89` (RTSP)

Suggested fix (see bug report for full detail): on accept() error, log and
`continue` the loop instead of propagating with `?`. Only `bind()` errors
should be fatal.

## State as of last session

`bigone` (repo `~/moonshine`, branch `freebsd`, was at commit
`74a4d7bc2046e600681ae064be5ebf79487fb0d8`) was working on a fix. **Not
yet verified deployed.**

## What to do this session

1. Check whether the fix landed: `ssh bigone "cd ~/moonshine && git log --oneline -5"`
   and diff the three call sites above against the bug report's "bad code" snippet.
2. If fixed, rebuild on `bigone`:
   `RUSTFLAGS="-C link-arg=-L/usr/local/lib -C link-arg=-Wl,-rpath,/usr/local/lib" cargo build --release`
   from `~/moonshine` (native FreeBSD 16.0-CURRENT build host).
3. Deploy the new binary to `framework` (`ssh framework`, the FreeBSD 16.0-CURRENT
   box actually running the Sunshine-alternative host, IPv6
   `2a01:e0a:1092:3d20:dead:beef:0:7`, config
   `/usr/local/etc/moonshine/moonshine.toml`, log `/var/log/moonshine.log`,
   rc.d service name `moonshine`, requires `sudo` to `service moonshine start/stop`
   since the shell user `olivier` isn't root).
4. **Verify the fix actually holds under the exact repro that crashed it twice
   before:** start the service, then from this Mac immediately run
   `nmap -6 -Pn -p 47984,47989,48010 2a01:e0a:1092:3d20:dead:beef:0:7` and
   `curl -6 -vk --max-time 5 https://[2a01:e0a:1092:3d20:dead:beef:0:7]:47984/serverinfo`.
   Confirm via `tail -f /var/log/moonshine.log` on `framework` that an
   `ECONNABORTED`/accept error (if any occurs) is logged as a `WARN` and the
   process keeps running — no crash, no shutdown log line, service still
   `running` afterward (`service moonshine status`).
5. Only after that holds for several minutes of probing, do the actual
   end-to-end test: connect from the macOS Moonlight client
   (`/Applications/Moonlight.app/Contents/MacOS/Moonlight list --verbose
   2a01:e0a:1092:3d20:dead:beef:0:7`, then a real `stream` session against
   app "CWR-CE").
6. Also check the secondary finding in the bug report: `rc.d` has no
   crash-restart supervision (`daemon -r` or equivalent). Ask the user if
   they want that added as defense-in-depth even after the accept-loop fix.

## Rules / environment notes

- Don't push commits without explicit user approval.
- `bigone` = build host for the `freebsd` branch of `~/moonshine` (also
  builds `framework`'s kernel — `uname -a` on `framework` shows
  `root@bigone` as builder).
- `framework` = the actual FreeBSD 16.0-CURRENT host running the Sunshine
  server for streaming (this is what the Mac Moonlight client connects to).
  Do not confuse with `ser6`, which was the *previous* project's runtime
  test target for the unrelated `/launch` black-screen race work (see
  `STATE.md`/old `README.md` — that work is fully resolved and unrelated
  to this bug).
- SSH aliases: `ser6`'s config entry points at a stale IPv6 that currently
  times out — don't use it for this task. Use `framework` and `bigone`
  directly.
- `service moonshine start/stop/status` on `framework` needs `sudo` (plain
  `service` as `olivier` fails with `setrlimit: Operation not permitted`).
