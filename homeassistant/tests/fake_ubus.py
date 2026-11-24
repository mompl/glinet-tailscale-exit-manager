"""A fake router web endpoint (/ubus JSON-RPC) in front of the REAL rpcd plugin and controller.

It imitates what rpcd does that matters here: session login, "access denied" for missing/expired sessions, and the
per-user ACL taken from the REAL src/usr/share/rpcd/acl.d/tsem.json. It is a software stand-in for rpcd, not rpcd.
"""
import json
import os
import secrets
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ["ROOT"]
PLUGIN = os.path.join(ROOT, "src/usr/libexec/rpcd/tsem")
ACL = json.load(open(os.path.join(ROOT, "src/usr/share/rpcd/acl.d/tsem.json")))


class FakeRouter:
    def __init__(self, users):
        self.users = users  # name -> (password, acl group)
        self.sessions = {}  # sid -> group
        self.requests = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                out = outer.handle(body)
                data = json.dumps(out, separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def expire_sessions(self):
        self.sessions.clear()

    def allowed(self, group, method):
        g = ACL.get(group, {})
        for kind in ("read", "write"):
            if method in g.get(kind, {}).get("ubus", {}).get("tsem", []):
                return True
        return False

    def handle(self, req):
        rid = req.get("id")
        sid, obj, method, args = req["params"]
        self.requests.append((obj, method))
        if obj == "session" and method == "login":
            u = self.users.get(args.get("username"))
            if not u or u[0] != args.get("password"):
                return {"jsonrpc": "2.0", "id": rid, "result": [6]}
            new = secrets.token_hex(16)
            self.sessions[new] = u[1]
            return {"jsonrpc": "2.0", "id": rid, "result": [0, {"ubus_rpc_session": new}]}
        group = self.sessions.get(sid)
        if group is None:
            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32002, "message": "Access denied"}}
        if obj != "tsem" or not self.allowed(group, method):
            return {"jsonrpc": "2.0", "id": rid, "result": [6]}
        p = subprocess.run(["sh", PLUGIN, "call", method], input=json.dumps(args), capture_output=True, text=True)
        return {"jsonrpc": "2.0", "id": rid, "result": [0, json.loads(p.stdout)]}
