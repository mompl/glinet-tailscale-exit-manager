# shellcheck shell=sh
# History and report: how long was the router in which mode, failovers, BLOCKED episodes, restarts; the weekly message.

_rep_hist() { printf '%s\n' "$@" >"$TSEM_STATE_DIR/history"; }
_rj() { tsem report --json "$@"; }
_jn() { printf '%s' "$1" | sed -n "s/.*\"$2\":\([0-9]*\).*/\1/p" | head -n1; }

test_history_records_state_changes_once_and_marks_the_boot() {
	go_german
	_h=$(cat "$TSEM_STATE_DIR/history")
	assert_contains boot "|BOOT" "$_h"
	assert_contains primary "|PRIMARY_ACTIVE" "$_h"
	_n=$(wc -l <"$TSEM_STATE_DIR/history")
	tk 10
	assert_eq "steady ticks add nothing" "$_n" "$(wc -l <"$TSEM_STATE_DIR/history")"
	mdown "$P1"; tk 10
	assert_contains failover "|SECONDARY_ACTIVE" "$(cat "$TSEM_STATE_DIR/history")"
	tsem set blocked --no-wait >/dev/null 2>&1
	tsem set direct >/dev/null 2>&1
	_h=$(cat "$TSEM_STATE_DIR/history")
	assert_contains blocked "|BLOCKED" "$_h"
	assert_contains direct "|DISABLED" "$_h"
}

test_history_ignores_a_clock_that_is_not_set_yet() {
	export TSEM_NOW=1000
	go_german
	[ ! -s "$TSEM_STATE_DIR/history" ] || fail "nothing may be recorded before the clock is set: $(cat "$TSEM_STATE_DIR/history")"
}

test_report_adds_up_the_time_in_every_mode_and_counts_the_episodes() {
	_t=$TSEM_NOW
	_rep_hist "$((_t - 200000))|BOOT" "$((_t - 200000))|PRIMARY_ACTIVE" "$((_t - 100000))|SECONDARY_ACTIVE" "$((_t - 50000))|BLOCKED" "$((_t - 49400))|PRIMARY_ACTIVE"
	_j=$(_rj)
	assert_eq exit 149400 "$(printf '%s' "$_j" | sed -n 's/.*"exit":\([0-9]*\).*/\1/p')"
	assert_eq backup 50000 "$(printf '%s' "$_j" | sed -n 's/.*"backup":\([0-9]*\).*/\1/p')"
	assert_eq blocked 600 "$(printf '%s' "$_j" | sed -n 's/.*"blocked":\([0-9]*\).*/\1/p')"
	assert_eq tracked 200000 "$(_jn "$_j" tracked)"
	assert_eq failovers 1 "$(_jn "$_j" failovers)"
	assert_eq episodes 1 "$(_jn "$_j" blocked_episodes)"
	assert_eq longest 600 "$(_jn "$_j" longest_blocked)"
	assert_eq restarts 1 "$(_jn "$_j" restarts)"
	_o=$(tsem report)
	assert_contains txt "backup exit node" "$_o"
	assert_contains txt2 "BLOCKED" "$_o"
	assert_contains txt3 "failovers: 1" "$_o"
}

test_report_cuts_the_period_and_counts_only_events_inside_it() {
	_t=$TSEM_NOW
	_rep_hist "$((_t - 200000))|BOOT" "$((_t - 200000))|PRIMARY_ACTIVE" "$((_t - 100000))|SECONDARY_ACTIVE" "$((_t - 50000))|BLOCKED" "$((_t - 49400))|PRIMARY_ACTIVE"
	_j=$(_rj --days 1)
	assert_eq exit 49400 "$(printf '%s' "$_j" | sed -n 's/.*"exit":\([0-9]*\).*/\1/p')"
	assert_eq "backup is cut at the start of the period" 36400 "$(printf '%s' "$_j" | sed -n 's/.*"backup":\([0-9]*\).*/\1/p')"
	assert_eq "the failover happened before the period" 0 "$(_jn "$_j" failovers)"
	assert_eq "the BLOCKED episode is inside it" 1 "$(_jn "$_j" blocked_episodes)"
	assert_eq restarts 0 "$(_jn "$_j" restarts)"
}

test_report_does_not_count_the_time_the_router_was_off_as_a_mode() {
	_t=$TSEM_NOW
	_rep_hist "$((_t - 100000))|BOOT" "$((_t - 100000))|PRIMARY_ACTIVE" "$((_t - 60000))|DOWN" "$((_t - 50000))|BOOT" "$((_t - 50000))|PRIMARY_ACTIVE"
	_j=$(_rj)
	assert_eq exit 90000 "$(printf '%s' "$_j" | sed -n 's/.*"exit":\([0-9]*\).*/\1/p')"
	assert_eq off 10000 "$(printf '%s' "$_j" | sed -n 's/.*"off":\([0-9]*\).*/\1/p')"
	assert_eq restarts 2 "$(_jn "$_j" restarts)"
}

test_report_counts_direct_time_and_episodes() {
	_t=$TSEM_NOW
	_rep_hist "$((_t - 10000))|BOOT" "$((_t - 10000))|PRIMARY_ACTIVE" "$((_t - 7200))|DISABLED" "$((_t - 6000))|PRIMARY_ACTIVE" "$((_t - 3000))|DISABLED" "$((_t - 2400))|PRIMARY_ACTIVE"
	_j=$(_rj)
	assert_eq direct 1800 "$(printf '%s' "$_j" | sed -n 's/.*"direct":\([0-9]*\).*/\1/p')"
	assert_eq episodes 2 "$(_jn "$_j" direct_episodes)"
}

test_report_without_data_says_so_and_bad_arguments_are_refused() {
	assert_contains none "not enough data" "$(tsem report)"
	for _a in "--days 0" "--days 91" "--days abc" "--days" "--bogus" "--days 7x"; do
		# shellcheck disable=SC2086
		if tsem report $_a >/dev/null 2>&1; then fail "must be refused: $_a"; fi
	done
}

_rep_stub() {
	mkdir -p "$T/bin"
	printf '#!/bin/sh\nprintf "%%s\n" "$*" >>"%s/notify.calls"\n' "$T" >"$T/bin/tsem-notify"; chmod +x "$T/bin/tsem-notify"
	export TSEM_NOTIFY_BIN=$T/bin/tsem-notify TSEM_NOTIFY_CONF=$T/notify.conf
	printf 'NOTIFY_URL=https://ntfy.example/t\nNOTIFY_EVENTS="%s"\n' "$1" >"$T/notify.conf"
}

test_report_notify_sends_one_line_with_the_numbers() {
	_rep_stub "failover blocked"
	_t=$TSEM_NOW
	_rep_hist "$((_t - 200000))|BOOT" "$((_t - 200000))|PRIMARY_ACTIVE" "$((_t - 100000))|SECONDARY_ACTIVE" "$((_t - 50000))|BLOCKED" "$((_t - 49400))|PRIMARY_ACTIVE"
	tsem report --notify >/dev/null 2>&1 || fail "report --notify failed"
	_c=$(grep '^report ' "$T/notify.calls")
	assert_contains lead "week report (7 d)" "$_c"
	assert_contains fo "1 failover(s)" "$_c"
	assert_contains blocked "BLOCKED 10m (1 x)" "$_c"
	assert_eq "one line" 1 "$(printf '%s\n' "$_c" | wc -l | tr -d ' ')"
}

test_the_weekly_report_is_sent_by_the_controller_only_when_the_event_is_listed() {
	_rep_stub "failover blocked report"
	tsem tick >/dev/null 2>&1
	[ -s "$TSEM_STATE_DIR/report_last" ] || fail "the first tick must start the week"
	_t0=$(cat "$TSEM_STATE_DIR/report_last")
	export TSEM_NOW=$((TSEM_NOW + 3 * 86400)); tsem tick >/dev/null 2>&1; sleep 1
	grep -q '^report ' "$T/notify.calls" 2>/dev/null && fail "too early: after 3 days nothing may be sent"
	export TSEM_NOW=$((TSEM_NOW + 5 * 86400)); tsem tick >/dev/null 2>&1; sleep 1
	assert_eq "sent once after a week" 1 "$(grep -c '^report ' "$T/notify.calls")"
	[ "$(cat "$TSEM_STATE_DIR/report_last")" -gt "$_t0" ] || fail "report_last must move forward"
	export TSEM_NOW=$((TSEM_NOW + 3600)); tsem tick >/dev/null 2>&1; sleep 1
	assert_eq "not again the next hour" 1 "$(grep -c '^report ' "$T/notify.calls")"
}

test_no_weekly_report_without_the_event_in_the_message_settings() {
	_rep_stub "failover blocked"
	tsem tick >/dev/null 2>&1
	export TSEM_NOW=$((TSEM_NOW + 30 * 86400)); tsem tick >/dev/null 2>&1; sleep 1
	grep -q '^report ' "$T/notify.calls" 2>/dev/null && fail "the report is opt-in: it must not be sent"
	true
}

test_a_router_that_stays_in_direct_or_blocked_over_a_reboot_is_in_the_history_too() {
	# the mode comes from the stored intent, nobody calls tsem set after the boot: only the tick can write the state
	tsem set direct >/dev/null 2>&1
	rm -f "$TSEM_STATE_DIR/history" "$TSEM_RUN_DIR/booted" "$TSEM_RUN_DIR/hist_started" "$TSEM_RUN_DIR/hourly"
	tk 2
	_h=$(cat "$TSEM_STATE_DIR/history")
	assert_contains boot "|BOOT" "$_h"
	assert_contains direct "|DISABLED" "$_h"
	_n=$(wc -l <"$TSEM_STATE_DIR/history")
	tk 6
	assert_eq "steady ticks add nothing" "$_n" "$(wc -l <"$TSEM_STATE_DIR/history")"
	export TSEM_NOW=$((TSEM_NOW + 3600))
	assert_contains tracked "DIRECT" "$(tsem report)"
	[ "$(_jn "$(_rj)" direct)" -ge 3600 ] || fail "the hour in DIRECT must be counted"
	tsem set blocked --no-wait >/dev/null 2>&1
	rm -f "$TSEM_STATE_DIR/history" "$TSEM_RUN_DIR/booted" "$TSEM_RUN_DIR/hist_started" "$TSEM_RUN_DIR/hourly"
	tk 2
	assert_contains blocked "|BLOCKED" "$(cat "$TSEM_STATE_DIR/history")"
}
