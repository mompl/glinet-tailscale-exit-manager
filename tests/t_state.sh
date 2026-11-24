# shellcheck shell=sh
# Intent storage, "last user action wins", fail-closed on bad intent.

test_set_german_writes_valid_intent() {
	tsem set german --no-wait --source hw || fail "set failed"
	assert_eq mode german "$(st mode)"
	assert_eq source hw "$(st source)"
	assert_eq seq 1 "$(st seq)"
	assert_eq intent ok "$(st intent)"
	[ "$(grep -c '^crc=' "$TSEM_STATE_DIR/intent")" -eq 1 ] || fail "crc line missing"
}

test_intent_file_mode_is_private() {
	tsem set german --no-wait
	_m=$(stat -c %a "$TSEM_STATE_DIR/intent")
	assert_eq mode 600 "$_m"
}

test_same_mode_is_no_change() {
	tsem set german --no-wait
	_s=$(isum)
	tsem set german --no-wait --source ha
	assert_eq unchanged "$_s" "$(isum)"
	assert_eq seq 1 "$(st seq)"
}

test_last_action_wins() {
	tsem set german --no-wait --source hw
	tsem set direct --no-wait --source ha
	tsem set german --no-wait --source cli
	assert_eq mode german "$(st mode)"
	assert_eq seq 3 "$(st seq)"
	assert_eq source cli "$(st source)"
}

test_readers_never_write_intent() {
	tsem set german --no-wait
	_s=$(isum)
	tsem status >/dev/null; tsem status --json >/dev/null; tk 6; tsem boot; tsem reapply; tsem diag >/dev/null 2>&1
	assert_eq "intent untouched" "$_s" "$(isum)"
}

test_restart_does_not_replay_old_switch_position() {
	# HA/hardware turned it OFF last; a later boot must not resurrect an older ON.
	tsem set german --no-wait --source hw
	tsem set direct --no-wait --source ha
	rm -rf "$TSEM_RUN_DIR"/failover "$TSEM_MOCK_DIR"/guard
	tsem boot
	assert_eq mode direct "$(st mode)"
	assert_eq guard open "$(guard)"
}

test_tampered_intent_is_blocked_not_direct() {
	tsem set german --no-wait
	sed -i 's/^mode=german/mode=direct/' "$TSEM_STATE_DIR/intent"
	assert_eq intent invalid "$(st intent)"
	tsem boot
	assert_eq guard blocked "$(guard)"
	tk 3
	assert_eq guard blocked "$(guard)"
	assert_eq state BLOCKED "$(st state)"
}

test_missing_intent_is_blocked_not_direct() {
	tsem boot
	assert_eq guard blocked "$(guard)"
	tk 3
	assert_eq guard blocked "$(guard)"
	assert_eq intent missing "$(st intent)"
}

test_corrupt_intent_garbage() {
	tsem set german --no-wait
	printf 'garbage\n' >"$TSEM_STATE_DIR/intent"
	assert_eq intent invalid "$(st intent)"
	tsem boot
	assert_eq guard blocked "$(guard)"
}

test_invalid_arguments_rejected() {
	assert_rc "bad mode" 1 tsem set bogus
	assert_rc "bad source" 1 tsem set direct --source 'a b'
	assert_rc "bad source2" 1 tsem set direct --source 'A;rm'
	assert_rc "no args" 1 tsem set
	assert_rc "unknown opt" 1 tsem set direct --bogus
	assert_rc "unknown cmd" 2 tsem frobnicate
}

test_explicit_blocked_mode_closes_the_guard_and_stays_closed() {
	go_german
	tsem set blocked --no-wait --source gui || fail "set blocked failed"
	assert_eq mode blocked "$(st mode)"
	assert_eq guard blocked "$(guard)"
	assert_eq state BLOCKED "$(st state)"
	assert_eq ks true "$(st kill_switch_active)"
	tk 8
	assert_eq "still blocked after ticks" blocked "$(guard)"
	tsem boot; tsem reapply
	assert_eq "still blocked after boot/reapply" blocked "$(guard)"
	assert_eq "no failover/exit activity makes it open" blocked "$(guard)"
}

test_blocked_never_turns_into_direct_and_leaving_it_is_explicit() {
	go_german
	tsem set blocked --no-wait
	for _i in 1 2 3; do tk 3; tsem reapply; done
	[ "$(guard)" != open ] || fail "BLOCKED opened the guard"
	tsem set direct --no-wait
	assert_eq guard open "$(guard)"
	tsem set blocked --no-wait
	assert_eq guard blocked "$(guard)"
	tsem set german --no-wait
	assert_eq mode german "$(st mode)"
	[ "$(guard)" != open ] || fail "GERMAN came up open"
}

test_blocked_intent_survives_tampering_checks_and_rpc_accepts_it() {
	tsem set blocked --no-wait
	assert_eq intent ok "$(st intent)"
	grep -q 'blocked' "$ROOT/src/usr/libexec/rpcd/tsem" || fail "rpcd does not know blocked"
	grep -q 'confirmation_required' "$ROOT/src/usr/libexec/rpcd/tsem"
	tsem set bogus --no-wait 2>/dev/null && fail "bogus mode accepted"
	assert_eq mode blocked "$(st mode)"
}

test_german_needs_primary() {
	unset TSEM_PRIMARY
	assert_rc "no primary" 2 tsem set german
	[ ! -e "$TSEM_STATE_DIR/intent" ] || fail "intent written without primary"
}

test_concurrent_sets_keep_intent_consistent() {
	for i in 1 2 3 4 5 6 7 8; do
		if [ $((i % 2)) -eq 0 ]; then tsem set direct --no-wait --source ha & else tsem set german --no-wait --source hw & fi
	done
	wait
	assert_eq intent ok "$(st intent)"
	_j=$(tail -n 1 "$TSEM_RUN_DIR/journal" | cut -d' ' -f1)
	assert_eq "seq equals journal" "$_j" "$(st seq)"
	_m=$(st mode)
	assert_eq "guard matches intent" "$([ "$_m" = direct ] && echo open || echo blocked)" "$(guard)"
}

test_journal_is_bounded() {
	_i=0
	while [ $_i -lt 260 ]; do
		tsem set german --no-wait; tsem set direct --no-wait; _i=$((_i + 2))
	done
	[ "$(wc -l <"$TSEM_RUN_DIR/journal")" -le 501 ] || fail "journal grew unbounded"
}
