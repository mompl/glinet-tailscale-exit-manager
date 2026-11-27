# shellcheck shell=sh
# Exit-node identity (names must match IPs), adaptive polling, boot failure state,
# init retry, and "never touch the router's own exit-node advertisement".

_names() { export TSEM_PRIMARY_NAME=exit-a TSEM_SECONDARY_NAME=exit-b; }
_bad() { mkdir -p "$TSEM_MOCK_DIR/node_bad"; : >"$TSEM_MOCK_DIR/node_bad/$1"; }
_good() { rm -f "$TSEM_MOCK_DIR/node_bad/$1"; }

# --- identity in the failover logic (mock backend) -----------------------------

test_node_failing_identity_is_never_selected() {
	_names; _bad "$P1"
	go_german 16
	assert_eq state SECONDARY_ACTIVE "$(st state)"
	assert_eq exit "$P2" "$(mexit)"
	assert_never_open_after 0
}

test_both_nodes_failing_identity_means_blocked_never_direct() {
	_names; _bad "$P1"; _bad "$P2"
	go_german 16
	assert_eq state BLOCKED "$(st state)"
	assert_eq guard blocked "$(guard)"
	assert_eq exit none "$(mexit)"
	assert_never_open_after 0
}

test_identity_returns_then_primary_is_used_again() {
	_names; _bad "$P1"
	go_german 16
	assert_eq secondary SECONDARY_ACTIVE "$(st state)"
	_good "$P1"
	export TSEM_NOW=$((TSEM_NOW + 400)) # backoff and dwell expired
	tk 20
	assert_eq primary PRIMARY_ACTIVE "$(st state)"
}

test_active_node_that_stops_matching_is_dropped() {
	_names
	go_german 16
	assert_eq start PRIMARY_ACTIVE "$(st state)"
	_bad "$P1" # the IP now belongs to another machine / lost its exit-node approval
	tk 12
	assert_eq failover SECONDARY_ACTIVE "$(st state)"
	assert_never_open_after "$(ev_line 'guard german' first)"
}

test_status_unavailable_with_names_is_blocked() {
	_names
	go_german 16
	mflag scan_fail
	tk 14
	assert_eq state BLOCKED "$(st state)"
	assert_eq guard blocked "$(guard)"
}

test_without_names_the_identity_check_is_skipped_and_reported() {
	mflag scan_fail # would break every named setup; must not matter without names
	go_german 16
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	_o=$(tsem verify-nodes)
	assert_contains warn "WARN primary" "$_o"
	assert_contains hint "NOT verified" "$_o"
}

test_verify_nodes_reports_pass_and_fail_with_exit_code() {
	_names
	_o=$(tsem verify-nodes) || fail "expected rc 0: $_o"
	assert_contains p "PASS primary: exit-a $P1" "$_o"
	assert_contains s "PASS secondary: exit-b $P2" "$_o"
	_bad "$P2"
	_o=$(tsem verify-nodes) && fail "a failing secondary must give rc 1"
	assert_contains f "FAIL secondary: exit-b $P2" "$_o"
	assert_rc "no primary" 1 env TSEM_PRIMARY= TSEM_PRIMARY_NAME= "$SH" "$ROOT/src/usr/sbin/tsem" verify-nodes
}

test_missing_primary_refuses_german_and_changes_nothing() {
	_before=$(isum)
	assert_rc refused 2 env TSEM_PRIMARY= "$SH" "$ROOT/src/usr/sbin/tsem" set german --no-wait
	assert_eq intent "$_before" "$(isum)"
	assert_eq guard none "$(guard)"
}

test_invalid_exit_node_ip_in_config_is_ignored_not_guessed() {
	unset TSEM_PRIMARY
	printf 'TSEM_PRIMARY=100.64.0\nTSEM_PRIMARY_NAME=exit-a\n' >"$T/c.conf"
	assert_rc refused 2 env TSEM_CONF="$T/c.conf" "$SH" "$ROOT/src/usr/sbin/tsem" set german --no-wait
	assert_eq guard none "$(guard)"
}

test_exit_set_failure_never_falls_back_to_direct() {
	_names
	mflag fail_exit
	tsem set german --no-wait >/dev/null 2>&1
	tk 8
	assert_eq state ERROR "$(st state)"
	assert_eq guard blocked "$(guard)"
	assert_never_open_after 0
}

# --- identity parsing (real backend code against realistic `tailscale status --json`) -------

_mkstatus() { # name ip online exitoption  (one peer) -> JSON on stdout, tailscale pretty-print layout
	cat <<J
{
  "Version": "1.92.5",
  "BackendState": "Running",
  "TailscaleIPs": [
    "100.70.0.2",
    "fd7a:115c:a1e0::2"
  ],
  "Self": {
    "ID": "nSelf",
    "HostName": "root",
    "DNSName": "root.tail1234.ts.net.",
    "TailscaleIPs": [
      "100.70.0.2"
    ],
    "Online": true,
    "ExitNodeOption": true
  },
  "ExitNodeStatus": {
    "ID": "nX",
    "Online": true,
    "TailscaleIPs": [
      "100.64.9.9/32"
    ]
  },
  "Peer": {
    "nodekey:aaaa": {
      "ID": "n1",
      "HostName": "$1",
      "DNSName": "$5.tail1234.ts.net.",
      "OS": "linux",
      "TailscaleIPs": [
        "$2",
        "fd7a:115c:a1e0::1"
      ],
      "AllowedIPs": [
        "$2/32",
        "0.0.0.0/0",
        "::/0"
      ],
      "Online": $3,
      "ExitNode": false,
      "ExitNodeOption": $4,
      "Active": false
    },
    "nodekey:bbbb": {
      "ID": "n2",
      "HostName": "laptop",
      "DNSName": "laptop.tail1234.ts.net.",
      "TailscaleIPs": [
        "100.64.1.1"
      ],
      "Online": true,
      "ExitNodeOption": false
    }
  }
}
J
}

_ts_fixture() { # name ip online exitoption [dnslabel] -> $T/ts (stub tailscale printing it)
	_mkstatus "$1" "$2" "$3" "$4" "${5:-$1}" >"$T/status.json"
	printf '#!/bin/sh\n[ "$1" = status ] && exec cat "%s/status.json"\nexit 1\n' "$T" >"$T/ts"
	chmod +x "$T/ts"
}

_why() { # name ip -> reason (runs the REAL backend functions)
	( TSEM_TAILSCALE="$T/ts"; TSEM_BACKEND=ipt; export TSEM_TAILSCALE TSEM_BACKEND
	. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"
	be_nodes_scan; be_node_why "$1" "$2" )
}

test_parser_accepts_the_intended_node() {
	_ts_fixture exit-a 100.64.0.30 true true
	assert_eq ok ok "$(_why exit-a 100.64.0.30)"
	assert_eq case-insensitive ok "$(_why Exit-A 100.64.0.30)"
}

test_parser_rejects_wrong_ip_unknown_name_offline_and_not_exit_node() {
	_ts_fixture exit-a 100.64.0.30 true true
	assert_contains wrongip "does not own" "$(_why exit-a 100.64.0.99)"
	assert_contains unknown "no node with this name" "$(_why other-host 100.64.0.30)"
	_ts_fixture exit-a 100.64.0.30 false true
	assert_contains offline "offline" "$(_why exit-a 100.64.0.30)"
	_ts_fixture exit-a 100.64.0.30 true false
	assert_contains noexit "not an approved exit node" "$(_why exit-a 100.64.0.30)"
}

test_parser_matches_the_magicdns_label_when_the_hostname_differs() {
	_ts_fixture raw-os-hostname 100.64.0.30 true true exit-a
	assert_eq label ok "$(_why exit-a 100.64.0.30)"
}

# tailscale 1.92 on a GL-MG1300 describes peers in a short form (no HostName, no Online) until a connection exists
_ts_short_fixture() {
	cat >"$T/status.json" <<J
{
  "Version": "1.92.5-1 (OpenWrt)",
  "BackendState": "Running",
  "Self": { "ID": "nSelf", "HostName": "GL-MG1300", "DNSName": "mango.tail1234.ts.net.", "TailscaleIPs": [ "100.70.0.2" ], "Online": true },
  "Peer": {
    "nodekey:aaaa": {
      "PublicKey": "nodekey:aaaa",
      "DNSName": "exit-a.tail1234.ts.net.",
      "TailscaleIPs": [
        "100.64.0.30"
      ],
      "ExitNodeOption": true
    },
    "nodekey:bbbb": {
      "PublicKey": "nodekey:bbbb",
      "DNSName": "plain.tail1234.ts.net.",
      "TailscaleIPs": [
        "100.64.1.1"
      ]
    }
  }
}
J
	printf '#!/bin/sh
[ "$1" = status ] && exec cat "%s/status.json"
exit 1
' "$T" >"$T/ts"
	chmod +x "$T/ts"
}

test_parser_reads_the_short_peer_form_by_dns_label_and_does_not_call_unknown_online_offline() {
	_ts_short_fixture
	assert_eq short ok "$(_why exit-a 100.64.0.30)"
	assert_contains wrongip "does not own" "$(_why exit-a 100.64.0.31)"
	assert_contains noexit "not an approved exit node" "$(_why plain 100.64.1.1)"
	assert_contains unknown "no node with this name" "$(_why nobody 100.64.0.30)"
}

test_parser_does_not_confuse_self_laptop_or_exitnodestatus_with_the_target() {
	_ts_fixture exit-a 100.64.0.30 true true
	assert_contains self "no node with this name" "$(_why root 100.64.0.30)"
	assert_contains laptop "not an approved exit node" "$(_why laptop 100.64.1.1)"
	assert_contains mix "does not own" "$(_why laptop 100.64.0.30)"
}

test_parser_status_failure_is_not_ok() {
	printf '#!/bin/sh\nexit 1\n' >"$T/ts"; chmod +x "$T/ts"
	assert_contains unavailable "unavailable" "$(_why exit-a 100.64.0.30)"
	printf '#!/bin/sh\necho\n' >"$T/ts"
	assert_contains empty "unavailable" "$(_why exit-a 100.64.0.30)"
}


test_a_single_failed_status_call_is_retried_and_a_persistent_failure_is_logged() {
	_mkstatus exit-a 100.64.0.30 true true exit-a >"$T/status.json"
	# first call fails, the retry works
	printf '#!/bin/sh\nn=$(cat "%s/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n >"%s/n"\n[ "$n" -ge 2 ] || { echo "transient: tailscaled busy" >&2; exit 1; }\n[ "$1" = status ] && exec cat "%s/status.json"\nexit 1\n' "$T" "$T" "$T" >"$T/ts"; chmod +x "$T/ts"
	rm -f "$T/n"
	assert_eq retried "ok" "$(TSEM_SCAN_RETRY_DELAY=0 _why exit-a 100.64.0.30)"
	# always failing: unavailable, and the reason reaches the log (stderr of the call)
	printf '#!/bin/sh\necho "boom: no socket" >&2\nexit 1\n' >"$T/ts"; chmod +x "$T/ts"
	_o=$(TSEM_SCAN_RETRY_DELAY=0 TSEM_SYSLOG=0 _why exit-a 100.64.0.30 2>&1)
	assert_contains unavailable "unavailable" "$_o"
	assert_contains reason "boom: no socket" "$_o"
}
# --- the router's own exit-node advertisement is never touched -----------------

test_tailscale_is_only_called_in_known_ways() {
	_calls=$(grep -rhoE '_tsc +[a-z-]+( +[-a-z=]+)?' "$ROOT/src/usr" | sed 's/[[:space:]]*$//' | sort -u)
	_want='_tsc debug prefs
_tsc set --exit-node=
_tsc status --json'
	assert_eq "tailscale invocations" "$_want" "$_calls"
	grep -rnE 'tailscale +(up|login|logout|down|set +--advertise|cert)|--advertise' "$ROOT/src" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -v 'advertis.*WARN\|_st_warn\|grep -q' && fail "source must never change the node's advertisement"
	true
}

test_set_exit_node_call_is_the_only_mutation_and_only_names_exit_node() {
	mkdir -p "$T/ts-calls"
	printf '#!/bin/sh\necho "$*" >>"%s/calls"\n[ "$1" = set ] && exit 0\nexit 1\n' "$T/ts-calls" >"$T/ts2"; chmod +x "$T/ts2"
	( TSEM_TAILSCALE="$T/ts2"; export TSEM_TAILSCALE; . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load
	  . "$TSEM_LIBDIR/backend_ipt.sh"; be_exit_set 100.64.0.30; be_exit_set none )
	assert_eq calls "set --exit-node=100.64.0.30
set --exit-node=" "$(cat "$T/ts-calls/calls")"
}

# --- adaptive polling -------------------------------------------------------------

test_interval_follows_the_state() {
	tsem set direct --no-wait >/dev/null 2>&1
	assert_eq direct "60 direct" "$(tsem interval)"
	tsem set german --no-wait >/dev/null 2>&1
	assert_contains connecting "5 " "$(tsem interval)"
	tk 8
	assert_eq active "20 PRIMARY_ACTIVE" "$(tsem interval)"
	mdown "$P1"
	tk 14
	assert_eq secondary "15 SECONDARY_ACTIVE" "$(tsem interval)"
	mdown "$P2"
	tk 8
	assert_eq blocked "5 BLOCKED" "$(tsem interval)"
}

test_interval_without_valid_intent_is_fast() {
	assert_eq none "5 intent-invalid" "$(tsem interval)"
}

test_interval_values_are_configurable_and_never_below_the_fast_one() {
	go_german 16
	assert_eq custom "40 PRIMARY_ACTIVE" "$(TSEM_INTERVAL_STEADY=40 tsem interval)"
	assert_eq clamp "10 PRIMARY_ACTIVE" "$(TSEM_INTERVAL=10 TSEM_INTERVAL_STEADY=2 tsem interval)"
}

test_daemon_sleeps_the_adaptive_interval() {
	# fake sleep records its argument; the daemon is stopped after 2 iterations
	mkdir -p "$T/bin"
	printf '#!/bin/sh\necho "$1" >>"%s/sleeps"\n[ "$(wc -l <"%s/sleeps")" -ge 2 ] && kill -TERM "$PPID"\nexit 0\n' "$T" "$T" >"$T/bin/sleep"
	chmod +x "$T/bin/sleep"
	go_german 16
	PATH="$T/bin:$PATH" "$SH" "$ROOT/src/usr/sbin/tsem" daemon >/dev/null 2>&1 || true
	assert_eq sleeps "20
20" "$(cat "$T/sleeps")"
}

# --- boot failure --------------------------------------------------------------------

test_boot_failure_is_an_error_state_and_a_leak_risk() {
	tsem set german --no-wait >/dev/null 2>&1
	mflag fail_guard
	assert_rc boot-fails 1 tsem boot
	assert_eq state ERROR "$(st state)"
	assert_contains err "boot" "$(st error)"
	munflag fail_guard
	tk 2 # a later successful apply clears the error
	assert_contains recovered "CONNECTING" "$(st state)"
}

test_boot_failure_never_opens_the_guard() {
	tsem set german --no-wait >/dev/null 2>&1
	mflag fail_guard
	tsem boot >/dev/null 2>&1
	tk 3
	assert_never_open_after 0
}

# --- init script ------------------------------------------------------------------------

_init_fn() { # run boot_guard from the real init script with a fake tsem
	cat >"$T/fake-tsem" <<X
#!/bin/sh
n=\$(cat "$T/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"$T/n"
[ "\$n" -gt "${1:-0}" ]
X
	chmod +x "$T/fake-tsem"
	( TSEM_BIN="$T/fake-tsem" TSEM_BOOT_RETRY_DELAY=0 TSEM_BOOT_TRIES=${2:-5}
	  export TSEM_BIN TSEM_BOOT_RETRY_DELAY TSEM_BOOT_TRIES
	  . "$ROOT/src/etc/init.d/tsem"; boot_guard )
}

test_init_retries_the_boot_guard_until_it_succeeds() {
	_init_fn 3 5 || fail "boot_guard should succeed on the 4th try"
	assert_eq tries 4 "$(cat "$T/n")"
}

test_init_gives_up_after_the_configured_tries_and_reports() {
	_init_fn 99 4 && fail "boot_guard must report failure"
	assert_eq tries 4 "$(cat "$T/n")"
}

test_init_runs_before_firewall_and_network_and_stop_does_not_open() {
	_s=$(sed -n 's/^START=//p' "$ROOT/src/etc/init.d/tsem")
	[ "$_s" -lt 19 ] || fail "START=$_s must be before firewall (19)"
	! grep -n 'tsem set direct\|teardown\|be_guard_set open' "$ROOT/src/etc/init.d/tsem" | grep -v '^[0-9]*:#' | grep -q . || fail "init must never open the kill switch"
	grep -q '^stop_service\|^stop()' "$ROOT/src/etc/init.d/tsem" && fail "a stop handler could open the guard"
	true
}

test_firewall_include_and_hotplug_reapply_without_opening() {
	assert_contains fw 'exec /usr/sbin/tsem reapply' "$(cat "$ROOT/src/usr/lib/tsem/fw-include.sh")"
	_h=$(cat "$ROOT/src/etc/hotplug.d/iface/50-tsem")
	assert_contains hp 'tsem reapply' "$_h"
	case $_h in *'set direct'*) fail "hotplug must never open" ;; esac
}

test_saving_unchanged_exit_nodes_does_not_restart_the_verification() {
	_names; go_german 16
	assert_eq active PRIMARY_ACTIVE "$(st state)"
	tsem config set TSEM_PRIMARY="$P1" TSEM_PRIMARY_NAME=exit-a TSEM_SECONDARY="$P2" TSEM_SECONDARY_NAME=exit-b >/dev/null 2>&1 || fail "config set failed"
	assert_eq "unchanged values keep the exit node" PRIMARY_ACTIVE "$(st state)"
	tsem config set TSEM_SECONDARY_NAME=exit-new >/dev/null 2>&1 || fail "config set failed"
	[ "$(st state)" != PRIMARY_ACTIVE ] || fail "a changed exit node must restart the verification"
}

# the name shown and saved is the tailnet name (what `tailscale status` and the admin console show), not the machine's own hostname:
# found on two routers that named the same node differently (one tailscale prints HostName, the older short form does not)
_peers_line() { ( TSEM_TAILSCALE="$T/ts"; TSEM_BACKEND=ipt; export TSEM_TAILSCALE TSEM_BACKEND
	. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"
	be_nodes_scan; grep "^$1|" "$TSEM_RUN_DIR/peers" ); }

test_the_listed_name_is_the_tailnet_name_even_when_the_hostname_differs_and_both_names_verify() {
	_ts_fixture my-os-hostname 100.64.0.30 true true tailnet-name
	_l=$(_peers_line tailnet-name)
	[ -n "$_l" ] || fail "the node is not listed under its tailnet name: $(_peers_line my-os-hostname)"
	assert_contains hostname-kept "|my-os-hostname" "$_l"
	assert_eq by-tailnet-name ok "$(_why tailnet-name 100.64.0.30)"
	assert_eq by-old-hostname ok "$(_why my-os-hostname 100.64.0.30)"
}

test_the_short_peer_form_and_the_full_form_name_a_node_the_same_way() {
	_ts_fixture my-os-hostname 100.64.0.30 true true exit-a
	_full=$(_peers_line exit-a | cut -d'|' -f1)
	_ts_short_fixture
	_short=$(_peers_line exit-a | cut -d'|' -f1)
	assert_eq same-name "$_full" "$_short"
}
