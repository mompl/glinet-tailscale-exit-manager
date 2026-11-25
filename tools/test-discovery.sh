#!/bin/sh
# Tests for tools/discovery.sh. Run:  sh tools/test-discovery.sh
# Optional: SHELLS="dash bash busybox" to choose shells (default: dash bash).
# Nothing here touches the host except a temp dir and one report in /tmp
# (created and removed by the test).

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/discovery.sh
SHELLS=${SHELLS:-"dash bash"}
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { # name command...
	_n=$1
	shift
	if "$@" >/dev/null 2>&1; then ok "$_n"; else bad "$_n"; fi
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

echo "== static checks"
check "line 1 is the sh shebang" test "$(sed -n 1p "$SCRIPT")" = '#!/bin/sh'
check "line 2 is umask 077" test "$(sed -n 2p "$SCRIPT")" = 'umask 077'
check "no dynamic code execution (eval/source of data)" sh -c "! grep -v '^[[:space:]]*#' '$SCRIPT' | grep -Ew 'eval|exec'"
check "no bashisms: [[ ]], local, echo -e, <(, pipefail" sh -c "! grep -v '^[[:space:]]*#' '$SCRIPT' | grep -E '(^|[[:space:];])\[\[ |^[[:space:]]*local |echo -e|<\(|pipefail|\\$\\{[A-Za-z_]+//|\\$\\{[A-Za-z_]+:[0-9]'"
# read-only guarantee: no mutating commands (the single allowed rm removes our own report)
FORBID='(^|[^A-Za-z_-])(mv|cp|reboot|poweroff|halt|service|opkg (install|remove|update|upgrade)|uci (set|add|delete|commit|revert)|nft (add|delete|flush|insert|replace|-f)|ip(6)?tables(-restore)? .*(-A|-I|-D|-F|-X|-P)|tailscale (up|down|set|logout|login)|/etc/init\.d/[A-Za-z_-]+ (start|stop|restart|reload|enable|disable)|sysctl -w|kill|killall|ifup|ifdown|wifi|firewall (reload|restart)|chmod [0-7]+ /etc|>[[:space:]]*/etc)([^A-Za-z_-]|$)'
check "no mutating commands" sh -c "! grep -v '^[[:space:]]*#' '$SCRIPT' | grep -E '$FORBID'"
check "only allowed rm is the report cleanup" test "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -cE '(^|[^A-Za-z_])rm ')" = 1
check "that rm targets only \$OUT" sh -c "grep -v '^[[:space:]]*#' '$SCRIPT' | grep -E '(^|[^A-Za-z_])rm ' | grep -q 'rm -f \"\$OUT\"'"

echo "== syntax"
for sh in $SHELLS; do
	if command -v "$sh" >/dev/null 2>&1; then
		check "$sh -n" "$sh" -n "$SCRIPT"
		[ "$sh" = bash ] && check "bash --posix -n" bash --posix -n "$SCRIPT"
	else
		echo "  skip $sh (not installed)"
	fi
done

echo "== redaction (fixture)"
cat >"$TMP/secrets.txt" <<'EOF'
network.wg0.private_key='aGVsbG93b3JsZHRoaXNpc2Fwcml2YXRla2V5MDEyMzQ='
network.wg0.preshared_key='cHJlc2hhcmVkcHJlc2hhcmVkcHJlc2hhcmVkMDEyMzQ='
network.@wireguard_wg0[0].public_key='cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMTI='
network.wan.password='hunter2-PPPoE'
network.wan.username='customer4711@isp.example'
wireless.default_radio0.key='WifiSecretKey123'
wireless.default_radio0.sae_password='SaePass!456'
option private_key 'optionSecret789'
list token 'listToken000'
"AuthKey": "tskey-auth-kAbC123CNTRL-supersecretvalue",
"PrivateNodeKey": "privkey:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
"NodeKey": "nodekey:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
tailscale up --authkey=tskey-auth-kXyZ999CNTRL-anothersecret --hostname=x
tailscale up --auth-key tskey-auth-kQqQ111CNTRL-spacesep
tailscale up --authkey tskey-preauth-kPre222-preauthsecret
curl -H "Authorization: Bearer abc.DEF-123_xyz~tok"
Authorization: Basic dXNlcjpwYXNz
Proxy-Authorization: Basic cHJveHl1c2VyOnByb3h5cHc=
Send token Bearer zzz.BEARER.only99 to the API
https://admin:s3cr3tpw@router.example/path
To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e6f7
api_token=abcdef1234567890
pasted into chat: tskey-auth-kBare000CNTRL-barevalue ok?
secret: topsecretvalue
-----BEGIN OPENVPN STATIC KEY-----
0123456789abcdef0123456789abcdef
-----END OPENVPN STATIC KEY-----
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
-----END PRIVATE KEY-----
wg key line: aGVsbG93b3JsZHRoaXNpc2Fwcml2YXRla2V5MDEyMzQ= trailing
100.64.0.9  host1.tail1234.ts.net  jane.doe@example.org  linux  active
eth0 link/ether 94:83:c4:aa:bb:cc brd ff:ff:ff:ff:ff:ff
EOF

cat >"$TMP/benign.txt" <<'EOF'
network.lan.ipaddr='192.168.8.1'
network.lan.netmask='255.255.255.0'
firewall.@zone[0].name='lan'
firewall.@rule[1].target='ACCEPT'
dhcp.lan.start='100'
"ExitNodeAllowLANAccess": false,
100.64.0.9  host1  linux  active; offers exit node
default via 192.168.1.1 dev eth0 proto static
EOF

cat >"$TMP/redact-test.sh" <<EOF
TSEM_DISCOVERY_NOEXEC=1
. '$SCRIPT'
redact <"\$1"
EOF

for sh in $SHELLS; do
	command -v "$sh" >/dev/null 2>&1 || continue
	"$sh" "$TMP/redact-test.sh" "$TMP/secrets.txt" >"$TMP/secrets.out" 2>"$TMP/secrets.err"
	check "[$sh] redact ran without errors" test ! -s "$TMP/secrets.err"
	_before_fail=$FAIL
	for needle in \
		aGVsbG93b3JsZHRoaXNpc2Fwcml2YXRla2V5MDEyMzQ cHJlc2hhcmVkcHJlc2hhcmVkcHJlc2hhcmVkMDEyMzQ \
		cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMTI hunter2 customer4711 WifiSecretKey123 'SaePass!456' \
		optionSecret789 listToken000 supersecretvalue 0123456789abcdef0123456789abcdef anothersecret \
		spacesep preauthsecret abc.DEF-123_xyz dXNlcjpwYXNz s3cr3tpw 1a2b3c4d5e6f7 abcdef1234567890 \
		topsecretvalue barevalue cHJveHl1c2VyOnByb3h5cHc zzz.BEARER.only99 MIIEvQIBADANBgkqhkiG9w0BAQEFAASC jane.doe tail1234 94:83:c4 fedcba9876543210; do
		if grep -qF -- "$needle" "$TMP/secrets.out"; then bad "[$sh] leaked: $needle"; else PASS=$((PASS + 1)); fi
	done
	[ "$FAIL" -eq "$_before_fail" ] && ok "[$sh] no fixture secret survived (25 patterns checked)"
	"$sh" "$TMP/redact-test.sh" "$TMP/benign.txt" >"$TMP/benign.out" 2>&1
	check "[$sh] benign config lines unchanged" cmp -s "$TMP/benign.txt" "$TMP/benign.out"
done

echo "== drop_secret_lines / leak_check / limit"
cat >"$TMP/fn-test.sh" <<EOF
TSEM_DISCOVERY_NOEXEC=1
. '$SCRIPT'
printf '%s\n' "network.lan.ipaddr='1.2.3.4'" "network.wan.password='x'" "network.wg0.private_key='y'" "network.wg0.listen_port='51820'" | drop_secret_lines
EOF
dash "$TMP/fn-test.sh" >"$TMP/fn.out" 2>&1 || sh "$TMP/fn-test.sh" >"$TMP/fn.out" 2>&1
check "secret-bearing uci lines are dropped" sh -c "! grep -qE \"password|private_key\" '$TMP/fn.out'"
check "non-secret uci lines are kept" grep -q "listen_port" "$TMP/fn.out"
check "omission is reported" grep -q "2 secret-bearing line(s) omitted" "$TMP/fn.out"
printf 'clean line\n' >"$TMP/clean.txt"
printf 'tskey-auth-kLEAK123-abc\n' >"$TMP/dirty.txt"
cat >"$TMP/leak-test.sh" <<EOF
TSEM_DISCOVERY_NOEXEC=1
. '$SCRIPT'
leak_check "\$1"
EOF
check "leak_check passes a clean file" sh "$TMP/leak-test.sh" "$TMP/clean.txt"
check "leak_check fails a file with a surviving key" sh -c "! sh '$TMP/leak-test.sh' '$TMP/dirty.txt'"
cat >"$TMP/limit-test.sh" <<EOF
TSEM_DISCOVERY_NOEXEC=1
. '$SCRIPT'
LIMIT=5
seq 1 20 | limit
EOF
sh "$TMP/limit-test.sh" >"$TMP/limit.out" 2>&1
check "limit truncates with marker" test "$(wc -l <"$TMP/limit.out" | tr -d ' ')" = 6

echo "== end-to-end with stub tools that emit secrets"
mkdir -p "$TMP/stubs"
cat >"$TMP/stubs/tailscale" <<'EOF'
#!/bin/sh
case "$1" in
version) echo "1.92.5" ;;
status) echo "100.64.0.9  host1.tail1234.ts.net  jane.doe@example.org  linux  active; offers exit node"
	echo "Log in at: https://login.tailscale.com/a/1a2b3c4d5e6f7" ;;
debug)
	cat <<'JSON'
{
  "ControlURL": "https://controlplane.tailscale.com",
  "RouteAll": true,
  "ExitNodeID": "nSTUBnodeID",
  "ExitNodeAllowLANAccess": false,
  "AdvertiseRoutes": [
    "192.168.8.0/24"
  ],
  "Persist": {
    "PrivateNodeKey": "privkey:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "AuthKey": "tskey-auth-kStub123CNTRL-neverprint"
  }
}
JSON
	;;
esac
EOF
cat >"$TMP/stubs/uci" <<'EOF'
#!/bin/sh
case "$2" in
network) echo "network.lan.ipaddr='192.168.8.1'"; echo "network.wan.password='hunter2'"; echo "network.wg0.private_key='aGVsbG93b3JsZHRoaXNpc2Fwcml2YXRla2V5MDEyMzQ='"; echo "network.wg0.public_key='cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMTI='" ;;
glconfig) echo "glconfig.general.mode='router'"; echo "glconfig.cloud.token='cloudtoken123'"; echo "glconfig.admin.password='adminpw'"; echo "glconfig.tailscale.enable='1'" ;;
tailscale) echo "tailscale.settings.authkey='tskey-auth-kUci999-uciSecret'" ;;
*) echo "$2.x.y='z'" ;;
esac
EOF
cat >"$TMP/stubs/logread" <<'EOF'
#!/bin/sh
echo "tailscaled: To authenticate, visit: https://login.tailscale.com/a/9z8y7x6w5v"
echo "tailscaled: --authkey=tskey-auth-kLog555-logsecret"
EOF
chmod +x "$TMP/stubs/"*

for sh in $SHELLS; do
	command -v "$sh" >/dev/null 2>&1 || continue
	REPORT=$(PATH="$TMP/stubs:$PATH" "$sh" "$SCRIPT" 2>"$TMP/e2e.err" | sed -n 's/^Report: \(.*\) (mode 600)$/\1/p')
	if [ -n "$REPORT" ] && [ -f "$REPORT" ]; then
		ok "[$sh] report created"
		check "[$sh] report mode is 600" test "$(ls -l "$REPORT" | cut -c1-10)" = '-rw-------'
		check "[$sh] report name is under /tmp" sh -c "case '$REPORT' in /tmp/tsem-discovery-*) true;; *) false;; esac"
		_before_fail=$FAIL
		for needle in neverprint hunter2 aGVsbG93b3JsZHRoaXNpc2Fwcml2YXRla2V5MDEyMzQ cloudtoken123 adminpw uciSecret logsecret \
			1a2b3c4d5e6f7 9z8y7x6w5v 0123456789abcdef0123456789abcdef jane.doe tail1234; do
			if grep -qF -- "$needle" "$REPORT"; then bad "[$sh] e2e leaked: $needle"; else PASS=$((PASS + 1)); fi
		done
		[ "$FAIL" -eq "$_before_fail" ] && ok "[$sh] no stub secret in the report (11 patterns checked)"
		check "[$sh] allowlisted prefs present (ExitNodeID)" grep -q ExitNodeID "$REPORT"
		check "[$sh] non-allowlisted prefs absent (Persist)" sh -c "! grep -q Persist '$REPORT'"
		check "[$sh] glconfig filtered (mode kept, cloud/admin lines gone)" sh -c "grep -q \"glconfig.general.mode\" '$REPORT' && ! grep -q 'glconfig.cloud' '$REPORT'"
		check "[$sh] uci network ip kept" grep -q "network.lan.ipaddr" "$REPORT"
		rm -f "$REPORT"
	else
		bad "[$sh] report not created: $(cat "$TMP/e2e.err")"
	fi
done

echo "== report is removed when a secret survives"
cat >"$TMP/stubs/ip" <<'EOF'
#!/bin/sh
# emits a 44-char key-looking token in a form redact() deliberately does not know
echo "weird-field aGVsbG93b3JsZHRoaXNpc2Fwcml2YXRla2V5MDEyMzQ="
EOF
cat >"$TMP/stubs/tailscale" <<'EOF'
#!/bin/sh
echo "unknown-format tskey-auth-kSneaky-abc"
EOF
chmod +x "$TMP/stubs/ip" "$TMP/stubs/tailscale"
BEFORE=$(ls /tmp/tsem-discovery-* 2>/dev/null | wc -l)
# Make redact() blind on purpose by sourcing and overriding it, then calling main.
cat >"$TMP/blind.sh" <<EOF
TSEM_DISCOVERY_NOEXEC=1
. '$SCRIPT'
redact() { cat; }
main
EOF
PATH="$TMP/stubs:$PATH" sh "$TMP/blind.sh" >/dev/null 2>"$TMP/blind.err"
RC=$?
AFTER=$(ls /tmp/tsem-discovery-* 2>/dev/null | wc -l)
check "exit code 3 when a secret survives" test "$RC" = 3
check "report file was deleted" test "$BEFORE" = "$AFTER"
check "error message printed" grep -q "report deleted" "$TMP/blind.err"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
