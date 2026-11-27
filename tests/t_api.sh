# shellcheck shell=sh
# Local API (rpcd exec plugin "tsem"): validation, reached-vs-requested replies, permissions (ACL),
# concurrency. The plugin is the only thing the GUI and Home Assistant talk to.

_api_setup() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 is not installed (JSON stand-in for jsonfilter)"
	export PATH=$ROOT/tests/stubs:$PATH
	mkdir -p "$T/bin"
	printf '#!/bin/sh\nexec "%s" "%s/src/usr/sbin/tsem" "$@"\n' "$SH" "$ROOT" >"$T/bin/tsem"
	chmod +x "$T/bin/tsem"
	export TSEM_BIN=$T/bin/tsem
	export TSEM_CONF=$T/tsem.conf
	unset TSEM_PRIMARY TSEM_SECONDARY
	printf 'TSEM_PRIMARY=%s\nTSEM_SECONDARY=%s\n' "$P1" "$P2" >"$TSEM_CONF"
	export TSEM_LOGREAD=$T/logread
	printf '#!/bin/sh\nprintf "%%s\\n" "Wed tsem: probe primary: egress ok" "tsem: weird \\"quote\\" and back\\\\slash"\n' >"$T/logread"
	chmod +x "$T/logread"
}
api() { # METHOD [JSON]
	_am=$1; shift
	printf '%s' "${1:-{\}}" | "$SH" "$ROOT/src/usr/libexec/rpcd/tsem" call "$_am"
}
jget() { python3 -c 'import sys,json
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[k]
print(str(d).lower() if isinstance(d,bool) else d)' "$1"; }
jvalid() { python3 -c 'import sys,json; json.load(sys.stdin)'; }

test_api_list_is_valid_json_and_matches_acl() {
	_api_setup
	"$SH" "$ROOT/src/usr/libexec/rpcd/tsem" list | jvalid || fail "list is not valid JSON"
	python3 - "$ROOT" <<'PY' || fail "ACL does not match the methods"
import json, subprocess, sys
root = sys.argv[1]
lst = json.loads(subprocess.check_output(["sh", root + "/src/usr/libexec/rpcd/tsem", "list"]))
acl = json.load(open(root + "/src/usr/share/rpcd/acl.d/tsem.json"))
reads = set(acl["tsem-read"]["read"]["ubus"]["tsem"])
assert "write" not in acl["tsem-read"], "read ACL must not grant write"
writes = set(acl["tsem-write"]["write"]["ubus"]["tsem"])
assert reads.isdisjoint(writes)
assert set(acl["tsem-write"]["read"]["ubus"]["tsem"]) == reads
assert reads | writes == set(lst), (reads | writes, set(lst))
assert writes == {"set_mode", "set_failover", "failover_now", "config_set", "notify_set", "notify_test"}
# no wildcard / unauthenticated grants anywhere
raw = open(root + "/src/usr/share/rpcd/acl.d/tsem.json").read()
assert '"*"' not in raw and "unauthenticated" not in raw
PY
}

test_api_status_is_the_controllers_status() {
	_api_setup
	_o=$(api status)
	assert_eq ok true "$(printf '%s' "$_o" | jget ok)"
	assert_eq state BLOCKED "$(printf '%s' "$_o" | jget status.state)"
	assert_eq mode none "$(printf '%s' "$_o" | jget status.mode)"
	assert_eq ipv6 unverified "$(printf '%s' "$_o" | jget status.ipv6_protection)"
}

test_api_set_mode_german_reports_requested_and_reached() {
	_api_setup
	# both exit nodes are down: the request is accepted, but the reply must NOT claim an active exit node
	mdown "$P1"; mdown "$P2"
	_o=$(api set_mode '{"mode":"german","source":"gui"}')
	assert_eq requested german "$(printf '%s' "$_o" | jget requested)"
	assert_eq src gui "$(printf '%s' "$_o" | jget status.source)"
	assert_eq mode german "$(printf '%s' "$_o" | jget status.mode)"
	assert_eq active none "$(printf '%s' "$_o" | jget status.active_exit)"
	assert_eq guard blocked "$(printf '%s' "$_o" | jget status.guard)"
	tk 8
	assert_eq state BLOCKED "$(api status | jget status.state)"
	# the primary comes back: only now an exit node is reported as active
	mup "$P1"; tk 8
	_o=$(api status)
	assert_eq state PRIMARY_ACTIVE "$(printf '%s' "$_o" | jget status.state)"
	assert_eq active "$P1" "$(printf '%s' "$_o" | jget status.active_exit)"
	assert_never_open_after 0
}

test_api_direct_needs_explicit_confirmation() {
	_api_setup
	go_german 8
	_o=$(api set_mode '{"mode":"direct","source":"ha"}')
	assert_eq ok false "$(printf '%s' "$_o" | jget ok)"
	assert_eq code confirmation_required "$(printf '%s' "$_o" | jget code)"
	assert_eq mode german "$(st mode)"
	assert_eq guard german "$(guard)"
	_o=$(api set_mode '{"mode":"direct","source":"ha","confirm":true}')
	assert_eq ok true "$(printf '%s' "$_o" | jget ok)"
	assert_eq mode direct "$(st mode)"
	assert_eq guard open "$(guard)"
	assert_eq source ha "$(st source)"
}

test_api_rejects_invalid_arguments_without_side_effects() {
	_api_setup
	go_german 8
	_i=$(isum)
	for _j in '{"mode":"open"}' '{"mode":""}' '{}' '{"mode":"german","source":"x y"}' '{"mode":"german","source":"hw"}' \
		'{"mode":"german\"; touch '"$T"'/pwned; \""}' '{"mode":"german","source":"gui;touch '"$T"'/pwned"}' 'not json'; do
		_o=$(api set_mode "$_j")
		assert_eq "ok for $_j" false "$(printf '%s' "$_o" | jget ok)"
	done
	[ ! -e "$T/pwned" ] || fail "injection executed"
	assert_eq intent "$_i" "$(isum)"
	assert_eq mode german "$(st mode)"
	_o=$(api no_such_method)
	assert_eq code not_found "$(printf '%s' "$_o" | jget code)"
}

test_api_failover_policy_and_failover_now() {
	_api_setup
	go_german 8
	_o=$(api set_failover '{"mode":"off","source":"gui"}')
	assert_eq failover off "$(printf '%s' "$_o" | jget status.failover)"
	_o=$(api set_failover '{"mode":"sometimes"}')
	assert_eq ok false "$(printf '%s' "$_o" | jget ok)"
	api set_failover '{"mode":"auto"}' >/dev/null
	tk 4
	_o=$(api failover_now)
	assert_eq requested failover_now "$(printf '%s' "$_o" | jget requested)"
	tk 8
	assert_eq exit "$P2" "$(mexit)"
	# the secondary is down -> a manual failover back is refused, the guard stays closed
	mdown "$P1"; tk 2
	_o=$(api failover_now)
	assert_eq ok false "$(printf '%s' "$_o" | jget ok)"
	assert_eq code refused "$(printf '%s' "$_o" | jget code)"
	assert_never_open_after 0
}

test_api_config_set_validates_and_persists() {
	_api_setup
	_o=$(api config_set '{"primary":"100.64.0.20","primary_name":"alpha","secondary":"100.64.0.21","secondary_name":"beta","auto_return":false}')
	assert_eq ok true "$(printf '%s' "$_o" | jget ok)"
	assert_eq primary 100.64.0.20 "$(printf '%s' "$_o" | jget config.primary)"
	assert_eq auto_return false "$(printf '%s' "$_o" | jget config.auto_return)"
	grep -q '^TSEM_PRIMARY=100.64.0.20$' "$TSEM_CONF" || fail "config file not updated"
	grep -q '^TSEM_AUTO_RETURN=0$' "$TSEM_CONF" || fail "auto_return not stored"
	# the same file still parses with the controller's own loader
	assert_eq primary 100.64.0.20 "$(api config_get | jget config.primary)"
	_c=$(md5sum <"$TSEM_CONF")
	for _j in '{"primary":"999.1.1.1"}' '{"primary":""}' '{"primary":"100.64.0.5","secondary":"100.64.0.5"}' '{"secondary":"x;y"}' \
		'{"primary_name":"bad name"}' '{"auto_return":"maybe"}' '{}' '{"primary":"100.64.0.9$(id)"}'; do
		_o=$(api config_set "$_j")
		assert_eq "ok for $_j" false "$(printf '%s' "$_o" | jget ok)"
		assert_eq "unchanged after $_j" "$_c" "$(md5sum <"$TSEM_CONF")"
	done
}

test_api_config_set_never_opens_the_guard() {
	_api_setup
	go_german 8
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	_s=$(ev_seq)
	api config_set '{"primary":"100.64.0.50","primary_name":"","secondary":"100.64.0.51"}' >/dev/null
	assert_never_open_after "$_s"
	assert_eq mode german "$(st mode)"
	assert_eq secondary 100.64.0.51 "$(api config_get | jget config.secondary)"
}

test_api_config_set_edits_the_mode_name_and_the_blocked_subnets() {
	_api_setup
	_o=$(api config_set '{"mode_label":"Office VPN","allow_subnets4":"10.5.0.0/24 10.6.0.0/24"}')
	assert_eq ok true "$(printf '%s' "$_o" | jget ok)"
	assert_eq label "Office VPN" "$(printf '%s' "$_o" | jget config.mode_label)"
	assert_eq subnets "10.5.0.0/24 10.6.0.0/24" "$(printf '%s' "$_o" | jget config.params.allow_subnets4)"
	assert_eq status_label "Office VPN" "$(api status | jget status.mode_label)"
	_c=$(md5sum <"$TSEM_CONF")
	for _j in '{"allow_subnets4":"10.0.0.0/8"}' '{"allow_subnets4":"0.0.0.0/0"}' '{"allow_subnets4":"172.16.0.0/12"}' '{"allow_subnets4":"10.5.0.0/24;reboot"}' 		'{"allow_subnets4":"10.1.0.0/24 10.2.0.0/24 10.3.0.0/24 10.4.0.0/24 10.5.0.0/24 10.6.0.0/24 10.7.0.0/24 10.8.0.0/24 10.9.0.0/24"}' 		'{"allow_subnets4":"not-a-net"}' '{"mode_label":"evil label!"}' '{"mode_label":""}' '{"mode_label":"abcdefghijklmnopqrstuvwxyz"}'; do
		_o=$(api config_set "$_j")
		assert_eq "refused $_j" false "$(printf '%s' "$_o" | jget ok)"
		assert_eq "unchanged after $_j" "$_c" "$(md5sum <"$TSEM_CONF")"
	done
	_o=$(api config_set '{"allow_subnets4":""}')
	assert_eq cleared true "$(printf '%s' "$_o" | jget ok)"
	assert_eq none "" "$(api config_get | jget config.params.allow_subnets4)"
}

test_api_changing_the_blocked_subnets_while_protected_never_opens_the_guard() {
	_api_setup
	go_german 8
	assert_eq state PRIMARY_ACTIVE "$(st state)"
	_s=$(ev_seq)
	_o=$(api config_set '{"allow_subnets4":"10.9.0.0/24"}')
	assert_eq ok true "$(printf '%s' "$_o" | jget ok)"
	assert_never_open_after "$_s"
	assert_eq mode german "$(st mode)"
	assert_eq state PRIMARY_ACTIVE "$(st state)"
}

test_api_subnets_lists_advertised_and_allowed_networks_read_only() {
	_api_setup
	printf '10.5.0.0/24\n10.6.0.0/24\n10.0.0.0/8\n' >"$TSEM_MOCK_DIR/subnets"
	api config_set '{"allow_subnets4":"10.5.0.0/24 10.9.0.0/24"}' >/dev/null
	_o=$(api subnets)
	assert_eq ok true "$(printf '%s' "$_o" | jget ok)"
	assert_eq avail true "$(printf '%s' "$_o" | jget result.available)"
	assert_contains advertised '"cidr":"10.6.0.0/24","allowed":false,"present":true,"selectable":true' "$(tsem subnets --json)"
	assert_contains allowed '"cidr":"10.5.0.0/24","allowed":true,"present":true,"selectable":true' "$(tsem subnets --json)"
	assert_contains configured_only '"cidr":"10.9.0.0/24","allowed":true,"present":false,"selectable":true' "$(tsem subnets --json)"
	assert_contains blanket_not_selectable '"cidr":"10.0.0.0/8","allowed":false,"present":true,"selectable":false' "$(tsem subnets --json)"
	_c=$(md5sum <"$TSEM_CONF")
	api subnets >/dev/null
	assert_eq "reading changes nothing" "$_c" "$(md5sum <"$TSEM_CONF")"
}

test_api_nodes_lists_peers_with_role() {
	_api_setup
	printf 'alpha|%s|true|true|alpha\nlaptop|100.64.0.99|true|false|laptop\n' "$P1" >"$TSEM_MOCK_DIR/peers"
	_o=$(api nodes)
	assert_eq available true "$(printf '%s' "$_o" | jget result.available)"
	printf '%s' "$_o" | python3 -c 'import sys,json
n=json.load(sys.stdin)["result"]["nodes"]
assert n[0]["role"]=="primary" and n[0]["exit_option"] is True and n[1]["role"]=="none" and n[1]["exit_option"] is False, n' || fail "nodes wrong"
	mflag scan_fail
	assert_eq available false "$(api nodes | jget result.available)"
}

test_api_events_and_diag_are_valid_json() {
	_api_setup
	_o=$(api events)
	printf '%s' "$_o" | jvalid || fail "events not valid JSON"
	printf '%s' "$_o" | python3 -c 'import sys,json
e=json.load(sys.stdin)["events"]; assert len(e)==2 and "back\\slash" in e[1], e' || fail "event escaping wrong"
	api diag | jvalid || fail "diag not valid JSON"
}

test_api_concurrent_mode_changes_leave_a_consistent_state() {
	_api_setup
	_i=0
	while [ "$_i" -lt 6 ]; do
		if [ $((_i % 2)) -eq 0 ]; then api set_mode '{"mode":"german","source":"gui"}' >/dev/null 2>&1 &
		else api set_mode '{"mode":"direct","confirm":true,"source":"ha"}' >/dev/null 2>&1 & fi
		_i=$((_i + 1))
	done
	wait
	assert_rc intent-valid 0 tsem intent-check
	_m=$(st mode)
	case $_m in german | direct) ;; *) fail "mode is '$_m'" ;; esac
	# the last writer wins and the guard matches it. german: the guard is 'blocked' until an exit node is proven and
	# 'german' once the activation tick of the last writer has finished (a normal progression that depends only on
	# timing); the invariant is that it is never open.
	case $_m in
	german) case $(guard) in blocked | german) ;; *) fail "guard in german must be blocked or german, got '$(guard)'" ;; esac ;;
	direct) assert_eq guard open "$(guard)" ;;
	esac
	assert_eq leak false "$(st leak_risk)"
}

test_api_without_controller_is_a_clean_error() {
	_api_setup
	_o=$(printf '{}' | TSEM_BIN=$T/nope "$SH" "$ROOT/src/usr/libexec/rpcd/tsem" call status)
	assert_eq code backend "$(printf '%s' "$_o" | jget code)"
}

# ---- tsem-api-check (read-only security check run on the router)
_chk_stubs() { # unauth behaviour: refuse | read | write
	mkdir -p "$T/chk"
	cat >"$T/chk/curl" <<STUB
#!/bin/sh
case "\$*" in
*session*login*) echo '{"jsonrpc":"2.0","id":1,"result":[6]}' ;;
*'"status"'*) [ "\${CHK_MODE:-refuse}" = read ] && echo '{"jsonrpc":"2.0","id":1,"result":[0,{"ok":true,"status":{}}]}' || echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"Access denied"}}' ;;
*config_set*) [ "\${CHK_MODE:-refuse}" = write ] && echo '{"jsonrpc":"2.0","id":1,"result":[0,{"ok":false,"code":"invalid_argument"}]}' || echo '{"jsonrpc":"2.0","id":1,"result":[6]}' ;;
esac
STUB
	printf '#!/bin/sh\necho set_mode\n' >"$T/chk/ubus"
	printf '#!/bin/sh\n[ "$1" = -q ] && shift\n[ "$2" = uhttpd.main.listen_http ] || [ "$1" = get ] && echo "0.0.0.0:8080"\n' >"$T/chk/uci"
	cat >"$T/chk/iptables" <<'STUB'
#!/bin/sh
case ${CHK_WAN:-none} in
nochain) exit 1 ;;
accept) echo "-N zone_wan_input"; echo "-A zone_wan_input -p tcp -m tcp --dport 8080 -j ACCEPT" ;;
*) echo "-N zone_wan_input"; echo "-A zone_wan_input -j input_wan_rule"; echo "-A zone_wan_input -j zone_wan_src_REJECT" ;;
esac
STUB
	chmod +x "$T/chk/"*
}
_chk() {
	PATH=$T/chk:$PATH TSEM_PLUGIN=$ROOT/src/usr/libexec/rpcd/tsem TSEM_ACL=$ROOT/src/usr/share/rpcd/acl.d/tsem.json "$SH" "$ROOT/src/usr/sbin/tsem-api-check" "$@"
}

test_api_check_passes_when_unauthenticated_access_is_refused() {
	_api_setup; _chk_stubs
	_o=$(_chk); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains plugin "PASS plugin" "$_o"
	assert_contains unauth "PASS unauth-read" "$_o"
	assert_contains write "PASS unauth-write" "$_o"
	assert_contains wan "PASS wan-exposure" "$_o"
	assert_contains result "API_CHECK=ok" "$_o"
}

test_api_check_fails_on_unauthenticated_read_or_write_or_wan_accept() {
	_api_setup; _chk_stubs
	_o=$(CHK_MODE=read _chk); assert_eq read-rc 1 $?; assert_contains r "FAIL unauth-read" "$_o"
	_o=$(CHK_MODE=write _chk); assert_eq write-rc 1 $?; assert_contains w "FAIL unauth-write" "$_o"
	_o=$(CHK_WAN=accept _chk); assert_eq wan-rc 1 $?; assert_contains wan "FAIL wan-exposure" "$_o"
	assert_contains fail "API_CHECK=fail" "$_o"
}

test_api_check_reports_unverified_not_pass_without_endpoint_or_firewall() {
	_api_setup; _chk_stubs
	printf '#!/bin/sh\nexit 7\n' >"$T/chk/curl"
	_o=$(_chk)
	assert_contains endpoint "WARN http-endpoint" "$_o"
	case $_o in *"PASS unauth-read"*) fail "an unreachable endpoint must not be reported as a pass" ;; esac
	_chk_stubs
	_o=$(CHK_WAN=nochain _chk)
	assert_contains wan "UNVERIFIED wan-exposure" "$_o"
}

test_api_check_flags_a_wildcard_acl() {
	_api_setup; _chk_stubs
	cp "$ROOT/src/usr/share/rpcd/acl.d/tsem.json" "$T/acl.json"
	sed -i 's/"set_mode"/"*"/' "$T/acl.json"
	_o=$(PATH=$T/chk:$PATH TSEM_PLUGIN=$ROOT/src/usr/libexec/rpcd/tsem TSEM_ACL=$T/acl.json "$SH" "$ROOT/src/usr/sbin/tsem-api-check")
	assert_contains acl "FAIL acl" "$_o"
}

test_config_get_exposes_read_only_parameters_and_they_cannot_be_written() {
	_api_setup
	assert_eq interval 5 "$(api config_get | jget config.params.interval)"
	assert_eq failn 3 "$(api config_get | jget config.params.fail_n)"
	_o=$(api config_set '{"interval":"1","fail_n":"1"}')
	assert_eq refused false "$(printf '%s' "$_o" | jget ok)"
	assert_eq unchanged 5 "$(api config_get | jget config.params.interval)"
}

test_every_entry_point_works_without_a_path_from_its_caller() {
	# The web server bridge runs the plugin from io.popen WITHOUT a PATH; GNU timeout then cannot find tailscale
	# (seen on a GL-MT3000 as "tailscale status unavailable" on every GUI action). Each layer fixes the PATH itself.
	grep -qF 'PATH=\"${PATH:+$PATH:}/usr/sbin:/usr/bin:/sbin:/bin\" sh ' "$ROOT/src/usr/lib/oui-httpd/rpc/tsem" || fail "bridge must set PATH for the plugin"
	grep -q '^PATH=${PATH:+$PATH:}/usr/sbin:/usr/bin:/sbin:/bin; export PATH' "$ROOT/src/usr/libexec/rpcd/tsem" || fail "plugin must extend PATH"
	grep -q '^PATH=${PATH:+$PATH:}/usr/sbin:/usr/bin:/sbin:/bin; export PATH' "$ROOT/src/usr/sbin/tsem" || fail "controller must extend PATH"
	# and it really works with an empty environment
	_o=$(env -i TSEM_LIBDIR="$ROOT/src/usr/lib/tsem" "$SH" "$ROOT/src/usr/sbin/tsem" 2>&1); assert_contains usage "usage" "$_o"
}

test_api_egress_reads_the_public_address_sanitises_it_and_is_read_only() {
	_api_setup
	export TSEM_RUN_DIR=$T/run; mkdir -p "$TSEM_RUN_DIR"
	printf '#!/bin/sh\ncat <<J\n{\n  "YourFuckingIPAddress": "203.0.113.7",\n  "YourFuckingLocation": "Bonn, <b>NW</b>, Germany",\n  "YourFuckingHostname": "h-7.example.net",\n  "YourFuckingISP": "Example ISP \\\\"GmbH\\\\"",\n  "YourFuckingTorExit": false,\n  "YourFuckingCountry": "Germany",\n  "YourFuckingCountryCode": "DE"\n}\nJ\n' >"$T/curl-ok"
	chmod +x "$T/curl-ok"
	export TSEM_CURL=$T/curl-ok
	_o=$(api egress)
	assert_eq ok true "$(printf '%s' "$_o" | jget ok | tr 'A-Z' 'a-z')"
	assert_eq ip "203.0.113.7" "$(printf '%s' "$_o" | jget result.ip)"
	assert_eq cc "DE" "$(printf '%s' "$_o" | jget result.country_code)"
	# the answer is untrusted text: no markup characters survive
	case $_o in *'<'* | *'>'* | *'\\"GmbH'*) fail "unsanitised text in the reply: $_o" ;; esac
	assert_contains loc "Bonn" "$_o"
	# the GUI button asks with --refresh: within 5 s it is answered from the cache, later it asks again
	printf '#!/bin/sh\necho "{ \\"YourFuckingIPAddress\\": \\"198.51.100.9\\" }"\n' >"$T/curl-ok2"; chmod +x "$T/curl-ok2"
	export TSEM_CURL=$T/curl-ok2
	assert_eq cached "203.0.113.7" "$(api egress | jget result.ip)"
	assert_eq refreshed "198.51.100.9" "$(TSEM_NOW=$(( $(date +%s) + 10 )) "$SH" "$ROOT/src/usr/sbin/tsem" egress --json --refresh | jget ip)"
	# unreachable / garbage: ok=false, never a made-up address
	rm -f "$TSEM_RUN_DIR/egress"; printf '#!/bin/sh\necho "<html>nope</html>"\n' >"$T/curl-bad"; chmod +x "$T/curl-bad"; export TSEM_CURL=$T/curl-bad
	assert_eq failed false "$(api egress | jget result.ok | tr 'A-Z' 'a-z')"
	# the method exists in the read ACL only
	grep -q '"egress"' "$ROOT/src/usr/share/rpcd/acl.d/tsem.json" || fail "egress missing in the ACL"
	unset TSEM_CURL TSEM_RUN_DIR
}

_api_notify_setup() {
	_api_setup
	printf '#!/bin/sh\nexec "%s" "%s/src/usr/sbin/tsem-notify" "$@"\n' "$SH" "$ROOT" >"$T/bin/tsem-notify"; chmod +x "$T/bin/tsem-notify"
	export TSEM_NOTIFY_BIN=$T/bin/tsem-notify TSEM_NOTIFY_CONF=$T/notify.conf TSEM_NOTIFY_TOKEN=$T/notify.token TSEM_NOTIFY_TOKEN2=$T/notify.token2
	export TSEM_RUN_DIR=$T/run TSEM_CURL=$T/bin/curl TSEM_SYSLOG=0
	mkdir -p "$T/run"
	printf '#!/bin/sh\nprintf "%%s\n" "$*" >>"%s/curl.args"\nexit 0\n' "$T" >"$T/bin/curl"; chmod +x "$T/bin/curl"
}

test_api_notify_set_saves_server_topic_and_tokens_and_never_returns_them() {
	_api_notify_setup
	_r=$(api notify_set '{"server":"https://ntfy.example","topic":"very-secret-topic","fallback_server":"http://192.0.2.10:8098","token":"tk_main123","fallback_token":"tk_lan456","name":"r7"}')
	assert_eq ok true "$(printf '%s' "$_r" | jget ok)"
	assert_eq server ntfy.example "$(printf '%s' "$_r" | jget notify.server)"
	assert_eq fallback 192.0.2.10:8098 "$(printf '%s' "$_r" | jget notify.fallback_server)"
	assert_eq token true "$(printf '%s' "$_r" | jget notify.token)"
	assert_eq fbtoken true "$(printf '%s' "$_r" | jget notify.fallback_token)"
	case $_r in *very-secret-topic* | *tk_main123* | *tk_lan456*) fail "the reply must never contain the topic or a token" ;; esac
	assert_contains topic-in-file "NOTIFY_URL=https://ntfy.example/very-secret-topic" "$(cat "$T/notify.conf")"
	assert_eq tokenfile "tk_main123" "$(cat "$T/notify.token")"
	assert_eq mode 600 "$(stat -c %a "$T/notify.token" 2>/dev/null || stat -f %Lp "$T/notify.token")"
	_g=$(api notify_get)
	assert_eq get-server ntfy.example "$(printf '%s' "$_g" | jget notify.server)"
	case $_g in *very-secret-topic* | *tk_main123*) fail "notify_get must never contain the topic or a token" ;; esac
}

test_api_notify_set_keeps_an_existing_token_when_none_is_sent() {
	_api_notify_setup
	api notify_set '{"server":"https://ntfy.example","topic":"t1","token":"tk_keep1"}' >/dev/null
	_r=$(api notify_set '{"server":"https://other.example","topic":"t2"}')
	assert_eq server other.example "$(printf '%s' "$_r" | jget notify.server)"
	assert_eq token-kept true "$(printf '%s' "$_r" | jget notify.token)"
	assert_eq content "tk_keep1" "$(cat "$T/notify.token")"
}

test_api_notify_set_public_and_bad_input() {
	_api_notify_setup
	# a fresh router has no topic to carry over: a server alone is not enough
	assert_eq no-topic false "$(api notify_set '{"server":"https://x.example"}' | jget ok)"
	_r=$(api notify_set '{"public":true}')
	assert_eq ok true "$(printf '%s' "$_r" | jget ok)"
	assert_eq host ntfy.sh "$(printf '%s' "$_r" | jget notify.server)"
	case $(sed -n 's/^NOTIFY_URL=//p' "$T/notify.conf") in https://ntfy.sh/tsem-*) ;; *) fail "public must use ntfy.sh with a random topic" ;; esac
	_before=$(cat "$T/notify.conf")
	for _j in '{}' '{"server":"ftp://x/y","topic":"t"}' '{"server":"https://x.example","topic":"a/b"}' '{"server":"https://x.example","topic":"t","token":"a;b"}' '{"server":"https://x.example","topic":"t","events":"X;Y"}'; do
		_e=$(api notify_set "$_j")
		assert_eq "refused $_j" false "$(printf '%s' "$_e" | jget ok)"
		assert_eq "code $_j" invalid_argument "$(printf '%s' "$_e" | jget code)"
		assert_eq "config untouched after $_j" "$_before" "$(cat "$T/notify.conf")"
	done
}

test_api_notify_get_without_config_and_notify_test() {
	_api_notify_setup
	assert_eq none false "$(api notify_get | jget notify.configured)"
	assert_eq refused false "$(api notify_test | jget ok)"
	api notify_set '{"server":"https://ntfy.example","topic":"t1"}' >/dev/null
	_t=$(api notify_test)
	assert_eq sent true "$(printf '%s' "$_t" | jget ok)"
	case $_t in *t1*) ;; esac
	assert_contains url "https://ntfy.example/t1" "$(cat "$T/curl.args")"
}

test_api_notify_set_keeps_topic_name_events_and_the_backup_server_when_the_form_leaves_them_empty() {
	_api_notify_setup
	printf 'NOTIFY_TYPE=ntfy\nNOTIFY_URL=https://ntfy.example/keep-this-topic\nNOTIFY_URL_FALLBACK=http://192.0.2.10:8098/keep-this-topic\nNOTIFY_NAME=router9\nNOTIFY_EVENTS="failover blocked recovered exit direct error"\n' >"$T/notify.conf"
	# only a token is sent, as when the user pastes a new token into the form
	_r=$(api notify_set '{"token":"tk_new789"}')
	assert_eq ok true "$(printf '%s' "$_r" | jget ok)"
	_c=$(cat "$T/notify.conf")
	assert_contains url "NOTIFY_URL=https://ntfy.example/keep-this-topic" "$_c"
	assert_contains fb "NOTIFY_URL_FALLBACK=http://192.0.2.10:8098/keep-this-topic" "$_c"
	assert_contains name "NOTIFY_NAME=router9" "$_c"
	assert_contains events 'NOTIFY_EVENTS="failover blocked recovered exit direct error"' "$_c"
	assert_contains tokfile "NOTIFY_TOKEN_FILE=$T/notify.token" "$_c"
	# the backup server can be removed on purpose
	_r=$(api notify_set '{"clear_fallback":true}')
	assert_eq ok true "$(printf '%s' "$_r" | jget ok)"
	case $(cat "$T/notify.conf") in *NOTIFY_URL_FALLBACK*) fail "the backup server must be gone" ;; esac
	assert_contains url-still "NOTIFY_URL=https://ntfy.example/keep-this-topic" "$(cat "$T/notify.conf")"
}

test_api_set_mode_direct_with_a_duration_starts_the_timer_and_bad_ones_are_refused() {
	_api_setup
	_r=$(api set_mode '{"mode":"direct","confirm":true,"duration":"30m"}')
	assert_eq ok true "$(printf '%s' "$_r" | jget ok)"
	_u=$(printf '%s' "$_r" | jget status.direct_until)
	[ "$_u" -gt 0 ] || fail "the reply must show the timer (direct_until), got $_u"
	assert_eq return german "$(printf '%s' "$_r" | jget status.direct_return)"
	for _j in '{"mode":"direct","confirm":true,"duration":"0"}' '{"mode":"direct","confirm":true,"duration":"abc"}' '{"mode":"direct","confirm":true,"duration":"25h"}' \
		'{"mode":"german","duration":"30m"}' '{"mode":"direct","confirm":true,"duration":"5;reboot"}'; do
		assert_eq "refused $_j" false "$(api set_mode "$_j" | jget ok)"
	done
	# DIRECT again without a duration removes the timer
	_r=$(api set_mode '{"mode":"direct","confirm":true}')
	assert_eq removed 0 "$(printf '%s' "$_r" | jget status.direct_until)"
}

test_api_leaktest_returns_the_result_object_even_when_the_test_fails() {
	_api_setup
	# no valid mode in this fixture: the test FAILs, and the API still hands over the result
	_r=$(api leaktest)
	assert_eq ok true "$(printf '%s' "$_r" | jget ok)"
	assert_eq result fail "$(printf '%s' "$_r" | jget result.result)"
	assert_contains scope router "$(printf '%s' "$_r" | jget result.scope)"
}

test_api_report_returns_the_numbers_for_the_period() {
	_api_setup
	_t=$TSEM_NOW
	printf '%s\n' "$((_t - 100000))|BOOT" "$((_t - 100000))|PRIMARY_ACTIVE" "$((_t - 1000))|BLOCKED" >"$TSEM_STATE_DIR/history"
	_r=$(api report '{"days":3}')
	assert_eq ok true "$(printf '%s' "$_r" | jget ok)"
	assert_eq days 3 "$(printf '%s' "$_r" | jget result.days)"
	assert_eq exit 99000 "$(printf '%s' "$_r" | jget result.seconds.exit)"
	assert_eq blocked 1000 "$(printf '%s' "$_r" | jget result.seconds.blocked)"
	assert_eq refused false "$(api report '{"days":500}' | jget ok)"
	assert_eq refused2 false "$(api report '{"days":"x;y"}' | jget ok)"
}
