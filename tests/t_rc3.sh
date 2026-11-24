# shellcheck shell=sh
# RC3 regression tests: intent diagnosis, deny-action fallback, fast path, boot failure visibility.

_mkintent() { # mode failover seq ts source [badcrc]
	_b="v=1
mode=$1
failover=$2
seq=$3
ts=$4
source=$5"
	_c=$(printf '%s\n' "$_b" | md5sum | cut -c1-32)
	[ -z "$6" ] || _c=00000000000000000000000000000000
	printf '%s\ncrc=%s\n' "$_b" "$_c" >"$TSEM_STATE_DIR/intent"
}

test_intent_check_reports_reason_for_each_failure() {
	t_setup
	rm -f "$TSEM_STATE_DIR/intent"
	_o=$(tsem intent-check); _rc=$?
	assert_eq missing-rc 1 "$_rc"; assert_contains missing 'reason=missing' "$_o"
	printf 'v=1\nmode=german\n' >"$TSEM_STATE_DIR/intent"
	_o=$(tsem intent-check); _rc=$?
	assert_eq nocrc-rc 2 "$_rc"; assert_contains nocrc 'reason=no-crc' "$_o"
	_mkintent german auto 1 1 x bad
	_o=$(tsem intent-check); assert_contains crc 'reason=crc-mismatch' "$_o"
	_mkintent weird auto 1 1 x
	_o=$(tsem intent-check); assert_contains mode 'reason=mode' "$_o"
	_mkintent german maybe 1 1 x
	_o=$(tsem intent-check); assert_contains fo 'reason=failover' "$_o"
	_mkintent german auto one 1 x
	_o=$(tsem intent-check); assert_contains seq 'reason=seq-ts' "$_o"
	_mkintent german auto 1 1 'BAD SRC'
	_o=$(tsem intent-check); assert_contains src 'reason=source' "$_o"
	_mkintent german auto 1 1 test
	_o=$(tsem intent-check); _rc=$?
	assert_eq ok-rc 0 "$_rc"; assert_contains ok 'reason=ok' "$_o"
}

test_intent_check_is_read_only() {
	t_setup
	_mkintent german auto 3 5 test bad
	_s=$(isum); _n=$(ls "$TSEM_MOCK_DIR" | wc -l)
	tsem intent-check >/dev/null 2>&1
	assert_eq intent-unchanged "$_s" "$(isum)"
	assert_eq mock-untouched "$_n" "$(ls "$TSEM_MOCK_DIR" | wc -l)"
}

test_invalid_intent_is_blocked_never_direct_and_reason_in_status() {
	t_setup
	_mkintent direct auto 1 1 test bad
	tsem boot >/dev/null 2>&1
	assert_eq guard blocked "$(guard)"
	assert_eq intent invalid "$(st intent)"
	assert_eq reason crc-mismatch "$(st intent_reason)"
	assert_contains json '"intent_reason":"crc-mismatch"' "$(tsem status --json)"
	tk 3
	assert_eq stays-blocked blocked "$(guard)"
	assert_eq intent-untouched invalid "$(st intent)"
}

test_installer_keeps_invalid_intent_and_saves_copy() {
	t_setup
	. "$ROOT/tests/t_install.sh"
	mkroot
	mkdir -p "$RT/etc/tsem"
	printf 'v=1\nmode=direct\ncrc=deadbeef\n' >"$RT/etc/tsem/intent"
	_h=$(md5sum <"$RT/etc/tsem/intent")
	inst --yes || fail "install failed: $(cat "$T/inst.out")"
	assert_eq untouched "$_h" "$(md5sum <"$RT/etc/tsem/intent")"
	[ -f "$RT/etc/tsem/intent.invalid-20260101-000001" ] || fail "no copy of the invalid intent"
	assert_contains warn 'INVALID' "$(cat "$T/inst.out")"
}

test_installer_fresh_intent_is_valid() {
	t_setup
	. "$ROOT/tests/t_install.sh"
	mkroot
	inst --yes || fail "install failed"
	TSEM_STATE_DIR=$RT/etc/tsem tsem intent-check >/dev/null || fail "fresh intent not valid"
}

# ---- layer-1 deny action fallback (fake `ip`) ----
_fakeip() {
	mkdir -p "$T/fb"
	cat >"$T/fb/ip" <<'IPEOF'
#!/bin/sh
db=${FAKE_RULES:?}
case $1 in -4 | -6) shift ;; esac
[ "$1" = rule ] || exit 0
shift
case $1 in
show) cat "$db" 2>/dev/null; exit 0 ;;
add)
	shift
	iif='' prio='' act=''
	while [ $# -gt 0 ]; do
		case $1 in
		iif) iif=$2; shift ;;
		priority) prio=$2; shift ;;
		lookup | suppress_prefixlength) act="$act $1 $2"; shift ;;
		prohibit | unreachable | blackhole) act=$1; for r in $FAKE_REFUSE; do [ "$r" = "$1" ] && exit 2; done ;;
		esac
		shift
	done
	echo "$prio:	from all iif $iif $act" >>"$db"; exit 0 ;;
del)
	shift
	while [ $# -gt 0 ]; do [ "$1" = priority ] && p=$2; shift; done
	grep -v "^$p:" "$db" >"$db.n"; mv "$db.n" "$db"; exit 0 ;;
esac
IPEOF
	chmod +x "$T/fb/ip"
	export FAKE_RULES=$T/rules
	: >"$FAKE_RULES"
	PATH=$T/fb:$PATH; export PATH
}
_rtsh() { ( . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"; "$@" ); }

test_deny_prefers_prohibit() {
	t_setup; _fakeip; export FAKE_REFUSE=''
	_rtsh _rt_on || fail "_rt_on"
	grep -q '5290:.*prohibit' "$FAKE_RULES" || fail "no prohibit rule: $(cat "$FAKE_RULES")"
	assert_eq state all "$(_rtsh _rt_state)"
}

test_deny_falls_back_to_unreachable_then_blackhole_and_stays_closed() {
	t_setup; _fakeip
	export FAKE_REFUSE='prohibit'
	_rtsh _rt_on || fail "fallback to unreachable failed"
	grep -q '5290:.*unreachable' "$FAKE_RULES" || fail "unreachable not used"
	assert_eq state all "$(_rtsh _rt_state)"
	_rtsh _rt_off
	assert_eq off none "$(_rtsh _rt_state)"
	export FAKE_REFUSE='prohibit unreachable'
	_rtsh _rt_on || fail "fallback to blackhole failed"
	grep -q '5290:.*blackhole' "$FAKE_RULES" || fail "blackhole not used"
	_rtsh _rt_off
	assert_eq off2 none "$(_rtsh _rt_state)"
}

test_deny_failure_is_an_error_not_a_silent_open() {
	t_setup; _fakeip; export FAKE_REFUSE='prohibit unreachable blackhole'
	if _rtsh _rt_on; then fail "_rt_on must fail when no deny action is accepted"; fi
	assert_eq partial partial "$(_rtsh _rt_state)"
}

test_deny_action_can_be_forced() {
	t_setup; _fakeip; export FAKE_REFUSE='' TSEM_RT_DENY=blackhole
	_rtsh _rt_on || fail "_rt_on"
	grep -q '5290:.*blackhole' "$FAKE_RULES" || fail "forced blackhole not used"
	assert_eq rtstate all "$(_rtsh _rt_state)"
}

test_selftest_has_no_false_prohibit_warning() {
	if grep -q 'ip-rule-prohibit' "$ROOT/src/usr/sbin/tsem"; then fail "old false-negative selftest id still present"; fi
}

# ---- fast path ----
_fpenv() {
	export TSEM_PROC_MODULES=$T/modules TSEM_FASTPATH=${1:-unload}
	printf 'nf_conntrack 100 3 - Live 0x0\nshortcut_fe_cm 10 0 - Live 0x0\nshortcut_fe 10 1 shortcut_fe_cm, Live 0x0\n' >"$TSEM_PROC_MODULES"
	mkdir -p "$T/fb"
	cat >"$T/fb/rmmod" <<'RMEOF'
#!/bin/sh
[ -e "$FAKE_RMMOD_FAIL" ] && exit 1
grep -v "^$1 " "$TSEM_PROC_MODULES" >"$TSEM_PROC_MODULES.n"; mv "$TSEM_PROC_MODULES.n" "$TSEM_PROC_MODULES"
RMEOF
	chmod +x "$T/fb/rmmod"
	export TSEM_RMMOD=$T/fb/rmmod FAKE_RMMOD_FAIL=$T/nofail
}

test_fastpath_detected_and_unloaded() {
	t_setup; _fpenv unload
	assert_contains state 'loaded:shortcut_fe_cm,shortcut_fe' "$(_rtsh be_fastpath_state)"
	_rtsh _fp_unload || fail "unload failed"
	assert_eq gone none "$(_rtsh be_fastpath_state)"
	grep -q '^nf_conntrack ' "$TSEM_PROC_MODULES" || fail "unrelated module was removed"
}

test_fastpath_unload_failure_is_reported() {
	t_setup; _fpenv unload; : >"$FAKE_RMMOD_FAIL"
	if _rtsh _fp_unload; then fail "must fail while the module is still loaded"; fi
	assert_contains still 'loaded:' "$(_rtsh be_fastpath_state)"
}

test_fastpath_refuse_mode_touches_nothing() {
	t_setup; _fpenv refuse
	_rtsh _fp_unload || fail "refuse mode must not touch anything"
	assert_contains kept 'loaded:' "$(_rtsh be_fastpath_state)"
}

test_fastpath_none_when_absent() {
	t_setup; export TSEM_PROC_MODULES=$T/modules
	printf 'nf_conntrack 100 3 - Live 0x0\n' >"$TSEM_PROC_MODULES"
	assert_eq none none "$(_rtsh be_fastpath_state)"
}

test_fastpath_config_validation() {
	t_setup
	printf 'TSEM_FASTPATH=bogus\nTSEM_RT_DENY=nonsense\n' >"$T/c.conf"
	_v2=$( ( TSEM_CONF=$T/c.conf; . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load 2>/dev/null; echo "$TSEM_FASTPATH $TSEM_RT_DENY" ) )
	assert_eq defaults "unload auto" "$_v2"
}

# ---- boot failure is visible ----
_initfn() { sed -n '/^boot_guard()/,/^}/p;/^start_service()/,/^}/p' "$ROOT/src/etc/init.d/tsem"; }

test_boot_guard_failure_is_logged_and_marked_not_ignored() {
	t_setup
	mkdir -p "$T/fb" "$T/vr"
	printf '#!/bin/sh\necho "$@" >>%s/logger.out\n' "$T" >"$T/fb/logger"; chmod +x "$T/fb/logger"
	printf '#!/bin/sh\nexit 1\n' >"$T/fb/failbin"; chmod +x "$T/fb/failbin"
	_initfn >"$T/fn.sh"
	sed -i "s#/var/run/tsem#$T/vr#g" "$T/fn.sh"
	( PATH=$T/fb:$PATH; export TSEM_BIN=$T/fb/failbin TSEM_BOOT_TRIES=3 TSEM_BOOT_RETRY_DELAY=0
	  procd_open_instance() { :; }; procd_set_param() { :; }; procd_close_instance() { :; }
	  . "$T/fn.sh"; start_service ) >/dev/null 2>&1
	[ -s "$T/vr/boot_failed" ] || fail "boot_failed marker not written"
	assert_contains crit 'CRITICAL' "$(cat "$T/logger.out")"
}

test_boot_guard_retries_then_succeeds() {
	t_setup
	printf '#!/bin/sh\nn=$(cat %s/n 2>/dev/null || echo 0); n=$((n+1)); echo $n >%s/n; [ $n -ge 3 ]\n' "$T" "$T" >"$T/flaky"; chmod +x "$T/flaky"
	_initfn >"$T/fn.sh"
	( export TSEM_BIN=$T/flaky TSEM_BOOT_TRIES=5 TSEM_BOOT_RETRY_DELAY=0; . "$T/fn.sh"; boot_guard ) || fail "should succeed on 3rd try"
	assert_eq tries 3 "$(cat "$T/n")"
}

test_status_reports_boot_failed_as_leak_risk() {
	t_setup; _mkintent german auto 1 1 test
	tsem boot >/dev/null 2>&1
	assert_eq clean no "$(st boot_failed)"
	: >"$TSEM_RUN_DIR/boot_failed"
	assert_eq marked yes "$(st boot_failed)"
	if tsem status >/dev/null 2>&1; then fail "status must exit non-zero (leak risk) while boot_failed is set"; fi
	tsem boot >/dev/null 2>&1
	assert_eq cleared no "$(st boot_failed)"
}

# ---- DNS classification (string logic only; 0.0.0.0 is never "interpreted") ----
_dnsc() { sed -n '/^dns_class()/,/^}/p' "$ROOT/src/usr/sbin/tsem" >"$T/dc.sh"; ( . "$T/dc.sh"; dns_class "$1" ); }

test_dns_class_does_not_interpret_unspecified_address() {
	t_setup
	assert_eq unspec unspecified "$(_dnsc 0.0.0.0)"
	assert_eq loop loopback "$(_dnsc 127.0.0.1)"
	assert_eq priv private "$(_dnsc 192.168.8.1)"
	assert_eq priv2 private "$(_dnsc 172.20.1.1)"
	assert_eq ts tailnet "$(_dnsc 100.100.100.100)"
	assert_eq pub public "$(_dnsc 1.1.1.1)"
	assert_eq pub2 public "$(_dnsc 172.32.0.1)"
	assert_eq v6 loopback "$(_dnsc ::1)"
}

# ---- resolver 0.0.0.0: PASS only on kernel evidence (ip route get ... local ... dev lo) ----
_unspec() { # <fake ip output> -> rc of dns_unspec_local
	mkdir -p "$T/ipf"
	printf '#!/bin/sh\n[ -z "$FAKE_IP_OUT" ] || printf "%%s\\n" "$FAKE_IP_OUT"\nexit ${FAKE_IP_RC:-0}\n' >"$T/ipf/ip"; chmod +x "$T/ipf/ip"
	sed -n '/^dns_unspec_local()/,/^}/p' "$ROOT/src/usr/sbin/tsem" >"$T/du.sh"
	( PATH=$T/ipf:$PATH; FAKE_IP_OUT=$1; FAKE_IP_RC=${2:-0}; export FAKE_IP_OUT FAKE_IP_RC; . "$T/du.sh"; dns_unspec_local )
}

test_resolver_zero_is_local_when_the_kernel_says_so() {
	t_setup
	_unspec 'local 0.0.0.0 dev lo src 127.0.0.1 uid 0' || fail "local ... dev lo must be accepted"
	_unspec 'local 0.0.0.0 dev lo' || fail "local ... dev lo (end of line) must be accepted"
}

test_resolver_zero_not_proven_when_route_goes_elsewhere_or_fails() {
	t_setup
	if _unspec '0.0.0.0 via 192.168.1.1 dev eth0 src 192.168.1.2'; then fail "a route via eth0 is no proof"; fi
	if _unspec 'local 0.0.0.0 dev lo0x src 1.2.3.4'; then fail "dev lo0x is not dev lo"; fi
	if _unspec '' 2; then fail "an error / empty answer is no proof"; fi
}
