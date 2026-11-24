"""Config flow: router address + the router user's credentials (a user with the rpcd ACL "tsem-write")."""
from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.const import CONF_HOST, CONF_PASSWORD, CONF_PORT, CONF_USERNAME
from homeassistant.core import callback

from .api import TsemAuthError, TsemClient, TsemConnectionError, TsemError
from .const import (CONF_SCAN_INTERVAL, CONF_SSL, DEFAULT_PORT, DEFAULT_SCAN_INTERVAL, DEFAULT_SSL, DOMAIN, MIN_SCAN_INTERVAL)
from .transport import make_post


async def validate(hass, data: dict, timeout: float = 10.0) -> None:
    client = TsemClient(make_post(hass), data[CONF_HOST], data[CONF_USERNAME], data[CONF_PASSWORD],
                        port=data.get(CONF_PORT, DEFAULT_PORT), ssl=data.get(CONF_SSL, DEFAULT_SSL), timeout=timeout)
    await client.login()
    await client.status()  # proves the controller answers and the user may read it


# where a router usually answers the ubus API: GL.iNet (uhttpd) 8443 https / 8080 http, plain OpenWrt 443 / 80
FALLBACKS = ((8443, True), (8080, False), (443, True), (80, False))


async def validate_any(hass, data: dict) -> dict:
    """Try the address as typed, then the usual ports (a wrong port is the most common mistake). Returns the data with the
    port/ssl that worked. A router that answers but refuses the login stops the search (that is an authentication problem)."""
    first = (data.get(CONF_PORT, DEFAULT_PORT), data.get(CONF_SSL, DEFAULT_SSL))
    tries = list(dict.fromkeys([first, (first[0], not first[1])] + list(FALLBACKS)))  # as typed, same port with the other scheme, then the usual ports
    last: TsemError = TsemConnectionError("no answer")
    for i, (port, ssl) in enumerate(tries):
        cand = {**data, CONF_PORT: port, CONF_SSL: ssl}
        try:
            await validate(hass, cand, timeout=10.0 if i == 0 else 4.0)
        except TsemAuthError:
            raise
        except TsemConnectionError as err:
            last = err
            continue
        return cand
    raise last


def _schema(defaults: dict) -> vol.Schema:
    return vol.Schema({
        vol.Required(CONF_HOST, default=defaults.get(CONF_HOST, "")): str,
        vol.Required(CONF_USERNAME, default=defaults.get(CONF_USERNAME, "root")): str,
        vol.Required(CONF_PASSWORD): str,
        vol.Optional(CONF_PORT, default=defaults.get(CONF_PORT, DEFAULT_PORT)): int,
        vol.Optional(CONF_SSL, default=defaults.get(CONF_SSL, DEFAULT_SSL)): bool,
    })


class TsemConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input: dict[str, Any] | None = None):
        errors: dict[str, str] = {}
        if user_input is not None:
            await self.async_set_unique_id(user_input[CONF_HOST])
            self._abort_if_unique_id_configured()
            try:
                found = await validate_any(self.hass, user_input)
            except TsemAuthError:
                errors["base"] = "invalid_auth"
            except TsemError:
                errors["base"] = "cannot_connect"
            except Exception:  # noqa: BLE001
                errors["base"] = "unknown"
            else:
                return self.async_create_entry(title=f"TSEM {user_input[CONF_HOST]}", data=found)
        return self.async_show_form(step_id="user", data_schema=_schema(user_input or {}), errors=errors)

    async def async_step_reauth(self, entry_data: dict[str, Any]):
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(self, user_input: dict[str, Any] | None = None):
        entry = self._get_reauth_entry()
        errors: dict[str, str] = {}
        if user_input is not None:
            data = {**entry.data, CONF_PASSWORD: user_input[CONF_PASSWORD]}
            try:
                await validate(self.hass, data)
            except TsemAuthError:
                errors["base"] = "invalid_auth"
            except TsemError:
                errors["base"] = "cannot_connect"
            else:
                return self.async_update_reload_and_abort(entry, data=data)
        return self.async_show_form(step_id="reauth_confirm", data_schema=vol.Schema({vol.Required(CONF_PASSWORD): str}), errors=errors)

    @staticmethod
    @callback
    def async_get_options_flow(config_entry):
        return TsemOptionsFlow()


class TsemOptionsFlow(config_entries.OptionsFlow):
    async def async_step_init(self, user_input: dict[str, Any] | None = None):
        if user_input is not None:
            return self.async_create_entry(data=user_input)
        cur = self.config_entry.options.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL)
        return self.async_show_form(step_id="init", data_schema=vol.Schema({
            vol.Required(CONF_SCAN_INTERVAL, default=cur): vol.All(int, vol.Range(min=MIN_SCAN_INTERVAL, max=600))}))
