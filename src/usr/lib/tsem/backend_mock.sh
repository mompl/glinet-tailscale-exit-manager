# shellcheck shell=sh
# Mock backend for tests. Touches nothing outside $TSEM_MOCK_DIR.
#
# Every mutation is appended to $TSEM_MOCK_DIR/events as "<n> guard <state>" or
# "<n> exit <node>" so tests can assert ordering (guard blocked BEFORE the exit
# node changes, guard never "open" during failover).
#
# Fault injection (create/remove files in $TSEM_MOCK_DIR):
#   down_all        every probe fails
#   down/<ip>       probes of <ip> fail
#   dns_down        be_probe_dns fails
#   fail_exit       be_exit_set fails
#   ts_down         tailscaled dead: be_exit_set fails, be_exit_get = unavailable
#   fail_guard      be_guard_set fails (and changes nothing)
#   drift_guard     be_guard_get reports inconsistent
#   node_bad/<ip>   exit node <ip> fails the identity check; scan_fail: tailscale status unavailable

_mock_ev() {
	_mn=$(cat "$TSEM_MOCK_DIR/seq" 2>/dev/null || echo 0)
	_mn=$((_mn + 1))
	echo "$_mn" >"$TSEM_MOCK_DIR/seq"
	echo "$_mn $*" >>"$TSEM_MOCK_DIR/events"
}

be_guard_set() {
	case $1 in open | german | blocked) ;; *) return 1 ;; esac
	[ ! -e "$TSEM_MOCK_DIR/fail_guard" ] || { _mock_ev guard-fail "$1"; return 1; }
	_mock_ev guard "$1"
	echo "$1" >"$TSEM_MOCK_DIR/guard"
}

be_guard_get() {
	[ ! -e "$TSEM_MOCK_DIR/drift_guard" ] || { echo inconsistent; return 0; }
	cat "$TSEM_MOCK_DIR/guard" 2>/dev/null || echo none
}

be_guard_remove() { _mock_ev guard-removed; rm -f "$TSEM_MOCK_DIR/guard"; }

be_exit_set() {
	if [ -e "$TSEM_MOCK_DIR/fail_exit" ] || [ -e "$TSEM_MOCK_DIR/ts_down" ]; then
		_mock_ev exit-fail "$1"
		return 1
	fi
	_mock_ev exit "$1"
	echo "$1" >"$TSEM_MOCK_DIR/exit"
}

be_exit_get() {
	if [ -e "$TSEM_MOCK_DIR/ts_down" ]; then echo unavailable; return 0; fi
	cat "$TSEM_MOCK_DIR/exit" 2>/dev/null || echo none
}

# Exit-node identity: node_bad/<ip> makes the node fail verification (wrong host, offline, not an exit node)
be_nodes_scan() {
	[ ! -e "$TSEM_MOCK_DIR/scan_fail" ] || return 1
	# peers: host|ip[,ip]|online|exitoption|dnslabel  (same format as the real scan)
	mkdir -p "$TSEM_RUN_DIR" 2>/dev/null
	if [ -f "$TSEM_MOCK_DIR/peers" ]; then cp "$TSEM_MOCK_DIR/peers" "$TSEM_RUN_DIR/peers"; else : >"$TSEM_RUN_DIR/peers"; fi
	return 0
}
be_node_why() {
	[ -n "$1" ] || { echo "ok (no name configured: identity NOT verified)"; return 0; }
	[ ! -e "$TSEM_MOCK_DIR/scan_fail" ] || { echo "tailscale status unavailable"; return 1; }
	if [ -e "$TSEM_MOCK_DIR/node_bad/$2" ]; then echo "mock: node failed verification"; return 1; fi
	echo ok
}
be_node_check() { be_node_why "$1" "$2" >/dev/null; }

be_probe_reach() {
	[ ! -e "$TSEM_MOCK_DIR/down_all" ] || return 1
	[ ! -e "$TSEM_MOCK_DIR/down/$1" ] || return 1
	return 0
}

# egress_fail/<ip>: the peer answers (reach ok) but the Internet through it does not work
be_probe_egress() {
	_me=$(be_exit_get)
	case $_me in none | unavailable | pending | '') return 1 ;; esac
	[ ! -e "$TSEM_MOCK_DIR/egress_fail/$_me" ] || return 1
	be_probe_reach "$_me"
}
be_probe_detail() { echo "mock"; }

be_probe_dns() { [ ! -e "$TSEM_MOCK_DIR/dns_down" ]; }

# private networks that peers advertise to this router (one CIDR per line)
be_subnets_scan() { [ -f "$TSEM_MOCK_DIR/subnets" ] && cat "$TSEM_MOCK_DIR/subnets"; return 0; }
