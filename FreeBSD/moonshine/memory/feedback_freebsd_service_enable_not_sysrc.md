---
name: freebsd-service-enable-not-sysrc
description: "On modern FreeBSD, the idiomatic way to enable an rc service is `service <name> enable`, not `sysrc <name>_enable=YES`. Both write the same rc.conf line, but `service enable` is the documented user-facing command and works even when the rc script has quirks the user shouldn't need to know."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f3e4c030-b385-40b6-994b-1c49dba1ffa4
  modified: 2026-07-24T01:18:45.473Z
---

**Rule:** when telling a user (or writing docs / error hints / pkg-messages)
how to enable an rc.d service on FreeBSD, use:

```
service <name> enable
service <name> start
```

**Not:**

```
sysrc <name>_enable=YES
service <name> start
```

**Why:** both end up writing the same line to `/etc/rc.conf`, but
`service <name> enable` is FreeBSD's documented user-facing idiom.
It also handles the case where an rc script's `_enable` variable
name doesn't follow the exact `<name>_enable` convention (rare
but happens), and it's discoverable via `service --help`. The
`sysrc` habit is more common in Linux-migrant blog posts and
throws FreeBSD-idiomatic users off.

`sysrc` is still the right tool for **writing arbitrary rc.conf
key/value pairs that aren't service enable/disable flags** (e.g.
`hostname=`, `ifconfig_XXX=`, `firewall_type=`). Use `service ...
enable`/`disable` specifically for the `<name>_enable=YES/NO`
key, and `sysrc` for everything else.

**How to apply:** any documentation, error hint, port pkg-message,
memory, or advice that instructs the user to enable an rc service
should use `service <name> enable`. Tripped on 2026-07-24 in
moonshine's OSS-capture error hint (`virtual_oss` unavailable),
where I originally wrote `sysrc virtual_oss_enable=YES` — user
corrected.
