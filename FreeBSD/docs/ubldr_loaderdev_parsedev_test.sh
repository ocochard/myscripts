#!/bin/sh
# Feed ubldr's get_load_device() arguments to the real disk_parsedev() of
# three revisions, compiled for the host.  The byte before loaderdev is set
# to 0 and then to 'Z', since p - 4 reads it for 3-letter device types.
#
#   ./ubldr_loaderdev_parsedev_test.sh [freebsd-src-git-dir]
set -eu

SRC=${1:-$HOME/freebsd-official/src}
REVS="33bbe5ddcbbc d18ed8e19c3c d687c9fc7efe"
W=$(mktemp -d /tmp/ubldr-parse.XXXXXX)
trap 'rm -rf "$W"' EXIT

cat > "$W/common.h" <<'EOF'
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define LOADER_GPT_SUPPORT
#define LOADER_MBR_SUPPORT
#define EUNIT 1001
#define ESLICE 1002
#define EPART 1003
#define D_SLICEWILD -1
#define D_SLICENONE -2
#define D_PARTWILD -1
#define D_PARTNONE -2
#define D_PARTISGPT 255
struct devdesc { int d_unit; };
struct disk_devdesc { struct devdesc dd; int d_slice, d_partition; };
typedef int (*pf)(struct devdesc **, const char *, const char **);
EOF

echo '#include "common.h"' > "$W/parsers.c"
for r in $REVS; do
	git -C "$SRC" show "$r:stand/common/disk.c" |
	    awk '/^disk_parsedev\(/,/^}/' |
	    sed "s/^disk_parsedev(/int parse_$r(/" >> "$W/parsers.c"
done

{
	echo '#include "common.h"'
	for r in $REVS; do echo "int parse_$r(struct devdesc **, const char *, const char **);"; done
	echo 'static const struct { const char *n; pf f; } revs[] = {'
	for r in $REVS; do echo "	{ \"$r\", parse_$r },"; done
	cat <<'EOF'
};
/* Prefixes from ubldr's device_types[]: 4-letter and 3-letter. */
static const char *typ[] = { "disk", "sata", "mmc" };

static void
run(pf f, const char *spec)
{
	struct devdesc *d;
	int e;

	if ((e = f(&d, spec, NULL)) == 0) {
		printf("OK unit=%d slice=%d", d->d_unit,
		    ((struct disk_devdesc *)d)->d_slice);
		free(d);
	} else
		printf("error %d", e);
}

int
main(void)
{
	for (size_t t = 0; t < nitems(typ); t++)
	for (int z = 0; z < 2; z++)
	for (size_t r = 0; r < nitems(revs); r++) {
		char buf[32];
		char *devstr = buf + 1;
		const char *p;

		buf[0] = z ? 'Z' : '\0';
		snprintf(devstr, sizeof(buf) - 1, "%s0p2", typ[t]);
		p = devstr + strlen(typ[t]);	/* as get_device_type() */
		printf("%-8s byte[-1]=%-3s %s  p - 4: ", devstr,
		    z ? "'Z'" : "0", revs[r].n);
		run(revs[r].f, p - 4);
		printf("  | devstr: ");
		run(revs[r].f, devstr);
		printf("\n");
	}
	return (0);
}
EOF
} > "$W/h.c"
sed -i '' '1a\
#define nitems(x) (sizeof(x) / sizeof((x)[0]))
' "$W/h.c"

cc -Wall -Wno-unused-variable -o "$W/h" "$W/h.c" "$W/parsers.c"
"$W/h"
