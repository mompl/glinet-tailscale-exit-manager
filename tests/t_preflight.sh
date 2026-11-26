# shellcheck shell=sh
# Tests for tools/tsem-preflight.sh (read-only router preflight) and tools/run-preflight-mac.sh.
# A fake "root" (files under $T/root, command stubs under $T/bin) feeds the script; the stubs log
# every call so the tests can prove that only read-only queries were made.

pf_stub() { printf '#!/bin/sh\n%s\n' "$2" >"$B/$1"; chmod +x "$B/$1"; }

pf_status() { # primary-online primary-exitoption [secondary-online secondary-exitoption | none]
	cat <<J
{
  "Version": "1.92.5",
  "BackendState": "Running",
  "Self": {
    "HostName": "root",
    "TailscaleIPs": [
      "100.64.0.99"
    ],
    "Online": true,
    "PublicKey": "nodekey:SELFSECRET"
  },
  "Peer": {
    "nodekey:aaaa": {
      "ID": "n1",
      "HostName": "exit-a",
      "DNSName": "exit-a.tail1234.ts.net.",
      "TailscaleIPs": [
        "100.64.0.30",
        "fd7a:115c:a1e0::1"
      ],
      "Online": $1,
      "ExitNodeOption": $2
    }
J
	if [ "${3:-none}" != none ]; then
		cat <<J
    ,"nodekey:bbbb": {
      "ID": "n2",
      "HostName": "exit-b",
      "DNSName": "exit-b.tail1234.ts.net.",
      "TailscaleIPs": [
        "100.64.0.31"
      ],
      "Online": $3,
      "ExitNodeOption": $4
    }
J
	fi
	printf '  }\n}\n'
}

# Resolve a tool to a real binary for the fake router PATH. A sandbox may put a guard wrapper for rm first on PATH
# (".../rm-guard/..."); that wrapper only works with a further rm on PATH, so linking it into the isolated fake PATH
# makes every delete fail (this was the cause of the local-only failure D10). Wrappers are skipped here.
pf_realcmd() {
	_o=$IFS; IFS=:
	for _d in $PATH; do
		case $_d in */rm-guard/*) continue ;; esac
		if [ -x "$_d/$1" ] && [ ! -d "$_d/$1" ]; then IFS=$_o; printf '%s\n' "$_d/$1"; return 0; fi
	done
	IFS=$_o; return 1
}
pf_fixture() {
	PFX=$T/fx RT=$T/root B=$T/bin
	mkdir -p "$PFX" "$B" "$T/tmp" "$RT/etc/config" "$RT/etc/rc.d" "$RT/etc/gl-switch.d" "$RT/tmp/sysinfo" "$RT/sbin" \
		"$RT/proc/sys/net/ipv6/conf/all" "$RT/overlay"
	SHP=$(command -v "$SH")
	for _c in awk sed grep cut tr head tail sort uniq ls cat date uname md5sum sha256sum wc find dirname basename flock timeout mkdir rm busybox gzip tar; do
		_p=$(pf_realcmd $_c) && ln -sf "$_p" "$B/$_c"
	done
	ln -sf "$SHP" "$B/sh"
	: >"$PFX/calls"
	pf_stub ip 'echo "ip $*" >>"$PFX/calls"
case "$*" in
"rule show") cat "$PFX/ip.rule" ;;
"-6 rule show") printf "0:\tfrom all lookup local\n" ;;
"route show table 52") cat "$PFX/ip.t52" ;;
"route show default") cat "$PFX/ip.maindef" ;;
"rule help") echo "SUPPRESSOR := [ suppress_prefixlength NUMBER ]" >&2; exit 255 ;;
"link show tailscale0" | "link show br-lan") [ ! -e "$PFX/nolink_$3" ] || exit 1; echo "2: $3: <UP> mtu 1500" ;;
"-6 addr show scope global") cat "$PFX/ip6.addr" 2>/dev/null; true ;;
"-6 route show default") cat "$PFX/ip6.route" 2>/dev/null; true ;;
*) echo "UNEXPECTED ip $*" >>"$PFX/calls"; exit 99 ;;
esac'
	pf_stub iptables 'echo "iptables $*" >>"$PFX/calls"
case "$*" in
"-V") cat "$PFX/ipt.V" ;;
"-w 5 -S") cat "$PFX/ipt.S" ;;
"-w 5 -t nat -S") [ -e "$PFX/ipt.nat" ] || exit 1; cat "$PFX/ipt.nat" ;;
*) echo "UNEXPECTED iptables $*" >>"$PFX/calls"; exit 99 ;;
esac'
	pf_stub uci 'echo "uci $*" >>"$PFX/calls"
if [ "$1 $2" = "-q show" ]; then [ -f "$PFX/uci.$3" ] || exit 1; cat "$PFX/uci.$3"; else echo "UNEXPECTED uci $*" >>"$PFX/calls"; exit 99; fi'
	pf_stub tailscale 'echo "tailscale $*" >>"$PFX/calls"
case "$*" in
"version") cat "$PFX/ts.version" ;;
"status --json") [ ! -e "$PFX/ts_dead" ] || { echo "failed to connect to local tailscaled" >&2; exit 1; }; cat "$PFX/ts.status" ;;
"debug prefs") [ ! -e "$PFX/ts_dead" ] || exit 1; cat "$PFX/ts.prefs" ;;
*) echo "UNEXPECTED tailscale $*" >>"$PFX/calls"; exit 99 ;;
esac'
	pf_stub ps 'echo "ps $*" >>"$PFX/calls"; cat "$PFX/ps.out"'
	pf_stub netstat 'echo "netstat $*" >>"$PFX/calls"; cat "$PFX/netstat.out"'
	pf_stub df 'echo "df $*" >>"$PFX/calls"; cat "$PFX/df.out"'
	for _c in ip6tables curl mosquitto_pub logger; do pf_stub "$_c" 'exit 0'; done
	printf '0:\tfrom all lookup local\n5210:\tfrom all fwmark 0x80000/0xff0000 lookup main\n5270:\tfrom all lookup 52\n32766:\tfrom all lookup main\n32767:\tfrom all lookup default\n' >"$PFX/ip.rule"
	printf '10.30.0.0/24 dev tailscale0 \n10.30.1.0/24 dev tailscale0 \n10.30.2.0/24 dev tailscale0 \n100.64.0.0/10 dev tailscale0 \n' >"$PFX/ip.t52"
	echo "default via 192.168.8.1 dev apclix0 proto static" >"$PFX/ip.maindef"
	echo "iptables v1.8.7 (legacy)" >"$PFX/ipt.V"
	cat >"$PFX/ipt.S" <<'J'
-P INPUT ACCEPT
-P FORWARD DROP
-N forwarding_lan_rule
-A forwarding_lan_rule -m comment --comment "!fw3" -j zone_tailscale0_dest_ACCEPT
J
	cat >"$PFX/ipt.nat" <<'J'
-P PREROUTING ACCEPT
-N zone_tailscale0_postrouting
-A POSTROUTING -m comment --comment "!fw3" -j zone_tailscale0_postrouting
-A zone_tailscale0_postrouting -m comment --comment "!fw3" -j MASQUERADE
J
	cat >"$PFX/uci.firewall" <<'J'
firewall.@defaults[0]=defaults
firewall.@defaults[0].input='ACCEPT'
firewall.@defaults[0].flow_offloading='0'
firewall.lan=zone
firewall.lan.name='lan'
firewall.tailscale0=zone
firewall.tailscale0.name='tailscale0'
firewall.tailscale0.masq='1'
firewall.tailscale0.device='tailscale0'
firewall.lan_tailscale=forwarding
firewall.lan_tailscale.src='lan'
firewall.lan_tailscale.dest='tailscale0'
firewall.@include[0]=include
firewall.@include[0].path='/etc/firewall.user'
J
	printf "dhcp.@dnsmasq[0]=dnsmasq\ndhcp.@dnsmasq[0].server='100.100.100.100'\ndhcp.lan=dhcp\ndhcp.lan.ra='disabled'\n" >"$PFX/uci.dhcp"
	printf "network.lan=interface\nnetwork.lan.proto='static'\n" >"$PFX/uci.network"
	printf "glconfig.switch_button=switch_button\nglconfig.switch_button.func='tailscale'\n" >"$PFX/uci.glconfig"
	pf_status true true true true >"$PFX/ts.status"
	printf '{\n  "RouteAll": true,\n  "ExitNodeID": "",\n  "ExitNodeIP": "",\n  "AdvertiseRoutes": null,\n  "AuthKey": "tskey-SECRETSECRET"\n}\n' >"$PFX/ts.prefs"
	printf '1.92.5\n  tailscale commit: abc\n' >"$PFX/ts.version"
	printf '  PID USER COMMAND\n    1 root /sbin/procd\n  321 root /usr/sbin/tailscaled --state=/etc/tailscale/tailscaled.state\n' >"$PFX/ps.out"
	echo "udp 0 0 0.0.0.0:53 0.0.0.0:* 321/dnsmasq" >"$PFX/netstat.out"
	printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/ubi0_1 100000 20000 80000 20%% /overlay\n' >"$PFX/df.out"
	printf "DISTRIB_RELEASE='21.02.7'\n" >"$RT/etc/openwrt_release"
	echo "GL.iNet GL-MT3000" >"$RT/tmp/sysinfo/model"
	echo "4.11.0" >"$RT/etc/glversion"
	: >"$RT/sbin/fw3"
	for _c in firewall network dhcp glconfig; do printf 'config x\n' >"$RT/etc/config/$_c"; done
	echo "# nothing" >"$RT/etc/firewall.user"
	: >"$RT/etc/rc.d/S19firewall"
	: >"$RT/etc/rc.d/S20network"
	: >"$RT/etc/rc.d/S80tailscale"
	printf '#!/bin/sh\n# GL prototype\ntailscale set --exit-node=x\n' >"$RT/etc/gl-switch.d/tailscale-de.sh"
	chmod 755 "$RT/etc/gl-switch.d/tailscale-de.sh"
	echo "MemAvailable:     300000 kB" >"$RT/proc/meminfo"
	echo 0 >"$RT/proc/sys/net/ipv6/conf/all/disable_ipv6"
	echo "nameserver 127.0.0.1" >"$RT/tmp/resolv.conf"
	: >"$PFX/ip6.addr"
	: >"$PFX/ip6.route"
	# GL.iNet 4.x web UI layout (what native-gui looks for); LuCI present
	mkdir -p "$RT/usr/share/oui/menu.d" "$RT/www/views" "$RT/usr/lib/oui-httpd/rpc" "$RT/www/luci-static/resources"
	printf '{\n\t"index": 31,\n\t"view": "tailscale",\n\t"title": "Tailscale",\n\t"level": 2,\n\t"parent": "applications"\n}\n' >"$RT/usr/share/oui/menu.d/tailscale.json"
	printf '{"index": 32, "view": "zerotier", "parent": "applications"}\n' >"$RT/usr/share/oui/menu.d/zerotier.json"
	printf 'var a="Admin-Token";post("/rpc",{headers:{glinet:1}});method:"call";\n' | gzip -9nc >"$RT/www/views/gl-sdk4-ui-tailscale.common.js.gz"
	printf 'local cjson = require "cjson"\nlocal M = {}\nreturn M\n' >"$RT/usr/lib/oui-httpd/rpc/tailscale"
	: >"$RT/www/luci-static/resources/luci.js"
}

pf_run() { # [extra args]
	PFOUT=$(PFX=$PFX PF_ROOT=$RT TMPDIR=$T/tmp PATH=$B "$SHP" "$ROOT/tools/tsem-preflight.sh" --repo "${PF_REPO:-$ROOT}" "$@" 2>"$T/pf.err")
	PFRC=$?
}
want() { printf '%s\n' "$PFOUT" | grep -Eq "^$1 +$2( |\$)" || fail "expected '$1 $2'; got: $(printf '%s\n' "$PFOUT" | grep -E "^(PASS|WARN|FAIL|SKIP) +$2( |\$)" | head -n 3) / summary: $(printf '%s\n' "$PFOUT" | grep -E '^(PASS=|RECOMMENDATION)')"; }
rec() { assert_contains recommendation "RECOMMENDATION: $1" "$PFOUT"; }
rcis() { [ "$PFRC" -eq "$1" ] || fail "exit code $PFRC, expected $1 ($(printf '%s\n' "$PFOUT" | grep -E '^(FAIL|SKIP)' | head -n 4))"; }
pf_snap() { (cd "$RT" && find . | sort | while IFS= read -r f; do if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(md5sum <"$f" | cut -c1-32)"; else printf '%s\n' "$f"; fi; done); }
pf_repo_copy() { PF_REPO=$T/repo2; mkdir -p "$PF_REPO"; cp -R "$ROOT/src" "$ROOT/contrib" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$PF_REPO/"; }

# ------------------------------------------------------------------ healthy reference
test_healthy_root_is_ready_for_passive_install() {
	# a router that was set up (nodes and the remote-site subnets configured) and a repository whose default config lists them
	pf_fixture; pf_repo_copy
	sed -i 's|^TSEM_ALLOW_SUBNETS4=.*|TSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24"|' "$PF_REPO/src/etc/tsem/tsem.conf"
	mkdir -p "$RT/etc/tsem"; printf 'TSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24"
TSEM_PRIMARY=100.64.0.30
TSEM_SECONDARY=100.64.0.31
' >"$RT/etc/tsem/tsem.conf"
	pf_run
	rcis 0; rec READY_FOR_PASSIVE_INSTALL
	printf '%s\n' "$PFOUT" | grep -Eq '^PASS=[0-9]+ WARN=0 FAIL=0 ' || fail "unexpected warnings/failures: $(printf '%s\n' "$PFOUT" | grep -E '^(WARN|FAIL)')"
	for _id in sys.openwrt sys.model sys.firmware sys.fw3 sys.iptables sys.tailscale sys.tools pr.tailscale pr.collision node.primary node.secondary \
		masq.uci masq.forward masq.nat masq.hook masq.live route.extnet0 route.extnet1 route.extnet2 allow.extnet0 sw.hook sw.uci dns.upstream ipv6.state \
		fw.includes fw.offload boot.order conf.allow conf.repo dry.run proof.readonly; do want PASS "$_id"; done
	assert_contains scope "NOT a release for the kill switch or GERMAN mode" "$PFOUT"
	_n=$(printf '%s\n' "$PFOUT" | grep -c '^SKIP')
	[ "$_n" -ge 5 ] || fail "deliberately skipped active tests must be reported as SKIP"
}

test_preflight_changes_nothing_and_only_reads() {
	pf_fixture; _s=$(pf_snap); _cp=$(cd "$ROOT" && find . -path ./.git -prune -o -type f -newer "$T/fx" -print | head -n 3)
	pf_run
	assert_eq "fake router unchanged" "$_s" "$(pf_snap)"
	assert_eq "no temp files" "" "$(ls -A "$T/tmp")"
	assert_eq "repo not modified" "" "$(cd "$ROOT" && find . -path ./.git -prune -o -type f -newer "$T/fx" -print | head -n 3)"
	! grep -q UNEXPECTED "$PFX/calls" || fail "unexpected command call: $(grep UNEXPECTED "$PFX/calls")"
	# every command the script ran is a read-only query
	! grep -Eq '^uci (-q )?(set|add|add_list|del_list|delete|commit|revert|import|rename|reorder)' "$PFX/calls" || fail "uci write call"
	! grep -Eq '^iptables .* -[AIDRFNXPZE] ' "$PFX/calls" || fail "iptables rule change"
	! grep -Eq '^ip .* (add|del|delete|replace|change|flush|set) ' "$PFX/calls" || fail "ip change"
	! grep -Eq '^tailscale (up|down|set|login|logout|ping|serve|funnel|cert|file)' "$PFX/calls" || fail "tailscale change or active probe"
	grep -q '^tailscale status --json' "$PFX/calls" || fail "status was not queried"
	assert_eq "no stderr noise" 0 "$(grep -c . "$T/pf.err")"
}

test_report_contains_no_secrets() {
	pf_fixture; pf_run
	for _s in tskey- nodekey SELFSECRET PublicKey AuthKey; do
		case $PFOUT in *"$_s"*) fail "report leaks '$_s'" ;; esac
	done
	assert_contains derived "routeall=yes advertise_exit=no exit_selected=no" "$PFOUT"
}

# ------------------------------------------------------------------ masquerading
test_masq_disabled_in_uci_is_fail() {
	pf_fixture; sed -i "s/masq='1'/masq='0'/" "$PFX/uci.firewall"; pf_run
	want FAIL masq.uci; rcis 1; rec NEEDS_FIX
}
test_missing_masquerade_rule_is_fail() {
	pf_fixture; grep -v MASQUERADE "$PFX/ipt.nat" >"$PFX/n" && mv "$PFX/n" "$PFX/ipt.nat"; pf_run
	want FAIL masq.nat; rcis 1; rec NEEDS_FIX
}
test_missing_postrouting_chain_is_fail() {
	pf_fixture; printf -- '-P PREROUTING ACCEPT\n' >"$PFX/ipt.nat"; pf_run
	want FAIL masq.nat; want FAIL masq.hook; rcis 1
}
test_missing_lan_to_tailscale_forwarding_is_fail() {
	pf_fixture; sed -i "s/dest='tailscale0'/dest='wan'/" "$PFX/uci.firewall"; pf_run
	want FAIL masq.forward; rcis 1
	pf_fixture; sed -i "s/lan_tailscale.src='lan'/lan_tailscale.src='lan'\nfirewall.lan_tailscale.enabled='0'/" "$PFX/uci.firewall"; pf_run
	want FAIL masq.forward
}
test_nat_table_unreadable_is_insufficient_evidence_not_pass() {
	pf_fixture; rm -f "$PFX/ipt.nat"; pf_run
	want SKIP masq.nat; rcis 2; rec INSUFFICIENT_EVIDENCE
}
test_missing_extnet_route_in_table52_is_fail() {
	pf_fixture; grep -v '10.30.1.0/24' "$PFX/ip.t52" >"$PFX/t" && mv "$PFX/t" "$PFX/ip.t52"; pf_run
	want FAIL route.extnet1; want PASS route.extnet0; want PASS route.extnet2; rcis 1; rec NEEDS_FIX
}
test_empty_table52_fails_all_extnet_routes() {
	pf_fixture; : >"$PFX/ip.t52"; pf_run
	want FAIL route.extnet0; want FAIL route.extnet1; want FAIL route.extnet2; want WARN pr.table52; rcis 1
}
test_further_private_routes_are_listed_as_warning_only() {
	pf_fixture; printf '10.20.5.0/24 dev tailscale0 \n192.168.50.0/24 dev tailscale0 \n' >>"$PFX/ip.t52"; pf_run
	want WARN masq.private; assert_contains list "10.20.5.0/24 192.168.50.0/24" "$PFOUT"; rcis 0; rec READY_FOR_PASSIVE_INSTALL
}
test_private_route_covered_by_allow_list_is_pass() {
	pf_fixture; printf '10.20.5.0/24 dev tailscale0 \n' >>"$PFX/ip.t52"
	mkdir -p "$RT/etc/tsem"; printf 'TSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24 10.20.5.0/24"\n' >"$RT/etc/tsem/tsem.conf"; pf_run
	want PASS masq.private; want PASS conf.allow
}

# ------------------------------------------------------------------ configuration
test_installed_config_without_extnet_subnets_warns() {
	pf_fixture; mkdir -p "$RT/etc/tsem"; printf 'TSEM_ALLOW_SUBNETS4=""\nTSEM_PRIMARY=100.64.0.30\nTSEM_SECONDARY=100.64.0.31\n' >"$RT/etc/tsem/tsem.conf"; pf_run
	want WARN conf.allow; want WARN allow.extnet0; want WARN allow.extnet2; rcis 0
}
test_blanket_rfc1918_in_config_warns() {
	pf_fixture; mkdir -p "$RT/etc/tsem"; printf 'TSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.0.0.0/8 bad;entry"\n' >"$RT/etc/tsem/tsem.conf"; pf_run
	want WARN conf.blanket; assert_contains blanket "10.0.0.0/8" "$(printf '%s\n' "$PFOUT" | grep conf.blanket)"
}
test_old_repository_copy_without_extnet_subnets_warns() {
	pf_fixture; pf_repo_copy; sed -i 's/^TSEM_ALLOW_SUBNETS4=.*/TSEM_ALLOW_SUBNETS4=""/' "$PF_REPO/src/etc/tsem/tsem.conf"; pf_run
	want WARN conf.repo; want WARN conf.allow
}
test_config_is_parsed_never_executed() {
	pf_fixture; mkdir -p "$RT/etc/tsem"; printf 'TSEM_ALLOW_SUBNETS4="10.30.0.0/24"\ntouch %s/pwned\n$(touch %s/pwned2)\n' "$T" "$T" >"$RT/etc/tsem/tsem.conf"; pf_run
	[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] || fail "configuration file was executed"
}

# ------------------------------------------------------------------ hardware switch
test_switch_hook_missing_warns() {
	pf_fixture; rm "$RT/etc/gl-switch.d/tailscale-de.sh"; pf_run
	want WARN sw.hook; rcis 0
}
test_switch_hook_not_executable_warns() {
	pf_fixture; chmod 644 "$RT/etc/gl-switch.d/tailscale-de.sh"; pf_run
	want WARN sw.hook; assert_contains notexec "NOT executable" "$PFOUT"
}
test_switch_mapping_deviating_or_missing_warns() {
	pf_fixture; printf "glconfig.switch_button=switch_button\nglconfig.switch_button.func='vpn'\n" >"$PFX/uci.glconfig"; pf_run
	want WARN sw.uci; assert_contains deviates "does not mention tailscale" "$PFOUT"
	pf_fixture; rm "$PFX/uci.glconfig" "$RT/etc/config/glconfig"; pf_run
	want WARN sw.uci
}
test_switch_is_never_toggled() {
	pf_fixture; pf_run
	want SKIP sw.toggle
	! grep -Eq 'gl-switch|button' "$PFX/calls" || fail "switch touched"
	assert_eq "hook untouched" "$(printf '#!/bin/sh\n# GL prototype\ntailscale set --exit-node=x\n')" "$(cat "$RT/etc/gl-switch.d/tailscale-de.sh")"
}

# ------------------------------------------------------------------ tools / system
test_missing_flock_is_fail_and_breaks_the_dry_run() {
	pf_fixture; rm "$B/flock"; pf_run
	want FAIL sys.tools; want FAIL dry.run; rcis 1; rec NEEDS_FIX
	assert_contains named "flock" "$(printf '%s\n' "$PFOUT" | grep sys.tools)"
}
test_missing_iptables_is_fail_with_missing_evidence() {
	pf_fixture; rm "$B/iptables"; pf_run
	want FAIL sys.iptables; want SKIP masq.nat; rcis 1
}
test_nft_iptables_or_fw4_is_fail() {
	pf_fixture; echo "iptables v1.8.7 (nf_tables)" >"$PFX/ipt.V"; pf_run; want FAIL sys.iptables
	pf_fixture; : >"$RT/sbin/fw4"; pf_run; want FAIL sys.fw3
}
test_wrong_model_is_fail() {
	pf_fixture; echo "GL.iNet GL-MG1300" >"$RT/tmp/sysinfo/model"; pf_run; want FAIL sys.model; rcis 1
}
test_missing_optional_tools_only_warn() {
	pf_fixture; rm "$B/timeout" "$B/curl" "$B/logger"; pf_run
	want WARN sys.optional; want WARN sys.http; rcis 0; rec READY_FOR_PASSIVE_INSTALL
}
test_other_openwrt_or_firmware_version_warns() {
	pf_fixture; printf "DISTRIB_RELEASE='23.05.3'\n" >"$RT/etc/openwrt_release"; echo "4.8.1" >"$RT/etc/glversion"; printf '1.80.0\n' >"$PFX/ts.version"; pf_run
	want WARN sys.openwrt; want WARN sys.firmware; want WARN sys.tailscale; rcis 0
}

# ------------------------------------------------------------------ tailscale nodes
test_tailscaled_down_is_insufficient_evidence() {
	pf_fixture; : >"$PFX/ts_dead"; pf_run
	want SKIP node.status; rcis 2; rec INSUFFICIENT_EVIDENCE
	assert_contains hint "evidence missing" "$PFOUT"
}
test_offline_or_missing_exit_nodes_warn_only() {
	pf_fixture; pf_status false true none >"$PFX/ts.status"; pf_run
	want WARN node.primary; want WARN node.secondary; rcis 0
	assert_contains offline "offline" "$(printf '%s\n' "$PFOUT" | grep node.primary)"
	pf_fixture; pf_status true false true true >"$PFX/ts.status"; pf_run
	assert_contains noexit "no-exit-option" "$(printf '%s\n' "$PFOUT" | grep node.primary)"
}
test_node_name_mismatch_warns() {
	pf_fixture; sed -i 's/"HostName": "exit-b"/"HostName": "someone-else"/; s/exit-b.tail1234/someone-else.tail1234/' "$PFX/ts.status"; pf_run
	want WARN node.secondary; assert_contains differs "name-differs:someone-else" "$PFOUT"
}
test_router_advertising_exit_node_or_no_accept_routes_warns() {
	pf_fixture; printf '{\n  "RouteAll": true,\n  "AdvertiseRoutes": [\n    "0.0.0.0/0",\n    "::/0"\n  ]\n}\n' >"$PFX/ts.prefs"; pf_run
	want WARN node.prefs; assert_contains adv "advertise_exit=yes" "$PFOUT"
	pf_fixture; printf '{\n  "RouteAll": false,\n  "AdvertiseRoutes": null\n}\n' >"$PFX/ts.prefs"; pf_run
	want WARN node.prefs
}
test_active_probes_are_never_made() {
	pf_fixture; pf_run
	want SKIP node.ping
	! grep -q '^tailscale ping' "$PFX/calls" || fail "active tailscale ping"
}

# ------------------------------------------------------------------ install state / dry run
test_existing_installation_is_detected() {
	pf_fixture
	mkdir -p "$RT/usr/sbin" "$RT/etc/tsem" "$RT/etc/init.d"
	: >"$RT/usr/sbin/tsem"; : >"$RT/etc/init.d/tsem"; : >"$RT/etc/rc.d/S18tsem"
	printf 'config defaults\n# tsem-begin (managed block, removed by uninstall)\nconfig include\n# tsem-end\n' >"$RT/etc/config/firewall"
	printf '  500 root /usr/sbin/tsem tick\n' >>"$PFX/ps.out"
	printf -- '-N TSEM_FWD\n' >>"$PFX/ipt.S"
	printf '5280:\tfrom all iif br-lan lookup main suppress_prefixlength 0\n5290:\tfrom all iif br-lan prohibit\n' >>"$PFX/ip.rule"
	pf_run
	for _id in tsem.files tsem.proc tsem.fwhook tsem.autostart tsem.chains tsem.rules boot.autostart; do want WARN "$_id"; done
	want PASS pr.collision
}
test_foreign_rule_on_tsem_priority_is_fail() {
	pf_fixture; printf '5280:\tfrom 10.0.0.0/8 lookup 100\n' >>"$PFX/ip.rule"; pf_run
	want FAIL pr.collision; rcis 1
}
test_dry_run_failure_is_fail() {
	pf_fixture; pf_repo_copy
	sed -i 's/for c in flock md5sum iptables ip awk sed; do/for c in flock md5sum iptables ip awk sed no_such_tool_xyz; do/' "$PF_REPO/install.sh"
	pf_run
	want FAIL dry.run; rcis 1; rec NEEDS_FIX
	assert_contains why "no_such_tool_xyz" "$PFOUT"
}
test_installer_without_dry_run_guard_is_not_executed() {
	pf_fixture; pf_repo_copy
	printf '#!/bin/sh\ntouch "%s/EXECUTED"\n' "$T" >"$PF_REPO/install.sh"
	pf_run
	want SKIP dry.run; [ ! -e "$T/EXECUTED" ] || fail "an installer without a verifiable dry-run guard was executed"
	rcis 2; rec INSUFFICIENT_EVIDENCE
}
test_dry_run_is_started_without_any_option_and_changes_nothing() {
	pf_fixture; pf_repo_copy
	# the repo copy's installer records its arguments, then performs the real dry run
	{ sed -n '1,/^set -u$/p' "$ROOT/install.sh"; printf 'printf "%%s\\n" "$*" >>"%s/install.args"\n' "$T"; sed '1,/^set -u$/d' "$ROOT/install.sh"; } >"$PF_REPO/install.sh"
	_s=$(pf_snap); pf_run
	assert_eq "dry run arguments" "--root $RT" "$(cat "$T/install.args")"
	assert_eq "root unchanged" "$_s" "$(pf_snap)"
	want PASS dry.run
}
test_repository_missing_is_fail_and_dry_run_skipped() {
	pf_fixture; PF_REPO=$T/nowhere; pf_run
	want FAIL repo.present; want SKIP dry.run; rcis 1
}
test_prototype_hook_is_reported_by_the_installer_note_on_a_real_root() {
	# On the router (no PF_ROOT) the installer itself warns that two controllers would compete.
	pf_fixture
	printf '#!/bin/sh\necho "WARNING: /etc/gl-switch.d/tailscale-de.sh exists and is NOT replaced: two controllers would compete."\necho "dry run only; nothing changed. Re-run with the apply option."\n' >/dev/null
	pf_repo_copy
	sed -i 's|^\tsay "plan:"|\tsay "  WARNING: /etc/gl-switch.d/tailscale-de.sh exists and is NOT replaced: two controllers would compete."\n\tsay "plan:"|' "$PF_REPO/install.sh"
	pf_run
	want WARN dry.notes; want PASS dry.run
}

# ------------------------------------------------------------------ DNS / IPv6 / firewall / boot
test_dns_external_resolvers_and_zero_resolver_warn() {
	pf_fixture; printf 'nameserver 1.1.1.1\nnameserver 0.0.0.0\n' >"$RT/tmp/resolv.conf"; pf_run
	want WARN dns.upstream; want WARN dns.zero; assert_contains ext "1.1.1.1" "$PFOUT"
}
test_foreign_dns_redirect_warns() {
	pf_fixture; printf -- '-A PREROUTING -i br-lan -p udp -m udp --dport 53 -j REDIRECT --to-ports 5353\n' >>"$PFX/ipt.nat"; pf_run
	want WARN dns.redirect
}
test_active_ipv6_warns() {
	pf_fixture
	printf '2: br-lan: <BROADCAST,UP> mtu 1500\n    inet6 2001:db8:1::1/64 scope global\n3: tailscale0: <UP>\n    inet6 fd7a:115c:a1e0::99/48 scope global\n' >"$PFX/ip6.addr"
	pf_run; want WARN ipv6.state; assert_contains iface "global on: br-lan" "$PFOUT"
	case $PFOUT in *"global on: br-lan tailscale0"*) fail "ULA address of tailscale0 must not count as global IPv6" ;; esac
	pf_fixture; printf "dhcp.lan=dhcp\ndhcp.lan.ra='server'\n" >"$PFX/uci.dhcp"; pf_run; want WARN ipv6.state
	pf_fixture; echo 1 >"$RT/proc/sys/net/ipv6/conf/all/disable_ipv6"; pf_run; want PASS ipv6.state
}
test_flow_offloading_and_fastpath_warn() {
	pf_fixture; sed -i "s/flow_offloading='0'/flow_offloading='1'/" "$PFX/uci.firewall"; pf_run
	want WARN fw.offload; assert_contains gate "kill switch approval" "$PFOUT"; rcis 0
	pf_fixture; printf 'shortcut_fe 12345 0 - Live 0x0\n' >"$RT/proc/modules"; pf_run; want WARN fw.fastpath
}
test_firewall_user_and_foreign_includes_warn() {
	pf_fixture; printf 'iptables -A forward_rule -j DROP\n' >"$RT/etc/firewall.user"
	printf "firewall.@include[1]=include\nfirewall.@include[1].path='/etc/my-fw.sh'\n" >>"$PFX/uci.firewall"; pf_run
	want WARN fw.user; want WARN fw.includes; assert_contains inc "/etc/my-fw.sh" "$PFOUT"
}
test_boot_order_is_checked_against_firewall_and_network() {
	pf_fixture; mv "$RT/etc/rc.d/S19firewall" "$RT/etc/rc.d/S10firewall"; pf_run; want WARN boot.order
	pf_fixture; rm "$RT/etc/rc.d/S20network"; pf_run; want WARN boot.order
}
test_low_memory_and_disk_thresholds() {
	pf_fixture; echo "MemAvailable: 5000 kB" >"$RT/proc/meminfo"; pf_run; want FAIL res.mem
	pf_fixture; echo "MemAvailable: 20000 kB" >"$RT/proc/meminfo"; pf_run; want WARN res.mem
	pf_fixture; sed -i 's/ 80000 / 300 /' "$PFX/df.out"; pf_run; want FAIL res.disk
	pf_fixture; sed -i 's/ 80000 / 1500 /' "$PFX/df.out"; pf_run; want WARN res.disk
}
test_risks_that_need_hardware_are_skipped_not_passed() {
	pf_fixture; pf_run
	for _id in risk.boot risk.reload risk.failover risk.packet risk.masq; do want SKIP "$_id"; done
	assert_contains honest "full boot freedom is NOT claimed" "$PFOUT"
}

# ------------------------------------------------------------------ usage / streaming
test_unknown_options_are_refused() {
	pf_fixture
	for _o in --yes --enable --replace-gl-hook --force --apply; do
		_r=$(PF_ROOT=$RT PATH=$B "$SHP" "$ROOT/tools/tsem-preflight.sh" "$_o" 2>&1); _c=$?
		[ "$_c" -eq 64 ] || fail "$_o must be refused (rc $_c)"
		assert_contains msg "read-only" "$_r"
	done
	[ ! -e "$RT/etc/tsem" ] || fail "something was created"
}
test_streamed_through_sh_s_still_completes() {
	pf_fixture
	_o=$(PFX=$PFX PF_ROOT=$RT PATH=$B "$SHP" -s -- --repo "$ROOT" <"$ROOT/tools/tsem-preflight.sh" 2>&1)
	assert_contains tail "RESULT READY_FOR_PASSIVE_INSTALL" "$_o"
}

# ------------------------------------------------------------------ static guarantees
_pf_code() { grep -v '^[[:space:]]*#' "$1" | sed 's/have [A-Za-z0-9_-]*//g'; }
test_preflight_source_contains_no_mutating_action() {
	_c=$(_pf_code "$ROOT/tools/tsem-preflight.sh")
	for _pat in \
		'uci[[:space:]]+(-q[[:space:]]+)?(set|add|add_list|del_list|delete|rename|reorder|commit|revert|import)' \
		'iptables[^|;]*[[:space:]]-[AIDRFNXPZE][[:space:]]' 'iptables-restore|iptables-save|ip6tables-restore|nft[[:space:]]' \
		'ip[[:space:]]+(-6[[:space:]]+)?(rule|route|addr|address|link|neigh)[[:space:]]+(add|del|delete|replace|change|flush|set|append)' \
		'tailscale[[:space:]]+(up|down|set|login|logout|serve|funnel|cert|file|switch|lock|ssh|ping|netcheck|bugreport|configure|update)' \
		'/etc/init\.d/[^[:space:]]+[[:space:]]+(start|stop|restart|reload|enable|disable)' '(^|[;&|(]|\$\()[[:space:]]*fw3[[:space:]]+[a-z]' '(^|[;&|(]|\$\()[[:space:]]*(reboot|poweroff|halt)([[:space:]]|$)|sysctl[[:space:]]+-w' \
		'ubus[[:space:]]+call' '(^|[;&|(]|\$\()[[:space:]]*(service|rm|mv|cp|mkdir|rmdir|touch|chmod|chown|ln|mktemp|tee|dd|kill|killall|opkg|wget|curl|uclient-fetch|scp|rsync|ssh|nc|logger|crontab|eval)[[:space:]]' \
		'sed[[:space:]]+-i' '(^|[;&|[:space:]])(source|\.)[[:space:]]+["$/]' '--yes|--enable|--replace-gl-hook|--force|--rollback'; do
		printf '%s\n' "$_c" | grep -Eq -- "$_pat" && fail "forbidden pattern '$_pat': $(printf '%s\n' "$_c" | grep -E -- "$_pat" | head -n 2)"
	done
	# no redirect into a file (only /dev/null, stderr and fd duplication)
	_r=$(printf '%s\n' "$_c" | sed 's/2>&1//g; s/>\/dev\/null//g; s/<\/dev\/null//g; s/>&2//g' | grep '>')
	[ -z "$_r" ] || fail "file redirect in the script: $_r"
	# the only program run from the repository is the installer WITHOUT options
	assert_eq "installer invocations" 2 "$(printf '%s\n' "$_c" | grep -c 'sh "\$REPO/install.sh"')"
	printf '%s\n' "$_c" | grep 'sh "\$REPO/install.sh"' | grep -Ev 'install.sh" (--root "\$R" )?2>&1\)$|install.sh" 2>&1\)$' && fail "installer must be called without options"
	true
}
test_preflight_is_posix_sh() {
	_c=$(_pf_code "$ROOT/tools/tsem-preflight.sh")
	for _pat in '\[\[[[:space:]]' '(^|[;&|[:space:]])local[[:space:]]' 'echo[[:space:]]+-e' '\$\{[A-Za-z_0-9]+//' '<<<' "(^|[[:space:]=(])\\\$'" '^[[:space:]]*function[[:space:]]+[A-Za-z_]+[[:space:]]*(\(\))?[[:space:]]*\{?[[:space:]]*$' 'declare[[:space:]]' '=\(' '&>' '\|&' '(^|[[:space:]])let[[:space:]]' '\[ [^]]*==' 'pipefail' 'read[[:space:]]+-[a-qs-z]' '\$RANDOM'; do
		printf '%s\n' "$_c" | grep -Eq -- "$_pat" && fail "non-POSIX construct '$_pat': $(printf '%s\n' "$_c" | grep -E -- "$_pat" | head -n 2)"
	done
	true
}
test_scripts_parse_in_every_available_shell() {
	for _s in "$SH" dash bash ash; do
		command -v "$_s" >/dev/null 2>&1 || continue
		"$_s" -n "$ROOT/tools/tsem-preflight.sh" || fail "tsem-preflight.sh does not parse in $_s"
		"$_s" -n "$ROOT/tools/run-preflight-mac.sh" || fail "run-preflight-mac.sh does not parse in $_s"
	done
	if command -v busybox >/dev/null 2>&1 && busybox ash -c : >/dev/null 2>&1; then
		busybox ash -n "$ROOT/tools/tsem-preflight.sh" || fail "busybox ash cannot parse the preflight"
	fi
}

# ------------------------------------------------------------------ macOS wrapper
pf_wrapper_setup() {
	pf_fixture
	mkdir -p "$T/mbin" "$T/home"
	cat >"$T/mbin/ssh" <<'J'
#!/bin/sh
echo "$*" >>"$SSHLOG"
[ ! -e "$SSHFAIL" ] || { echo "ssh: Could not resolve hostname" >&2; exit 255; }
for a; do cmd=$a; done
exec sh -c "$cmd"
J
	chmod +x "$T/mbin/ssh"
	ln -s "$ROOT" "$T/repoln"
}
pf_wrapper() {
	WOUT=$(PATH=$T/mbin:$B HOME=$T/home PFX=$PFX PF_ROOT=$RT SSHLOG=$T/ssh.log SSHFAIL=$T/ssh.fail TMPDIR=$T/tmp \
		"$SHP" "$ROOT/tools/run-preflight-mac.sh" --repo "${WREPO:-$T/repoln}" "$@" 2>&1)
	WRC=$?
}
test_wrapper_runs_over_ssh_and_saves_the_report_locally() {
	pf_wrapper_setup; _s=$(pf_snap); pf_wrapper
	assert_eq "exit code is the preflight's" 0 "$WRC"
	_rep=$(ls "$T"/home/tsem-preflight/preflight-root-*.txt 2>/dev/null | head -n 1)
	[ -s "$_rep" ] || fail "no local report: $WOUT"
	assert_contains rec "RECOMMENDATION: READY_FOR_PASSIVE_INSTALL" "$(cat "$_rep")"
	assert_contains cmp "PASS  repo.compare" "$(cat "$_rep")"
	assert_contains shown "Report saved:" "$WOUT"
	assert_eq "one ssh call" 1 "$(grep -c . "$T/ssh.log")"
	assert_contains ssh "root sh -s -- --repo $T/repoln" "$(cat "$T/ssh.log")"
	assert_eq "router untouched" "$_s" "$(pf_snap)"
	assert_eq "only the report directory was created" "tsem-preflight" "$(ls -A "$T/home")"
}
test_wrapper_reports_hash_mismatch_with_the_local_checkout() {
	pf_wrapper_setup; pf_repo_copy; echo "# drift" >>"$PF_REPO/src/usr/lib/tsem/backend_ipt.sh"
	WREPO=$PF_REPO; pf_wrapper
	_rep=$(ls "$T"/home/tsem-preflight/*.txt | head -n 1)
	assert_contains warn "WARN  repo.compare" "$(cat "$_rep")"
	assert_contains file "src/usr/lib/tsem/backend_ipt.sh" "$(cat "$_rep")"
}
test_wrapper_passes_the_recommendation_exit_code_through() {
	pf_wrapper_setup; sed -i "s/masq='1'/masq='0'/" "$PFX/uci.firewall"; pf_wrapper
	assert_eq "NEEDS_FIX exit code" 1 "$WRC"
	assert_contains rec "RECOMMENDATION: NEEDS_FIX" "$WOUT"
}
test_wrapper_without_connection_fails_cleanly() {
	pf_wrapper_setup; : >"$T/ssh.fail"; pf_wrapper
	assert_eq "exit code" 69 "$WRC"
	assert_contains msg "no report received" "$WOUT"
}
test_wrapper_refuses_unsafe_values_and_has_no_other_effects() {
	pf_wrapper_setup
	WREPO='/tmp/x;reboot' pf_wrapper
	assert_eq "unsafe repo" 64 "$WRC"
	pf_wrapper --host 'a b'
	assert_eq "unsafe host" 64 "$WRC"
	[ ! -s "$T/ssh.log" ] || fail "ssh was called with unsafe input"
	_c=$(grep -v '^[[:space:]]*#' "$ROOT/tools/run-preflight-mac.sh")
	for _pat in 'scp|rsync|sftp|ssh-keygen|ssh-add|ssh-copy-id|curl|wget|tee|crontab|launchctl|sudo|ssh_config'; do
		printf '%s\n' "$_c" | grep -Eq "(^|[^A-Za-z_.-])($_pat)([^A-Za-z_-]|\$)" && fail "wrapper contains '$_pat'"
	done
	assert_eq "single ssh invocation" 1 "$(printf '%s\n' "$_c" | grep -c '^ssh ')"
}

# ------------------------------------------------------------------ native GL.iNet GUI architecture (section 12)
test_native_architecture_is_reported_and_the_static_prerequisites_are_pass() {
	pf_fixture; pf_run
	for _id in ui.dir ui.menu.tailscale ui.menu.order ui.bundle.Admin_Token ui.bundle._rpc ui.bundle.glinet ui.rpc.shape ui.rpc.cjson web.luci native.verdict; do want PASS "$_id"; done
	assert_contains order "entries under parent 'applications' (index:view): 31:tailscale 32:zerotier" "$PFOUT"
	assert_contains reference "reference entry /usr/share/oui/menu.d/tailscale.json" "$PFOUT"
	# what cannot be proven read-only is reported as such, never as PASS
	want SKIP ui.lua
}

test_native_prerequisites_missing_is_only_a_warning_and_never_blocks_the_passive_install() {
	pf_fixture; rm -rf "$RT/usr/lib/oui-httpd"; rm -f "$RT/usr/share/oui/menu.d/tailscale.json"; pf_run
	want WARN ui.dir; want WARN ui.menu.tailscale; want WARN native.verdict
	assert_contains refused "would be refused by the installer" "$PFOUT"
	rcis 0; rec READY_FOR_PASSIVE_INSTALL
}

test_stock_bundle_without_the_assumed_session_mechanism_is_flagged() {
	pf_fixture; printf 'nothing relevant\n' | gzip -9nc >"$RT/www/views/gl-sdk4-ui-tailscale.common.js.gz"; pf_run
	want WARN ui.bundle.Admin_Token; want WARN ui.bundle.glinet
	assert_contains unconfirmed "NOT confirmed" "$PFOUT"
}

test_web_ports_on_all_addresses_are_flagged_for_wan_review() {
	pf_fixture; mkdir -p "$RT/proc/net"
	printf '  sl  local_address rem_address   st\n   0: 00000000:0050 00000000:0000 0A 00000000:00000000\n   1: 0100000A:0016 00000000:0000 0A 00000000:00000000\n' >"$RT/proc/net/tcp"
	pf_run
	want WARN web.wan_exposure
	assert_contains lst "0.0.0.0:80" "$PFOUT"
	assert_contains lan "10.0.0.1:22" "$PFOUT"
}

test_native_section_is_read_only() {
	pf_fixture; _s=$(pf_snap); pf_run
	assert_eq "fake router unchanged" "$_s" "$(pf_snap)"
	assert_eq "no temp files" "" "$(ls -A "$T/tmp")"
}

test_menu_files_are_listed_and_a_title_match_finds_the_tailscale_entry() {
	pf_fixture
	printf '{\n\t"index": 31,\n\t"view": "gl-sdk4-ui-tailscale",\n\t"title": "Tailscale",\n\t"parent": "applications"\n}\n' >"$RT/usr/share/oui/menu.d/tailscale.json"
	pf_run
	want PASS ui.menu.files; want PASS ui.menu.tailscale
	assert_contains structure "parent=applications index=31" "$PFOUT"
}

test_without_a_tailscale_entry_the_applications_sibling_fallback_is_a_warning_not_a_refusal() {
	pf_fixture; rm -f "$RT/usr/share/oui/menu.d/tailscale.json"; pf_run
	want WARN ui.menu.tailscale
	assert_contains fallback "END of that group" "$PFOUT"
	want PASS native.verdict
}

test_wrapper_stage_is_a_labelled_write_in_a_unique_dir_and_is_removed_again() {
	pf_wrapper_setup
	WOUT=$(PATH=$T/mbin:$B HOME=$T/home PFX=$PFX PF_ROOT=$RT SSHLOG=$T/ssh.log SSHFAIL=$T/ssh.fail TMPDIR=$T/tmp \
		"$SHP" "$ROOT/tools/run-preflight-mac.sh" --stage "$ROOT" 2>&1); WRC=$?
	assert_contains label "WRITE on the router: staging" "$WOUT"
	assert_eq "three ssh calls: stage, run, cleanup" 3 "$(grep -c . "$T/ssh.log")"
	_sd=$(sed -n 's/.*mkdir \(\/tmp\/tsem-pf\.[0-9.]*\) .*/\1/p' "$T/ssh.log" | head -n 1)
	[ -n "$_sd" ] || fail "no staging dir named in the ssh log"
	[ ! -e "$_sd" ] || fail "staging dir $_sd was left behind"
	_rep=$(ls "$T"/home/tsem-preflight/preflight-root-*.txt 2>/dev/null | head -n 1)
	[ -s "$_rep" ] || fail "no local report: $WOUT"
	assert_contains present "PASS  repo.present" "$(cat "$_rep")"
	assert_contains cmp "PASS  repo.compare" "$(cat "$_rep")"
	assert_contains marker ".tsem-pf-stage" "$(cat "$T/ssh.log")"
}

test_wrapper_stage_is_removed_again_even_when_the_preflight_run_itself_fails() {
	pf_wrapper_setup
	cat >"$T/mbin/ssh" <<'J'
#!/bin/sh
echo "$*" >>"$SSHLOG"
for a; do cmd=$a; done
case $cmd in "sh -s -- "*) echo "ssh: connection lost" >&2; exit 255 ;; esac
exec sh -c "$cmd"
J
	WOUT=$(PATH=$T/mbin:$B HOME=$T/home PFX=$PFX PF_ROOT=$RT SSHLOG=$T/ssh.log SSHFAIL=$T/ssh.fail TMPDIR=$T/tmp \
		"$SHP" "$ROOT/tools/run-preflight-mac.sh" --stage "$ROOT" 2>&1); WRC=$?
	assert_eq "no report is an error" 69 "$WRC"
	_sd=$(sed -n 's/.*mkdir \(\/tmp\/tsem-pf\.[0-9.]*\) .*/\1/p' "$T/ssh.log" | head -n 1)
	[ -n "$_sd" ] || fail "staging did not happen: $WOUT"
	[ ! -e "$_sd" ] || fail "staging dir $_sd was left behind after a failed run"
}

test_wrapper_stage_cleanup_never_removes_a_foreign_directory() {
	pf_wrapper_setup
	_foreign=$T/foreign; mkdir -p "$_foreign"; : >"$_foreign/keep"
	WOUT=$(PATH=$T/mbin:$B HOME=$T/home PFX=$PFX PF_ROOT=$RT SSHLOG=$T/ssh.log SSHFAIL=$T/ssh.fail TMPDIR=$T/tmp \
		"$SHP" "$ROOT/tools/run-preflight-mac.sh" --stage "$ROOT" 2>&1)
	[ -f "$_foreign/keep" ] || fail "an unrelated directory was touched"
	assert_contains guarded "[ -f \$d/.tsem-pf-stage ]" "$(cat "$T/ssh.log")"
	assert_contains pattern "/tmp/tsem-pf.[0-9]*.[0-9]*" "$(cat "$T/ssh.log")"
}

test_fake_router_path_never_receives_a_guard_wrapper_as_a_tool() {
	pf_fixture
	_g=$T/rm-guard/x/refuse; mkdir -p "$_g"; printf '#!/bin/sh\nexit 1\n' >"$_g/rm"; chmod +x "$_g/rm"
	_r=$(PATH=$_g:$PATH pf_realcmd rm)
	case $_r in */rm-guard/*) fail "guard wrapper selected: $_r" ;; esac
	[ -x "$_r" ] || fail "no real rm found: '$_r'"
	[ "$(readlink "$B/rm")" = "$(pf_realcmd rm)" ] || [ -x "$B/rm" ] || fail "fake PATH has no usable rm"
}

test_wrapper_stage_and_repo_cannot_be_combined_and_nothing_is_written() {
	pf_wrapper_setup
	WOUT=$(PATH=$T/mbin:$B HOME=$T/home SSHLOG=$T/ssh.log SSHFAIL=$T/ssh.fail "$SHP" "$ROOT/tools/run-preflight-mac.sh" --stage "$ROOT" --repo /tmp/x 2>&1); WRC=$?
	assert_eq rc 64 "$WRC"
	[ ! -s "$T/ssh.log" ] || fail "ssh was called"
}
