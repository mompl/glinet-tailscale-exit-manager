"""GL.iNet Tailscale Exit Manager (TSEM): local integration. Works through the router's local API only."""
from __future__ import annotations

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_HOST, CONF_PASSWORD, CONF_PORT, CONF_USERNAME
from homeassistant.core import HomeAssistant

from .api import TsemClient
from .const import CONF_SSL, DEFAULT_PORT, DOMAIN, PLATFORMS
from .coordinator import TsemCoordinator
from .transport import make_post


def build_client(hass: HomeAssistant, data: dict) -> TsemClient:
    return TsemClient(
        make_post(hass), data[CONF_HOST], data[CONF_USERNAME], data[CONF_PASSWORD],
        port=data.get(CONF_PORT, DEFAULT_PORT), ssl=data.get(CONF_SSL, False),
    )


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    coordinator = TsemCoordinator(hass, entry, build_client(hass, entry.data))
    await coordinator.async_config_entry_first_refresh()
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    entry.async_on_unload(entry.add_update_listener(_reload))
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def _reload(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if ok:
        hass.data[DOMAIN].pop(entry.entry_id, None)
    return ok
