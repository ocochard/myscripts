# ipmitool

## Access

If ipmi drivers loaded, just run ipmitool, so it will use the SMBus channel:
```
# ipmitool channel info
Channel 0x4 info:
  Channel Medium Type   : SMBus v2.0
  Channel Protocol Type : IPMI-SMBus
  Session Support       : session-less
  Active Session Count  : 0
  Protocol Vendor ID    : 7154
```
If not, need to known IP, login and password, so it will use the 802.3 LAN channel:
```
$ ipmitool -H 172.16.16.16 -U admin -P admin -I lanplus channel info
Channel 0x8 info:
  Channel Medium Type   : 802.3 LAN
  Channel Protocol Type : IPMB-1.0
  Session Support       : multi-session
  Active Session Count  : 1
  Protocol Vendor ID    : 7154
  Volatile(active) Settings
    Alerting            : enabled
    Per-message Auth    : disabled
    User Level Auth     : enabled
    Access Mode         : always available
  Non-Volatile Settings
    Alerting            : enabled
    Per-message Auth    : disabled
    User Level Auth     : enabled
    Access Mode         : always available
```
On this output we get the channel number (8) assigned to this LAN interface.

## IP address

Display existing IPv4 setup on channel 8:
```
$ ipmitool lan print 8
(etc.)
IP Address Source       : DHCP Address
(etc.
```
Here, it get its IP by DHCP.

Display existing IPv6 setup:
```
$ ipmitool lan6 print
(etc.)
IPv6 Static Address 0:
    Enabled:        no
(etc.)
IPv6 Dynamic Address 0:
    Source/Type:    SLAAC
    Address:        xxxx:xxxx:yyyy:xxxx:x::y/64
(etc.)
IPv6 Static Router 1:
    Address: ::
    MAC:     00:00:00:00:00:00
    Prefix:  ::/0
(etc.)
IPv6 Dynamic Router 0:
    Address: xxx:xxx:xxx:xxx:xxx
    MAC:     yy:yy:yy:yy:yy
    Prefix:  xxx:xxxx:xxx::/64
```

Here it is SLAAC retreived.
To configure a static IPv6 (using the static address entry 0) on our LAN interface (channel 8 in our case):
```
ipmitool lan6 set 8 nolock static_addr 0 enable xxx:xxxx:xxxx:xxx::yyyy 64
```

To configure a DHCP client on channel 1:
```
ipmitool lan set 1 ipsrc dhcp
```

## Users

Display the user list:
```
$ ipmitool user list
ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
1                    false   false      false      NO ACCESS
2   admin            false   false      true       ADMINISTRATOR
3                    true    false      false      NO ACCESS
4                    true    false      false      NO ACCESS
5                    true    false      false      NO ACCESS
6                    true    false      false      NO ACCESS
7                    true    false      false      NO ACCESS
8                    true    false      false      NO ACCESS
9                    true    false      false      NO ACCESS
10                   true    false      false      NO ACCESS
11                   true    false      false      NO ACCESS
12                   true    false      false      NO ACCESS
13                   true    false      false      NO ACCESS
14                   true    false      false      NO ACCESS
15                   true    false      false      NO ACCESS
```

Create a new user, set its password and enable it, here on the list the ID 3 is free:

```
$ ipmitool user set name 3 username
$ ipmitool user set password 3 password
$ ipmitool user enable 3
```

But we need to set some privilege too, but warning they need to be assigned to a specific
channel too.
If the LAN interface used is channel 8, then set admin privilege (0x4) for this user (id 3):
```
$ ipmitool user priv 3 0x4 8
```
But this is not enough: If trying to log into the WebUI or remotely using ipmitoo using this new
credentials, it will be refused.
We need to set authorization (access) permission on the LAN channel, for this specific user:
```
$ ipmitool channel setaccess 8 4 callin=o ipmi=on link=on
```
