# shellcheck shell=sh
# tsem-masq: permanent repair of the LAN -> tailscale0 source NAT. Everything runs against fake uci / iptables /
# firewall-init commands in a throw-away directory (simulated; nothing here is hardware evidence).
#
# Fake world ($FX):  masq (value of firewall.<zone>.masq; absent = unset), chain (exists), rules (nat chain rules),
#                    uci.log / ipt.log / fw.log (every call), commits (count)

_mq_setup() {
	t_setup
	FX=$T/fx; mkdir -p "$FX/bin" "$FX/run"
	: >"$FX/uci.log"; : >"$FX/ipt.log"; : >"$FX/fw.log"; : >"$FX/rules"; echo 0 >"$FX/commits"
	cat >"$FX/bin/uci" <<'S'
#!/bin/sh
# fake uci for the firewall config: zone lan + zone tailscale0 (named cfg0a1b2c) + forwarding lan->tailscale0
echo "$*" >>"$FX/uci.log"
[ "$1" = -q ] && shift
case $1 in
show)
	echo "firewall.cfg01=zone"; echo "firewall.cfg01.name='lan'"
	[ -e "$FX/nozone" ] || {
		echo "firewall.cfg0a1b2c=zone"; echo "firewall.cfg0a1b2c.name='tailscale0'"
		[ ! -e "$FX/masq" ] || echo "firewall.cfg0a1b2c.masq='$(cat "$FX/masq")'"
	}
	if [ ! -e "$FX/noforward" ]; then
		echo "firewall.@forwarding[0]=forwarding"; echo "firewall.@forwarding[0].src='lan'"; echo "firewall.@forwarding[0].dest='tailscale0'"
	fi ;;
get) case $2 in firewall.cfg0a1b2c.masq) [ -e "$FX/masq" ] && cat "$FX/masq" || exit 1 ;; *) exit 1 ;; esac ;;
set) case $2 in firewall.cfg0a1b2c.masq=*) echo "${2#*=}" >"$FX/masq" ;; *) exit 1 ;; esac ;;
commit) echo $(( $(cat "$FX/commits") + 1 )) >"$FX/commits" ;;
*) exit 1 ;;
esac
S
	cat >"$FX/bin/iptables" <<'S'
#!/bin/sh
# fake iptables: only the nat zone chain
echo "$*" >>"$FX/ipt.log"
[ "$1" = -t ] && [ "$2" = nat ] || exit 2
shift 2
op=$1; ch=$2; shift 2
[ "$ch" = zone_tailscale0_postrouting ] || exit 2
case $op in
-S) [ -e "$FX/chain" ] || exit 1; echo "-N $ch"; sed "s/^/-A $ch /" "$FX/rules" ;;
-A) [ -e "$FX/chain" ] || exit 1; echo "$*" >>"$FX/rules" ;;
-C) grep -qxF -- "$*" "$FX/rules" ;;
-D) grep -qxF -- "$*" "$FX/rules" || exit 1; grep -vxF -- "$*" "$FX/rules" >"$FX/r2"; mv "$FX/r2" "$FX/rules" ;;
*) exit 2 ;;
esac
S
	# fake `/etc/init.d/firewall reload` = fw3: rebuilds the zone chain from UCI (masq=1 -> its MASQUERADE rule)
	cat >"$FX/bin/firewall" <<'S'
#!/bin/sh
echo "$*" >>"$FX/fw.log"
[ "$1" = reload ] || exit 1
[ ! -e "$FX/reload_noop" ] || exit 0
: >"$FX/chain"; : >"$FX/rules"
[ "$(cat "$FX/masq" 2>/dev/null)" = 1 ] && echo '-m comment --comment !fw3 -j MASQUERADE' >"$FX/rules"
exit 0
S
	chmod +x "$FX/bin/uci" "$FX/bin/iptables" "$FX/bin/firewall"
	export FX
	export TSEM_MASQ_UCI=$FX/bin/uci TSEM_MASQ_IPT=$FX/bin/iptables TSEM_MASQ_FWINIT=$FX/bin/firewall
	export TSEM_MASQ_RUN=$FX/run TSEM_MASQ_BACKUP=$FX/backup TSEM_MASQ_LOG=0
	export TSEM_MASQ_FWCONF=$FX/firewall.conf
	echo "config zone" >"$FX/firewall.conf"
	unset TSEM_MASQ_NORELOAD
}
_mq() { "$SH" "$ROOT/src/usr/sbin/tsem-masq" "$@"; }
_mq_writes() { grep -c -E '^-t nat -(A|D|I|F) ' "$FX/ipt.log" | tr -d ' '; }
_mq_rules() { wc -l <"$FX/rules" | tr -d ' '; }
_mq_stock() { : >"$FX/chain"; echo 0 >"$FX/masq"; : >"$FX/rules"; } # the state the GL firmware leaves: masq=0, chain without MASQUERADE

test_check_reports_the_real_failure_and_changes_nothing() {
	_mq_setup; _mq_stock
	_o=$(_mq check); _rc=$?
	assert_eq rc 1 "$_rc"
	assert_contains uci "FAIL  masq.uci" "$_o"
	assert_contains nat "FAIL  masq.nat" "$_o"
	assert_eq "no commit" 0 "$(cat "$FX/commits")"
	assert_eq "no iptables write" 0 "$(_mq_writes)"
	assert_eq "masq untouched" 0 "$(cat "$FX/masq")"
	[ ! -s "$FX/fw.log" ] || fail "check reloaded the firewall"
}

test_ensure_resets_masq0_and_adds_the_live_rule_without_a_reload() {
	_mq_setup; _mq_stock
	_mq ensure >"$T/o" 2>&1 || fail "ensure failed: $(cat "$T/o")"
	assert_eq masq 1 "$(cat "$FX/masq")"
	assert_eq "one commit" 1 "$(cat "$FX/commits")"
	assert_eq "one live rule" 1 "$(_mq_rules)"
	grep -q 'tsem-masq' "$FX/rules" || fail "our rule is not recognisable"
	[ ! -s "$FX/fw.log" ] || fail "reload although the chain existed"
	[ -d "$FX/backup" ] && [ -n "$(ls "$FX/backup")" ] || fail "no backup of /etc/config/firewall before the first change"
	_mq check >/dev/null || fail "state not consistent after ensure"
}

test_missing_nat_rule_alone_is_repaired_without_touching_uci() {
	_mq_setup; : >"$FX/chain"; echo 1 >"$FX/masq"
	_mq ensure >/dev/null 2>&1 || fail "ensure failed"
	assert_eq "no commit" 0 "$(cat "$FX/commits")"
	assert_eq "rule added" 1 "$(_mq_rules)"
	grep -q 'set' "$FX/uci.log" && fail "uci was written although masq was already 1"
	:
}

test_consistent_state_causes_no_write_at_all_and_repeats_are_idempotent() {
	_mq_setup; _mq_stock
	_mq ensure >/dev/null 2>&1
	_c=$(cat "$FX/commits"); _w=$(_mq_writes); _u=$(grep -c '^set\|^-q set' "$FX/uci.log")
	for _i in 1 2 3 4 5; do _mq ensure >/dev/null 2>&1 || fail "repeat $_i failed"; done
	assert_eq commits "$_c" "$(cat "$FX/commits")"
	assert_eq "iptables writes" "$_w" "$(_mq_writes)"
	assert_eq "uci sets" "$_u" "$(grep -c '^set\|^-q set' "$FX/uci.log")"
	assert_eq "rules" 1 "$(_mq_rules)"
	[ ! -s "$FX/fw.log" ] || fail "reload during repeats"
}

test_firewall_reload_after_a_gl_reset_is_repaired_by_the_include_and_fw3_becomes_the_owner() {
	_mq_setup
	# 1. everything fine, fw3 loaded with masq=1
	echo 1 >"$FX/masq"; "$FX/bin/firewall" reload
	assert_eq "fw3 rule" 1 "$(_mq_rules)"
	# 2. GL (firewall.tailscale.sh / captive portal / tailscale restart) rewrites the zone with masq=0 and reloads fw3
	echo 0 >"$FX/masq"; "$FX/bin/firewall" reload
	assert_eq "rule gone after the reset" 0 "$(_mq_rules)"
	# 3. the fw3 include of the component runs after the reload: UCI and live rule are repaired, no recursion
	TSEM_MASQ_NORELOAD=1 "$SH" "$ROOT/src/usr/lib/tsem/masq-include.sh" 2>/dev/null
	# the include calls /usr/sbin/tsem-masq; in the sandbox run the same code path directly
	TSEM_MASQ_NORELOAD=1 _mq ensure >/dev/null 2>&1 || fail "ensure inside the include failed"
	assert_eq masq 1 "$(cat "$FX/masq")"
	assert_eq "live rule" 1 "$(_mq_rules)"
	assert_eq "no reload by the repair" 2 "$(grep -c reload "$FX/fw.log")"
	# 4. the next fw3 reload builds the rule from UCI: tsem-masq must leave exactly that one
	"$FX/bin/firewall" reload
	TSEM_MASQ_NORELOAD=1 _mq ensure >/dev/null 2>&1
	assert_eq "exactly one MASQUERADE" 1 "$(_mq_rules)"
	grep -q 'tsem-masq' "$FX/rules" && fail "our duplicate survived next to fw3's rule"
	:
}

test_duplicate_tsem_rule_is_removed_when_fw3_has_its_own() {
	_mq_setup; echo 1 >"$FX/masq"; "$FX/bin/firewall" reload
	echo '-m comment --comment tsem-masq -j MASQUERADE' >>"$FX/rules"
	assert_eq "two before" 2 "$(_mq_rules)"
	_mq ensure >/dev/null 2>&1
	assert_eq "one after" 1 "$(_mq_rules)"
	grep -q '!fw3' "$FX/rules" || fail "fw3's own rule was removed"
}

test_reboot_simulation_boot_repair_never_reloads_and_fw3_then_builds_the_rule() {
	_mq_setup
	echo 0 >"$FX/masq"; rm -f "$FX/chain"        # firmware booted: UCI has masq=0, fw3 has not built the chain yet
	TSEM_MASQ_NORELOAD=1 _mq ensure >"$T/o" 2>&1 || fail "boot ensure failed: $(cat "$T/o")"
	assert_eq masq 1 "$(cat "$FX/masq")"
	[ ! -s "$FX/fw.log" ] || fail "boot repair reloaded the firewall"
	assert_eq "no rule written into a missing chain" 0 "$(_mq_writes)"
	"$FX/bin/firewall" reload                     # fw3 starts
	_mq check >/dev/null || fail "after fw3 started the state is not consistent"
	assert_eq "fw3 rule" 1 "$(_mq_rules)"
}

test_missing_chain_triggers_one_reload_and_the_rate_limit_stops_loops() {
	_mq_setup; echo 1 >"$FX/masq"; rm -f "$FX/chain"
	export TSEM_MASQ_NOW_UNUSED=1
	_mq ensure >/dev/null 2>&1 || fail "ensure with a missing chain failed"
	assert_eq "one reload" 1 "$(grep -c reload "$FX/fw.log")"
	assert_eq "rule from fw3" 1 "$(_mq_rules)"
	# fw3 that never builds the chain: the second call inside the gap must NOT reload again
	rm -f "$FX/chain"; : >"$FX/reload_noop"
	_mq ensure >/dev/null 2>&1 && fail "must report failure while the chain is missing"
	assert_eq "still one reload" 1 "$(grep -c reload "$FX/fw.log")"
}

test_no_reload_flag_and_environment_never_reload() {
	_mq_setup; echo 1 >"$FX/masq"; rm -f "$FX/chain"
	_mq ensure --no-reload >/dev/null 2>&1
	TSEM_MASQ_NORELOAD=1 _mq ensure >/dev/null 2>&1
	[ ! -s "$FX/fw.log" ] || fail "reload despite --no-reload / TSEM_MASQ_NORELOAD"
}

test_without_the_tailscale_zone_nothing_is_created_or_written() {
	_mq_setup; : >"$FX/nozone"
	_mq ensure >/dev/null 2>&1; assert_eq rc 3 "$?"
	_mq check >/dev/null 2>&1; assert_eq rc 3 "$?"
	assert_eq commits 0 "$(cat "$FX/commits")"
	assert_eq writes 0 "$(_mq_writes)"
}

test_missing_forwarding_is_reported_but_never_created() {
	_mq_setup; _mq_stock; : >"$FX/noforward"
	_o=$(_mq check)
	assert_contains warn "WARN  masq.forward" "$_o"
	_mq ensure >/dev/null 2>&1
	grep -q 'forwarding' "$FX/uci.log" && grep -q '^set\|^-q set' "$FX/uci.log" && \
		[ "$(grep -c 'forwarding' "$FX/uci.log")" -gt 0 ] && grep 'set.*forwarding' "$FX/uci.log" && fail "a forwarding was created"
	:
}

test_repair_only_touches_the_zone_nat_chain_never_the_kill_switch_or_wan() {
	_mq_setup; _mq_stock; _mq ensure >/dev/null 2>&1; _mq check >/dev/null 2>&1
	# every iptables call: nat table, the zone chain only; no filter table, no TSEM chain, no ACCEPT, no flush
	grep -v '^-t nat -[SACD] zone_tailscale0_postrouting' "$FX/ipt.log" | grep -q . && fail "unexpected iptables call: $(grep -v '^-t nat -[SACD] zone_tailscale0_postrouting' "$FX/ipt.log")"
	grep -q 'ACCEPT\|TSEM\|FORWARD\|-F\|-X' "$FX/ipt.log" && fail "kill-switch / policy rule touched"
	# the source never mentions the kill switch objects outside comments
	grep -v '^[[:space:]]*#' "$ROOT/src/usr/sbin/tsem-masq" | grep -qE 'TSEM_FWD|TSEM_OUT|TSEM_DNS|ip rule|tailscale (set|up)|ACCEPT' && fail "tsem-masq references kill-switch objects"
	:
}

test_check_works_without_tsem_installed_or_running() {
	_mq_setup; _mq_stock
	# the component does not source or call the controller
	grep -qE '/usr/sbin/tsem([^-]|$)|TSEM_LIBDIR|common\.sh' "$ROOT/src/usr/sbin/tsem-masq" && fail "tsem-masq depends on the controller"
	_mq check >/dev/null 2>&1; assert_eq rc 1 "$?"
}

test_hooks_are_event_driven_and_cannot_loop_or_fail_the_firewall() {
	# include: never reloads, never fails fw3
	grep -q 'TSEM_MASQ_NORELOAD=1' "$ROOT/src/usr/lib/tsem/masq-include.sh" || fail "include may reload"
	grep -q '^exit 0' "$ROOT/src/usr/lib/tsem/masq-include.sh" || fail "include can fail fw3"
	# hotplug: only ifup/ifupdate, debounced, no reload, background
	grep -q 'ifup' "$ROOT/src/etc/hotplug.d/iface/51-tsem-masq" || fail "no ifup trigger"
	grep -q 'TSEM_MASQ_NORELOAD=1' "$ROOT/src/etc/hotplug.d/iface/51-tsem-masq" || fail "hotplug may reload"
	grep -q 'ge 5' "$ROOT/src/etc/hotplug.d/iface/51-tsem-masq" || fail "no debounce"
	# init: config trigger on the firewall config, watcher with a sleep (no busy loop), respawn limited
	grep -q 'procd_add_config_trigger "config.change" "firewall"' "$ROOT/src/etc/init.d/tsem-masq" || fail "no config trigger"
	grep -q 'sleep "$INTERVAL"' "$ROOT/src/usr/sbin/tsem-masq" || fail "watch loop without sleep"
	grep -qE 'cron|reload.*while|while.*firewall reload' "$ROOT/src/etc/init.d/tsem-masq" && fail "periodic reloads"
	for f in src/usr/sbin/tsem-masq src/usr/lib/tsem/masq-include.sh src/etc/hotplug.d/iface/51-tsem-masq src/etc/init.d/tsem-masq; do
		"$SH" -n "$ROOT/$f" || fail "syntax: $f"
	done
}

# ---------------------------------------------------------------- installer integration
_mq_inst_helpers() { [ -n "$(command -v mkroot)" ] || . "$ROOT/tests/t_install.sh"; }

test_masq_component_installs_alone_without_core_and_adds_only_its_include() {
	_mq_inst_helpers; mkroot
	inst --yes --enable --components masq || fail "masq install failed: $(cat "$T/inst.out")"
	for f in usr/sbin/tsem-masq usr/lib/tsem/masq-include.sh etc/init.d/tsem-masq etc/hotplug.d/iface/51-tsem-masq; do
		[ -f "$RT/$f" ] || fail "missing $f"
	done
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "core installed by a masq-only run"
	assert_eq mode 755 "$(stat -c %a "$RT/usr/lib/tsem/masq-include.sh")"
	grep -q "include 'tsem_masq'" "$RT/etc/config/firewall" || fail "masq include missing"
	grep -q "include 'tsem'$" "$RT/etc/config/firewall" && fail "core include added by a masq-only install"
	[ -L "$RT/etc/rc.d/S96tsem-masq" ] || fail "boot link missing"
	grep -q '^C|masq$' "$RT/etc/tsem/install.manifest" || fail "component not recorded"
	# repeating the install is a no-op for the firewall file
	_h=$(md5sum <"$RT/etc/config/firewall")
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes --enable --components masq || fail "repeat failed"
	assert_eq "firewall file unchanged" "$_h" "$(md5sum <"$RT/etc/config/firewall")"
	assert_eq "one block" 1 "$(grep -c tsem-begin "$RT/etc/config/firewall")"
}

test_adding_masq_to_an_existing_core_install_rebuilds_one_block_and_rollback_restores_it() {
	_mq_inst_helpers; mkroot
	inst --yes --components core || fail "core failed"
	_before=$(md5sum <"$RT/etc/config/firewall")
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes --components masq || fail "masq add failed: $(cat "$T/inst.out")"
	assert_eq "one block" 1 "$(grep -c tsem-begin "$RT/etc/config/firewall")"
	grep -q "include 'tsem'$" "$RT/etc/config/firewall" || fail "core include lost"
	grep -q "include 'tsem_masq'" "$RT/etc/config/firewall" || fail "masq include missing"
	"$SH" "$ROOT/install.sh" --root "$RT" --rollback --yes >"$T/rb.out" 2>&1 || fail "rollback failed: $(cat "$T/rb.out")"
	assert_eq "firewall restored" "$_before" "$(md5sum <"$RT/etc/config/firewall")"
	[ ! -e "$RT/usr/sbin/tsem-masq" ] || fail "masq file survived the rollback"
}

test_uninstall_removes_the_masq_component_and_the_include() {
	_mq_inst_helpers; mkroot
	inst --yes --enable --components masq || fail "install failed"
	uninst --yes || fail "uninstall failed: $(cat "$T/uninst.out")"
	[ ! -e "$RT/usr/sbin/tsem-masq" ] || fail "tool left behind"
	[ ! -e "$RT/etc/rc.d/S96tsem-masq" ] || fail "boot link left behind"
	grep -q 'tsem' "$RT/etc/config/firewall" && fail "include left in the firewall config"
	:
}

test_masq_is_opt_in_the_default_install_leaves_it_out_and_the_component_adds_it() {
	_mq_inst_helpers; mkroot
	inst --yes || fail "install failed: $(cat "$T/inst.out")"
	[ ! -e "$RT/usr/sbin/tsem-masq" ] || fail "masq is part of the default install"
	grep -q "include 'tsem'$" "$RT/etc/config/firewall" || fail "controller include missing"
	grep -q "include 'tsem_masq'" "$RT/etc/config/firewall" && fail "default install wrote the masq include"
	TSEM_INSTALL_STAMP=20260101-000009 inst --yes --components core,api,luci-gui,masq || fail "opt-in masq failed: $(cat "$T/inst.out")"
	[ -x "$RT/usr/sbin/tsem-masq" ] || fail "opt-in did not install masq"
	grep -q "include 'tsem'$" "$RT/etc/config/firewall" && grep -q "include 'tsem_masq'" "$RT/etc/config/firewall" || fail "includes missing"
	assert_eq "one block" 1 "$(grep -c tsem-begin "$RT/etc/config/firewall")"
}

_mq_wrap() { # args for run-masq-fix-mac.sh; stdin = answer
	cat >"$T/fakessh" <<S
#!/bin/sh
for a; do cmd=\$a; done
echo "\$cmd" >>"$T/ssh.log"
exec $SH -c "\$cmd"
S
	chmod +x "$T/fakessh"; : >"$T/ssh.log"
	WO=$(TSEM_MASQ_SSH=$T/fakessh "$SH" "$ROOT/tools/run-masq-fix-mac.sh" --out "$T/out" "$@" 2>&1); WRC=$?
}

test_mac_fix_without_apply_is_read_only() {
	_mq_setup; _mq_stock
	_mq_wrap </dev/null
	assert_eq rc 1 "$WRC"
	assert_contains res "Nothing was changed" "$WO"
	assert_eq "no commit" 0 "$(cat "$FX/commits")"
	assert_eq "masq untouched" 0 "$(cat "$FX/masq")"
	assert_eq "one ssh call" 1 "$(grep -c . "$T/ssh.log")"
}

test_mac_fix_apply_needs_the_phrase_and_repairs_with_it() {
	_mq_setup; _mq_stock
	echo nope >"$T/ans"; _mq_wrap --apply <"$T/ans"
	assert_eq "wrong phrase aborts" 1 "$WRC"
	assert_eq "masq untouched" 0 "$(cat "$FX/masq")"
	assert_eq "no commit" 0 "$(cat "$FX/commits")"
	echo FIX-MASQ >"$T/ans"; _mq_wrap --apply <"$T/ans"
	assert_eq "repaired" 0 "$WRC"
	assert_contains res "repaired and verified" "$WO"
	assert_eq masq 1 "$(cat "$FX/masq")"
	assert_eq "one live rule" 1 "$(_mq_rules)"
	[ ! -s "$FX/fw.log" ] || fail "the repair reloaded the firewall"
	_mq check >/dev/null || fail "not consistent afterwards"
}

test_mac_fix_nothing_to_do_when_consistent_and_no_connection_is_69() {
	_mq_setup; : >"$FX/chain"; echo 1 >"$FX/masq"; echo '-m comment --comment !fw3 -j MASQUERADE' >"$FX/rules"
	_mq_wrap </dev/null
	assert_eq rc 0 "$WRC"
	assert_contains res "nothing to do" "$WO"
	printf '#!/bin/sh\nexit 255\n' >"$T/fakessh"
	WO=$(TSEM_MASQ_SSH=$T/fakessh "$SH" "$ROOT/tools/run-masq-fix-mac.sh" --out "$T/out" </dev/null 2>&1); WRC=$?
	assert_eq "no connection" 69 "$WRC"
}
