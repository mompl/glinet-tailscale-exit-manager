"""Diagnostics download: controller status, config, events and the router-side diagnostic text (secrets redacted)."""
from __future__ import annotations

from typing import Any

from homeassistant.components.diagnostics import async_redact_data

from .api import TsemError
from .const import DOMAIN, TO_REDACT


async def async_get_config_entry_diagnostics(hass, entry) -> dict[str, Any]:
    coordinator = hass.data[DOMAIN][entry.entry_id]
    out: dict[str, Any] = {
        "entry": async_redact_data(dict(entry.data), TO_REDACT),
        "options": dict(entry.options),
        "last_update_success": coordinator.last_update_success,
        "last_error": str(coordinator.last_exception) if coordinator.last_exception else None,
        "status": (coordinator.data or {}).get("status"),
    }
    for name in ("config_get", "events", "diag"):
        try:
            out[name] = await getattr(coordinator.client, name)()
        except TsemError as err:
            out[name] = f"unavailable: {err}"
    return out
