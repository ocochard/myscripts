### Description

`lib/route_types.h` is generated with the list of daemons enabled at configure time, but its make rule does not depend on that list:

```make
# lib/subdir.am
lib/route_types.h: $(top_srcdir)/lib/route_types.txt $(top_srcdir)/lib/route_types.pl
	@$(MKDIR_P) lib
	$(PERL) $(top_srcdir)/lib/route_types.pl $(rt_enabled) < $(top_srcdir)/lib/route_types.txt > $@
```

`$(rt_enabled)` comes from the `--enable-<daemon>` options, so re-running `./configure` with a different daemon set in an existing build tree leaves `route_types.h` untouched. The `FRR_REDIST_STR_*` / `FRR_REDIST_HELP_STR_*` macros keep the old daemon list, and the rebuilt daemons and vtysh reject `redistribute <newly enabled protocol>` as an unknown command.

### Version

```text
master (7fca281997)
```

### How to reproduce

1. Configure and build without sharpd: `./configure ... && make`
2. In the same tree, reconfigure with sharpd and rebuild: `./configure ... --enable-sharpd && make && make install`
3. `grep -A1 'define FRR_REDIST_STR_BGPD' lib/route_types.h` shows no `sharp`.
4. Load a config containing:
   ```
   router bgp 1001
    address-family ipv4 unicast
     redistribute sharp
   ```

### Expected behavior

`route_types.h` is regenerated when the enabled daemon set changes, and `redistribute sharp` is accepted.

### Actual behavior

```
line 785: % Unknown command[31]:    redistribute sharp
[...|bgpd] Configuration file[/usr/local/etc/frr/frr.conf] processing failure: 2
```

sharpd itself is built, installed and runs, so the failure is easy to misread. In our case it surfaced as the zebra_nhg_check topotest failing with "Failed to install expected IPv4 routes: got 0, expected 2000", because bgpd never redistributed the sharp routes.

Workaround: `rm lib/route_types.h` before rebuilding.

### Additional context

Seen on FreeBSD 16.0-CURRENT with GNU make, but the rule is platform independent. A possible fix is to make the target depend on something that changes with the configure options (e.g. `config.status`, or a stamp file written only when the `$(rt_enabled)` value changes, to avoid rebuilding everything on every reconfigure).

The hosttools copy (`$(MAKE) -C $(top_builddir)/hosttools lib/route_types.h`) uses the same rule and probably has the same issue when cross-compiling.

### Checklist

- [x] I have searched the open issues for this bug.
- [x] I have not included sensitive information in this report.
