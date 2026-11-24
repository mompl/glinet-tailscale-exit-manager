# shellcheck shell=sh
# GUI (LuCI view) against the real API plugin and controller (mock backend). Needs node; otherwise SKIPPED, never "passed".

test_gui_view_end_to_end_against_api_and_controller() {
	command -v node >/dev/null 2>&1 || need_skip "node is not installed"
	_api_setup 2>/dev/null || { . "$ROOT/tests/t_api.sh"; _api_setup; }
	export ROOT SH P1 P2
	node "$ROOT/tests/gui/gui_test.js" || fail "GUI test failed"
	node "$ROOT/tests/gui/label_test.js" || fail "mode label test failed"
}

test_gui_files_are_wellformed() {
	python3 - "$ROOT" <<'PY' || fail "GUI packaging files malformed"
import json, sys
root = sys.argv[1]
m = json.load(open(root + "/src/usr/share/luci/menu.d/luci-app-tsem.json"))
e = m["admin/services/tsem"]
assert e["action"] == {"type": "view", "path": "tsem/status"}
assert e["depends"]["acl"] == ["tsem-read"]
import os
assert os.path.isfile(root + "/src/www/luci-static/resources/view/tsem/status.js")
PY
}
