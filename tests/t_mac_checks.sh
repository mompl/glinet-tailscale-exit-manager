# shellcheck shell=sh
# Mac-side checks of phases 8/9 (API, GUI, Home Assistant) against a local fake web endpoint that sits in front of
# the REAL plugin and controller. The functions are taken from tools/run-rc3-active-mac.sh as they are.

_fn_body() { sed -n "/^$2() {/,/^}/p" "$1"; }

_mc_setup() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 is not installed"
	command -v curl >/dev/null 2>&1 || need_skip "curl is not installed"
	. "$ROOT/tests/t_api.sh"
	_api_setup
	export ROOT SH
	mkfifo "$T/hold"
	python3 "$ROOT/homeassistant/tests/fake_server.py" <"$T/hold" >"$T/port" 2>"$T/server.err" &
	SRV=$!
	exec 9>"$T/hold"
	_i=0; while [ ! -s "$T/port" ] && [ "$_i" -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
	PORT=$(cat "$T/port")
	[ -n "$PORT" ] || fail "fake server did not start: $(cat "$T/server.err")"
	MAC=$ROOT/tools/run-rc3-active-mac.sh
	_mc_load
	OUT=$T/macout; mkdir -p "$OUT"; REPORT=$OUT/report.txt; : >"$REPORT"
	MCURL=curl API_URL=http://127.0.0.1:$PORT GUI_URL='' API_USER='' HA_URL='' HA_TOKEN_FILE=''
	say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
	RS() { tsem status | sed 's/^/ /' | tr '\n' ' ' | sed 's/^ */INFO status /'; }
}
_mc_load() {
	for _f in mrow ubus_rpc mac_api_gui_check mac_ha_check; do eval "$(_fn_body "$MAC" "$_f")"; done
}
_mc_stop() { exec 9>&-; kill "$SRV" 2>/dev/null; }

test_mac_api_check_without_credentials_proves_refusals_and_marks_the_rest_unverified() {
	_mc_setup
	_o=$(mac_api_gui_check 2>&1); _rc=$?; _mc_stop
	assert_eq rc 0 "$_rc"
	assert_contains reach "PASS  mac.api.reachable" "$_o"
	assert_contains bad "PASS  mac.api.badlogin" "$_o"
	assert_contains unauth "PASS  mac.api.unauth.read" "$_o"
	assert_contains write "PASS  mac.api.unauth.write" "$_o"
	assert_contains gui "PASS  mac.gui.served" "$_o"
	assert_contains unv "WARN  mac.api.auth.rw" "$_o"
	assert_contains why "UNVERIFIED: no --api-user" "$_o"
}

test_mac_api_check_with_credentials_exercises_read_and_the_write_path() {
	_mc_setup
	go_german 8
	_seq=$(st seq)
	_o=$(TSEM_API_PASSWORD=pw API_USER=admin mac_api_gui_check 2>&1); _rc=$?; _mc_stop
	assert_eq rc 0 "$_rc"
	assert_contains badpass "PASS  mac.api.badpass" "$_o"
	assert_contains rw "PASS  mac.api.auth.rw" "$_o"
	assert_eq "mode unchanged by the check" german "$(st mode)"
	assert_eq "the no-op request did not write a new intent" "$_seq" "$(st seq)"
}

test_mac_api_check_reports_wrong_credentials_and_missing_endpoint_honestly() {
	_mc_setup
	_o=$(API_USER=admin TSEM_API_PASSWORD=wrong mac_api_gui_check 2>&1); _rc=$?
	assert_eq rc 1 "$_rc"
	assert_contains fail "FAIL  mac.api.auth.rw" "$_o"
	_mc_stop
	API_URL=http://127.0.0.1:1
	_o=$(mac_api_gui_check 2>&1); _rc=$?
	assert_eq "unreachable is not a failure of the router, but never a pass" 0 "$_rc"
	assert_contains unv "WARN  mac.api.reachable" "$_o"
	case $_o in *"PASS  mac.api.unauth"*) fail "a missing endpoint was reported as a pass" ;; esac
}

test_mac_gui_check_distinguishes_missing_view_from_missing_luci() {
	_mc_setup
	_mc_stop
	for _v in "FAKE_GUI=0 FAKE_LUCI=1:FAIL" "FAKE_GUI=0 FAKE_LUCI=0:WARN"; do
		_env=${_v%%:*} _want=${_v##*:}
		rm -f "$T/port2"; mkfifo "$T/hold2" 2>/dev/null
		env $_env python3 "$ROOT/homeassistant/tests/fake_server.py" <"$T/hold2" >"$T/port2" 2>/dev/null &
		_s2=$!
		exec 8>"$T/hold2"
		_i=0; while [ ! -s "$T/port2" ] && [ "$_i" -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
		API_URL=http://127.0.0.1:$(cat "$T/port2")
		_o=$(mac_api_gui_check 2>&1)
		exec 8>&-; kill "$_s2" 2>/dev/null; rm -f "$T/hold2"
		assert_contains "$_env" "$_want  mac.gui.served" "$_o"
	done
}

test_mac_ha_check_compares_home_assistant_with_the_router() {
	_mc_setup
	go_german 8
	_o=$(mac_ha_check 2>&1); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains unv "UNVERIFIED: no --ha-url" "$_o"
	HA_URL=http://127.0.0.1:$PORT
	_o=$(mac_ha_check 2>&1)
	assert_contains notoken "UNVERIFIED: no token" "$_o"
	printf 'test-token\n' >"$T/token"; HA_TOKEN_FILE=$T/token
	_o=$(mac_ha_check 2>&1); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains pass "PASS  ha.entities" "$_o"
	printf 'wrong\n' >"$T/token"
	_o=$(mac_ha_check 2>&1); _rc=$?
	assert_eq "an unauthorised token is a failure to read, never a pass" 1 "$_rc"
	case $_o in *"PASS  ha.entities"*) fail "passed with a bad token" ;; esac
	_mc_stop
}
