# shellcheck shell=sh
# Probe tolerance: the first packets to an exit node reachable only via DERP can be lost while
# tailscaled sets up the path. One lost ping / one lost fetch must not condemn a node, but a node
# that never answers must still fail (fail-closed is unchanged).

_pb() { # run a backend_ipt function in a clean subshell with a scripted tailscale / curl
	( . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load
	  . "$TSEM_LIBDIR/backend_ipt.sh"; "$@" ); }

_pb_env() {
	_PB=$(mktemp -d); mkdir -p "$_PB/bin"
	cat >"$_PB/bin/tailscale" <<'S'
#!/bin/sh
# ping: mirrors the real CLI. A lost ping (counter file > 0) prints the timeout line and exits 1;
# otherwise $PB_DIR/mode decides (default direct). Real behaviour: exit 1 whenever no DIRECT path exists.
[ "$1" = ping ] || exit 2
echo x >>"$PB_DIR/ping_calls"
for ip; do :; done
n=$(cat "$PB_DIR/ping_fail" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$PB_DIR/ping_fail"; echo "ping \"$ip\" timed out"; exit 1; fi
case $(cat "$PB_DIR/mode" 2>/dev/null || echo direct) in
direct) echo "pong from exit-a ($ip) via 203.0.113.9:41641 in 31ms"; exit 0 ;;
derp) echo "pong from exit-a ($ip) via DERP(nue) in 224ms"; exit 1 ;;
relay) echo "pong from exit-a ($ip) via peer-relay(198.51.100.4:3478:vni:7) in 90ms"; exit 1 ;;
us) echo "pong from exit-a ($ip) via 203.0.113.9:41641 in 850µs"; exit 0 ;;
wrongip) echo "pong from someone-else (100.64.0.77) via DERP(nue) in 20ms"; exit 1 ;;
nomatch) echo "no matching peer"; exit 1 ;;
garbage) echo "something unrelated"; exit 0 ;;
silent_rc0) exit 0 ;;
esac
S
	cat >"$_PB/bin/curl" <<'S'
#!/bin/sh
n=$(cat "$PB_DIR/curl_fail" 2>/dev/null || echo 0)
echo x >>"$PB_DIR/curl_calls"
[ "$n" -gt 0 ] || exit 0
echo $((n - 1)) >"$PB_DIR/curl_fail"; exit 22
S
	chmod +x "$_PB/bin/tailscale" "$_PB/bin/curl"
	export PB_DIR=$_PB TSEM_TAILSCALE=$_PB/bin/tailscale PATH="$_PB/bin:$PATH" TSEM_PROBE_TIMEOUT=1
}

test_reach_survives_two_lost_pings() {
	_pb_env; echo 2 >"$_PB/ping_fail"
	_pb be_probe_reach 100.64.0.30 || fail "two lost pings must not condemn the node"
}

test_reach_fails_when_node_never_answers() {
	_pb_env; echo 99 >"$_PB/ping_fail"
	_pb be_probe_reach 100.64.0.30 && fail "a silent node must fail"
	assert_eq "attempts" 96 "$(cat "$_PB/ping_fail")"
}

test_egress_survives_one_lost_round() {
	_pb_env; echo 2 >"$_PB/curl_fail" # both URLs of round 1 fail, round 2 succeeds
	_pb be_probe_egress || fail "a lost first round must not condemn the node"
}

test_egress_fails_when_internet_never_works() {
	_pb_env; echo 99 >"$_PB/curl_fail"
	_pb be_probe_egress && fail "no internet through the node must fail"
	assert_eq "fetches" 4 "$(wc -l <"$_PB/curl_calls" | tr -d ' ')"
}

test_probe_detail_names_the_failure_class_per_url() {
	_pb_env
	# the stub exits 22 (HTTP error) for every call: both URLs, both rounds
	echo 99 >"$_PB/curl_fail"
	_pb sh -c '. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"; be_probe_egress; be_probe_detail' >"$_PB/out" 2>&1 || true
	_d=$(cat "$_PB/out")
	assert_contains url1 "1.1.1.1=http" "$_d"
	assert_contains url2 "9.9.9.9=http" "$_d"
}

test_probe_detail_after_success_ends_with_ok() {
	_pb_env; echo 1 >"$_PB/curl_fail"
	_pb sh -c '. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"; be_probe_egress; be_probe_detail' >"$_PB/out" 2>&1
	assert_contains ok "9.9.9.9=ok" "$(cat "$_PB/out")"
}

# GL.iNet 4.11 / tailscale 1.92.5 deviations: an exit node set through the GUI may show only an ID in the prefs
test_exit_get_reports_pending_when_only_the_node_id_is_set() {
	_pb_env
	cat >"$_PB/bin/tailscale" <<'S'
#!/bin/sh
case $1 in
status) echo '{ "ExitNodeStatus": null }' ;;
debug) printf '{\n "ExitNodeID": "nXYZ123",\n "ExitNodeIP": ""\n}\n' ;;
esac
S
	[ "$(_pb be_exit_get)" = pending ] || fail "ID set without IP and without status must be pending, not none and not an address"
}

test_exit_get_reports_none_without_any_exit_node() {
	_pb_env
	cat >"$_PB/bin/tailscale" <<'S'
#!/bin/sh
case $1 in
status) echo '{ "ExitNodeStatus": null }' ;;
debug) printf '{\n "ExitNodeID": "",\n "ExitNodeIP": ""\n}\n' ;;
esac
S
	[ "$(_pb be_exit_get)" = none ] || fail "no exit node must read as none"
}

test_exit_get_prefers_the_live_status_over_the_prefs() {
	_pb_env
	cat >"$_PB/bin/tailscale" <<'S'
#!/bin/sh
case $1 in
status) printf '{\n "ExitNodeStatus": {\n  "ID": "n1",\n  "TailscaleIPs": [ "100.64.0.31/32" ]\n }\n}\n' ;;
debug) printf '{\n "ExitNodeID": "n1",\n "ExitNodeIP": ""\n}\n' ;;
esac
S
	[ "$(_pb be_exit_get)" = 100.64.0.31 ] || fail "live ExitNodeStatus must win, got $(_pb be_exit_get)"
}

# ---- reachability is decided by the OUTPUT of `tailscale ping`, never by its exit code ----
# (hardware: DERP-only pong, relay nue, 224 ms, exit code 1 was classified as unreachable)
_pb_mode() { echo "$1" >"$_PB/mode"; }
_PB_IP=100.64.0.30

test_reach_derp_only_pong_counts_although_exit_code_is_1() {
	_pb_env; _pb_mode derp
	_pb be_probe_reach "$_PB_IP" || fail "a DERP-only pong (CLI exit 1) must count as reachable"
	assert_eq "one ping is enough" 1 "$(wc -l <"$_PB/ping_calls" | tr -d ' ')"
}

test_reach_direct_pong() {
	_pb_env; _pb_mode direct
	_pb be_probe_reach "$_PB_IP" || fail "a direct pong must count as reachable"
}

test_reach_peer_relay_and_microsecond_latency() {
	_pb_env; _pb_mode relay
	_pb be_probe_reach "$_PB_IP" || fail "a peer-relay pong must count as reachable"
	_pb_mode us
	_pb be_probe_reach "$_PB_IP" || fail "a pong with microsecond latency must count as reachable"
}

test_reach_pong_from_another_node_is_not_this_node() {
	_pb_env; _pb_mode wrongip
	if _pb be_probe_reach "$_PB_IP"; then fail "a pong naming a different address must not count"; fi
	assert_eq "all attempts used" 3 "$(wc -l <"$_PB/ping_calls" | tr -d ' ')"
}

test_reach_no_matching_peer_and_timeout_fail() {
	_pb_env; _pb_mode nomatch
	if _pb be_probe_reach "$_PB_IP"; then fail "'no matching peer' must not count"; fi
	_pb_mode direct; echo 99 >"$_PB/ping_fail"
	if _pb be_probe_reach "$_PB_IP"; then fail "timeouts must not count"; fi
}

test_reach_garbage_or_silent_exit_0_is_not_a_pong() {
	_pb_env; _pb_mode garbage
	if _pb be_probe_reach "$_PB_IP"; then fail "unrelated output with exit 0 must not count"; fi
	_pb_mode silent_rc0
	if _pb be_probe_reach "$_PB_IP"; then fail "silence with exit 0 must not count"; fi
}

test_reach_rejects_invalid_ip_without_calling_tailscale() {
	_pb_env
	if _pb be_probe_reach 'not-an-ip'; then fail "invalid address must be rejected"; fi
	[ ! -e "$_PB/ping_calls" ] || fail "tailscale must not be called for an invalid address"
}

test_reach_does_not_replace_egress_proof() {
	_pb_env; _pb_mode derp; echo 99 >"$_PB/curl_fail"
	_pb be_probe_reach "$_PB_IP" || fail "reachable over DERP"
	if _pb be_probe_egress; then fail "reachability must never stand in for real egress"; fi
}
