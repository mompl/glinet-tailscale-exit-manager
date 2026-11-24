# shellcheck shell=sh
# RC3 active hardware acceptance: router script, recovery watchdog and Mac wrapper, tested with fake commands only.
# Nothing here touches a real router; the fake tsem/ip/iptables/curl/tailscale record every call.

ACT=$ROOT/tools/tsem-rc3-active.sh
REC=$ROOT/tools/tsem-rc3-recover.sh
MAC=$ROOT/tools/run-rc3-active-mac.sh
_code() { grep -v '^[[:space:]]*#' "$1"; }
_fn_body() { sed -n "/^$2() {/,/^}/p" "$1"; }

_ac_setup() {
	t_setup
	F=$T/f; RT=$T/rt; FB=$T/fbin; AR=$T/run
	mkdir -p "$F" "$FB" "$AR" "$RT/usr/lib/tsem" "$RT/etc/tsem" "$RT/etc/config" "$RT/etc/init.d" "$RT/usr/sbin" "$T/bk"
	_V=$(sed -n 's/^TSEM_VERSION=//p' "$ROOT/src/usr/lib/tsem/common.sh" | head -n 1 | tr -d '"')
	echo "TSEM_VERSION=$_V" >"$RT/usr/lib/tsem/common.sh"
	printf '#!/bin/sh\n' >"$RT/usr/sbin/tsem"; printf '#!/bin/sh\n' >"$RT/etc/init.d/tsem"; chmod +x "$RT/etc/init.d/tsem"
	echo "config interface 'lan'" >"$RT/etc/config/network"; echo 'TSEM_X=1' >"$RT/etc/tsem/tsem.conf"
	printf 'v=1\nmode=german\n' >"$RT/etc/tsem/intent"
	echo "config defaults" >"$RT/etc/config/firewall"
	echo german >"$F/mode"; echo PRIMARY_ACTIVE >"$F/state"; echo german >"$F/guard"; echo 100.64.0.30 >"$F/exit"
	cat >"$FB/tsem" <<'FEOF'
#!/bin/sh
echo "$* P=${TSEM_PRIMARY_NAME:-} S=${TSEM_SECONDARY_NAME:-}" >>"$FAKE_F/calls"
g() { cat "$FAKE_F/$1" 2>/dev/null; }
w() { echo "$2" >"$FAKE_F/$1"; }
case $1 in
status)
	_leak=false; [ "$(g guard)" = open ] && [ "$(g mode)" != direct ] && _leak=true
	_ks=false; case $(g guard) in german | blocked) _ks=true ;; esac
	printf 'version=0.1.0-rc3\nmode=%s\nstate=%s\nguard=%s\nexit_node=%s\nkill_switch_active=%s\nleak_risk=%s\nprimary=100.64.0.30\nsecondary=100.64.0.31\nintent=ok\nseq=%s\nsource=%s\nhw_state=%s\n' \
		"$(g mode)" "$(g state)" "$(g guard)" "$(g exit)" "$_ks" "$_leak" "$(g seq || echo 1)" "$(g source)" "$(g hw)" ;;
tick)
	[ "$(g mode)" = german ] || exit 0
	[ -e "$FAKE_F/reapply_broken" ] && exit 0
	_pd=0 _sd=0
	[ "${TSEM_PRIMARY_NAME:-}" = tsem-rc3-test-no-such-primary ] && _pd=1
	[ "${TSEM_SECONDARY_NAME:-}" = tsem-rc3-test-no-such-secondary ] && _sd=1
	if [ $_pd = 1 ] && [ $_sd = 1 ]; then w state BLOCKED; w exit none; if [ -e "$FAKE_F/leak" ]; then w guard open; else w guard blocked; fi
	elif [ $_pd = 1 ]; then w state SECONDARY_ACTIVE; w exit 100.64.0.31; w guard german
	else w state PRIMARY_ACTIVE; w exit 100.64.0.30; w guard german; fi ;;
set)
	case $2 in
	german) w mode german
		if [ -e "$FAKE_F/set_active" ]; then w state PRIMARY_ACTIVE; w guard german; w exit 100.64.0.30; else w state BLOCKED; w guard blocked; w exit none; fi ;;
	direct) w mode direct; w state DIRECT; w guard open; w exit none ;;
	esac ;;
reapply) [ -e "$FAKE_F/reapply_broken" ] || { [ "$(g mode)" = german ] && [ "$(g guard)" = open ] && w guard blocked; }; exit 0 ;;
selftest)
	[ -e "$FAKE_F/open_on_selftest" ] && w guard open
	[ -e "$FAKE_F/selftest_fail" ] && { echo "FAIL fake selftest"; exit 1; }
	echo "PASS fake selftest"; exit 0 ;;
verify-nodes) cat "$FAKE_F/verify_out" 2>/dev/null; exit "$(cat "$FAKE_F/verify_rc" 2>/dev/null || echo 0)" ;;
intent-check) echo "ok"; exit 0 ;;
daemon) echo "daemon" >>"$FAKE_F/calls"; while :; do sleep 1; done ;;
esac
exit 0
FEOF
	cat >"$FB/curl" <<'FEOF'
#!/bin/sh
echo "curl $*" >>"$FAKE_F/curl.log"
[ -e "$FAKE_F/curldead" ] && exit 28
if [ "$(cat "$FAKE_F/guard")" = blocked ] && [ ! -e "$FAKE_F/curlok" ]; then exit "$(cat "$FAKE_F/curlrc" 2>/dev/null || echo 28)"; fi
echo "ip=203.0.113.9"
FEOF
	cat >"$FB/ip" <<'FEOF'
#!/bin/sh
case "$*" in
"rule show" | "-6 rule show") echo "5290: from all iif br-lan prohibit" ;;
"route get"* | "-6 route get"*)
	[ -e "$FAKE_F/route_weird" ] && { echo "garbage"; exit 0; }
	if [ "$(cat "$FAKE_F/guard")" = blocked ]; then echo "prohibit 1.1.1.1 from 192.168.8.2 dev br-lan"; else echo "1.1.1.1 dev tailscale0 src 100.64.0.1"; fi ;;
"-6 addr show"*) : ;;
esac
FEOF
	printf '#!/bin/sh\necho "*filter"\n' >"$FB/iptables-save"
	cat >"$FB/iptables" <<'FEOF'
#!/bin/sh
[ -e "$FAKE_F/ipt_empty" ] && exit 0
case "$*" in "-S TSEM_FWD") echo "-N TSEM_FWD" ;; "-S FORWARD") echo "-A FORWARD -j TSEM_FWD" ;; esac
FEOF
	printf '#!/bin/sh\nif [ -e "$FAKE_F/sfe" ]; then echo "shortcut_fe 1 0"; fi\necho "nf_conntrack 1 0"\n' >"$FB/lsmod"
	printf '#!/bin/sh\nexit 0\n' >"$FB/nslookup"
	# BusyBox `ps w` lists every process; procps needs "ax" for that
	_psb=$(command -v ps) && printf '#!/bin/sh\nexec %s axww\n' "$_psb" >"$FB/ps"
	printf '#!/bin/sh\nif [ "$1" = status ]; then exit 0; fi\n[ "$1" = ping ] && echo "pong from node (100.64.0.9) via DERP(nue) in 20ms"\nexit 0\n' >"$FB/tailscale"
	printf '#!/bin/sh\necho "firewall $*" >>"$FAKE_F/calls"\nsleep 1\n' >"$RT/etc/init.d/firewall"
	printf '#!/bin/sh\necho "tailscale-init $*" >>"$FAKE_F/calls"\n' >"$RT/etc/init.d/tailscale"
	# fake ssh: runs the remote command line locally (same environment), logs it
	cat >"$FB/ssh" <<'FEOF'
#!/bin/sh
for a in "$@"; do last=$a; done
printf '%s\n' "$last" >>"$FAKE_F/ssh.log"
exec sh -c "$last"
FEOF
	# fake procd: `ubus call service add|list|delete`; "add" really starts the two instances (reparented to init like procd children)
	cat >"$FB/ubus" <<'FEOF'
#!/bin/sh
D=$FAKE_F/svc; mkdir -p "$D"
unset TSEM_NOW AR_FAKE_CLOCK # procd starts its children with a clean environment
if [ "$1" = list ] && [ "$2" = tsem ]; then [ -e "$FAKE_F/ubus_no_tsem" ] && exit 4; printf 'status\nset_mode\n'; exit 0; fi
if [ "$1" = call ] && [ "$2" = tsem ] && [ "$3" = status ]; then printf '{"ok":true,"status":{"mode":"%s"}}\n' "$(cat "$FAKE_F/mode")"; exit 0; fi
[ "$1" = call ] && [ "$2" = service ] || exit 4
j() { printf '%s' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
case $3 in
add)
	[ -e "$FAKE_F/ubus_noadd" ] && exit 0
	n=$(printf '%s' "$4" | sed -n 's/^{"name":"\([^"]*\)".*/\1/p')
	for i in watch monitor; do
		( AR_RUN=$(j AR_RUN "$4") AR_SVC=$(j AR_SVC "$4") AR_PROBE=$(j AR_PROBE "$4") AR_WATCH_STEP=$(j AR_WATCH_STEP "$4") AR_HB_STALE=$(j AR_HB_STALE "$4") AR_MON_GRACE=$(j AR_MON_GRACE "$4") AR_SLEEP=sleep \
			sh -c 'echo $$ >"$1"; exec sh "$2/recover.sh" "$3"' x "$D/$n.$i.pid" "$(j AR_RUN "$4")" "$i" </dev/null >>"$D/$n.$i.out" 2>&1 & )
	done
	sleep 1 ;;
list)
	n=$(printf '%s' "$4" | sed -n 's/^{"name":"\([^"]*\)".*/\1/p')
	[ -e "$D/$n.watch.pid" ] || { echo '{}'; exit 0; }
	printf '{\n\t"%s": {\n\t\t"instances": {\n' "$n"
	for i in watch monitor; do
		p=$(cat "$D/$n.$i.pid" 2>/dev/null); r=false; kill -0 "$p" 2>/dev/null && r=true
		printf '\t\t\t"%s": {\n\t\t\t\t"running": %s,\n\t\t\t\t"pid": %s,\n\t\t\t},\n' "$i" "$r" "${p:-0}"
	done
	printf '\t\t}\n\t}\n}\n' ;;
delete)
	n=$(printf '%s' "$4" | sed -n 's/^{"name":"\([^"]*\)".*/\1/p')
	for i in watch monitor; do p=$(cat "$D/$n.$i.pid" 2>/dev/null); [ -z "$p" ] || { kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; }; rm -f "$D/$n.$i.pid"; done ;;
esac
exit 0
FEOF
	chmod +x "$FB"/* "$RT/etc/init.d"/*
	export TSEM_RC3_AR_RUN=$AR FAKE_F=$F PF_ROOT=$RT TSEM_BIN=$FB/tsem AR_RUN=$AR AR_BK_BASE=$T/bk TSEM_RC3_BK_BASE=$T/bk AR_INITD=$RT/etc/init.d
	export AR_PROBE_TIMEOUT=3 AR_FAKE_CLOCK=1 AR_SLEEP=true AR_RECOVER_TICK_WAIT=0 AR_RECOVER_TICKS=3 AR_WATCH_STEP=1 TSEM_SSH=$FB/ssh
	export PATH=$FB:$PATH
}
_arm_fake() { # watchdog state with a really moving heartbeat, without a real watchdog
	mkdir -p "$AR/recovery"
	date +%s >"$AR/recovery/hb"
	( while :; do date +%s >"$AR/recovery/hb.new" && mv -f "$AR/recovery/hb.new" "$AR/recovery/hb"; sleep 1; done ) &
	FAKE_WD=$!
	echo $FAKE_WD >"$AR/recovery/pid"
	echo 300 >"$AR/recovery/timeout"
	echo 9999999999 >"$AR/recovery/deadline"
	: >"$AR/recovery/armed"
}
_calls() { cat "$F/calls" 2>/dev/null; }
_acts() { sh "$ACT" "$@" 2>&1 </dev/null; }

# ---------------------------------------------------------------- static guarantees
test_active_script_opens_the_kill_switch_only_in_return_to_direct() {
	t_setup
	_n=$(_code "$ACT" | grep -c 'set direct')
	assert_eq one-place 1 "$_n"
	assert_contains where "set direct" "$(_fn_body "$ACT" cmd_return_to_direct)"
	_code "$ACT" | grep -Eq 'teardown|iptables +-[FXDAI]|ip6tables +-[FXDAI]|ip +(-6 +)?rule +(add|del)|modprobe|insmod|rmmod' && fail "active script changes firewall/rules/modules directly"
	:
}

test_recovery_script_never_opens_or_removes_protection() {
	t_setup
	_c=$(_code "$REC")
	for _bad in 'set direct' teardown 'iptables' 'ip6tables' 'ip rule' 'ip -6 rule' modprobe insmod rmmod 'rc.d' 'gl-switch' -- '--rollback' '--enable' '--replace-gl-hook' '--initial-mode'; do
		case $_c in *"$_bad"*) [ "$_bad" = -- ] || fail "recovery script contains '$_bad'" ;; esac
	done
	# the only thing it may run from install.sh is the journal replay of an interrupted install
	_n=$(printf '%s\n' "$_c" | grep -o 'sh "\$_is"' | wc -l | tr -d ' ')
	assert_eq replay-calls 2 "$_n"
	printf '%s\n' "$_c" | grep -o 'sh "\$_is"[^;]*' | grep -vq -- '--recover --yes' && fail "install.sh is called with something other than --recover --yes"
	:
}

test_stage_rc3_is_a_copy_and_only_wire_installs_live() {
	t_setup
	_b=$(_fn_body "$ACT" cmd_stage_rc3)
	case $_b in *--enable* | *--replace-gl-hook* | *'$INITD'* | *"ln -s"* | *inst_sh*) fail "stage-rc3 can enable, start or install live" ;; esac
	assert_contains side-root '--root "$_tr"' "$_b"
	# every live install.sh call is in wire, install-recover (via wire_restore), rollback or activate
	for _fn in cmd_wire cmd_go_live wire_restore cmd_rollback cmd_activate cmd_native_install; do assert_contains "live-$_fn" "inst_sh" "$(_fn_body "$ACT" $_fn)"; done
	_n=$(_code "$ACT" | grep -c 'inst_sh "')
	assert_eq live-calls 8 "$_n"
	# the old, misnamed passive install no longer exists
	_code "$ACT" "$MAC" | grep -q 'install-passive\|INSTALL-PASSIVE' && fail "install-passive still present"
	:
}

test_mac_wrapper_has_no_force_option_and_requires_typed_phrases() {
	t_setup
	assert_rc noyes 64 sh "$MAC" --yes --stage "$ROOT" status
	assert_rc noforce 64 sh "$MAC" --force --stage "$ROOT" status
	assert_rc nostage 64 sh "$MAC" status
	assert_rc badphase 64 sh "$MAC" --stage "$ROOT" frobnicate
	_c=$(_code "$MAC")
	for _p in BACKUP STAGE-RC3 WIRE-RC3 ARM-RECOVERY 'START' DISARM RECOVER REPAIR ROLLBACK OPEN-KILLSWITCH; do assert_contains "phrase-$_p" "$_p" "$_c"; done
}

# ---------------------------------------------------------------- router script refusals
test_active_refuses_dangerous_commands_without_their_flag() {
	_ac_setup
	_o=$(_acts rollback); assert_contains rb "REFUSED" "$_o"; assert_rc rb 2 sh "$ACT" rollback
	assert_rc dir 2 sh "$ACT" return-to-direct
	assert_rc act 2 sh "$ACT" activate
	assert_rc nobk 2 sh "$ACT" stage-rc3
	assert_rc nowire 2 sh "$ACT" wire
	assert_rc norepair 2 sh "$ACT" install-recover
	assert_rc arm-short 2 sh "$ACT" recovery-arm 10
	assert_rc arm-bad 2 sh "$ACT" recovery-arm abc
	assert_rc rb-nobk 2 sh "$ACT" rollback --confirm-rollback
	assert_eq nothing-called "" "$(_calls)"
}

test_active_tests_refuse_without_armed_watchdog() {
	_ac_setup
	_o=$(_acts test t03_both_down)
	assert_contains why "recovery watchdog is not armed" "$_o"
	assert_rc rc 2 sh "$ACT" test t03_both_down
	case $(_calls) in *tick*) fail "a tick ran without a watchdog" ;; esac
}

test_active_tests_refuse_when_rc3_not_installed() {
	_ac_setup; _arm_fake
	echo 'TSEM_VERSION=0.1.0-rc2' >"$RT/usr/lib/tsem/common.sh"
	_o=$(_acts test t03_both_down); kill "$FAKE_WD" 2>/dev/null
	assert_contains why "is not installed (installed:" "$_o"
}

# ---------------------------------------------------------------- recovery behaviour
test_recovery_keeps_the_kill_switch_closed_and_never_sets_direct() {
	_ac_setup
	mkdir -p "$AR/fault" "$AR/obs"; : >"$AR/obs/hold.x"
	echo blocked >"$F/guard"; echo BLOCKED >"$F/state"; echo none >"$F/exit"
	_o=$(sh "$REC" now 2>&1); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains res "RECOVERY_RESULT=ok" "$_o"
	[ ! -e "$AR/fault" ] || fail "fault directory not removed"
	[ ! -e "$AR/obs/hold.x" ] || fail "hold marker not removed"
	_c=$(_calls)
	assert_contains reapply "reapply" "$_c"
	assert_contains tick "tick" "$_c"
	case $_c in *"set direct"* | *teardown*) fail "recovery opened or tore down: $_c" ;; esac
	assert_eq guard german "$(cat "$F/guard")"
}

test_recovery_with_both_nodes_unusable_ends_blocked_not_open() {
	_ac_setup
	# the controller can only produce BLOCKED (simulated by tick doing nothing useful)
	printf '#!/bin/sh\necho "$*" >>"$FAKE_F/calls"\ncase $1 in status) printf "mode=german\\nstate=BLOCKED\\nguard=blocked\\nexit_node=none\\nleak_risk=false\\n";; esac\nexit 0\n' >"$FB/tsem"
	_o=$(sh "$REC" now 2>&1); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains res "RECOVERY_RESULT=blocked" "$_o"
	assert_contains by-design "kill switch closed" "$_o"
	case $(_calls) in *"set direct"*) fail "recovery set direct" ;; esac
}

test_recovery_reports_failure_when_guard_is_open_but_intent_is_german() {
	_ac_setup
	echo open >"$F/guard"; : >"$F/reapply_broken"
	_o=$(sh "$REC" now 2>&1); _rc=$?
	assert_eq rc 1 "$_rc"
	assert_contains res "RECOVERY_RESULT=failed" "$_o"
	case $(_calls) in *"set direct"* | *teardown*) fail "recovery must not 'fix' this by opening/removing" ;; esac
}

test_recovery_leaves_an_explicit_direct_intent_alone() {
	_ac_setup
	echo direct >"$F/mode"; echo open >"$F/guard"; echo DIRECT >"$F/state"; echo none >"$F/exit"
	_o=$(sh "$REC" now 2>&1)
	assert_contains res "RECOVERY_RESULT=direct" "$_o"
	case $(_calls) in *"set "*) fail "recovery changed the mode" ;; esac
}

test_watchdog_fires_recovery_after_the_deadline_and_disarm_prevents_it() {
	_ac_setup
	unset TSEM_NOW; AR_SLEEP=sleep; export AR_SLEEP
	AR_RUN=$AR sh "$REC" watch 2 >/dev/null 2>&1 &
	_w=$!
	_i=0; while [ ! -e "$AR/recovery/fired" ] && [ "$_i" -lt 15 ]; do sleep 1; _i=$((_i + 1)); done
	wait "$_w" 2>/dev/null
	[ -e "$AR/recovery/fired" ] || fail "watchdog did not fire"
	assert_contains log "deadline passed without keepalive" "$(cat "$AR/recovery/recover.log")"
	assert_contains ran "reapply" "$(_calls)"
	# disarm: no recovery
	rm -rf "$AR/recovery" "$F/calls"
	AR_RUN=$AR sh "$REC" watch 30 >/dev/null 2>&1 &
	_w=$!
	_i=0; while [ ! -e "$AR/recovery/armed" ] && [ "$_i" -lt 10 ]; do sleep 1; _i=$((_i + 1)); done
	AR_RUN=$AR sh "$REC" disarm >/dev/null 2>&1
	wait "$_w" 2>/dev/null
	[ ! -e "$AR/recovery/fired" ] || fail "recovery fired after disarm"
	assert_eq nocalls "" "$(_calls)"
}

# ---------------------------------------------------------------- active tests (fake clock, fake commands)
_run_t() { _arm_fake; TSEM_NOW=1790000000 sh "$ACT" test "$@" 2>&1 </dev/null; _RC=$?; kill "$FAKE_WD" 2>/dev/null; }

test_t03_both_nodes_down_ends_blocked_with_no_wan_fallback() {
	_ac_setup
	_o=$(_run_t t03_both_down >"$T/out"; cat "$T/out"); _rc=$(sed -n 's/^SUMMARY.*FAIL=\([0-9]*\).*/\1/p' "$T/out")
	assert_eq nofail 0 "$_rc"
	for _k in t03.blocked t03.guard t03.leak t03.router_egress t03.lan_route t03.deny t03.never_open t03.recovered final.killswitch; do assert_contains "$_k" "PASS  $_k" "$_o"; done
	_c=$(_calls)
	assert_contains faultP "tick P=tsem-rc3-test-no-such-primary S=tsem-rc3-test-no-such-secondary" "$_c"
	case $_c in *"set direct"* | *"set "*) fail "a mode change happened during t03: $_c" ;; esac
	assert_eq end-guard german "$(cat "$F/guard")"
}

test_t03_fails_when_the_guard_opens_with_both_nodes_down() {
	_ac_setup; : >"$F/leak"
	_arm_fake
	_o=$(TSEM_NOW=1790000000 sh "$ACT" test t03_both_down 2>&1 </dev/null); _rc=$?; kill "$FAKE_WD" 2>/dev/null
	assert_eq exit 1 "$_rc"
	assert_contains open "FAIL  t03.never_open" "$_o"
	assert_contains guard "FAIL  t03.guard" "$_o"
}

test_t03_fails_when_the_router_reaches_the_internet_while_blocked() {
	_ac_setup; : >"$F/curlok"
	_arm_fake
	_o=$(TSEM_NOW=1790000000 sh "$ACT" test t03_both_down 2>&1 </dev/null); _rc=$?; kill "$FAKE_WD" 2>/dev/null
	assert_eq exit 1 "$_rc"
	assert_contains egress "FAIL  t03.router_egress" "$_o"
	assert_contains unprot "unprotected WAN path" "$_o"
}

test_t02_failover_switches_to_secondary_and_returns() {
	_ac_setup
	_o=$(_run_t t02_failover >"$T/out"; cat "$T/out")
	for _k in t02.switch t02.exit t02.never_open t02.return t02.never_open_return final.killswitch; do assert_contains "$_k" "PASS  $_k" "$_o"; done
	assert_contains faultP "tick P=tsem-rc3-test-no-such-primary S=" "$(_calls)"
	assert_contains simulated "SIMULATED" "$(_fn_body "$ACT" t02_failover)"
	assert_contains note "simulation by identity mismatch" "$_o"
}

test_t00_activate_sets_german_and_waits_for_an_exit_node() {
	_ac_setup
	echo direct >"$F/mode"; echo open >"$F/guard"; echo DIRECT >"$F/state"; echo none >"$F/exit"
	_o=$(_run_t t00_activate >"$T/out"; cat "$T/out")
	# need_tests_ok runs first and passes; t00 itself changes the mode by `tsem set german` only
	assert_contains set "set german" "$(_calls)"
	assert_contains state "PASS  t00.state" "$_o"
	assert_contains guard "PASS  t00.guard" "$_o"
	case $(_calls) in *"set direct"*) fail "t00 set direct" ;; esac
}

test_t06_fastpath_module_loaded_in_german_is_a_failure() {
	_ac_setup; : >"$F/sfe"
	_o=$(_run_t t06_fastpath >"$T/out"; cat "$T/out")
	assert_contains fail "FAIL  t06.modules" "$_o"
	rm -f "$F/sfe"
	_o=$(_run_t t06_fastpath >"$T/out"; cat "$T/out")
	assert_contains pass "PASS  t06.modules" "$_o"
}

test_t07_firewall_reload_checks_layer1_and_restoration() {
	_ac_setup
	_o=$(_run_t t07_fwreload >"$T/out"; cat "$T/out")
	assert_contains reload "PASS  t07.reload" "$_o"
	assert_contains restored "PASS  t07.restored" "$_o"
	assert_contains window "t07.window" "$_o"
	case $_o in *"FAIL  t07"*) fail "unexpected FAIL: $_o" ;; esac
	assert_contains called "firewall reload" "$(_calls)"
	assert_contains limit "evidence, not proof" "$_o"
}

test_t08_tailscale_restart_is_skipped_over_a_tailnet_ssh_session() {
	_ac_setup; _arm_fake
	_o=$(AR_SSH_PATH=tailnet TSEM_NOW=1790000000 sh "$ACT" test t08_tsrestart 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains skip "SKIP  t08.restart" "$_o"
	case $(_calls) in *tailscale-init*) fail "tailscale was restarted over a tailnet session" ;; esac
	_o=$(_run_t t08_tsrestart >"$T/out"; cat "$T/out")
	assert_contains restart "PASS  t08.restart" "$_o"
	assert_contains rec "t08.recovered" "$_o"
	assert_contains called "tailscale-init restart" "$(_calls)"
}

test_active_test_end_state_is_never_an_open_guard_pass() {
	_ac_setup; : >"$F/leak"
	_arm_fake
	_o=$(TSEM_NOW=1790000000 sh "$ACT" test t03_both_down 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains final "final.killswitch" "$_o"
	case $_o in *"PASS  final.killswitch"*"guard=open"*) fail "open guard reported as PASS" ;; esac
}

# ---------------------------------------------------------------- Mac wrapper
_mac() { # args... ; stdin is the typed answers
	TSEM_MAC_CURL=${TSEM_MAC_CURL:-/nonexistent/curl} sh "$MAC" --out "$T/out" --stage "$ROOT" "$@" 2>&1
}
_stages() { ls -d /tmp/tsem-rc3-active-stage.* 2>/dev/null | sort; }

test_mac_prepare_declined_changes_nothing_on_the_router() {
	_ac_setup
	_b=$(_stages)
	_o=$(_mac prepare </dev/null); _rc=$?
	assert_eq rc 2 "$_rc"
	assert_contains declined "not confirmed" "$_o"
	[ -z "$(ls "$T/bk")" ] || fail "a backup was written without confirmation"
	case $(cat "$F/ssh.log") in *" backup"* | *stage-rc3* | *wire* | *recovery-arm*) fail "ssh ran a changing phase" ;; esac
	assert_eq stage-cleaned "$_b" "$(_stages)"
	# a near miss is not a confirmation
	_o=$(printf 'backup\n' | _mac prepare); assert_contains lower "not confirmed" "$_o"
	[ -z "$(ls "$T/bk")" ] || fail "lowercase phrase accepted"
}

test_mac_prepare_backs_up_and_copies_before_the_install_confirmation() {
	_ac_setup
	_o=$(printf 'BACKUP\nno\n' | _mac prepare); _rc=$?
	assert_eq rc 2 "$_rc"
	assert_contains copied "PASS  backup.copy " "$_o"
	assert_contains verified "PASS  backup.copy.verified" "$_o"
	ls "$T"/out/backup-*.tar >/dev/null 2>&1 || fail "no backup tar on the Mac side"
	[ -s "$T/out/latest-backup-dir" ] || fail "latest-backup-dir missing"
	case $(cat "$F/ssh.log") in *stage-rc3*) fail "staging ran without STAGE-RC3" ;; esac
	tar tf "$T"/out/backup-*.tar | grep -q manifest.txt || fail "manifest missing in backup"
	mkdir "$T/x" && tar xf "$T"/out/backup-*.tar -C "$T/x"
	_m=$(cat "$T"/x/*/manifest.txt); assert_contains mf "version.installed=$(sed -n 's/^TSEM_VERSION=//p' "$ROOT/src/usr/lib/tsem/common.sh" | tr -d '"')" "$_m"
	[ "$(stat -c %a "$T"/out/backup-*.tar)" = 600 ] || fail "backup tar not private"
}

test_mac_test_phase_needs_arm_and_a_start_phrase_per_test() {
	_ac_setup
	AR_SLEEP=sleep; export AR_SLEEP
	printf 'BACKUP\nSTAGE-RC3\n' | _mac prepare >/dev/null 2>&1 || fail "prepare failed"
	rm -f "$F/ssh.log"
	# nothing typed: no watchdog, no test
	_o=$(_mac test t04_dns </dev/null); assert_eq rc 2 "$?"
	case $(cat "$F/ssh.log") in *"recovery-arm"* | *"test t04_dns"*) fail "armed or ran without confirmation" ;; esac
	[ ! -e "$AR/recovery/armed" ] || fail "watchdog armed without ARM-RECOVERY"
	# armed but the START phrase is wrong: watchdog armed, test not run
	_o=$(printf 'ARM-RECOVERY\nWIRE-RC3\nstart t04_dns\nDISARM\n' | _mac test t04_dns)
	assert_contains armed "PASS  recovery.arm" "$_o"
	case $(cat "$F/ssh.log") in *"test t04_dns"*) fail "test ran with a wrong phrase" ;; esac
	# correct phrases: the test runs, the watchdog is disarmed afterwards
	rm -f "$F/ssh.log"
	_o=$(printf 'ARM-RECOVERY\nWIRE-RC3\nSTART t04_dns\nDISARM\n' | _mac test t04_dns)
	assert_contains ran "PASS  t04.resolve" "$_o"
	assert_contains summary "SUMMARY phase=test" "$_o"
	assert_contains disarmed "disarmed" "$_o"
	[ ! -e "$AR/recovery/armed" ] || fail "watchdog still armed after DISARM"
	ls "$T"/out/active-test-*.txt >/dev/null 2>&1 || fail "no report saved on the Mac"
}

test_mac_direct_is_the_only_command_that_opens_and_needs_its_phrase() {
	_ac_setup
	_o=$(printf 'direct\n' | _mac direct); assert_eq rc 2 "$?"
	assert_eq mode german "$(cat "$F/mode")"
	case $(_calls) in *"set direct"*) fail "opened without phrase" ;; esac
	_o=$(printf 'OPEN-KILLSWITCH\n' | _mac direct)
	assert_contains opened "PASS  direct.set" "$_o"
	assert_eq mode direct "$(cat "$F/mode")"
}

test_mac_recover_runs_recovery_without_opening() {
	_ac_setup
	echo blocked >"$F/guard"; echo BLOCKED >"$F/state"
	_o=$(printf 'recover\n' | _mac recover); assert_eq rc 2 "$?"
	: >"$F/calls"
	_o=$(printf 'RECOVER\n' | _mac recover)
	assert_contains res "RECOVERY_RESULT=ok" "$_o"
	case $(_calls) in *"set direct"* | *teardown*) fail "recovery opened the kill switch" ;; esac
	assert_eq guard german "$(cat "$F/guard")"
}

test_recovery_is_only_ok_when_the_router_really_reaches_the_internet() {
	_ac_setup
	echo blocked >"$F/guard"; echo BLOCKED >"$F/state"; : >"$F/curldead"
	_o=$(printf 'RECOVER\n' | _mac recover)
	assert_contains deg "RECOVERY_RESULT=degraded" "$_o"
	assert_contains why "router-own HTTPS request through the exit node FAILS" "$_o"
	assert_eq guard german "$(cat "$F/guard")"
	case $(_calls) in *"set direct"* | *teardown*) fail "recovery opened the kill switch" ;; esac
	rm -f "$F/curldead"; echo blocked >"$F/guard"; echo BLOCKED >"$F/state"
	_o=$(printf 'RECOVER\n' | _mac recover)
	assert_contains ok "RECOVERY_RESULT=ok" "$_o"
}

test_mac_rollback_needs_a_known_backup_and_its_phrase() {
	_ac_setup
	_o=$(printf 'ROLLBACK\n' | _mac rollback); assert_eq rc 2 "$?"
	assert_contains nobk "no known backup" "$_o"
	case $(cat "$F/ssh.log" 2>/dev/null) in *--confirm-rollback*) fail "rollback ran" ;; esac
}

test_mac_wrapper_rejects_unsafe_stage_and_backup_paths() {
	t_setup
	_fn=$(sed -n '/^valid_stage_path() {/,/^}/p; /^valid_backup_dir() {/p; /^valid_stage_dir() {/p' "$MAC")
	( eval "$_fn"
	  valid_stage_path /tmp/tsem-rc3-active-stage.1790000000.123 || exit 1
	  valid_stage_path /tmp/glinet-tailscale-exit-manager && exit 2
	  valid_stage_path /tmp/tsem-rc3-active-stage.1.2/../x && exit 3
	  valid_stage_path /tmp/tsem-rc3-active-stage.1.2.3a && exit 4
	  valid_stage_path / && exit 5
	  valid_stage_path '/tmp/tsem-rc3-active-stage.1.2; rm -rf /' && exit 6
	  TSEM_RC3_BK_BASE=/root; valid_backup_dir /root/tsem-rc3-backup-20261117-101010-55 || exit 7
	  valid_backup_dir /root/tsem-rc3-backup-1/../../etc && exit 8
	  valid_backup_dir /etc && exit 9
	  valid_stage_dir /root/tsem-rc3-stage-20261117-101010-55 || exit 10
	  valid_stage_dir /root/tsem-rc3-stage-1/../../etc && exit 11
	  valid_stage_dir /root/tsem-rc3-backup-1 && exit 12
	  exit 0 ); assert_eq paths 0 "$?"
}

# ======================================================================================================
# Regression tests for the three blockers of the pre-prepare review
#   B1  "passive" install was live (hotplug/fw3 include/boot) -> prepare only stages; wire is separate, journaled, auto-restoring
#   B2  interrupted install had no recovery -> INPROGRESS marker, signals ignored, --recover / install-recover
#   B3  weak gates -> hard backup gates, leak tests that cannot pass on a broken probe
# ======================================================================================================
_rsnap() { (cd "$RT" && find . \( -type f -o -type l \) | grep -v '^./etc/tsem/backup/' | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(md5sum <"$f" 2>/dev/null | cut -c1-32)"; done); }
# a router that really has RC2-ish tsem installed (real install.sh into the fake root), with config, boot link and GL hook
_ac_real_rc2() {
	_ac_setup; _path_tools
	rm -rf "${RT:?}/usr" "${RT:?}/etc/tsem" "${RT:?}/etc/init.d/tsem"
	mkdir -p "$RT/etc/gl-switch.d" "$RT/etc/rc.d" "$RT/etc/hotplug.d/iface"
	printf "config defaults\n\toption input 'ACCEPT'\n" >"$RT/etc/config/firewall"
	printf '#!/bin/sh\n# GL prototype\n' >"$RT/etc/gl-switch.d/tailscale-de.sh"; chmod 755 "$RT/etc/gl-switch.d/tailscale-de.sh"
	TSEM_INSTALL_STAMP=20260101-000001 sh "$ROOT/install.sh" --root "$RT" --yes --no-enable --keep-gl-hook >"$T/rc2.out" 2>&1 || fail "fixture install failed: $(cat "$T/rc2.out")"
	for _f in usr/sbin/tsem usr/lib/tsem/common.sh usr/lib/tsem/state.sh usr/lib/tsem/conf.sh etc/init.d/tsem etc/hotplug.d/iface/50-tsem; do echo '# rc2' >>"$RT/$_f"; done
	sed -i 's/^TSEM_VERSION=.*/TSEM_VERSION="0.1.0-rc2"/' "$RT/usr/lib/tsem/common.sh"
	printf 'TSEM_KEEP=1\n' >>"$RT/etc/tsem/tsem.conf"
	ln -s ../init.d/tsem "$RT/etc/rc.d/S18tsem"
	echo german >"$F/mode"; echo german >"$F/guard"
}
_prep() { # backup + stage on the fake router; sets BKD SD
	BKD=$(sh "$ACT" backup 2>&1 </dev/null | sed -n 's/^BACKUP_DIR=//p')
	[ -d "$BKD" ] || fail "backup failed"
	SD=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null | sed -n 's/^STAGE_DIR=//p')
	[ -d "$SD" ] || fail "stage failed: $(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null | grep -v '^INFO')"
}
_wire() { _arm_fake; TSEM_INSTALL_STAMP=20260101-000002 sh "$ACT" wire --confirm-wire "$BKD" "$SD" >"$T/wire.out" 2>&1 </dev/null; _WRC=$?; kill "$FAKE_WD" 2>/dev/null; _W=$(cat "$T/wire.out"); }

# ---------------- B1: prepare changes nothing live ----------------
test_b1_prepare_stage_leaves_every_live_handler_untouched() {
	_ac_real_rc2
	_before=$(_rsnap)
	_o=$(sh "$ACT" backup 2>&1 </dev/null); BKD=$(printf '%s\n' "$_o" | sed -n 's/^BACKUP_DIR=//p')
	_so=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); _rc=$?
	assert_eq stage-rc 0 "$_rc"
	for _k in stage.manifest stage.verified stage.syntax stage.trial stage.live_unchanged; do assert_contains "$_k" "PASS  $_k" "$_so"; done
	assert_eq live-tree-identical "$_before" "$(_rsnap)"
	# nothing that could fire RC3 changed: hotplug handler, fw3 include, init script, boot link, GL hook
	grep -q '# rc2' "$RT/etc/hotplug.d/iface/50-tsem" || fail "hotplug handler replaced during prepare"
	[ -L "$RT/etc/rc.d/S18tsem" ] || fail "boot link changed"
	assert_eq version 0.1.0-rc2 "$(sed -n 's/^TSEM_VERSION="\(.*\)"/\1/p' "$RT/usr/lib/tsem/common.sh")"
	SD=$(printf '%s\n' "$_so" | sed -n 's/^STAGE_DIR=//p')
	[ -s "$SD/.complete" ] && [ -s "$SD/MANIFEST" ] && [ -f "$SD/repo/install.sh" ] || fail "stage incomplete"
	case $(_calls) in *reapply* | *tick* | *"set "*) fail "prepare called the controller: $(_calls)" ;; esac
}
test_b1_live_fingerprint_sees_every_handler() {
	_ac_real_rc2
	_fn=$(sed -n '/^hsum() {/p; /^have() {/p; /^live_fingerprint() {/,/^}/p' "$ACT")
	_f0=$( R=$RT; eval "$_fn"; live_fingerprint )
	[ -n "$_f0" ] || fail "empty fingerprint"
	for _mut in 'echo x >>"$RT/etc/hotplug.d/iface/50-tsem"' 'echo x >>"$RT/etc/config/firewall"' 'echo x >>"$RT/etc/init.d/tsem"' \
		'rm "$RT/etc/rc.d/S18tsem"' 'ln -s ../init.d/tsem "$RT/etc/rc.d/K10tsem"' 'echo x >>"$RT/etc/gl-switch.d/tailscale-de.sh"' 'echo x >>"$RT/usr/lib/tsem/fw-include.sh"' 'echo x >>"$RT/etc/tsem/intent"'; do
		_ac_real_rc2
		( R=$RT; eval "$_fn"; _a=$(live_fingerprint); eval "$_mut"; _b=$(live_fingerprint); [ "$_a" != "$_b" ] ) || fail "fingerprint blind to: $_mut"
	done
}
test_b1_wire_refuses_without_watchdog_confirmation_or_verified_inputs() {
	_ac_real_rc2; _prep; _s=$(_rsnap)
	_o=$(sh "$ACT" wire --confirm-wire "$BKD" "$SD" 2>&1 </dev/null); assert_contains nowd "recovery watchdog is not armed" "$_o"
	_arm_fake
	_o=$(sh "$ACT" wire "$BKD" "$SD" 2>&1 </dev/null); assert_contains noflag "wire needs --confirm-wire" "$_o"
	_o=$(sh "$ACT" wire --confirm-wire "$BKD" /tmp/evil 2>&1 </dev/null); assert_contains badstage "completed stage directory" "$_o"
	echo '# tampered' >>"$SD/repo/src/usr/sbin/tsem"
	_o=$(sh "$ACT" wire --confirm-wire "$BKD" "$SD" 2>&1 </dev/null); _rc=$?
	kill "$FAKE_WD" 2>/dev/null
	assert_eq rc 1 "$_rc"; assert_contains tamper "FAIL  stage.verified" "$_o"; assert_contains refused "WIRE_RESULT=refused" "$_o"
	assert_eq nothing-changed "$_s" "$(_rsnap)"
}
test_b1_wire_upgrades_and_keeps_intent_config_hook_and_boot_link() {
	_ac_real_rc2; _prep
	_i0=$(md5sum <"$RT/etc/tsem/intent"); _c0=$(md5sum <"$RT/etc/tsem/tsem.conf"); _h0=$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")
	_wire
	assert_eq rc 0 "$_WRC"
	assert_contains result "WIRE_RESULT=ok" "$_W"
	for _k in install.rc verify.version verify.files verify.preserved verify.intent verify.selftest verify.guard verify.journal; do assert_contains "$_k" "PASS  $_k" "$_W"; done
	assert_eq version "$(sed -n 's/^TSEM_VERSION=//p' "$ROOT/src/usr/lib/tsem/common.sh" | tr -d '"')" "$(sed -n 's/^TSEM_VERSION=//p' "$RT/usr/lib/tsem/common.sh" | tr -d '"')"
	assert_eq intent "$_i0" "$(md5sum <"$RT/etc/tsem/intent")"
	assert_eq conf "$_c0" "$(md5sum <"$RT/etc/tsem/tsem.conf")"
	assert_eq hook "$_h0" "$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")"
	[ -L "$RT/etc/rc.d/S18tsem" ] || fail "boot link lost"
	grep -q TSEM_KEEP=1 "$RT/etc/tsem/tsem.conf" || fail "tsem.conf content lost"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left"
	# a second wire of the same version does nothing
	_wire; assert_contains again "wire.already" "$_W"
}
test_b1_wire_upgrades_an_installed_rc3_to_rc3_1_without_an_open_guard() {
	_ac_real_rc2
	sed -i 's/^TSEM_VERSION=.*/TSEM_VERSION="0.1.0-rc3"/' "$RT/usr/lib/tsem/common.sh"
	_prep; _wire
	assert_eq rc 0 "$_WRC"
	assert_contains result "WIRE_RESULT=ok" "$_W"
	assert_eq version "$(sed -n 's/^TSEM_VERSION=//p' "$ROOT/src/usr/lib/tsem/common.sh" | tr -d '"')" "$(sed -n 's/^TSEM_VERSION=//p' "$RT/usr/lib/tsem/common.sh" | tr -d '"')"
	assert_contains guard "PASS  verify.guard" "$_W"
	[ "$(cat "$F/guard")" != open ] || fail "guard open after the upgrade"
	# a failed first attempt followed by a re-run converges (no inconsistent intermediate state)
	_wire; assert_contains again "wire.already" "$_W"
}
test_b1_failed_verification_restores_the_previous_state_exactly() {
	_ac_real_rc2; _prep; : >"$F/selftest_fail"
	_s=$(_rsnap)
	_wire
	assert_eq rc 1 "$_WRC"
	assert_contains fail "FAIL  verify.selftest" "$_W"
	assert_contains restored "WIRE_RESULT=restored" "$_W"
	assert_contains rv "PASS  restore.version" "$_W"; assert_contains rp "PASS  restore.preserved" "$_W"; assert_contains rg "PASS  restore.guard" "$_W"
	assert_eq exact-previous-state "$_s" "$(_rsnap)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left"
	case $(_calls) in *"set direct"*) fail "restore opened the kill switch" ;; esac
}
test_b1_guard_opened_by_the_new_version_is_closed_again_without_wan_fallback() {
	_ac_real_rc2; _prep; : >"$F/open_on_selftest"
	_wire
	assert_eq rc 1 "$_WRC"
	assert_contains opened "FAIL  verify.guard" "$_W"
	assert_contains restored "WIRE_RESULT=restored" "$_W"
	assert_contains closed "PASS  restore.guard" "$_W"
	[ "$(cat "$F/guard")" != open ] || fail "guard is open after the restore: $(cat "$F/guard")"
	case $(_calls) in *"set direct"*) fail "direct was set" ;; esac
	# even when reapply cannot fix it, the saved mode is re-asserted (never left open)
	_ac_real_rc2; _prep; : >"$F/open_on_selftest"; : >"$F/reapply_broken"
	_wire
	assert_contains result "WIRE_RESULT=restored" "$_W"
	assert_contains reasserted "set german" "$(_calls)"
	[ "$(cat "$F/guard")" != open ] || fail "guard open although reapply was broken"
}
test_b2_install_killed_during_wire_is_restored_from_the_journal() {
	_ac_real_rc2; _prep; _s=$(_rsnap)
	_arm_fake
	TSEM_INSTALL_KILL_AFTER=3 TSEM_INSTALL_STAMP=20260101-000002 sh "$ACT" wire --confirm-wire "$BKD" "$SD" >"$T/wire.out" 2>&1 </dev/null; _rc=$?
	kill "$FAKE_WD" 2>/dev/null
	assert_eq rc 1 "$_rc"
	assert_contains result "WIRE_RESULT=restored" "$(cat "$T/wire.out")"
	assert_eq exact-previous-state "$_s" "$(_rsnap)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left"
}
test_b2_repair_replays_an_interrupted_install_and_needs_its_flag() {
	_ac_real_rc2; _prep; _s=$(_rsnap)
	# the wiring process is killed and nobody restores it: only the persistent journal knows what happened
	TSEM_INSTALL_KILL_AFTER=3 TSEM_INSTALL_STAMP=20260101-000002 sh "$SD/repo/install.sh" --root "$RT" --yes --no-enable --keep-gl-hook >/dev/null 2>&1
	[ -f "$RT/etc/tsem/backup/INPROGRESS" ] || fail "no marker after the kill"
	[ "$_s" != "$(_rsnap)" ] || fail "kill happened before any change"
	assert_rc noflag 2 sh "$ACT" install-recover
	assert_rc badpath 2 sh "$ACT" install-recover --confirm-repair /etc /etc
	# wire refuses to start on top of it
	_arm_fake
	_o=$(sh "$ACT" wire --confirm-wire "$BKD" "$SD" 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains pending "wire.pending" "$_o"
	_o=$(sh "$ACT" install-recover --confirm-repair "$BKD" "$SD" 2>&1 </dev/null); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains ok "PASS  restore.install" "$_o"
	assert_eq exact-previous-state "$_s" "$(_rsnap)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left"
}
test_b2_watchdog_reports_a_pending_interrupted_install() {
	_ac_setup; mkdir -p "$RT/etc/tsem/backup"; echo 20260101-000002 >"$RT/etc/tsem/backup/INPROGRESS"
	mkdir -p "$AR/recovery"
	_o=$(sh "$REC" now 2>&1 </dev/null; cat "$AR/recovery/recover.log" 2>/dev/null)
	assert_contains note "interrupted tsem install is pending" "$_o"
}

# ---------------- B3: backup gates ----------------
test_b3_missing_hash_tools_or_tar_can_never_pass_the_backup() {
	_ac_real_rc2
	_o=$(AR_MISSING="sha256sum md5sum" sh "$ACT" backup 2>&1 </dev/null); _rc=$?
	assert_eq rc 1 "$_rc"; assert_contains tool "FAIL  backup.tool" "$_o"
	case $_o in *"PASS  backup.verified"* | *BACKUP_DIR=*) fail "backup passed without a hash tool" ;; esac
	_o=$(AR_MISSING=tar sh "$ACT" backup 2>&1 </dev/null); assert_eq rc 1 "$?"; assert_contains tar "FAIL  backup.tool" "$_o"
	# only one of the two hash tools missing: still fine
	_o=$(AR_MISSING=sha256sum sh "$ACT" backup 2>&1 </dev/null); assert_eq rc 0 "$?"; assert_contains md5 "PASS  backup.verified" "$_o"
	# a stage run with the hash tools gone is refused too
	_prep
	_o=$(AR_MISSING="sha256sum md5sum" sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); assert_eq rc 1 "$?"
	assert_contains gate "FAIL  backup.tool" "$_o"
}
test_b3_missing_required_files_fail_the_backup() {
	_ac_real_rc2; rm "$RT/etc/config/network"
	_o=$(sh "$ACT" backup 2>&1 </dev/null); assert_eq rc 1 "$?"; assert_contains net "FAIL  backup.required" "$_o"
	_ac_real_rc2; rm "$RT/etc/init.d/tsem"
	_o=$(sh "$ACT" backup 2>&1 </dev/null); assert_eq rc 1 "$?"; assert_contains incomplete "FAIL  backup.required" "$_o"
}
test_b3_incomplete_or_tampered_backups_are_rejected_before_staging_and_wiring() {
	_ac_real_rc2
	BKD=$(sh "$ACT" backup 2>&1 </dev/null | sed -n 's/^BACKUP_DIR=//p'); [ -d "$BKD" ] || fail "no backup"
	cp -R "$BKD" "$T/good"
	# 1. archive tampered
	echo junk >>"$BKD/files.tar"
	_o=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); assert_eq tamper 1 "$?"; assert_contains sum "FAIL  backup.checksum" "$_o"
	case $_o in *STAGE_DIR=*) fail "staged despite a bad backup" ;; esac
	# 2. archive lacks the tsem config but has a matching checksum
	rm -rf "$BKD"; cp -R "$T/good" "$BKD"
	( cd "$RT" && tar cf "$BKD/files.tar" usr etc/config etc/init.d etc/hotplug.d etc/gl-switch.d etc/rc.d )
	sha256sum "$BKD/files.tar" | cut -d' ' -f1 >"$BKD/files.tar.sum"
	_o=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); assert_eq incomplete 1 "$?"; assert_contains miss "FAIL  backup.complete" "$_o"
	# 3. manifest without a required field / with a wrong intent hash
	rm -rf "$BKD"; cp -R "$T/good" "$BKD"; grep -v '^intent.sum=' "$T/good/manifest.txt" >"$BKD/manifest.txt"
	_o=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); assert_eq nofield 1 "$?"; assert_contains mf "FAIL  backup.manifest" "$_o"
	rm -rf "$BKD"; cp -R "$T/good" "$BKD"; sed -i 's/^intent.sum=.*/intent.sum=deadbeef/' "$BKD/manifest.txt"
	_o=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); assert_eq badsum 1 "$?"; assert_contains is "FAIL  backup.intent.sum" "$_o"
	# 4. empty firewall snapshot although iptables-save exists
	rm -rf "$BKD"; cp -R "$T/good" "$BKD"; : >"$BKD/iptables.txt"
	_o=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); assert_eq emptyipt 1 "$?"; assert_contains ipt "FAIL  backup.iptables" "$_o"
	# 5. wire runs the same gate again right before the live change
	_prep; rm -rf "$BKD"; cp -R "$T/good" "$BKD"; echo junk >>"$BKD/files.tar"
	_arm_fake; _s=$(_rsnap)
	_o=$(sh "$ACT" wire --confirm-wire "$BKD" "$SD" 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains wiregate "wire.backup" "$_o"; assert_eq unchanged "$_s" "$(_rsnap)"
	# control: the untouched backup passes every gate
	rm -rf "$BKD"; cp -R "$T/good" "$BKD"
	_o=$(sh "$ACT" stage-rc3 "$BKD" 2>&1 </dev/null); assert_eq control 0 "$?"; assert_contains ok "PASS  backup.verified" "$_o"
}

# ---------------- B3: leak tests that cannot pass on a broken probe ----------------
_t03() { _o=$(_run_t t03_both_down >"$T/out"; cat "$T/out"); }
test_b3_t03_without_curl_is_not_a_pass() {
	_ac_setup
	_arm_fake; _o=$(AR_MISSING=curl TSEM_NOW=1790000000 sh "$ACT" test t03_both_down 2>&1 </dev/null); _rc=$?; kill "$FAKE_WD" 2>/dev/null
	assert_eq rc 1 "$_rc"
	assert_contains fail "FAIL  t03.router_egress" "$_o"
	case $_o in *"PASS  t03.router_egress"*) fail "leak test passed without curl" ;; esac
}
test_b3_t03_curl_errors_other_than_blocked_are_inconclusive() {
	_ac_setup; echo 35 >"$F/curlrc"
	_t03; assert_contains fail "FAIL  t03.router_egress" "$_o"; assert_contains why "inconclusive" "$_o"
	case $_o in *"PASS  t03.router_egress"*) fail "TLS/other curl error counted as blocked" ;; esac
	_ac_setup; echo 7 >"$F/curlrc"
	_t03; assert_contains refused-is-evidence "PASS  t03.router_egress" "$_o"
	_ac_setup; echo 6 >"$F/curlrc"
	_t03; assert_contains resolve-is-evidence "PASS  t03.router_egress" "$_o"
}
test_b3_t03_needs_a_working_curl_in_german_as_positive_control() {
	_ac_setup; : >"$F/curldead"
	_t03
	assert_contains control "FAIL  t03.curl_control" "$_o"
	assert_contains egress "FAIL  t03.router_egress" "$_o"
	case $_o in *"PASS  t03.router_egress"*) fail "passed without a positive control" ;; esac
	_ac_setup
	_t03; assert_contains ok "PASS  t03.curl_control" "$_o"
}
test_b3_route_checks_need_recognised_output() {
	_ac_setup; : >"$F/route_weird"
	_t03; assert_contains fail "FAIL  t03.lan_route" "$_o"; assert_contains why "inconclusive" "$_o"
	_ac_setup
	_arm_fake; _o=$(AR_MISSING=ip TSEM_NOW=1790000000 sh "$ACT" test t03_both_down 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains noip "FAIL  t03.lan_route" "$_o"
	_fn=$(sed -n '/^route_class() {/,/^}/p' "$ACT"); eval "$_fn"
	assert_eq prohibit denied "$(route_class 'prohibit 1.1.1.1 from 192.168.8.2 dev br-lan')"
	assert_eq unreach denied "$(route_class 'RTNETLINK answers: Network is unreachable')"
	assert_eq tun tunnel "$(route_class '1.1.1.1 dev tailscale0 src 100.64.0.1')"
	assert_eq wan routed "$(route_class '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.2')"
	assert_eq empty inconclusive "$(route_class '')"
	assert_eq nf inconclusive "$(route_class 'sh: ip: not found')"
}
test_b3_probe_https_classification() {
	_ac_setup
	_fn=$(sed -n '/^probe_https() {/,/^}/p; /^have() {/p' "$ACT"); eval "$_fn"
	printf '#!/bin/sh\nexit "$(cat "$FAKE_F/rc")"\n' >"$FB/curl"; chmod +x "$FB/curl"
	for _pair in 0:reached 6:blocked 7:blocked 28:blocked 1:inconclusive 35:inconclusive 60:inconclusive 127:inconclusive; do
		echo "${_pair%%:*}" >"$F/rc"; assert_eq "curl-${_pair%%:*}" "${_pair#*:}" "$(probe_https https://x)"
	done
	AR_MISSING=curl; assert_eq nocurl inconclusive "$(probe_https https://x)"
}
test_b3_fastpath_and_offload_checks_need_their_tools() {
	_ac_setup
	printf '#!/bin/sh\n' >"$FB/lsmod"
	_o=$(_run_t t06_fastpath >"$T/out"; cat "$T/out"); assert_contains lsmod "FAIL  t06.lsmod" "$_o"
	_ac_setup; : >"$F/ipt_empty"
	_o=$(_run_t t06_fastpath >"$T/out"; cat "$T/out"); assert_contains ipt "FAIL  t06.flowoffload" "$_o"
	case $_o in *"PASS  t06.flowoffload"*) fail "offload check passed without iptables output" ;; esac
	_ac_setup
	_o=$(_run_t t06_fastpath >"$T/out"; cat "$T/out"); assert_contains control "PASS  t06.flowoffload" "$_o"
	_ac_setup
	_arm_fake; _o=$(AR_MISSING=nslookup TSEM_NOW=1790000000 sh "$ACT" test t04_dns 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains dns "FAIL  t04.resolve" "$_o"
}
test_b3_mac_observer_needs_curl_and_a_positive_control() {
	t_setup
	_fn=$(sed -n '/^mac_curl() {/,/^}/p; /^mac_ip4() {/p; /^mac_ip6() {/p; /^observe_point() {/,/^}/p' "$MAC")
	printf '#!/bin/sh\nrc=$(cat "$MCRC")\n[ "$rc" = 0 ] && echo "ip=203.0.113.9"\nexit "$rc"\n' >"$T/mcurl"; chmod +x "$T/mcurl"
	MCRC=$T/mcrc; export MCRC TSEM_RC3_CURL=$T/mcurl
	( say() { echo "$*"; }; mac_dns() { :; }; eval "$_fn"
	  echo 28 >"$MCRC"; EXPECT_IP=''; _a=$(observe_point blocked)
	  echo "$_a" | grep -q 'FAIL  *mac.blocked.*positive control' || exit 1
	  EXPECT_IP=203.0.113.9; _b=$(observe_point blocked); echo "$_b" | grep -q 'PASS  *mac.blocked ' || exit 2
	  echo 35 >"$MCRC"; _c=$(observe_point blocked); echo "$_c" | grep -q 'FAIL  *mac.blocked.*inconclusive' || exit 3
	  echo 0 >"$MCRC"; _d=$(observe_point blocked); echo "$_d" | grep -q 'FAIL  *mac.blocked.*UNPROTECTED' || exit 4
	  TSEM_RC3_CURL=/nonexistent/curl; _e=$(observe_point blocked); echo "$_e" | grep -q 'FAIL  *mac.blocked.*curl is missing' || exit 5
	  exit 0 ); assert_eq observer 0 "$?"
}

# ---------------- B3/8: BusyBox / OpenWrt compatibility ----------------
test_b8_router_side_scripts_use_only_posix_sh_and_busybox_applets() {
	t_setup
	for _f in "$ACT" "$REC" "$ROOT/install.sh"; do
		_c=$(_code "$_f")
		printf '%s\n' "$_c" | grep -nE '\[\[|\blocal +[a-z_]+|<<<|\$\{[A-Za-z_]+//|\$\{[A-Za-z_]+:[0-9]|echo +-e|readarray|mapfile|^[[:space:]]*source |^[[:space:]]*function |^[[:space:]]*\(\( |pipefail|declare |<\(|(^|[|;&(])[[:space:]]*timeout +[0-9]|\bxargs +-0|\bstat +-c|sed +-i|\bgrep +-[a-zA-Z]*P|\bdate +-d|\breadlink +-f|tar .*--wildcards|find .* -printf|\bsort +-V' >"$T/bash.txt" && fail "non-BusyBox construct in ${_f##*/}: $(head -n 3 "$T/bash.txt")"
	done
	# the router script only needs applets that BusyBox in OpenWrt 21.02 provides
	_used=$(_code "$ACT" | grep -oE '(^|[|;&(]|\$\()[[:space:]]*(tar|find|sort|uniq|awk|sed|grep|cut|tr|head|tail|wc|readlink|date|ps|df|sleep|kill|cat|mkdir|rm|cp|ls|md5sum|sha256sum|env|setsid|nohup)[[:space:]]' | tr -d '|;&($ ' | sort -u | tr '\n' ' ')
	[ -n "$_used" ] || fail "no applets found"
	for _a in $_used; do case $_a in tar | find | sort | uniq | awk | sed | grep | cut | tr | head | tail | wc | readlink | date | ps | df | sleep | kill | cat | mkdir | rm | cp | ls | md5sum | sha256sum | env | setsid | nohup) ;; *) fail "unexpected applet $_a" ;; esac; done
	_c=$(_code "$ACT")
	case $_c in *"tar cf"*"-C"*) ;; esac
	for _s in "$ACT" "$REC" "$MAC" "$ROOT/install.sh"; do sh -n "$_s" || fail "syntax error in $_s"; done
}

# ======================================================================================================
# Final acceptance: recovery watchdog under procd (proven by use), prepared-input verification, go-live,
# final mode, persistence, and the single-command Mac flow
# ======================================================================================================
_wd_env() { unset TSEM_NOW; export AR_PROBE_TIMEOUT=3 AR_WD_STEP=1 AR_WD_STALE=4 AR_WD_GRACE=3 AR_HB_FRESH=20; }
_wd_cleanup() { for _s in tsem-rc3-wd tsem-rc3-wd-probe; do ubus call service delete "{\"name\":\"$_s\"}" >/dev/null 2>&1; done; pkill -9 -f "$FB/tsem daemon" 2>/dev/null; true; }
_fake_initd() { # an init script that starts a fake daemon (the real one needs procd/rc.common)
	mkdir -p "$T/initd"
	cat >"$T/initd/tsem" <<'IEOF'
#!/bin/sh
case $1 in
start) [ -e "$FAKE_F/nostart" ] && exit 1; sh "$FB/tsem" daemon </dev/null >/dev/null 2>&1 & ;;
stop) pkill -9 -f "$FB/tsem daemon" 2>/dev/null; exit 0 ;;
esac
exit 0
IEOF
	cp "$RT/etc/init.d/tailscale" "$T/initd/tailscale"; cp "$RT/etc/init.d/firewall" "$T/initd/firewall"; chmod +x "$T/initd"/*
	export AR_INITD=$T/initd FB
}

test_wd_probe_proves_the_mechanism_by_using_it() {
	_ac_setup; _wd_env
	_o=$(sh "$ACT" recovery-verify 2>&1 </dev/null); _rc=$?
	_wd_cleanup
	assert_eq rc 0 "$_rc"
	for _k in probe.start probe.detached probe.heartbeat probe.keepalive probe.timeout probe.monitor recovery.verified; do assert_contains "$_k" "PASS  $_k" "$_o"; done
	[ ! -d "$AR/probe" ] || fail "probe directory left behind"
	[ ! -e "$F/svc/tsem-rc3-wd-probe.watch.pid" ] || fail "probe service left behind"
	# the probe never touched tsem or the network
	assert_eq nocalls "" "$(_calls)"
}
test_wd_arm_is_refused_when_the_mechanism_cannot_be_proven() {
	for _case in noubus noadd nofire nohb; do
		_ac_setup; _wd_env
		case $_case in
		noubus) _e='AR_MISSING=ubus' ;;
		noadd) : >"$F/ubus_noadd"; _e='X=1' ;;
		nofire) _e='AR_PROBE_BROKEN=nofire' ;;
		nohb) _e='AR_PROBE_BROKEN=nohb' ;;
		esac
		_o=$(env "$_e" sh "$ACT" recovery-arm 120 2>&1 </dev/null); _rc=$?
		_wd_cleanup
		assert_eq "rc-$_case" 1 "$_rc"
		assert_contains "arm-$_case" "FAIL  recovery.arm" "$_o"
		case $_o in *"PASS  recovery.arm"*) fail "armed although $_case" ;; esac
		[ ! -e "$AR/recovery/armed" ] || fail "armed marker exists after a failed arm ($_case)"
		# nothing may be wired or tested without it
		_o=$(sh "$ACT" test t04_dns 2>&1 </dev/null); assert_contains "tests-$_case" "not armed" "$_o"
		_o=$(sh "$ACT" go-live --confirm-golive /root/tsem-rc3-backup-1 /root/tsem-rc3-stage-1 2>&1 </dev/null); assert_eq "golive-$_case" 2 "$?"
	done
}
test_wd_real_arm_runs_under_procd_and_tests_check_it_stays_alive() {
	_ac_setup; _wd_env
	_o=$(sh "$ACT" recovery-arm 120 2>&1 </dev/null); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains arm "PASS  recovery.arm" "$_o"; assert_contains check "PASS  recovery.check" "$_o"
	assert_contains st "heartbeat_age=" "$(sh "$ACT" recovery-status 2>&1)"
	_o=$(sh "$ACT" test t04_dns 2>&1 </dev/null)
	assert_contains alive "PASS  t04_dns.watchdog" "$_o"
	# a stale heartbeat is never "armed"
	_p=$(cat "$AR/recovery/pid"); kill -STOP "$_p"; sleep 1
	echo 1 >"$AR/recovery/hb"
	_o=$(AR_HB_FRESH=2 sh "$ACT" test t04_dns 2>&1 </dev/null); assert_contains stale "not armed" "$_o"
	kill -CONT "$_p" 2>/dev/null
	sh "$ACT" recovery-disarm >/dev/null 2>&1; _wd_cleanup
	[ ! -e "$AR/recovery/armed" ] || fail "still armed after disarm"
}
test_wd_monitor_recovers_when_the_watcher_hangs_and_recovery_keeps_the_guard_closed() {
	_ac_setup; _wd_env; echo blocked >"$F/guard"
	_o=$(sh "$ACT" recovery-arm 120 2>&1 </dev/null); assert_contains arm "PASS  recovery.arm" "$_o"
	: >"$F/calls"
	kill -STOP "$(cat "$AR/recovery/pid")"
	_i=0; while [ ! -e "$AR/recovery/fired" ] && [ "$_i" -lt 25 ]; do sleep 1; _i=$((_i + 1)); done
	kill -CONT "$(cat "$AR/recovery/pid" 2>/dev/null)" 2>/dev/null
	_wd_cleanup
	[ -e "$AR/recovery/fired" ] || fail "the monitor did not recover although the watcher was frozen"
	assert_contains why "heartbeat is stale" "$(cat "$AR/recovery/recover.log")"
	assert_contains reapply "reapply" "$(_calls)"
	case $(_calls) in *"set direct"*) fail "recovery opened the kill switch" ;; esac
}
test_wd_watch_resumes_its_state_and_keepalive_is_atomic() {
	_ac_setup; unset TSEM_NOW; AR_SLEEP=sleep; export AR_SLEEP
	mkdir -p "$AR/recovery"
	AR_RUN=$AR sh "$REC" prepare 100 >/dev/null 2>&1
	_d1=$(cat "$AR/recovery/deadline")
	AR_RUN=$AR AR_WATCH_STEP=1 sh "$REC" watch >/dev/null 2>&1 &
	_w=$!; sleep 2
	assert_eq unchanged "$_d1" "$(cat "$AR/recovery/deadline")"
	assert_contains resumed "watchdog resumed" "$(cat "$AR/recovery/recover.log")"
	[ -s "$AR/recovery/hb" ] || fail "no heartbeat"
	kill "$_w" 2>/dev/null
	# no state and no seconds: nothing to watch, no recovery
	rm -rf "$AR/recovery"; _o=$(AR_RUN=$AR sh "$REC" watch 2>&1); assert_contains none "not armed" "$_o"
	case $(_calls) in *reapply*) fail "recovery ran without any armed state" ;; esac
	# the deadline writers replace the file atomically
	assert_contains atomic "deadline.new" "$(_fn_body "$REC" setdl)"
}
test_wd_recovery_replays_an_interrupted_install_from_the_journal() {
	_ac_real_rc2; _prep; _s=$(_rsnap); _wd_env
	TSEM_INSTALL_KILL_AFTER=3 TSEM_INSTALL_STAMP=20260101-000002 sh "$SD/repo/install.sh" --root "$RT" --yes --no-enable --keep-gl-hook >/dev/null 2>&1
	[ -f "$RT/etc/tsem/backup/INPROGRESS" ] || fail "no marker after the kill"
	mkdir -p "$AR/recovery"; echo "$SD/repo/install.sh" >"$AR/recovery/install_sh"
	_o=$(AR_RUN=$AR sh "$REC" now 2>&1)
	assert_contains replay "journal replay rc=0" "$(cat "$AR/recovery/recover.log")"
	assert_eq exact-previous-state "$_s" "$(_rsnap)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left"
	case $(_calls) in *"set direct"*) fail "opened" ;; esac
	# without the install script: reported, nothing opened, nothing changed further
	TSEM_INSTALL_KILL_AFTER=3 TSEM_INSTALL_STAMP=20260101-000003 sh "$SD/repo/install.sh" --root "$RT" --yes --no-enable --keep-gl-hook >/dev/null 2>&1
	rm -f "$AR/recovery/install_sh"; _s2=$(_rsnap)
	_o=$(AR_RUN=$AR sh "$REC" now 2>&1)
	assert_contains warn "cannot replay the journal" "$(cat "$AR/recovery/recover.log")"
	assert_eq unchanged "$_s2" "$(_rsnap)"
	[ "$(cat "$F/guard")" != open ] || fail "guard open"
}

# ---------------- verify-prepared ----------------
test_verify_prepared_accepts_the_prepared_inputs_and_rejects_drift() {
	_ac_real_rc2; _prep
	_o=$(sh "$ACT" verify-prepared "$BKD" "$SD" 2>&1 </dev/null); _rc=$?
	assert_eq rc 0 "$_rc"; assert_contains payload "PASS  prepared.payload" "$_o"; assert_contains version "PASS  prepared.version" "$_o"
	# the router changed since the backup
	echo 'TSEM_NEW=1' >>"$RT/etc/tsem/tsem.conf"
	_o=$(sh "$ACT" verify-prepared "$BKD" "$SD" 2>&1 </dev/null); assert_eq drift 1 "$?"; assert_contains d "FAIL  prepared.drift" "$_o"
	_ac_real_rc2; _prep
	# an interrupted install is pending
	mkdir -p "$RT/etc/tsem/backup"; echo x >"$RT/etc/tsem/backup/INPROGRESS"
	_o=$(sh "$ACT" verify-prepared "$BKD" "$SD" 2>&1 </dev/null); assert_eq pend 1 "$?"; assert_contains p "FAIL  prepared.journal" "$_o"
	# tampered backup / stage
	_ac_real_rc2; _prep; echo junk >>"$BKD/files.tar"
	_o=$(sh "$ACT" verify-prepared "$BKD" "$SD" 2>&1 </dev/null); assert_eq bk 1 "$?"; assert_contains b "FAIL  prepared.backup" "$_o"
	_ac_real_rc2; _prep; echo '# x' >>"$SD/repo/src/usr/sbin/tsem"
	_o=$(sh "$ACT" verify-prepared "$BKD" "$SD" 2>&1 </dev/null); assert_eq st 1 "$?"; assert_contains s "FAIL  prepared.stage" "$_o"
}
test_verify_prepared_notices_a_stage_for_another_payload() {
	_ac_real_rc2
	mkdir -p "$T/co"; ( cd "$ROOT" && tar cf - tools install.sh uninstall.sh src contrib ) | ( cd "$T/co" && tar xf - )
	ACT=$T/co/tools/tsem-rc3-active.sh
	_prep
	echo '# other payload' >>"$T/co/src/usr/lib/tsem/state.sh"
	_o=$(sh "$ACT" verify-prepared "$BKD" "$SD" 2>&1 </dev/null); assert_eq rc 1 "$?"
	assert_contains payload "FAIL  prepared.payload" "$_o"
}

# ---------------- go-live ----------------
_golive() { _arm_fake; sh "$ACT" go-live --confirm-golive "$BKD" "$SD" >"$T/gl.out" 2>&1 </dev/null; _GRC=$?; kill "$FAKE_WD" 2>/dev/null; _G=$(cat "$T/gl.out"); }
_wired() { _ac_real_rc2; rm -f "$RT/etc/rc.d/S18tsem"; _fake_initd; _prep; _wire; assert_eq wired 0 "$_WRC"; }
test_golive_integrates_hook_boot_link_and_service_and_keeps_the_original_hook() {
	_wired; _h0=$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh"); _i0=$(md5sum <"$RT/etc/tsem/intent"); _c0=$(md5sum <"$RT/etc/tsem/tsem.conf")
	_s0=$(_rsnap)
	_golive
	pkill -9 -f "$FB/tsem daemon" 2>/dev/null
	assert_eq rc 0 "$_GRC"
	assert_contains res "GOLIVE_RESULT=ok" "$_G"
	for _k in golive.install golive.hook golive.hook.original golive.boot golive.preserved golive.daemon golive.guard golive.selftest; do assert_contains "$_k" "PASS  $_k" "$_G"; done
	cmp -s "$ROOT/contrib/tsem-switch.sh" "$RT/etc/gl-switch.d/tailscale-de.sh" || fail "the GL hook is not the tsem hook"
	[ -x "$RT/etc/rc.d/S18tsem" ] || fail "no boot link"
	assert_eq intent "$_i0" "$(md5sum <"$RT/etc/tsem/intent")"; assert_eq conf "$_c0" "$(md5sum <"$RT/etc/tsem/tsem.conf")"
	_bp=$(sed -n 's/^B|etc\/gl-switch.d\/tailscale-de.sh|//p' "$RT/etc/tsem/install.manifest")
	[ "$(md5sum <"$_bp")" = "$_h0" ] || fail "the original hook is not kept at $_bp"
	[ "$(cat "$F/guard")" != open ] || fail "guard open"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left"
}
test_golive_failures_restore_the_wired_state_and_never_open_the_guard() {
	for _case in selftest nostart killed; do
		_wired; _s0=$(_rsnap)
		case $_case in
		selftest) : >"$F/selftest_fail" ;;
		nostart) : >"$F/nostart" ;;
		killed) export TSEM_INSTALL_KILL_AFTER=1 ;;
		esac
		_arm_fake
		sh "$ACT" go-live --confirm-golive "$BKD" "$SD" >"$T/gl.out" 2>&1 </dev/null; _GRC=$?; kill "$FAKE_WD" 2>/dev/null
		unset TSEM_INSTALL_KILL_AFTER; pkill -9 -f "$FB/tsem daemon" 2>/dev/null
		_G=$(cat "$T/gl.out")
		assert_eq "rc-$_case" 1 "$_GRC"
		assert_contains "res-$_case" "GOLIVE_RESULT=restored" "$_G"
		assert_eq "state-$_case" "$_s0" "$(_rsnap)"
		[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left ($_case)"
		[ "$(cat "$F/guard")" != open ] || fail "guard open after failed go-live ($_case)"
		case $(_calls) in *"set direct"*) fail "direct set ($_case)" ;; esac
		cmp -s "$ROOT/contrib/tsem-switch.sh" "$RT/etc/gl-switch.d/tailscale-de.sh" && fail "the new hook stayed ($_case)"
		:
	done
}
test_golive_refuses_without_watchdog_wiring_or_with_a_running_daemon() {
	_ac_real_rc2; _fake_initd; _prep
	_o=$(sh "$ACT" go-live --confirm-golive "$BKD" "$SD" 2>&1 </dev/null); assert_contains unarmed "not armed" "$_o"
	_arm_fake; _o=$(sh "$ACT" go-live --confirm-golive "$BKD" "$SD" 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains notwired "not wired yet" "$_o"
	_o=$(sh "$ACT" go-live "$BKD" "$SD" 2>&1 </dev/null); assert_contains flag "--confirm-golive" "$_o"
	_wire
	sh "$FB/tsem" daemon </dev/null >/dev/null 2>&1 &
	_d=$!; sleep 1
	_arm_fake; _o=$(sh "$ACT" go-live --confirm-golive "$BKD" "$SD" 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	pkill -9 -f "$FB/tsem daemon"; wait "$_d" 2>/dev/null
	assert_contains daemon "daemon is already running" "$_o"
}

# ---------------- final mode, persistence ----------------
test_final_state_needs_german_with_an_active_exit_node() {
	_ac_setup; _arm_fake; : >"$F/set_active"; echo direct >"$F/mode"; echo open >"$F/guard"
	_o=$(sh "$ACT" final-state 2>&1 </dev/null); _rc=$?; kill "$FAKE_WD" 2>/dev/null
	# no daemon in this fixture: that alone is a FAIL, the mode itself is fine
	assert_contains mode "PASS  final.mode" "$_o"; assert_contains nodaemon "FAIL  final.daemon" "$_o"; assert_eq rc 1 "$_rc"
	_ac_setup; _arm_fake; rm -f "$F/set_active"
	_o=$(sh "$ACT" final-state 2>&1 </dev/null); kill "$FAKE_WD" 2>/dev/null
	assert_contains blocked "FAIL  final.mode" "$_o"
	case $_o in *"PASS  final.mode"*) fail "reported german without an active exit node" ;; esac
	[ "$(cat "$F/guard")" != open ] || fail "guard open"
	_ac_setup; _o=$(sh "$ACT" final-state 2>&1 </dev/null); assert_eq unarmed 2 "$?"
}
test_persist_check_reads_the_boot_state_without_changing_anything() {
	_wired; _golive; pkill -9 -f "$FB/tsem daemon" 2>/dev/null
	_s=$(_rsnap)
	_o=$(sh "$ACT" persist-check "$SD" 2>&1 </dev/null); _rc=$?
	assert_eq rc 0 "$_rc"
	for _k in persist.version persist.intent persist.init persist.bootlink persist.order persist.fwinclude persist.hotplug persist.hook; do assert_contains "$_k" "PASS  $_k" "$_o"; done
	assert_contains noreboot "no reboot was forced" "$_o"
	assert_eq read-only "$_s" "$(_rsnap)"
	rm -f "$RT/etc/rc.d/S18tsem"
	_o=$(sh "$ACT" persist-check "$SD" 2>&1 </dev/null); assert_eq rc1 1 "$?"; assert_contains nolink "FAIL  persist.bootlink" "$_o"
}

# ---------------- the single-command Mac flow ----------------
_final_setup() { _ac_real_rc2; _path_tools; printf 'v=1\nmode=german\n' >"$RT/etc/tsem/intent"; : >"$F/set_active"; _fake_initd; _wd_env; printf 'BACKUP\nSTAGE-RC3\n' | _mac prepare >/dev/null 2>&1 || fail "prepare failed"; rm -f "$F/calls" "$F/ssh.log"; }
test_mac_final_runs_the_whole_acceptance_with_four_confirmations() {
	_final_setup; _s0=$(_rsnap)
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\n' | _mac final); _rc=$?
	_wd_cleanup
	assert_eq rc 4 "$_rc"; assert_contains incomplete "ACCEPTANCE INCOMPLETE" "$_o"
	for _k in prepared.payload probe.monitor recovery.arm verify.version t00_activate.watchdog t08_tsrestart.watchdog golive.hook golive.daemon final.mode persist.bootlink; do case $_o in *"$_k"*) ;; *) fail "missing $_k in the final report" ;; esac; done
	assert_contains result "RC3 is wired and in operation" "$_o"
	assert_contains notproven "Not proven by this run" "$_o"
	assert_contains table "ACCEPTANCE CRITERIA" "$_o"
	assert_contains unverified "UNVERIFIED   Hardware switch GERMAN -> DIRECT" "$_o"
	assert_contains skipped "WARN  switch.skipped" "$_o"
	assert_contains extnet "PASS  extnet.10.30.0.0/24.lan" "$_o"
	case $_o in *"### STOP"*) fail "stopped: $_o" ;; esac
	cmp -s "$ROOT/contrib/tsem-switch.sh" "$RT/etc/gl-switch.d/tailscale-de.sh" || fail "hook not integrated"
	assert_eq mode german "$(cat "$F/mode")"
	[ "$(cat "$F/guard")" = german ] || fail "guard is $(cat "$F/guard")"
	[ ! -e "$AR/recovery/armed" ] || fail "watchdog still armed"
	[ "$(_calls | grep -c "set direct")" -eq 1 ] || fail "direct must be set exactly once (the PROVE-DIRECT proof), got $(_calls | grep -c "set direct")"
	# prepare steps are not repeated: no second backup or stage was made
	assert_eq one-backup 1 "$(ls -d "$T"/bk/tsem-rc3-backup-* | wc -l | tr -d ' ')"
	assert_eq one-stage 1 "$(ls -d "$T"/bk/tsem-rc3-stage-* | wc -l | tr -d ' ')"
	case $(cat "$F/ssh.log") in *" backup"* | *stage-rc3*) fail "the final run repeated a prepare step" ;; esac
}
test_mac_accept_is_one_command_for_prepare_and_final() {
	_ac_real_rc2; printf 'v=1\nmode=german\n' >"$RT/etc/tsem/intent"; : >"$F/set_active"; _fake_initd; _wd_env
	_o=$(printf 'BACKUP\nSTAGE-RC3\nSWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\n' | _mac accept); _rc=$?
	_wd_cleanup
	assert_eq rc 4 "$_rc"; assert_contains incomplete "ACCEPTANCE INCOMPLETE" "$_o"
	assert_contains prep "Prepared (RC3 is only staged" "$_o"
	assert_contains result "RC3 is wired and in operation" "$_o"
	assert_contains table "ACCEPTANCE CRITERIA" "$_o"
	assert_eq one-backup 1 "$(ls -d "$T"/bk/tsem-rc3-backup-* | wc -l | tr -d ' ')"
	case $_o in *"### STOP"*) fail "stopped: $_o" ;; esac
	# a missing precondition (no BACKUP phrase) stops before anything active
	_ac_real_rc2; _fake_initd; _wd_env
	_o=$(printf 'no\n' | _mac accept); assert_eq refused 2 "$?"
	[ ! -e "$AR/recovery/armed" ] || fail "armed although the first precondition was refused"
}
test_mac_diag_saves_a_secret_free_bundle_without_changing_anything() {
	_ac_setup; _s0=$(_rsnap)
	_o=$(_mac diag); _rc=$?
	assert_eq rc 0 "$_rc"
	_b=$(ls "$T"/out/diag-bundle-*-manual.txt 2>/dev/null | head -n 1)
	[ -s "$_b" ] || fail "no bundle saved on the Mac side: $_o"
	assert_contains end "END OF BUNDLE" "$(cat "$_b")"
	assert_eq unchanged "$_s0" "$(_rsnap)"
}
test_mac_abort_saves_the_bundle_before_the_recovery_runs() {
	_final_setup; : >"$F/leak"
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\n' | _mac final); _wd_cleanup
	assert_contains stop "### STOP" "$_o"
	_b=$(ls "$T"/out/diag-bundle-*-before-recovery.txt 2>/dev/null | head -n 1)
	[ -s "$_b" ] || fail "no bundle saved before the recovery"
	_ib=$(printf '%s\n' "$_o" | grep -n "diag.saved" | head -n 1 | cut -d: -f1); _ir=$(printf '%s\n' "$_o" | grep -n "RECOVERY_RESULT" | head -n 1 | cut -d: -f1)
	[ -n "$_ib" ] && [ -n "$_ir" ] && [ "$_ib" -lt "$_ir" ] || fail "the bundle must be saved before the recovery starts ($_ib / $_ir)"
}
test_mac_final_changes_nothing_without_the_typed_phrases() {
	_final_setup; _s0=$(_rsnap)
	_o=$(printf 'SWITCH-MAYBE\n' | _mac final); assert_eq sw 2 "$?"; assert_eq unchanged "$_s0" "$(_rsnap)"
	_o=$(printf 'SWITCH-ON\nno\n' | _mac final); assert_eq wire 2 "$?"; assert_eq unchanged2 "$_s0" "$(_rsnap)"
	[ ! -e "$AR/recovery/armed" ] || fail "armed without the phrase"
	_o=$(_mac final </dev/null); assert_eq eof 2 "$?"
}
test_mac_final_stops_at_the_first_failing_test_and_recovers_without_opening() {
	_final_setup; : >"$F/leak"
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\n' | _mac final); _rc=$?
	_wd_cleanup
	assert_eq rc 1 "$_rc"
	assert_contains stop "### STOP" "$_o"; assert_contains rec "RECOVERY" "$_o"
	case $_o in *"### Step 5"*) fail "went on to the integration after a failed test" ;; esac
	cmp -s "$ROOT/contrib/tsem-switch.sh" "$RT/etc/gl-switch.d/tailscale-de.sh" && fail "hook integrated after a failed test"
	[ ! -e "$AR/recovery/armed" ] || fail "watchdog left armed"
	[ "$(_calls | grep -c "set direct")" -eq 1 ] || fail "only the PROVE-DIRECT proof may set direct (recovery never does)"; case $(_calls) in *teardown*) fail "recovery tore the guard down" ;; esac
}
test_mac_final_refuses_without_a_verified_backup_copy_or_with_a_changed_payload() {
	_ac_real_rc2; _fake_initd; _wd_env
	_o=$(printf 'SWITCH-ON\n' | _mac --backup-dir /etc --stage-dir /etc final 2>&1); assert_eq unsafe 1 "$?"
	assert_contains inputs "FAIL  final.inputs" "$_o"
	printf 'BACKUP\nSTAGE-RC3\n' | _mac prepare >/dev/null 2>&1
	rm -f "$T"/out/backup-*.tar
	_o=$(printf 'SWITCH-ON\n' | _mac final 2>&1); assert_eq nocopy 1 "$?"
	assert_contains copy "final.backup.copy" "$_o"
}

test_the_background_sampler_never_holds_the_callers_pipe_open() {
	# found by the final acceptance fixture: a sampler that outlives t07/t08 keeps an ssh session or `| tee` open forever
	_ac_setup; _arm_fake
	( TSEM_NOW=1790000000 timeout 60 sh "$ACT" test t07_fwreload 2>&1 </dev/null | cat >"$T/pipe.out" ); _rc=$?
	kill "$FAKE_WD" 2>/dev/null
	assert_eq finished 0 "$_rc"
	assert_contains "done" "SUMMARY" "$(cat "$T/pipe.out")"
	_body=$(_fn_body "$ACT" sampler_start); assert_contains detached ">/dev/null 2>&1" "$_body"
	case $(_fn_body "$ACT" sampler_stop) in *'wait "$SAMPLER"'*) fail "sampler_stop uses wait inside a command substitution" ;; esac
}

# --- RC3.1 diagnostics: read-only evidence that survives the failure (simulated: fake commands only) ---

test_diag_bundle_is_read_only_and_removes_secrets() {
	_ac_setup
	cat >"$FB/tailscale" <<'EOS'
#!/bin/sh
echo "tailscale $*" >>"$FAKE_F/ts.calls"
case $1 in
status) echo "100.89.254.34 gl-mt3000 tskey-auth-SECRET123 linux"; echo '"PrivateKey": "privkey:abcdef"'; echo "100.64.0.31 exit-b linux active; exit node; direct" ;;
debug) echo '"RouteAll": true'; echo '"ExitNodeID": "nXYZ"' ;;
ping) echo "pong from exit-b (100.64.0.31) via 185.146.50.48:20513 in 217ms" ;;
esac
exit 0
EOS
	chmod +x "$FB/tailscale"
	_o=$(sh "$ACT" diag-bundle 2>&1); _r=$?
	assert_eq rc 0 "$_r"
	assert_contains head "TSEM DIAGNOSTIC BUNDLE" "$_o"
	assert_contains tsem "primary_ok" "$(printf '%s' "$_o"; echo primary_ok)"
	assert_contains tail "END OF BUNDLE" "$_o"
	assert_contains routing "ip -4 rule" "$_o"
	assert_contains switch "hardware switch evidence" "$_o"
	case $_o in *SECRET123*) fail "an auth key leaked into the bundle" ;; esac
	case $_o in *privkey*) fail "a private key leaked into the bundle" ;; esac
	assert_contains redacted "tskey-REDACTED" "$_o"
	# nothing mutating was called: no tsem set/tick/reapply, only reading tailscale verbs
	! grep -E '^(set|tick|reapply|failover|boot|teardown)' "$F/calls" | grep -q . || fail "the bundle called a mutating tsem command"
	! grep -vE '^tailscale (status|debug prefs|ping )' "$F/ts.calls" | grep -q . || fail "the bundle called a mutating tailscale command"
}

test_diag_bundle_source_has_no_mutating_command() {
	_b=$(_fn_body "$ACT" cmd_diag_bundle; _fn_body "$ACT" bundle_run; _fn_body "$ACT" bundle_grep; _fn_body "$ACT" bundle_fetch)
	[ -n "$_b" ] || fail "bundle code not found"
	! printf '%s\n' "$_b" | grep -E 'tsem.* (set|tick|reapply|failover)|tailscale (set|up|down|logout)|iptables.* -[ADIFXP] |ip rule (add|del)|ip route (add|del|replace)|rm -|reboot|uci (set|commit)|fw3|/etc/init.d/[a-z]+ (start|stop|restart|reload)' | grep -q . || fail "the diagnostic bundle must only read"
}

test_nodes_check_reports_identity_and_path_without_any_change() {
	_ac_setup
	printf 'PASS primary: exit-a 100.64.0.30: ok\nPASS secondary: exit-b 100.64.0.31: ok\n' >"$F/verify_out"
	cat >"$FB/tailscale" <<'EOS'
#!/bin/sh
echo "tailscale $*" >>"$FAKE_F/ts.calls"
[ "$1" = ping ] || exit 0
case $5 in
*100.64.0.30*) echo "pong from exit-a (100.64.0.30) via DERP(nue) in 224ms" ;;
*) echo "pong from exit-b (100.64.0.31) via 185.146.50.48:20513 in 217ms" ;;
esac
EOS
	chmod +x "$FB/tailscale"
	_o=$(sh "$ACT" nodes-check 2>&1); _r=$?
	assert_eq rc 0 "$_r"
	assert_contains id "PASS  nodes.identity" "$_o"
	assert_contains derp "relay nue" "$_o"
	assert_contains direct "path direct" "$_o"
	assert_contains honest "reachability only, not egress" "$_o"
	! grep -E '^(set|tick|reapply|failover)' "$F/calls" | grep -q . || fail "nodes-check must not change anything"
}

test_nodes_check_fails_on_identity_or_silent_peer() {
	_ac_setup
	printf 'FAIL primary: exit-a 100.64.0.30: node is offline\nPASS secondary: exit-b 100.64.0.31: ok\n' >"$F/verify_out"; echo 1 >"$F/verify_rc"
	printf '#!/bin/sh\n[ "$1" = ping ] && echo "ping timed out"\nexit 1\n' >"$FB/tailscale"; chmod +x "$FB/tailscale"
	_o=$(sh "$ACT" nodes-check 2>&1); _r=$?
	assert_eq rc 1 "$_r"
	assert_contains id "FAIL  nodes.identity" "$_o"
	assert_contains ping "FAIL  nodes.primary.ping" "$_o"
}

# helper: a "physical switch" that fires a hook-like event after a delay (simulated; the real firmware call is UNVERIFIED)
_fake_hw_event() { # mode source delay
	( sleep "$3"; case $1 in direct) echo direct >"$F/mode"; echo DIRECT >"$F/state"; echo open >"$F/guard"; echo none >"$F/exit" ;; german) echo german >"$F/mode"; echo PRIMARY_ACTIVE >"$F/state"; echo german >"$F/guard"; echo 100.64.0.30 >"$F/exit" ;; esac
	  echo "$2" >"$F/source"; echo $(( $(cat "$F/seq" 2>/dev/null || echo 1) + 1 )) >"$F/seq" ) >/dev/null 2>&1 &
}

test_switch_watch_accepts_a_hw_event_to_direct_and_checks_the_wan() {
	_ac_setup; echo 1 >"$F/seq"; export AR_SLEEP=sleep AR_FAKE_CLOCK=0
	_fake_hw_event direct hw 1
	_o=$(AR_SWITCH_MAX=20 sh "$ACT" switch-watch off 2>&1); _r=$?
	assert_eq rc 0 "$_r"
	assert_contains src "PASS  switch.source" "$_o"
	assert_contains mode "PASS  switch.mode" "$_o"
	assert_contains direct "PASS  switch.direct " "$_o"
	assert_contains egress "PASS  switch.direct.egress" "$_o"
	! grep -E '^(set|tick|reapply)' "$F/calls" | grep -q . || fail "switch-watch must only read"
}

test_switch_watch_accepts_a_hw_event_to_german_and_requires_a_closed_guard() {
	_ac_setup; export AR_SLEEP=sleep AR_FAKE_CLOCK=0; echo 1 >"$F/seq"; echo direct >"$F/mode"; echo DIRECT >"$F/state"; echo open >"$F/guard"
	_fake_hw_event german hw 1
	_o=$(AR_SWITCH_MAX=20 AR_SWITCH_ACTIVE_MAX=6 sh "$ACT" switch-watch on 2>&1); _r=$?
	assert_eq rc 0 "$_r"
	assert_contains guard "PASS  switch.guard" "$_o"
	assert_contains active "PASS  switch.active" "$_o"
}

test_switch_watch_fails_when_the_event_never_arrives_or_has_the_wrong_source() {
	_ac_setup; export AR_SLEEP=sleep AR_FAKE_CLOCK=0; echo 1 >"$F/seq"
	_o=$(AR_SWITCH_MAX=4 sh "$ACT" switch-watch off 2>&1); _r=$?
	assert_eq rc 1 "$_r"
	assert_contains none "FAIL  switch.event" "$_o"
	_ac_setup; echo 1 >"$F/seq"; export AR_SLEEP=sleep AR_FAKE_CLOCK=0
	_fake_hw_event direct ha 1
	_o=$(AR_SWITCH_MAX=20 sh "$ACT" switch-watch off 2>&1); _r=$?
	assert_eq rc 1 "$_r"
	assert_contains src "FAIL  switch.source" "$_o"
}

test_extnet_check_requires_tailscale_routes_for_router_and_lan_client() {
	_ac_setup
	cat >"$FB/ip" <<'EOS'
#!/bin/sh
case "$*" in
"addr show br-lan"*|"-4 addr show br-lan"*) echo "    inet 10.20.0.1/24 brd 10.20.0.255 scope global br-lan" ;;
"route get 10.30."*) echo "10.30.0.1 dev tailscale0 table 52 src 100.64.0.1" ;;
esac
EOS
	chmod +x "$FB/ip"
	_o=$(sh "$ACT" extnet-check 2>&1); _r=$?
	assert_eq rc 0 "$_r"
	assert_contains lan "PASS  extnet.10.30.2.0/24.lan" "$_o"
	assert_contains unv "UNVERIFIED" "$_o"
	printf '#!/bin/sh\ncase "$*" in "route get 10.30."*) echo "prohibit 10.30.1.1 dev br-lan" ;; esac\n' >"$FB/ip"
	_o=$(sh "$ACT" extnet-check 2>&1); _r=$?
	assert_eq rc 1 "$_r"
	assert_contains bad "FAIL  extnet.10.30.0.0/24.router" "$_o"
}

test_t01_samples_egress_repeatedly_and_flags_an_intermittent_path() {
	_ac_setup
	cat >"$FB/curl" <<'EOS'
#!/bin/sh
n=$(cat "$FAKE_F/cn" 2>/dev/null || echo 0); n=$((n + 1)); echo $n >"$FAKE_F/cn"
[ $((n % 2)) -eq 0 ] && exit 28
echo "ip=203.0.113.9"
EOS
	chmod +x "$FB/curl"
	export AR_T01_SAMPLES=5 AR_T01_GAP=0 AR_SLEEP=true
	_o=$(_run_t t01_primary)
	assert_contains series "t01.series" "$_o"
	assert_contains warn "WARN  t01.egress" "$_o"
	assert_contains intermittent "INTERMITTENT" "$_o"
}

test_t01_in_acceptance_mode_fails_when_the_primary_is_not_the_active_node() {
	_ac_setup; echo SECONDARY_ACTIVE >"$F/state"; echo 100.64.0.31 >"$F/exit"
	export AR_T01_SAMPLES=1 AR_SLEEP=true AR_STRICT_PRIMARY=1
	_o=$(_run_t t01_primary)
	assert_contains strict "FAIL  t01.primary" "$_o"
	unset AR_STRICT_PRIMARY
	_o=$(_run_t t01_primary)
	assert_contains lenient "WARN  t01.primary" "$_o"
}

test_mac_acceptance_table_counts_only_evidence() {
	_m=$(_fn_body "$ROOT/tools/run-rc3-active-mac.sh" crit; _fn_body "$ROOT/tools/run-rc3-active-mac.sh" acceptance_table)
	[ -n "$_m" ] || fail "table code not found"
	_rep=$(mktemp); say() { printf '%s\n' "$*"; }
	printf 'PASS  t01.egress  ok\nPASS  t01.primary  ok\nFAIL  t03.blocked  x\n' >"$_rep"
	REPORT=$_rep
	eval "$_m"
	_o=$(acceptance_table)
	rm -f "$_rep"
	assert_contains pass "PASS         Primary exit node verified" "$_o"
	assert_contains fail "FAIL         Both nodes unavailable" "$_o"
	assert_contains unv "UNVERIFIED   Hardware switch GERMAN -> DIRECT" "$_o"
}

# ---------------------------------------------------------------- DIRECT return path / API check (router side)
_path_tools() { # presence stubs for the tools the DIRECT switch-over needs
	for _x in iptables ip6tables ip flock; do [ -x "$FB/$_x" ] || { printf '#!/bin/sh\nexit 0\n' >"$FB/$_x"; chmod +x "$FB/$_x"; }; done
}

test_direct_path_check_proves_the_way_back_with_the_staged_code_before_anything_active() {
	_ac_setup; _path_tools
	_o=$(sh "$ACT" direct-path-check 2>&1); _r=$?
	for _k in direct.path.live direct.path.staged direct.path.intent direct.path.tools direct.path.sim.german direct.path.sim.direct direct.path.sim.noauto direct.path.hook direct.path.recovery direct.path.proven; do
		assert_contains "$_k" "PASS  $_k" "$_o"
	done
	assert_eq rc 0 "$_r"
	# read-only: no call of the live controller other than intent-check, and never 'set'
	case $(_calls) in *"set "*) fail "the check called 'tsem set' on the live controller: $(_calls)" ;; esac
	case $(_calls) in *tick* | *reapply*) fail "the check changed live state: $(_calls)" ;; esac
	assert_eq mode german "$(cat "$F/mode")"
}

test_direct_path_check_fails_closed_when_a_prerequisite_is_missing() {
	_ac_setup; _path_tools
	: >"$FB/ip.gone"
	_o=$(AR_MISSING="flock" sh "$ACT" direct-path-check 2>&1); _r=$?
	assert_contains tools "FAIL  direct.path.tools" "$_o"
	assert_contains notproven "FAIL  direct.path.proven" "$_o"
	assert_eq rc 1 "$_r"
}

test_direct_path_check_detects_a_staged_controller_without_a_working_direct_mode() {
	_ac_setup; _path_tools
	# a stage whose controller cannot reach direct: the simulation must say so
	_st=$T/badrepo
	mkdir -p "$_st/tools" "$_st/src" "$_st/contrib"
	cp -r "$ROOT/src/." "$_st/src/"; cp "$ROOT/contrib/tsem-switch.sh" "$_st/contrib/"; cp "$ROOT/tools/tsem-rc3-recover.sh" "$_st/tools/"; cp "$ACT" "$_st/tools/tsem-rc3-active.sh"
	sed -i 's/direct) CONVERGE_CLEAR_ALL=1; converge open/direct) CONVERGE_CLEAR_ALL=1; converge blocked/' "$_st/src/usr/sbin/tsem"
	_o=$(sh "$_st/tools/tsem-rc3-active.sh" direct-path-check 2>&1); _r=$?
	assert_contains sim "FAIL  direct.path.sim.direct" "$_o"
	assert_contains notproven "FAIL  direct.path.proven" "$_o"
	assert_eq rc 1 "$_r"
}

test_api_check_maps_the_router_side_result_and_never_calls_a_missing_check_a_pass() {
	_ac_setup
	_o=$(sh "$ACT" api-check 2>&1); _r=$?
	assert_contains missing "FAIL  api.installed" "$_o"
	assert_eq rc 1 "$_r"
	# installed: the lines of tsem-api-check become PASS/FAIL/UNVERIFIED lines
	mkdir -p "$RT/usr/sbin"
	printf '#!/bin/sh\necho "PASS plugin: ok"\necho "WARN http-endpoint: nothing found"\necho "UNVERIFIED wan-exposure: no chain"\necho API_CHECK=ok\n' >"$RT/usr/sbin/tsem-api-check"; chmod +x "$RT/usr/sbin/tsem-api-check"
	_o=$(sh "$ACT" api-check 2>&1); _r=$?
	assert_contains pass "PASS  api.plugin" "$_o"
	assert_contains warn "WARN  api.http-endpoint" "$_o"
	assert_contains unv "UNVERIFIED: no chain" "$_o"
	assert_eq rc 0 "$_r"
	printf '#!/bin/sh\necho "FAIL unauth-read: status readable WITHOUT a session"\necho API_CHECK=fail\nexit 1\n' >"$RT/usr/sbin/tsem-api-check"
	_o=$(sh "$ACT" api-check 2>&1); _r=$?
	assert_contains fail "FAIL  api.unauth-read" "$_o"
	assert_eq rc 1 "$_r"
}

test_mac_final_stops_before_anything_active_when_the_direct_return_path_is_not_proven() {
	_final_setup; _s0=$(_rsnap)
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\n' | AR_MISSING="flock" _mac final); _rc=$?
	_wd_cleanup
	assert_eq rc 1 "$_rc"
	assert_contains step "### Step 1b: DIRECT return path" "$_o"
	assert_contains fail "FAIL  direct.path.proven" "$_o"
	assert_contains msg "no active step will run" "$_o"
	case $_o in *"### Step 2"* | *"WIRE-RC3  to continue"*) fail "an active step was offered although the way back is not proven" ;; esac
	[ ! -e "$AR/recovery/armed" ] || fail "the watchdog was armed"
	case $(_calls) in *tick* | *"set "*) fail "the controller was driven: $(_calls)" ;; esac
	assert_eq "router unchanged" "$_s0" "$(_rsnap)"
}

test_mac_final_runs_api_and_ha_steps_and_lists_them_in_the_matrix() {
	_final_setup
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\n' | _mac final); _rc=$?
	_wd_cleanup
	assert_eq rc 4 "$_rc"; assert_contains incomplete "ACCEPTANCE INCOMPLETE" "$_o"
	assert_contains s8 "### Step 8: local API and GUI" "$_o"
	assert_contains s9 "### Step 9: Home Assistant" "$_o"
	assert_contains router "api.plugin" "$_o"
	assert_contains path "PASS         DIRECT return path proven before any active step" "$_o"
	# nothing about this computer's view was available in the fake setup: honest UNVERIFIED, never PASS
	assert_contains api "UNVERIFIED   Local API: authenticated read and write work" "$_o"
	assert_contains ha "UNVERIFIED   Home Assistant integration matches the router" "$_o"
	assert_contains gui "UNVERIFIED   GUI served and usable" "$_o"
}

# ---------------- native GL.iNet GUI step (router side) ----------------
_native_fw() { # a GL.iNet 4.x UI layout in the fake router
	mkdir -p "$RT/usr/share/oui/menu.d" "$RT/usr/lib/oui-httpd/rpc" "$RT/www/views"
	printf '{\n\t"index": 31,\n\t"view": "tailscale",\n\t"title": "Tailscale",\n\t"level": 2,\n\t"parent": "applications"\n}\n' >"$RT/usr/share/oui/menu.d/tailscale.json"
	printf 'stock\n' >"$RT/www/views/gl-sdk4-ui-tailscale.common.js.gz"
	printf 'return {}\n' >"$RT/usr/lib/oui-httpd/rpc/tailscale"
}
_native() { TSEM_INSTALL_STAMP=${NSTAMP:-20260101-000003} sh "$ACT" native-install --confirm-native "$BKD" "$SD" >"$T/nat.out" 2>&1 </dev/null; _NRC=$?; _N=$(cat "$T/nat.out"); }

test_native_install_step_adds_files_only_and_verifies() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 missing (jsonfilter stand-in)"
	_wired; _native_fw; PATH=$PATH:$ROOT/tests/stubs; export PATH
	_f0=$(cd "$RT/usr/share/oui/menu.d" && md5sum tailscale.json); _c0=$(md5sum <"$RT/etc/tsem/tsem.conf"); _i0=$(md5sum <"$RT/etc/tsem/intent")
	_o=$(sh "$ACT" native-install "$BKD" "$SD" 2>&1 </dev/null); assert_contains need "needs --confirm-native" "$_o"
	[ ! -e "$RT/usr/share/oui/menu.d/tsem.json" ] || fail "installed without the confirmation"
	_native
	assert_eq rc 0 "$_NRC"
	assert_contains res "NATIVE_RESULT=ok" "$_N"
	for _k in native.install.rc native.file.tsem_json native.gz native.menu.view native.menu.parent native.foreign; do assert_contains "$_k" "PASS  $_k" "$_N"; done
	assert_contains lua "native.rpc.syntax" "$_N"
	assert_eq firmware "$_f0" "$(cd "$RT/usr/share/oui/menu.d" && md5sum tailscale.json)"
	assert_eq conf "$_c0" "$(md5sum <"$RT/etc/tsem/tsem.conf")"
	assert_eq intent "$_i0" "$(md5sum <"$RT/etc/tsem/intent")"
	_c=$(sh "$ACT" native-check 2>&1 </dev/null); assert_contains check "PASS  native.gz" "$_c"
}

test_native_install_step_refuses_on_unexpected_firmware_and_changes_nothing() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 missing (jsonfilter stand-in)"
	_wired; PATH=$PATH:$ROOT/tests/stubs; export PATH   # no GL.iNet UI layout at all
	_s=$(_rsnap)
	_native
	assert_contains res "NATIVE_RESULT=restored" "$_N"
	assert_contains why "native.install.rc" "$_N"
	assert_eq "nothing changed" "$_s" "$(_rsnap)"
}

test_native_install_step_failure_midway_is_rolled_back_completely() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 missing (jsonfilter stand-in)"
	_wired; _native_fw; PATH=$PATH:$ROOT/tests/stubs; export PATH
	_s=$(_rsnap)
	TSEM_INSTALL_FAIL_AFTER=2 _native
	assert_contains res "NATIVE_RESULT=restored" "$_N"
	assert_eq "state restored" "$_s" "$(_rsnap)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left"
}

test_mac_final_installs_the_native_gui_only_with_its_own_confirmation_and_never_claims_what_it_cannot_see() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 missing (jsonfilter stand-in)"
	_final_setup; _native_fw; PATH=$PATH:$ROOT/tests/stubs; export PATH
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\nNATIVE-GUI\n' | _mac --native-gui final); _rc=$?
	_wd_cleanup
	assert_eq rc 4 "$_rc"; assert_contains incomplete "ACCEPTANCE INCOMPLETE" "$_o"
	assert_contains step "### Step 8b: native GL.iNet GUI" "$_o"
	assert_contains res "NATIVE_RESULT=ok" "$_o"
	[ -f "$RT/usr/share/oui/menu.d/tsem.json" ] || fail "menu entry missing"
	# no browser/curl evidence in this fake setup: the criteria stay UNVERIFIED, never PASS
	assert_contains served "UNVERIFIED   Native GL.iNet GUI: served, unauthenticated DIRECT refused" "$_o"
	assert_contains attested "UNVERIFIED   Native GL.iNet GUI seen in the browser (user-attested)" "$_o"
	assert_eq mode german "$(cat "$F/mode")"
}

test_mac_final_without_the_native_phrase_installs_nothing_native() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 missing (jsonfilter stand-in)"
	_final_setup; _native_fw; PATH=$PATH:$ROOT/tests/stubs; export PATH
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\nno\n' | _mac --native-gui final); _rc=$?
	_wd_cleanup
	assert_eq rc 4 "$_rc"; assert_contains incomplete "ACCEPTANCE INCOMPLETE" "$_o"
	assert_contains skipped "native GUI NOT installed (UNVERIFIED)" "$_o"
	[ ! -e "$RT/usr/share/oui/menu.d/tsem.json" ] || fail "native menu entry installed without the phrase"
	assert_contains row "UNVERIFIED   Native GL.iNet GUI seen in the browser (user-attested)" "$_o"
}

test_mac_final_with_no_native_gui_never_mentions_a_native_step() {
	_final_setup
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\n' | _mac --no-native-gui final)
	_wd_cleanup
	case $_o in *"Step 8b"* | *native-install*) fail "native step although --no-native-gui was given" ;; esac
}

test_mac_accept_flow_has_a_separate_masq_step_with_its_own_phrase_before_wiring() {
	_a=$(grep -n 'Masquerading check (read-only' "$ROOT/tools/run-rc3-active-mac.sh" | head -n 1 | cut -d: -f1)
	_w=$(grep -n 'confirm WIRE-RC3' "$ROOT/tools/run-rc3-active-mac.sh" | head -n 1 | cut -d: -f1)
	[ -n "$_a" ] && [ -n "$_w" ] && [ "$_a" -lt "$_w" ] || fail "masq step missing or after WIRE-RC3"
	grep -q 'confirm FIX-MASQ' "$ROOT/tools/run-rc3-active-mac.sh" || fail "no separate FIX-MASQ confirmation"
	grep -q 'ensure --no-reload' "$ROOT/tools/run-rc3-active-mac.sh" || fail "repair may reload the firewall"
	grep -q 'masq.step' "$ROOT/tools/run-rc3-active-mac.sh"
}

test_mac_accept_flow_proves_the_live_direct_path_before_the_first_german_test() {
	_f=$ROOT/tools/run-rc3-active-mac.sh
	_p=$(grep -n 'confirm PROVE-DIRECT' "$_f" | head -n 1 | cut -d: -f1)
	_w=$(grep -n 'run_logged "wire --confirm-wire' "$_f" | head -n 1 | cut -d: -f1)
	_t=$(grep -n 'confirm RUN-TESTS' "$_f" | head -n 1 | cut -d: -f1)
	[ -n "$_p" ] && [ -n "$_w" ] && [ -n "$_t" ] && [ "$_w" -lt "$_p" ] && [ "$_p" -lt "$_t" ] || fail "PROVE-DIRECT must come after wiring and before RUN-TESTS"
	sed -n "${_p},${_t}p" "$_f" | grep -q 'abort_recover' || fail "a failed DIRECT proof must stop the run"
	grep -q 'direct.egress' "$ROOT/tools/tsem-rc3-active.sh" || fail "return-to-direct does not require WAN egress"
	# the default install used by wire/go-live carries no masq component
	! sed -n '/^cmd_wire/,/^}/p' "$ROOT/tools/tsem-rc3-active.sh" | grep -q 'components[ =]*[a-z,-]*masq' || fail "wire installs masq"
}

test_mac_run_with_unproven_criteria_is_reported_incomplete_never_complete() {
	_final_setup
	_o=$(printf 'SWITCH-ON\nWIRE-RC3\nPROVE-DIRECT\nRUN-TESTS\nINTEGRATE-SWITCH\nSKIP-SWITCH\n' | _mac final); _rc=$?
	assert_eq rc 4 "$_rc"
	assert_contains incomplete "ACCEPTANCE INCOMPLETE" "$_o"
	assert_contains router "ROUTER ACCEPTANCE INCOMPLETE" "$_o"
	assert_contains product "FULL PRODUCT ACCEPTANCE NOT PASSED" "$_o"
	case $_o in *"FULL PRODUCT ACCEPTANCE PASSED"*) fail "full product reported passed without a proven router and HA" ;; esac
	case $_o in *"ACCEPTANCE COMPLETE"*) fail "an unproven run was reported complete" ;; esac
	# the skipped switch test and the missing Home Assistant read are NOT accepted criteria
	assert_contains switch "NOT accepted" "$_o"
	# a Mac that is not a LAN client cannot observe DIRECT: that is NOT TESTED, never PASS
	case $_o in *"PASS  mac.direct"*) fail "mac.direct passed without a LAN-client observation" ;; esac
	assert_contains direct-nt "mac.direct" "$_o"
}

# ---------------------------------------------------------------- F07: watchdog truth, keepalive while waiting, stop on REFUSED
test_f07_recovery_ensure_reports_alive_fired_dead_and_absent() {
	_ac_setup
	# absent
	_o=$(_acts recovery-ensure); assert_rc absent-rc 1 sh "$ACT" recovery-ensure
	assert_contains absent "RECOVERY_STATE=absent" "$_o"
	assert_contains absent-reason "no watchdog state exists" "$_o"
	# fired: the deadline passed (nobody sent keepalives) and the recovery ran; the armed marker is gone
	mkdir -p "$AR/recovery"; : >"$AR/recovery/fired"; echo "1790000000 watchdog: deadline passed without keepalive: running RECOVERY" >"$AR/recovery/recover.log"
	_o=$(_acts recovery-ensure); assert_rc fired-rc 1 sh "$ACT" recovery-ensure
	assert_contains fired "RECOVERY_STATE=fired" "$_o"
	assert_contains fired-reason "FIRED" "$_o"
	assert_contains fired-log "deadline passed without keepalive" "$_o"
	rm -rf "$AR/recovery"
	# dead: an armed marker, but the heartbeat is old
	mkdir -p "$AR/recovery"; : >"$AR/recovery/armed"; echo $(($(date +%s) - 100)) >"$AR/recovery/hb"
	_o=$(_acts recovery-ensure); assert_rc dead-rc 1 sh "$ACT" recovery-ensure
	assert_contains dead "RECOVERY_STATE=dead" "$_o"
	assert_contains dead-reason "dead or hung" "$_o"
	rm -rf "$AR/recovery"
	# alive: marker plus a moving heartbeat; the keepalive moves the deadline out
	_arm_fake
	echo $(($(date +%s) + 5)) >"$AR/recovery/deadline"
	_o=$(_acts recovery-ensure); _rc=$?
	kill "$FAKE_WD" 2>/dev/null
	assert_eq alive-rc 0 "$_rc"
	assert_contains alive "RECOVERY_STATE=armed" "$_o"
	[ "$(cat "$AR/recovery/deadline")" -gt $(($(date +%s) + 100)) ] || fail "recovery-ensure did not push the deadline out"
}

_f07_ssh_shim() { # installs a ssh wrapper: kills the watchdog state at the Nth recovery-ensure, refuses a named test
	cp "$FB/ssh" "$FB/ssh.real"
	cat >"$FB/ssh" <<SEOF
#!/bin/sh
for last; do :; done
case \$last in
*recovery-ensure*)
	n=\$(cat "\$FAKE_F/ens.n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"\$FAKE_F/ens.n"
	if [ "\$n" = "\${F07_KILL_AT:-0}" ]; then rm -f "\$AR_RUN/recovery/armed" "\$AR_RUN/recovery/hb"; fi ;;
*"test t04_dns"*)
	if [ -e "\$FAKE_F/refuse_t04" ]; then echo "REFUSED: simulated refusal" >&2; exit 2; fi ;;
esac
exec "$FB/ssh.real" "\$@"
SEOF
	chmod +x "$FB/ssh"
}

test_f07_mac_rearms_a_watchdog_that_died_while_waiting_for_the_confirmation() {
	_ac_setup
	AR_SLEEP=sleep; export AR_SLEEP
	printf 'BACKUP\nSTAGE-RC3\n' | _mac prepare >/dev/null 2>&1 || fail "prepare failed"
	_f07_ssh_shim
	F07_KILL_AT=2; export F07_KILL_AT
	_o=$(printf 'ARM-RECOVERY\nWIRE-RC3\nSTART t04_dns\nDISARM\n' | _mac test t04_dns)
	unset F07_KILL_AT
	assert_contains noticed "FAIL  recovery.alive" "$_o"
	assert_contains rearm "Re-arming it with the full verification" "$_o"
	assert_contains rearmed "watchdog armed under procd" "$_o"
	assert_contains ran "PASS  t04.resolve" "$_o"
}

test_f07_mac_stops_after_a_refused_test_and_does_not_claim_a_disarm() {
	_ac_setup
	AR_SLEEP=sleep; export AR_SLEEP
	printf 'BACKUP\nSTAGE-RC3\n' | _mac prepare >/dev/null 2>&1 || fail "prepare failed"
	_f07_ssh_shim
	: >"$F/refuse_t04"
	rm -f "$F/ssh.log"
	_o=$(printf 'ARM-RECOVERY\nWIRE-RC3\nSTART t04_dns\nSTART t05_ipv6\nDISARM\n' | _mac test t04_dns t05_ipv6); _rc=$?
	[ "$_rc" -ne 0 ] || fail "the run reported success although a test was refused"
	assert_contains refused "was REFUSED by the router script" "$_o"
	assert_contains stops "the run STOPS here" "$_o"
	case $(cat "$F/ssh.log") in *"test t05_ipv6"*) fail "a later test ran after a refusal" ;; esac
	case $_o in *"### t05_ipv6"*) fail "the next test header was printed" ;; esac
}

test_f07_mac_runner_has_keepalive_while_waiting_and_no_blind_disarm() {
	t_setup
	_b=$(_fn_body "$MAC" confirm_ka)
	assert_contains ka-loop "recovery-keepalive" "$_b"
	assert_contains ka-kill "kill" "$_b"
	_code "$MAC" | grep -q 'confirm_ka "START' || fail "the START confirmation is not protected by the keepalive loop"
	_code "$MAC" | grep -q 'wd_ensure ||' || fail "the watchdog is not checked before a test"
}
