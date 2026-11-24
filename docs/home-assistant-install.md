# Home Assistant: prerequisites, controlled install, acceptance, rollback

Target: Home Assistant OS on the Dell Wyse 5070, planned address **10.20.0.11** (LAN 10.20.0.0/24); router `root` at
**10.20.0.1**. No MQTT. **Nothing here touches existing dashboards, integrations or automations**: the integration only
*adds* one custom component and one config entry (which is removed again by the rollback below).

Status: the integration is software-tested against the real rpcd plugin + controller behind a fake web endpoint and a
minimal Home Assistant stand-in. It has **never been loaded in a real Home Assistant**. Until section 4 is done and
`ha.entities` shows PASS in a Mac acceptance run, the Home Assistant part of the product is **UNVERIFIED, not PASS**.

## 1. Prerequisites (all must be true before the test)

| # | Prerequisite | How to check |
|---|---|---|
| 1 | Router acceptance has passed (`ROUTER ACCEPTANCE COMPLETE`), TSEM in mode german or direct, native or LuCI GUI working | Mac run report |
| 2 | HA OS reachable at 10.20.0.11 from the Mac; HA can reach `http://10.20.0.1:80/ubus` (LAN side only) | from HA: *Developer tools* cannot curl; use the integration setup step "cannot_connect" as the test, or the SSH add-on: `curl -s -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","login",{"username":"x","password":"x"}]}' http://10.20.0.1/ubus` must answer JSON |
| 3 | A **dedicated router user** for HA (not `root`) with the rpcd ACL group `tsem-write` (see `docs/api.md`) | `tsem-api-check` on the router, or the Mac runner's `mac.api.auth.rw` |
| 4 | The API is **not** reachable from the WAN | Mac report line `api.wan-exposure` PASS |
| 5 | A fresh **full HA backup** exists and its file is stored outside the Wyse | section 2 |
| 6 | HA version recent enough for config flows with `_get_reauth_entry` (2024.11+) | HA *Settings → About* |
| 7 | Credentials: the router user's password is typed into the HA UI only. It lives in HA's config-entry storage, never in this repo, never in a file you copy | `git grep -i password homeassistant/` shows only code, no values |

Open on real hardware: whether the GL.iNet firmware serves `/ubus` for that user on port 80 (the router acceptance step
`mac.api.auth.rw` proves it from the Mac; the HA test then proves it from HA's address).

## 2. Backup (before any change in HA)

1. HA UI: *Settings → System → Backups → Create backup → Full backup*. Note its name. (CLI alternative in the SSH add-on: `ha backups new --name before-tsem`.)
2. Download the `.tar` to the Mac. A backup that only exists on the Wyse is not a backup.
3. Record the current list of installed custom components (SSH add-on / Samba: `ls /config/custom_components`) so the rollback can be checked against it.

## 3. Install (only after your explicit approval; adds, never edits)

HA cannot install a custom integration from its UI alone: **the component folder must be copied once (manual step)**, then the
setup itself is done in the UI.

1. Copy `homeassistant/custom_components/tsem` from this repo to `/config/custom_components/tsem` on the HA OS (Samba or SSH add-on). Do not touch `configuration.yaml`, `automations.yaml`, dashboards.
2. *Settings → System → Restart*, or *Developer tools → Restart*.
3. *Settings → Devices & services → Add integration → "GL.iNet Tailscale Exit Manager"*: host `10.20.0.1`, the router user (GL.iNet: `root`) and its password. The port is found by itself: the setup tries the port you typed, then GL.iNet's 8443 (HTTPS, self-signed certificate) and 8080 (HTTP), then 443 and 80 (plain OpenWrt). The working variant is stored. A wrong password shows `invalid_auth`; an unreachable router shows `cannot_connect`; nothing is changed on the router by this step (it reads status only).
4. Do not add automations yet.

## 4. Acceptance on the the production Home Assistant (read, then control)

Run the Mac runner with the HA URL and a long-lived token file (the token is created in the HA profile page and stays on the Mac, `chmod 600`):

    sh tools/run-rc3-active-mac.sh final --ha-url http://10.20.0.11:8123 --ha-token-file ~/.tsem-ha-token

(the `final` run is the full acceptance with its own confirmations; `ha.entities` is evaluated in its Step 9 together with the router criteria. The flags are the runner's only HA input.) The runner checks the six entities
`switch.tailscale_exit_manager_exit_node_mode`, `sensor.…_operating_mode`, `sensor.…_active_exit_node`, `sensor.…_failover_status`,
`binary_sensor.…_kill_switch_active`, `binary_sensor.…_controller_connection` against `tsem status` on the router.

Manual checks (record the result of each; an unexecuted line is NOT PASS):

| Check | Expected | Result |
|---|---|---|
| Switch ON in HA | `tsem status` mode german, source `ha`, guard german (kill switch active) | |
| Switch OFF in HA | mode direct, guard open, only because you pressed it | |
| Change on the router GUI / hardware switch | HA shows the new state within the polling interval (15 s) | |
| **Router unreachable** (unplug the Wyse's LAN or stop polling: e.g. block 10.20.0.1 for the HA) | entities `unavailable`, `controller_connection` = off, **router mode unchanged, kill switch unchanged, never DIRECT** | |
| **HA restart** | after the restart HA reads the status; no mode change appears in `tsem events` | |
| **Router restart** | HA recovers by itself; router comes back in its saved mode (guard blocks until the saved mode is applied); no DIRECT from HA | |
| Viewer user (`tsem-read` only) | monitoring works, every switch action fails with an error | |

Safety facts that are unit-tested (see `homeassistant/tests/test_platforms.py`): polling, losing the connection and reconnecting send
**reads only**; a change is sent only when a user or automation actions the switch; DIRECT additionally requires `confirm`, which the
switch supplies for an explicit OFF. HA keeps no state of its own and shows the *desired* mode separately from what the controller
*reached*.

Recommendation for automations you add later: act on `switch.…_exit_node_mode` ON (safe direction) only; do not write an automation that
turns it OFF on a connection loss, a sensor going `unavailable`, or a restart.

## 5. Rollback (reversible, in this order)

1. HA UI: *Settings → Devices & services → TSEM → ⋮ → Delete* (removes the config entry and its entities).
2. Delete `/config/custom_components/tsem`; restart HA.
3. Verify `ls /config/custom_components` equals the list recorded in section 2.
4. Still wrong? *Settings → System → Backups →* restore the full backup from section 2 (restores the whole HA, so do it last).
5. The router is unaffected by all of this; HA only used its local API. To cut HA's access at once, remove its router user or its `tsem-write` ACL group.

## 6. Two verdicts, never mixed

* **ROUTER ACCEPTANCE**: routing and kill switch, failover, DIRECT recovery, DNS/IPv6, hardware switch, API and GUI, persistence. It can pass on its own.
* **FULL PRODUCT ACCEPTANCE**: router acceptance complete **and** `ha.entities` PASS **and** the manual checks above recorded. Anything untested in Home Assistant keeps this at NOT PASSED while the router verdict stands.

## 7. Push notifications to your phone (Home Assistant blueprint)

TSEM sends no push messages itself. Home Assistant is the notification channel: it already knows the router's state (section 4) and
its Companion app delivers to **iPhone and Android**. A router in BLOCKED has no Internet on purpose, so a message sent *by the router*
would not get out exactly when it matters; Home Assistant sits on your LAN and is not affected.

Install: copy `blueprints/automation/tsem/exit_node_alerts.yaml` (in the `tsem-ha-*.tar.gz` package) to
`/config/blueprints/automation/tsem/` on the Home Assistant host. Then *Settings → Automations & scenes → Blueprints → TSEM - exit node
alerts → Create automation*, pick the entities (controller state, controller connection, leak risk, exit node mode switch) and your phone's notify
service (`notify.mobile_app_<your phone>`). One automation per router; one per phone if several phones should be told.

| Event | Message | Buttons |
|---|---|---|
| Primary exit node fails, backup takes over | "Exit node failed - using the backup" | |
| Exit node unstable | "Exit node unstable" | |
| Neither exit node works | "BLOCKED - no exit node reachable" | **Keep blocked**, **Go DIRECT (unprotected)** |
| Primary is back | "Exit node is back" | |
| Home Assistant cannot reach the router for N minutes (default 2) | "Router not reachable" | |
| Leak risk reported | "LEAK RISK on the router" (critical) | |
| Mode changed by the hardware switch, the GUI or the command line | "Mode changed: ..." | **Back to exit node** or **Go DIRECT** |

After you tap a button the automation switches the mode, waits (up to 60 s for DIRECT, 90 s for the exit node) and sends a second
message that says what the router **really reached**, or that it was **not** reached. It never claims success it has not seen.

Notes:
* "Go DIRECT" switches the kill switch off. It is only ever offered in a notification, always needs your tap, and can be removed completely
  (`Offer a "Go DIRECT" button` = off; a stale button then does nothing either). Nothing in the blueprint switches to DIRECT by itself.
* The iPhone interruption level can be `time-sensitive` (default) or `critical`; Android uses high priority.
* Detection time: the router first has to see the exit node fail several checks in a row (default 3 checks, 5 s apart), then Home Assistant sees it at its next poll (every 15 s): expect roughly half a minute, not instantly.
* Two routers: use one automation per router and be aware that notification button names are shared, so give each blueprint instance its own
  notify service or keep to one router per phone.
* Tested in the real Home Assistant core (`homeassistant/tests_real`), with a simulated phone service. **Not yet tested on a real phone.**


## 8. Alerts are critical where the Internet is cut

The blueprint sends BLOCKED, "exit node unstable", leak risk and "router not reachable" as **critical** alerts (iPhone: allow "Critical alerts" in the Companion app; Android: alarm channel). The failover to the backup node and mode changes use the interruption level chosen in the blueprint.

## 9. Public address entities

The integration shows what the Internet sees for the router: `Public IP` (attributes: country, host name), `Public location`, `Public provider`, and the button `Check public address`. The router asks myip.wtf only when the button is pressed or after a reached change of mode, state or exit node, never at startup.
