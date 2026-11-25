#!/bin/sh
# run-rc3-acceptance-mac.sh - run the READ-ONLY tsem RC3 acceptance (phase 1) on the router over SSH and save the
# report on THIS computer (macOS or Linux).
#
#   sh tools/run-rc3-acceptance-mac.sh [--host root] [--out DIR] --stage DIR
#   sh tools/run-rc3-acceptance-mac.sh [--host root] [--out DIR] --repo REMOTE_DIR     (no copy; reads REMOTE_DIR)
#
# - THE ONLY WRITE ON THE ROUTER: with --stage DIR the checkout in DIR is copied (tar over ssh) into a NEW,
#   UNIQUE directory /tmp/tsem-rc3-accept.<epoch>.<pid> (volatile RAM on OpenWrt, about 1 MB). It is created with
#   `mkdir` WITHOUT -p, so an existing path is never reused, overwritten or merged. An existing
#   /tmp/glinet-tailscale-exit-manager (the earlier repository on the router) is neither read as the
#   code under test, nor changed, nor deleted.
#   Cleanup removes ONLY that one directory, and only after checking on the router that the path has the exact
#   name pattern, is a real directory (no symlink) and contains the marker file .tsem-rc3-stage written by this run.
#   It also happens when the run fails. Why a copy is needed at all: the acceptance runs the RC3 code (not the
#   installed RC2) with its read-only commands. Without --stage nothing at all is written on the router.
# - The acceptance script itself is streamed through ssh into `sh -s` and runs only read-only commands
#   (enforced by tests/t_rc3_accept.sh). It also reports whether RC2/RC3 is installed on the router.
# - ssh calls: 1 stage, 1 read-only run, 1 cleanup of the staged directory. Nothing else.
# - No router configuration is touched, no ~/.ssh/config change, no upload anywhere but the one ssh
#   connection to the router. The report is written locally (default ~/tsem-rc3-acceptance/).
# - After the run the hashes of the repository files on the router are compared with the files of this
#   checkout, so you can see whether the router examined the same code you reviewed.
#
# Exit code is the acceptance run: 0 RC3_READ_ONLY_OK, 1 NEEDS_FIX, 2 INSUFFICIENT_EVIDENCE.

set -u
HOST=${TSEM_RC3_HOST:-root}
REMOTE_REPO=${TSEM_RC3_REPO:-}
OUT=${TSEM_RC3_OUT:-$HOME/tsem-rc3-acceptance}
STAGE=
while [ $# -gt 0 ]; do
	case $1 in
	--host) [ $# -ge 2 ] || { echo "--host needs a value" >&2; exit 64; }; HOST=$2; shift 2 ;;
	--repo) [ $# -ge 2 ] || { echo "--repo needs a value" >&2; exit 64; }; REMOTE_REPO=$2; shift 2 ;;
	--stage) [ $# -ge 2 ] || { echo "--stage needs a directory" >&2; exit 64; }; STAGE=$2; shift 2 ;;
	--out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 64; }; OUT=$2; shift 2 ;;
	-h | --help) sed -n '2,24p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 64 ;;
	esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
SCRIPT=$HERE/tsem-rc3-acceptance.sh
[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT" >&2; exit 66; }
case $REMOTE_REPO in *[!A-Za-z0-9._/-]*|*..*) echo "unsafe --repo value" >&2; exit 64 ;; esac
case $HOST in *[!A-Za-z0-9._@:-]*) echo "unsafe --host value" >&2; exit 64 ;; esac

# --stage and --repo exclude each other: the staged directory name is chosen here, never by the caller.
if [ -n "$STAGE" ] && [ -n "$REMOTE_REPO" ]; then echo "--stage and --repo cannot be combined" >&2; exit 64; fi
[ -n "$STAGE" ] || [ -n "$REMOTE_REPO" ] || { echo "need --stage DIR (copy the checkout to a new /tmp dir) or --repo REMOTE_DIR" >&2; exit 64; }

# Unique directory name chosen on this side; checked against one strict pattern before anything is deleted.
valid_stage_path() {
	case $1 in
	*[!A-Za-z0-9._/-]* | *..*) return 1 ;;
	/tmp/tsem-rc3-accept.[0-9]*.[0-9]*) case ${1#/tmp/tsem-rc3-accept.} in *[!0-9.]*) return 1 ;; esac; return 0 ;;
	esac
	return 1
}
STAGED=0
STAGE_DIR=
cleanup_remote() {
	[ "$STAGED" -eq 1 ] || return 0
	STAGED=0
	valid_stage_path "$STAGE_DIR" || { echo "REFUSING to delete '$STAGE_DIR' (not a staging path of this tool)" >&2; return 0; }
	# the router re-checks: exact pattern, real directory (not a symlink), our marker file; only then rm -rf that one path
	ssh -o ConnectTimeout=15 -o ClearAllForwardings=yes "$HOST" "d=$STAGE_DIR; case \$d in /tmp/tsem-rc3-accept.[0-9]*.[0-9]*) [ -d \$d ] && [ ! -L \$d ] && [ -f \$d/.tsem-rc3-stage ] && rm -rf \$d ;; esac" </dev/null >/dev/null 2>&1 ||
		echo "WARNING: could not remove $HOST:$STAGE_DIR (volatile /tmp; it disappears at reboot)" >&2
}
trap cleanup_remote EXIT INT TERM
if [ -n "$STAGE" ]; then
	for f in install.sh uninstall.sh src/usr/sbin/tsem src/usr/lib/tsem/common.sh tools/tsem-rc3-acceptance.sh; do
		[ -f "$STAGE/$f" ] || { echo "stage directory lacks $f" >&2; exit 66; }
	done
	STAGE_DIR=/tmp/tsem-rc3-accept.$(date +%s).$$
	valid_stage_path "$STAGE_DIR" || { echo "internal error: bad stage path $STAGE_DIR" >&2; exit 70; }
	REMOTE_REPO=$STAGE_DIR
	STAGED=1
	echo "staging $STAGE -> $HOST:$STAGE_DIR (new volatile /tmp directory; the existing /tmp/glinet-tailscale-exit-manager is not touched)"
	# mkdir WITHOUT -p: fails if the path exists. The marker is written first, so cleanup can recognise the directory.
	( cd "$STAGE" && tar cf - install.sh uninstall.sh src tools contrib docs 2>/dev/null ) |
		ssh -o ConnectTimeout=15 -o ClearAllForwardings=yes "$HOST" "umask 077 && mkdir $STAGE_DIR && : >$STAGE_DIR/.tsem-rc3-stage && cd $STAGE_DIR && tar xf -" ||
		{ echo "staging failed" >&2; exit 69; }
fi

SRC_HEAD=
[ -z "$STAGE" ] || SRC_HEAD=$(git -C "$STAGE" rev-parse HEAD 2>/dev/null)

mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 73; }
STAMP=$(date +%Y%m%d-%H%M%S)
REPORT=$OUT/rc3-acceptance-$HOST-$STAMP.txt
ERRF=$OUT/rc3-acceptance-$HOST-$STAMP.stderr
echo "tsem RC3 acceptance (phase 1) on '$HOST' (read-only), report: $REPORT"
[ -z "$SRC_HEAD" ] || echo "code under test: git commit $SRC_HEAD"

# One ssh call. The script arrives on stdin; the remote command line only names the repository path.
ssh -o ConnectTimeout=15 -o ClearAllForwardings=yes "$HOST" "sh -s -- --repo $REMOTE_REPO" <"$SCRIPT" >"$REPORT" 2>"$ERRF"
RC=$?
cleanup_remote
[ -s "$ERRF" ] || rm -f "$ERRF"

if [ ! -s "$REPORT" ]; then
	echo "no report received (ssh exit $RC). Is the alias '$HOST' reachable?" >&2
	[ -s "$ERRF" ] && sed 's/^/ssh: /' "$ERRF" >&2
	exit 69
fi

# Compare the router's repository copy with this checkout (only if both sides can hash).
ALG=$(sed -n 's/^# hashalg //p' "$REPORT" | head -n 1)
local_hash() {
	case $ALG in
	sha256sum) if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi ;;
	md5sum) if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi ;;
	*) return 1 ;;
	esac
}
CMP=''
N=0 BAD=0
if [ -n "$ALG" ]; then
	LIST=$(sed -n 's/^# hash \([0-9a-f]*\) \(.*\)$/\1 \2/p' "$REPORT")
	while IFS=' ' read -r H F; do
		[ -n "$F" ] || continue
		[ -f "$TOP/$F" ] || continue
		L=$(local_hash "$TOP/$F" 2>/dev/null) || continue
		N=$((N + 1))
		[ "$L" = "$H" ] || { BAD=$((BAD + 1)); CMP="$CMP $F"; }
	done <<EOF
$LIST
EOF
fi
{
	echo
	echo "== Local comparison (router repository copy vs. this checkout)"
	if [ "$N" -eq 0 ]; then
		echo "SKIP  repo.compare   no files could be compared (router repository missing or no hash tool)"
	elif [ "$BAD" -eq 0 ]; then
		echo "PASS  repo.compare   all $N compared files on the router are identical to this checkout"
	else
		echo "WARN  repo.compare   $BAD of $N files differ from this checkout:$CMP"
		echo "      The router examined its own, different copy; extract the reviewed head to the router first."
	fi
} >>"$REPORT"

[ -z "$SRC_HEAD" ] || echo "# code under test: git commit $SRC_HEAD" >>"$REPORT"
cat "$REPORT"
echo
echo "Report saved: $REPORT"
exit "$RC"
