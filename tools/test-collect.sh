#!/bin/sh
# Tests for tools/collect.sh (v4) and tools/run-collector.sh. No router contact.
# Usage: sh tools/test-collect.sh   (optional: ASH=/path/to/busybox-ash)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
C="$HERE/collect.sh"
R="$HERE/run-collector.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
t() { # t DESC cmd...
	_d=$1
	shift
	if "$@" >/dev/null 2>&1; then ok; else bad "$_d"; fi
}
tn() { # must fail
	_d=$1
	shift
	if "$@" >/dev/null 2>&1; then bad "$_d"; else ok; fi
}
has() { grep -qF -- "$2" "$1"; }          # has FILE TEXT
hasnt() { ! grep -qF -- "$2" "$1"; }

# ---- static: read-only and privacy guarantees -----------------------------------
t "shebang line 1" sh -c "head -n 1 '$C' | grep -qx '#!/bin/sh'"
t "umask 077 line 2" sh -c "sed -n 2p '$C' | grep -qx 'umask 077'"
tn "no eval" sh -c "grep -nE '(^|[^a-z_])eval[[:space:]]' '$C'"
t "only exec is stdin redirect" sh -c "[ \"\$(grep -cE '^[[:space:]]*exec[[:space:]]' '$C')\" = 1 ] && grep -qE '^[[:space:]]*exec </dev/null' '$C'"
MUT='(^|[;&|(`]|then|do|else)[[:space:]]*(iptables|ip6tables|iptables-restore|ip6tables-restore|nft|ipset|ebtables)[[:space:]]+(-[ADIRFXZNPEC]|add|delete|flush|insert|replace|-I|-A|-D|-F|-X|-P)|(^|[;&|(`])[[:space:]]*(reboot|poweroff|halt|opkg[[:space:]]+(install|remove|update|upgrade)|uci[[:space:]]+(set|add|delete|commit|revert|del_list|add_list)|ip[[:space:]]+(-[46][[:space:]]+)?(route|rule|link|addr|address)[[:space:]]+(add|del|delete|flush|replace|set|change)|tailscale[[:space:]]+(up|down|set|login|logout|serve|funnel|file|ssh|cert|lock)|ifup|ifdown|wifi|killall|kill|mv|cp|chmod[[:space:]]+[0-7]|chown|sysctl[[:space:]]+-w|modprobe|insmod|rmmod|curl|wget|uclient-fetch|ping|nc|ssh|scp|mosquitto_pub|logger)[[:space:]]'
tn "no mutating/network commands" sh -c "grep -vE '^[[:space:]]*(#|echo )|; do$' '$C' | grep -E '$MUT'"
t "init.d scripts only read" sh -c "! grep -vE '^[[:space:]]*#' '$C' | grep -E '/etc/init.d/[a-z]+[[:space:]]+(start|stop|restart|reload|enable|disable)'"
tn "no write redirection except \$OUT/\$CAP" sh -c "grep -vE '^[[:space:]]*#' '$C' | grep -E '[[:space:]]>>?[[:space:]]*[\"/]' | grep -vE '>>?[[:space:]]*\"\\\$(OUT|CAP)\"|/dev/null|>&2'"
tn "no tailscale state file reads" sh -c "grep -vE '^[[:space:]]*#' '$C' | grep -E 'tailscaled\\.state|/var/lib/tailscale/[a-z]|cat[[:space:]]+/var/lib/tailscale'"
tn "no netmap/capture/bugreport/auth-key use" sh -c "grep -E 'debug (netmap|watch-ipn|capture)|tailscale bugreport|--auth-key' '$C' | grep -v '^#'"
tn "no opkg update" sh -c "grep -vE '^[[:space:]]*(#|echo )' '$C' | grep -E 'opkg[[:space:]]+update'"
t "exactly three rm -f" sh -c "[ \"\$(grep -c 'rm -f' '$C')\" = 3 ]"
t "all rm -f target \$OUT/\$CAP" sh -c "! grep 'rm -f' '$C' | grep -vE '\"\\\$(OUT|CAP)\"'"
tn "no ps command (arguments leak)" sh -c "grep -vE '^[[:space:]]*(#|echo )' '$C' | grep -E '(^|[;&|(\`]|\\\$\\()[[:space:]]*ps([[:space:]]|\$)'"
tn "no recursive grep" sh -c "grep -vE '^[[:space:]]*#' '$C' | grep -E 'grep -[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]|--recursive'"
tn "grep -I only as probe (BusyBox lacks it)" sh -c "grep -E 'grep -[a-zA-Z]*I' '$C' | grep -v 'not used by collector'"
tn "uci never dumped raw (only tcap/allowlist/firewall)" sh -c "grep -E 'uci (show|export)' '$C' | grep -vE '^[[:space:]]*#|tcap uci show|uci export firewall|echo |section '"
tn "logread only via tcap" sh -c "grep -n 'logread' '$C' | grep -vE 'tcap logread|^[0-9]+:[[:space:]]*#'"
tn "cmdline only kernel cmdline or tailscaled allowlist" sh -c "grep -n 'cmdline' '$C' | grep -vE 'cat_file /proc/cmdline|kernel cmdline|_ta_d/cmdline|^[0-9]+:[[:space:]]*#'"
tn "no find without bounds (maxdepth/size/dirs)" sh -c "grep -nE '(^|[^a-z_])find (/ |/ -|\\\$\\(|\\.)' '$C'"
t "list_small is size and count bounded" sh -c "grep -E '^list_small' '$C' | grep -q 'size -128' && grep -E '^list_small' '$C' | grep -q 'head -n 500'"
tn "no bashisms ([[ ]], local, \${x//}, <<<, function kw)" sh -c "grep -nE '\\[\\[ |^[[:space:]]*local |\\\$\\{[a-z_]+//|<<<|^function ' '$C'"
t "main guarded by NOEXEC hook and called last" sh -c "tail -n 4 '$C' | grep -q 'main \"\$@\"'"
t "run-collector: umask, no eval" sh -c "sed -n 2p '$R' | grep -qx 'umask 077' && ! grep -q eval '$R'"
tn "run-collector: no scp/sftp" sh -c "grep -E '^[^#]*(scp|sftp)' '$R'"

# ---- syntax -----------------------------------------------------------------------
for s in dash bash "bash --posix"; do
	command -v "${s%% *}" >/dev/null 2>&1 || continue
	t "syntax collect ($s)" $s -n "$C"
	t "syntax run-collector ($s)" $s -n "$R"
	t "syntax tests ($s)" $s -n "$0"
done
ASH=${ASH:-$(ls /nix/store/*busybox*/bin/ash 2>/dev/null | head -n 1)}
if [ -n "$ASH" ] && [ -x "$ASH" ]; then
	t "syntax collect (busybox ash)" "$ASH" -n "$C"
	t "syntax run-collector (busybox ash)" "$ASH" -n "$R"
	ASH_USED=1
else
	ASH_USED=0
	echo "NOTE: no busybox ash found; ash checks are OPEN"
fi
SHELLS="dash bash"
[ "$ASH_USED" = 1 ] && SHELLS="dash bash $ASH"

# ---- setup ------------------------------------------------------------------------
TD=$(mktemp -d /tmp/tsem-tc.XXXXXX) || exit 1
trap 'rm -rf "$TD"' EXIT
rm -f /tmp/tsem-collect-*
fn() { # fn SHELL CODE: source helpers, run code
	_sh=$1
	shift
	TSEM_COLLECT_NOEXEC=1 $_sh -c ". '$C'; $*" 2>&1
}
leftover() { ls /tmp/tsem-collect-* >/dev/null 2>&1; }

# ---- redaction --------------------------------------------------------------------
fx="$TD/fx.txt"
cat >"$fx" <<'EOF'
option key 'abcSECRETkey123'
option password hunter2
option psk 'wifipass123'
option ssid 'MyHomeWifi'
	option ssid MyOtherWifi
wireless.default_radio0.ssid='NeighbourNet'
wireless.default_radio0.key='supersecretwifi'
tskey-auth-kABCDEF123456-xyz789
tailscale up --auth-key tskey-auth-kAAAAAAAA-bbbbbbbb
Authorization: Bearer abc.def.ghi
https://user:pw@host.example/path
"PrivateKey": "privkey:0123456789abcdef0123"
nodekey:00112233445566778899aabbccddeeff
mkey:aabbccddeeff00112233
user@example.com
aa:bb:cc:dd:ee:ff
mynode.tail1234.ts.net
home123.glddns.com
aGVsbG8gd29ybGQgdGhpcyBpcyBhIDMyYnl0ZSBrZXkhIQ0=
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
-----END PRIVATE KEY-----
https://login.tailscale.com/a/abcdef123456
token=abc123
EOF
for s in $SHELLS; do
	red=$(TSEM_COLLECT_NOEXEC=1 $s -c ". '$C'; redact" <"$fx")
	for leak in SECRETkey123 hunter2 wifipass123 MyHomeWifi MyOtherWifi NeighbourNet supersecretwifi kAAAAAAAA kABCDEF123456 'abc.def.ghi' 'pw@' 0123456789abcdef0123 00112233445566778899 'aabbccddeeff00112233' 'user@example' 'aa:bb:cc' 'mynode.tail' 'home123' 'aGVsbG8' MIIEvQIB abcdef123456 'abc123'; do
		if printf '%s' "$red" | grep -qF -- "$leak"; then bad "redact[$s] leaked: $leak"; else ok; fi
	done
	printf '%s' "$red" | grep -q 'ts.net' && ok || bad "redact[$s] keeps .ts.net marker"
done

d=$(printf 'a=1\nprivate_key=x\nwg_psk=y\nname=z\nauth_key=q\n' | fn dash drop_secret_lines)
printf '%s' "$d" | grep -q 'a=1' && printf '%s' "$d" | grep -q 'name=z' && ok || bad "drop keeps normal lines"
printf '%s' "$d" | grep -qE 'private_key|wg_psk|auth_key=q' && bad "drop removes secret lines" || ok
printf '%s' "$d" | grep -q '3 secret-bearing' && ok || bad "drop counts"

# ---- emit: status line, markers, truncation -----------------------------------------
fn dash "OUT='$TD/e1'; SEC=t1; : >\"\$OUT\"; seq 1 50 | emit 10" >/dev/null
[ "$(grep -c '' "$TD/e1")" = 12 ] && ok || bad "emit truncation lines (got $(grep -c '' "$TD/e1"))"
grep -q '^# \[t1\] status=partial issues=0 na=0 lines=50 truncated=1' "$TD/e1" && ok || bad "emit truncated status"
fn dash "OUT='$TD/e2'; SEC=t2; : >\"\$OUT\"; printf 'a\n!! failed rc=1: x\n!! n/a: y\n' | emit 100" >/dev/null
grep -q '^# \[t2\] status=partial issues=1 na=1 lines=3 truncated=0' "$TD/e2" && ok || bad "emit failure markers counted"
fn dash "OUT='$TD/e3'; SEC=t3; : >\"\$OUT\"; printf 'a\nb\n' | emit 100" >/dev/null
grep -q '^# \[t3\] status=ok issues=0 na=0 lines=2 truncated=0' "$TD/e3" && ok || bad "emit ok status"
fn dash "OUT='$TD/e4'; SEC=t4; : >\"\$OUT\"; { for i in 1 2 3 4 5 6; do echo line\$i; done; echo '!! failed rc=2: z'; } | emit 3" >/dev/null
grep -q 'issues=1' "$TD/e4" && ok || bad "emit counts markers beyond the line limit"

# ---- leak_check ---------------------------------------------------------------------
printf 'ok line\noption enabled 1\nencryption=psk2\npassword=<redacted>\n# 3 secret-bearing line(s) omitted\n' >"$TD/clean"
printf 'x tskey-auth-kABCDEFG\n' >"$TD/dirty1"
printf 'wifi_password=hunter22\n' >"$TD/dirty2"
printf 'api_key: "abcd1234"\n' >"$TD/dirty3"
fn dash "leak_check '$TD/clean'" >/dev/null && ok || bad "leak_check clean"
for n in 1 2 3; do
	fn dash "leak_check '$TD/dirty$n'" >/dev/null && bad "leak_check dirty$n" || ok
done
fn dash "leak_check '$TD/dirty2'" | grep -q 'hunter22' && bad "leak_check prints no content" || ok

# ---- chain_summary / base_jumps ----------------------------------------------------------
cat >"$TD/ipt" <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:ts-input - [0:0]
-A INPUT -j ts-input
-A FORWARD -j ACCEPT
-A ts-input -i lo -j ACCEPT
COMMIT
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o wan -j MASQUERADE
COMMIT
EOF
cs=$(fn dash "chain_summary ip4 <'$TD/ipt'")
printf '%s' "$cs" | grep -q 'ip4 filter FORWARD policy=DROP rules=1' && ok || bad "chain_summary forward ($cs)"
printf '%s' "$cs" | grep -q 'ip4 filter ts-input policy=- rules=1' && ok || bad "chain_summary ts-input"
bj=$(fn dash "base_jumps ip4 <'$TD/ipt'")
printf '%s' "$bj" | grep -q 'ip4 nat -A POSTROUTING' && ok || bad "base_jumps"

# ---- script_view / sv_auto -------------------------------------------------------------------
cat >"$TD/sw.sh" <<'EOF'
#!/bin/sh
iptables -A INPUT -j DROP
tailscale set --exit-node=100.1.1.1
TOKEN=abcdef123456
tailscale up --auth-key tskey-auth-kSECRET
echo hello-unrelated
EOF
for s in $SHELLS; do
	v0=$(TSEM_COLLECT_NOEXEC=1 $s -c ". '$C'; script_view '$TD/sw.sh' 0" 2>&1)
	printf '%s' "$v0" | grep -q 'iptables -A INPUT' && ok || bad "script_view[$s] shows command lines"
	printf '%s' "$v0" | grep -q 'exit-node=100.1.1.1' && ok || bad "script_view[$s] shows tailscale set"
	printf '%s' "$v0" | grep -qE 'abcdef123456|kSECRET|auth-key' && bad "script_view[$s] suppresses secret lines" || ok
	printf '%s' "$v0" | grep -q 'hello-unrelated' && bad "script_view[$s] hides unrelated lines" || ok
	printf '%s' "$v0" | grep -q 'suppressed (secret-like words)' && ok || bad "script_view[$s] reports suppression"
	printf '%s' "$v0" | grep -q 'sha256=' && ok || bad "script_view[$s] metadata"
done
v1=$(TSEM_COLLECT_NOEXEC=1 dash -c ". '$C'; script_view '$TD/sw.sh' 1; " 2>&1 | TSEM_COLLECT_NOEXEC=1 dash -c ". '$C'; redact")
printf '%s' "$v1" | grep -q 'hello-unrelated' && ok || bad "script_view full shows everything"
printf '%s' "$v1" | grep -qE 'abcdef123456|kSECRET' && bad "script_view full is still redacted" || ok
sa=$(TSEM_COLLECT_NOEXEC=1 dash -c ". '$C'; script_view() { echo \"\$1 full=\$2\"; }; FULL=1; sv_auto /etc/gl-switch.d/x; sv_auto /etc/hotplug.d/button/y; sv_auto /etc/init.d/tailscale; sv_auto /etc/firewall.user; FULL=0; sv_auto /etc/gl-switch.d/x" 2>&1)
printf '%s' "$sa" | grep -q '/etc/gl-switch.d/x full=1' && ok || bad "sv_auto full for gl-switch.d"
printf '%s' "$sa" | grep -q '/etc/hotplug.d/button/y full=1' && ok || bad "sv_auto full for button hotplug"
printf '%s' "$sa" | grep -q '/etc/init.d/tailscale full=0' && ok || bad "sv_auto allowlist for init.d even with --full-scripts"
printf '%s' "$sa" | grep -q '/etc/firewall.user full=0' && ok || bad "sv_auto allowlist for firewall.user"
[ "$(printf '%s\n' "$sa" | tail -n 1)" = "/etc/gl-switch.d/x full=0" ] && ok || bad "sv_auto default is allowlist"

# ---- process helpers (fixture /proc) ----------------------------------------------------------
mkdir -p "$TD/proc/100" "$TD/proc/200"
echo tailscaled >"$TD/proc/100/comm"
printf '/usr/sbin/tailscaled\0--state=/etc/tailscale/x.state\0--auth-key=tskey-auth-kSECRETPROC\0--port=41641\0' >"$TD/proc/100/cmdline"
echo sh >"$TD/proc/200/comm"
printf 'sh\0-c\0password=hunter2procarg\0' >"$TD/proc/200/cmdline"
for s in $SHELLS; do
	pn=$(TSEM_PROC="$TD/proc" TSEM_COLLECT_NOEXEC=1 $s -c ". '$C'; proc_names" 2>&1)
	printf '%s' "$pn" | grep -q 'tailscaled' && ok || bad "proc_names[$s] lists names"
	printf '%s' "$pn" | grep -q 'hunter2procarg' && bad "proc_names[$s] no arguments" || ok
	ta=$(TSEM_PROC="$TD/proc" TSEM_COLLECT_NOEXEC=1 $s -c ". '$C'; tailscaled_args" 2>&1)
	printf '%s' "$ta" | grep -q -- '--state=' && printf '%s' "$ta" | grep -q -- '--port=41641' && ok || bad "tailscaled_args[$s] allowlisted flags ($ta)"
	printf '%s' "$ta" | grep -qE 'SECRETPROC|auth-key|hunter2procarg' && bad "tailscaled_args[$s] drops auth key" || ok
done

# ---- end-to-end with stubs --------------------------------------------------------------------
SB="$TD/bin"
mkdir -p "$SB"
export STDIN_SEEN="$TD/stdin-seen"
cat >"$SB/tailscale" <<'EOF'
#!/bin/sh
case "$*" in
"debug prefs") cat <<'J'
{
  "PrivateNodeKey": "privkey:aaaaaaaaaaaaaaaaaaaaaaaa",
  "ExitNodeID": "nodeABC",
  "ExitNodeIP": "100.64.0.30",
  "CorpDNS": false,
  "AdvertiseRoutes": [
    "10.0.0.0/24"
  ],
  "NetfilterMode": 2
}
J
;;
"status --json") cat <<'J'
{
  "BackendState": "Running",
  "AuthURL": "https://login.tailscale.com/a/SECRETURLTOKEN",
  "Self": { "PublicKey": "nodekey:bbbbbbbbbbbbbbbbbbbbbbbb", "HostName": "root", "Online": true },
  "ExitNodeStatus": {
    "ID": "nodeABC",
    "Online": true,
    "TailscaleIPs": [
      "100.64.0.30/32"
    ]
  }
}
J
;;
status) echo "100.64.0.1 root tagged-devices linux -" ;;
*) echo "tailscale stub: $*" ;;
esac
EOF
cat >"$SB/uci" <<'EOF'
#!/bin/sh
case "$*" in
"export firewall") printf "config forwarding\n\toption src 'lan'\n\toption dest 'wan'\n" ;;
"show wireless") printf "wireless.radio0=wifi-device\nwireless.radio0.band='5g'\nwireless.default_radio0=wifi-iface\nwireless.default_radio0.ssid='HomeNet'\nwireless.default_radio0.key='wifikey1'\nwireless.default_radio0.mode='ap'\nwireless.default_radio0.encryption='psk2'\n" ;;
"show dhcp") printf "dhcp.@host[0]=host\ndhcp.@host[0].mac='aa:bb:cc:dd:ee:ff'\ndhcp.@host[0].name='secretphone'\ndhcp.lan=dhcp\ndhcp.lan.start='100'\n" ;;
"show network") printf "network.lan=interface\nnetwork.lan.proto='static'\nnetwork.lan.ipaddr='10.20.0.1'\nnetwork.wg0=interface\nnetwork.wg0.private_key='wgpriv123'\nnetwork.wg0.proto='wireguard'\n" ;;
"show glconfig") printf "glconfig.general=general\nglconfig.general.mode='router'\nglconfig.general.cloud_token='gltok12345'\nglconfig.blk=macblock\nglconfig.blk.mac='aa:bb:cc:dd:ee:01'\nglconfig.blk.enable='1'\n" ;;
"show tailscale") printf "tailscale.settings=tailscale\ntailscale.settings.enabled='1'\ntailscale.settings.auth_key='tskey-auth-kUCI12345'\n" ;;
"show system") printf "system.@system[0]=system\nsystem.@system[0].hostname='myhostname'\nsystem.@system[0].timezone='CET-1CEST'\n" ;;
*) echo "uci.stub=1" ;;
esac
EOF
cat >"$SB/iptables-save" <<'EOF'
#!/bin/sh
if [ "${TSEM_STUB_FAIL:-0}" = 1 ]; then echo "iptables-save: Permission denied" >&2; exit 1; fi
printf '*filter\n:INPUT ACCEPT [0:0]\n:ts-input - [0:0]\n-A INPUT -j ts-input\nCOMMIT\n'
EOF
cat >"$SB/ip6tables-save" <<'EOF'
#!/bin/sh
# reads stdin on purpose: must see EOF (collector runs with stdin=/dev/null)
cat >"$STDIN_SEEN"
printf '*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n'
EOF
cat >"$SB/logread" <<'EOF'
#!/bin/sh
cat <<'L'
Sat Nov 14 06:00:00 2026 daemon.notice netifd: Interface 'wan' is now up
Sat Nov 14 06:00:01 2026 daemon.err myapp[123]: login password=logsecret99 for user bobuser
Sat Nov 14 06:00:02 2026 daemon.info tailscaled[5]: authkey tskey-auth-kLOGKEY1 used by pubkey logpeer77
L
EOF
cat >"$SB/ubus" <<'EOF'
#!/bin/sh
case "$*" in
"call service list") printf '{\n\t"tailscale": {\n\t\t"instances": {\n\t\t\t"instance1": {\n\t\t\t\t"running": true,\n\t\t\t\t"command": [ "/usr/sbin/tailscaled", "--auth-key=tskey-auth-kSVC123" ],\n\t\t\t\t"env": { "TOKEN": "svcsecret88" }\n\t\t\t}\n\t\t}\n\t},\n\t"dnsmasq": {\n\t\t"instances": {\n\t\t\t"instance1": {\n\t\t\t\t"running": false\n\t\t\t}\n\t\t}\n\t}\n}\n' ;;
list) printf 'network\ngl-tailscale\nsystem\n' ;;
*) echo '{}' ;;
esac
EOF
chmod +x "$SB"/*

for s in $SHELLS; do
	n=$(basename "$s")
	rep="$TD/rep-$n.txt"
	PATH="$SB:$PATH" $s "$C" >"$rep" 2>"$TD/err-$n.txt"
	rc=$?
	[ $rc -eq 0 ] && ok || bad "e2e[$n] exit $rc"
	[ "$(grep -c '^## \[' "$rep")" -ge 100 ] && ok || bad "e2e[$n] headers + index"
	for id in 00 01a 01b 01c 01e 01f 01g 02c 02d 02g 03a 03c 04a 04c 05a 05f 05g 06c 06e 06f 06i 07a 07c 08c 09c 09d 10; do
		grep -q "^## \[$id\]" "$rep" && grep -q "^# \[$id\] status=" "$rep" && ok || bad "e2e[$n] section+status $id"
	done
	grep -q '^completeness=' "$rep" && ok || bad "e2e[$n] SUMMARY completeness"
	[ "$(grep -c '^## \[' "$rep")" -eq $((2 * $(sed -n 's/^sections=\([0-9]*\) .*/\1/p' "$rep"))) ] && ok || bad "e2e[$n] headers = 2 x sections"
	# privacy
	grep -q 'ExitNodeIP' "$rep" && ok || bad "e2e[$n] prefs allowlist keeps ExitNodeIP"
	for leak in PrivateNodeKey SECRETURLTOKEN bbbbbbbbbbbb aaaaaaaaaaaa HomeNet wifikey1 secretphone wgpriv123 gltok12345 kUCI12345 logsecret99 bobuser LOGKEY1 logpeer77 SVC123 svcsecret88 myhostname; do
		hasnt "$rep" "$leak" && ok || bad "e2e[$n] leaked: $leak"
	done
	grep -q "Interface 'wan' is now up" "$rep" && ok || bad "e2e[$n] allowlisted log event kept"
	grep -q '^tailscale running 1' "$rep" && grep -q '^dnsmasq stopped 1' "$rep" && ok || bad "e2e[$n] procd service summary"
	grep -q "wireless.default_radio0.mode='ap'" "$rep" && grep -q "wireless.radio0.band='5g'" "$rep" && ok || bad "e2e[$n] wireless allowlist keeps mode/band"
	grep -q "dhcp.lan.start='100'" "$rep" && ok || bad "e2e[$n] dhcp allowlist keeps settings"
	grep -q "network.lan.ipaddr='10.20.0.1'" "$rep" && ok || bad "e2e[$n] network allowlist keeps ipaddr"
	grep -q "glconfig.blk.enable='1'" "$rep" && grep -q 'glconfig.general.cloud_token$' "$rep" && ok || bad "e2e[$n] glconfig keys listed, allowlisted values only"
	grep -q 'timezone' "$rep" && ok || bad "e2e[$n] system allowlist keeps timezone"
	grep -q 'forwarding lan -> wan' "$rep" && ok || bad "e2e[$n] fw3 forwarding derived"
	grep -q 'ip4 filter ts-input' "$rep" && ok || bad "e2e[$n] chain summary"
	# integrity line
	last=$(tail -n 1 "$rep")
	nn=${last#*lines=}
	nn=${nn%% *}
	hh=${last#*sha256=}
	[ "$(wc -l <"$rep" | tr -d ' ')" -eq $((nn + 1)) ] && ok || bad "e2e[$n] END lines matches file"
	[ "$(head -n "$nn" "$rep" | sha256sum | cut -d' ' -f1)" = "$hh" ] && ok || bad "e2e[$n] END sha256 matches"
	[ -f "$STDIN_SEEN" ] && [ ! -s "$STDIN_SEEN" ] && ok || bad "e2e[$n] tools see empty stdin"
	rm -f "$STDIN_SEEN"
	leftover && bad "e2e[$n] temp files removed" || ok
done

# ---- failure detection ---------------------------------------------------------------------------
frep="$TD/fail.txt"
PATH="$SB:$PATH" TSEM_STUB_FAIL=1 dash "$C" >"$frep" 2>/dev/null
has "$frep" '!! failed rc=1: iptables-save -c' && ok || bad "failing command is marked in the report"
has "$frep" 'iptables-save: Permission denied' && ok || bad "error text of failing command is kept"
grep -q '^# \[01b\] status=partial issues=1' "$frep" && ok || bad "failing section is partial"
grep -q '^completeness=partial' "$frep" && ok || bad "SUMMARY completeness=partial"
grep -q '^# \[01b\] status=partial' "$frep" && ok || bad "SUMMARY lists the partial section"
fn dash "OUT='$TD/na1'; CAP='$TD/na1.cap'; SEC=na; : >\"\$OUT\"; { try no-such-tool-xyz; } | emit 50" >/dev/null
has "$TD/na1" '!! n/a: no-such-tool-xyz' && ok || bad "missing tool marked n/a"
grep -q '^# \[na\] status=ok issues=0 na=1' "$TD/na1" && ok || bad "n/a is counted, not an issue"
trep="$TD/trunc.txt"
PATH="$SB:$PATH" TSEM_LIMIT=3 TSEM_BIGLIMIT=3 dash "$C" >"$trep" 2>/dev/null
grep -q 'truncated=1' "$trep" && grep -q '^\[\.\.\. truncated at 3 of' "$trep" && ok || bad "truncation is reported"
grep -q '^completeness=partial' "$trep" && ok || bad "truncation makes the report partial"
# a section without status => incomplete
cat >"$TD/nostatus.sh" <<EOF
TSEM_COLLECT_NOEXEC=1
. '$C'
s09() { section 09x "crashed section"; echo 'half'; }
main "\$@"
EOF
PATH="$SB:$PATH" dash "$TD/nostatus.sh" >"$TD/ns.txt" 2>/dev/null
grep -q '^completeness=incomplete' "$TD/ns.txt" && grep -q '^no-status: 09x' "$TD/ns.txt" && ok || bad "section without status => incomplete"
leftover && bad "failure runs leave no temp files" || ok

# ---- --keep, options --------------------------------------------------------------------------------
PATH="$SB:$PATH" dash "$C" --keep >"$TD/keep.out" 2>"$TD/keep.err"
[ ! -s "$TD/keep.out" ] && ok || bad "--keep stdout empty"
kf=$(sed -n 's/^report kept: \(.*\) (mode 600)$/\1/p' "$TD/keep.err")
if [ -n "$kf" ] && [ -f "$kf" ]; then
	[ "$(stat -c %a "$kf")" = 600 ] && ok || bad "--keep mode 600"
	[ ! -e "$kf.cap" ] && ok || bad "--keep removes scratch file"
	rm -f "$kf"
else
	bad "--keep file exists"
fi
tn "unknown option rejected" dash "$C" --bogus
PATH="$SB:$PATH" dash "$C" --full-scripts >"$TD/full.txt" 2>/dev/null
grep -q 'full_scripts:1' "$TD/full.txt" && ok || bad "--full-scripts recorded in report"

# ---- sh -s with exec </dev/null: complete execution via stdin ---------------------------------------
trickle() { # trickle FILE: send the script in 4 chunks with pauses
	_n=$(wc -l <"$1" | tr -d ' ')
	_per=$((_n / 4 + 1))
	_i=1
	while [ "$_i" -le "$_n" ]; do
		sed -n "${_i},$((_i + _per - 1))p" "$1"
		sleep 0.2
		_i=$((_i + _per))
	done
}
for s in $SHELLS; do
	n=$(basename "$s")
	PATH="$SB:$PATH" $s -s <"$C" >"$TD/pipe-$n.txt" 2>/dev/null
	has "$TD/pipe-$n.txt" '## END lines=' && ok || bad "stdin-pipe[$n] reaches END"
	[ "$(grep -c '^## \[' "$TD/pipe-$n.txt")" -ge 100 ] && ok || bad "stdin-pipe[$n] all sections"
	grep -q '^# \[10\] status=' "$TD/pipe-$n.txt" && ok || bad "stdin-pipe[$n] last section ran"
	[ -f "$STDIN_SEEN" ] && [ ! -s "$STDIN_SEEN" ] && ok || bad "stdin-pipe[$n] tools see empty stdin (script not consumed)"
	rm -f "$STDIN_SEEN"
	# slow producer (script arrives in chunks, like a slow SSH link)
	trickle "$C" | PATH="$SB:$PATH" $s -s >"$TD/trick-$n.txt" 2>/dev/null
	has "$TD/trick-$n.txt" '## END lines=' && ok || bad "stdin-trickle[$n] reaches END"
	[ "$(grep -c '^## \[' "$TD/trick-$n.txt")" -ge 100 ] && ok || bad "stdin-trickle[$n] all sections"
	rm -f "$STDIN_SEEN"
	# truncated script: nothing may run (main is the last command)
	head -n 300 "$C" | PATH="$SB:$PATH" $s -s >"$TD/cut-$n.txt" 2>/dev/null
	[ ! -s "$TD/cut-$n.txt" ] && ok || bad "stdin-cut[$n] truncated script produces no partial run"
	leftover && bad "stdin[$n] no temp files" || ok
done

# ---- leak block ------------------------------------------------------------------------------------------
cat >"$TD/noredact.sh" <<EOF
TSEM_COLLECT_NOEXEC=1
. '$C'
redact() { cat; }
tskey_probe() { echo 'tskey-auth-kLEAKLEAK1234'; }
s10() { section 10 probe; tskey_probe | emit 10; }
s00() { :; }; s01() { :; }; s02() { :; }; s03() { :; }; s04() { :; }; s05() { :; }; s06() { :; }; s07() { :; }; s08() { :; }; s09() { :; }
main "\$@"
EOF
dash "$TD/noredact.sh" >"$TD/lb.out" 2>"$TD/lb.err"
[ $? -eq 3 ] && ok || bad "leak-block exit 3"
[ ! -s "$TD/lb.out" ] && ok || bad "leak-block: nothing on stdout"
hasnt "$TD/lb.err" 'LEAKLEAK' && ok || bad "leak-block: stderr shows counts only"
leftover && bad "leak-block: files deleted" || ok

# ---- run-collector ---------------------------------------------------------------------------------------
mkreport() { # mkreport FILE STATUS01 COMPLETENESS [nosum]
	{
		echo "# hdr"
		printf '\n## [00] a\nline\n# [00] status=ok issues=0 na=0 lines=1 truncated=0\n'
		printf '\n## [01] b\nline\n# [01] status=%s issues=0 na=0 lines=1 truncated=0\n' "$2"
		printf '\n## SUMMARY\nsections=2 statuses=2\ncompleteness=%s\n' "$3"
		[ "$2" = partial ] && echo '# [01] status=partial issues=1 na=0 lines=1 truncated=0'
		printf '\n## INDEX\n## [00] a\n## [01] b\n'
	} >"$1"
	_n=$(wc -l <"$1" | tr -d ' ')
	if [ "${4:-}" = nosum ]; then _h=none; else _h=$(sha256sum <"$1" | cut -d' ' -f1); fi
	printf '## END lines=%s sha256=%s\n' "$_n" "$_h" >>"$1"
}
rc_run() { # rc_run NAME REPORTFILE [extra args]: returns exit code, report dir in $TD/h-NAME
	_nm=$1
	_rf=$2
	shift 2
	mkdir -p "$TD/h-$_nm" "$TD/fb-$_nm"
	cat >"$TD/fb-$_nm/ssh" <<EOF
#!/bin/sh
for last; do :; done
printf '%s\n' "\$last" >"$TD/arg-$_nm"
cat "$_rf"
EOF
	chmod +x "$TD/fb-$_nm/ssh"
	HOME="$TD/h-$_nm" PATH="$TD/fb-$_nm:$PATH" sh "$R" root@fake "$_nm" "$@" >/dev/null 2>"$TD/rc-$_nm.err"
}
saved() { ls "$TD"/h-"$1"/glinet-discovery/"$1"-*.txt >/dev/null 2>&1; }

mkreport "$TD/r-ok" ok complete
rc_run okrun "$TD/r-ok"; rc=$?
[ $rc -eq 0 ] && saved okrun && ok || bad "run-collector complete report accepted (rc=$rc)"
rf=$(ls "$TD"/h-okrun/glinet-discovery/okrun-*.txt 2>/dev/null | head -n 1)
[ -n "$rf" ] && [ "$(stat -c %a "$rf")" = 600 ] && [ "$(stat -c %a "$TD/h-okrun/glinet-discovery")" = 700 ] && ok || bad "run-collector modes 600/700"
grep -q 'sh -s --$' "$TD/arg-okrun" && ok || bad "remote command is 'sh -s --'"

mkreport "$TD/r-part" partial partial
rc_run part "$TD/r-part"; rc=$?
[ $rc -eq 4 ] && saved part && ok || bad "run-collector partial => exit 4 and saved (rc=$rc)"
grep -q 'PARTIAL' "$TD/rc-part.err" && grep -q 'status=partial' "$TD/rc-part.err" && ok || bad "partial sections are listed"

mkreport "$TD/r-inc" ok incomplete
rc_run inc "$TD/r-inc"; rc=$?
[ $rc -eq 1 ] && ! saved inc && ok || bad "incomplete => rejected (rc=$rc)"

mkreport "$TD/r-cor" ok complete
sed 's/^line$/lime/;1,6s/^line$/lime/' "$TD/r-cor" >"$TD/r-cor2"
rc_run cor "$TD/r-cor2"; rc=$?
[ $rc -eq 1 ] && ! saved cor && grep -q 'sha256 mismatch' "$TD/rc-cor.err" && ok || bad "corrupted content => sha256 mismatch (rc=$rc)"

mkreport "$TD/r-cut" ok complete
head -n 8 "$TD/r-cut" >"$TD/r-cut2"
rc_run cut "$TD/r-cut2"; rc=$?
[ $rc -eq 1 ] && ! saved cut && ok || bad "stream cut off => rejected (rc=$rc)"

mkreport "$TD/r-end" ok complete
tail -n 1 "$TD/r-end" >"$TD/r-end-only"
{ head -n 4 "$TD/r-end"; tail -n 1 "$TD/r-end"; } >"$TD/r-end2"
rc_run endonly "$TD/r-end2"; rc=$?
[ $rc -eq 1 ] && ! saved endonly && ok || bad "valid-looking END alone is not enough (rc=$rc)"

mkreport "$TD/r-nosum" ok complete nosum
rc_run nosum "$TD/r-nosum"; rc=$?
[ $rc -eq 0 ] && grep -q 'integrity NOT verified' "$TD/rc-nosum.err" && ok || bad "no router sha256sum => warning (rc=$rc)"

{ head -n 3 "$TD/r-ok"; echo 'x tskey-auth-kABCDEFG12345'; sed -n '4,$p' "$TD/r-ok" | grep -v '^## END'; } >"$TD/r-leak0"
_n=$(wc -l <"$TD/r-leak0" | tr -d ' ')
{ cat "$TD/r-leak0"; printf '## END lines=%s sha256=%s\n' "$_n" "$(sha256sum <"$TD/r-leak0" | cut -d' ' -f1)"; } >"$TD/r-leak"
rc_run leak "$TD/r-leak"; rc=$?
[ $rc -eq 3 ] && ! saved leak && ok || bad "local leak scan => exit 3, nothing saved (rc=$rc)"

rc_run fullarg "$TD/r-ok" --full-scripts; rc=$?
[ $rc -eq 0 ] && grep -q 'sh -s -- --full-scripts' "$TD/arg-fullarg" && ok || bad "--full-scripts forwarded to the router (rc=$rc)"
rc_run badarg "$TD/r-ok" --bogus; rc=$?
[ $rc -eq 2 ] && ok || bad "unknown 3rd argument rejected (rc=$rc)"
tn "run-collector rejects missing args" sh "$R"

# Regression: INDEX length must not matter (real report was rejected with
# "section/index count mismatch"); the SUMMARY section count is what counts.
{
	echo "# hdr"
	printf '\n## [00] a\nline\n# [00] status=ok issues=0 na=0 lines=1 truncated=0\n'
	printf '\n## [01] b\nline\n# [01] status=ok issues=0 na=0 lines=1 truncated=0\n'
	printf '\n## SUMMARY\nsections=2 statuses=2\ncompleteness=complete\n'
	printf '\n## INDEX\n## [00] a\n## [01] b\n## [00] a\n## [01] b\n## [00] a\n'
} >"$TD/r-idx0"
_n=$(wc -l <"$TD/r-idx0" | tr -d ' ')
{ cat "$TD/r-idx0"; printf '## END lines=%s sha256=%s\n' "$_n" "$(sha256sum <"$TD/r-idx0" | cut -d' ' -f1)"; } >"$TD/r-idx"
rc_run idx "$TD/r-idx"; rc=$?
[ $rc -eq 0 ] && saved idx && ok || bad "valid report with irregular INDEX length accepted (rc=$rc)"
sed 's/^sections=2 /sections=3 /' "$TD/r-idx0" >"$TD/r-hdr0"
_n=$(wc -l <"$TD/r-hdr0" | tr -d ' ')
{ cat "$TD/r-hdr0"; printf '## END lines=%s sha256=%s\n' "$_n" "$(sha256sum <"$TD/r-hdr0" | cut -d' ' -f1)"; } >"$TD/r-hdr"
rc_run hdr "$TD/r-hdr"; rc=$?
[ $rc -eq 1 ] && ! saved hdr && grep -q 'section count mismatch' "$TD/rc-hdr.err" && ok || bad "SUMMARY/header count mismatch still rejected (rc=$rc)"

echo "passed: $PASS  failed: $FAIL"
[ "$ASH_USED" = 1 ] || echo "OPEN: BusyBox ash not tested"
[ "$FAIL" -eq 0 ]
