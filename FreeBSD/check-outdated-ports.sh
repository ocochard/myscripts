#!/bin/sh
#
# check-outdated-ports.sh
#
# List FreeBSD ports maintained by a given e-mail and report which are behind
# upstream. Dispatches per upstream: GitHub (via gh(1)), GitLab freedesktop.org
# (via curl), PyPI (via curl). Perl (p5-*) and other custom sources are skipped
# and listed at the end for manual review.
#
# Requires: portgrep, gh (authenticated), curl, jq.
#
# Usage:
#   check-outdated-ports.sh                       # default maintainer: olivier@FreeBSD.org
#   check-outdated-ports.sh some@maintainer.tld
#
# Environment:
#   PORTSDIR   ports tree root (default: /home/olivier/freebsd-official/ports)

set -u

MAINTAINER="${1:-olivier@FreeBSD.org}"
PORTSDIR="${PORTSDIR:-/home/olivier/freebsd-official/ports}"

for tool in portgrep gh curl jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: $tool not in PATH" >&2
		exit 1
	fi
done

if ! gh auth status >/dev/null 2>&1; then
	echo "error: gh not authenticated (run 'gh auth login')" >&2
	exit 1
fi

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

echo "==> listing ports maintained by $MAINTAINER"
portgrep -R "$PORTSDIR" -m "$MAINTAINER" -o -s > "$TMP/ports.txt"

# Filter to exact-match maintainer (portgrep -m is substring)
: > "$TMP/ports-strict.txt"
while read -r origin; do
	[ -z "$origin" ] && continue
	real=$(cd "$PORTSDIR/$origin" && make -V MAINTAINER 2>/dev/null)
	[ "$real" = "$MAINTAINER" ] && echo "$origin" >> "$TMP/ports-strict.txt"
done < "$TMP/ports.txt"

count=$(wc -l < "$TMP/ports-strict.txt" | tr -d ' ')
echo "    $count ports"

echo "==> extracting version + upstream metadata"
: > "$TMP/info.txt"
while read -r origin; do
	[ -z "$origin" ] && continue
	cd "$PORTSDIR/$origin" || continue
	ver=$(make -V DISTVERSION 2>/dev/null)
	[ -z "$ver" ] && ver=$(make -V PORTVERSION 2>/dev/null)
	gh_acct=$(make -V GH_ACCOUNT 2>/dev/null | awk '{print $1}')
	gh_proj=$(make -V GH_PROJECT 2>/dev/null | awk '{print $1}')
	gl_acct=$(make -V GL_ACCOUNT 2>/dev/null)
	gl_proj=$(make -V GL_PROJECT 2>/dev/null)
	portname=$(make -V PORTNAME 2>/dev/null)
	echo "${origin}|${ver}|${gh_acct}|${gh_proj}|${gl_acct}|${gl_proj}|${portname}"
done < "$TMP/ports-strict.txt" > "$TMP/info.txt"

echo "==> querying upstream (this takes a minute)"
: > "$TMP/check.txt"
while IFS='|' read -r origin ver gh_acct gh_proj gl_acct gl_proj portname; do
	[ -z "$origin" ] && continue
	upstream=""
	latest=""

	if [ -n "$gh_acct" ] && [ -n "$gh_proj" ]; then
		upstream="gh:${gh_acct}/${gh_proj}"
		tag=$(gh api "repos/${gh_acct}/${gh_proj}/releases/latest" --jq '.tag_name' 2>/dev/null)
		case "$tag" in
			''|null|'{"message"'*|*"Not Found"*) tag="" ;;
		esac
		if [ -z "$tag" ]; then
			tag=$(gh api "repos/${gh_acct}/${gh_proj}/tags?per_page=1" --jq '.[0].name' 2>/dev/null)
		fi
		if [ -z "$tag" ] || [ "$tag" = "null" ]; then
			# tagless repo: fall back to commit sha + date
			tag=$(gh api "repos/${gh_acct}/${gh_proj}/commits?per_page=1" \
				--jq '.[0].sha[0:7] + " (" + .[0].commit.committer.date[0:10] + ")"' 2>/dev/null)
		fi
		latest="$tag"
	elif [ -n "$gl_acct" ] && [ -n "$gl_proj" ]; then
		upstream="gl:${gl_acct}/${gl_proj}"
		enc="${gl_acct}%2F${gl_proj}"
		latest=$(curl -sf "https://gitlab.freedesktop.org/api/v4/projects/${enc}/repository/tags?per_page=1" 2>/dev/null \
			| jq -r '.[0].name' 2>/dev/null)
		if [ -z "$latest" ] || [ "$latest" = "null" ]; then
			latest=$(curl -sf "https://gitlab.freedesktop.org/api/v4/projects/${enc}/repository/commits?per_page=1" 2>/dev/null \
				| jq -r '.[0].id[0:7] + " (" + .[0].committed_date[0:10] + ")"' 2>/dev/null)
		fi
	elif echo "$portname" | grep -qE '^p5-'; then
		upstream="skip-cpan"
	else
		# PyPI fallback: query by portname. May yield the wrong package when
		# PORTNAME doesn't match the PyPI name -- verify by hand for those.
		upstream="pypi:${portname}"
		latest=$(curl -sf "https://pypi.org/pypi/${portname}/json" 2>/dev/null | jq -r '.info.version' 2>/dev/null)
		case "$latest" in ''|null) latest="" ;; esac
	fi

	echo "${origin}|${ver}|${upstream}|${latest}"
done < "$TMP/info.txt" > "$TMP/check.txt"

echo "==> report"
echo ""
printf '%-42s %-18s %-40s %s\n' "PORT" "CURRENT" "UPSTREAM SOURCE" "LATEST"
printf '%-42s %-18s %-40s %s\n' "----" "-------" "---------------" "------"

# Ports where current != latest (excluding skip-* and empty upstream)
outdated=""
matched=""
manual=""
while IFS='|' read -r origin ver upstream latest; do
	case "$upstream" in
		skip-*)
			manual="${manual}${origin}|${ver}|${upstream}
"
			continue ;;
	esac
	if [ -z "$latest" ]; then
		manual="${manual}${origin}|${ver}|${upstream}|<no upstream data>
"
		continue
	fi
	# Strip common tag prefixes from upstream for a fair compare
	norm=$(echo "$latest" | sed -E 's/^(v|V|release-|Release-)//')
	if [ "$ver" = "$latest" ] || [ "$ver" = "$norm" ]; then
		matched="${matched}${origin}
"
	else
		outdated="${outdated}${origin}|${ver}|${upstream}|${latest}
"
	fi
done < "$TMP/check.txt"

echo "$outdated" | while IFS='|' read -r origin ver upstream latest; do
	[ -z "$origin" ] && continue
	printf '%-42s %-18s %-40s %s\n' "$origin" "$ver" "$upstream" "$latest"
done

echo ""
echo "==> manual review (custom sources, prefix mismatches, no upstream API)"
echo "$manual" | while IFS='|' read -r origin ver upstream extra; do
	[ -z "$origin" ] && continue
	printf '    %s (%s) %s %s\n' "$origin" "$ver" "$upstream" "$extra"
done

up_count=$(echo "$matched" | grep -c . || true)
echo ""
echo "==> summary: $up_count up-to-date, $(echo "$outdated" | grep -c .) flagged, $(echo "$manual" | grep -c .) need manual check"
echo ""
echo "Caveats:"
echo "  * 'flagged' can include false positives: versioned ports (libyang2/3,"
echo "    frr9/10, bird2/3) share one repo but each tracks its own major;"
echo "    ports pinned to a commit intentionally may look behind."
echo "  * Vulkan repos: releases/latest is the SDK tag (vulkan-sdk-*), but"
echo "    Vulkan-Headers/Loader/Tools/etc. also cut finer v1.4.NNN tags."
echo "  * PyPI lookup uses PORTNAME as-is; py-zipkin -> py_zipkin etc. are"
echo "    misdetected -- listed under 'manual review' if empty."
