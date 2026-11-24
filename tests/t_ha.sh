# shellcheck shell=sh
# Home Assistant integration (separately installable module): API client against a fake rpcd/web endpoint in front of the
# REAL plugin + controller, and the platform code against a minimal Home Assistant stand-in. Needs python3.

test_ha_client_against_real_plugin_and_controller() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 is not installed"
	_api_setup 2>/dev/null || { . "$ROOT/tests/t_api.sh"; _api_setup; }
	export ROOT SH
	python3 "$ROOT/homeassistant/tests/test_client.py" 2>&1 || fail "HA client tests failed"
}

test_ha_platforms_with_home_assistant_stub() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 is not installed"
	_api_setup 2>/dev/null || { . "$ROOT/tests/t_api.sh"; _api_setup; }
	export ROOT SH
	python3 "$ROOT/homeassistant/tests/test_platforms.py" 2>&1 || fail "HA platform tests failed"
}

test_ha_integration_is_separate_from_the_router_package() {
	# the router installer must not ship Home Assistant files, and the HA module needs nothing from the router tree
	! grep -q "homeassistant" "$ROOT/install.sh" || fail "install.sh references homeassistant"
	[ -f "$ROOT/homeassistant/custom_components/tsem/manifest.json" ] || fail "manifest missing"
	! grep -rn "mqtt" "$ROOT/homeassistant/custom_components/tsem" >/dev/null || fail "HA module must not require MQTT"
}
