"""Serves, on one local port: /ubus (FakeRouter in front of the REAL plugin + controller), the GUI static file, a
LuCI marker, and a minimal Home Assistant REST API (/api/states/<entity>) that reflects the real controller's mode.
Prints the port, then runs until stdin closes. Used only by tests/t_mac_checks.sh (software test, not a router)."""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_ubus  # noqa: E402

ROOT = os.environ["ROOT"]
TOKEN = "test-token"
router = fake_ubus.FakeRouter({"admin": ("pw", "tsem-write")})
LUCI = os.environ.get("FAKE_LUCI", "1") == "1"
GUI = os.environ.get("FAKE_GUI", "1") == "1"
HA_BAD = os.environ.get("FAKE_HA_BAD", "0") == "1"


def tsem(*a):
    return subprocess.run(["sh", os.path.join(ROOT, "src/usr/sbin/tsem"), *a], capture_output=True, text=True).stdout


def ha_state(entity):
    st = dict(l.split("=", 1) for l in tsem("status").splitlines() if "=" in l)
    mode = st.get("mode", "none")
    if HA_BAD:
        mode = "direct" if mode == "german" else "german"
    vals = {
        "switch.tailscale_exit_manager_exit_node_mode": "on" if mode == "german" else "off",
        "sensor.tailscale_exit_manager_operating_mode": mode,
        "sensor.tailscale_exit_manager_active_exit_node": st.get("active_exit", "none"),
        "sensor.tailscale_exit_manager_failover_status": "armed",
        "binary_sensor.tailscale_exit_manager_kill_switch_active": st.get("kill_switch_active", "false") == "true" and "on" or "off",
        "binary_sensor.tailscale_exit_manager_controller_connection": "on",
    }
    return vals.get(entity)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/ubus":
            return self._send(404, "{}")
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self._send(200, json.dumps(router.handle(body), separators=(",", ":")))

    def do_GET(self):
        if self.path == "/luci-static/resources/view/tsem/status.js":
            if not GUI:
                return self._send(404, "not found", "text/plain")
            return self._send(200, open(os.path.join(ROOT, "src/www/luci-static/resources/view/tsem/status.js"), "rb").read(), "application/javascript")
        if self.path == "/luci-static/resources/luci.js":
            return self._send(200 if LUCI else 404, "luci" if LUCI else "nf", "application/javascript")
        if self.path.startswith("/api/states/"):
            if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                return self._send(401, '{"message":"401: Unauthorized"}')
            ent = self.path.rsplit("/", 1)[1]
            v = ha_state(ent)
            if v is None:
                return self._send(404, '{"message":"Entity not found."}')
            return self._send(200, json.dumps({"entity_id": ent, "state": v, "attributes": {}}, indent=1))
        self._send(404, "{}")


httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(httpd.server_address[1], flush=True)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
sys.stdin.read()
