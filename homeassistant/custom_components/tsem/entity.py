"""Shared entity base."""
from __future__ import annotations

from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import TsemCoordinator


class TsemEntity(CoordinatorEntity):
    _attr_has_entity_name = True

    def __init__(self, coordinator: TsemCoordinator, key: str) -> None:
        super().__init__(coordinator)
        entry = coordinator.entry
        self._key = key
        self._attr_unique_id = f"{entry.entry_id}_{key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name="Tailscale Exit Manager",
            manufacturer="TSEM",
            model="GL.iNet router",
            sw_version=(coordinator.data or {}).get("derived", {}).get("version"),
        )

    @property
    def derived(self) -> dict:
        return (self.coordinator.data or {}).get("derived", {})
