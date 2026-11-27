# shellcheck shell=sh
# Leak test: what the router can measure about its own traffic and rules. A curl stand-in plays the "what is my IP" service.

_lt_setup() {
	mkdir -p "$T/bin"
	printf '203.0.113.5\n' >"$T/ip"; printf '2001:db8::7\n' >"$T/v6.ip"
	cat >"$T/bin/curl" <<CURL
#!/bin/sh
v6=0; for a in "\$@"; do [ "\$a" = -6 ] && v6=1; done
[ -e "$T/curl.down" ] && exit 7
[ "\$v6" = 0 ] && [ -e "$T/curl.rc6" ] && exit 6
if [ "\$v6" = 1 ]; then [ -e "$T/v6.ok" ] || exit 7; ip=\$(cat "$T/v6.ip"); else ip=\$(cat "$T/ip"); fi
printf '{"YourFuckingIPAddress": "%s", "YourFuckingCountry": "Germany", "YourFuckingCountryCode": "DE", "YourFuckingLocation": "Berlin", "YourFuckingISP": "Example", "YourFuckingHostname": "h.example"}' "\$ip"
CURL
	chmod +x "$T/bin/curl"
	export TSEM_CURL=$T/bin/curl TSEM_DNS_REDIRECT=198.51.100.53
}
_lt() { rm -f "$TSEM_RUN_DIR/egress"; tsem leaktest "$@"; }

test_leaktest_in_direct_shows_the_own_address_and_keeps_it_as_the_baseline() {
	_lt_setup
	tsem set direct >/dev/null 2>&1
	_o=$(_lt) || fail "DIRECT is not a failure: $_o"
	assert_contains addr "your own public address is 203.0.113.5" "$_o"
	assert_eq baseline 203.0.113.5 "$(cat "$TSEM_STATE_DIR/egress_direct")"
}

test_leaktest_passes_when_the_exit_address_differs_from_the_own_one() {
	_lt_setup
	tsem set direct >/dev/null 2>&1; _lt >/dev/null
	printf '198.51.100.77\n' >"$T/ip"
	go_german
	_o=$(_lt) || fail "must pass: $_o"
	assert_contains pass "PASS  address" "$_o"
	assert_contains txt "not your own (203.0.113.5)" "$_o"
	assert_contains ks "PASS  kill-switch" "$_o"
	assert_contains v6 "PASS  ipv6-traffic" "$_o"
	assert_contains res "leaktest: pass (0 failed, 0 warnings)" "$_o"
}

test_leaktest_fails_when_the_address_outside_is_the_own_uplink_address() {
	_lt_setup
	tsem set direct >/dev/null 2>&1; _lt >/dev/null
	go_german
	if _o=$(_lt); then fail "the own address outside must FAIL: $_o"; fi
	assert_contains fail "FAIL  address" "$_o"
	assert_contains why "OWN uplink address" "$_o"
}

test_leaktest_says_so_when_the_own_address_is_not_known_yet() {
	_lt_setup
	go_german
	_o=$(_lt) || fail "unknown baseline is not a failure: $_o"
	assert_contains info "INFO  address" "$_o"
	assert_contains hint "not known yet" "$_o"
}

test_leaktest_warns_when_the_router_reaches_the_internet_over_ipv6() {
	_lt_setup
	tsem set direct >/dev/null 2>&1; _lt >/dev/null
	printf '198.51.100.77\n' >"$T/ip"; : >"$T/v6.ok"
	go_german
	_o=$(_lt) || fail "a warning is not a failure: $_o"
	assert_contains warn "WARN  ipv6-traffic" "$_o"
	assert_contains addr "2001:db8::7" "$_o"
	assert_contains res "leaktest: warn" "$_o"
}

test_leaktest_blocked_passes_only_when_nothing_leaves_the_router() {
	_lt_setup
	tsem set blocked --no-wait >/dev/null 2>&1; tk 4
	: >"$T/curl.down"
	_o=$(_lt) || fail "BLOCKED without a connection must pass: $_o"
	assert_contains pass "PASS  traffic" "$_o"
	rm -f "$T/curl.down"
	if _o=$(_lt); then fail "BLOCKED but the router reaches the Internet must FAIL: $_o"; fi
	assert_contains fail "FAIL  traffic" "$_o"
}

test_leaktest_fails_when_the_kill_switch_does_not_match_the_mode() {
	_lt_setup
	go_german
	printf 'open\n' >"$TSEM_MOCK_DIR/guard"
	if _o=$(_lt); then fail "an open guard in the exit mode must FAIL: $_o"; fi
	assert_contains fail "FAIL  kill-switch" "$_o"
}

test_leaktest_only_informs_when_device_dns_is_not_redirected_it_is_the_default() {
	_lt_setup
	export TSEM_DNS_REDIRECT=''
	tsem set direct >/dev/null 2>&1; _lt >/dev/null
	printf '198.51.100.77\n' >"$T/ip"
	go_german
	_o=$(_lt) || fail "a warning is not a failure: $_o"
	assert_contains info "INFO  dns" "$_o"
	assert_contains res "leaktest: pass" "$_o"
}

test_leaktest_names_a_dns_failure_of_the_router_instead_of_blaming_the_exit_node() {
	_lt_setup
	tsem set direct >/dev/null 2>&1; _lt >/dev/null
	go_german
	: >"$T/curl.rc6"
	_o=$(_lt) || fail "a warning is not a failure: $_o"
	assert_contains dns "WARN  router-dns" "$_o"
	assert_contains hint "cannot resolve names" "$_o"
	case $_o in *"exit node may not be carrying"*) fail "must not blame the exit node for a DNS failure" ;; esac
}

test_leaktest_without_a_valid_mode_fails_and_asks_for_nothing_from_the_network() {
	_lt_setup
	rm -f "$TSEM_STATE_DIR/intent"
	: >"$T/curl.down"
	if _o=$(_lt); then fail "no valid mode must FAIL: $_o"; fi
	assert_contains fail "FAIL  kill-switch" "$_o"
}

test_leaktest_json_is_one_object_with_checks_and_never_contains_quotes_in_texts() {
	_lt_setup
	tsem set direct >/dev/null 2>&1; _lt >/dev/null
	printf '198.51.100.77\n' >"$T/ip"
	go_german
	_j=$(_lt --json)
	case $_j in '{'*'}') ;; *) fail "not one JSON object: $_j" ;; esac
	assert_contains res '"result":"pass"' "$_j"
	assert_contains mode '"mode":"german"' "$_j"
	assert_contains chk '"name":"address"' "$_j"
	assert_contains scope '"scope":"router"' "$_j"
	command -v python3 >/dev/null 2>&1 && { printf '%s' "$_j" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert len(d["checks"])>=4' || fail "JSON does not parse or has too few checks"; }
	true
}
