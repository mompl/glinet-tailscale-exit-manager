import asyncio
import json
import os
import sys
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import fake_ubus  # noqa: E402
import types  # noqa: E402

# api.py / model.py have no Home Assistant imports: load them without running the package __init__ (which needs HA)
_pkg = types.ModuleType("tsem_pkg")
_pkg.__path__ = [os.path.join(HERE, "..", "custom_components", "tsem")]
sys.modules["tsem_pkg"] = _pkg
import importlib  # noqa: E402

api = importlib.import_module("tsem_pkg.api")
model = importlib.import_module("tsem_pkg.model")


async def post_json(url, payload, timeout):
    def _do():
        req = urllib.request.Request(url, json.dumps(payload).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    return await asyncio.get_running_loop().run_in_executor(None, _do)


def ctl(*a):
    import subprocess
    return subprocess.run(["sh", os.path.join(os.environ["ROOT"], "src/usr/sbin/tsem"), *a], capture_output=True, text=True)


class ClientTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        import shutil
        for k in ("TSEM_STATE_DIR", "TSEM_RUN_DIR", "TSEM_MOCK_DIR"):  # every test starts from a fresh controller
            shutil.rmtree(os.environ[k], ignore_errors=True)
            os.makedirs(os.environ[k])
        self.router = fake_ubus.FakeRouter({"admin": ("pw", "tsem-write"), "viewer": ("pw2", "tsem-read")})

    def tearDown(self):
        self.router.stop()

    def client(self, user="admin", pw="pw"):
        return api.TsemClient(post_json, "127.0.0.1", user, pw, port=self.router.port, timeout=15)

    async def test_wrong_password_is_an_auth_error(self):
        with self.assertRaises(api.TsemAuthError):
            await self.client(pw="nope").status()

    async def test_no_session_no_access(self):
        c = self.client()
        before = ctl("status").stdout
        reply = await c._raw([api.NULL_SESSION, "tsem", "status", {}])
        self.assertIn("error", reply)  # an unauthenticated call is refused by the router side
        reply = await c._raw([api.NULL_SESSION, "tsem", "set_mode", {"mode": "direct", "confirm": True}])
        self.assertIn("error", reply)
        self.assertEqual(ctl("status").stdout.count("mode=direct"), before.count("mode=direct"))
        self.assertNotIn("mode=direct", ctl("status").stdout)

    async def test_read_and_write_with_reached_state(self):
        c = self.client()
        st = await c.status()
        self.assertEqual(st["state"], "BLOCKED")
        reply = await c.set_mode("german")
        self.assertEqual(reply["requested"], "german")
        self.assertEqual(reply["status"]["source"], "ha")
        self.assertEqual(reply["status"]["mode"], "german")
        d = model.derive(reply["status"])
        self.assertEqual(d["desired_mode"], "german")
        self.assertIn(d["state"], ("PRIMARY_ACTIVE", "CONNECTING_PRIMARY", "BLOCKED"))
        if d["state"] != "PRIMARY_ACTIVE":
            self.assertFalse(d["reached"])
            self.assertIsNone(d["active_exit_node"])

    async def test_direct_needs_confirm_and_viewer_cannot_write(self):
        c = self.client()
        await c.set_mode("german")
        with self.assertRaises(api.TsemApiError) as cm:
            await c.set_mode("direct", confirm=False)
        self.assertEqual(cm.exception.code, "confirmation_required")
        self.assertEqual((await c.status())["mode"], "german")
        v = self.client("viewer", "pw2")
        self.assertEqual((await v.status())["mode"], "german")  # reading is allowed
        with self.assertRaises(api.TsemAuthError):
            await v.set_mode("direct", confirm=True)
        with self.assertRaises(api.TsemAuthError):
            await v.config_set(primary="100.64.0.77")
        self.assertEqual((await c.status())["mode"], "german")  # nothing changed
        r = await c.set_mode("direct", confirm=True)
        self.assertEqual(r["status"]["mode"], "direct")
        self.assertEqual(r["status"]["guard"], "open")

    async def test_expired_session_relogs_in_transparently(self):
        c = self.client()
        await c.status()
        self.router.expire_sessions()
        st = await c.status()
        self.assertIn("state", st)
        self.assertGreaterEqual([m for o, m in self.router.requests].count("login"), 2)

    async def test_invalid_config_is_an_api_error(self):
        c = self.client()
        with self.assertRaises(api.TsemApiError):
            await c.config_set(primary="not-an-ip")
        cfg = await c.config_get()
        self.assertNotEqual(cfg["primary"], "not-an-ip")
        r = await c.config_set(auto_return=False)
        self.assertEqual(r["config"]["auto_return"], False)

    async def test_connection_error(self):
        c = self.client()
        self.router.stop()
        with self.assertRaises(api.TsemConnectionError):
            await c.status()
        self.router = fake_ubus.FakeRouter({})  # for tearDown

    async def test_events_diag_nodes(self):
        c = self.client()
        self.assertIsInstance(await c.events(), list)
        self.assertIsInstance(await c.diag(), list)
        self.assertIn("available", await c.nodes())


class ModelTest(unittest.TestCase):
    base = {"state": "BLOCKED", "mode": "german", "guard": "blocked", "kill_switch_active": True, "leak_risk": False,
            "secondary": "100.64.0.11", "failover": "auto", "active_exit": "none"}

    def d(self, **kw):
        return model.derive({**self.base, **kw})

    def test_states(self):
        self.assertTrue(self.d(state="PRIMARY_ACTIVE", active_exit="100.64.0.10")["reached"])
        self.assertEqual(self.d(state="PRIMARY_ACTIVE", active_exit="100.64.0.10")["failover_status"], "armed")
        s = self.d(state="SECONDARY_ACTIVE", active_exit="100.64.0.11")
        self.assertEqual((s["failover_status"], s["reached"], s["active_exit_node"]), ("failed_over", True, "100.64.0.11"))
        for st in ("CONNECTING_PRIMARY", "CONNECTING_SECONDARY", "DEGRADED", "BLOCKED"):
            self.assertFalse(self.d(state=st)["reached"], st)
        self.assertIsNone(self.d(state="BLOCKED", active_exit="100.64.0.10")["active_exit_node"])
        self.assertEqual(self.d(state="PRIMARY_ACTIVE", failover="off")["failover_status"], "off")
        self.assertEqual(self.d(state="BLOCKED")["failover_status"], "blocked")

    def test_direct_requires_open_guard(self):
        self.assertTrue(self.d(mode="direct", state="DISABLED", guard="open")["reached"])
        self.assertFalse(self.d(mode="direct", state="DISABLED", guard="blocked")["reached"])
        self.assertEqual(self.d(mode="direct", state="DISABLED", guard="open")["failover_status"], "inactive")


class ModelNameTest(unittest.TestCase):
    def test_active_exit_name_comes_from_the_controller_and_only_while_active(self):
        st = {"state": "PRIMARY_ACTIVE", "mode": "german", "guard": "blocked", "active_exit": "100.64.0.10",
              "active_exit_name": "exit-a", "primary_name": "exit-a", "secondary_name": "none"}
        d = model.derive(st)
        self.assertEqual((d["active_exit_node"], d["active_exit_name"]), ("100.64.0.10", "exit-a"))
        self.assertEqual((d["primary_name"], d["secondary_name"]), ("exit-a", None))
        self.assertIsNone(model.derive({**st, "state": "BLOCKED"})["active_exit_name"])
        # an older controller without the field: no name, the address stays
        old = {k: v for k, v in st.items() if "name" not in k}
        self.assertIsNone(model.derive(old)["active_exit_name"])
        self.assertEqual(model.derive(old)["active_exit_node"], "100.64.0.10")

    def test_node_list_and_active_rank_pass_through_and_older_controllers_give_an_empty_list(self):
        st = {"state": "SECONDARY_ACTIVE", "mode": "german", "guard": "german", "active_exit": "100.64.0.12", "active_rank": 3,
              "node_list": [{"rank": 1, "ip": "100.64.0.10", "name": "a", "ok": "fail", "probe": "unreachable"},
                            {"rank": 3, "ip": "100.64.0.12", "name": "", "ok": "ok", "probe": "egress"}, "junk"]}
        d = model.derive(st)
        self.assertEqual(d["active_rank"], 3)
        self.assertEqual([n["rank"] for n in d["node_list"]], [1, 3])
        self.assertIsNone(d["node_list"][1]["name"])
        old = {k: v for k, v in st.items() if k not in ("node_list", "active_rank")}
        self.assertEqual(model.derive(old)["node_list"], [])
        self.assertIsNone(model.derive(old)["active_rank"])


if __name__ == "__main__":
    unittest.main()
