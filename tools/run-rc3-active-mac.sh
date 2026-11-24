#!/bin/sh
# run-rc3-active-mac.sh - Mac-controlled, guarded RC3 upgrade and ACTIVE hardware acceptance.
# Runs on the Mac (or any Linux), drives the router over ssh, stores every report on THIS computer
# (default ~/tsem-rc3-active/). Nothing runs on the router unless you type the confirmation phrase
# shown for that phase. There is no --yes / --force option on purpose.
#
#   sh tools/run-rc3-active-mac.sh [--host root] [--out DIR] --stage DIR prepare
#        phase A  preflight (read-only), backup on the router + copy to this Mac     confirm: BACKUP
#        phase B  stage RC3 in a SIDE directory on the router (a verified copy; no live    confirm: STAGE-RC3
#                 file, hotplug handler, fw3 include, boot link, rule or service changes)
#   sh tools/run-rc3-active-mac.sh ... --stage DIR test [t00_activate ... | all] [--timeout S] [--no-observe]
#        phase C  arm the independent recovery watchdog on the router                confirm: ARM-RECOVERY
#        phase D  every test with its own phrase, e.g. START t03_both_down           confirm: START <test>
#        phase C2 wire RC3 into the live router (journaled install.sh, verified,        confirm: WIRE-RC3
#                 automatic restore of the previous version if verification fails)
#        then the watchdog is disarmed (only if you confirm: DISARM)
#   sh tools/run-rc3-active-mac.sh [--backup-dir D --stage-dir D] --stage DIR final
#        THE final acceptance in one command: reuses the backup and staging of `prepare` (nothing is repeated or
#        overwritten), verifies them against the router, then: hardware-switch gate (SWITCH-ON|SWITCH-OFF), watchdog
#        verified by really using it + WIRE-RC3, tests t00..t08 (RUN-TESTS), INTEGRATE-SWITCH (boot link, switch hook,
#        service), final mode german verified, persistence check, watchdog disarmed, one report. Any FAIL stops the run
#        and starts the recovery (never opens the kill switch).
#   sh tools/run-rc3-active-mac.sh --stage DIR accept
#        THE single start command: prepare (fresh backup + stage of THIS checkout, BACKUP/STAGE-RC3) and then final, in one run.
#        Phases: 1 read-only preflight, 2 backup, 3 install/upgrade (core+api+gui), 4 DIRECT return path PROVEN before anything
#        active, 5 controller + exit nodes, 6 active routing/firewall tests, 7 hardware switch, 8 API + GUI (router and this
#        computer), 9 Home Assistant (as far as access exists), 10 report with the PASS/FAIL/UNVERIFIED matrix.
#        Optional read-only checks of phases 8/9:  --api-url URL (default http://10.20.0.1)  --api-user NAME (password from
#        TSEM_API_PASSWORD or asked silently)  --gui-url URL  --ha-url URL  --ha-token-file FILE (or TSEM_HA_TOKEN).
#        the native GL.iNet GUI (APPLICATIONS > Tailscale Exit Manager; ADDS files only, undocumented GL.iNet extension
#        interface) is the MAIN GUI and part of the run: its own confirmed step NATIVE-GUI after the API check. --no-native-gui
#        (alias --native-gui is accepted) skips it; LuCI is only the fallback.
#        It stops at the first missing precondition. `diag` = read-only diagnostic bundle + node check, saved on this computer.
#   sh tools/run-rc3-active-mac.sh ... --stage DIR repair        replay the journal of an interrupted wire     confirm: REPAIR
#   sh tools/run-rc3-active-mac.sh ... --stage DIR recover       RECOVERY now (never opens the kill switch)   confirm: RECOVER
#   sh tools/run-rc3-active-mac.sh ... --stage DIR rollback      ROLLBACK to the saved version                confirm: ROLLBACK
#   sh tools/run-rc3-active-mac.sh ... --stage DIR direct        return to DIRECT: OPENS the kill switch      confirm: OPEN-KILLSWITCH
#   sh tools/run-rc3-active-mac.sh ... --stage DIR status
#
# Recovery, rollback and return-to-direct are three different things (docs/rc/rc3-active.md):
#   recover   keeps/reasserts the kill switch from the intent; never runs `tsem set direct`.
#   rollback  restores the previous tsem version; it does not open the guard either.
#   direct    the ONLY command that opens the kill switch, by your explicit decision.
#
# Router writes: staging in a NEW unique /tmp/tsem-rc3-active-stage.<epoch>.<pid> (mkdir without -p, marker
# file, guarded cleanup of exactly that path, like the read-only wrapper), runtime files in /tmp/tsem-rc3-active,
# the backup below /root/tsem-rc3-backup-*, and what the confirmed phases do.
# Exit code: 0 no FAIL, 1 at least one FAIL, 2 refused or declined, 64/66/69 usage/ssh problems.

set -u
HOST=${TSEM_RC3_HOST:-root}
OUT=${TSEM_RC3_OUT:-$HOME/tsem-rc3-active}
STAGE=
TIMEOUT=300
OBSERVE=1
OPT_BK=
OPT_SD=
API_URL=${TSEM_API_URL:-http://10.20.0.1}
API_USER=${TSEM_API_USER:-}
GUI_URL=${TSEM_GUI_URL:-}
HA_URL=${TSEM_HA_URL:-}
NATIVE=1
NATIVE_REQ=1
HA_TOKEN_FILE=${TSEM_HA_TOKEN_FILE:-}
MCURL=${TSEM_MAC_CURL:-curl}
SSHBIN=${TSEM_SSH:-ssh}
while [ $# -gt 0 ]; do
	case $1 in
	--host) [ $# -ge 2 ] || { echo "--host needs a value" >&2; exit 64; }; HOST=$2; shift 2 ;;
	--out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 64; }; OUT=$2; shift 2 ;;
	--stage) [ $# -ge 2 ] || { echo "--stage needs a directory" >&2; exit 64; }; STAGE=$2; shift 2 ;;
	--timeout) [ $# -ge 2 ] || { echo "--timeout needs seconds" >&2; exit 64; }; TIMEOUT=$2; shift 2 ;;
	--no-observe) OBSERVE=0; shift ;;
	--native-gui) NATIVE=1; NATIVE_REQ=1; shift ;;
	--no-native-gui) NATIVE=0; NATIVE_REQ=0; shift ;;
	--api-url) [ $# -ge 2 ] || { echo "--api-url needs a value" >&2; exit 64; }; API_URL=$2; shift 2 ;;
	--api-user) [ $# -ge 2 ] || { echo "--api-user needs a value" >&2; exit 64; }; API_USER=$2; shift 2 ;;
	--gui-url) [ $# -ge 2 ] || { echo "--gui-url needs a value" >&2; exit 64; }; GUI_URL=$2; shift 2 ;;
	--ha-url) [ $# -ge 2 ] || { echo "--ha-url needs a value" >&2; exit 64; }; HA_URL=$2; shift 2 ;;
	--ha-token-file) [ $# -ge 2 ] || { echo "--ha-token-file needs a value" >&2; exit 64; }; HA_TOKEN_FILE=$2; shift 2 ;;
	--backup-dir) [ $# -ge 2 ] || { echo "--backup-dir needs a path" >&2; exit 64; }; OPT_BK=$2; shift 2 ;;
	--stage-dir) [ $# -ge 2 ] || { echo "--stage-dir needs a path" >&2; exit 64; }; OPT_SD=$2; shift 2 ;;
	-h | --help) sed -n '2,30p' "$0"; exit 0 ;;
	-*) echo "unknown option: $1" >&2; exit 64 ;;
	*) break ;;
	esac
done
PHASE=${1:-}
[ $# -gt 0 ] && shift
case $HOST in *[!A-Za-z0-9._@:-]*) echo "unsafe --host value" >&2; exit 64 ;; esac
for _u in "$API_URL" "$GUI_URL" "$HA_URL"; do case $_u in '' | http://* | https://*) ;; *) echo "URLs must start with http:// or https://" >&2; exit 64 ;; esac; case $_u in *[!A-Za-z0-9._:/@-]*) echo "unsafe URL" >&2; exit 64 ;; esac; done
case $API_USER in *[!A-Za-z0-9._-]*) echo "unsafe --api-user" >&2; exit 64 ;; esac
case $TIMEOUT in '' | *[!0-9]*) echo "--timeout must be seconds" >&2; exit 64 ;; esac
[ "$TIMEOUT" -ge 120 ] && [ "$TIMEOUT" -le 3600 ] || { echo "--timeout must be 120..3600 seconds" >&2; exit 64; }
case $PHASE in prepare | final | accept | test | recover | repair | rollback | direct | status | diag) ;; *) echo "usage: $0 [--host H] [--out DIR] --stage DIR prepare|final|accept|test|recover|repair|rollback|direct|status|diag" >&2; exit 64 ;; esac
[ -n "$STAGE" ] || { echo "need --stage DIR (the checkout; the one-liner in docs/rc/rc3-active.md does this)" >&2; exit 64; }
HERE=$(cd "$(dirname "$0")" && pwd)
for f in install.sh src/usr/sbin/tsem tools/tsem-rc3-active.sh tools/tsem-rc3-recover.sh; do
	[ -f "$STAGE/$f" ] || { echo "stage directory lacks $f" >&2; exit 66; }
done
AR_RUN=${TSEM_RC3_AR_RUN:-/tmp/tsem-rc3-active}
SRC_HEAD=$(git -C "$STAGE" rev-parse --verify -q HEAD 2>/dev/null)
case $SRC_HEAD in *[!0-9a-f]* | "") SRC_HEAD=unknown ;; esac

rsh() { "$SSHBIN" -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=6 -o ClearAllForwardings=yes "$HOST" "$@"; }

valid_stage_path() {
	case $1 in
	*[!A-Za-z0-9._/-]* | *..*) return 1 ;;
	/tmp/tsem-rc3-active-stage.[0-9]*.[0-9]*) case ${1#/tmp/tsem-rc3-active-stage.} in *[!0-9.]*) return 1 ;; esac; return 0 ;;
	esac
	return 1
}
STAGED=0
STAGE_DIR=
cleanup_remote() {
	[ "$STAGED" -eq 1 ] || return 0
	STAGED=0
	valid_stage_path "$STAGE_DIR" || { echo "REFUSING to delete '$STAGE_DIR' (not a staging path of this tool)" >&2; return 0; }
	rsh "d=$STAGE_DIR; case \$d in /tmp/tsem-rc3-active-stage.[0-9]*.[0-9]*) [ -d \$d ] && [ ! -L \$d ] && [ -f \$d/.tsem-rc3-stage ] && rm -rf \$d ;; esac" </dev/null >/dev/null 2>&1 ||
		echo "WARNING: could not remove $HOST:$STAGE_DIR (volatile /tmp; gone at reboot)" >&2
}
trap cleanup_remote EXIT INT TERM

mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 73; }
chmod 700 "$OUT" 2>/dev/null
STAMP=$(date +%Y%m%d-%H%M%S)
REPORT=$OUT/active-$PHASE-$HOST-$STAMP.txt
: >"$REPORT"
chmod 600 "$REPORT" 2>/dev/null
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }

# typed confirmation: the phrase must be typed exactly; anything else (and EOF) declines
confirm() { # PHRASE, then description lines
	_ph=$1
	shift
	echo
	for _l in "$@"; do say "  $_l"; done
	printf '  Type exactly  %s  to continue (anything else cancels): ' "$_ph"
	_a=''
	read -r _a || _a=''
	if [ "$_a" = "$_ph" ]; then say "  confirmed: $_ph"; return 0; fi
	say "  not confirmed: nothing was changed by this phase"
	return 1
}

stage_up() {
	STAGE_DIR=/tmp/tsem-rc3-active-stage.$(date +%s).$$
	valid_stage_path "$STAGE_DIR" || { echo "internal error: bad stage path" >&2; exit 70; }
	STAGED=1
	say "staging $STAGE -> $HOST:$STAGE_DIR (new unique /tmp dir; /tmp/glinet-tailscale-exit-manager is not touched)"
	( cd "$STAGE" && tar cf - install.sh uninstall.sh src tools contrib docs 2>/dev/null ) |
		rsh "umask 077 && mkdir $STAGE_DIR && : >$STAGE_DIR/.tsem-rc3-stage && cd $STAGE_DIR && tar xf -" || { echo "staging failed" >&2; exit 69; }
}
RENV="AR_RUN=$AR_RUN TSEM_RC3_COMMIT=$SRC_HEAD"
RS() { rsh "env $RENV sh $STAGE_DIR/tools/tsem-rc3-active.sh $*"; } # router script, output to stdout
# run, tee into the report, return the router script's exit code
run_logged() {
	_rcf=$OUT/.rc.$$
	{ RS "$@" 2>&1; echo $? >"$_rcf"; } | tee -a "$REPORT"
	_r=$(cat "$_rcf" 2>/dev/null || echo 1)
	rm -f "$_rcf"
	return "$_r"
}

say "tsem RC3 active acceptance: phase=$PHASE host=$HOST"
say "code under test: git commit $SRC_HEAD"
say "report: $REPORT"
say "time: $(date '+%Y-%m-%d %H:%M:%S %z')"

backup_dir_remote() { rsh "cat $AR_RUN/backup.dir 2>/dev/null" </dev/null | head -n 1; }
valid_stage_dir() { case $1 in "${TSEM_RC3_BK_BASE:-/root}"/tsem-rc3-stage-[0-9]*) case $1 in *[!A-Za-z0-9._/-]* | *..*) return 1 ;; esac; return 0 ;; esac; return 1; }
valid_backup_dir() { case $1 in "${TSEM_RC3_BK_BASE:-/root}"/tsem-rc3-backup-[0-9]*) case $1 in *[!A-Za-z0-9._/-]* | *..*) return 1 ;; esac; return 0 ;; esac; return 1; }

# ------------------------------------------------------------------ prepare
do_prepare() {
	stage_up
	say; say "### Phase A: preflight (read-only)"
	_pf=$OUT/.pf.$$
	run_logged preflight >"$_pf"; _prc=$?
	cat "$_pf"
	_path=$(sed -n 's/^SSH_PATH=//p' "$_pf" | tail -n 1)
	rm -f "$_pf"
	say "ssh path to the router: ${_path:-unknown}"
	if [ "$_prc" -ne 0 ]; then say "Preflight has FAIL lines: fix them before going on."; return 1; fi
	confirm BACKUP "Phase A writes ONLY a new directory /root/tsem-rc3-backup-<time> on the router (RC2 files, config, intent, GL hook, boot links," \
		"firewall/network UCI, iptables, ip rules, routes, loaded modules, hardware switch state) and copies it to $OUT." \
		"No service, rule or setting is changed." || return 2
	run_logged backup || { say "Backup failed: stopping before any install."; return 1; }
	_bk=$(backup_dir_remote)
	valid_backup_dir "$_bk" || { say "$(printf '%-5s %-24s ' FAIL backup.path)unexpected backup path '$_bk'"; return 1; }
	_tar=$OUT/backup-$HOST-$STAMP.tar
	rsh "sh $STAGE_DIR/tools/tsem-rc3-active.sh backup-stream $_bk" </dev/null >"$_tar" 2>/dev/null
	chmod 600 "$_tar" 2>/dev/null
	if [ -s "$_tar" ] && tar tf "$_tar" >/dev/null 2>&1; then
		say "$(printf '%-5s %-24s ' PASS backup.copy)backup copied to this computer: $_tar ($(tar tf "$_tar" | wc -l | tr -d ' ') entries, private, mode 600)"
		echo "$_bk" >"$OUT/latest-backup-dir"
	else say "$(printf '%-5s %-24s ' FAIL backup.copy)could not copy the backup to this computer: do NOT continue"; return 1; fi
	verify_backup_copy "$_tar" || return 1
	confirm STAGE-RC3 "Phase B copies the tested tree ($SRC_HEAD) into a NEW side directory /root/tsem-rc3-stage-<time> on the router and checks it there" \
		"(hash manifest, shell syntax, a trial install into a throw-away root, and that every live handler is byte-identical afterwards)." \
		"It changes NO live file: not the tsem files, hotplug handler, fw3 include, init script, boot links, GL switch hook, config, intent, rules, routes or services." || return 2
	run_logged "stage-rc3 $_bk" || { say "Staging has FAIL lines: nothing was wired."; return 1; }
	_sd=$(rsh "cat $AR_RUN/stage.dir 2>/dev/null" </dev/null | head -n 1)
	valid_stage_dir "$_sd" || { say "$(printf '%-5s %-24s ' FAIL stage.path)unexpected stage path '$_sd'"; return 1; }
	echo "$_sd" >"$OUT/latest-stage-dir"
	say; say "Prepared (RC3 is only staged, NOT active). Next: sh tools/run-rc3-active-mac.sh --stage DIR test all   (asks WIRE-RC3 after the watchdog is armed)"
}
# the copy on this computer must be complete and consistent, with a hash tool on THIS side too
verify_backup_copy() {
	_t=$1
	_h=''
	for _c in sha256sum "shasum -a 256" md5sum "md5 -q"; do command -v "${_c%% *}" >/dev/null 2>&1 && { _h=$_c; break; }; done
	[ -n "$_h" ] || { say "$(printf '%-5s %-24s ' FAIL backup.copy.hash)no hash tool on this computer: the copied backup cannot be verified, do NOT continue"; return 1; }
	_x=$OUT/.bkv.$$; mkdir -p "$_x"
	if ! tar xf "$_t" -C "$_x" 2>/dev/null; then say "$(printf '%-5s %-24s ' FAIL backup.copy.extract)copy does not extract"; rm -rf "$_x"; return 1; fi
	_d=$(ls -d "$_x"/tsem-rc3-backup-* 2>/dev/null | head -n 1)
	_want=$(cat "$_d/files.tar.sum" 2>/dev/null)
	_got=$($_h "$_d/files.tar" 2>/dev/null | awk '{print $1}')
	if [ -s "$_d/manifest.txt" ] && [ -s "$_d/expected.txt" ] && [ -n "$_want" ] && [ "$_want" = "$_got" ] && [ "$(wc -c <"$_d/files.tar" | tr -d ' ')" -gt 0 ]; then
		say "$(printf '%-5s %-24s ' PASS backup.copy.verified)the copy on this computer has the router's checksum ($_want) and a manifest"; rm -rf "$_x"; return 0
	fi
	say "$(printf '%-5s %-24s ' FAIL backup.copy.verified)copy checksum '$_got' differs from the router's '$_want' or files are missing: do NOT continue"; rm -rf "$_x"; return 1
}

# ------------------------------------------------------------------ test
# observer: while the router holds at a named point, check the INTERNET FROM THIS MAC (a LAN client)
observer_loop() {
	while [ ! -e "$OUT/.obs-stop.$$" ]; do
		_h=$(rsh "ls $AR_RUN/obs/ 2>/dev/null | sed -n 's/^hold\.//p'" </dev/null 2>/dev/null | head -n 1)
		if [ -n "$_h" ]; then
			observe_point "$_h"
			rsh "touch $AR_RUN/obs/done.$_h" </dev/null >/dev/null 2>&1
		fi
		sleep 1
	done
}
# mac_curl 4|6: sets MC_OUT (public ip or empty) and MC_RC (curl exit code; 127 if curl is missing)
mac_curl() {
	MC_OUT='' MC_RC=127
	_cb=${TSEM_RC3_CURL:-curl}
	command -v "$_cb" >/dev/null 2>&1 || return 0
	if [ "$1" = 4 ]; then _u=https://1.1.1.1/cdn-cgi/trace; else _u='https://[2606:4700:4700::1111]/cdn-cgi/trace'; fi
	_o=$("$_cb" -"$1" -fsS --connect-timeout 5 --max-time 8 "$_u" 2>/dev/null); MC_RC=$?
	MC_OUT=$(printf '%s\n' "$_o" | sed -n 's/^ip=//p' | head -n 1)
}
mac_ip4() { mac_curl 4; printf '%s' "$MC_OUT"; }
mac_ip6() { mac_curl 6; printf '%s' "$MC_OUT"; }
mac_dns() { if command -v dig >/dev/null 2>&1; then dig +time=3 +tries=1 +short example.com 2>/dev/null | head -n 1; else nslookup -timeout=3 example.com 2>/dev/null | sed -n 's/^Address: *//p' | tail -n 1; fi; }
EXPECT_IP=''
observe_point() { # emits Mac-side evidence lines (appended to the report)
	_n=$1
	if ! command -v "${TSEM_RC3_CURL:-curl}" >/dev/null 2>&1; then say "$(printf '%-5s %-24s ' FAIL mac.$_n)curl is missing on this computer: no client-side evidence, the observation is inconclusive (NOT a pass)"; return 0; fi
	mac_curl 4; _v4=$MC_OUT _rc4=$MC_RC
	mac_curl 6; _v6=$MC_OUT _rc6=$MC_RC
	_d=$(mac_dns)
	case $_n in
	blocked)
		# the Mac must NOT reach the Internet; "no answer" only counts when curl itself works (positive control from a
		# german point: EXPECT_IP set) and failed with resolve/connect/timeout, never with a TLS/usage/other error
		_blk4=no; case $_rc4 in 6 | 7 | 28) _blk4=yes ;; esac
		if [ -n "$_v4" ] || [ -n "$_v6" ]; then say "$(printf '%-5s %-24s ' FAIL mac.blocked)LAN client reached the Internet while BLOCKED: v4='${_v4}' v6='${_v6}' (UNPROTECTED PATH)"
		elif [ -z "$EXPECT_IP" ]; then say "$(printf '%-5s %-24s ' FAIL mac.blocked)no positive control: this computer never reached the Internet at a german point (curl may be broken): inconclusive, NOT a pass"
		elif [ "$_blk4" = yes ]; then say "$(printf '%-5s %-24s ' PASS mac.blocked)LAN client has NO IPv4 Internet while BLOCKED (curl exit $_rc4, and curl worked at a german point: no unprotected WAN fallback seen from the client)"
		else say "$(printf '%-5s %-24s ' FAIL mac.blocked)curl exit $_rc4 does not prove a blocked path (inconclusive, NOT a pass)"; fi
		[ -z "$_d" ] && say "$(printf '%-5s %-24s ' PASS mac.blocked.dns)LAN client DNS did not resolve while BLOCKED" || say "$(printf '%-5s %-24s ' WARN mac.blocked.dns)LAN client DNS answered ($_d): cached or local answer? check the router DNS chain"
		;;
	*)
		if [ -n "$_v4" ]; then
			say "$(printf '%-5s %-24s ' PASS mac.$_n)LAN client IPv4 egress works (public IP $_v4)"
			[ -z "$EXPECT_IP" ] && EXPECT_IP=$_v4
		else say "$(printf '%-5s %-24s ' WARN mac.$_n)LAN client has no IPv4 Internet at this point"; fi
		if [ -n "$_v6" ]; then say "$(printf '%-5s %-24s ' WARN mac.$_n.v6)LAN client reached IPv6 Internet ($_v6): confirm that this is the exit node's IPv6 and not the WAN's"; else say "$(printf '%-5s %-24s ' INFO mac.$_n.v6)LAN client has no IPv6 Internet (nothing leaked)"; fi
		[ -n "$_d" ] && say "$(printf '%-5s %-24s ' INFO mac.$_n.dns)LAN client resolves example.com ($_d)" || say "$(printf '%-5s %-24s ' WARN mac.$_n.dns)LAN client DNS did not resolve"
		;;
	esac
}

TESTS_ALL="t00_activate t01_primary t02_failover t03_both_down t04_dns t05_ipv6 t06_fastpath t07_fwreload t08_tsrestart"
test_effect() {
	case $1 in
	t00_activate) echo "switches the router to mode german: ALL LAN clients are routed through the exit node; if no exit node works they have no Internet" ;;
	t01_primary) echo "read-only checks of the primary exit node" ;;
	t02_failover) echo "forces primary -> secondary -> primary by identity mismatch in foreground ticks; clients briefly switch exit node" ;;
	t03_both_down) echo "simulates BOTH exit nodes down: LAN clients LOSE the Internet on purpose (BLOCKED) until the nodes are usable again" ;;
	t04_dns) echo "read-only DNS checks" ;;
	t05_ipv6) echo "read-only IPv6 checks" ;;
	t06_fastpath) echo "read-only SFE/fast-path checks" ;;
	t07_fwreload) echo "reloads the firewall (fw3): netfilter chains are flushed for a moment, policy routing must hold; running connections may stall" ;;
	t08_tsrestart) echo "RESTARTS tailscale: the exit node disappears for some seconds; the LAN has no Internet meanwhile; an SSH session over Tailscale would be cut" ;;
	esac
}

do_test() {
	_sel=${*:-all}
	[ "$_sel" != all ] || _sel=$TESTS_ALL
	for _t in $_sel; do case " $TESTS_ALL " in *" $_t "*) ;; *) echo "unknown test: $_t (valid: $TESTS_ALL all)" >&2; return 64 ;; esac; done
	stage_up
	say; say "### Preflight (read-only)"
	_pf=$OUT/.pf.$$
	run_logged preflight >"$_pf"; _prc=$?
	cat "$_pf"
	_path=$(sed -n 's/^SSH_PATH=//p' "$_pf" | tail -n 1)
	rm -f "$_pf"
	say "ssh path to the router: ${_path:-unknown}"
	if [ "$_prc" -ne 0 ]; then say "Preflight has FAIL lines: nothing active was started."; return 1; fi
	_obs=0
	if [ "$OBSERVE" -eq 1 ] && [ "$_path" = lan ]; then
		_obs=1; say "observer: this computer is a LAN client and checks the Internet from the client side at the hold points"
		# positive control for the BLOCKED observation: this computer's curl must reach the Internet before the faults start
		mac_curl 4
		if [ -n "$MC_OUT" ]; then EXPECT_IP=$MC_OUT; say "$(printf '%-5s %-24s ' PASS mac.control)curl on this computer reaches the Internet before the tests (public IP $MC_OUT): a later failure is real evidence"
		else say "$(printf '%-5s %-24s ' WARN mac.control)curl on this computer does not reach the Internet now (exit $MC_RC): the BLOCKED observation will count as inconclusive unless a german hold point succeeds first"; fi
	else
		say "observer: OFF (no LAN client path or --no-observe): router-side evidence only"
	fi
	confirm ARM-RECOVERY "Phase C starts an independent watchdog process on the router (own process, not tsem, not this Mac)." \
		"If no keepalive arrives for ${TIMEOUT}s (this Mac gone, ssh dead, a test stuck) it runs RECOVERY:" \
		"  removes the test fault, starts tailscaled if needed, 'tsem reapply' (guard from the intent), 'tsem tick' until an exit node is active." \
		"RECOVERY never opens the kill switch: with mode german the LAN stays blocked rather than unprotected." \
		"Manual recovery any time on the router:  sh $AR_RUN/recover.sh now" || return 2
	run_logged recovery-arm "$TIMEOUT" || { say "Watchdog did not arm: no active test is allowed."; return 1; }
	_env="AR_OBSERVER=$_obs AR_SSH_PATH=${_path:-unknown} AR_RUN=$AR_RUN AR_STRICT_PRIMARY=1"
	_bk=$(cat "$OUT/latest-backup-dir" 2>/dev/null) _sd=$(cat "$OUT/latest-stage-dir" 2>/dev/null)
	if ! valid_backup_dir "$_bk" || ! valid_stage_dir "$_sd"; then
		say "$(printf '%-5s %-24s ' FAIL wire.inputs)no verified backup and staged RC3 known on this computer (run prepare first): nothing is wired, no test runs"
		run_logged recovery-disarm; return 1
	fi
	# Phase C1 (own step, own phrase): the LAN -> tailscale0 masquerading is checked read-only; a repair is a separate approval.
	# It is independent of the kill switch (no TSEM chain, no ip rule, no exit node) and never reloads the firewall.
	say; say "### Masquerading check (read-only, tsem-masq from the staged copy)"
	_mqs=$STAGE_DIR/src/usr/sbin/tsem-masq
	_mqo=$(rsh "sh $_mqs check" </dev/null 2>&1); _mqr=$?
	printf '%s\n' "$_mqo" | tee -a "$REPORT"
	case $_mqr in
	0) say "$(printf '%-5s %-24s ' PASS masq.step)masquerading is consistent: nothing to repair" ;;
	3) say "$(printf '%-5s %-24s ' SKIP masq.step)not applicable on this router (no uci or no zone tailscale0)" ;;
	*)
		say "$(printf '%-5s %-24s ' WARN masq.step)LAN -> tailscale0 masquerading is NOT consistent (exit $_mqr): exit-node traffic from LAN clients will not work until it is repaired"
		if confirm FIX-MASQ "Phase C1 repairs ONLY the masquerading: backup of /etc/config/firewall, firewall.<zone tailscale0>.masq=1 (uci commit) and one MASQUERADE rule in the nat chain zone_tailscale0_postrouting." \
			"No firewall reload, no TSEM chain, no ip rule, no exit node, no zone/forwarding is created. Undo: cp /etc/tsem/backup/masq/firewall.<time> /etc/config/firewall"; then
			_mqo=$(rsh "sh $_mqs ensure --no-reload" </dev/null 2>&1); _mqr=$?
			printf '%s\n' "$_mqo" | tee -a "$REPORT"
			_mqo=$(rsh "sh $_mqs check" </dev/null 2>&1); _mqr=$?
			printf '%s\n' "$_mqo" | tee -a "$REPORT"
			if [ "$_mqr" -eq 0 ]; then say "$(printf '%-5s %-24s ' PASS masq.repair)repaired and verified"
			else say "$(printf '%-5s %-24s ' FAIL masq.repair)still inconsistent after the repair (if the zone chain is missing a firewall reload is needed; not done here)"; run_logged recovery-disarm; return 1; fi
		else say "$(printf '%-5s %-24s ' WARN masq.step)repair declined: exit-node traffic from LAN clients stays broken; the kill switch is unaffected"; fi ;;
	esac
	confirm WIRE-RC3 "Phase C2 puts RC3 into the LIVE router: install.sh --yes from the verified staged copy (journaled; an interrupted run is repairable with the 'repair' phase)." \
		"This installs the hotplug handler and fw3 include of RC3: from here RC3 reacts to interface and firewall events. It keeps the intent, tsem.conf, the GL switch hook and the boot links." \
		"If the verification fails, the previous version is restored automatically and the guard is re-applied from the intent (never opened)." || { run_logged recovery-disarm; return 2; }
	run_logged "wire --confirm-wire $_bk $_sd"; _wrc=$?
	if [ "$_wrc" -ne 0 ]; then say "Wiring failed and was restored (or could not be restored: read the FAIL lines). No test is run."; run_logged recovery-disarm; return 1; fi
	_stop=0
	for _t in $_sel; do
		# F07: the watchdog must be alive BEFORE the question is shown AND while a person reads and types.
		wd_ensure || { say "$(printf '%-5s %-24s ' FAIL wd.before.$_t)the recovery watchdog is not protecting the router and could not be re-armed: test $_t and all later tests are NOT started"; _stop=1; break; }
		confirm_ka "START $_t" "Test $_t: $(test_effect "$_t")" "Recovery watchdog is armed (${TIMEOUT}s) and is kept alive while you read this. Ctrl-C stops everything; the watchdog then recovers." ||
			{ say "Test $_t and all later tests are not started."; break; }
		# the confirmation can be slow: check once more, right before the test starts
		wd_ensure || { say "$(printf '%-5s %-24s ' FAIL wd.start.$_t)the watchdog stopped protecting the router while waiting for the confirmation: test $_t is NOT started"; _stop=1; break; }
		_ob=''
		if [ "$_obs" -eq 1 ]; then rm -f "$OUT/.obs-stop.$$"; observer_loop & _ob=$!; fi
		say; say "### $_t"
		RENV=$_env run_logged "test $_t"; _trc=$?
		[ -z "$_ob" ] || { : >"$OUT/.obs-stop.$$"; wait "$_ob" 2>/dev/null; rm -f "$OUT/.obs-stop.$$"; }
		case $_trc in
		0) ;;
		2) say "$(printf '%-5s %-24s ' FAIL run.$_t)test $_t was REFUSED by the router script (exit 2): the run STOPS here, later tests are NOT started"; _stop=1; break ;;
		*) say "(test $_t reported FAIL, exit $_trc)" ;;
		esac
	done
	say; say "### Final state"
	run_logged status || true
	# F07: ask about DISARM only when there is a running watchdog to disarm; otherwise say what really happened.
	if RS recovery-ensure >/dev/null 2>&1; then
		if confirm DISARM "Stops the recovery watchdog. The kill switch stays as it is (guard german or blocked)." "Without DISARM the watchdog runs RECOVERY at its deadline (harmless if everything is fine)."; then
			run_logged recovery-disarm
		fi
	else
		say "No recovery watchdog is running (nothing to disarm). State and reason:"
		run_logged recovery-status || true
		[ "$_stop" -eq 1 ] || say "NOTE: the watchdog was lost during the run; results after that point were obtained WITHOUT recovery protection."
		_stop=1
	fi
	[ "$_stop" -eq 0 ] || return 1
}

# ------------------------------------------------------------------ final: the whole acceptance in one run
FINAL_FAILED=0
# F07: the watchdog must be proven alive before a critical step, never assumed. recovery-ensure answers truthfully
# (armed+heartbeat / fired / dead / absent). A watchdog that is not alive is re-armed with the full, verified arm
# routine (it exercises the mechanism first); if that fails the caller stops.
wd_ensure() {
	run_logged recovery-ensure && return 0
	say "The recovery watchdog is not alive (see above). Re-arming it with the full verification (${TIMEOUT}s) before anything critical runs."
	run_logged recovery-disarm >/dev/null 2>&1 || true
	run_logged "recovery-arm $TIMEOUT" || return 1
	run_logged recovery-ensure
}
# confirm with a keepalive loop in the background: a slow human must never let the watchdog deadline pass
confirm_ka() {
	( while :; do sleep "${KA_EVERY:-20}"; RS recovery-keepalive >/dev/null 2>&1 </dev/null || :; done ) &
	_kap=$!
	confirm "$@"
	_kar=$?
	kill "$_kap" 2>/dev/null
	wait "$_kap" 2>/dev/null
	return "$_kar"
}
# save_bundle TAG: read-only diagnostic bundle of the router, saved on THIS computer (call it BEFORE anything changes state)
save_bundle() {
	_bf=$OUT/diag-bundle-$HOST-$STAMP-$1.txt
	say "diagnostic bundle (read-only, secrets removed) -> $_bf"
	if RS diag-bundle >"$_bf" 2>&1 </dev/null; then say "$(printf '%-5s %-24s ' INFO diag.saved)$_bf ($(wc -l <"$_bf" | tr -d ' ') lines)"
	else say "$(printf '%-5s %-24s ' WARN diag.saved)the bundle could not be fetched completely (router unreachable?): partial file $_bf"; fi
}
# abort_recover WHY: stop everything, start the recovery (never opens the kill switch), show the state, keep the diagnosis
abort_recover() {
	say; say "### STOP: $1"
	say "Recovery is started now (removes test faults, starts tailscaled if needed, 'tsem reapply' from the intent, 'tsem tick'). It never opens the kill switch."
	save_bundle before-recovery
	run_logged recover || true
	run_logged status || true
	run_logged recovery-disarm || true
	say "The router is left with the guard closed (german/blocked) or direct only if that was your explicit mode before."
	say "NO INTERNET FOR THE LAN? That is the closed kill switch doing its job. To go online unprotected, YOUR decision: ssh root 'tsem set direct'"
	say "Why a node was rejected (logged since this run):  ssh root 'logread | grep \"tsem: probe\" | tail -20'"
	say "Options: 'repair' (an interrupted install), 'rollback' (back to the previous tsem version), 'direct' (explicitly open the kill switch). Read the FAIL lines above."
	FINAL_FAILED=1
	return 1
}
ask_switch() {
	say; say "  Hardware switch gate: the physical switch position cannot be read by software."
	say "  Put the GL hardware switch where you want it for normal operation and do NOT touch it during the whole run."
	say "  ON = the 'Tailscale Germany' position (the tsem hook maps on/1/true to german), OFF = direct (off/0/false)."
	say "  The run sets the router to german at the end whatever the switch says; a switch that stands on OFF changes nothing until you next move it."
	printf '  Type exactly  SWITCH-ON  or  SWITCH-OFF  to state the position (anything else cancels): '
	_a=''
	read -r _a || _a=''
	case $_a in
	SWITCH-ON) say "  confirmed: the switch stands on ON (german)"; HW_SWITCH=on; return 0 ;;
	SWITCH-OFF) say "  confirmed: the switch stands on OFF (direct)"; HW_SWITCH=off; say "$(printf '%-5s %-24s ' WARN hwswitch.declared)the switch stands on OFF but the run ends in german: the next move of the switch to ON is a no-op, a move to OFF would open the kill switch by your decision"; return 0 ;;
	esac
	say "  not confirmed: nothing was changed"
	return 1
}
# acceptance_table: every success criterion is PASS only if the report holds the PASS line(s) for it; otherwise FAIL or UNVERIFIED
crit() { # label  pattern-of-pass-names  [pattern-of-fail-names]
	_l=$1; _pp=$2
	if grep -E "^FAIL +($_pp)( |\$)" "$REPORT" >/dev/null 2>&1; then _v=FAIL
	elif grep -E "^PASS +($_pp)( |\$)" "$REPORT" >/dev/null 2>&1; then _v=PASS
	else _v=UNVERIFIED; fi
	say "$(printf '  %-12s %s' "$_v" "$_l")"
	case $_v in PASS) ACC_PASS=$((ACC_PASS + 1)) ;; *) ACC_BAD=$((ACC_BAD + 1)) ;; esac
}
acceptance_table() {
	ACC_PASS=0 ACC_BAD=0
	say; say "ACCEPTANCE CRITERIA (PASS only with evidence in this report; everything else is NOT accepted)"
	crit "DIRECT internet via the WAN (hardware switch OFF)" "switch\\.direct\\.egress"
	crit "DIRECT proven from this computer as a LAN client before the first german test" "mac\\.direct"
	crit "GERMAN internet via a German exit node" "t01\\.egress|final\\.mode"
	crit "Primary exit node verified" "t01\\.primary"
	crit "Secondary exit node verified (failover to it works)" "t02\\.egress|t02\\.exit"
	crit "Failover primary -> secondary" "t02\\.switch"
	crit "Both nodes unavailable: internet stays blocked" "t03\\.blocked"
	crit "Return to the primary" "t02\\.return"
	crit "Hardware switch GERMAN -> DIRECT" "switch\\.direct"
	crit "Hardware switch DIRECT -> GERMAN" "switch\\.active"
	crit "remote-site subnets routed (router and LAN)" "extnet\\.[0-9./]+\\.lan"
	crit "No DNS leak" "t04\\.resolve"
	crit "No IPv6 leak" "t05\\.deny"
	crit "Recovery watchdog proven" "recovery\\.verified"
	crit "TSEM in a documented consistent state" "final\\.intent\\.valid"
	crit "DIRECT return path proven before any active step" "direct\\.path\\.proven"
	crit "Local API: unauthenticated access refused (from this computer)" "mac\\.api\\.unauth\\.write"
	crit "Local API not reachable from the WAN (router firewall)" "api\\.wan-exposure"
	crit "Local API: authenticated read and write work" "mac\\.api\\.auth\\.rw"
	crit "GUI served and usable (LuCI view)" "mac\\.gui\\.served"
	[ "$NATIVE_REQ" -eq 0 ] || crit "Native GL.iNet GUI: served, unauthenticated DIRECT refused" "mac\\.native\\.unauth\\.state"
	[ "$NATIVE_REQ" -eq 0 ] || crit "Native GL.iNet GUI seen in the browser (user-attested)" "mac\\.native\\.attested"
	say "  => ROUTER: $ACC_PASS criteria PASS, $ACC_BAD not accepted (FAIL or UNVERIFIED). A criterion without a PASS line counts as NOT accepted."
	ROUTER_BAD=$ACC_BAD
	say; say "HOME ASSISTANT CRITERION (separate: it never makes the router verdict better or worse)"
	ACC_PASS=0 ACC_BAD=0
	crit "Home Assistant integration matches the router (entities, authenticated control, same state)" "ha\\.entities"
	HA_BAD=$ACC_BAD
	ACC_BAD=$ROUTER_BAD
}
HW_SWITCH=unknown
# ---------------------------------------------------------------- phases 8/9: API, GUI, Home Assistant (this computer's view)
mrow() { say "$(printf '%-5s %-24s ' "$1" "$2")$3"; }
ubus_rpc() { # session object method json -> body (empty if unreachable)
	"$MCURL" -s -m 10 -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"$2\",\"$3\",$4]}" "$API_URL/ubus" 2>/dev/null
}
mac_api_gui_check() {
	API_FAILS=0 _gui_only=''
	command -v "$MCURL" >/dev/null 2>&1 || { mrow WARN mac.api.reachable "UNVERIFIED: curl is not available on this computer: API, GUI and the Home Assistant path were not checked from here"; return 0; }
	_nul=00000000000000000000000000000000
	_o=$(ubus_rpc "$_nul" session login '{"username":"tsem-no-such-user","password":"x"}')
	case $_o in
	*'"jsonrpc"'*) mrow PASS mac.api.reachable "$API_URL/ubus answers from this computer" ;;
	*) mrow WARN mac.api.reachable "UNVERIFIED: no ubus endpoint at $API_URL (use --api-url; LuCI/uhttpd must serve /ubus). The authentication checks below could not run."; _gui_only=1 ;;
	esac
	if [ -z "${_gui_only:-}" ]; then
		case $_o in *'"result":[0'*) mrow FAIL mac.api.badlogin "a bogus user could log in"; API_FAILS=$((API_FAILS + 1)) ;; *) mrow PASS mac.api.badlogin "a login with a bogus user is refused" ;; esac
		_o=$(ubus_rpc "$_nul" tsem status '{}')
		case $_o in *'"ok":true'*) mrow FAIL mac.api.unauth.read "status is readable WITHOUT a session"; API_FAILS=$((API_FAILS + 1)) ;; *) mrow PASS mac.api.unauth.read "an unauthenticated read is refused" ;; esac
		_o=$(ubus_rpc "$_nul" tsem config_set '{"primary":"not-an-ip"}')
		case $_o in *'"ok":'*) mrow FAIL mac.api.unauth.write "a write method ANSWERED without a session"; API_FAILS=$((API_FAILS + 1)) ;; *) mrow PASS mac.api.unauth.write "an unauthenticated write is refused" ;; esac
		if [ -n "$API_USER" ]; then
			_pw=${TSEM_API_PASSWORD:-}
			if [ -z "$_pw" ] && [ -t 0 ]; then printf '  password for router user %s (not shown): ' "$API_USER"; stty -echo 2>/dev/null; read -r _pw || _pw=''; stty echo 2>/dev/null; echo; fi
			if [ -z "$_pw" ]; then mrow WARN mac.api.auth.rw "UNVERIFIED: no password (TSEM_API_PASSWORD): the authenticated read/write path was not checked"
			else
				_o=$(ubus_rpc "$_nul" session login "{\"username\":\"$API_USER\",\"password\":\"x$$bad\"}")
				case $_o in *'"result":[0'*) mrow FAIL mac.api.badpass "a wrong password was accepted"; API_FAILS=$((API_FAILS + 1)) ;; *) mrow PASS mac.api.badpass "a wrong password is refused" ;; esac
				_o=$(ubus_rpc "$_nul" session login "{\"username\":\"$API_USER\",\"password\":\"$_pw\"}")
				_sid=$(printf '%s' "$_o" | sed -n 's/.*"ubus_rpc_session": *"\([0-9a-f]*\)".*/\1/p')
				if [ -z "$_sid" ]; then mrow FAIL mac.api.auth.rw "login as $API_USER failed"; API_FAILS=$((API_FAILS + 1))
				else
					_st=$(ubus_rpc "$_sid" tsem status '{}' | tr -d ' \n\t')
					_rm=$(RS status 2>/dev/null | sed -n 's/.*mode=\([a-z]*\).*/\1/p' | head -n 1)
					case $_st in *'"ok":true'*"\"mode\":\"$_rm\""*) _rd=1 ;; *) _rd=0 ;; esac
					# the write path is exercised with a request that changes nothing (mode german while german)
					_wr=0
					if [ "$_rm" = german ]; then
						_w=$(ubus_rpc "$_sid" tsem set_mode '{"mode":"german","source":"api"}' | tr -d ' \n\t')
						case $_w in *'"ok":true'*'"requested":"german"'*"\"mode\":\"german\""*) _wr=1 ;; esac
					fi
					if [ "$_rd" = 1 ] && [ "$_wr" = 1 ]; then mrow PASS mac.api.auth.rw "authenticated read matches the controller (mode=$_rm) and the write path answers with the state it reached (no-op request)"
					else mrow FAIL mac.api.auth.rw "authenticated read=$_rd write=$_wr (router mode '$_rm')"; API_FAILS=$((API_FAILS + 1)); fi
				fi
			fi
		else
			mrow WARN mac.api.auth.rw "UNVERIFIED: no --api-user: the authenticated read/write path was not checked from this computer"
		fi
	fi
	# GUI: is the view served, and does LuCI exist at all?
	_g=${GUI_URL:-$API_URL}
	_gf=$OUT/.gui.$$
	_code=$("$MCURL" -s -m 10 -o "$_gf" -w '%{http_code}' "$_g/luci-static/resources/view/tsem/status.js" 2>/dev/null)
	if [ "$_code" = 200 ] && grep -q "object: 'tsem'" "$_gf" 2>/dev/null; then mrow PASS mac.gui.served "$_g serves the TSEM view (status.js)"
	else
		_lc=$("$MCURL" -s -m 10 -o /dev/null -w '%{http_code}' "$_g/luci-static/resources/luci.js" 2>/dev/null)
		if [ "$_lc" = 200 ]; then mrow FAIL mac.gui.served "LuCI is there at $_g but the TSEM view is not served (HTTP $_code)"; API_FAILS=$((API_FAILS + 1))
		else mrow WARN mac.gui.served "UNVERIFIED: LuCI was not found at $_g (HTTP $_lc): the GUI has no host there. Use --gui-url if LuCI listens elsewhere, or install luci-base."; fi
	fi
	rm -f "$_gf"
	return "$API_FAILS"
}
mac_native_check() {
	command -v "$MCURL" >/dev/null 2>&1 || { mrow WARN mac.native.served "UNVERIFIED: curl is not available on this computer"; return 0; }
	_g=${GUI_URL:-$API_URL}
	_nf=$OUT/.native.$$
	_code=$("$MCURL" -s -m 10 -o "$_nf" -w '%{http_code}' "$_g/views/gl-sdk4-ui-tsem.common.js" 2>/dev/null)
	if [ "$_code" = 200 ] && grep -q "name: 'tsem'" "$_nf" 2>/dev/null; then mrow PASS mac.native.served "$_g serves the TSEM view bundle"
	else mrow WARN mac.native.served "UNVERIFIED: the bundle is not served at $_g/views (HTTP $_code): the GL.iNet UI may be on another URL (--gui-url) or the file is not served as assumed"; fi
	rm -f "$_nf"
	# a call without a session must not be answered by the native RPC object
	_o=$("$MCURL" -s -m 10 -H 'Content-Type: application/json' -H 'glinet: 1' -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["","tsem","call",{"m":"set_mode","p":{"mode":"direct","confirm":true}}]}' "$_g/rpc" 2>/dev/null)
	case $_o in
	*'"ok"'*) mrow FAIL mac.native.unauth "the native RPC object ANSWERED a DIRECT request without a session"; return 1 ;;
	'') mrow WARN mac.native.unauth "UNVERIFIED: no answer from $_g/rpc: the unauthenticated refusal could not be shown" ;;
	*) mrow PASS mac.native.unauth "an unauthenticated native RPC call is refused" ;;
	esac
	# the state after that request must still be the one before it
	_rm=$(RS status 2>/dev/null | sed -n 's/.*mode=\([a-z]*\).*/\1/p' | head -n 1)
	[ "$_rm" = german ] && mrow PASS mac.native.unauth.state "the mode is still german after the unauthenticated DIRECT attempt" || { mrow FAIL mac.native.unauth.state "the router mode is '$_rm' after an unauthenticated DIRECT attempt"; return 1; }
	# what only a person with a browser can see is attested, never assumed
	printf '  Open the GL.iNet web UI (%s), log in as usual: is there APPLICATIONS > Tailscale Exit Manager right below Tailscale, does it open WITHOUT a LuCI login and show the controller state (also on the phone)?\n  Type exactly  NATIVE-OK  to attest it, or  NATIVE-SKIP  to leave it UNVERIFIED: ' "$_g"
	_a=''; read -r _a || _a=''
	case $_a in
	NATIVE-OK) mrow PASS mac.native.attested "user-attested: menu entry, state display and login-free access were seen in the GL.iNet UI (not machine-verified)" ;;
	*) mrow WARN mac.native.attested "UNVERIFIED: the native GUI was not confirmed in a browser" ;;
	esac
	return 0
}
mac_ha_check() {
	HA_FAILS=0
	if [ -z "$HA_URL" ]; then mrow WARN ha.entities "UNVERIFIED: no --ha-url: the Home Assistant integration was not checked (software-tested only, never installed in a real Home Assistant)"; return 0; fi
	_tok=${TSEM_HA_TOKEN:-}
	[ -z "$_tok" ] && [ -n "$HA_TOKEN_FILE" ] && [ -r "$HA_TOKEN_FILE" ] && _tok=$(head -n 1 "$HA_TOKEN_FILE" | tr -d ' \r\n')
	if [ -z "$_tok" ]; then mrow WARN ha.entities "UNVERIFIED: no token (--ha-token-file or TSEM_HA_TOKEN): Home Assistant was not read"; return 0; fi
	command -v "$MCURL" >/dev/null 2>&1 || { mrow WARN ha.entities "UNVERIFIED: curl is not available"; return 0; }
	_hs() { "$MCURL" -s -m 10 -H "Authorization: Bearer $_tok" -H 'Content-Type: application/json' "$HA_URL/api/states/$1" 2>/dev/null; }
	_rm=$(RS status 2>/dev/null | sed -n 's/.*mode=\([a-z]*\).*/\1/p' | head -n 1)
	_miss=''
	for _e in switch.tailscale_exit_manager_exit_node_mode sensor.tailscale_exit_manager_operating_mode sensor.tailscale_exit_manager_active_exit_node \
		sensor.tailscale_exit_manager_failover_status binary_sensor.tailscale_exit_manager_kill_switch_active binary_sensor.tailscale_exit_manager_controller_connection; do
		_b=$(_hs "$_e")
		case $_b in *'"state"'*) ;; *) _miss="$_miss $_e" ;; esac
	done
	if [ -n "$_miss" ]; then mrow FAIL ha.entities "Home Assistant does not know these TSEM entities:$_miss (integration not installed or named differently)"; HA_FAILS=1; return 1; fi
	_ms=$(_hs sensor.tailscale_exit_manager_operating_mode | sed -n 's/.*"state": *"\([^"]*\)".*/\1/p')
	_cs=$(_hs binary_sensor.tailscale_exit_manager_controller_connection | sed -n 's/.*"state": *"\([^"]*\)".*/\1/p')
	if [ "$_ms" = "$_rm" ] && [ "$_cs" = on ]; then mrow PASS ha.entities "Home Assistant shows operating mode '$_ms' (= the router's) and the controller connection 'on'"
	else mrow FAIL ha.entities "Home Assistant says mode '$_ms', connection '$_cs'; the router says mode '$_rm'"; HA_FAILS=1; return 1; fi
	return 0
}

do_final() {
	_bk=${OPT_BK:-$(cat "$OUT/latest-backup-dir" 2>/dev/null)} _sd=${OPT_SD:-$(cat "$OUT/latest-stage-dir" 2>/dev/null)}
	if ! valid_backup_dir "$_bk" || ! valid_stage_dir "$_sd"; then
		say "$(printf '%-5s %-24s ' FAIL final.inputs)no usable backup/stage ('$_bk' '$_sd'): pass --backup-dir and --stage-dir, or run prepare first"; return 1
	fi
	_tar=$(ls -t "$OUT"/backup-"$HOST"-*.tar 2>/dev/null | head -n 1)
	[ -n "$_tar" ] && verify_backup_copy "$_tar" || { say "$(printf '%-5s %-24s ' FAIL final.backup.copy)no verified copy of the backup on this computer in $OUT: run prepare"; return 1; }
	say "reusing backup $_bk and stage $_sd (nothing is repeated, no backup is overwritten)"
	[ "$STAGED" -eq 1 ] || stage_up
	say; say "### Step 1: preflight and verification of the prepared inputs (read-only)"
	_pf=$OUT/.pf.$$
	run_logged preflight >"$_pf"; _prc=$?
	cat "$_pf"; _path=$(sed -n 's/^SSH_PATH=//p' "$_pf" | tail -n 1); rm -f "$_pf"
	say "ssh path to the router: ${_path:-unknown}"
	[ "$_prc" -eq 0 ] || { say "Preflight has FAIL lines: nothing was changed."; return 1; }
	run_logged nodes-check || { say "The exit nodes are not usable (identity or reachability): nothing was changed. Details above; the bundle is saved."; save_bundle nodes-check-failed; return 1; }
	run_logged "verify-prepared $_bk $_sd" || { say "The prepared backup/stage do not verify against the router: nothing was changed."; return 1; }
	say; say "### Step 1b: DIRECT return path (read-only proof BEFORE anything active)"
	run_logged "direct-path-check $_bk $_sd" || { say "The way back to DIRECT is not proven: nothing was changed and no active step will run. Fix the FAIL lines above first."; return 1; }
	_obs=0
	if [ "$OBSERVE" -eq 1 ] && [ "$_path" = lan ]; then
		_obs=1; say "observer: this computer is a LAN client and checks the Internet from the client side at the hold points"
		mac_curl 4
		if [ -n "$MC_OUT" ]; then EXPECT_IP=$MC_OUT; say "$(printf '%-5s %-24s ' PASS mac.control)curl on this computer reaches the Internet (public IP $MC_OUT): a later failure is real evidence"
		else say "$(printf '%-5s %-24s ' WARN mac.control)curl on this computer does not reach the Internet now (exit $MC_RC): BLOCKED observations count as inconclusive unless a german point succeeds first"; fi
	else say "observer: OFF (no LAN client path or --no-observe): router-side evidence only"; fi
	say; say "### Step 2: hardware switch gate"
	ask_switch || return 2
	say; say "### Step 3: independent recovery (verified by use) and WIRE-RC3"
	confirm WIRE-RC3 "1. A procd watchdog (watch + monitor) is started and PROVEN by a probe: heartbeat, keepalive, deadline and a hung watcher (about 40 s, no tsem or network change)." \
		"   If that cannot be proven, nothing is wired." \
		"2. Then RC3 goes into the LIVE router: install.sh --yes from the verified staged copy (journaled; intent, tsem.conf, GL hook and boot link kept)." \
		"   RC3's hotplug handler and fw3 include are active from here. If the verification fails, the previous version is restored automatically (guard re-applied, never opened)." \
		"3. The local API (rpcd plugin + ACL) and the LuCI view are installed too; rpcd is reloaded (restarted only if it does not pick the plugin up: web-UI sessions may be logged out once)." \
		"Watchdog timeout: ${TIMEOUT}s without keepalive runs RECOVERY (never opens the kill switch)." || return 2
	run_logged "recovery-arm $TIMEOUT $_sd" || { say "The recovery watchdog could not be armed/verified: NOTHING was wired."; run_logged recovery-disarm || true; return 1; }
	run_logged "wire --confirm-wire $_bk $_sd" || { say "Wiring failed and the previous version was restored (read the FAIL lines)."; run_logged recovery-disarm || true; return 1; }
	say; say "### Step 3b: DIRECT recovery path on the LIVE router (must work BEFORE the first german test)"
	confirm PROVE-DIRECT "Runs 'tsem set direct' now: the kill switch is OFF and ALL LAN clients use the WAN directly (no exit node) for a few seconds." \
		"It then requires the router's own Internet over the WAN. If this fails the run stops: no german test is started." \
		"The run continues in german only after this proof (the first test t00 sets german again)." || { abort_recover "DIRECT proof not confirmed"; return 2; }
	run_logged "return-to-direct --confirm-direct" || { abort_recover "the live DIRECT path is not proven (no WAN egress in direct): no german test was started"; return 1; }
	if [ "$_obs" -eq 1 ]; then
		# DIRECT must also work for a real LAN client: this computer, over the router, before the first german test
		_mi=0; MC_OUT=''
		while [ "$_mi" -lt 5 ] && [ -z "$MC_OUT" ]; do mac_curl 4; [ -n "$MC_OUT" ] || sleep 3; _mi=$((_mi + 1)); done
		if [ -n "$MC_OUT" ]; then mrow PASS mac.direct "this computer (a LAN client) reaches the Internet in DIRECT (public IP $MC_OUT)"; EXPECT_IP=$MC_OUT
		else mrow FAIL mac.direct "this computer (a LAN client) has NO Internet in DIRECT: the DIRECT path is not proven for clients"; abort_recover "DIRECT is not usable from the LAN client: no german test was started"; return 1; fi
	else
		mrow WARN mac.direct "NOT TESTED: this computer is not a LAN client of the router (or --no-observe): DIRECT was proven from the router only"
	fi
	say; say "### Step 4: tests t00..t08 (disruptive on purpose)"
	confirm RUN-TESTS "Runs t00 .. t08 in one go: t00 sets mode german (ALL LAN clients go through the exit node), t02 forces a failover, t03 simulates BOTH exit nodes down" \
		"(LAN clients LOSE the Internet on purpose), t07 reloads the firewall, t08 restarts tailscale (no Internet for some seconds; skipped when this ssh session is on the tailnet)." \
		"The first FAIL stops the run and starts the recovery. These are simulated faults on the real router, not a real outage of the exit nodes." || { abort_recover "tests not confirmed"; return 2; }
	_env="AR_OBSERVER=$_obs AR_SSH_PATH=${_path:-unknown} AR_RUN=$AR_RUN AR_STRICT_PRIMARY=1"
	for _t in $TESTS_ALL; do
		_ob=''
		if [ "$_obs" -eq 1 ]; then rm -f "$OUT/.obs-stop.$$"; observer_loop & _ob=$!; fi
		say; say "### $_t"
		RENV=$_env run_logged "test $_t"; _trc=$?
		[ -z "$_ob" ] || { : >"$OUT/.obs-stop.$$"; wait "$_ob" 2>/dev/null; rm -f "$OUT/.obs-stop.$$"; }
		[ "$_trc" -eq 0 ] || { abort_recover "$_t reported FAIL or was refused"; return 1; }
	done
	say; say "### Step 5: integrate the hardware switch, boot link and service"
	confirm INTEGRATE-SWITCH "Journaled install.sh --yes --enable --replace-gl-hook from the verified stage, then the tsem service is started:" \
		"  - boot link S18tsem (tsem installs the guard from the intent BEFORE firewall and network at every boot)," \
		"  - the GL switch hook /etc/gl-switch.d/tailscale-de.sh becomes the tsem hook (the old file is kept and restored by rollback), so the switch and the daemon never compete," \
		"  - the tsem daemon starts. If any check fails everything is undone and the guard stays closed." || { abort_recover "integration not confirmed"; return 2; }
	run_logged "go-live --confirm-golive $_bk $_sd" || { abort_recover "go-live failed (it was undone by the router)"; return 1; }
	say; say "### Step 6: final operating mode, persistence"
	run_logged final-state || { abort_recover "the final mode german could not be verified"; return 1; }
	run_logged "persist-check $_sd" || { abort_recover "persistence/boot check failed"; return 1; }
	run_logged extnet-check || { abort_recover "remote-site routes are not preserved"; return 1; }
	say; say "### Step 7: hardware switch, end to end (YOU flip the physical switch; the router only watches)"
	SW_RESULT=UNVERIFIED
	printf '  Type exactly  FLIP-SWITCH  to run it now (you will be asked to flip OFF and then ON), or  SKIP-SWITCH  to leave it UNVERIFIED: '
	_a=''; read -r _a || _a=''
	case $_a in
	FLIP-SWITCH)
		_seq="off on"; [ "$HW_SWITCH" = off ] && _seq="on off on"
		SW_RESULT=PASS
		for _p in $_seq; do
			say "  >>> Flip the hardware switch to $(echo "$_p" | tr a-z A-Z) NOW (waiting up to ${AR_SWITCH_MAX:-120}s). OFF = direct internet (kill switch open by YOUR switch), ON = german."
			run_logged "switch-watch $_p ${AR_SWITCH_MAX:-120}" || { SW_RESULT=FAIL; abort_recover "hardware switch to $_p did not produce the expected state"; return 1; }
		done ;;
	*) say "$(printf '%-5s %-24s ' WARN switch.skipped)hardware switch NOT verified (UNVERIFIED): the physical switch may do nothing" ;;
	esac
	say; say "### Step 8: local API and GUI (router side, then from this computer; read-only)"
	run_logged api-check || { abort_recover "the local API check on the router failed"; return 1; }
	mac_api_gui_check || { abort_recover "the API/GUI check from this computer failed"; return 1; }
	if [ "$NATIVE" -eq 1 ]; then
		say; say "### Step 8b: native GL.iNet GUI (optional; adds files only)"
		confirm NATIVE-GUI "install.sh --yes --components native-gui --accept-undocumented-native-gui from the verified stage:" \
			"  - ADDS /usr/share/oui/menu.d/tsem.json, /www/views/gl-sdk4-ui-tsem.common.js(.gz), /usr/lib/oui-httpd/rpc/tsem. No GL.iNet firmware file is edited, no web server is restarted, the kill switch is not touched." \
			"  - It uses an extension interface GL.iNet does not document (community-verified only). If any check fails it is rolled back, LuCI stays available." \
			"  - Afterwards the GL.iNet UI needs a page reload; if the page stays empty, 'nginx restart' may be needed (it logs the GL.iNet UI out once) - you are asked first." || { say "$(printf '%-5s %-24s ' WARN native.skipped)native GUI NOT installed (UNVERIFIED): LuCI remains the GUI"; NATIVE=0; }
	fi
	if [ "$NATIVE" -eq 1 ]; then
		run_logged "native-install --confirm-native $_bk $_sd" || { say "The native GUI was not installed (restored); LuCI stays available. Read the FAIL lines."; NATIVE=0; NATIVE_FAILED=1; }
	fi
	if [ "$NATIVE" -eq 1 ]; then
		mac_native_check || { abort_recover "the native GUI check from this computer failed"; return 1; }
	fi
	say; say "### Step 9: Home Assistant (read-only, as far as access exists)"
	mac_ha_check || { abort_recover "Home Assistant does not match the router"; return 1; }
	run_logged recovery-disarm || true
	say; say "### RESULT"
	acceptance_table
	if [ "${ROUTER_BAD:-0}" -gt 0 ]; then
		say "ROUTER ACCEPTANCE INCOMPLETE: $ROUTER_BAD criteria are not accepted (FAIL, UNVERIFIED or NOT TESTED). RC3 is wired and in operation (mode german, guard german), but this run is NOT a successful acceptance."
		_incomplete=1
	else
		say "ROUTER ACCEPTANCE COMPLETE: every router criterion has a PASS line. RC3 is wired, integrated and in operation: mode german, guard german, hardware switch declared '$HW_SWITCH'."
		_incomplete=0
	fi
	if [ "$_incomplete" -ne 0 ]; then
		say "FULL PRODUCT ACCEPTANCE NOT PASSED: the router acceptance is not complete."
	elif [ "${HA_BAD:-1}" -gt 0 ]; then
		say "FULL PRODUCT ACCEPTANCE NOT PASSED: the Home Assistant integration is not proven in this run (untested or failed). The router result above stands on its own."
	else
		say "FULL PRODUCT ACCEPTANCE PASSED: router acceptance complete and the Home Assistant integration matches the router."
	fi
	say "Not proven by this run (see docs/rc/rc3-active.md): a real outage of the exit nodes (faults were simulated), a real reboot, the firmware's call convention of the hardware switch (flip it once and check 'tsem status'), IPv6 from every client."
	[ "$_incomplete" -eq 0 ] || return 4
	return 0
}

do_recover() {
	stage_up
	confirm RECOVER "RECOVERY on the router: removes test faults, starts tailscaled if needed, 'tsem reapply', 'tsem tick' until an exit node is active." \
		"It NEVER runs 'tsem set direct' and never removes a chain, rule or module: with mode german the LAN stays BLOCKED if no exit node works." || return 2
	run_logged recover
}
do_repair() {
	_bk=$(cat "$OUT/latest-backup-dir" 2>/dev/null) _sd=$(cat "$OUT/latest-stage-dir" 2>/dev/null)
	valid_backup_dir "$_bk" && valid_stage_dir "$_sd" || { say "no known backup/stage (run prepare first, or the paths are unsafe: '$_bk' '$_sd')"; return 2; }
	stage_up
	confirm REPAIR "REPAIR on the router: if an install was interrupted it replays its journal and restores the previous files; then 'tsem reapply'." \
		"It never opens the kill switch; if the guard would be open it is FAIL and re-asserted from the saved mode." || return 2
	run_logged "install-recover --confirm-repair $_bk $_sd"
}
do_rollback() {
	_bk=$(cat "$OUT/latest-backup-dir" 2>/dev/null)
	valid_backup_dir "$_bk" || { say "no known backup (run prepare first, or the backup path is unsafe: '$_bk')"; return 2; }
	stage_up
	confirm ROLLBACK "ROLLBACK to the version saved in $_bk (install.sh --rollback). This replaces the tsem files; it is NOT recovery." \
		"The guard is re-applied from the intent afterwards; if the rollback would leave the guard OPEN, that is reported as FAIL." || return 2
	run_logged "rollback --confirm-rollback $_bk"
}
do_direct() {
	stage_up
	confirm OPEN-KILLSWITCH "This runs 'tsem set direct': the kill switch is OFF and LAN traffic uses the WAN directly (no exit node)." \
		"This is the only command of this tool that opens it. Use it only if you really want direct Internet." || return 2
	run_logged "return-to-direct --confirm-direct"
}
do_status() { stage_up; run_logged status; }
do_diag() { stage_up; save_bundle manual; run_logged nodes-check; }

case $PHASE in
prepare) do_prepare ;;
final) do_final ;;
accept) do_prepare && { say; say "### prepare finished: the controlled acceptance (final) follows"; do_final; } ;;
test) do_test "$@" ;;
recover) do_recover ;;
repair) do_repair ;;
rollback) do_rollback ;;
direct) do_direct ;;
status) do_status ;;
diag) do_diag ;;
esac
RC=$?
cleanup_remote
FAILS=$(grep -c '^FAIL ' "$REPORT" 2>/dev/null)
say
say "SUMMARY phase=$PHASE exit=$RC FAIL_LINES=${FAILS:-0} PASS_LINES=$(grep -c '^PASS ' "$REPORT" 2>/dev/null) WARN_LINES=$(grep -c '^WARN ' "$REPORT" 2>/dev/null)"
say "Report saved: $REPORT"
[ "$RC" -ne 0 ] && exit "$RC"
[ "${FAILS:-0}" -eq 0 ] && exit 0 || exit 1
