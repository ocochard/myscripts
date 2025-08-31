# Samba

Install samba and wsdd (Web Service Discovery daemon, allowing Windows machine to detect it)
```
sudo pkg install samba420 net/py-wsdd
```

Setup guest unauthentitcated [samba doc](https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Standalone_Server):

```
mkdir /tmp/share
echo dummy > /tmp/share/dummy.txt
sudo chown -R nobody /tmp/share
cat <<'EOF' | sudo tee /usr/local/etc/smb4.conf
[global]
  map to guest = Bad User
  log file = /var/log/samba4/log.%m
  log level = 1
  server role = standalone server
  security = user

[guest]
  # This share allows anonymous (guest) read/write access without authentication
  path = /tmp/share
  read only = no
  guest ok = yes
  guest only = yes
EOF
```

Testing config:
```
testparm
```

Starting:
```
sudo service wsdd enable
sudo service wsdd start
sudo service samba_server enable
sudo service samba_server start
```

[Microsoft guide to allow guest access on Windows 10 and 11](https://docs.microsoft.com/en-us/troubleshoot/windows-server/networking/guest-access-in-smb2-is-disabled-by-default)
