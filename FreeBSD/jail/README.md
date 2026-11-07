# Jails

## Null-fs jail

Lightest jail:
- Use same base as host by read-only nullfs mounting
- Use unionfs for read-write directory
- A base.txz from your running release (to extract only its /etc)

### Example: Simple HTTP/SCP file sharing

Here is an example of read-only sharing host’s directories:
- SFTP/SCP access (unix passwd database)
- Existing host’s directory to be shared: /srv/data

Start to populate the jail’s directories and the default configuration files:
```
sudo mkdir -p /usr/jails/share
cd /usr/jails/share
sudo mkdir -p dev root bin sbin lib libexec usr/bin usr/libdata usr/share \
      usr/libexec usr/sbin usr/local usr/include usr/lib tmp srv/data
sudo chmod 777 tmp
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

Now we can configure the minimal jail’rc.conf:
```
echo hostname=share | sudo tee /usr/jails/share/etc/rc.conf
```

And start it:
```
sudo service jail enable
sudo sysrc jail_list+=share
sudo service jail start
```

Then log into the jail to finish its configuration:
- Replace the sshd sftp subsystem by internal version
- Configure sshd to chroot all users that belong to group 'sftp' in the shared dir
- Create one user to test this setup

```
sudo service jail console share
service sshd enable
sysrc sshd_flags="-p 8022"
sed -i '' 's|/usr/libexec/sftp-server|'
cat <<EOF >>/etc/ssh/sshd_config
Match Group sftp
    ForceCommand internal-sftp
    ChrootDirectory /srv/data
EOF
service sshd start
adduser -D -g sftp -s nologin -w random
pw groupadd -n sftp
pw useradd -n jdoe -c "John Doe" -d /srv/data -s /usr/sbin/nologin -g sftp -w random
```

And testing it (forcing password here):
```
sftp -P 8022 -o "PreferredAuthentications=keyboard-interactive,password" jdoe@localhost
```

### Example: NETINT Quadra card in a jail

Same light jail as above. The jail sees the host's `/usr/local` through
unionfs, so `libxcoder`, `ffmpeg-netint` and Python are already there: nothing
to install in the jail. Not tested on hardware yet: the points marked
*(to verify)* are expectations.

On the host, make the card's device nodes group-readable (see
`FreeBSD/netint_demo/README.md`: `/etc/devfs.conf` sets `nvme1` and `nvme1n1`
to `root:video`, mode 0660), then a devfs ruleset that unhides only the card
in the jail:
```
cat <<'EOF2' | sudo tee -a /etc/devfs.rules
[devfsrules_netint_jail=100]
add include $devfsrules_hide_all
add include $devfsrules_unhide_basic
add include $devfsrules_unhide_login
add path 'nvme1' unhide
add path 'nvme1n1' unhide
EOF2
sudo service devfs restart
```

Directories and `/etc/jail.conf.d/netint.conf` as for the `share` jail, with
`devfs_ruleset = 100;` instead of 4, no `allow.raw_sockets`, and these two
extra directories for the demo (`mkdir -p usr/jails/netint/opt/demo/videos`):
```
cat <<'EOF2' | sudo tee /etc/jail.conf.d/netint.fstab
/root /usr/jails/netint/root unionfs rw,below,noatime 0 0
/bin /usr/jails/netint/bin nullfs ro 0 0
/sbin /usr/jails/netint/sbin nullfs ro 0 0
/lib /usr/jails/netint/lib nullfs ro 0 0
/libexec /usr/jails/netint/libexec nullfs ro 0 0
/usr/bin /usr/jails/netint/usr/bin nullfs ro 0 0
/usr/libdata /usr/jails/netint/usr/libdata nullfs ro 0 0
/usr/share /usr/jails/netint/usr/share nullfs ro 0 0
/usr/libexec /usr/jails/netint/usr/libexec nullfs ro 0 0
/usr/sbin /usr/jails/netint/usr/sbin nullfs ro 0 0
/usr/local /usr/jails/netint/usr/local unionfs rw,below,noatime 0 0
/usr/include /usr/jails/netint/usr/include nullfs ro 0 0
/usr/lib /usr/jails/netint/usr/lib nullfs ro 0 0
/home/olivier/netint_demo /usr/jails/netint/opt/demo nullfs ro 0 0
/home/olivier/netint_demo/videos /usr/jails/netint/opt/demo/videos nullfs ro 0 0
EOF2
```

Inside the jail, the user needs the host's `video` gid (44 in the base
system, so the jail's `/etc/group` already has it):
```
sudo jexec netint pw useradd -n olivier -u 1001 -G video -s /bin/sh -m
sudo jexec netint su -m olivier -c 'ni_rsrc_list | head'
sudo jexec netint su -m olivier -c 'cd /opt/demo && DEMO_HLS=/tmp/hls python3 -I server.py'
```

Things to check, in this order:
- `ni_rsrc_list` works in the jail (devices visible, NVMe ioctls allowed).
  The ioctls are not known to need any `allow.*` parameter *(to verify)*.
- **Shared state with the host.** libxcoder keeps its locks in `/tmp`
  (`NI_LCK_*`, per jail here because the jail has its own `/tmp`) and its
  resource table in POSIX shared memory (`/NI_SHM_CODERS`, `/NI_shm_*`).
  Whether the shm names are shared between host and jail is *(to verify)*:
  `posixshmcontrol ls` on the host while a jail process runs. If they are
  shared while the locks are not, a host process and a jail process can
  corrupt each other's accounting of the card. Safe rule: use the card from
  one place at a time, or share the lock directory by adding
  `/tmp /usr/jails/netint/tmp nullfs rw 0 0` to the fstab.
- Stale host objects: root-owned `/NI_*` shm objects left by earlier root
  runs block an unprivileged jail user the same way they block the host user.
