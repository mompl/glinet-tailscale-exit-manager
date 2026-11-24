# TSEM for Home Assistant (separate module)

A small custom integration. It is **not** part of the router package: the router works completely without it, and
nothing in the router installer refers to it. No MQTT, no extra Python packages; it uses the router's local API.

## Install

For the production Home Assistant (backup, controlled install, acceptance, rollback) follow `docs/home-assistant-install.md`.

1. Copy `homeassistant/custom_components/tsem` to `<HA config>/custom_components/tsem`, restart Home Assistant.
2. *Settings → Devices & services → Add integration → GL.iNet Tailscale Exit Manager*: router address, user, password.
   Use a router user with the rpcd ACL `tsem-write` (the default `root` works). A user with only `tsem-read` can monitor
   but every switch action fails with a clear error (see `docs/api.md`).
3. Reaching the router: Home Assistant needs a route to the router's web port on the LAN side (not WAN).

## Entities (device "Tailscale Exit Manager")

| entity | meaning |
|---|---|
| `switch.…_exit_node_mode` | ON = GERMAN, OFF = DIRECT (explicit, switches the kill switch off). Shows the *desired* mode; attributes `reached`, `state`, `active_exit_node` show what the controller verified |
| `sensor.…_operating_mode` | german / direct / none |
| `sensor.…_controller_state` | PRIMARY_ACTIVE, SECONDARY_ACTIVE, CONNECTING_*, DEGRADED, BLOCKED, ERROR, DISABLED |
| `sensor.…_active_exit_node` | IP of the exit node actually in use (empty unless active) |
| `sensor.…_failover_status` | armed / failed_over / off / blocked / connecting / degraded / inactive … |
| `sensor.…_primary_check`, `…_secondary_check` | evidence per node: egress / reach / unreachable / rejected … |
| `sensor.…_hardware_switch`, `…_ipv6_protection`, `…_dns_protection` | as reported by the controller |
| `binary_sensor.…_kill_switch_active`, `…_leak_risk`, `…_requested_mode_reached` | |
| `binary_sensor.…_controller_connection` | stays available when the router cannot be reached and then turns off with the error as attribute; all other entities become unavailable (no stale values) |

Diagnostics download (device page): status, config, event log and router-side diagnostic text, password/user/host redacted.
Polling interval: 15 s (option, minimum 5 s).

## Tested / not tested

Software-tested here: the API client against the real rpcd plugin and controller (behind a fake web endpoint that applies the
real ACL file), the entity logic, config-flow error mapping and diagnostics redaction against a *minimal Home Assistant
stand-in*. **Not tested:** loading in a real Home Assistant (UNVERIFIED until installed there), HTTPS with a self-signed
certificate (the integration does not verify certificates when `ssl` is on).
