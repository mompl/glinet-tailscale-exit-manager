#!/bin/sh
# run-preflight-mac.sh - run the READ-ONLY tsem preflight on the router over SSH and save the
# report on THIS computer (macOS or Linux).
#
#   sh tools/run-preflight-mac.sh [--host root] [--repo /tmp/glinet-tailscale-exit-manager] [--out DIR]
#   sh tools/run-preflight-mac.sh [--host root] [--out DIR] --stage DIR      (WRITES a temporary copy, see below)
#
# - The preflight script is streamed through ssh into `sh -s`: nothing is copied to or written on
#   the router. The router-side repository is only read (and its installer dry run is executed).
# - No router configuration is touched, no ~/.ssh/config change, no upload anywhere but the one ssh
#   connection to the router. The report is written locally (default ~/tsem-preflight/).
# - After the run the hashes of the repository files on the router are compared with the files of this
#   checkout, so you can see whether the router examined the same code you reviewed.
#
# - OPTIONAL WRITE: with --stage DIR (your checkout) the checkout is copied (tar over ssh) into a NEW volatile directory
#   /tmp/tsem-pf.<epoch>.<pid> on the router (mkdir without -p, marker file .tsem-pf-stage) so that the repository
#   checks (repo.present, installer dry run, hash comparison) work without a repository on the router. That directory
#   is the only thing written; it is deleted again after the run, but only after the router re-checked the name pattern,
#   that it is a real directory (no symlink) and that it carries the marker. An existing
#   /tmp/glinet-tailscale-exit-manager is neither used nor touched. Without --stage nothing is written (strict read-only).
#
# Exit code is the preflight's: 0 READY_FOR_PASSIVE_INSTALL, 1 NEEDS_FIX, 2 INSUFFICIENT_EVIDENCE.

set -u
HOST=${TSEM_PF_HOST:-root}
REMOTE_REPO=${TSEM_PF_REPO:-/tmp/glinet-tailscale-exit-manager}
OUT=${TSEM_PF_OUT:-$HOME/tsem-preflight}
STAGE=
REPO_GIVEN=0
while [ $# -gt 0 ]; do
	case $1 in
	--host) [ $# -ge 2 ] || { echo "--host needs a value" >&2; exit 64; }; HOST=$2; shift 2 ;;
	--repo) [ $# -ge 2 ] || { echo "--repo needs a value" >&2; exit 64; }; REMOTE_REPO=$2; REPO_GIVEN=1; shift 2 ;;
	--stage) [ $# -ge 2 ] || { echo "--stage needs a directory" >&2; exit 64; }; STAGE=$2; shift 2 ;;
	--out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 64; }; OUT=$2; shift 2 ;;
	-h | --help) sed -n '2,24p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 64 ;;
	esac
done

if [ -n "$STAGE" ] && [ "$REPO_GIVEN" -eq 1 ]; then echo "--stage and --repo cannot be combined" >&2; exit 64; fi
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
SCRIPT=$HERE/tsem-preflight.sh
[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT" >&2; exit 66; }
case $REMOTE_REPO in *[!A-Za-z0-9._/-]*) echo "unsafe --repo value" >&2; exit 64 ;; esac
case $HOST in *[!A-Za-z0-9._@:-]*) echo "unsafe --host value" >&2; exit 64 ;; esac

mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 73; }

STAGED=0
STAGE_DIR=
valid_stage_path() { case $1 in /tmp/tsem-pf.[0-9]*.[0-9]*) case ${1#/tmp/} in *[!A-Za-z0-9._-]*) return 1 ;; esac; return 0 ;; esac; return 1; }
cleanup_stage() {
	[ "$STAGED" -eq 1 ] || return 0
	STAGED=0
	valid_stage_path "$STAGE_DIR" || { echo "REFUSING to delete '$STAGE_DIR' (not a staging path of this tool)" >&2; return 0; }
	ssh -o ConnectTimeout=15 -o ClearAllForwardings=yes "$HOST" "d=$STAGE_DIR; case \$d in /tmp/tsem-pf.[0-9]*.[0-9]*) [ -d \$d ] && [ ! -L \$d ] && [ -f \$d/.tsem-pf-stage ] && rm -rf \$d ;; esac" </dev/null >/dev/null 2>&1 ||
		echo "WARNING: could not remove $HOST:$STAGE_DIR (volatile /tmp; it disappears at reboot)" >&2
}
trap 'cleanup_stage' EXIT
if [ -n "$STAGE" ]; then
	for f in install.sh uninstall.sh src contrib; do [ -e "$STAGE/$f" ] || { echo "stage directory lacks $f" >&2; exit 66; }; done
	STAGE_DIR=/tmp/tsem-pf.$(date +%s).$$
	valid_stage_path "$STAGE_DIR" || { echo "internal error: bad stage path $STAGE_DIR" >&2; exit 70; }
	REMOTE_REPO=$STAGE_DIR
	echo "WRITE on the router: staging $STAGE -> $HOST:$STAGE_DIR (new volatile /tmp directory, deleted after the run)"
	( cd "$STAGE" && tar cf - install.sh uninstall.sh src tools contrib docs 2>/dev/null ) |
		ssh -o ConnectTimeout=15 -o ClearAllForwardings=yes "$HOST" "umask 077 && mkdir $STAGE_DIR && : >$STAGE_DIR/.tsem-pf-stage && cd $STAGE_DIR && tar xf -" ||
		{ echo "staging failed; nothing else was done" >&2; exit 69; }
	STAGED=1
fi
STAMP=$(date +%Y%m%d-%H%M%S)
REPORT=$OUT/preflight-$HOST-$STAMP.txt
ERRF=$OUT/preflight-$HOST-$STAMP.stderr
echo "tsem preflight on '$HOST' (read-only), report: $REPORT"

# One ssh call. The script arrives on stdin; the remote command line only names the repository path.
ssh -o ConnectTimeout=15 -o ClearAllForwardings=yes "$HOST" "sh -s -- --repo $REMOTE_REPO" <"$SCRIPT" >"$REPORT" 2>"$ERRF"
RC=$?
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

cat "$REPORT"
echo
echo "Report saved: $REPORT"
exit "$RC"
