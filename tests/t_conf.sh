# shellcheck shell=sh
# Config parsing: whitelist, validation, no code execution.

_conf_status() { TSEM_CONF=$T/c.conf tsem diag 2>&1; }

test_valid_config_is_applied() {
	unset TSEM_PRIMARY TSEM_SECONDARY
	cat >"$T/c.conf" <<'X'
# comment
TSEM_PRIMARY=100.1.2.3
TSEM_SECONDARY="100.1.2.4"
TSEM_LAN_IFACES="br-lan br-guest"
TSEM_FAIL_N=5
X
	_o=$(_conf_status)
	assert_contains primary 'TSEM_PRIMARY=100.1.2.3' "$_o"
	assert_contains secondary 'TSEM_SECONDARY=100.1.2.4' "$_o"
	assert_contains lan 'TSEM_LAN_IFACES=br-lan br-guest' "$_o"
	assert_contains failn 'TSEM_FAIL_N=5' "$_o"
}

test_invalid_values_ignored() {
	unset TSEM_PRIMARY
	printf 'TSEM_PRIMARY=999.1.1.1\nTSEM_LAN_IFACES=br lan;x\nTSEM_FAIL_N=abc\n' >"$T/c.conf"
	_o=$(_conf_status)
	assert_contains primary 'TSEM_PRIMARY=' "$_o"
	case $_o in *'TSEM_PRIMARY=999'*) fail "invalid primary accepted" ;; esac
	assert_contains lan 'TSEM_LAN_IFACES=br-lan' "$_o"
	assert_contains failn 'TSEM_FAIL_N=3' "$_o"
}

test_config_cannot_execute_code() {
	printf 'TSEM_PRIMARY=$(touch %s/pwned)\nTSEM_DNS_PROBE_HOST=`touch %s/pwned2`\nTSEM_LAN_IFACES=br-lan;touch\n' "$T" "$T" >"$T/c.conf"
	_conf_status >/dev/null
	[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] || fail "config executed code"
}

test_unknown_keys_ignored() {
	printf 'EVIL=1\nPATH=/nonexistent\nTSEM_FAIL_N=4\n' >"$T/c.conf"
	_o=$(_conf_status)
	assert_contains unknown 'unknown key' "$_o"
	assert_contains failn 'TSEM_FAIL_N=4' "$_o"
}

test_env_overrides_file() {
	printf 'TSEM_FAIL_N=9\n' >"$T/c.conf"
	_o=$(TSEM_FAIL_N=2 _conf_status)
	assert_contains env 'TSEM_FAIL_N=2' "$_o"
}

test_timing_sanity_clamps() {
	printf 'TSEM_FAIL_N=0\nTSEM_UP_N=0\nTSEM_RETURN_N=1\nTSEM_UP_N=3\n' >"$T/c.conf"
	_o=$(_conf_status)
	assert_contains failn 'TSEM_FAIL_N=3' "$_o"
	assert_contains retn 'TSEM_RETURN_N=3' "$_o"
}

test_rc2_keys_and_defaults() {
	unset TSEM_PRIMARY TSEM_SECONDARY
	: >"$T/c.conf"
	_o=$(_conf_status)
	for kv in TSEM_OUT_GUARD=on TSEM_ALLOW_NTP=1 TSEM_ALLOW_UNDERLAY_DNS=0 TSEM_UNDERLAY_MARK=0x80000/0xff0000 \
		TSEM_INTERVAL=5 TSEM_INTERVAL_RECOVERY=15 TSEM_INTERVAL_STEADY=20 TSEM_INTERVAL_IDLE=60; do
		assert_contains "$kv" "$kv" "$_o"
	done
}

test_rc2_invalid_values_are_ignored() {
	unset TSEM_PRIMARY TSEM_SECONDARY
	printf 'TSEM_OUT_GUARD=maybe\nTSEM_ALLOW_NTP=2\nTSEM_UNDERLAY_MARK=0x80000\nTSEM_UNDERLAY_MARK=zz/yy\nTSEM_PRIMARY_NAME=bad name\nTSEM_SECONDARY_NAME=-x\nTSEM_OUT_LOCAL_IFACES=br guest;x\n' >"$T/c.conf"
	_o=$(_conf_status)
	assert_contains guard 'TSEM_OUT_GUARD=on' "$_o"
	assert_contains ntp 'TSEM_ALLOW_NTP=1' "$_o"
	assert_contains mark 'TSEM_UNDERLAY_MARK=0x80000/0xff0000' "$_o"
	assert_contains pn 'TSEM_PRIMARY_NAME=
' "$_o"
	assert_contains local 'TSEM_OUT_LOCAL_IFACES=
' "$_o"
}

test_rc2_exit_node_names_and_interval_clamps() {
	unset TSEM_PRIMARY TSEM_SECONDARY
	printf 'TSEM_PRIMARY_NAME=exit-a\nTSEM_SECONDARY_NAME=exit-b\nTSEM_INTERVAL=10\nTSEM_INTERVAL_STEADY=3\nTSEM_INTERVAL_IDLE=1\n' >"$T/c.conf"
	_o=$(_conf_status)
	assert_contains pn 'TSEM_PRIMARY_NAME=exit-a' "$_o"
	assert_contains sn 'TSEM_SECONDARY_NAME=exit-b' "$_o"
	assert_contains steady 'TSEM_INTERVAL_STEADY=10' "$_o"
	assert_contains idle 'TSEM_INTERVAL_IDLE=10' "$_o"
}
