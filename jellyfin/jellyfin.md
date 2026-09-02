# Jellyfin and certbot

Here is a Jellyfin SSL setup example.

---

## The Overview

Because Jellyfin requires a **PKCS#12 (`.pfx`)** format and Certbot generates **PEM** files, the architecture relies on an automated script to handle the translation every time the certificate renews.

---

## Step 1: The Initial Certificate Generation

You used Certbot’s standalone mode to validate your subdomain and save the base certificates to your FreeBSD/custom path system.

```bash
sudo certbot certonly --standalone -d jelly.home.com

```

* **Result:** Your keys were saved to `/usr/local/etc/letsencrypt/live/jelly.home.com/`

---

## Step 2: Create the Automation & Renewal Script

To bridge the gap between Certbot and Jellyfin, you created a deployment script.

1. **File Path:** `/usr/local/bin/jellyfin-cert-renew.sh`
2. **Script Content:**

```bash
#!/bin/sh

TARGET_DIR="/var/lib/jellyfin"
LE_DIR="/usr/local/etc/letsencrypt/live/jelly.home.com"
PASSWORD="your_secure_password" # Replace with your actual password

echo "Processing certificate for Jellyfin..."

mkdir -p $TARGET_DIR

# 1. Convert PEM files to a single PFX file using the custom password
openssl pkcs12 -export \
  -out "$TARGET_DIR/jellyfin.pfx" \
  -inkey "$LE_DIR/privkey.pem" \
  -in "$LE_DIR/fullchain.pem" \
  -passout pass:"$PASSWORD"

# 2. Fix permissions so the jellyfin service user can read it
chown jellyfin:jellyfin "$TARGET_DIR/jellyfin.pfx"

# 3. Restart Jellyfin to apply changes
service jellyfin restart

echo "Jellyfin SSL update complete!"

```

3. **Make it executable:**

```bash
sudo chmod +x /usr/local/bin/jellyfin-cert-renew.sh

```

*(Note: Run this script manually **once** right now to generate your very first `jellyfin.pfx` file).*

---

## Step 3: Automate with a Cron Job

`certbot renew` is a no-op until the certificate is inside its renewal window, so it is safe to run on a schedule. It runs the deployment script only when a renewal actually succeeds.

Register the hook once in the renewal config rather than passing it on every command line. Certbot then applies it to every renewal, including ones you run by hand:

```
# /usr/local/etc/letsencrypt/renewal/nas.cochard.me.conf, under [renewalparams]
renew_hook = /usr/local/bin/jellyfin-cert-renew.sh
```

With that in place the cron line carries no `--deploy-hook`:

```bash
sudo mkdir -p /usr/local/etc/cron.d
sudo tee /usr/local/etc/cron.d/jellyfin_certbot >/dev/null <<'EOF'
# Renew LE cert for nas.cochard.me; renew_hook in the renewal conf rebuilds jellyfin.pfx.
# Twice daily at a randomized minute, per Let's Encrypt guidance (no midnight thundering herd).
23 3,15 * * * root /usr/local/bin/certbot renew --quiet --preferred-chain "ISRG Root X1"
EOF
sudo chmod 644 /usr/local/etc/cron.d/jellyfin_certbot
```

Notes on the details, all verified on nas with certbot 4.2.0:

- **`--no-self-upgrade` is gone.** It was a `certbot-auto` flag and appears zero times in `certbot --help all`. Modern certbot tolerates it silently, so it looks like it works. Leave it out.
- **Twice daily, jittered.** Let's Encrypt asks clients not to converge on the top of the hour. Certbot additionally applies its own random delay of up to ten minutes on non-interactive runs, so a renewal that seems to hang for several minutes is normal:
  ```
  INFO:certbot._internal.renewal:Non-interactive renewal: random delay of 335.0503709871323 seconds
  ```
- **The filename has no dot.** Cron skips `cron.d` entries whose names look like backup files.

FreeBSD's cron does read this directory, with a user field in each line (`man 8 cron`, "`/usr/local/etc/cron.d` Directory for third-party package provided crontab files"). Since a misplaced file fails silently, confirm execution with a throwaway probe rather than assuming:

```bash
echo "* * * * * root /usr/bin/touch /tmp/cron_probe" | sudo tee /usr/local/etc/cron.d/zzprobe
sudo chmod 644 /usr/local/etc/cron.d/zzprobe
sleep 95; ls -l /tmp/cron_probe          # should exist, owned by root
sudo rm -f /usr/local/etc/cron.d/zzprobe /tmp/cron_probe
```

Verify the real job is wired end to end. `--dry-run` hits the staging server and does not run deploy hooks "unless enabled by `--run-deploy-hooks`", so it will not restart Jellyfin:

```bash
sudo certbot renew --dry-run
sudo openssl x509 -in /usr/local/etc/letsencrypt/live/nas.cochard.me/fullchain.pem -noout -enddate
```

---

## Warning: TV devices may reject the newer Let's Encrypt chain

Let's Encrypt's newer hierarchy roots at `ISRG Root X2`, which is **not in the trust store of most TV firmware** (LG, Samsung, older Android TV builds). The Jellyfin app on those devices fails to connect with an SSL error even though the certificate is perfectly valid in browsers and on phones.

**Symptom:** The Jellyfin TV app cannot connect when the address is entered manually, while the same address works fine in a browser or on a phone.

**Verify what is actually on the wire.** Inspect the served chain, not the file on disk, because the two differ here (see below):

```bash
echo | openssl s_client -connect nas.cochard.me:8920 -showcerts 2>/dev/null \
  | awk '/^ [0-9]+ s:/{print} /^   i:/{print}'
```

### `--preferred-chain` alone does not fix this

The obvious fix is to ask for the chain that terminates at the older root, which TVs have trusted since 2021:

```bash
sudo certbot renew --force-renewal --preferred-chain "ISRG Root X1"
```

That flag works, but it does not survive contact with Jellyfin. Measured on nas 2026-09-02 with an ECDSA certificate, certbot selected a four-certificate chain:

```
leaf -> YE1 -> Root YE -> ISRG Root X2 (cross-signed) -> ISRG Root X1
```

`jellyfin.pfx` contains all four. Jellyfin serves only three:

```
0 s:CN=nas.cochard.me    i:CN=YE1
1 s:CN=YE1               i:CN=Root YE
2 s:CN=Root YE           i:CN=ISRG Root X2      <- last one sent
```

The certificate it drops is exactly the X2-cross-signed-by-X1 bridge, the one that makes X1 trust work at all. Kestrel builds its own chain and stops once it reaches a certificate that is a trusted root in the host store, and `ISRG Root X2` is one. A TV that trusts X1 but not X2 therefore receives a chain ending at an issuer it does not have, with no path back to X1. The flag is silently neutralized.

Note also that `--preferred-chain` fails soft by design: "If no match, the default offered chain will be used." A successful certbot run is not evidence that you got the chain you asked for. Always check the wire.

### What to do instead

Reissue with an RSA key. The RSA hierarchy chains to `ISRG Root X1` directly, so there is no cross-sign for Kestrel to truncate, and old firmware handles RSA more reliably than ECDSA regardless.

```bash
# in /usr/local/etc/letsencrypt/renewal/nas.cochard.me.conf, under [renewalparams]
key_type = rsa

sudo certbot renew --force-renewal --preferred-chain "ISRG Root X1"
```

Then confirm on the wire that the last certificate sent is issued by `ISRG Root X1`, and only then retest the TV app. Keep `--preferred-chain "ISRG Root X1"` in the cron line either way so the choice survives future renewals.

Rate limit: Let's Encrypt allows 5 duplicate certificates per week for the same set of names. Verify the served chain after each attempt rather than reissuing speculatively.

---

## Step 4: Configure the Jellyfin Web UI

With the `.pfx` file successfully created at `/var/lib/jellyfin/jellyfin.pfx`, you input these settings into your Jellyfin Dashboard:

1. Navigate to **Dashboard -> Networking -> Secure Connection Settings**.
2. Check **Enable HTTPS**.
3. **Custom certificate path:** `/var/lib/jellyfin/jellyfin.pfx`
4. **Certificate password:** `your_secure_password` *(the one inside your script)*.
5. Save and restart Jellyfin.

---

## Step 5: Verification

You verified from your remote CLI that everything is secure and listening:

```bash
openssl s_client -connect jelly.home.com:8920

```

> **Status:** Verified! Handshake completes cleanly, showing the Let's Encrypt issuer and your exact `jelly.home.com` domain.

---

# Hardware Transcoding (VA-API on FreeBSD with AMD GPU)

## Log locations

| Path | Contents |
|------|----------|
| `/var/db/jellyfin/log/log_YYYYMMDD.log` | Main application log |
| `/var/db/jellyfin/log/FFmpeg.Transcode-*.log` | FFmpeg transcoding jobs |
| `/var/db/jellyfin/log/FFmpeg.Remux-*.log` | FFmpeg remux jobs |
| `/var/db/jellyfin/log/FFmpeg.DirectStream-*.log` | FFmpeg direct stream jobs |

Jellyfin process (not in a jail):
```
/usr/local/jellyfin/jellyfin --datadir /var/db/jellyfin --cachedir /var/cache/jellyfin
```

## Diagnosing playback failures

Check today's log for errors, optionally filtering by username:
```bash
grep -E '\[(ERR|WRN)\]' /var/db/jellyfin/log/log_$(date +%Y%m%d).log | tail -50
grep -i 'lulu' /var/db/jellyfin/log/log_$(date +%Y%m%d).log | tail -50
```

Check the most recent FFmpeg transcode logs:
```bash
ls -t /var/db/jellyfin/log/FFmpeg.Transcode-*.log | head -5 | xargs tail -30
```

## Symptom: LibraryMonitor "Error watching path" — inotify watch leak

All libraries stop auto-detecting new media. In the main log, every library path fails at once, repeatedly (seen at 05:19, 17:20, 05:21 on consecutive days):

```
[ERR] Emby.Server.Implementations.IO.LibraryMonitor: Error watching path: "/NAS/films"
System.IO.IOException: The configured user limit on the number of inotify instances
has been reached, or the per-process limit on the number of open file descriptors
has been reached.
   at System.IO.FileSystemWatcher.StartRaisingEvents()
```

**The message is accurate, not Linux boilerplate.** FreeBSD 15+ has native inotify (`vfs.inotify.*`), and .NET's `FileSystemWatcher` uses it.

### Diagnose

```bash
sysctl vfs.inotify.watches vfs.inotify.max_user_watches
```

If `watches` equals `max_user_watches`, the table is saturated. Compare against how many directories actually exist:

```bash
find /NAS -type d | wc -l
```

Observed on nas 2026-08-24: **362,766 watches consumed, cap 362,766, but only 47,474 directories exist** — and Jellyfin's healthy steady state is only ~20,335 (it skips non-media trees like a large Calibre library). It had accumulated ~18× its own working set.

Rule out the other candidates the exception mentions:

```bash
# fd limit — not the cause if these are far apart
sudo procstat -l $(pgrep -x jellyfin) | grep openfiles   # 922554
sudo procstat -f $(pgrep -x jellyfin) | wc -l            # 820
```

kqueue/`EVFILT_VNODE` on the media paths is unaffected and will test fine; the failure is purely watch-table exhaustion.

### The leak is per-scan, not per-day

The count does not creep upward with time. It steps by one full watch set every time LibraryMonitor tears down and re-arms its watches, which is what a library scan does. The "Stopping directory watching" pass never releases the old inotify watches, so each scan strands another complete set.

Measured on nas 2026-09-02, immediately after a restart:

```
09:02:53  first arm                                  20339 watches   (1.00 sets)
09:04:42  "Stopping directory watching" (scan start)
09:05:47  re-arm, "Scan Media Library" completed
09:06:35  stable                                     40668 watches   (2.00 sets)
```

Exactly 2x the baseline, and flat between scans. The earlier observations fit the same pattern: 241,489 watches is 11.9 sets, 362,766 is 17.8 sets.

The practical consequence is that the budget is counted in scans, not in days:

```
1000000 / 20334 = ~49 scans before exhaustion
```

At the observed rate of roughly 2.6 scans per day (the nightly 05:20 scan plus ad-hoc ones), that is about 19 days between restarts. Anything that triggers extra scans shortens it proportionally.

### Fix

Restarting releases the leaked watches:

```bash
sudo service jellyfin restart
sysctl vfs.inotify.watches      # 241489 -> 20339
```

This is a recovery, not a cure. The cap is already raised in `/etc/sysctl.conf` (a runtime tunable, no boot risk):

```
vfs.inotify.max_user_watches=1000000
```

Check the current consumption in sets rather than raw watches, since the set size is what makes the number meaningful:

```bash
echo "scale=2; $(sysctl -n vfs.inotify.watches)/20334" | bc
```

### Workaround: threshold-triggered restart

Because the leak advances per scan rather than per day, a fixed restart schedule either fires too often or too late. Check the watch count instead and restart only when it approaches the cap and nothing is playing.

`/usr/local/bin/jellyfin-watch-watchdog.sh`:

```sh
#!/bin/sh
# Restart Jellyfin when its leaked inotify watches approach the cap.
# The leak steps one ~20.3k set per library scan, so trigger on the count, not a schedule.

THRESHOLD=500000        # ~25 leaked sets, half of vfs.inotify.max_user_watches

watches=$(sysctl -n vfs.inotify.watches)
[ "$watches" -lt "$THRESHOLD" ] && exit 0

# Never cut an in-flight stream: ffmpeg runs as a child of jellyfin.
# No children means nothing is transcoding or remuxing; retry on the next run otherwise.
pid=$(pgrep -x jellyfin) || exit 0
pgrep -P "$pid" >/dev/null 2>&1 && exit 0

logger -t jellyfin-watchdog "inotify watches $watches >= $THRESHOLD, restarting jellyfin"
service jellyfin restart
logger -t jellyfin-watchdog "watches now $(sysctl -n vfs.inotify.watches)"
```

Install it and run it hourly:

```bash
sudo chmod +x /usr/local/bin/jellyfin-watch-watchdog.sh
echo "0 * * * * root /usr/local/bin/jellyfin-watch-watchdog.sh" \
  | sudo tee -a /usr/local/etc/cron.d/jellyfin_watchdog
```

At 500,000 the threshold leaves roughly 24 spare sets of headroom, so a run that keeps deferring because something is always playing still has days of margin before watches actually run out.

Verify it fired:

```bash
grep jellyfin-watchdog /var/log/messages
```

---

## Symptom: Dynamic Image Provider error

In the Jellyfin main log (`log_YYYYMMDD.log`):
```
[ERR] MediaBrowser.Providers.Folders.CollectionFolderMetadataService: Error in "Dynamic Image Provider"
```

This error fires when Jellyfin tries to render a library thumbnail (collection folder image). It has two distinct root causes, both present on a fresh FreeBSD install. Apply both fixes.

### Fix 1 — missing fonts

The image renderer calls `SKTypeface.FromFamilyName("sans-serif")` via SkiaSharp. With no fonts registered in fontconfig the typeface lookup returns `null`, which surfaces as:
```
System.ArgumentNullException: Value cannot be null. (Parameter 'typeface')
   at SkiaSharp.HarfBuzz.SKShaper..ctor(SKTypeface typeface)
```

Install the DejaVu font package:
```bash
pkg install dejavu
sudo fc-cache -fv
```

Verify:
```bash
fc-list | grep -i dejavu
```

### Fix 2 — missing libHarfBuzzSharp native library

Even with fonts installed, `SKShaper` tries to load `libHarfBuzzSharp.so` (the HarfBuzz C-API bridge used by the .NET HarfBuzzSharp wrapper). The Jellyfin FreeBSD package does not ship this library and there is no separate port for it. The standard system `libharfbuzz.so` exports the same symbols, so a symlink is sufficient:

```bash
ln -sf /usr/local/lib/libharfbuzz.so /usr/local/jellyfin/libHarfBuzzSharp.so
```

This error surfaces as:
```
System.DllNotFoundException: Unable to load shared library 'libHarfBuzzSharp' or one of its dependencies.
   at HarfBuzzSharp.HarfBuzzApi.hb_blob_create(...)
   at SkiaSharp.HarfBuzz.SKShaper..ctor(SKTypeface typeface)
```

Note: the symlink lives inside `/usr/local/jellyfin/` which is managed by the `jellyfin` package. It will be lost if `pkg upgrade jellyfin` replaces that directory. Re-create it after upgrades.

### Apply both fixes

```bash
pkg install dejavu
sudo fc-cache -fv
ln -sf /usr/local/lib/libharfbuzz.so /usr/local/jellyfin/libHarfBuzzSharp.so
service jellyfin restart
```

Then trigger **Dashboard → Libraries → Scan All Libraries** and verify no more errors:
```bash
tail -f /var/db/jellyfin/log/log_$(date +%Y%m%d).log | grep --line-buffered -E 'Dynamic Image|ERR'
```

---

## Symptom: FFmpeg exits with code 234 — hardware upload failure

In the Jellyfin main log (`log_YYYYMMDD.log`):
```
MediaBrowser.Common.FfmpegException: FFmpeg exited with code 234
```

In the FFmpeg transcode log (`FFmpeg.Transcode-*.log`):
```
[hwupload @ 0x...] A hardware device reference is required to upload frames to.
[AVFilterGraph @ 0x...] Error initializing filters
Error opening output files: Invalid argument
```

When testing the FFmpeg command manually with `-vaapi_device`:
```
[VAAPI @ 0x...] No VA display found for device /dev/dri/renderD128.
Device creation failed: -22.
Failed to set value '/dev/dri/renderD128' for option 'vaapi_device': Invalid argument
```

**Cause:** VA-API hardware acceleration is enabled in Jellyfin but the userspace Mesa driver is missing or misconfigured. Jellyfin silently fails to validate the device at startup and omits `-vaapi_device` from all FFmpeg commands.

**Working FFmpeg command (after fix):**
```
"ffmpeg" "-analyzeduration 200M ... -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va -hwaccel vaapi ... -codec:v:0 h264_vaapi ..."
```
```
FFmpeg exited with code 0
```

The key difference is `-init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va` appearing in the command — Jellyfin only injects this when it successfully validated the device at startup.

## Required packages (FreeBSD)

```bash
pkg install mesa-dri libva libva-utils
```

- `mesa-dri`: provides `radeonsi_drv_video.so` — the actual VA-API driver for AMD GPUs
- `libva`: VA-API wrapper
- `libva-utils`: provides `vainfo` to verify GPU codec support

## Verify VA-API works

```bash
sudo env LIBVA_DRIVERS_PATH=/usr/local/lib/dri LIBVA_DRIVER_NAME=radeonsi \
    vainfo --display drm --device /dev/drm/128
```

Expected output for AMD Radeon 780M (Phoenix/Hawk Point):
```
VAProfileH264ConstrainedBaseline:  VAEntrypointVLD + VAEntrypointEncSlice
VAProfileH264Main:                 VAEntrypointVLD + VAEntrypointEncSlice
VAProfileH264High:                 VAEntrypointVLD + VAEntrypointEncSlice
VAProfileHEVCMain:                 VAEntrypointVLD + VAEntrypointEncSlice
VAProfileHEVCMain10:               VAEntrypointVLD + VAEntrypointEncSlice  (10-bit HDR)
VAProfileAV1Profile0:              VAEntrypointVLD + VAEntrypointEncSlice
VAProfileVP9Profile0/2:            VAEntrypointVLD (decode only)
VAProfileJPEGBaseline:             VAEntrypointVLD (decode only)
```

## Permissions

- `/dev/drm/128` (symlinked as `/dev/dri/renderD128`) must be owned `root:video`, mode `crw-rw----`
- The `jellyfin` user must be in the `video` group:
  ```bash
  pw groupshow video        # verify
  pw groupmod video -m jellyfin  # add if missing
  ```

## Configure Jellyfin

In **Admin → Dashboard → Playback → Transcoding**:
- Hardware acceleration: **VA-API**
- VA-API device: `/dev/dri/renderD128`
- Enable H264, HEVC, AV1 hardware decode/encode checkboxes

## Required environment variables for Jellyfin service

Without `LIBVA_DRIVER_NAME=radeonsi`, libva cannot auto-detect the driver. Jellyfin will silently fail to open the VA-API device at startup and will omit `-vaapi_device` from all FFmpeg commands, causing the same `hwupload` error even after `mesa-dri` is installed.

Add to `/etc/rc.conf`:
```
jellyfin_env="LIBVA_DRIVERS_PATH=/usr/local/lib/dri LIBVA_DRIVER_NAME=radeonsi"
```

Then restart:
```bash
service jellyfin restart
```

Confirm it worked — the log should show on startup:
```
VAAPI device "/dev/dri/renderD128" is AMD GPU
```

---

# Jellyfin API with curl

## Extract an access token

Jellyfin tokens are stored in its SQLite database. The quickest way to grab one (pick any recent session):

```bash
sqlite3 /var/db/jellyfin/data/jellyfin.db \
  'SELECT AccessToken, DeviceName, DateCreated FROM Devices ORDER BY DateCreated DESC LIMIT 5'
```

## Using the API

All API calls require the `Authorization` header with a `MediaBrowser Token=` prefix. Jellyfin redirects HTTP (port 8096) to HTTPS (port 8920); use `-sk` to follow redirects and skip certificate verification when calling from localhost:

```bash
TOKEN="9fc8945e60464fcd95bc3bc880be8ef2"

# List scheduled tasks
curl -sk "https://localhost:8920/ScheduledTasks" \
  -H "Authorization: MediaBrowser Token=${TOKEN}"

# Find the ID of a specific task (example: Scan Media Library)
curl -sk "https://localhost:8920/ScheduledTasks" \
  -H "Authorization: MediaBrowser Token=${TOKEN}" \
  | tr '{' '\n' | grep -i 'scan media'

# Run a scheduled task by ID
curl -sk -X POST "https://localhost:8920/ScheduledTasks/Running/<task-id>" \
  -H "Authorization: MediaBrowser Token=${TOKEN}"

# Trigger a full library refresh (equivalent to Dashboard → Libraries → Scan All)
curl -sk -X POST "https://localhost:8920/Library/Refresh" \
  -H "Authorization: MediaBrowser Token=${TOKEN}"
```

Scan Media Library task ID (stable across restarts): `7738148ffcd07979c7ceb148e06b3aed`
