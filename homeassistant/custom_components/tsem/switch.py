"""Mode switch: ON = exit-node mode (exit node + kill switch), OFF = DIRECT (explicit; kill switch off)."""
from __future__ import annotations

from typing import Any

from homeassistant.components.switch import SwitchEntity
from homeassistant.exceptions import HomeAssistantError

from .api import TsemError
from .const import DOMAIN
from .entity import TsemEntity


async def async_setup_entry(hass, entry, async_add_entities) -> None:
    async_add_entities([TsemModeSwitch(hass.data[DOMAIN][entry.entry_id])])


class TsemModeSwitch(TsemEntity, SwitchEntity):
    """is_on shows the DESIRED mode; `reached` / `state` attributes and the sensors show what the controller verified."""

    _attr_name = "Exit node mode"
    _attr_icon = "mdi:shield-lock"

    def __init__(self, coordinator) -> None:
        super().__init__(coordinator, "mode_switch")

    @property
    def is_on(self) -> bool | None:
        mode = self.derived.get("desired_mode")
        if mode in ("german", "direct"):
            return mode == "german"
        return None  # no valid mode saved: unknown, not "off"

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        d = self.derived
        return {"reached": d.get("reached"), "state": d.get("state"), "active_exit_node": d.get("active_exit_node"),
                "kill_switch": d.get("kill_switch"), "error": d.get("error")}

    async def _set(self, mode: str) -> None:
        try:
            reply = await self.coordinator.client.set_mode(mode, confirm=(mode == "direct"))
        except TsemError as err:
            raise HomeAssistantError(f"TSEM: {err}") from err
        if isinstance(reply.get("status"), dict):
            self.coordinator.adopt_status(reply["status"])
        else:
            await self.coordinator.async_request_refresh()

    async def async_turn_on(self, **kwargs: Any) -> None:
        await self._set("german")

    async def async_turn_off(self, **kwargs: Any) -> None:
        await self._set("direct")
