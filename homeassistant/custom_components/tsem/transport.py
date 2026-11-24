"""aiohttp transport for TsemClient (the only module that touches Home Assistant's HTTP session)."""
from __future__ import annotations

import asyncio
from typing import Any

import aiohttp
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession


def make_post(hass: HomeAssistant, verify_ssl: bool = False):
    session = async_get_clientsession(hass, verify_ssl=verify_ssl)

    async def post_json(url: str, payload: dict, timeout: float) -> Any:
        try:
            async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
                if resp.status != 200:
                    raise OSError(f"HTTP {resp.status}")
                return await resp.json(content_type=None)
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as err:
            raise OSError(str(err) or type(err).__name__) from err

    return post_json
