#!/bin/sh
# run-masq-fix-mac.sh - immediate, minimal repair of the LAN -> tailscale0 masquerading on the router.
#
#   sh tools/run-masq-fix-mac.sh [--host root] [--out DIR]            read-only check (default)
#   sh tools/run-masq-fix-mac.sh [--host root] [--out DIR] --apply    check, ask, repair, verify
#
# Independent of the rest of tsem: nothing else has to be installed on the router, no kill-switch part is touched
# (no TSEM chain, no ip rule, no exit node, no WAN rule, no zone/forwarding is created).
#
# What --apply changes on the router (and nothing else), after you typed the phrase FIX-MASQ:
#   1. /etc/config/firewall is copied to /etc/tsem/backup/masq/firewall.<time>
#   2. uci firewall.<zone tailscale0>.masq=1 + uci commit firewall            (only if it is not 1 already)
#   3. ONE iptables rule in the nat chain zone_tailscale0_postrouting: -m comment --comment tsem-masq -j MASQUERADE
#      (only if the chain has no MASQUERADE; fw3 builds its own from UCI at the next reload)
# The firewall is NOT reloaded by this tool. If the zone chain does not exist yet, it says so and does nothing more.
#
# Undo: cp /etc/tsem/backup/masq/firewall.<time> /etc/config/firewall
#       iptables -t nat -D zone_tailscale0_postrouting -m comment --comment tsem-masq -j MASQUERADE
#
# The router-side script is src/usr/sbin/tsem-masq of THIS checkout, streamed through ssh into `sh -s`
# (nothing is copied to the router). Reports are written to this computer (default ~/tsem-masq-fix/).
# Exit code: 0 consistent (or repaired and verified), 1 drift remains / not applied, 3 not applicable, 69 no connection.

set -u
HOST=${TSEM_MASQ_HOST:-root}
OUT=${TSEM_MASQ_OUT:-$HOME/tsem-masq-fix}
SSH=${TSEM_MASQ_SSH:-ssh}
APPLY=0
while [ $# -gt 0 ]; do
	case $1 in
	--host) [ $# -ge 2 ] || { echo "--host needs a value" >&2; exit 64; }; HOST=$2; shift 2 ;;
	--out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 64; }; OUT=$2; shift 2 ;;
	--apply) APPLY=1; shift ;;
	-h | --help) sed -n '2,24p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 64 ;;
	esac
done
case $HOST in *[!A-Za-z0-9._@:-]*) echo "unsafe --host value" >&2; exit 64 ;; esac
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../src/usr/sbin/tsem-masq
[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT" >&2; exit 66; }
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 73; }
STAMP=$(date +%Y%m%d-%H%M%S)
REPORT=$OUT/masq-fix-$HOST-$STAMP.txt

# one ssh call per step; the script arrives on stdin, the remote command line carries only fixed words
remote() { # args for tsem-masq
	$SSH -o ConnectTimeout=15 -o ClearAllForwardings=yes "$HOST" "sh -s -- $*" <"$SCRIPT" 2>&1
}
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }

say "tsem-masq on '$HOST' ($([ "$APPLY" -eq 1 ] && echo 'repair requested' || echo 'read-only check')), report: $REPORT"
say "== Step 1: read-only check"
OUT1=$(remote check); RC1=$?
printf '%s\n' "$OUT1" | tee -a "$REPORT"
if [ -z "$OUT1" ]; then say "no answer from the router (ssh exit $RC1). Is the alias '$HOST' reachable?"; exit 69; fi
case $RC1 in
0) say "RESULT masq consistent: nothing to do."; exit 0 ;;
3) say "RESULT not applicable on this router (no uci or no zone tailscale0); nothing changed."; exit 3 ;;
255) say "RESULT ssh failed."; exit 69 ;;
esac
if [ "$APPLY" -ne 1 ]; then
	say "RESULT drift found. Nothing was changed. To repair (separate approval): sh tools/run-masq-fix-mac.sh --host $HOST --apply"
	exit 1
fi

say "== Step 2: repair needs your confirmation"
say "This sets masq=1 on the tailscale0 zone (backup first) and adds one MASQUERADE rule to its nat chain. No firewall reload."
printf 'Type FIX-MASQ to continue, anything else aborts: '
read -r ANSWER || ANSWER=''
if [ "$ANSWER" != FIX-MASQ ]; then say "aborted: the router was not changed."; exit 1; fi
OUT2=$(remote ensure --no-reload); RC2=$?
printf '%s\n' "$OUT2" | tee -a "$REPORT"
say "== Step 3: verification (read-only)"
OUT3=$(remote check); RC3=$?
printf '%s\n' "$OUT3" | tee -a "$REPORT"
if [ "$RC3" -eq 0 ] && [ "$RC2" -eq 0 ]; then
	say "RESULT repaired and verified. fw3 keeps masq=1 from UCI; the persistent component (install.sh --components masq) restores it after resets."
	exit 0
fi
say "RESULT NOT fully repaired (ensure rc=$RC2, check rc=$RC3). If the zone chain is missing, a firewall reload is needed; this tool does not do that."
say "Undo (on the router): cp /etc/tsem/backup/masq/firewall.<time> /etc/config/firewall; iptables -t nat -D zone_tailscale0_postrouting -m comment --comment tsem-masq -j MASQUERADE"
exit 1
