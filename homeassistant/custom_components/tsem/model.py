"""Turns the controller status into the values Home Assistant shows. No HA imports.

Nothing here invents success: `reached` is true only when the controller itself reports an active, verified
state; `desired_mode` and the reached state are separate values.
"""
from __future__ import annotations

ACTIVE_STATES = ("PRIMARY_ACTIVE", "SECONDARY_ACTIVE", "DEGRADED")


def derive(st: dict) -> dict:
    state = st.get("state", "UNKNOWN")
    mode = st.get("mode", "none")
    guard = st.get("guard", "none")
    reached = (state in ("PRIMARY_ACTIVE", "SECONDARY_ACTIVE")) if mode == "german" else (mode == "direct" and state == "DISABLED" and guard == "open")
    active = st.get("active_exit") if state in ACTIVE_STATES else None
    if active in ("", "none"):
        active = None
    aname = st.get("active_exit_name") if active else None
    if aname in ("", "none"):
        aname = None

    if mode == "direct":
        failover = "inactive"
    elif st.get("failover") == "off":
        failover = "off"
    elif state == "SECONDARY_ACTIVE":
        failover = "failed_over"
    elif state == "PRIMARY_ACTIVE":
        failover = "armed" if st.get("secondary") not in (None, "", "none") else "no_secondary"
    elif state == "DEGRADED":
        failover = "degraded"
    elif state.startswith("CONNECTING"):
        failover = "connecting"
    elif state == "BLOCKED":
        failover = "blocked"
    else:
        failover = "error"

    return {
        "desired_mode": mode,
        "state": state,
        "reached": bool(reached),
        "active_exit_node": active,
        "active_exit_name": aname,
        "failover_status": failover,
        "failover_policy": st.get("failover"),
        "kill_switch": bool(st.get("kill_switch_active")),
        "leak_risk": bool(st.get("leak_risk")),
        "primary": st.get("primary"),
        "primary_name": st.get("primary_name") if st.get("primary_name") not in ("", "none") else None,
        "primary_probe": st.get("primary_probe"),
        "secondary": st.get("secondary"),
        "secondary_name": st.get("secondary_name") if st.get("secondary_name") not in ("", "none") else None,
        "secondary_probe": st.get("secondary_probe"),
        "hw_state": st.get("hw_state"),
        "hw_match": st.get("hw_match"),
        "ipv6_protection": st.get("ipv6_protection"),
        "dns_protection": st.get("dns_protection"),
        "error": st.get("error") or None,
        "last_change_source": st.get("source"),
        "version": st.get("version"),
    }
