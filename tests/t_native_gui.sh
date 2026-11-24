# shellcheck shell=sh
# Native GL.iNet GUI component: installer gate, additive-only behaviour, rollback/uninstall, bundle contract.
# Runs against a fake firmware root. It says NOTHING about a real GL.iNet 4.11.0 firmware (that is the preflight's
# and the acceptance's job): result classes are PASS-simulated here.

_nat_fw() { # fake GL.iNet UI layout inside the throw-away root
	mkdir -p "$RT/usr/share/oui/menu.d" "$RT/usr/lib/oui-httpd/rpc" "$RT/www/views"
	printf '{\n\t"index": 31,\n\t"view": "tailscale",\n\t"title": "Tailscale",\n\t"level": 2,\n\t"parent": "applications",\n\t"parent_icon": "application",\n\t"parent_index": 50,\n\t"show_mode": ["router"]\n}\n' >"$RT/usr/share/oui/menu.d/tailscale.json"
	printf '{"index": 32, "view": "zerotier", "title": "ZeroTier", "level": 2, "parent": "applications"}\n' >"$RT/usr/share/oui/menu.d/zerotier.json"
	printf 'stock bundle\n' >"$RT/www/views/gl-sdk4-ui-tailscale.common.js.gz"
	printf -- '-- stock rpc\nreturn {}\n' >"$RT/usr/lib/oui-httpd/rpc/tailscale"
}
_nat_setup() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 is not installed (jsonfilter stand-in)"
	. "$ROOT/tests/t_install.sh"; . "$ROOT/tests/t_install_components.sh"; mkroot; _nat_fw
	PATH=$ROOT/tests/stubs:$PATH; export PATH
}
_fw_sum() { (cd "$RT" && for f in usr/share/oui/menu.d/tailscale.json usr/share/oui/menu.d/zerotier.json www/views/gl-sdk4-ui-tailscale.common.js.gz usr/lib/oui-httpd/rpc/tailscale; do printf '%s %s\n' "$f" "$(md5sum <"$f")"; done); }
_NATIVE=core,api,native-gui

test_native_gui_is_refused_when_named_without_acknowledgement() {
	_nat_setup; _s=$(snap)
	if inst --yes --components $_NATIVE; then fail "an explicit native-gui must not install without the acknowledgement"; fi
	assert_contains why "REFUSED native-gui" "$(cat "$T/inst.out")"
	assert_eq "nothing changed" "$_s" "$(snap)"
}

test_native_gui_is_part_of_the_default_install_under_applications() {
	_nat_setup
	inst --yes || fail "default install failed"
	[ -f "$RT/usr/share/oui/menu.d/tsem.json" ] || fail "native menu entry missing in the default install"
	[ -f "$RT/www/views/gl-sdk4-ui-tsem.common.js.gz" ] || fail "native view missing in the default install"
	[ -f "$RT/usr/lib/oui-httpd/rpc/tsem" ] || fail "native rpc bridge missing in the default install"
	assert_contains parent '"parent": "applications"' "$(cat "$RT/usr/share/oui/menu.d/tsem.json")"
	[ -f "$RT/www/luci-static/resources/view/tsem/status.js" ] || fail "LuCI stays part of the default install"
}

test_default_install_skips_native_gui_with_a_reason_where_the_firmware_layout_is_missing() {
	_nat_setup
	rm -rf "$RT/usr/lib/oui-httpd"
	inst --yes || fail "the default install must still succeed without the GL.iNet UI layout"
	assert_contains why "native-gui skipped" "$(cat "$T/inst.out")"
	[ ! -e "$RT/usr/share/oui/menu.d/tsem.json" ] || fail "no menu entry may be added when the layout is missing"
	[ -f "$RT/usr/libexec/rpcd/tsem" ] && [ -f "$RT/www/luci-static/resources/view/tsem/status.js" ] || fail "api and LuCI must be installed anyway"
}

test_no_native_gui_opts_out_of_the_default() {
	_nat_setup
	inst --yes --no-native-gui || fail "install with --no-native-gui failed"
	[ ! -e "$RT/usr/share/oui/menu.d/tsem.json" ] || fail "--no-native-gui must not add the menu entry"
	[ -f "$RT/usr/libexec/rpcd/tsem" ] || fail "api must still be installed"
}

test_native_gui_refuses_when_firmware_prerequisites_are_missing() {
	_nat_setup
	rm -rf "$RT/usr/lib/oui-httpd"; _s=$(snap)
	if inst --yes --accept-undocumented-native-gui --components $_NATIVE; then fail "must refuse without the rpc directory"; fi
	assert_contains dir "MISSING for native-gui: /usr/lib/oui-httpd/rpc" "$(cat "$T/inst.out")"
	assert_eq "nothing changed" "$_s" "$(snap)"
	mkdir -p "$RT/usr/lib/oui-httpd/rpc"; rm -f "$RT/usr/share/oui/menu.d/tailscale.json" "$RT/usr/share/oui/menu.d/zerotier.json"; _s=$(snap)
	if inst --yes --accept-undocumented-native-gui --components $_NATIVE; then fail "must refuse without a Tailscale entry and without any APPLICATIONS sibling"; fi
	assert_contains ref "no menu entry for Tailscale and no entry under parent" "$(cat "$T/inst.out")"
	assert_eq "nothing changed" "$_s" "$(snap)"
	# the LuCI fallback still installs on such a firmware
	inst --yes --components core,api,luci-gui || fail "LuCI fallback must not depend on the native prerequisites"
}

test_native_gui_does_not_take_over_a_foreign_file() {
	_nat_setup
	printf 'foreign\n' >"$RT/usr/share/oui/menu.d/tsem.json"; _s=$(snap)
	if inst --yes --accept-undocumented-native-gui --components $_NATIVE; then fail "must not replace a foreign file"; fi
	assert_contains clash "CLASH: /usr/share/oui/menu.d/tsem.json" "$(cat "$T/inst.out")"
	assert_eq "nothing changed" "$_s" "$(snap)"
}

test_native_gui_install_is_additive_positioned_below_tailscale_and_reversible() {
	_nat_setup; _fw=$(_fw_sum); _orig=$(_files)
	inst --yes --accept-undocumented-native-gui --components $_NATIVE || fail "install failed: $(cat "$T/inst.out")"
	assert_eq "firmware files untouched" "$_fw" "$(_fw_sum)"
	python3 - "$RT/usr/share/oui/menu.d/tsem.json" <<'PY' || fail "generated menu entry is wrong"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["view"] == "tsem" and m["title"] == "Tailscale Exit Manager", m
assert m["index"] == 32, m                      # tailscale 31 + 1
assert m["parent"] == "applications" and m["parent_icon"] == "application" and m["parent_index"] == 50 and m["show_mode"] == ["router"], m
assert m["level"] == 2, m
PY
	gzip -dc "$RT/www/views/gl-sdk4-ui-tsem.common.js.gz" | cmp - "$ROOT/src/www/views/gl-sdk4-ui-tsem.common.js" || fail "gz copy differs from the view"
	cmp "$ROOT/src/usr/lib/oui-httpd/rpc/tsem" "$RT/usr/lib/oui-httpd/rpc/tsem" || fail "bridge not installed"
	[ ! -e "$RT/www/luci-static/resources/view/tsem/status.js" ] || fail "luci-gui installed without being asked"
	grep -q '^C|native-gui$' "$RT/etc/tsem/install.manifest" || fail "component not recorded"
	# repeated install: nothing changes
	_a=$(_files)
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes --accept-undocumented-native-gui --components $_NATIVE || fail "repeat failed"
	assert_eq "idempotent" "$_a" "$(_files)"
	# explicit index
	TSEM_BACKEND=mock uninst --yes --purge || fail "uninstall failed: $(cat "$T/uninst.out")"
	assert_eq "firmware files untouched after uninstall" "$_fw" "$(_fw_sum)"
	for f in usr/share/oui/menu.d/tsem.json www/views/gl-sdk4-ui-tsem.common.js www/views/gl-sdk4-ui-tsem.common.js.gz usr/lib/oui-httpd/rpc/tsem; do
		[ ! -e "$RT/$f" ] || fail "left behind: /$f"
	done
	assert_eq "state after uninstall" "$_orig" "$(_files | grep -v -E 'tsem|rpcd|www/luci')"
}

test_native_gui_failed_install_rolls_back_completely() {
	_nat_setup; inst --yes --components core || fail "core failed"
	_before=$(_files); _fw=$(_fw_sum)
	for n in 2 4 6; do
		TSEM_INSTALL_STAMP=20260101-00001$n TSEM_INSTALL_FAIL_AFTER=$n inst --yes --accept-undocumented-native-gui --components api,native-gui && fail "simulated failure after $n was not a failure"
		assert_eq "state after failure $n" "$_before" "$(_files)"
		assert_eq "firmware after failure $n" "$_fw" "$(_fw_sum)"
	done
	TSEM_INSTALL_STAMP=20260101-000020 inst --yes --accept-undocumented-native-gui --components api,native-gui || fail "install failed"
	TSEM_INSTALL_STAMP=20260101-000020 inst --rollback --yes || fail "rollback failed"
	assert_eq "state after rollback" "$_before" "$(_files)"
}

test_native_gui_explicit_index_and_reference_are_honoured() {
	_nat_setup
	inst --yes --accept-undocumented-native-gui --native-index 77 --components $_NATIVE || fail "install failed: $(cat "$T/inst.out")"
	assert_contains idx '"index": 77' "$(cat "$RT/usr/share/oui/menu.d/tsem.json")"
}

test_home_assistant_is_not_an_installer_component() {
	_nat_setup
	if inst --yes --components home-assistant; then fail "home-assistant must not be installable here"; fi
	assert_contains why "separate module" "$(cat "$T/inst.out")"
}

test_bridge_whitelist_matches_the_api_plugin() {
	python3 - "$ROOT" <<'PY' || fail "RPC bridge and API plugin disagree"
import re, subprocess, sys, json
root = sys.argv[1]
lua = open(root + "/src/usr/lib/oui-httpd/rpc/tsem").read()
spec = lua[lua.index("local SPEC = {"):lua.index("local function fail")]
names = set(re.findall(r"\b([a-z_]+) = \{", spec)) - {"SPEC"}
names |= set(re.findall(r"([a-z_]+) = \{\}", spec))
plugin = json.loads(subprocess.check_output(["sh", root + "/src/usr/libexec/rpcd/tsem", "list"]))
assert names == set(plugin), (names ^ set(plugin))
# parameters the bridge lets through must be exactly those the plugin documents (source is set by the bridge)
for m, params in plugin.items():
    block = re.search(r"\b" + m + r" = \{([^}]*)\}", spec).group(1)
    got = set(re.findall(r"([a-z0-9_]+) = \"", block))
    assert got == set(params) - {"source"}, (m, got, params)
assert 'out.source = "gui"' in lua, "the bridge must force source=gui"
assert "io.popen" in lua and "os.execute" not in lua
PY
}

_lua_bin() { for _b in lua lua5.4 lua5.3 lua5.2 lua5.1 luajit texlua; do command -v "$_b" >/dev/null 2>&1 && { echo "$_b"; return 0; }; done; return 1; }

test_bridge_lua_is_executed_when_a_lua_interpreter_exists() {
	_LB=$(_lua_bin) || need_skip "no Lua interpreter (lua, lua5.x, luajit, texlua): the RPC bridge cannot be executed"
	# the REAL bridge file runs against the REAL rpcd plugin and the mock controller (cjson = test stand-in)
	. "$ROOT/tests/t_api.sh"; _api_setup
	_o=$("$_LB" "$ROOT/tests/lua/bridge_test.lua" "$ROOT/src/usr/lib/oui-httpd/rpc/tsem" "$ROOT/src/usr/libexec/rpcd/tsem" 2>&1) || fail "Lua bridge test failed ($_LB): $_o"
	assert_contains passed "all checks passed" "$_o"
}

test_native_view_bundle_is_in_sync_and_honours_the_eval_contract() {
	command -v node >/dev/null 2>&1 || need_skip "node is not installed"
	node "$ROOT/tools/build-native-view.js" --check || fail "bundle drifted from tsem/logic.js + native/tsem-view.js"
	_nat_export() { export ROOT SH P1 P2; }
	_api_setup 2>/dev/null || { . "$ROOT/tests/t_api.sh"; _api_setup; }
	_nat_export
	node "$ROOT/tests/gui/native_test.js" || fail "native view test failed"
}

test_native_gui_without_a_tailscale_entry_uses_a_real_applications_sibling_and_goes_to_the_end() {
	_nat_setup
	# firmware where no entry says "tailscale" (as reported for 4.11.0): fields come from a real sibling, never invented
	rm -f "$RT/usr/share/oui/menu.d/tailscale.json"
	printf '{"index": 40, "view": "adguard", "title": "AdGuard Home", "level": 2, "parent": "applications", "parent_icon": "application", "parent_index": 50, "show_mode": ["router"]}\n' >"$RT/usr/share/oui/menu.d/adguard.json"
	inst --yes --accept-undocumented-native-gui --components $_NATIVE || fail "fallback install failed: $(cat "$T/inst.out")"
	assert_contains note "no Tailscale entry found" "$(cat "$T/inst.out")"
	python3 - "$RT/usr/share/oui/menu.d/tsem.json" <<'PY' || fail "generated entry wrong"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["parent"] == "applications" and m["parent_icon"] == "application" and m["parent_index"] == 50, m
assert m["level"] == 2 and m["show_mode"] == ["router"] and m["view"] == "tsem", m
assert m["index"] == 41, m   # highest sibling (40) + 1: end of the group
PY
	# the explicit override still wins
	uninst --yes >/dev/null 2>&1
}

test_native_reference_is_found_by_title_when_the_view_key_differs() {
	_nat_setup
	printf '{\n\t"index": 31,\n\t"view": "gl-sdk4-ui-tailscale",\n\t"title": "Tailscale",\n\t"level": 2,\n\t"parent": "applications"\n}\n' >"$RT/usr/share/oui/menu.d/tailscale.json"
	inst --yes --accept-undocumented-native-gui --components $_NATIVE || fail "install failed: $(cat "$T/inst.out")"
	grep -q '"index": 32' "$RT/usr/share/oui/menu.d/tsem.json" || fail "not placed directly below the Tailscale entry: $(cat "$RT/usr/share/oui/menu.d/tsem.json")"
}
