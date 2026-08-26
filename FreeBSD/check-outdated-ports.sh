#!/bin/sh
#
# check-outdated-ports.sh
#
# List FreeBSD ports maintained by a given e-mail that are behind upstream,
# using the Repology aggregator API (one request, no per-upstream dispatch).
#
# Repology already tracks 40+ package repos, normalizes versions, and computes
# a per-repo status (newest/devel/outdated/...). We ask it directly:
#   "which freebsd ports maintained by <email> are outdated?"
# then reconcile each hit against the local ports tree, so ports already bumped
# locally (but not yet reflected on Repology) are not re-flagged.
#
# Equivalent web view:
#   https://repology.org/projects/?maintainer=<email>&inrepo=freebsd&outdated=on
#
# Requires: curl, jq, make, and a local ports checkout at $PORTSDIR.
#
# Usage:
#   check-outdated-ports.sh                 # default maintainer: olivier@FreeBSD.org
#   check-outdated-ports.sh some@maint.tld
#   check-outdated-ports.sh -v              # also list ports already bumped locally
#
# Environment:
#   PORTSDIR   ports tree root (default: /home/olivier/freebsd-official/ports)

set -u

VERBOSE=0
case "${1:-}" in
	-v) VERBOSE=1; shift ;;
esac

MAINTAINER="${1:-olivier@FreeBSD.org}"
PORTSDIR="${PORTSDIR:-/home/olivier/freebsd-official/ports}"

# Repology API terms require bulk clients to identify themselves with a custom
# User-Agent linking to a source repo + issue tracker. Miscomplying clients are
# blocked. This script makes a single request, well under the 1 req/s limit.
UA="check-outdated-ports.sh (+https://github.com/ocochard/xxx)"
API="https://repology.org/api/v1/projects/"

for tool in curl jq make; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: $tool not in PATH" >&2
		exit 1
	fi
done

if [ ! -d "$PORTSDIR" ]; then
	echo "error: PORTSDIR not found: $PORTSDIR" >&2
	exit 1
fi

# URL-encode the '@' in the maintainer address (lowercased for the query).
enc=$(printf '%s' "$MAINTAINER" | tr 'A-Z' 'a-z' | sed 's/@/%40/g')

echo "==> querying Repology for outdated freebsd ports maintained by $MAINTAINER"
json=$(curl -sf -A "$UA" \
	"${API}?inrepo=freebsd&maintainer=${enc}&outdated=1" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$json" ]; then
	echo "error: Repology request failed (network, rate-limit, or bad maintainer)" >&2
	exit 1
fi

nproj=$(printf '%s' "$json" | jq 'length' 2>/dev/null)
case "$nproj" in
	''|null) echo "error: unexpected response from Repology" >&2; exit 1 ;;
	0) echo "    nothing outdated on Repology for $MAINTAINER"; exit 0 ;;
esac

if [ "$nproj" -eq 200 ]; then
	echo "    warning: hit the 200-project API cap; results may be truncated" >&2
	echo "    (pagination not implemented -- unlikely to matter for one maintainer)" >&2
fi

# Extract one TSV row per project:
#   origin \t repology_freebsd_ver \t newest_versions \t devel_versions
# newest/devel are comma-joined uniques across all repos carrying that status.
tsv=$(printf '%s' "$json" | jq -r '
	to_entries[]
	| (.value[] | select(.repo=="freebsd")) as $fb
	| ([.value[] | select(.status=="newest") | .version] | unique) as $newest
	| ([.value[] | select(.status=="devel")  | .version] | unique) as $devel
	| [ ($fb.srcname // "?"),
	    ($fb.version // "?"),
	    ($newest | join(",")),
	    ($devel  | join(",")) ]
	| @tsv
')

outdated=""
bumped=""
judgment=""
missing=""

# Read TSV; IFS=tab so version strings keep their spaces intact.
oldifs=$IFS
IFS='	'
while read -r origin fbver newest devel; do
	[ -z "$origin" ] && continue

	# Pick the upstream target: prefer "newest", fall back to "devel".
	src="newest"
	target="$newest"
	if [ -z "$target" ]; then
		src="devel"
		target="$devel"
	fi
	[ -z "$target" ] && target="$fbver"   # last resort: whatever Repology saw

	# Local version wins over Repology's freebsd row (which can lag an
	# uncommitted local bump).
	if [ ! -d "$PORTSDIR/$origin" ]; then
		missing="${missing}${origin}|${fbver}|${target}
"
		continue
	fi
	localver=$(make -C "$PORTSDIR/$origin" -V DISTVERSION 2>/dev/null)
	[ -z "$localver" ] && localver=$(make -C "$PORTSDIR/$origin" -V PORTVERSION 2>/dev/null)

	# Strip a leading v/V from the target for a fair string compare.
	norm=$(printf '%s' "$target" | sed -E 's/^[vV]//')
	if [ "$localver" = "$target" ] || [ "$localver" = "$norm" ]; then
		bumped="${bumped}${origin}|${localver}
"
		continue
	fi

	# Needs judgment, not a blind bump, when:
	#  - local version is a git snapshot (gYYYYMMDD or a bare YYYYMMDD date), or
	#  - Repology reports several distinct "newest" versions (cross-repo
	#    namesake ambiguity, e.g. an unrelated tool sharing the project name).
	if printf '%s' "$localver" | grep -qE '^g?[0-9]{8}([._]|$)' \
	   || printf '%s' "$target" | grep -q ','; then
		judgment="${judgment}${origin}|${localver}|${src}|${target}
"
		continue
	fi

	outdated="${outdated}${origin}|${localver}|${src}|${target}
"
done <<EOF
$tsv
EOF
IFS=$oldifs

echo ""
printf '%-38s %-16s    %-16s %s\n' "PORT" "LOCAL" "LATEST" "SRC"
printf '%-38s %-16s    %-16s %s\n' "----" "-----" "------" "---"
printf '%s' "$outdated" | sort | while IFS='|' read -r origin localver src target; do
	[ -z "$origin" ] && continue
	printf '%-38s %-16s -> %-16s %s\n' "$origin" "$localver" "$target" "$src"
done

if [ -n "$judgment" ]; then
	echo ""
	echo "==> needs judgment (git-snapshot ports / ambiguous upstream version)"
	printf '%s' "$judgment" | sort | while IFS='|' read -r origin localver src target; do
		[ -z "$origin" ] && continue
		printf '    %-38s local=%-16s latest(%s)=%s\n' "$origin" "$localver" "$src" "$target"
	done
fi

if [ -n "$missing" ]; then
	echo ""
	echo "==> in Repology but not in local tree ($PORTSDIR)"
	printf '%s' "$missing" | sort | while IFS='|' read -r origin fbver target; do
		[ -z "$origin" ] && continue
		printf '    %-38s repology-freebsd=%-16s latest=%s\n' "$origin" "$fbver" "$target"
	done
fi

if [ "$VERBOSE" -eq 1 ] && [ -n "$bumped" ]; then
	echo ""
	echo "==> already bumped locally (Repology just hasn't caught up)"
	printf '%s' "$bumped" | sort | while IFS='|' read -r origin localver; do
		[ -z "$origin" ] && continue
		printf '    %-38s local=%s\n' "$origin" "$localver"
	done
fi

n_out=$(printf '%s' "$outdated" | grep -c . || true)
n_bump=$(printf '%s' "$bumped" | grep -c . || true)
n_judge=$(printf '%s' "$judgment" | grep -c . || true)
n_miss=$(printf '%s' "$missing" | grep -c . || true)

echo ""
echo "==> summary: $n_out outdated, $n_bump already-bumped, $n_judge need judgment, $n_miss not-in-tree"
echo ""
echo "Notes:"
echo "  * 'outdated' is Repology's own verdict reconciled against your local tree,"
echo "    so ports you already bumped locally are dropped (see -v to list them)."
echo "  * Vulkan ports: 'latest' may be the SDK tag; the suite moves in lockstep --"
echo "    bump graphics/vulkan-* + spirv-headers/spirv-cross together."
echo "  * git-snapshot ports land under 'needs judgment': bump = re-snapshot to a"
echo "    new gYYYYMMDD, not set DISTVERSION to the upstream tag."
