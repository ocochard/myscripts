# monit

## Example of usage

4 hosts doing burn test using stress-ng (CPU) and GravityMark (GPU).
- Need to peer-to-peer check their availability between them
- Check that burn processes are running
- Check that system temperature greater than 70°C
- Send alert message using to [telegram shell script](telegram.sh)

```
sudo apt install -y monit
sudo systemctl enable monit --now
wget https://raw.githubusercontent.com/ocochard/myscripts/refs/heads/master/tools/telegram.sh
sudo mv telegram.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/telegram.sh
cat <<EOF > /etc/tg.creds
TG_BOT_TOKEN="xxx"
TG_CHAT_ID="yyy"
EOF
sudo chmod 600 /etc/tg.creds
sudo telegram.sh sendMessage "test message from host1"
cat <<'EOF' | sudo tee /usr/local/bin/monit_temp.sh
#!/bin/sh
# Return true if temperature less than 70°C
temp=$(sysctl -n dev.amdtemp.0.core0.sensor0 | tr -dc '0-9.')
threshold=70
if [ $(echo "$temp > $threshold" | bc) -eq 1 ]; then
    exit 1
else
    exit 0
fi
EOF
chmod +x  /usr/local/bin/monit_temp.sh
cat <<EOF | sudo tee /etc/monit/conf.d/p2p
check program temperature with path /usr/local/bin/monit_temp.sh
    if status != 0 then alert
check process stress-ng matching "stress-ng"
  if not exist then exec "/usr/local/bin/telegram.sh sendMessage 'host1: stress-ng crashed'"
check process GravityMark matching GravityMark.x64
  if not exist then exec "/usr/local/bin/telegram.sh sendMessage 'host1: GravityMark crashed'"
check host host2 with address 192.168.1.2
  if failed ping count 2 size 64 with timeout 10 seconds for 4 cycles then exec "/usr/local/bin/telegram.sh sendMessage 'host2 unreachable from host1'"
check host host3 with address 192.168.1.3
  if failed ping count 2 size 64 with timeout 10 seconds for 4 cycles then exec "/usr/local/bin/telegram.sh sendMessage 'host3 unreachable from host1'"
check host host4 with address 192.168.1.4
  if failed ping count 2 size 64 with timeout 10 seconds for 4 cycles then exec "/usr/local/bin/telegram.sh sendMessage 'host4 unreachable from host1'"
EOF
sudo monit reload
cat /var/log/monit.log
```
