# shellcheck shell=sh
# The exit nodes are an ordered list: failover walks down the ranks, auto-return goes back to the best healthy rank,
# the older two-key configuration keeps working, and config set keeps list and older keys equal.

P3=100.64.0.12
P4=100.64.0.13

_three() { export TSEM_NODES="$P1 $P2 $P3"; }

test_three_nodes_fail_over_down_the_list_and_block_only_when_all_are_down() {
	_three
	go_german
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	assert_eq rank 1 "$(st active_rank)"
	assert_eq nodes 3 "$(st nodes)"
	_m=$(ev_seq)
	mdown $P1; tk 10
	assert_eq state SECONDARY_ACTIVE "$(st state)"
	assert_eq exit "$P2" "$(mexit)"
	assert_eq rank 2 "$(st active_rank)"
	mdown $P2; tk 10
	assert_eq "rank 3 is a fallback too" SECONDARY_ACTIVE "$(st state)"
	assert_eq exit "$P3" "$(mexit)"
	assert_eq rank 3 "$(st active_rank)"
	assert_eq guard german "$(guard)"
	mdown $P3; tk 10
	assert_eq state BLOCKED "$(st state)"
	assert_eq guard blocked "$(guard)"
	assert_never_open_after "$_m"
}

test_auto_return_goes_to_the_best_healthy_rank_not_just_rank_one() {
	_three
	export TSEM_DWELL=0
	go_german
	mdown $P1; mdown $P2; tk 14
	assert_eq "on rank 3" "$P3" "$(mexit)"
	mup $P2
	tk 14
	assert_eq "back to rank 2 while rank 1 is still down" "$P2" "$(mexit)"
	mup $P1
	tk 14
	assert_eq "back to rank 1" "$P1" "$(mexit)"
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_auto_return_off_keeps_a_fallback_until_it_fails() {
	_three
	export TSEM_DWELL=0 TSEM_AUTO_RETURN=0
	go_german
	mdown $P1; tk 10
	assert_eq "on rank 2" "$P2" "$(mexit)"
	mup $P1; tk 20
	assert_eq "no automatic return" "$P2" "$(mexit)"
}

test_manual_failover_goes_to_the_next_selectable_rank() {
	_three
	go_german
	tsem failover now >/dev/null 2>&1; tk 6
	assert_eq "rank 2" "$P2" "$(mexit)"
	assert_eq secondary SECONDARY_ACTIVE "$(st state)"
}

test_failover_off_uses_only_rank_one() {
	_three
	go_german
	tsem failover off >/dev/null 2>&1
	mdown $P1; tk 12
	assert_eq "never a fallback" BLOCKED "$(st state)"
	assert_eq guard blocked "$(guard)"
}

test_status_lists_every_node_with_its_verdict() {
	_three
	go_german
	mdown $P2; tk 6
	_o=$(tsem status)
	assert_contains n1 "node_1=$P1|" "$_o"
	assert_contains n2 "node_2=$P2|" "$_o"
	assert_contains n3 "node_3=$P3|" "$_o"
	assert_contains j '"node_list":[{"rank":1,' "$(tsem status --json)"
}

test_the_older_two_key_config_is_the_same_as_a_two_node_list() {
	unset TSEM_NODES
	printf 'TSEM_PRIMARY=%s\nTSEM_SECONDARY=%s\nTSEM_PRIMARY_NAME=a\nTSEM_SECONDARY_NAME=b\n' "$P1" "$P2" >"$T/c.conf"
	_o=$(TSEM_PRIMARY='' TSEM_SECONDARY='' TSEM_CONF=$T/c.conf tsem config get)
	unset TSEM_PRIMARY TSEM_SECONDARY
	_o=$(TSEM_CONF=$T/c.conf tsem config get)
	assert_contains p "primary=$P1" "$_o"
	assert_contains s "secondary=$P2" "$_o"
	assert_contains n1 "node_1=$P1|a" "$_o"
	assert_contains n2 "node_2=$P2|b" "$_o"
}

test_config_set_with_a_list_keeps_the_older_keys_equal_to_rank_one_and_two() {
	unset TSEM_NODES TSEM_PRIMARY TSEM_SECONDARY
	: >"$T/c.conf"
	TSEM_CONF=$T/c.conf tsem config set "TSEM_NODES=$P1 $P2 $P3" "TSEM_NODE_NAMES=a - c" >/dev/null || fail "set failed"
	_f=$(cat "$T/c.conf")
	assert_contains list "TSEM_NODES=$P1 $P2 $P3" "$_f"
	assert_contains names "TSEM_NODE_NAMES=a - c" "$_f"
	assert_contains primary "TSEM_PRIMARY=$P1" "$_f"
	assert_contains secondary "TSEM_SECONDARY=$P2" "$_f"
	assert_contains pname "TSEM_PRIMARY_NAME=a" "$_f"
	_o=$(TSEM_CONF=$T/c.conf tsem config get)
	assert_contains n3 "node_3=$P3|c" "$_o"
	# the older keys still edit rank 1 and 2 of the list
	TSEM_CONF=$T/c.conf tsem config set "TSEM_SECONDARY=$P4" >/dev/null || fail "set secondary failed"
	assert_contains moved "TSEM_NODES=$P1 $P4 $P3" "$(cat "$T/c.conf")"
	# removing the secondary removes rank 2 only
	TSEM_CONF=$T/c.conf tsem config set "TSEM_SECONDARY=" >/dev/null || fail "clear secondary failed"
	assert_contains cleared "TSEM_NODES=$P1 $P3" "$(cat "$T/c.conf")"
}

test_config_set_refuses_duplicates_too_many_nodes_and_an_empty_list() {
	unset TSEM_NODES TSEM_PRIMARY TSEM_SECONDARY
	: >"$T/c.conf"
	if TSEM_CONF=$T/c.conf tsem config set "TSEM_NODES=$P1 $P1" >/dev/null 2>&1; then fail "duplicates must be refused"; fi
	_many='100.64.1.1 100.64.1.2 100.64.1.3 100.64.1.4 100.64.1.5 100.64.1.6 100.64.1.7 100.64.1.8 100.64.1.9'
	if TSEM_CONF=$T/c.conf tsem config set "TSEM_NODES=$_many" >/dev/null 2>&1; then fail "more than 8 nodes must be refused"; fi
	if TSEM_CONF=$T/c.conf tsem config set "TSEM_NODES=" >/dev/null 2>&1; then fail "an empty list must be refused"; fi
	if TSEM_CONF=$T/c.conf tsem config set "TSEM_NODES=$P1;reboot" >/dev/null 2>&1; then fail "a hostile value must be refused"; fi
	assert_eq "nothing written" "" "$(cat "$T/c.conf")"
}

test_an_older_running_failover_state_is_read_after_the_upgrade() {
	_three
	go_german
	# the file of the two-node release: cur=secondary, counters with the old key names
	printf 'cur=secondary\nver=1\nokp=0\nfailp=3\noks=9\nfails=0\nlast=1789999000\ndeadp=1790001000\ndeads=0\nbop=60\nbos=30\ndns=skip\nchk=1790000000\nps=fail\nss=ok\npk=egress-fail\nsk=egress\nerr=\n' >"$TSEM_RUN_DIR/failover"
	assert_eq "rank 2" 2 "$(st active_rank)"
	assert_eq state SECONDARY_ACTIVE "$(st state)"
}
