"""Button: ask the router for the public address now (it asks myip.wtf; nothing is asked without a press or a mode change)."""
from __future__ import annotations

from homeassistant.components.button import ButtonEntity

from .const import DOMAIN
from .entity import TsemEntity


async def async_setup_entry(hass, entry, async_add_entities) -> None:
    async_add_entities([TsemEgressButton(hass.data[DOMAIN][entry.entry_id])])


class TsemEgressButton(TsemEntity, ButtonEntity):
    _attr_name = "Check public address"
    _attr_icon = "mdi:ip-network-outline"

    def __init__(self, coordinator) -> None:
        super().__init__(coordinator, "check_public_address")

    async def async_press(self) -> None:
        await self.coordinator.async_check_egress()
