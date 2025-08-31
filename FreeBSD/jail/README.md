# Jails

## Null-fs jail

Lightest jail:
- Use same base as host by read-only nullfs mounting
- Use unionfs for read-write directory
- A base.txz from your running release (to extract only its /etc)

### File sharing

Example by read-only host file directory using:
- Authenticated HTTP access (.htaccess database)
- SFTP/SCP access (unix passwd)
- Host’s directory to be shared: /srv/data

Start to populate the jail’s directories and a default configuration files:
```
sudo mkdir -p /usr/jails/share
cd /usr/jails/share
sudo mkdir -p dev root bin sbin lib libexec usr/bin usr/libdata usr/share \
      usr/libexec usr/sbin usr/local usr/include usr/lib srv/data
fetch -o /tmp/base.txz https://download.freebsd.org/snapshots/$(uname -p)/$(uname -r)/base.txz
sudo tar -xvf /tmp/base.txz -C /usr/jails/share etc
```

Then the jail’s configuration file:
```
cat <<'EOF' | sudo tee /etc/jail.conf.d/share.conf
share {
    jid = 1;
    path          = "/usr/jails/$name";
    mount.devfs;
    mount.fstab   = "/etc/jail.conf.d/$name.fstab";
    devfs_ruleset = 4;
    host.hostname = "$name";
    allow.chflags = 1;
    exec.start    = "/bin/sh /etc/rc";
    exec.stop     = "/bin/sh /etc/rc.shutdown";
    exec.clean;
    exec.consolelog = "/var/log/jail.$name";
    exec.poststop  = "logger poststop jail $name";
    # Commands to run on host before jail is created
    exec.prestart  = "logger pre-starting jail $name";
    allow.raw_sockets;
    ip4 = inherit;
    ip6 = inherit;
    exec.prestart  += "logger jail $name pre-started";
    exec.poststop  += "umount /usr/jails/$name/dev";
    exec.poststop  += "umount -a -F /etc/jail.conf.d/$name.fstab";
    exec.poststop  += "jail -r 1";
    exec.poststop  += "logger jail $name post-stopped";
}
EOF

Now need to populate the jail’s fstab to instruct to:
- Use unionfs in below mode for read-write directories
- Use nullfs for read-only
```
cat <<'EOF' | sudo tee /etc/jail.conf.d/share.fstab
/root /usr/jails/share/root unionfs rw,below,noatime 0 0
/bin /usr/jails/share/bin nullfs ro 0 0
/sbin /usr/jails/share/sbin nullfs ro 0 0
/lib /usr/jails/share/lib nullfs ro 0 0
/libexec /usr/jails/share/libexec nullfs ro 0 0
/usr/bin /usr/jails/share/usr/bin nullfs ro 0 0
/usr/libdata /usr/jails/share/usr/libdata nullfs ro 0 0
/usr/share /usr/jails/share/usr/share nullfs ro 0 0
/usr/libexec /usr/jails/share/usr/libexec nullfs ro 0 0
/usr/sbin /usr/jails/share/usr/sbin nullfs ro 0 0
/usr/local /usr/jails/share/usr/local unionfs rw,below,noatime 0 0
/usr/include /usr/jails/share/usr/include nullfs ro 0 0
/usr/lib /usr/jails/share/usr/lib nullfs ro 0 0
/srv/data /usr/jails/share/srv/data nullfs ro 0 0
EOF
```

Now we can configure this jail with minimum setup:
```
(echo hostname=share;echo sshd_enable=yes;echo sshd_flags="-p 9022") | sudo tee /usr/jails/share/etc/rc.conf
```

And start it:
```
sudo service jail enable
sudo service jail start share
```
