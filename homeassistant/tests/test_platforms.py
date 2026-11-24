"""Platform code of the integration against a MINIMAL stand-in for Home Assistant (no real HA is installed here).

This proves imports, entity logic, config-flow error mapping and diagnostics redaction. It does NOT prove that the
integration loads in a real Home Assistant: that stays UNVERIFIED until it is installed there.
"""
import asyncio
import importlib
import json
import os
import sys
import types
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_ubus  # noqa: E402


def mod(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    sys.modules[name] = m
    parent, _, child = name.rpartition(".")
    if parent:
        setattr(sys.modules[parent], child, m)
    return m


def install_stub():
    mod("homeassistant")
    mod("homeassistant.components")

    class ConfigFlow:
        def __init_subclass__(cls, domain=None, **kw):
            cls.domain = domain

        def async_show_form(self, **kw):
            return {"type": "form", **kw}

        def async_create_entry(self, **kw):
            return {"type": "create_entry", **kw}

        async def async_set_unique_id(self, u):
            self.uid = u

        def _abort_if_unique_id_configured(self):
            pass

    class OptionsFlow:
        pass

    mod("homeassistant.config_entries", ConfigEntry=object, ConfigFlow=ConfigFlow, OptionsFlow=OptionsFlow)
    mod("homeassistant.const", CONF_HOST="host", CONF_PASSWORD="password", CONF_PORT="port", CONF_USERNAME="username")
    mod("homeassistant.core", HomeAssistant=object, callback=lambda f: f)

    class HomeAssistantError(Exception):
        pass

    class ConfigEntryAuthFailed(Exception):
        pass

    mod("homeassistant.exceptions", HomeAssistantError=HomeAssistantError, ConfigEntryAuthFailed=ConfigEntryAuthFailed)
    mod("homeassistant.helpers")

    class UpdateFailed(Exception):
        pass

    class DataUpdateCoordinator:
        def __init__(self, hass, logger, name=None, update_interval=None):
            self.hass, self.name, self.update_interval = hass, name, update_interval
            self.data = None
            self.last_update_success = True
            self.last_exception = None

        async def async_refresh(self):
            try:
                self.data = await self._async_update_data()
                self.last_update_success, self.last_exception = True, None
            except Exception as err:  # noqa: BLE001
                self.last_update_success, self.last_exception = False, err

        async def async_request_refresh(self):
            await self.async_refresh()

        def async_set_updated_data(self, data):
            self.data, self.last_update_success = data, True

        def async_update_listeners(self):
            pass

    class CoordinatorEntity:
        def __init__(self, coordinator):
            self.coordinator = coordinator

        @property
        def available(self):
            return self.coordinator.last_update_success

    mod("homeassistant.helpers.update_coordinator", DataUpdateCoordinator=DataUpdateCoordinator, UpdateFailed=UpdateFailed,
        CoordinatorEntity=CoordinatorEntity)
    mod("homeassistant.helpers.device_registry", DeviceInfo=dict)
    mod("homeassistant.helpers.aiohttp_client", async_get_clientsession=lambda *a, **k: None)
    mod("homeassistant.components.switch", SwitchEntity=object)
    mod("homeassistant.components.sensor", SensorEntity=object)

    class BSDC:
        PROBLEM = "problem"
        CONNECTIVITY = "connectivity"

    mod("homeassistant.components.binary_sensor", BinarySensorEntity=object, BinarySensorDeviceClass=BSDC)

    def redact(data, keys):
        return {k: ("**REDACTED**" if k in keys else v) for k, v in data.items()}

    mod("homeassistant.components.diagnostics", async_redact_data=redact)
    mod("aiohttp", ClientError=Exception, ClientTimeout=lambda total=None: total)

    class _Schema:
        def __init__(self, s):
            self.schema = s

    mod("voluptuous", Schema=_Schema, Required=lambda k, default=None: k, Optional=lambda k, default=None: k,
        All=lambda *a: a, Range=lambda **k: k)


install_stub()
# the package under test, imported as a real package (its __init__ runs against the stub)
sys.path.insert(0, os.path.join(HERE, ".."))
pkg = importlib.import_module("custom_components.tsem")
api = importlib.import_module("custom_components.tsem.api")
coord_m = importlib.import_module("custom_components.tsem.coordinator")
switch_m = importlib.import_module("custom_components.tsem.switch")
sensor_m = importlib.import_module("custom_components.tsem.sensor")
binary_m = importlib.import_module("custom_components.tsem.binary_sensor")
flow_m = importlib.import_module("custom_components.tsem.config_flow")
diag_m = importlib.import_module("custom_components.tsem.diagnostics")
const = importlib.import_module("custom_components.tsem.const")
HAError = sys.modules["homeassistant.exceptions"].HomeAssistantError
AuthFailed = sys.modules["homeassistant.exceptions"].ConfigEntryAuthFailed


async def post_json(url, payload, timeout):
    def _do():
        req = urllib.request.Request(url, json.dumps(payload).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    return await asyncio.get_running_loop().run_in_executor(None, _do)


class Entry:
    entry_id = "e1"
    options = {}

    def __init__(self, port):
        self.data = {"host": "127.0.0.1", "username": "admin", "password": "pw", "port": port, "ssl": False}


class PlatformTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        import shutil
        for k in ("TSEM_STATE_DIR", "TSEM_RUN_DIR", "TSEM_MOCK_DIR"):
            shutil.rmtree(os.environ[k], ignore_errors=True)
            os.makedirs(os.environ[k])
        self.router = fake_ubus.FakeRouter({"admin": ("pw", "tsem-write")})
        self.entry = Entry(self.router.port)
        self.client = api.TsemClient(post_json, "127.0.0.1", "admin", "pw", port=self.router.port, timeout=15)
        import asyncio
        hass_stub = types.SimpleNamespace(async_create_task=lambda coro: asyncio.ensure_future(coro))
        self.coord = coord_m.TsemCoordinator(hass_stub, self.entry, self.client)
        self.hass = types.SimpleNamespace(data={const.DOMAIN: {"e1": self.coord}})

    def tearDown(self):
        self.router.stop()

    async def entities(self):
        out = []
        for m in (switch_m, sensor_m, binary_m):
            await m.async_setup_entry(self.hass, self.entry, out.extend)
        return {e._key: e for e in out}

    async def test_mode_switch_and_sensors_follow_the_controller(self):
        await self.coord.async_refresh()
        ents = await self.entities()
        sw = ents["mode_switch"]
        self.assertIsNone(sw.is_on)  # no saved mode: unknown, not "off"
        await sw.async_turn_on()
        self.assertTrue(sw.is_on)
        self.assertEqual(self.coord.data["status"]["source"], "ha")
        # desired GERMAN, but the controller has not proven an exit node yet in this instant -> reached is reported as it is
        reached = ents["mode_reached"].is_on
        self.assertEqual(reached, self.coord.data["derived"]["reached"])
        if not reached:
            self.assertIsNone(ents["active_exit_node"].native_value)
        self.assertEqual(ents["mode"].native_value, "german")
        self.assertTrue(ents["kill_switch"].is_on)
        self.assertFalse(ents["leak_risk"].is_on)
        await sw.async_turn_off()  # explicit DIRECT
        self.assertFalse(sw.is_on)
        self.assertEqual(self.coord.data["status"]["guard"], "open")
        self.assertFalse(ents["kill_switch"].is_on)
        self.assertEqual(ents["failover_status"].native_value, "inactive")
        self.assertEqual(sw.extra_state_attributes["reached"], True)

    async def test_failed_change_raises_and_keeps_state(self):
        await self.coord.async_refresh()
        ents = await self.entities()
        self.client._password = "wrong"
        self.client._sid = None
        with self.assertRaises(HAError):
            await ents["mode_switch"].async_turn_on()
        self.assertIsNone(ents["mode_switch"].is_on)

    async def test_connection_sensor_reports_loss_while_others_become_unavailable(self):
        await self.coord.async_refresh()
        ents = await self.entities()
        self.assertTrue(ents["connection"].is_on)
        self.router.stop()
        await self.coord.async_refresh()
        self.assertFalse(self.coord.last_update_success)
        self.assertFalse(ents["connection"].is_on)
        self.assertTrue(ents["connection"].available)
        self.assertIn("error", ents["connection"].extra_state_attributes)
        self.assertFalse(ents["mode"].available)  # no stale value pretends to be current
        self.router = fake_ubus.FakeRouter({})

    WRITE_METHODS = ("set_mode", "set_failover", "failover_now", "config_set")

    def _writes(self, *routers):
        return [m for r in (routers or (self.router,)) for (o, m) in r.requests if o == "tsem" and m in self.WRITE_METHODS]

    async def test_lost_connection_and_reconnect_never_send_a_change_and_never_open_the_kill_switch(self):
        # Fail-safe: a missing connection must never turn into DIRECT. HA only ever sends a change when a user/automation
        # actions the switch; polling, losing the router and reconnecting issue reads only.
        await self.coord.async_refresh()
        ents = await self.entities()
        await ents["mode_switch"].async_turn_on()
        self.assertEqual(self.coord.data["status"]["mode"], "german")
        old = self.router
        before = len(self._writes(old))
        old.stop()
        for _ in range(3):  # router gone (reboot / Wi-Fi outage): every poll fails
            await self.coord.async_refresh()
        self.assertFalse(self.coord.last_update_success)
        self.assertFalse(ents["mode_switch"].available)
        self.assertFalse(ents["connection"].is_on)
        # router (and HA) come back: a fresh endpoint with a fresh session, the controller state is on "the router"
        self.router = fake_ubus.FakeRouter({"admin": ("pw", "tsem-write")})
        self.client._url = f"http://127.0.0.1:{self.router.port}/ubus"
        self.client._sid = None
        await self.coord.async_refresh()
        self.assertTrue(self.coord.last_update_success)
        self.assertTrue(ents["connection"].is_on)
        self.assertEqual(self.coord.data["status"]["mode"], "german")
        self.assertNotEqual(self.coord.data["status"].get("guard"), "open")
        self.assertTrue(ents["kill_switch"].is_on)
        self.assertEqual(self._writes(), [], "reconnect must issue reads only")
        self.assertEqual(len(self._writes(old)), before, "no change request was sent while the router was unreachable")

    async def test_setup_with_unreachable_router_sends_nothing_and_fails_cleanly(self):
        self.router.stop()
        with self.assertRaises(Exception):
            await self.coord._async_update_data()
        self.assertEqual(self._writes(), [])
        self.router = fake_ubus.FakeRouter({})

    async def test_auth_failure_triggers_reauth(self):
        self.client._password = "wrong"
        with self.assertRaises(AuthFailed):
            await self.coord._async_update_data()

    async def test_config_flow_maps_errors(self):
        pkg_flow = flow_m.TsemConfigFlow()
        pkg_flow.hass = object()
        orig = flow_m.make_post
        flow_m.make_post = lambda hass, verify_ssl=False: post_json
        try:
            good = {"host": "127.0.0.1", "username": "admin", "password": "pw", "port": self.router.port}
            r = await pkg_flow.async_step_user(good)
            self.assertEqual(r["type"], "create_entry")
            f2 = flow_m.TsemConfigFlow()
            f2.hass = object()
            r = await f2.async_step_user({**good, "password": "bad"})
            self.assertEqual(r["errors"], {"base": "invalid_auth"})
            f3 = flow_m.TsemConfigFlow()
            f3.hass = object()
            r = await f3.async_step_user({**good, "port": 1})
            self.assertEqual(r["errors"], {"base": "cannot_connect"})
        finally:
            flow_m.make_post = orig

    async def test_diagnostics_redacts_credentials_and_collects_router_side_data(self):
        await self.coord.async_refresh()
        d = await diag_m.async_get_config_entry_diagnostics(self.hass, self.entry)
        self.assertEqual(d["entry"]["password"], "**REDACTED**")
        self.assertEqual(d["entry"]["username"], "**REDACTED**")
        self.assertNotIn("pw", json.dumps(d["entry"]))
        self.assertIn("state", d["status"])
        self.assertIsInstance(d["events"], list)
        self.assertIsInstance(d["diag"], list)

    def test_packaging_files(self):
        base = os.path.join(HERE, "..", "custom_components", "tsem")
        with open(os.path.join(base, "manifest.json")) as fh:
            m = json.load(fh)
        self.assertEqual(m["domain"], "tsem")
        self.assertTrue(m["config_flow"])
        self.assertEqual(m["requirements"], [])  # no extra Python packages, no MQTT
        self.assertNotIn("mqtt", json.dumps(m).lower())
        for f in ("strings.json", "translations/en.json", "translations/de.json"):
            with open(os.path.join(base, f)) as fh:
                json.load(fh)


if __name__ == "__main__":
    unittest.main()
