"""Polls the controller status. The status is read from the router; Home Assistant keeps no state of its own."""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .api import TsemAuthError, TsemClient, TsemError
from .const import CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL, DOMAIN, MIN_SCAN_INTERVAL
from .model import derive

EGRESS_KEYS = ("ip", "location", "isp", "country", "country_code", "hostname")

_LOGGER = logging.getLogger(__name__)


class TsemCoordinator(DataUpdateCoordinator):
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry, client: TsemClient) -> None:
        seconds = max(MIN_SCAN_INTERVAL, int(entry.options.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL)))
        super().__init__(hass, _LOGGER, name=DOMAIN, update_interval=timedelta(seconds=seconds))
        self.client = client
        self.entry = entry
        self.egress: dict | None = None  # last answer of the router (None = never asked)
        self.egress_checked: datetime | None = None
        self._last_key: tuple | None = None
        self._egress_task = None

    async def _async_update_data(self) -> dict:
        try:
            status = await self.client.status()
        except TsemAuthError as err:
            raise ConfigEntryAuthFailed(str(err)) from err
        except TsemError as err:
            raise UpdateFailed(str(err)) from err
        self._note(status)
        return {"status": status, "derived": derive(status)}

    def adopt_status(self, status: dict) -> None:
        """Use the status the controller returned together with a change (what was REACHED, not what was asked)."""
        self._note(status)
        self.async_set_updated_data({"status": status, "derived": derive(status)})

    def _note(self, status: dict) -> None:
        """The public address changes with the mode: once a CHANGE of mode / state / exit node is reached, ask the router again."""
        d = derive(status)
        key = (d["desired_mode"], d["state"], d["active_exit_node"])
        changed = self._last_key is not None and key != self._last_key
        self._last_key = key
        if changed and d["reached"] and (self._egress_task is None or self._egress_task.done()):
            self._egress_task = self.hass.async_create_task(self.async_check_egress())

    async def async_check_egress(self) -> None:
        """Ask the router for the public address (the router asks myip.wtf). A failure is shown as unknown, never invented."""
        try:
            res = await self.client.egress()
        except TsemError as err:
            _LOGGER.debug("public address not available: %s", err)
            res = {"ok": False}
        self.egress = res if isinstance(res, dict) and res.get("ok") else None
        self.egress_checked = datetime.now(timezone.utc)
        self.async_update_listeners()
