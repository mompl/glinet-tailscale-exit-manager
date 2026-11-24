"""Client for the TSEM local API (ubus object "tsem" on the router, JSON-RPC over HTTP).

No Home Assistant imports here: the HTTP transport is injected, so the client is unit-testable and the
integration needs no separate security logic. Authentication and authorization are the router's (rpcd session
+ ACL): this client logs in with the user's router credentials and only ever sends what that user may do.
"""
from __future__ import annotations

from typing import Any, Awaitable, Callable

NULL_SESSION = "0" * 32
UBUS_PERMISSION_DENIED = 6

# post_json(url, payload, timeout) -> parsed JSON reply; raises OSError/TimeoutError on transport problems
PostJson = Callable[[str, dict, float], Awaitable[Any]]


class TsemError(Exception):
    """Base class."""


class TsemConnectionError(TsemError):
    """Router not reachable / not speaking ubus JSON-RPC."""


class TsemAuthError(TsemError):
    """Wrong credentials or the user lacks the required rpcd permission."""


class TsemApiError(TsemError):
    """The controller refused or failed a request (reply had ok=false)."""

    def __init__(self, code: str, message: str, reply: dict | None = None):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.reply = reply or {}


class TsemClient:
    def __init__(self, post_json: PostJson, host: str, username: str, password: str, *,
                 port: int = 80, ssl: bool = False, timeout: float = 10.0) -> None:
        self._post = post_json
        self._url = f"{'https' if ssl else 'http'}://{host}:{port}/ubus"
        self._user = username
        self._password = password
        self._timeout = timeout
        self._sid: str | None = None
        self._id = 0

    async def _raw(self, params: list) -> Any:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": "call", "params": params}
        try:
            reply = await self._post(self._url, payload, self._timeout)
        except (OSError, TimeoutError) as err:  # aiohttp errors derive from OSError / are wrapped by the transport
            raise TsemConnectionError(str(err) or type(err).__name__) from err
        if not isinstance(reply, dict) or reply.get("jsonrpc") != "2.0":
            raise TsemConnectionError("not a ubus JSON-RPC reply")
        return reply

    async def login(self) -> None:
        reply = await self._raw([NULL_SESSION, "session", "login", {"username": self._user, "password": self._password}])
        res = reply.get("result")
        if not (isinstance(res, list) and len(res) == 2 and res[0] == 0 and isinstance(res[1], dict)
                and res[1].get("ubus_rpc_session")):
            self._sid = None
            raise TsemAuthError("login failed")
        self._sid = res[1]["ubus_rpc_session"]

    async def call(self, method: str, args: dict | None = None, *, _retry: bool = True) -> dict:
        if self._sid is None:
            await self.login()
        reply = await self._raw([self._sid, "tsem", method, args or {}])
        res = reply.get("result")
        denied = ("error" in reply) or (isinstance(res, list) and res and res[0] == UBUS_PERMISSION_DENIED)
        if denied:
            self._sid = None
            if _retry:  # an expired session looks exactly like a missing permission: log in once more
                return await self.call(method, args, _retry=False)
            raise TsemAuthError(f"access denied for {method}")
        if not (isinstance(res, list) and len(res) == 2 and res[0] == 0 and isinstance(res[1], dict)):
            raise TsemConnectionError(f"unexpected ubus status for {method}: {res!r}")
        body = res[1]
        if body.get("ok") is False:
            raise TsemApiError(str(body.get("code", "error")), str(body.get("error") or body.get("message") or ""), body)
        return body

    # ---- reads
    async def status(self) -> dict:
        body = await self.call("status")
        if not isinstance(body.get("status"), dict):
            raise TsemConnectionError("controller returned no status")
        return body["status"]

    async def config_get(self) -> dict:
        return (await self.call("config_get"))["config"]

    async def nodes(self) -> dict:
        return (await self.call("nodes"))["result"]

    async def egress(self) -> dict:
        """The public address the router reaches the Internet with (the router asks myip.wtf; on demand only)."""
        return (await self.call("egress"))["result"]

    async def events(self) -> list:
        return (await self.call("events")).get("events", [])

    async def diag(self) -> list:
        return (await self.call("diag")).get("diag", [])

    # ---- writes (each returns the reply incl. the status read AFTER the change)
    async def set_mode(self, mode: str, *, confirm: bool = False) -> dict:
        args: dict = {"mode": mode, "source": "ha"}
        if mode == "direct":
            args["confirm"] = bool(confirm)
        return await self.call("set_mode", args)

    async def set_failover(self, mode: str) -> dict:
        return await self.call("set_failover", {"mode": mode, "source": "ha"})

    async def failover_now(self) -> dict:
        return await self.call("failover_now")

    async def config_set(self, **kw: Any) -> dict:
        return await self.call("config_set", kw)
