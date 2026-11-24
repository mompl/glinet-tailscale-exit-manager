"""Read-only sensors: operating mode, controller state, active exit node, failover, probes, hardware switch."""
from __future__ import annotations

from homeassistant.components.sensor import SensorEntity

from .const import DOMAIN
from .entity import TsemEntity

# key, name, field of the router's answer, icon
EGRESS = (
    ("public_ip", "Public IP", "ip", "mdi:ip-network"),
    ("public_location", "Public location", "location", "mdi:map-marker"),
    ("public_provider", "Public provider", "isp", "mdi:domain"),
)

# key, name, derived key
SENSORS = (
    ("mode", "Operating mode", "desired_mode"),
    ("state", "Controller state", "state"),
    ("active_exit_node", "Active exit node", "active_exit_node"),
    ("failover_status", "Failover status", "failover_status"),
    ("primary_probe", "Primary check", "primary_probe"),
    ("secondary_probe", "Secondary check", "secondary_probe"),
    ("hw_switch", "Hardware switch", "hw_state"),
    ("ipv6_protection", "IPv6 protection", "ipv6_protection"),
    ("dns_protection", "DNS protection", "dns_protection"),
)


async def async_setup_entry(hass, entry, async_add_entities) -> None:
    coordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([TsemSensor(coordinator, k, n, d) for k, n, d in SENSORS] + [TsemEgressSensor(coordinator, *e) for e in EGRESS])


class TsemSensor(TsemEntity, SensorEntity):
    def __init__(self, coordinator, key: str, name: str, dkey: str) -> None:
        super().__init__(coordinator, key)
        self._attr_name = name
        self._dkey = dkey

    @property
    def native_value(self):
        if self._key == "active_exit_node":
            # the name comes from Tailscale via the router; the address is the fallback and stays an attribute
            return self.derived.get("active_exit_name") or self.derived.get("active_exit_node")
        return self.derived.get(self._dkey)

    @property
    def extra_state_attributes(self) -> dict:
        d = self.derived
        if self._key == "state":
            return {"reached": d.get("reached"), "error": d.get("error"), "last_change_source": d.get("last_change_source")}
        if self._key == "active_exit_node":
            return {"address": d.get("active_exit_node"), "primary": d.get("primary"), "primary_name": d.get("primary_name"), "secondary": d.get("secondary"), "secondary_name": d.get("secondary_name")}
        if self._key == "hw_switch":
            return {"matches_mode": d.get("hw_match")}
        return {}


class TsemEgressSensor(TsemEntity, SensorEntity):
    """What the Internet sees for this router (asked from myip.wtf by the router after every mode change and on the button)."""

    def __init__(self, coordinator, key: str, name: str, field: str, icon: str) -> None:
        super().__init__(coordinator, key)
        self._attr_name = name
        self._attr_icon = icon
        self._field = field

    @property
    def native_value(self):
        eg = self.coordinator.egress
        return (eg or {}).get(self._field) or None

    @property
    def extra_state_attributes(self) -> dict:
        eg = self.coordinator.egress or {}
        attrs = {"checked_at": self.coordinator.egress_checked.isoformat() if self.coordinator.egress_checked else None, "source": "myip.wtf"}
        if self._field == "ip":
            attrs.update({"country": eg.get("country"), "country_code": eg.get("country_code"), "hostname": eg.get("hostname"), "tor_exit": eg.get("tor")})
        return attrs
