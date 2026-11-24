"""Binary sensors: kill switch, leak risk, mode reached, controller connection."""
from __future__ import annotations

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity

from .const import DOMAIN
from .entity import TsemEntity

# key, name, derived key, device class
BINARY = (
    ("kill_switch", "Kill switch active", "kill_switch", None),
    ("leak_risk", "Leak risk", "leak_risk", BinarySensorDeviceClass.PROBLEM),
    ("mode_reached", "Requested mode reached", "reached", None),
)


async def async_setup_entry(hass, entry, async_add_entities) -> None:
    coordinator = hass.data[DOMAIN][entry.entry_id]
    ents = [TsemBinary(coordinator, *b) for b in BINARY]
    ents.append(TsemConnection(coordinator))
    async_add_entities(ents)


class TsemBinary(TsemEntity, BinarySensorEntity):
    def __init__(self, coordinator, key, name, dkey, dclass) -> None:
        super().__init__(coordinator, key)
        self._attr_name = name
        self._dkey = dkey
        if dclass is not None:
            self._attr_device_class = dclass

    @property
    def is_on(self) -> bool | None:
        v = self.derived.get(self._dkey)
        return None if v is None else bool(v)


class TsemConnection(TsemEntity, BinarySensorEntity):
    """Stays available when the router cannot be reached: it is the one entity that reports exactly that."""

    _attr_name = "Controller connection"
    _attr_device_class = BinarySensorDeviceClass.CONNECTIVITY

    def __init__(self, coordinator) -> None:
        super().__init__(coordinator, "connection")

    @property
    def available(self) -> bool:
        return True

    @property
    def is_on(self) -> bool:
        return bool(self.coordinator.last_update_success)

    @property
    def extra_state_attributes(self) -> dict:
        err = self.coordinator.last_exception
        return {} if self.coordinator.last_update_success else {"error": str(err) if err else "unknown"}
