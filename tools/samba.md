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

To solve MS Windows 11 problem to access to those share, open a powershell "Run as administrator":
```
Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -Force
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
```
[Microsoft guide to allow guest access on Windows 10 and 11](https://docs.microsoft.com/en-us/troubleshoot/windows-server/networking/guest-access-in-smb2-is-disabled-by-default)

## Filtering share by IPs

Declaring all shares availables for a list of host or subnets:
```
% cat /usr/local/etc/smb4_allowed_friends.conf
hosts allow = 127. ::1 10.10.10.0/25 172.16.10.0/24 192.168.10.0/24 192.168.1.0/24
```
Now in your smb.conf:
```
[sharename1]
  # shared with friends
  include = /usr/local/etc/smb4_allowed_friends.conf
[sharename2]
  # shared with friends
  include = /usr/local/etc/smb4_allowed_friends.conf
[sharename3]
  # not shared
  host allow = 127. ::1 192.168.1.0/24
```

## Windows 11 can't open a share: check for NTFS-forbidden chars in filenames

If a Windows 11 client fails to open a share with:
- Explorer: *"\\\\NAS\\<share> is not accessible. You might not have permission to use this network resource... The specified server cannot perform the requested operation."*
- `cmd: dir \\NAS\<share>` returns `File Not Found`

…but the same share works fine from `smbclient`, macOS, Linux, or older Windows versions, the cause is almost always **a single filename containing a character NTFS forbids**. When the Win11 SMB redirector enumerates the directory and hits such an entry, it aborts the entire listing instead of skipping it — the share looks empty / inaccessible to the user.

NTFS-forbidden filename characters: `" < > : | ? * \`

The connection itself succeeds — `smbstatus` will show the Win11 client tree-connected and holding an open lease on the share root — but no file operation follows because the directory enumeration failed client-side. The per-machine smbd log (`/var/log/samba4/log.<hostname>`) stays at 0 bytes for that reason.

### Diagnose

Search each writable share for forbidden chars:
```sh
find /NAS/<share> -regex '.*["<>:|?*\\].*' 2>/dev/null
```

Or for just the most common offender (double-quote):
```sh
find /NAS/<share> -name '*"*'
```

### Fix

Rename or delete each offending file. Example:
```sh
mv '/NAS/downloads/La physique de "Star Trek" ...epub' \
   "/NAS/downloads/La physique de 'Star Trek' ...epub"
```

### Prevent recurrence

Add a `veto files` rule to writable shares so Samba refuses to create files with NTFS-forbidden chars in the first place (this also hides any existing offenders from clients):

```ini
[downloads]
  path = /NAS/downloads
  writable = yes
  # Refuse to expose or create filenames containing NTFS-forbidden chars,
  # which silently break Win11 client directory enumeration.
  veto files = /*"*/*<*/*>*/*:*/*|*/*?*/*\**/
```

Note: `veto files` uses `/` as a separator between patterns; the `*` are glob wildcards, so `/*"*/` means "any name containing a double-quote". After editing, run `testparm` and `sudo service samba_server reload`.

### Red herrings to avoid

When diagnosing this, do **NOT** waste time on:
- `host msdfs = no` / DFS referrals
- `smb3 unix extensions = no`
- `hosts allow` IPv6 CIDR matching (`::/64` etc.)
- `veto files = /._*/.DS_Store/` for macOS metadata
- Clearing Win11 SMB caches (`net use * /delete`, `Stop-Service LanmanWorkstation`)
- Per-client privacy-IPv6 address mismatches

A `get_referred_path: |share| in dfs path \nas\share is not a dfs root` line in the smbd log is normal — Win11 always probes for DFS, and the "not a dfs root" response is correct and harmless.

**The signature that points to this bug specifically:** the share's per-machine smbd log shows the enumeration *completing* server-side (all entries returned via `smbd_dirptr_get_entry`), and `smbstatus` shows the client holding a live RH lease on the share root — yet the client reports failure.
