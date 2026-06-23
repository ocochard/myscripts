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
