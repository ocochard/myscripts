#!/bin/sh
# Report the upstream status of the ZBook patch branches listed in
# zbook-upstream.tsv: commits landed in main, ron-dev pull request state
# and approvals, local review report, rebase conflicts, readiness.
#
# Usage: zbook-upstream.sh [-n]   (-n: skip git fetch)
# Env:   REPO (default ~/freebsd-official/src), MAIN (default freebsd/main),
#        API (default https://ron-dev.freebsd.org/api/v1/repos/FreeBSD/src)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tsv=$here/zbook-upstream.tsv
reviews=$here/docs/reviews
REPO=${REPO:-$HOME/freebsd-official/src}
MAIN=${MAIN:-freebsd/main}
PORTS_REPO=${PORTS_REPO:-$HOME/freebsd-official/ports}
API=${API:-https://ron-dev.freebsd.org/api/v1/repos/FreeBSD/src}
WEB=$(echo "$API" | sed 's|/api/v1/repos/|/|')

cd "$REPO"
if [ "${1:-}" != "-n" ]; then
	git fetch -q "${MAIN%%/*}" "${MAIN#*/}"
	git fetch -q review 2>/dev/null || true
	git -C "$PORTS_REPO" fetch -q freebsd main 2>/dev/null || true
fi
subjects=$(mktemp)
trap 'rm -f "$subjects"' EXIT
git log --since='3 months ago' --format=%s "$MAIN" >"$subjects"

# landed <topic>: prints "landed/total"; patch-id match first, then subject
# match for commits whose diff changed when they were committed.
# repo_of <topic>: the git directory of that topic (ports PRs: ports tree)
repo_of() {
	case $(awk -F'\t' -v t="$1" '$1 == t {print $4}' "$tsv") in
	ports:*) echo "$PORTS_REPO" ;;
	*) echo "$REPO" ;;
	esac
}

landed() {
	br=pr/$1
	g="git -C $(repo_of "$1")"
	$g rev-parse -q --verify "$br" >/dev/null || { echo "no-branch"; return; }
	total=0; done=0
	for c in $($g cherry "$MAIN" "$br" | awk '{print $1 ":" $2}'); do
		total=$((total + 1))
		case $c in
		-:*) done=$((done + 1)) ;;
		+:*) grep -qFx "$($g log -1 --format=%s "${c#+:}")" "$subjects" &&
		    done=$((done + 1)) ;;
		esac
	done
	echo "$done/$total"
}

is_landed() {
	l=$(landed "$1")
	case $l in */0|no-branch) return 1 ;; esac
	[ "${l%/*}" = "${l#*/}" ]
}

pr_state() {
	[ "$1" = "-" ] && { echo "not sent"; return; }
	# "ports:N" is pull request N of the ports repository
	api=$API; web=$WEB; n=$1; label="#$1"
	case $1 in
	ports:*) n=${1#ports:}; label="ports#$n"
		api=${API%/src}/ports; web=${WEB%/src}/ports ;;
	esac
	j=$(curl -fsS -m 20 "$api/pulls/$n") || { echo "#$n api-error"; return; }
	st=$(echo "$j" | jq -r 'if .merged then "merged" else .state end')
	r=$(curl -fsS -m 20 "$api/pulls/$n/reviews" | jq -r \
	    '(map(select(.state == "APPROVED")) | length) as $a |
	     (map(select(.state == "REQUEST_CHANGES")) | length) as $c |
	     (map(select(.state == "REQUEST_REVIEW")) | length) as $q |
	     "\($a) approved, \($c) changes requested, \($q) asked"') ||
	    r="reviews: api-error"
	echo "[$label]($web/pulls/$n) $st, $r"
}

review_state() {
	f=$reviews/$1.md
	[ -f "$f" ] || { echo "not reviewed"; return; }
	# pre-existing and syzkaller IDs do not block the pull request
	n=$(grep -E '^POSTCR-[0-9a-f]{40}-[0-9]+:' "$f" | grep -cv \
	    -e ': *pre-existing:' -e ': *syzkaller:' || true)
	if grep -q '^VERDICT: ready' "$f"; then v=ready; else v="fix needed"; fi
	echo "$v, $n POSTCR"
}

echo "Status on $(date +%F), $MAIN = $(git rev-parse --short=12 "$MAIN")"
echo
echo "| Topic | Round | Landed | Pull request | Local review | Rebase | Next |"
echo "|---|---|---|---|---|---|---|"
grep -v '^#' "$tsv" | while IFS='	' read -r topic round deps pr note; do
	[ -n "$topic" ] || continue
	l=$(landed "$topic")
	g="git -C $(repo_of "$topic")"
	if $g rev-parse -q --verify "pr/$topic" >/dev/null; then
		if $g merge-tree --write-tree "$MAIN" "pr/$topic" >/dev/null 2>&1
		then rb=clean; else rb=CONFLICT; fi
	else
		rb=-
	fi
	waiting=
	if [ "$deps" != "-" ]; then
		for d in $(echo "$deps" | tr , ' '); do
			is_landed "$d" || waiting="$waiting $d"
		done
	fi
	rv=$(review_state "$topic")
	if is_landed "$topic"; then next="done"
	elif [ "$round" = hold ]; then next="on hold: $note"
	elif [ -n "$waiting" ]; then next="wait for$waiting"
	elif [ "$rb" = CONFLICT ]; then next="rebase, git pr -f"
	elif [ "$rb" = - ]; then next="create branch"
	elif [ "$rv" = "not reviewed" ] && [ "${pr#ports:}" = "$pr" ]; then
		next="review"
	elif [ "$rv" != "not reviewed" ] && [ "${rv%%,*}" != ready ]; then
		next="fix review findings"
	elif [ "$pr" = "-" ]; then next="git pr main -o $topic"
	else next="wait for reviewers"
	fi
	echo "| $topic | $round | $l | $(pr_state "$pr") | $rv | $rb | $next |"
done
