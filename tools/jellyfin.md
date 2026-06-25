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
service restart jellyfin

echo "Jellyfin SSL update complete!"

```

3. **Make it executable:**

```bash
sudo chmod +x /usr/local/bin/jellyfin-cert-renew.sh

```

*(Note: Run this script manually **once** right now to generate your very first `jellyfin.pfx` file).*

---

## Step 3: Automate with a Daily Cron Job

To ensure you never have to repeat this manually every 90 days, a daily cron job checks for expiration and runs your deployment script **only** when a renewal succeeds.

```bash
sudo mkdir -p /usr/local/etc/cron.d
echo "0 0 * * * root  certbot renew --quiet --no-self-upgrade --deploy-hook /usr/local/bin/jellyfin-cert-renew.sh" | sudo tee -a /usr/local/etc/cron.d/renew_certbot

```

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
