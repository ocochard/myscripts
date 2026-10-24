# Home Assistant

## Restore a backup on a fresh install (Raspberry Pi, HAOS)

1. Flash HAOS, boot the Pi: it gets a temporary DHCP address.
2. Open `http://<dhcp-ip>:8123` and, on the onboarding screen, choose
   "Restore from backup" and upload the backup file.
3. The restore page will very likely stop updating ("no reply") while
   Home Assistant restarts with the restored config. This is not a failure.
   Check the real state:
   ```
   curl -s http://<dhcp-ip>:4357/ | grep -A3 -E 'Supervisor|Health'   # observer: Connected / Healthy
   curl -s -o /dev/null -w '%{http_code}\n' http://<dhcp-ip>:8123/api/            # 401 => Core running
   curl -s http://<dhcp-ip>:8123/api/onboarding                                   # 404 => restored instance
   ```
4. Open a new tab (or Ctrl+Shift+R) on `http://<dhcp-ip>:8123` and log in
   with the account from the **old** installation (the account created
   during onboarding is gone).
5. Set the definitive IP: Settings => System => Network.
   Then update anything pointing at the old address (ESPHome, MQTT clients,
   webhooks, mobile app URL) and keep the old Pi powered off so both
   instances don't fight over the same devices.
