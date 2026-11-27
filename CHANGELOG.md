# Changelog

## 1.2.1

Fixed
- **Names did not resolve in the exit mode when the router's own resolver used a private upstream behind the uplink** (a travel router behind another router; found on real
  hardware in 1.2). Cause: dnsmasq binds its upstream sockets to the uplink interface, so the F03 redirect to `TSEM_DNS_ROUTER` could not move the query into the tunnel and the kill
  switch correctly rejected it there. Now, while a protected mode is active, tsem gives dnsmasq one small temporary file in `/tmp/dnsmasq.d` (RAM only, nothing in `/etc` is touched)
  with `server=<TSEM_DNS_ROUTER>`; DIRECT, the stop and the uninstall remove it again. New setting `TSEM_DNS_UPSTREAM` = `auto` (default: only when an upstream is private and not
  reachable through the LAN or the tailnet), `on`, `off`. Switching modes restarts dnsmasq once (a short DNS pause); nothing is opened by this.
- `tsem selftest` no longer warns about such an upstream when this is handled. The manual `uci` workaround from 1.2.0 is no longer needed (and can be removed).

## 1.2.0
## 1.2.0

Known limitation in 1.2.0 (fixed in 1.2.1), found on real hardware while testing 1.2
- A router whose own resolver (dnsmasq) uses a **private upstream resolver** (a travel router behind another router) cannot resolve names while the exit mode is active; the failure is closed, not open.
  `tsem selftest` and `tsem leaktest` now report it. Workaround and cause in `docs/rc/dns-ipv6.md`; a fix in tsem is planned.

New
- **Statistics and a weekly report.** `tsem report [--days N] [--json] [--notify]`: time in each mode, failovers, BLOCKED episodes, restarts. A small history (a few lines a week, only on changes) is kept;
  time the router was off is not counted as a mode. Optional weekly one-line message (add `report` to `NOTIFY_EVENTS`), a Statistics card in the GL.iNet page, API `report`. See `docs/rc/report.md`.
- **Leak test.** `tsem leaktest` (button "Leak test" in the GL.iNet page, API `leaktest`): checks the router's own traffic and rules in the current mode, in EXIT that the
  address seen outside is not your own uplink address (compared with the address remembered from DIRECT), IPv6, DNS and the kill switch; in BLOCKED that nothing leaves.
  Read-only. See `docs/rc/leak-test.md`.
- **Temporary DIRECT.** `tsem set direct --for 1h` (30m, 2h, 90 = minutes; 1 minute to 24 hours), in the GL.iNet page a "DIRECT for" choice, API `set_mode` with `duration`.
  The controller itself brings the router back to the mode it came from (EXIT or BLOCKED) when the time is over: no GUI and no Home Assistant needed. The timer
  belongs to that one DIRECT: any later action of yours (`tsem set`, the switch, the GUI) voids it, so nothing switches back by surprise; `tsem set direct` again removes it.
  A damaged timer file is ignored; if the clock goes backwards the router returns to protection. `tsem status` shows `direct_until` and `direct_return`.
- **Messages: choose your server.** Your own ntfy server or the public ntfy.sh, your choice; TSEM ships no address of anyone. Every address has its own
  access token (`NOTIFY_TOKEN_FILE`, `NOTIFY_TOKEN_FILE_FALLBACK`). `tsem-notify setup | show | token`, `setup.sh --notify-server/--notify-topic/--notify-token-file/--notify-fallback-server/--notify-public`,
  and a **Messages (ntfy)** card in the GL.iNet page (new API methods `notify_get`, `notify_set`, `notify_test`; not yet in LuCI). A topic or a token is never printed or returned.
  `tsem-notify test` names the server only. See `docs/rc/notifications.md`.

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
