# shellcheck shell=sh
# GL.iNet hardware-switch hook (contrib/tsem-switch.sh).

hook_setup() {
	printf '#!/bin/sh\nexec %s %s "$@"\n' "$SH" "$ROOT/src/usr/sbin/tsem" >"$T/tsem-wrap"; chmod +x "$T/tsem-wrap"
	export TSEM_BIN=$T/tsem-wrap TSEM_HOOK_MODE_FILE=$T/hook.mode
	# the hook is fire-and-forget; wait for the background job
}
hook() { "$SH" "$ROOT/contrib/tsem-switch.sh" "$@"; sleep 0.5; }

test_hook_on_off() {
	hook_setup
	hook on
	assert_eq mode german "$(st mode)"; assert_eq source hw "$(st source)"
	hook off
	assert_eq mode direct "$(st mode)"; assert_eq guard open "$(guard)"
}

test_hook_unknown_input_changes_nothing() {
	hook_setup; tsem set german --no-wait; _s=$(isum)
	hook pressed; hook ""; hook "on;reboot"
	assert_eq untouched "$_s" "$(isum)"
}

test_hook_trace_mode_changes_nothing() {
	hook_setup; echo trace >"$TSEM_HOOK_MODE_FILE"
	hook on
	[ ! -e "$TSEM_STATE_DIR/intent" ] || fail "trace mode must not change state"
}

test_hook_uses_action_env() {
	hook_setup
	ACTION=on hook
	assert_eq mode german "$(st mode)"
}

test_hook_never_touches_firewall_or_tailscale_directly() {
	! grep -nE 'iptables|ip6tables|nft|tailscale|ip (rule|route)' "$ROOT/contrib/tsem-switch.sh" | grep -v '^[0-9]*:#' | grep -q . || fail "hook must only call tsem"
}

test_rapid_hook_toggling() {
	hook_setup
	_i=0; while [ $_i -lt 10 ]; do "$SH" "$ROOT/contrib/tsem-switch.sh" on; "$SH" "$ROOT/contrib/tsem-switch.sh" off; _i=$((_i + 1)); done
	"$SH" "$ROOT/contrib/tsem-switch.sh" on
	sleep 1.5
	assert_eq intent ok "$(st intent)"
	assert_eq mode german "$(st mode)"
}

# --- RC3.1: switch events against every controller state -------------------------------------------

test_hook_direct_event_while_blocked_restores_wan_and_clears_the_exit_node() {
	hook_setup
	mdown "$P1"; mdown "$P2"
	tsem set german --no-wait >/dev/null 2>&1; tk 10
	assert_eq state BLOCKED "$(st state)"; assert_eq guard blocked "$(guard)"
	hook off
	assert_eq mode direct "$(st mode)"; assert_eq source hw "$(st source)"
	assert_eq guard open "$(guard)"; assert_eq exit none "$(mexit)"
	assert_eq ks false "$(st kill_switch_active)"
}

test_hook_german_event_while_direct_is_fail_closed_until_an_exit_node_is_verified() {
	hook_setup
	tsem set direct --no-wait >/dev/null 2>&1
	hook on
	assert_eq mode german "$(st mode)"; assert_eq source hw "$(st source)"
	assert_eq guard blocked "$(guard)" # recorded and closed at once, no probing in the hook
	assert_eq exit none "$(mexit)"
	_m=$(ev_seq)
	tk 12
	assert_eq state PRIMARY_ACTIVE "$(st state)"; assert_eq guard german "$(guard)"
	assert_never_open_after "$_m"
}

test_hook_german_event_with_both_nodes_down_stays_blocked_never_direct() {
	hook_setup
	mdown "$P1"; mdown "$P2"
	tsem set direct --no-wait >/dev/null 2>&1
	hook on; _m=$(ev_seq); tk 20
	assert_eq mode german "$(st mode)"; assert_eq guard blocked "$(guard)"
	assert_never_open_after "$_m"
}

test_repeated_and_doubled_hook_events_are_idempotent() {
	hook_setup
	hook on; _s1=$(st seq); _i1=$(isum)
	hook on; hook on
	assert_eq seq "$_s1" "$(st seq)"; assert_eq intent "$_i1" "$(isum)"
	hook off; _s2=$(st seq); hook off
	assert_eq seq "$_s2" "$(st seq)"
	assert_eq mode direct "$(st mode)"
}

test_every_mode_request_is_logged_with_source_and_result() {
	hook_setup
	_o=$(tsem set german --source hw --no-wait 2>&1)
	assert_contains log "set german requested by source=hw changed=1" "$_o"
	_o=$(tsem set german --source ha --no-wait 2>&1)
	assert_contains again "set german requested by source=ha changed=0" "$_o"
	_o=$(tsem set direct --source hw --no-wait 2>&1)
	assert_contains direct "set direct requested by source=hw changed=1 apply_rc=0" "$_o"
}

test_hook_records_the_reported_position_and_status_shows_it_as_event_not_as_a_reading() {
	hook_setup
	assert_eq before unknown "$(st hw_state)"
	assert_eq src-none none "$(st hw_source)"
	hook on
	assert_eq on on "$(st hw_state)"
	assert_eq src event "$(st hw_source)"
	assert_eq match yes "$(st hw_match)"
	[ "$(st hw_event_ts)" -gt 0 ] || fail "event time missing"
	hook off
	assert_eq off off "$(st hw_state)"
	assert_eq match yes "$(st hw_match)"
	# a mode change from elsewhere (GUI/API) makes the last reported position differ: shown, not hidden
	tsem set german --source gui --no-wait
	assert_eq differs no "$(st hw_match)"
	assert_eq source gui "$(st source)"
}

test_hook_trace_and_unknown_input_do_not_record_a_position() {
	hook_setup
	hook pressed
	assert_eq none unknown "$(st hw_state)"
	echo trace >"$TSEM_HOOK_MODE_FILE"; hook on
	assert_eq none unknown "$(st hw_state)"
}

test_a_configured_state_file_wins_over_the_event_record() {
	hook_setup
	hook on
	echo off >"$T/hwfile"
	assert_eq file off "$(TSEM_HW_STATE_FILE=$T/hwfile st hw_state)"
	assert_eq src file "$(TSEM_HW_STATE_FILE=$T/hwfile st hw_source)"
}

test_hook_and_api_and_gui_mode_changes_never_race_into_a_corrupt_intent() {
	hook_setup
	_api=$ROOT/src/usr/libexec/rpcd/tsem
	i=0
	while [ "$i" -lt 8 ]; do
		case $((i % 3)) in
		0) "$SH" "$ROOT/contrib/tsem-switch.sh" on >/dev/null 2>&1 & ;;
		1) "$TSEM_BIN" set direct --source gui --no-wait >/dev/null 2>&1 & ;;
		2) "$TSEM_BIN" set german --source ha --no-wait >/dev/null 2>&1 & ;;
		esac
		i=$((i + 1))
	done
	wait
	assert_rc intent-valid 0 tsem intent-check
	case $(st mode) in german | direct) ;; *) fail "mode '$(st mode)'" ;; esac
	[ -f "$_api" ] || fail "api missing"
}

# ------------------------------------------------------------------ F04: position source, persistence, reconstruction
test_f04_hook_accepts_the_lowercase_action_variable() {
	hook_setup
	action=on hook
	assert_eq mode german "$(st mode)"
	action=off hook
	assert_eq mode direct "$(st mode)"
	hook_setup; ACTION=released hook
	assert_eq nochange direct "$(st mode)"
}

test_f04_last_position_survives_a_reboot_and_is_marked_persisted() {
	hook_setup
	hook on
	assert_eq src-event event "$(st hw_source)"
	assert_eq hw on "$(st hw_state)"
	[ -s "$TSEM_STATE_DIR/hw_last" ] || fail "no persistent record of the last position"
	assert_eq fields 3 "$(wc -w <"$TSEM_STATE_DIR/hw_last" | tr -d ' ')"
	# reboot: the tmpfs record is gone, the flash record stays
	rm -f "$TSEM_RUN_DIR/hw_event"
	assert_eq src-persisted persisted "$(st hw_source)"
	assert_eq hw-after-boot on "$(st hw_state)"
	assert_eq match yes "$(st hw_match)"
	# the switch moved while the router was off: the persisted position is outdated; the mismatch is SHOWN, never silently resolved
	printf '%s off bootx\n' "$(date +%s)" >"$TSEM_STATE_DIR/hw_last"
	assert_eq mismatch no "$(st hw_match)"
	assert_eq mode-unchanged german "$(st mode)"
	# an event after the boot wins over the persisted record
	hook on
	assert_eq src-event-again event "$(st hw_source)"
}

test_f04_never_reported_position_is_unknown_not_guessed() {
	hook_setup
	tsem set german --no-wait
	assert_eq state unknown "$(st hw_state)"
	assert_eq source none "$(st hw_source)"
	assert_eq match unknown "$(st hw_match)"
}

test_f04_gpio_reader_reads_the_position_and_wins_over_events() {
	hook_setup
	printf '1\n' >"$T/gpio_value"
	export TSEM_HW_GPIO_VALUE=$T/gpio_value TSEM_HW_GPIO_ON=1
	tsem set german --no-wait
	assert_eq hw on "$(st hw_state)"; assert_eq src gpio "$(st hw_source)"; assert_eq match yes "$(st hw_match)"
	printf '0\n' >"$T/gpio_value"
	assert_eq hw-off off "$(st hw_state)"; assert_eq match-no no "$(st hw_match)"
	# active-low wiring
	export TSEM_HW_GPIO_ON=0
	assert_eq inverted on "$(st hw_state)"
	# an unreadable or garbage value is unknown, never a position
	printf 'xyz\n' >"$T/gpio_value"; unset TSEM_HW_STATE_FILE
	assert_eq garbage unknown "$(st hw_state)"
	unset TSEM_HW_GPIO_VALUE TSEM_HW_GPIO_ON
}

# ---- the firmware replays the switch position at every boot: policy "last" (default) vs "switch"
test_boot_replay_of_an_unchanged_switch_position_keeps_the_stored_mode_by_default() {
	hook_setup
	TSEM_BOOT_ID=boot1 hook off          # before the reboot: switch off, then the user chose the exit mode in the GUI
	tsem set german --no-wait
	assert_eq mode german "$(st mode)"
	TSEM_BOOT_ID=boot2 hook off          # after the reboot the firmware reports "off" again: a replay
	assert_eq "stored mode kept" german "$(st mode)"
	assert_contains recorded "boot2" "$(cat "$TSEM_STATE_DIR/hw_last")"
	# afterwards (same boot) a real flip is applied at once, and so is the next "off"
	TSEM_BOOT_ID=boot2 hook on;  assert_eq on german "$(st mode)"
	TSEM_BOOT_ID=boot2 hook off; assert_eq off direct "$(st mode)"
}

test_boot_event_with_a_moved_switch_is_applied() {
	hook_setup
	TSEM_BOOT_ID=boot1 hook off
	TSEM_BOOT_ID=boot2 hook on           # flipped while the router was off: differs from the last known position
	assert_eq "real flip applied" german "$(st mode)"
}

test_policy_switch_makes_the_boot_position_win_even_when_unchanged() {
	hook_setup
	tsem config set TSEM_HW_AT_BOOT=switch >/dev/null || fail "cannot set the policy"
	TSEM_BOOT_ID=boot1 hook off
	tsem set german --no-wait
	TSEM_BOOT_ID=boot2 hook off
	assert_eq "switch wins" direct "$(st mode)"
}

test_first_ever_event_has_nothing_to_compare_and_is_applied() {
	hook_setup
	rm -f "$TSEM_STATE_DIR/hw_last"
	TSEM_BOOT_ID=boot9 hook off
	assert_eq mode direct "$(st mode)"
}

test_hw_at_boot_is_a_validated_setting() {
	hook_setup
	tsem config set TSEM_HW_AT_BOOT=bogus >/dev/null 2>&1 && fail "invalid value accepted"
	assert_eq default last "$(tsem hw-policy)"
	tsem config set TSEM_HW_AT_BOOT=switch >/dev/null || fail "switch refused"
	assert_eq stored switch "$(tsem hw-policy)"
}
