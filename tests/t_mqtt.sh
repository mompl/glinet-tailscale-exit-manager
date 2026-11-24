# shellcheck shell=sh
# Home Assistant MQTT bridge, against stub mosquitto_pub/sub.

mq_setup() {
	export MQ_STUB_DIR=$T/mq MQTT_CONF=$T/mqtt.conf MOSQUITTO_PUB=$ROOT/tests/stubs/mosquitto_pub MOSQUITTO_SUB=$ROOT/tests/stubs/mosquitto_sub
	export TSEM_BIN="$ROOT/src/usr/sbin/tsem" TSEM_MQTT_ONCE=1
	# tsem is a script: call it through $SH for the test
	printf '#!/bin/sh\nexec %s %s "$@"\n' "$SH" "$ROOT/src/usr/sbin/tsem" >"$T/tsem-wrap"; chmod +x "$T/tsem-wrap"
	export TSEM_BIN=$T/tsem-wrap
	mkdir -p "$MQ_STUB_DIR"; : >"$MQ_STUB_DIR/published"
	printf 'secret-pass\n' >"$T/mqtt.pass"; chmod 600 "$T/mqtt.pass"
	cat >"$MQTT_CONF" <<X
MQTT_HOST=broker.local
MQTT_PORT=1883
MQTT_USER=tsem
MQTT_PASSFILE=$T/mqtt.pass
MQTT_BASE=tsem/test
MQTT_ID=test
MQTT_INTERVAL=2
X
}
mq() { "$SH" "$ROOT/src/usr/sbin/tsem-mqtt" >/dev/null 2>&1; }
mq_cmd() { printf '%s\n' "$1 $2" >"$MQ_STUB_DIR/sub_queue"; }

test_discovery_and_state_published() {
	mq_setup; go_german; mq
	_p=$(cat "$MQ_STUB_DIR/published")
	assert_contains switch "homeassistant/switch/tsem_test/german_internet/config" "$_p"
	assert_contains button "homeassistant/button/tsem_test/failover_now/config" "$_p"
	assert_contains binary "homeassistant/binary_sensor/tsem_test/kill_switch/config" "$_p"
	assert_contains state 'tsem/test/state' "$_p"
	assert_contains payload '"state":"PRIMARY_ACTIVE"' "$_p"
	assert_contains avail "tsem/test/availability	online" "$_p"
}

test_discovery_commands_are_not_retained() {
	mq_setup; go_german; mq
	grep 'german_internet/config' "$MQ_STUB_DIR/published" | grep -q '"retain":false' || fail "switch discovery must declare retain:false"
	grep 'failover_now/config' "$MQ_STUB_DIR/published" | grep -q '"retain":false' || fail "button discovery must declare retain:false"
}

test_discovery_payloads_are_valid_json() {
	mq_setup; go_german; mq
	command -v python3 >/dev/null 2>&1 || return 0
	awk -F'\t' '$2 ~ /\/config$/ { print $3 }' "$MQ_STUB_DIR/published" | while IFS= read -r l; do
		printf '%s' "$l" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["unique_id"] and d["device"]' || exit 1
	done || fail "invalid discovery JSON"
}

test_command_on_sets_german_from_ha() {
	mq_setup
	mq_cmd tsem/test/cmd/german ON; mq
	assert_eq mode german "$(st mode)"
	assert_eq source ha "$(st source)"
}

test_command_off_sets_direct() {
	mq_setup; go_german
	mq_cmd tsem/test/cmd/german OFF; mq
	assert_eq mode direct "$(st mode)"
	assert_eq guard open "$(guard)"
}

test_subscribe_ignores_retained_and_uses_persistent_session() {
	mq_setup; mq
	_a=$(cat "$MQ_STUB_DIR/sub_args")
	assert_contains retained '-R' "$_a"
	assert_contains session '-c' "$_a"
	assert_contains qos '-q 1' "$_a"
}

test_garbage_payloads_do_not_change_state() {
	mq_setup; go_german
	_s=$(isum)
	for p in ON1 "ON;reboot" '$(touch x)' on "" TOGGLE; do mq_cmd tsem/test/cmd/german "$p"; mq; done
	mq_cmd tsem/test/cmd/unknown ON; mq
	mq_cmd tsem/test/cmd/failover_now NOW; mq
	assert_eq "intent untouched" "$_s" "$(isum)"
	[ ! -e x ] || fail "payload was executed"
}

test_publishing_state_never_writes_intent() {
	mq_setup; go_german
	_s=$(isum)
	mq; mq; mq
	assert_eq "intent untouched" "$_s" "$(isum)"
}

test_auto_failover_switch() {
	mq_setup; go_german
	mq_cmd tsem/test/cmd/auto_failover OFF; mq
	assert_eq failover off "$(st failover)"
	mq_cmd tsem/test/cmd/auto_failover ON; mq
	assert_eq failover auto "$(st failover)"
}

test_failover_now_button() {
	mq_setup; go_german
	mq_cmd tsem/test/cmd/failover_now PRESS; mq
	tk 6
	assert_eq state SECONDARY_ACTIVE "$(st state)"
}

test_password_not_on_command_line_and_options_file_private() {
	mq_setup; mq
	# the stubs receive "-o <file>" only; the password must not appear in any argument
	! grep -q 'secret-pass' "$MQ_STUB_DIR/sub_args" || fail "password leaked into mosquitto_sub arguments"
	grep -q 'secret-pass' "$MQ_STUB_DIR/opts.seen" || fail "options file should carry the password"
	[ ! -e "$TSEM_RUN_DIR/mqtt.opts" ] || fail "options file must be removed on exit"
}

test_hw_and_ha_race_keeps_state_consistent() {
	mq_setup
	( tsem set german --no-wait --source hw ) &
	mq_cmd tsem/test/cmd/german OFF; mq
	wait
	assert_eq intent ok "$(st intent)"
	_m=$(st mode); tk 10
	assert_eq stable "$_m" "$(st mode)"
}

test_bad_config_rejected() {
	mq_setup
	printf 'MQTT_HOST=host;rm -rf /\n' >"$MQTT_CONF"
	"$SH" "$ROOT/src/usr/sbin/tsem-mqtt" >/dev/null 2>&1
	assert_eq "no publish" 0 "$(wc -l <"$MQ_STUB_DIR/published")"
}
