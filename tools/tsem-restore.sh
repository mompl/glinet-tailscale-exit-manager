#!/bin/sh
# Restores TSEM after a firmware upgrade wiped everything outside /etc/tsem (shipped as /etc/tsem/pkg/restore.sh,
# started at boot by /etc/init.d/tsem-restore; can also be run by hand: sh /etc/tsem/pkg/restore.sh).
#
#   sh restore.sh [--root DIR] [--no-start] [--force]
#
# What it does: re-runs the installer from the kept package /etc/tsem/pkg with the components that were installed
# before (an upgrade of the GUI part on new firmware may be refused: then it falls back to fewer components so that
# the kill switch itself always comes back first; the GUI opt-in made at install time carries over), then starts the service. The stored intent
# (DIRECT / exit mode / BLOCKED) and the configuration in /etc/tsem are kept, so the router comes back in the mode it
# had before the upgrade. It never downloads anything. Log: /etc/tsem/restore.log
set -u
umask 022
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=/ START=1 FORCE=0
while [ $# -gt 0 ]; do
	case $1 in
	--root) [ $# -ge 2 ] || { echo "--root needs a value" >&2; exit 2; }; ROOT=$2; shift 2 ;;
	--no-start) START=0; shift ;;
	--force) FORCE=1; shift ;;
	-h | --help) sed -n '2,12p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
R=${ROOT%/}
p() { printf '%s%s' "$R" "$1"; }
CONF=$(p /etc/tsem)
LOG=$CONF/restore.log
log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
	logger -t tsem-restore "$*" 2>/dev/null
	printf '%s\n' "$*"
}
trim_log() { [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -le 300 ] || { tail -n 200 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"; }; }

if [ "$FORCE" -eq 0 ] && [ -x "$(p /usr/sbin/tsem)" ] && [ -f "$(p /usr/lib/tsem/common.sh)" ]; then exit 0; fi
[ -f "$CONF/install.manifest" ] || { log "no install manifest in $CONF: TSEM was not installed here, nothing to restore"; exit 0; }
if [ ! -f "$HERE/install.sh" ] || [ ! -d "$HERE/src" ]; then
	log "CRITICAL: the kept package is incomplete ($HERE): TSEM cannot be restored automatically. Unpack a release and run: sh setup.sh --yes"
	exit 1
fi
LOCK=${TSEM_RESTORE_LOCK:-/var/run/tsem-restore.lock}
mkdir "$LOCK" 2>/dev/null || { echo "another restore is running"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

had=$(sed -n 's/^C|//p' "$CONF/install.manifest" | sort -u | tr '\n' ',' | sed 's/,$//')
[ -n "$had" ] || had=core,api
log "TSEM is missing (firmware upgrade?): restoring components '$had' from $HERE"

if [ -e "$CONF/backup/INPROGRESS" ]; then
	log "an interrupted install was pending: recovering it first"
	sh "$HERE/install.sh" --root "$ROOT" --recover --yes >>"$LOG" 2>&1
fi

drop() { printf '%s' ",$1," | sed "s/,$2,/,/; s/^,//; s/,\$//"; }
c1=$had
c2=$(drop "$had" native-gui)
c3=$(drop "$c2" luci-gui)
c4=core
done_with='' tried=''
for c in "$c1" "$c2" "$c3" "$c4"; do
	[ -n "$c" ] || continue
	case " $tried " in *" $c "*) continue ;; esac
	tried="$tried $c"
	if sh "$HERE/install.sh" --root "$ROOT" --yes --accept-undocumented-native-gui --components "$c" >"$CONF/restore-install.out" 2>&1; then done_with=$c; break; fi
	log "install with components '$c' was refused: $(tail -n 3 "$CONF/restore-install.out" | tr '\n' ' ')"
done
if [ -z "$done_with" ]; then
	log "CRITICAL: TSEM could not be restored (see $CONF/restore-install.out). The kill switch is NOT active. Fix: unpack a release matching the new firmware and run: sh setup.sh --yes"
	trim_log
	exit 1
fi
[ "$done_with" = "$had" ] || log "WARNING: restored with '$done_with' only (not restored: parts of '$had'); the protection itself is back"

if [ "$START" -eq 1 ]; then
	INITD=$(p /etc/init.d/tsem)
	"$INITD" enable >>"$LOG" 2>&1
	if "$INITD" start >>"$LOG" 2>&1; then log "service started; the stored intent was applied"
	else log "CRITICAL: the tsem service did not start (check: tsem status, logread | grep tsem)"; trim_log; exit 1; fi
fi
{
	echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
	echo "restored=$done_with"
	echo "wanted=$had"
} >"$CONF/last-restore"
log "restore finished: components '$done_with'"
trim_log
exit 0
