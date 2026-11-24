"""The TSEM integration inside the REAL Home Assistant core (requirement D)."""
import os
import subprocess
from datetime import timedelta

import pytest
from homeassistant import config_entries
from homeassistant.const import CONF_HOST, CONF_PASSWORD, CONF_PORT, CONF_USERNAME
from homeassistant.data_entry_flow import FlowResultType
from homeassistant.exceptions import HomeAssistantError
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.tsem.const import DOMAIN

SWITCH = "switch.tailscale_exit_manager_exit_node_mode"
S_MODE = "sensor.tailscale_exit_manager_operating_mode"
S_STATE = "sensor.tailscale_exit_manager_controller_state"
S_EXIT = "sensor.tailscale_exit_manager_active_exit_node"
S_HW = "sensor.tailscale_exit_manager_hardware_switch"
S_PRIMARY = "sensor.tailscale_exit_manager_primary_check"
B_KILL = "binary_sensor.tailscale_exit_manager_kill_switch_active"
B_CONN = "binary_sensor.tailscale_exit_manager_controller_connection"


def run(env, *cmd):
    return subprocess.run(list(cmd), capture_output=True, text=True, env={**os.environ, **env})


def tsem(env, *args):
    return run(env, "sh", env["TSEM_BIN"], *args)


def status(env):
    out = tsem(env, "status").stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def data(router, pw="pw", user="admin"):
    return {CONF_HOST: "127.0.0.1", CONF_PORT: router.port, CONF_USERNAME: user, CONF_PASSWORD: pw}


async def setup_entry(hass, router, tsem_env, user="admin"):
    tsem(tsem_env, "set", "direct", "--no-wait")
    entry = MockConfigEntry(domain=DOMAIN, data=data(router, user=user), unique_id="127.0.0.1", title="TSEM")
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    return entry


async def test_config_flow_creates_the_entry_and_all_entities(hass, router, tsem_env):
    tsem(tsem_env, "set", "direct", "--no-wait")
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    assert result["type"] == FlowResultType.FORM
    result = await hass.config_entries.flow.async_configure(result["flow_id"], data(router))
    assert result["type"] == FlowResultType.CREATE_ENTRY
    await hass.async_block_till_done()
    for ent in (SWITCH, S_MODE, S_STATE, S_EXIT, S_HW, S_PRIMARY, B_KILL, B_CONN):
        assert hass.states.get(ent) is not None, ent + " was not created"
    assert hass.states.get(S_MODE).state == "direct"
    assert hass.states.get(SWITCH).state == "off"
    assert hass.states.get(B_CONN).state == "on"


async def test_config_flow_maps_errors_and_never_stores_a_wrong_password(hass, router, tsem_env):
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    bad = await hass.config_entries.flow.async_configure(result["flow_id"], data(router, pw="wrong"))
    assert bad["type"] == FlowResultType.FORM and bad["errors"] == {"base": "invalid_auth"}
    down = data(router)
    down[CONF_PORT] = 1  # nothing listens there
    r2 = await hass.config_entries.flow.async_configure(result["flow_id"], down)  # the same open flow: the user corrects the form
    assert r2["type"] == FlowResultType.FORM and r2["errors"] == {"base": "cannot_connect"}
    assert not hass.config_entries.async_entries(DOMAIN)
    ok = await hass.config_entries.flow.async_configure(result["flow_id"], data(router))
    assert ok["type"] == FlowResultType.CREATE_ENTRY


async def test_switch_changes_the_real_controller_and_shows_what_was_reached(hass, router, tsem_env):
    await setup_entry(hass, router, tsem_env)
    await hass.services.async_call("switch", "turn_on", {"entity_id": SWITCH}, blocking=True)
    await hass.async_block_till_done()
    st = status(tsem_env)
    assert st["mode"] == "german" and st["source"] == "ha"  # the controller records WHO asked
    assert hass.states.get(SWITCH).state == "on"
    assert hass.states.get(S_MODE).state == "german"
    assert hass.states.get(B_KILL).state == "on"
    await hass.services.async_call("switch", "turn_off", {"entity_id": SWITCH}, blocking=True)
    await hass.async_block_till_done()
    assert hass.states.get(S_MODE).state == "direct" and hass.states.get(B_KILL).state == "off"


async def test_changes_made_elsewhere_reach_home_assistant(hass, router, tsem_env):
    """CLI and the hardware switch hook change the mode behind HA's back; the next poll shows it."""
    entry = await setup_entry(hass, router, tsem_env)
    coordinator = hass.data[DOMAIN][entry.entry_id]
    tsem(tsem_env, "set", "german", "--no-wait", "--source", "cli")
    await coordinator.async_refresh()
    await hass.async_block_till_done()
    assert hass.states.get(S_MODE).state == "german" and hass.states.get(SWITCH).state == "on"
    hook = os.path.join(tsem_env["ROOT"], "contrib/tsem-switch.sh")
    run(tsem_env, "sh", hook, "off")
    await coordinator.async_refresh()
    await hass.async_block_till_done()
    assert hass.states.get(S_MODE).state == "direct"
    assert hass.states.get(S_HW).state == "off"  # the hook's event is visible as the hardware switch state


async def test_router_down_marks_entities_unavailable_but_keeps_the_connection_sensor(hass, router, tsem_env):
    entry = await setup_entry(hass, router, tsem_env)
    coordinator = hass.data[DOMAIN][entry.entry_id]
    router.stop()
    await coordinator.async_refresh()
    await hass.async_block_till_done()
    assert hass.states.get(B_CONN).state == "off"
    assert hass.states.get(SWITCH).state == "unavailable"
    assert hass.states.get(S_MODE).state == "unavailable"
    assert "error" in hass.states.get(B_CONN).attributes


async def test_reload_and_restart_recover_the_same_state(hass, router, tsem_env):
    entry = await setup_entry(hass, router, tsem_env)
    tsem(tsem_env, "set", "german", "--no-wait", "--source", "cli")
    assert await hass.config_entries.async_reload(entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get(S_MODE).state == "german" and hass.states.get(SWITCH).state == "on"
    assert await hass.config_entries.async_unload(entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "unavailable"
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get(SWITCH).state == "on"


async def test_polling_is_not_aggressive(hass, router, tsem_env):
    entry = await setup_entry(hass, router, tsem_env)
    assert hass.data[DOMAIN][entry.entry_id].update_interval == timedelta(seconds=15)


async def test_a_read_only_router_user_can_read_but_the_switch_refuses_to_change(hass, router, tsem_env):
    await setup_entry(hass, router, tsem_env, user="reader")
    assert hass.states.get(S_MODE).state == "direct"
    with pytest.raises(HomeAssistantError):
        await hass.services.async_call("switch", "turn_on", {"entity_id": SWITCH}, blocking=True)
    assert status(tsem_env)["mode"] == "direct"


# ------------------------------------------------------------------------------------------------ alert blueprint
BLUEPRINT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "blueprints", "automation", "tsem", "exit_node_alerts.yaml")
B_LEAK = "binary_sensor.tailscale_exit_manager_leak_risk"


def tick(env, n):
    for _ in range(n):
        tsem(env, "tick")
        env["TSEM_NOW"] = str(int(env["TSEM_NOW"]) + 5)


def peers(env):
    with open(os.path.join(env["TSEM_MOCK_DIR"], "peers"), "w") as f:
        f.write(f"alpha|{env['TSEM_PRIMARY']}|true|true|alpha\nbeta|{env['TSEM_SECONDARY']}|true|true|beta\n")


def node_down(env, ip, down=True):
    d = os.path.join(env["TSEM_MOCK_DIR"], "down")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, ip)
    if down:
        open(p, "w").close()
    elif os.path.exists(p):
        os.remove(p)


async def install_blueprint(hass, allow_direct=True):
    import shutil
    from homeassistant.setup import async_setup_component
    from pytest_homeassistant_custom_component.common import async_mock_service
    dst = hass.config.path("blueprints/automation/tsem")
    os.makedirs(dst, exist_ok=True)
    shutil.copy(BLUEPRINT, os.path.join(dst, "exit_node_alerts.yaml"))
    calls = async_mock_service(hass, "notify", "mobile_app_test")
    assert await async_setup_component(hass, "automation", {"automation": {"use_blueprint": {
        "path": "tsem/exit_node_alerts.yaml",
        "input": {"notify_service": "notify.mobile_app_test", "state_sensor": S_STATE, "connection": B_CONN, "leak_risk": B_LEAK,
                  "mode_switch": SWITCH, "down_delay": {"minutes": 2}, "urgency": "time-sensitive", "allow_direct_button": allow_direct}}}})
    await hass.async_block_till_done()
    return calls


async def refresh(hass, coordinator):
    await coordinator.async_refresh()
    await hass.async_block_till_done()


def titles(calls):
    return [c.data.get("title") or c.data.get("message") for c in calls]


async def test_blueprint_alerts_on_failover_blocked_and_recovery_and_buttons_confirm_what_was_reached(hass, router, tsem_env):
    entry = await setup_entry(hass, router, tsem_env)
    coordinator = hass.data[DOMAIN][entry.entry_id]
    calls = await install_blueprint(hass)
    peers(tsem_env)
    tsem(tsem_env, "set", "german", "--no-wait", "--source", "cli")
    tick(tsem_env, 8)
    await refresh(hass, coordinator)
    assert hass.states.get(S_STATE).state == "PRIMARY_ACTIVE", hass.states.get(S_STATE).state
    assert any("Mode changed" in (t or "") for t in titles(calls)), titles(calls)  # CLI change is announced

    # the primary exit node fails: failover, the user is told
    node_down(tsem_env, tsem_env["TSEM_PRIMARY"])
    tick(tsem_env, 12)
    await refresh(hass, coordinator)
    assert hass.states.get(S_STATE).state == "SECONDARY_ACTIVE", hass.states.get(S_STATE).state
    assert any("using the backup" in (t or "") for t in titles(calls)), titles(calls)

    # both fail: BLOCKED, with the decision buttons
    node_down(tsem_env, tsem_env["TSEM_SECONDARY"])
    tick(tsem_env, 12)
    await refresh(hass, coordinator)
    assert hass.states.get(S_STATE).state == "BLOCKED", hass.states.get(S_STATE).state
    blocked = [c for c in calls if "BLOCKED" in (c.data.get("title") or "")]
    assert blocked, titles(calls)
    actions = [a["action"] for a in blocked[-1].data["data"]["actions"]]
    assert actions == ["TSEM_KEEP", "TSEM_GO_DIRECT"], actions
    assert blocked[-1].data["data"]["push"]["interruption-level"] == "critical"

    # tap "Go DIRECT": the controller really switches and the confirmation says what was reached
    n = len(calls)
    hass.bus.async_fire("mobile_app_notification_action", {"action": "TSEM_GO_DIRECT"})
    await hass.async_block_till_done()
    await refresh(hass, coordinator)
    assert status(tsem_env)["mode"] == "direct" and status(tsem_env)["source"] == "ha"
    assert hass.states.get(S_STATE).state == "DISABLED"
    assert any("DIRECT is active" in (t or "") for t in titles(calls[n:])), titles(calls[n:])

    # the exit nodes come back; "Back to exit node" restores the protected mode and the primary returns
    node_down(tsem_env, tsem_env["TSEM_PRIMARY"], False)
    node_down(tsem_env, tsem_env["TSEM_SECONDARY"], False)
    hass.bus.async_fire("mobile_app_notification_action", {"action": "TSEM_GO_EXIT"})
    await hass.async_block_till_done()
    tick(tsem_env, 12)
    await refresh(hass, coordinator)
    assert hass.states.get(S_STATE).state in ("PRIMARY_ACTIVE", "SECONDARY_ACTIVE")


async def test_blueprint_without_the_direct_button_never_offers_or_executes_direct(hass, router, tsem_env):
    entry = await setup_entry(hass, router, tsem_env)
    coordinator = hass.data[DOMAIN][entry.entry_id]
    calls = await install_blueprint(hass, allow_direct=False)
    peers(tsem_env)
    tsem(tsem_env, "set", "german", "--no-wait", "--source", "cli")
    tick(tsem_env, 8)
    await refresh(hass, coordinator)
    node_down(tsem_env, tsem_env["TSEM_PRIMARY"])
    node_down(tsem_env, tsem_env["TSEM_SECONDARY"])
    tick(tsem_env, 14)
    await refresh(hass, coordinator)
    blocked = [c for c in calls if "BLOCKED" in (c.data.get("title") or "")]
    assert blocked and [a["action"] for a in blocked[-1].data["data"]["actions"]] == ["TSEM_KEEP"]
    hass.bus.async_fire("mobile_app_notification_action", {"action": "TSEM_GO_DIRECT"})  # a stale button must not work either
    await hass.async_block_till_done()
    await refresh(hass, coordinator)
    assert status(tsem_env)["mode"] == "german"


async def test_blueprint_reports_an_unreachable_router_only_after_the_delay(hass, router, tsem_env):
    from homeassistant.util import dt as dt_util
    from pytest_homeassistant_custom_component.common import async_fire_time_changed
    entry = await setup_entry(hass, router, tsem_env)
    coordinator = hass.data[DOMAIN][entry.entry_id]
    calls = await install_blueprint(hass)
    router.stop()
    await refresh(hass, coordinator)
    assert hass.states.get(B_CONN).state == "off"
    assert not any("not reachable" in (t or "") for t in titles(calls)), "must wait for the delay first"
    async_fire_time_changed(hass, dt_util.utcnow() + timedelta(minutes=3))
    await hass.async_block_till_done()
    assert any("Router not reachable" in (t or "") for t in titles(calls)), titles(calls)


async def test_blocked_degraded_leak_and_unreachable_alerts_are_critical_while_failover_is_not(hass, router, tsem_env):
    entry = await setup_entry(hass, router, tsem_env)
    coordinator = hass.data[DOMAIN][entry.entry_id]
    calls = await install_blueprint(hass)
    peers(tsem_env)
    tsem(tsem_env, "set", "german", "--no-wait", "--source", "cli")
    tick(tsem_env, 8)
    await refresh(hass, coordinator)
    node_down(tsem_env, tsem_env["TSEM_PRIMARY"])
    tick(tsem_env, 12)
    await refresh(hass, coordinator)
    failover = [c for c in calls if "using the backup" in (c.data.get("title") or "")]
    assert failover and failover[-1].data["data"]["push"]["interruption-level"] == "time-sensitive"
    node_down(tsem_env, tsem_env["TSEM_SECONDARY"])
    tick(tsem_env, 12)
    await refresh(hass, coordinator)
    blocked = [c for c in calls if "BLOCKED" in (c.data.get("title") or "")][-1].data["data"]
    assert blocked["push"]["interruption-level"] == "critical"
    assert blocked["push"]["sound"] == {"name": "default", "critical": 1, "volume": 1.0}  # plays even when the phone is silent
    assert blocked["channel"] == "alarm_stream"  # Android: the alarm channel
    assert [a["action"] for a in blocked["actions"]] == ["TSEM_KEEP", "TSEM_GO_DIRECT"]  # the buttons are still there


EGRESS_JSON = '{ "YourFuckingIPAddress": "%s", "YourFuckingLocation": "%s", "YourFuckingISP": "Example ISP", "YourFuckingCountry": "Germany", "YourFuckingCountryCode": "DE", "YourFuckingHostname": "h.example.net" }'


def fake_curl(tmp_path, monkeypatch, ip, location):
    p = tmp_path / "curl-stub"
    p.write_text("#!/bin/sh\ncat <<'J'\n" + EGRESS_JSON % (ip, location) + "\nJ\n")
    p.chmod(0o755)
    monkeypatch.setenv("TSEM_CURL", str(p))


PUB_IP = "sensor.tailscale_exit_manager_public_ip"
PUB_LOC = "sensor.tailscale_exit_manager_public_location"
PUB_ISP = "sensor.tailscale_exit_manager_public_provider"
PUB_BTN = "button.tailscale_exit_manager_check_public_address"


async def test_public_address_is_unknown_until_asked_and_the_button_asks_the_router(hass, router, tsem_env, tmp_path, monkeypatch):
    fake_curl(tmp_path, monkeypatch, "203.0.113.7", "Bonn, Germany")
    await setup_entry(hass, router, tsem_env)
    for ent in (PUB_IP, PUB_LOC, PUB_ISP):
        assert hass.states.get(ent).state == "unknown", ent  # nothing is asked at startup
    await hass.services.async_call("button", "press", {"entity_id": PUB_BTN}, blocking=True)
    await hass.async_block_till_done()
    assert hass.states.get(PUB_IP).state == "203.0.113.7"
    assert hass.states.get(PUB_LOC).state == "Bonn, Germany"
    assert hass.states.get(PUB_ISP).state == "Example ISP"
    attrs = hass.states.get(PUB_IP).attributes
    assert attrs["country_code"] == "DE" and attrs["source"] == "myip.wtf" and attrs["checked_at"]


async def test_public_address_is_refreshed_after_a_mode_change_and_unknown_when_the_service_fails(hass, router, tsem_env, tmp_path, monkeypatch):
    fake_curl(tmp_path, monkeypatch, "203.0.113.7", "Bonn, Germany")
    entry = await setup_entry(hass, router, tsem_env)
    coordinator = hass.data[DOMAIN][entry.entry_id]
    peers(tsem_env)
    await refresh(hass, coordinator)  # first poll after the start: no change yet, nothing asked
    assert hass.states.get(PUB_IP).state == "unknown"
    fake_curl(tmp_path, monkeypatch, "198.51.100.9", "Frankfurt, Germany")
    tsem_env["TSEM_NOW"] = str(int(tsem_env["TSEM_NOW"]) + 120)  # beyond the router's 5 s answer cache
    monkeypatch.setenv("TSEM_NOW", tsem_env["TSEM_NOW"])
    tsem(tsem_env, "set", "german", "--no-wait", "--source", "cli")
    tick(tsem_env, 8)
    await refresh(hass, coordinator)
    await hass.async_block_till_done()
    assert hass.states.get(S_STATE).state == "PRIMARY_ACTIVE"
    assert hass.states.get(PUB_IP).state == "198.51.100.9"  # asked by itself once the new mode was REACHED
    # the service answers garbage: the sensors show unknown, never a made-up address
    bad = tmp_path / "curl-bad"
    bad.write_text("#!/bin/sh\necho nope\n")
    bad.chmod(0o755)
    monkeypatch.setenv("TSEM_CURL", str(bad))
    tsem_env["TSEM_NOW"] = str(int(tsem_env["TSEM_NOW"]) + 120)
    monkeypatch.setenv("TSEM_NOW", tsem_env["TSEM_NOW"])
    await hass.services.async_call("button", "press", {"entity_id": PUB_BTN}, blocking=True)
    await hass.async_block_till_done()
    assert hass.states.get(PUB_IP).state == "unknown"


async def test_config_flow_finds_the_right_port_when_the_default_does_not_answer(hass, router, tsem_env):
    tsem(tsem_env, "set", "direct", "--no-wait")
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    typed = data(router)
    typed["ssl"] = True  # the user ticked HTTPS but the fake router speaks plain HTTP on its port
    done = await hass.config_entries.flow.async_configure(result["flow_id"], typed)
    assert done["type"] == FlowResultType.CREATE_ENTRY
    assert done["data"]["ssl"] is False and done["data"][CONF_PORT] == router.port  # the working variant is stored
