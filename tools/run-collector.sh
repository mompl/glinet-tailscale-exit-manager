#!/bin/sh
umask 077
# Runs tools/collect.sh on a router over SSH and saves the report on THIS
# computer (macOS/Linux). Nothing is installed or changed on the router: the
# script text is piped into "sh -s" and the report comes back on stdout.
#
# Usage:  sh tools/run-collector.sh [user@]ROUTER NAME [--full-scripts]
#   e.g.  sh tools/run-collector.sh root@192.168.8.1 mt3000
# Result: ~/glinet-discovery/NAME-YYYYmmdd-HHMMSS.txt  (mode 600)
# Exit:   0 complete, 4 saved but PARTIAL (see the printed list),
#         1 failed/incomplete/corrupt (nothing saved), 3 leak scan hit, 2 usage
#
# --full-scripts also collects the full text of the switch/button scripts
# (/etc/gl-switch.d, /etc/hotplug.d/button|switch, /etc/rc.button). Default is
# allowlisted extraction only. Review the collector first: it is next to this file.

set -u

EXTRA=''
if [ $# -eq 3 ] && [ "$3" = "--full-scripts" ]; then
	EXTRA=' --full-scripts'
elif [ $# -ne 2 ]; then
	echo "usage: sh $0 [user@]ROUTER NAME [--full-scripts]" >&2
	exit 2
fi
TARGET=$1
NAME=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9._-')
[ -n "$NAME" ] || { echo "error: NAME must contain letters/digits" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
COLLECT="$HERE/collect.sh"
[ -r "$COLLECT" ] || { echo "error: $COLLECT not found" >&2; exit 1; }

sha256() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
}

echo "collector sha256: $(sha256 <"$COLLECT" | cut -d' ' -f1)" >&2

DIR="$HOME/glinet-discovery"
mkdir -p "$DIR" && chmod 700 "$DIR" || exit 1
STAMP=$(date '+%Y%m%d-%H%M%S')
DEST="$DIR/$NAME-$STAMP.txt"
TMP="$DEST.part"

# The router sees only: sh -s (reads the script from stdin). No scp/sftp needed.
if ! ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 "$TARGET" "sh -s --$EXTRA" <"$COLLECT" >"$TMP"; then
	rm -f "$TMP"
	echo "error: collection failed (see messages above); nothing saved" >&2
	exit 1
fi
chmod 600 "$TMP"

fail() {
	rm -f "$TMP"
	echo "error: $1; nothing saved" >&2
	exit 1
}

# 1. END line with line count and hash (an END line alone proves nothing).
LAST=$(tail -n 1 "$TMP")
case $LAST in
"## END lines="*) ;;
*) fail "report has no END line (stream cut off?)" ;;
esac
N=${LAST#*lines=}
N=${N%% *}
H=${LAST#*sha256=}
TOTAL=$(wc -l <"$TMP" | tr -d ' ')
[ "$TOTAL" -eq $((N + 1)) ] || fail "line count mismatch (file $TOTAL, END says $N)"
if [ "$H" = "none" ]; then
	echo "warning: router has no sha256sum; transfer integrity NOT verified" >&2
else
	CALC=$(head -n "$N" "$TMP" | sha256 | cut -d' ' -f1)
	[ "$CALC" = "$H" ] || fail "sha256 mismatch (report corrupted in transfer)"
fi

# 2. Structure: SUMMARY present, every section has a status line.
COMP=$(grep -m1 '^completeness=' "$TMP" | cut -d= -f2)
SECS=$(grep -m1 '^sections=' "$TMP" | sed 's/^sections=\([0-9]*\) .*/\1/')
# Section headers are counted BEFORE the SUMMARY only; the INDEX is informational
# and its length is not checked (it may legitimately differ).
HDRS=$(awk '/^## SUMMARY$/ { exit } /^## \[/ { n++ } END { print n + 0 }' "$TMP")
[ -n "$COMP" ] && [ -n "$SECS" ] || fail "report has no SUMMARY"
grep -q '^## INDEX$' "$TMP" || fail "report has no INDEX"
[ "$HDRS" -eq "$SECS" ] || fail "section count mismatch (headers $HDRS, SUMMARY says $SECS)"
[ "$COMP" != "incomplete" ] || fail "collector reports incomplete sections"

# 3. Local second leak scan (counts only).
HITS=$(grep -E 'tskey-[A-Za-z0-9]|(privkey|nodekey|mkey|nlpriv):[0-9a-fA-F]{8}|BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9+/]{43}=' "$TMP" | grep -vc 'redacted')
if [ "${HITS:-0}" -ne 0 ]; then
	rm -f "$TMP"
	echo "error: local scan found secret-like content; report deleted" >&2
	exit 3
fi

mv "$TMP" "$DEST"
chmod 600 "$DEST"
echo "saved: $DEST ($TOTAL lines, mode 600, integrity verified)" >&2
echo "Read it once before sending it anywhere." >&2
if [ "$COMP" = "partial" ]; then
	echo "PARTIAL: some commands failed or sections were truncated:" >&2
	grep '^# \[[0-9a-z]*\] status=partial' "$DEST" >&2
	exit 4
fi
