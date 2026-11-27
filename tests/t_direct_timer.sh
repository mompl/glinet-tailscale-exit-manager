# shellcheck shell=sh
# Temporary DIRECT ("1 hour, then back"): the controller itself brings the router back, the timer is bound to the DIRECT intent it was
# started with (any later action of the user voids it), and every doubt ends in the PROTECTED direction.

test_direct_for_returns_to_exit_by_itself_when_the_time_is_over() {
	go_german
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	_t0=$TSEM_NOW
	tsem set direct --for 30m >/dev/null 2>&1
	assert_eq mode direct "$(st mode)"
	assert_eq until $((_t0 + 1800)) "$(st direct_until)"
	assert_eq return german "$(st direct_return)"
	assert_eq guard open "$(guard)"
	tk 20
	assert_eq "still DIRECT before the time is over" direct "$(st mode)"
	export TSEM_NOW=$((_t0 + 1805))
	tk 10
	assert_eq "back in the exit mode" german "$(st mode)"
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq "timer is gone" 0 "$(st direct_until)"
	assert_eq source timer "$(st source)"
}

test_direct_for_returns_to_the_mode_it_came_from_blocked_stays_blocked() {
	tsem set blocked --no-wait >/dev/null 2>&1; tk 4
	_t0=$TSEM_NOW
	tsem set direct --for 1h >/dev/null 2>&1
	assert_eq return blocked "$(st direct_return)"
	export TSEM_NOW=$((_t0 + 3700))
	tk 6
	assert_eq mode blocked "$(st mode)"
	assert_eq guard blocked "$(guard)"
}

test_any_later_action_of_the_user_voids_the_timer() {
	go_german
	_t0=$TSEM_NOW
	tsem set direct --for 30m >/dev/null 2>&1
	tsem set blocked --no-wait >/dev/null 2>&1
	assert_eq "timer is not shown for another mode" 0 "$(st direct_until)"
	tsem set direct >/dev/null 2>&1
	assert_eq "plain DIRECT has no timer" 0 "$(st direct_until)"
	export TSEM_NOW=$((_t0 + 7200))
	tk 8
	assert_eq "stays DIRECT: nothing switches back by surprise" direct "$(st mode)"
	assert_eq guard open "$(guard)"
}

test_plain_direct_again_removes_a_running_timer_and_for_again_restarts_it() {
	go_german
	_t0=$TSEM_NOW
	tsem set direct --for 1h >/dev/null 2>&1
	tsem set direct --for 2h >/dev/null 2>&1
	assert_eq "restarted" $((_t0 + 7200)) "$(st direct_until)"
	assert_eq "the first return mode is kept" german "$(st direct_return)"
	tsem set direct >/dev/null 2>&1
	assert_eq removed 0 "$(st direct_until)"
	export TSEM_NOW=$((_t0 + 9000))
	tk 8
	assert_eq "stays DIRECT" direct "$(st mode)"
}

test_when_the_clock_goes_backwards_the_router_returns_to_protection() {
	go_german
	tsem set direct --for 1h >/dev/null 2>&1
	export TSEM_NOW=$((TSEM_NOW - 7200))
	tk 10
	assert_eq "a clock that cannot be trusted ends DIRECT" german "$(st mode)"
}

test_without_a_primary_the_return_goes_to_blocked_never_to_an_open_state() {
	export TSEM_PRIMARY=''
	_t0=$TSEM_NOW
	tsem set direct --for 10m >/dev/null 2>&1
	assert_eq return blocked "$(st direct_return)"
	export TSEM_NOW=$((_t0 + 700))
	tk 6
	assert_eq mode blocked "$(st mode)"
}

test_direct_for_refuses_bad_durations_and_other_modes_and_changes_nothing() {
	go_german
	_i=$(isum)
	for _a in "direct --for 0" "direct --for 25h" "direct --for abc" "direct --for 1441" "direct --for" "direct --for -5m" "direct --for 5s" "blocked --for 5m" "exit --for 5m"; do
		# shellcheck disable=SC2086
		if tsem set $_a >/dev/null 2>&1; then fail "must be refused: $_a"; fi
		assert_eq "intent untouched after: $_a" "$_i" "$(isum)"
	done
	assert_eq mode german "$(st mode)"
	tsem set direct --for 24h >/dev/null 2>&1 || fail "24 hours is allowed"
	tsem set direct --for 1m >/dev/null 2>&1 || fail "one minute is allowed"
}

test_a_damaged_timer_file_is_ignored_and_never_switches_anything() {
	go_german
	tsem set direct --for 1h >/dev/null 2>&1
	printf 'until=banana\nreturn=direct\nseq=x\n' >"$TSEM_STATE_DIR/direct_until"
	assert_eq "not shown" 0 "$(st direct_until)"
	export TSEM_NOW=$((TSEM_NOW + 9000))
	tk 8
	assert_eq "stays DIRECT (a damaged file is no instruction)" direct "$(st mode)"
}

test_status_json_carries_the_timer() {
	go_german
	_t0=$TSEM_NOW
	tsem set direct --for 45m >/dev/null 2>&1
	assert_contains until "\"direct_until\":$((_t0 + 2700))" "$(tsem status --json)"
	assert_contains ret '"direct_return":"german"' "$(tsem status --json)"
	assert_contains none '"direct_until":0' "$(tsem set german --no-wait >/dev/null 2>&1; tsem status --json)"
}
