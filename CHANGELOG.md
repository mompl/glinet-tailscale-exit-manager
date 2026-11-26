# Changelog

## 1.1.0

New
- **Ordered list of exit nodes (1 to 8).** Failover walks down the list; when all fail the router is BLOCKED (never DIRECT). Auto-return goes to the
  best healthy rank, not only rank 1. `setup.sh --fallback NAME` (repeatable), `tsem config set TSEM_NODES=... TSEM_NODE_NAMES=...`, the GL.iNet
  page (add/remove fallbacks), LuCI and the Home Assistant sensor show the whole list (`active_rank`, `node_list`). Configurations and a running
  failover state of 1.0 keep working unchanged.
- **Messages without Home Assistant** (`tsem-notify`, ntfy or webhook): failover, blocked, recovered, exit, direct, error. A message that cannot be
  sent while the kill switch is closed waits in a queue. `NOTIFY_URL_FALLBACK` is a second address (for example a server on the tailnet). The text
  names the exit node. Manual `set direct` / `set blocked` send a message too. See `docs/rc/notifications.md` (own ntfy server in Docker, public
  address for phones, tailnet address for routers).
- **`tsem backup` / `tsem restore`** of the settings (no mode, tokens or passwords).
- **Admin network while protected** (`TSEM_ADMIN_SUBNETS4/6`, `setup.sh --admin-subnet`): keep the router reachable over a WAN-side private network
  (for example the Wi-Fi uplink of a GL-E5800) in EXIT and BLOCKED.

Changed
- **`setup.sh` keeps a protected router protected.** Updating a router that is in the exit or blocked mode no longer passes through DIRECT
  (found on a Mudi 7, where it was open for about two minutes). If anything fails it stays closed.

Fixed
- GitHub CI: tests that need root run with sudo, scripts have their executable bit.

Firmware upgrades (field notes, GL-MG1300 4.11.1 -> 4.11.2): tsem survived and restored itself, including `ip6tables`. On a GL-E5800
(4.10.3 -> 4.10.4) the upgrade removed tsem completely, including the keep list: check `tsem status` after every firmware upgrade and run
`setup.sh` again if it is gone. Until then the router has NO kill switch. See `docs/firmware-upgrade.md`.

## 1.0.0
First public release (pre-release rc1): DIRECT / EXIT / BLOCKED, failover with hysteresis, kill switch, GL.iNet / LuCI GUI, Home Assistant integration.

Also in 1.1.0: `tsem selftest` warns (`multiwan`) when GL.iNet multi-WAN runs in balance mode with two uplinks (see docs/firmware-upgrade.md).
- **Firmware-upgrade protection written twice**: the keep list is now also installed as `/lib/upgrade/keep.d/tsem` (it keeps itself), not only as a block in
  `/etc/sysupgrade.conf`, because on a GL-E5800 the block did not survive and tsem was gone after the upgrade.
