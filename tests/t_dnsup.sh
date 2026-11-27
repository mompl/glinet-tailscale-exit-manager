# shellcheck shell=sh
# The router's own resolver while protected: a private upstream behind the uplink cannot be reached through the exit node (found on real
# hardware), so tsem gives dnsmasq a temporary upstream file for the time a protected mode is active.

_du_setup() { # [route-device]
	export TSEM_DNSMASQ_DIR=$T/dnsmasq.d
	mkdir -p "$T/bin" "$TSEM_DNSMASQ_DIR"
	printf '%s\n' "${1:-wlan0}" >"$T/ipdev"
	cat >"$T/bin/ip" <<IP
#!/bin/sh
d=\$(cat "$T/ipdev")
[ "\$d" = none ] && exit 2
echo "\$3 via 10.60.0.1 dev \$d src 10.60.0.101 uid 0"
IP
	chmod +x "$T/bin/ip"
	printf '#!/bin/sh\necho x >>"%s/restarts"\n' "$T" >"$T/bin/restart"; chmod +x "$T/bin/restart"
	export TSEM_IP=$T/bin/ip TSEM_DNSMASQ_DIR=$T/dnsmasq.d TSEM_DNSMASQ_RESTART=$T/bin/restart TSEM_LAN_IFACES=br-lan
	_du_resolv 10.60.0.1
}
_du_resolv() { printf '# Interface wwan\nnameserver %s\nsearch example.test\n' "$1" >"$T/no-resolv"; }
_du_file() { echo "$T/dnsmasq.d/tsem-dns.conf"; }
# the restart runs detached: wait for it
_du_restarts() { _w=0; while [ "$_w" -lt 30 ]; do [ -f "$T/restarts" ] && [ "$(wc -l <"$T/restarts")" -ge "$1" ] && break; _w=$((_w + 1)); sleep 0.1 2>/dev/null || sleep 1; done; if [ -f "$T/restarts" ]; then wc -l <"$T/restarts" | tr -d " "; else echo 0; fi; }

test_a_private_upstream_behind_the_uplink_gets_the_exit_resolver_while_protected() {
	_du_setup wlan0
	go_german
	[ -f "$(_du_file)" ] || fail "no upstream file in the exit mode"
	assert_contains srv "server=1.1.1.1" "$(cat "$(_du_file)")"
	assert_contains nores "no-resolv" "$(cat "$(_du_file)")"
	assert_eq restart 1 "$(_du_restarts 1)"
}

test_direct_removes_the_file_again_and_restarts_dnsmasq() {
	_du_setup wlan0
	go_german
	_du_restarts 1 >/dev/null
	tsem set direct --no-wait >/dev/null 2>&1; tk 3
	[ ! -e "$(_du_file)" ] || fail "the file must be gone in DIRECT"
	assert_eq restart 2 "$(_du_restarts 2)"
}

test_blocked_keeps_the_same_upstream_so_nothing_leaks_and_nothing_flaps() {
	_du_setup wlan0
	go_german
	_du_restarts 1 >/dev/null
	tsem set blocked --no-wait >/dev/null 2>&1; tk 3
	[ -f "$(_du_file)" ] || fail "BLOCKED is a protected mode: the file stays"
	assert_eq norestart 1 "$(_du_restarts 1)"
}

test_a_second_tick_does_not_restart_dnsmasq_again() {
	_du_setup wlan0
	go_german 10
	tk 5
	assert_eq restart 1 "$(_du_restarts 1)"
}

test_an_upstream_inside_the_lan_needs_nothing() {
	_du_setup br-lan
	go_german
	[ ! -e "$(_du_file)" ] || fail "a resolver reachable through the LAN stays as it is"
}

test_a_public_upstream_needs_nothing() {
	_du_setup wlan0
	_du_resolv 9.9.9.9
	go_german
	[ ! -e "$(_du_file)" ] || fail "a public upstream already follows the exit node"
}

test_an_unknown_route_to_a_private_upstream_counts_as_needed() {
	_du_setup none
	go_german
	[ -f "$(_du_file)" ] || fail "a private resolver we cannot reach locally is the failing case"
}

test_on_always_and_off_never_while_protected() {
	_du_setup wlan0
	_du_resolv 9.9.9.9
	TSEM_DNS_UPSTREAM=on; export TSEM_DNS_UPSTREAM
	go_german
	[ -f "$(_du_file)" ] || fail "on: the file must exist while protected"
	tsem set direct --no-wait >/dev/null 2>&1; tk 3
	_du_resolv 10.60.0.1
	TSEM_DNS_UPSTREAM=off; export TSEM_DNS_UPSTREAM
	go_german
	[ ! -e "$(_du_file)" ] || fail "off: never"
}

test_without_a_dnsmasq_directory_nothing_happens_and_nothing_fails() {
	_du_setup wlan0
	rm -rf "$T/dnsmasq.d"
	go_german
	assert_eq mode german "$(st mode)"
	[ ! -e "$T/restarts" ] || fail "no directory, no restart"
}

test_a_file_left_over_from_before_is_removed_by_the_tick_in_direct() {
	_du_setup wlan0
	printf 'no-resolv\nserver=1.1.1.1\n' >"$(_du_file)"
	tsem set direct --no-wait >/dev/null 2>&1; tk 2
	[ ! -e "$(_du_file)" ] || fail "DIRECT must not keep our upstream"
}

test_teardown_removes_the_file() {
	_du_setup wlan0
	go_german
	tsem teardown >/dev/null 2>&1
	[ ! -e "$(_du_file)" ] || fail "teardown must remove the file"
}

test_the_setting_is_validated_and_a_bad_value_falls_back_to_auto() {
	printf 'TSEM_DNS_UPSTREAM=maybe\n' >"$T/c.conf"
	_v=$(TSEM_CONF=$T/c.conf "$SH" -c '. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load >/dev/null 2>&1; echo "$TSEM_DNS_UPSTREAM"')
	assert_eq fallback auto "$_v"
	printf 'TSEM_DNS_UPSTREAM=off\n' >"$T/c.conf"
	_v=$(TSEM_CONF=$T/c.conf "$SH" -c '. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load >/dev/null 2>&1; echo "$TSEM_DNS_UPSTREAM"')
	assert_eq off off "$_v"
}
