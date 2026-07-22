# Prompt for a Claude session on the Mac client

Copy the block below verbatim into a fresh Claude Code session on your
Mac. Its ONLY job is to run Moonlight-qt streaming attempts, capture
tcpdump pcaps and Moonlight-qt logs, and hand the raw artefacts back.
It is a data-collection worker, not a diagnostician. The analysis is
handled in the parallel session on the FreeBSD build host.

---

I'm the Mac client side of a FreeBSD moonshine-host debugging session.
I need you to run repeatable streaming tests against a paired host
(`Moonshine`) and collect raw artefacts (pcap + Moonlight-qt log +
Moonlight-qt config) for each run. Do NOT diagnose, tune, or theorize —
another session on the FreeBSD build host analyses the data. Just
execute the recipe below and package the results.

## Fixed context (don't rediscover)

- **Client app**: Moonlight-qt 6.1.0, launched via
  `/Applications/Moonlight.app/Contents/MacOS/Moonlight stream Moonshine "CWR-CE"`.
- **Route to host**: `netstat -rn -f inet6 | grep 2a01:e0a:1092`
  points to a point-to-point tunnel (last known: `utun4`, MTU 1280).
  If the interface name changed, note the new one and substitute
  it below. Verify once at the start of each session.
- **Host IPv6**: `2a01:e0a:1092:3d20:57da:3a10:3e7:ab33`. Ports:
  47989/tcp HTTP, 47984/tcp HTTPS, 48010/tcp RTSP, 47998/udp video,
  47999/udp control, 48000/udp audio.
- **Server is already running** on `ser6` — don't try to ssh there,
  restart it, or touch its config. If the server side needs a
  change, the FreeBSD session will handle it out-of-band and tell you
  to retry.
- **Moonlight-qt config** lives at
  `~/Library/Preferences/com.moonlight-stream.Moonlight.plist`. Read
  with `defaults read com.moonlight-stream.Moonlight` (do NOT `defaults
  delete` — that wipes pairing state).

## The recipe per run

Each "run" produces four artefacts. Do this exactly:

1. **Capture Moonlight-qt config before the run:**
   ```
   defaults read com.moonlight-stream.Moonlight > /tmp/mac-run-<label>-prefs.txt
   ```
   Substitute `<label>` with something descriptive: `baseline`,
   `packet900`, `packet700`, `h264`, `bitrate2m`, etc.

2. **Arm client-side tcpdump** (this needs `sudo`; assume you're
   in a Terminal with credentials cached):
   ```
   sudo pkill -f "tcpdump.*47998" 2>/dev/null; true
   sudo tcpdump -i utun4 -n -tttt -vv -s 0 \
       -w /tmp/mac-run-<label>.pcap \
       'udp and (port 47998 or port 47999 or port 48000)' &
   sleep 1
   ```

3. **Trigger the stream** and let it run 30 seconds. Terminate
   with Ctrl-C on the Moonlight process (or wait for its auto
   disconnect on failure — usually ~18 seconds):
   ```
   /Applications/Moonlight.app/Contents/MacOS/Moonlight stream Moonshine "CWR-CE"
   ```
   Keep an eye on stdout — Moonlight prints the SDL/Qt log inline
   and also writes it to a file.

4. **Stop tcpdump:**
   ```
   sudo pkill -f "tcpdump.*47998"; true
   ```

5. **Locate the Moonlight-qt log file** written for this run:
   ```
   ls -tr /tmp/Moonlight-*.log | tail -1
   ```
   Copy it to a labelled path:
   ```
   cp "$(ls -tr /tmp/Moonlight-*.log | tail -1)" /tmp/mac-run-<label>.log
   ```

6. **Quick sanity numbers** to include in your report back — do NOT
   interpret them, just report:
   ```
   echo "=== $label pcap length histogram ==="
   sudo tcpdump -r /tmp/mac-run-<label>.pcap -nn 2>/dev/null | \
     grep -oE "length [0-9]+" | sort -n | uniq -c | sort -rn | head
   echo "=== $label packet counts by 5-tuple ==="
   sudo tcpdump -r /tmp/mac-run-<label>.pcap -nn 2>/dev/null | \
     awk '/^[0-9]/ {for(i=1;i<=NF;i++)if($i==">"){print $(i-1)" -> "$(i+1)}}' | \
       sed 's/[0-9]*:$//' | sort | uniq -c | sort -rn | head
   echo "=== $label first + last packet timestamps ==="
   sudo tcpdump -r /tmp/mac-run-<label>.pcap -nn -tttt 2>/dev/null | (head -1; tail -1)
   echo "=== $label Moonlight-qt log key lines ==="
   grep -E "first (audio|video) packet|IDR frame request|Terminating|No video|UDP port|Connection terminated|Video stream is|Interface MTU|Found matching interface" /tmp/mac-run-<label>.log
   ```

## Which runs to do

Do these in order and STOP after the first one that succeeds
(defined as: `first video packet` line in the Moonlight-qt log, and
inbound 1000+ byte packets in the pcap from ser6's IPv6):

| label | change to make in Moonlight settings before run |
|---|---|
| `baseline` | nothing — reproduce today's failure |
| `packet900` | Advanced → "Custom video packet size" = 900 (or plist equivalent) |
| `packet700` | Custom video packet size = 700 |
| `h264` | Video codec preference = H.264 (with packet size reset to default) |
| `bitrate2m` | Bitrate = 2 Mbps (with packet size reset to default) |

If none of the above make video packets arrive on utun4, add:

| label | change |
|---|---|
| `dual-pcap` | Same as baseline, but run TWO tcpdumps concurrently — one on `utun4`, one on the underlying WAN interface (find it: `route get default` → look at "interface"). This will tell us whether encrypted WG packets are arriving on the outer interface but the tunnel isn't decrypting/emitting them on utun4. |

## How to change Moonlight-qt settings

Prefer the UI (Settings gear icon → Advanced). If a setting isn't
exposed in the UI, use `defaults write` and restart Moonlight:

```
defaults write com.moonlight-stream.Moonlight <key> <value>
```

Common keys to look for (may differ per build — grep the plist
first):
- `videoPacketSize` (bytes; default 1024)
- `videoCodecConfig` (0=auto, 1=H.264, 2=HEVC, 3=AV1)
- `bitrate` (kbps)

Do NOT modify the paired-host state or clear any cert-related keys.

## When you're done

Bundle everything into one directory and let me know:
```
mkdir -p /tmp/mac-run-bundle
cp /tmp/mac-run-*.pcap /tmp/mac-run-*.log /tmp/mac-run-*-prefs.txt \
   /tmp/mac-run-bundle/ 2>/dev/null
ls -la /tmp/mac-run-bundle
```

Then tell the FreeBSD session what's in `/tmp/mac-run-bundle` — file
sizes, labels, and any inline output from step 6 for each run. I'll
transfer the bundle over (either `scp` from FreeBSD or you upload
somewhere). Do NOT try to draw conclusions yourself: just report
"here's what I captured, here's the Moonlight-qt Qt/SDL log summary,
here's the pcap histogram." I'll interpret.

## What NOT to do

- Don't `ssh` to `ser6` or any other host.
- Don't recompile/rebuild anything.
- Don't `defaults delete` any Moonlight keys (breaks pairing).
- Don't clear `/tmp/Moonlight-*.log` files — they're time-stamped
  and older ones might still be useful.
- Don't run Moonlight from anywhere other than the .app bundle
  (its plist keying is bundle-id specific).
