# shellcheck shell=sh
# Failover state machine + guard ordering, against the mock backend.

test_primary_reachable() {
	go_german
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq guard german "$(guard)"
	assert_eq exit "$P1" "$(mexit)"
	assert_eq active "$P1" "$(st active_exit)"
	assert_eq ks true "$(st kill_switch_active)"
}

test_guard_closed_before_exit_node_and_never_open() {
	go_german
	_c=$(ev_line "guard blocked" first)
	_e=$(ev_line "exit $P1" first)
	[ "$_c" -gt 0 ] && [ "$_e" -gt "$_c" ] || fail "guard must be blocked before exit node is set (blocked@$_c exit@$_e)"
	assert_never_open_after 0
}

test_not_active_before_hysteresis() {
	tsem set german --no-wait
	tk 1
	assert_eq state BLOCKED "$(st state)"
	assert_eq guard blocked "$(guard)"
	tk 2
	assert_eq state CONNECTING_PRIMARY "$(st state)"
	assert_eq guard blocked "$(guard)"
	tk 3
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_primary_down_fails_over_to_secondary() {
	go_german
	_m=$(ev_seq)
	mdown $P1
	tk 10
	assert_eq state SECONDARY_ACTIVE "$(st state)"
	assert_eq exit "$P2" "$(mexit)"
	assert_eq guard german "$(guard)"
	assert_never_open_after "$_m"
	assert_eq primary_ok fail "$(st primary_ok)"
}

test_single_failure_does_not_switch_and_shows_degraded() {
	go_german
	mdown $P1; tk 1
	assert_eq state DEGRADED "$(st state)"
	assert_eq exit "$P1" "$(mexit)"
	assert_eq guard german "$(guard)"
	mup $P1; tk 1
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_secondary_down_while_primary_active() {
	go_german
	mdown $P2; tk 6
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq secondary_ok fail "$(st secondary_ok)"
}

test_both_down_blocks_and_never_opens() {
	go_german
	_m=$(ev_seq)
	mflag down_all
	tk 12
	assert_eq state BLOCKED "$(st state)"
	assert_eq guard blocked "$(guard)"
	assert_eq ks true "$(st kill_switch_active)"
	assert_never_open_after "$_m"
}

test_recovery_from_blocked() {
	go_german
	mflag down_all; tk 12
	munflag down_all; tk 12
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq guard german "$(guard)"
}

test_return_to_primary_needs_dwell_and_returns() {
	export TSEM_DWELL=300
	go_german
	mdown $P1; tk 10
	assert_eq state SECONDARY_ACTIVE "$(st state)"
	mup $P1
	tk 10
	assert_eq "RETURN_N met but DWELL not" SECONDARY_ACTIVE "$(st state)"
	export TSEM_NOW=$((TSEM_NOW + 300))
	tk 6
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq exit "$P1" "$(mexit)"
}

test_return_needs_return_n_successes() {
	export TSEM_DWELL=0
	go_german
	mdown $P1; tk 10
	mup $P1; tk 3
	assert_eq "only 3 of RETURN_N=6" SECONDARY_ACTIVE "$(st state)"
}

test_flapping_primary_does_not_cause_switching() {
	go_german
	_m=$(ev_seq)
	_i=0
	while [ $_i -lt 12 ]; do
		mdown $P1; tk 1; mup $P1; tk 1; _i=$((_i + 1))
	done
	assert_eq exit "$P1" "$(mexit)"
	_x=$(awk -v s="$_m" '$1 > s && $2 == "exit" { n++ } END { print n + 0 }' "$TSEM_MOCK_DIR/events")
	assert_eq "no exit changes" 0 "$_x"
}

test_dead_node_backoff_blocks_immediate_reselect() {
	go_german
	mdown $P1; tk 10                   # primary dead -> secondary
	mup $P1; mdown $P2; tk 3           # secondary dies right after primary recovered
	# primary is in backoff (30 s) -> not selected yet, must stay blocked/connecting, never leak
	assert_eq guard blocked "$(guard)"
	tk 10
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_dns_failure_degrades_but_keeps_tunnel_only_guard() {
	export TSEM_DNS_PROBE_HOST=example.org
	go_german
	mflag dns_down; tk 2
	assert_eq state DEGRADED "$(st state)"
	assert_eq guard german "$(guard)"
	assert_eq dns fail "$(st dns)"
	munflag dns_down; tk 2
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_tailscale_down_is_never_direct() {
	go_german
	_m=$(ev_seq)
	mflag ts_down; mflag down_all; tk 12
	assert_eq guard blocked "$(guard)"
	assert_never_open_after "$_m"
	munflag ts_down; munflag down_all; tk 14
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_exit_set_failure_gives_error_and_blocked() {
	tsem set german --no-wait
	mflag fail_exit; tk 6
	assert_eq state ERROR "$(st state)"
	assert_eq guard blocked "$(guard)"
	munflag fail_exit; tk 8
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_guard_apply_failure_is_error_state() {
	go_german
	mflag fail_guard; mdown $P1; tk 8
	assert_eq state ERROR "$(st state)"
	munflag fail_guard; mup $P1; tk 10
	[ "$(st state)" != ERROR ] || fail "did not recover from ERROR"
}

test_drift_is_repaired() {
	go_german
	: >"$TSEM_MOCK_DIR/events"
	mflag drift_guard
	tk 1
	[ "$(ev_line 'guard german' first)" -gt 0 ] || fail "drift (hook/rules lost) was not re-applied"
}

test_failover_off_never_uses_secondary() {
	tsem set german --no-wait
	tsem failover off
	tk 8
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	mdown $P1; tk 10
	assert_eq state BLOCKED "$(st state)"
	assert_eq guard blocked "$(guard)"
	[ "$(mexit)" != "$P2" ] || fail "secondary was used with failover=off"
}

test_failover_now_switches_and_refuses_when_unavailable() {
	go_german
	tsem failover now || fail "manual failover failed"
	tk 6
	assert_eq state SECONDARY_ACTIVE "$(st state)"
	# secondary active, primary in backoff: a second manual failover must be refused, not self-block
	mdown $P1; tk 3
	assert_rc "refused" 1 tsem failover now
	assert_eq state SECONDARY_ACTIVE "$(st state)"
}

test_failover_policy_persists_in_intent() {
	tsem set german --no-wait
	tsem failover off --source ha
	assert_eq failover off "$(st failover)"
	assert_eq source ha "$(st source)"
	assert_eq mode german "$(st mode)"
}

test_direct_opens_guard_last_and_clears_exit() {
	go_german
	_m=$(ev_seq)
	tsem set direct --no-wait
	assert_eq guard open "$(guard)"
	assert_eq exit none "$(mexit)"
	_x=$(ev_line "exit none" last); _o=$(ev_line "guard open" last)
	[ "$_x" -gt "$_m" ] && [ "$_o" -gt "$_x" ] || fail "exit must be cleared before guard opens"
	assert_eq state DISABLED "$(st state)"
	assert_eq ks false "$(st kill_switch_active)"
}

test_direct_keeps_guard_if_exit_cannot_be_cleared() {
	go_german
	mflag fail_exit
	tsem set direct --no-wait
	[ "$(guard)" != open ] || fail "guard opened although exit node could not be cleared"
}

test_user_action_during_probe_wins() {
	go_german
	cat >"$TSEM_MOCK_DIR/slow_hook" <<'X'
X
	# make probes slow so a user action lands in the middle of a tick
	_orig=$TSEM_LIBDIR
	mkdir -p "$T/lib" && cp "$_orig"/*.sh "$T/lib/"
	cat >>"$T/lib/backend_mock.sh" <<'X'
_orig_reach() { :; }
be_probe_reach() { sleep 1; [ ! -e "$TSEM_MOCK_DIR/down_all" ]; }
X
	export TSEM_LIBDIR=$T/lib
	tsem tick &
	sleep 0.3
	tsem set direct --no-wait --source hw
	wait
	tk 2
	assert_eq mode direct "$(st mode)"
	assert_eq guard open "$(guard)"
	assert_eq state DISABLED "$(st state)"
}

test_rapid_switch_toggling_ends_consistent() {
	_i=0
	while [ $_i -lt 20 ]; do
		tsem set german --no-wait --source hw; tsem set direct --no-wait --source hw; _i=$((_i + 1))
	done
	tsem set german --no-wait --source hw
	tk 8
	assert_eq mode german "$(st mode)"
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq guard german "$(guard)"
}

test_hw_and_ha_concurrent_actions() {
	go_german
	for i in 1 2 3 4 5 6; do
		tsem set direct --no-wait --source ha & tsem set german --no-wait --source hw &
	done
	wait
	_m=$(st mode)
	tk 10
	assert_eq "mode stable" "$_m" "$(st mode)"
	assert_eq intent ok "$(st intent)"
	if [ "$_m" = german ]; then assert_eq state PRIMARY_ACTIVE "$(st state)"; assert_eq guard german "$(guard)"
	else assert_eq state DISABLED "$(st state)"; assert_eq guard open "$(guard)"; fi
}

test_reapply_restores_current_guard_without_probes() {
	go_german
	rm -f "$TSEM_MOCK_DIR/guard"
	tsem reapply
	assert_eq guard german "$(guard)"
}

test_reapply_after_reboot_state_is_blocked_for_german() {
	go_german
	rm -rf "$TSEM_RUN_DIR"/failover "$TSEM_MOCK_DIR"/guard
	tsem reapply
	assert_eq guard blocked "$(guard)"
}

test_reboot_goes_blocked_then_recovers() {
	go_german
	rm -rf "$TSEM_RUN_DIR"/failover "$TSEM_MOCK_DIR"/guard "$TSEM_MOCK_DIR"/exit
	tsem boot
	assert_eq guard blocked "$(guard)"
	assert_eq state BLOCKED "$(st state)"
	tk 10
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_status_leak_risk_when_guard_missing() {
	go_german
	rm -f "$TSEM_MOCK_DIR/guard"
	assert_rc "leak_risk" 1 tsem status
	assert_eq leak true "$(st leak_risk)"
}

test_status_json_is_valid() {
	go_german
	_j=$(tsem status --json)
	assert_contains json '"state":"PRIMARY_ACTIVE"' "$_j"
	assert_contains json '"kill_switch_active":true' "$_j"
	command -v python3 >/dev/null 2>&1 && printf '%s' "$_j" | python3 -c 'import json,sys; json.load(sys.stdin)' || true
}

test_set_wait_reaches_active() {
	tsem set german >/dev/null 2>&1
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_hw_state_consistency_reporting() {
	echo on >"$T/hw"; export TSEM_HW_STATE_FILE=$T/hw
	tsem set german --no-wait --source ha
	assert_eq match yes "$(st hw_match)"
	tsem set direct --no-wait --source ha
	assert_eq match no "$(st hw_match)"
}

test_no_advertise_exit_node_is_ever_used() {
	! grep -rn -- 'advertise-exit-node' "$ROOT/src" | grep -v '^[^:]*:[0-9]*:#' | grep -q . || fail "tsem must never touch --advertise-exit-node"
}

# --- RC3.1: the peer answers but the Internet through it does not (found on the GL-MT3000) ---------

test_reachable_peer_without_egress_is_never_accepted() {
	mkdir -p "$TSEM_MOCK_DIR/egress_fail"; : >"$TSEM_MOCK_DIR/egress_fail/$P1"
	_m=$(ev_seq)
	go_german 24
	# P1 answers (reach ok) but has no egress: it may be tried, never accepted; P2 carries the traffic
	assert_eq state SECONDARY_ACTIVE "$(st state)"
	assert_eq exit "$P2" "$(mexit)"
	# the unselected primary still answers ping: "ok" there is reachability only, and status says so
	assert_eq primary_probe reach "$(st primary_probe)"
	assert_eq secondary_probe egress "$(st secondary_probe)"
	assert_never_open_after "$_m"
}

test_no_egress_through_any_peer_means_blocked_never_direct() {
	mkdir -p "$TSEM_MOCK_DIR/egress_fail"; : >"$TSEM_MOCK_DIR/egress_fail/$P1"; : >"$TSEM_MOCK_DIR/egress_fail/$P2"
	_m=$(ev_seq)
	go_german 40
	case $(st state) in BLOCKED | CONNECTING_PRIMARY | CONNECTING_SECONDARY) ;; *) fail "state $(st state) with no egress anywhere" ;; esac
	assert_eq guard blocked "$(guard)"
	assert_eq kill_switch true "$(st kill_switch_active)"
	assert_never_open_after "$_m"
}

test_rejection_reason_is_logged_once_per_change() {
	export TSEM_PRIMARY_NAME=exit-a TSEM_SECONDARY_NAME=exit-b
	mkdir -p "$TSEM_MOCK_DIR/node_bad"; : >"$TSEM_MOCK_DIR/node_bad/$P1"
	tsem set german --no-wait >/dev/null 2>&1
	_o1=$(tsem tick 2>&1); export TSEM_NOW=$((TSEM_NOW + 5))
	_o2=$(tsem tick 2>&1)
	assert_contains reason "probe primary: rejected: mock: node failed verification" "$_o1"
	case $_o2 in *"probe primary: rejected"*) fail "the same verdict must not be logged again in the next round" ;; esac
}

test_egress_failure_is_logged_with_its_class() {
	mkdir -p "$TSEM_MOCK_DIR/egress_fail"; : >"$TSEM_MOCK_DIR/egress_fail/$P1"
	tsem set german --no-wait >/dev/null 2>&1
	_all=''
	_i=0
	while [ "$_i" -lt 6 ]; do _all="$_all$(tsem tick 2>&1)"; export TSEM_NOW=$((TSEM_NOW + 5)); _i=$((_i + 1)); done
	assert_contains egress "probe primary: egress FAILED through exit node $P1:" "$_all"
}

test_auto_return_off_stays_on_secondary_until_it_fails() {
	export TSEM_AUTO_RETURN=0
	mdown "$P1"
	go_german 16
	assert_eq state SECONDARY_ACTIVE "$(st state)"
	mup "$P1"
	tk 40
	assert_eq "no return to the primary" SECONDARY_ACTIVE "$(st state)"
	assert_eq exit "$P2" "$(mexit)"
	# the secondary fails -> the primary is used again (failover still works)
	mdown "$P2"
	tk 20
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_never_open_after 0
}

test_auto_return_on_returns_to_primary() {
	export TSEM_AUTO_RETURN=1
	mdown "$P1"
	go_german 16
	mup "$P1"
	tk 40
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_config_auto_return_is_validated() {
	printf 'TSEM_AUTO_RETURN=2\n' >"$T/c.conf"
	assert_eq default 1 "$(TSEM_CONF=$T/c.conf tsem config get | sed -n 's/^auto_return=//p')"
	printf 'TSEM_AUTO_RETURN=0\n' >"$T/c.conf"
	assert_eq off 0 "$(TSEM_CONF=$T/c.conf tsem config get | sed -n 's/^auto_return=//p')"
}

test_status_reports_the_node_names_from_the_configuration_for_the_active_exit() {
	export TSEM_PRIMARY_NAME=exit-a TSEM_SECONDARY_NAME=exit-b
	assert_eq none_before none "$(st active_exit_name)"
	assert_eq primary_name exit-a "$(st primary_name)"
	assert_eq secondary_name exit-b "$(st secondary_name)"
	go_german 16
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq active_name exit-a "$(st active_exit_name)"
	assert_eq json_name exit-a "$(tsem status --json | sed -n 's/.*"active_exit_name":"\([^"]*\)".*/\1/p')"
}
