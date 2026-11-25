#!/bin/sh
# tsem-rc3-recover.sh - dead-man's switch and RECOVERY for the RC3 hardware acceptance.
#
# Runs on the router as its own detached process. It is deliberately independent of the tsem
# service, the stage directory and the Mac: it is copied to $AR_RUN/recover.sh when armed.
#
#   recover.sh prepare SECONDS [FIRST]  write the armed state (timeout; the first deadline is FIRST seconds away); starts nothing
#   recover.sh watch [SECONDS]    loop: heartbeat; if the deadline passes without a keepalive, run `now`.
#                                 Resumes an existing armed state (procd respawn); SECONDS initialises it.
#   recover.sh monitor            second, independent process: fires the recovery itself if the watcher is
#                                 hung/dead (heartbeat stale) or the deadline is long past without `fired`
#   recover.sh now                recovery action (also callable by hand, no Mac needed)
#   recover.sh keepalive          push the deadline out again
#   recover.sh disarm             stop the watchdog without recovering
#   recover.sh check              non-mutating prerequisites of the recovery (tsem status parses, init scripts, logger)
#   recover.sh status
#
# On the router both loops run as two instances of ONE procd service (tools/tsem-rc3-active.sh adds it with
# `ubus call service add`), so they belong to procd, not to the SSH session. Neither setsid nor nohup is needed.
#
# RECOVERY is NOT ROLLBACK and NOT "open the Internet":
#   - it removes the test fault simulation, makes sure tailscaled runs, re-applies the protection
#     from the persisted intent (`tsem reapply`) and lets the real controller pick an exit node
#     (`tsem tick`);
#   - it NEVER runs `tsem set direct`, `tsem teardown`, never flushes or deletes a TSEM chain or ip
#     rule, never unloads or loads modules, never touches boot links, the GL switch hook or the
#     installed RC2/RC3 files;
#   - an interrupted install (/etc/tsem/backup/INPROGRESS) is first replayed from its persistent journal
#     (`install.sh --recover --yes`, nothing else is ever run from install.sh), then the guard is re-applied;
#   - if the intent says german, the kill switch stays closed (guard german, or blocked when no
#     exit node is usable). A router without Internet in that state is the intended result.
# Rollback to RC2 and "return to direct" are separate, explicit commands of tsem-rc3-active.sh.

set -u
AR_RUN=${AR_RUN:-/tmp/tsem-rc3-active}
RC_DIR=$AR_RUN/recovery
R=${PF_ROOT:-}
R=${R%/}
TSEM=${TSEM_BIN:-$R/usr/sbin/tsem}
INITD=${AR_INITD:-$R/etc/init.d}
SLEEP=${AR_SLEEP:-sleep}
SVC=${AR_SVC:-tsem-rc3-wd}
PROBE=${AR_PROBE:-0}
HB=$RC_DIR/hb

rt() { date +%s; } # real time (heartbeat); `now` may be faked by the tests
now() { if [ -n "${TSEM_NOW:-}" ]; then echo "$TSEM_NOW"; else date +%s; fi; }
rlog() {
	printf '%s %s\n' "$(now)" "$1" >>"$RC_DIR/recover.log" 2>/dev/null
	logger -t tsem-rc3-recover "$1" 2>/dev/null || true
	echo "$1"
}
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# leave the procd service (kills this very process: always the LAST action). No-op without ubus.
svc_delete() { command -v ubus >/dev/null 2>&1 && ubus call service delete "{\"name\":\"$SVC\"}" >/dev/null 2>&1; return 0; }

ts_running() { ps w 2>/dev/null | grep -v grep | grep -q 'tailscaled'; }

do_recover() {
	mkdir -p "$RC_DIR" 2>/dev/null
	rlog "RECOVERY start (kill switch is NOT disabled by recovery)"
	if [ -e "$R/etc/tsem/backup/INPROGRESS" ]; then
		rlog "an interrupted tsem install is pending ($(cat "$R/etc/tsem/backup/INPROGRESS" 2>/dev/null)): replaying its journal"
		_w=0
		while ps w 2>/dev/null | grep -v grep | grep -q 'install\.sh' && [ "$_w" -lt "${AR_RECOVER_INSTALL_WAIT:-60}" ]; do $SLEEP 1; _w=$((_w + 1)); done
		_is=$(cat "$RC_DIR/install_sh" 2>/dev/null)
		if ps w 2>/dev/null | grep -v grep | grep -q 'install\.sh'; then
			rlog "WARN an install.sh is still running after ${_w}s: not replaying under it; use the repair phase when it is gone"
		elif [ -n "$_is" ] && [ -f "$_is" ]; then
			if [ -n "$R" ]; then _o=$(sh "$_is" --root "$R" --recover --yes 2>&1 </dev/null); else _o=$(sh "$_is" --recover --yes 2>&1 </dev/null); fi
			_rrc=$?
			rlog "journal replay rc=$_rrc: $(printf '%s' "$_o" | tail -n 2 | tr '\n' ' ')"
			[ "$_rrc" -eq 0 ] || rlog "WARN the journal replay failed: the backup archive of the prepare step holds the previous files (repair phase)"
		else
			rlog "WARN cannot replay the journal: the install script of the stage is gone ($_is): run the repair phase of the Mac tool"
		fi
	fi
	# 1. test fault simulation is only ever a wrapper used through environment variables; remove it
	rm -rf "$AR_RUN/fault" 2>/dev/null
	rm -f "$AR_RUN"/obs/hold.* 2>/dev/null
	# 2. tailscaled must be running (the guard does not depend on it, the exit node does)
	if ! ts_running && [ -x "$INITD/tailscale" ]; then
		rlog "tailscaled is not running: starting it"
		"$INITD/tailscale" start >/dev/null 2>&1 || rlog "WARN could not start tailscaled"
		_w=0
		while [ "$_w" -lt "${AR_RECOVER_TS_WAIT:-30}" ]; do
			tailscale status >/dev/null 2>&1 && break
			$SLEEP 1
			_w=$((_w + 1))
		done
	fi
	if [ ! -x "$TSEM" ]; then
		rlog "RECOVERY_RESULT=failed: $TSEM is not installed; nothing was changed"
		echo "RECOVERY_RESULT=failed"
		return 1
	fi
	_pre=$("$TSEM" status 2>/dev/null)
	rlog "before: mode=$(kv "$_pre" mode) state=$(kv "$_pre" state) guard=$(kv "$_pre" guard) exit=$(kv "$_pre" exit_node)"
	# 3. re-assert the protection exactly as the persisted intent says (never opens unless the intent is direct)
	if ! "$TSEM" reapply >/dev/null 2>&1; then
		rlog "WARN tsem reapply failed: the guard state is unchanged and unknown, check 'tsem diag' (nothing was opened)"
	fi
	# 4. let the real controller (no simulation) choose the exit node again
	_mode=$(kv "$("$TSEM" status 2>/dev/null)" mode)
	if [ "$_mode" = german ]; then
		_i=0
		while [ "$_i" -lt "${AR_RECOVER_TICKS:-24}" ]; do
			"$TSEM" tick >/dev/null 2>&1
			case $(kv "$("$TSEM" status 2>/dev/null)" state) in PRIMARY_ACTIVE | SECONDARY_ACTIVE) break ;; esac
			$SLEEP "${AR_RECOVER_TICK_WAIT:-5}"
			_i=$((_i + 1))
		done
	fi
	_post=$("$TSEM" status 2>/dev/null)
	_g=$(kv "$_post" guard)
	rlog "after: mode=$(kv "$_post" mode) state=$(kv "$_post" state) guard=$_g exit=$(kv "$_post" exit_node) leak_risk=$(kv "$_post" leak_risk)"
	case $_g in
	german)
		case $(kv "$_post" state) in
		PRIMARY_ACTIVE | SECONDARY_ACTIVE)
			# the state label alone is not proof: a router-own HTTPS request through the active exit node must work (no change is made)
			if command -v curl >/dev/null 2>&1 && [ "${AR_RECOVER_EGRESS:-1}" = 1 ]; then
				_eg=0 _k=0
				while [ "$_k" -lt "${AR_RECOVER_EGRESS_TRIES:-3}" ]; do
					curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null "${AR_RECOVER_URL:-https://1.1.1.1/cdn-cgi/trace}" 2>/dev/null && { _eg=1; break; }
					_k=$((_k + 1)); $SLEEP 2
				done
				if [ "$_eg" -ne 1 ]; then
					echo "RECOVERY_RESULT=degraded"; rlog "RECOVERY degraded: state $(kv "$_post" state) but the router-own HTTPS request through the exit node FAILS ${AR_RECOVER_EGRESS_TRIES:-3}x (kill switch stays closed; run 'tsem status' and the diag bundle)"; return 0
				fi
			fi
			echo "RECOVERY_RESULT=ok"; rlog "RECOVERY ok: kill switch closed, exit node active, router-own HTTPS request works"; return 0 ;;
		*) echo "RECOVERY_RESULT=degraded"; rlog "RECOVERY degraded: kill switch closed (guard german), exit node not (yet) usable"; return 0 ;;
		esac ;;
	blocked)
		echo "RECOVERY_RESULT=blocked"
		rlog "RECOVERY: kill switch closed (BLOCKED): no exit node usable, LAN has no Internet by design. LAN/tailnet management still works."
		return 0 ;;
	open)
		if [ "$_mode" = direct ]; then echo "RECOVERY_RESULT=direct"; rlog "RECOVERY: intent is direct (explicit user choice), guard open; recovery changed nothing about that"; return 0; fi
		echo "RECOVERY_RESULT=failed"; rlog "RECOVERY FAILED: guard is open although the intent is $_mode; run 'tsem reapply' and 'tsem diag'"; return 1 ;;
	*)
		echo "RECOVERY_RESULT=failed"; rlog "RECOVERY FAILED: guard=$_g (inconsistent or missing); run 'tsem diag'. Nothing was opened or removed."; return 1 ;;
	esac
}

# fire exactly once, by whoever gets there first (watcher or monitor); the probe only leaves a canary
fire_once() { # REASON
	mkdir "$RC_DIR/rlock" 2>/dev/null || return 0
	rlog "$1: running RECOVERY"
	if [ "$PROBE" = 1 ]; then
		[ "${AR_PROBE_BROKEN:-}" = nofire ] || : >"$RC_DIR/canary"
	else
		do_recover >>"$RC_DIR/recover.out" 2>&1
	fi
	rm -f "$RC_DIR/armed" "$RC_DIR/pid"
	: >"$RC_DIR/fired"
	svc_delete
}
# deadline is replaced atomically: a reader never sees an empty or half-written value
setdl() { echo "$1" >"$RC_DIR/deadline.new" && mv -f "$RC_DIR/deadline.new" "$RC_DIR/deadline"; }
getdl() { _g=$(cat "$RC_DIR/deadline" 2>/dev/null); case $_g in '' | *[!0-9]*) return 1 ;; esac; echo "$_g"; }
init_state() { # SECONDS
	mkdir -p "$RC_DIR" || return 1
	rm -rf "$RC_DIR/rlock" "$RC_DIR/fired" "$RC_DIR/disarm" "$RC_DIR/canary" 2>/dev/null
	echo "$1" >"$RC_DIR/timeout"
	setdl $(($(now) + ${2:-$1}))
	: >"$RC_DIR/armed"
}

cmd=${1:-}
case $cmd in
now) do_recover ;;
check)
	_bad=''
	[ -x "$TSEM" ] || _bad="$_bad tsem-missing"
	_s=$("$TSEM" status 2>/dev/null)
	case $(kv "$_s" guard) in german | blocked | open | inconsistent | none) ;; *) _bad="$_bad tsem-status-unparsable" ;; esac
	[ -x "$INITD/tailscale" ] || _bad="$_bad no-tailscale-init"
	command -v logger >/dev/null 2>&1 || _bad="$_bad no-logger"
	command -v ps >/dev/null 2>&1 || _bad="$_bad no-ps"
	if [ -n "$_bad" ]; then echo "CHECK_FAIL$_bad"; exit 1; fi
	echo "CHECK_OK" ;;
prepare)
	_t=${2:-}
	case $_t in '' | *[!0-9]*) echo "prepare needs seconds" >&2; exit 64 ;; esac
	init_state "$_t" "${3:-$_t}" || exit 1
	rlog "watchdog state prepared: recovery in ${_t}s without keepalive" ;;
watch)
	mkdir -p "$RC_DIR" || exit 1
	if [ -e "$RC_DIR/armed" ] && [ ! -e "$RC_DIR/fired" ]; then _how=resumed
	elif [ -n "${2:-}" ]; then init_state "$2" || exit 1; _how=armed
	else echo "not armed: nothing to watch"; exit 0; fi
	echo "$$" >"$RC_DIR/pid"
	rlog "watchdog $_how: recovery at the deadline without keepalive (pid $$, probe=$PROBE)"
	while :; do
		if [ -e "$RC_DIR/disarm" ]; then rlog "watchdog disarmed"; rm -f "$RC_DIR/armed" "$RC_DIR/disarm" "$RC_DIR/pid" "$HB"; svc_delete; exit 0; fi
		[ -e "$RC_DIR/armed" ] || exit 0
		[ "${AR_PROBE_BROKEN:-}" = nohb ] || { rt >"$HB.new" && mv -f "$HB.new" "$HB"; }
		if _dl=$(getdl) && [ "$(now)" -ge "$_dl" ]; then fire_once "deadline passed without keepalive"; exit 0; fi
		$SLEEP "${AR_WATCH_STEP:-2}"
	done ;;
monitor)
	mkdir -p "$RC_DIR" || exit 1
	_t0=$(rt)
	rlog "monitor started (pid $$): fires the recovery itself if the watcher is hung or dead"
	while :; do
		[ -e "$RC_DIR/disarm" ] && exit 0
		[ -e "$RC_DIR/armed" ] || exit 0
		_h=$(cat "$HB" 2>/dev/null)
		case $_h in '' | *[!0-9]*) _h=$_t0 ;; esac
		if [ $(($(rt) - _h)) -gt "${AR_HB_STALE:-20}" ]; then fire_once "monitor: the watcher's heartbeat is stale (hung or dead)"; exit 0; fi
		if _dl=$(getdl) && [ "$(now)" -ge $((_dl + ${AR_MON_GRACE:-10})) ]; then fire_once "monitor: deadline passed and the watcher did not act"; exit 0; fi
		$SLEEP "${AR_WATCH_STEP:-2}"
	done ;;
keepalive)
	[ -e "$RC_DIR/armed" ] || { echo "not armed"; exit 1; }
	setdl $(($(now) + $(cat "$RC_DIR/timeout" 2>/dev/null || echo 300))) ;;
disarm)
	[ -e "$RC_DIR/armed" ] || { svc_delete; echo "not armed"; exit 0; }
	: >"$RC_DIR/disarm"
	_p=$(cat "$RC_DIR/pid" 2>/dev/null)
	_i=0
	while [ -e "$RC_DIR/armed" ] && [ "$_i" -lt 10 ]; do $SLEEP 1; _i=$((_i + 1)); done
	if [ -e "$RC_DIR/armed" ]; then [ -z "$_p" ] || kill "$_p" 2>/dev/null; rm -f "$RC_DIR/armed" "$RC_DIR/pid" "$RC_DIR/disarm" "$HB"; fi
	svc_delete
	echo "disarmed" ;;
status)
	if [ -e "$RC_DIR/armed" ]; then
		_h=$(cat "$HB" 2>/dev/null); case $_h in '' | *[!0-9]*) _h=0 ;; esac
		echo "armed pid=$(cat "$RC_DIR/pid" 2>/dev/null) timeout=$(cat "$RC_DIR/timeout" 2>/dev/null) deadline_in=$(($(cat "$RC_DIR/deadline" 2>/dev/null || echo 0) - $(now)))s heartbeat_age=$(($(rt) - _h))s"
	elif [ -e "$RC_DIR/fired" ]; then echo "fired (recovery ran; see $RC_DIR/recover.log)"
	else echo "not armed"; fi ;;
*) echo "usage: recover.sh prepare SECONDS | watch [SECONDS] | monitor | now | check | keepalive | disarm | status" >&2; exit 64 ;;
esac
