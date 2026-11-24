# TSEM final acceptance (one controlled hardware run)

All software parts are implemented and tested automatically (controller, firewall/routing mock + netns, installer incl.
upgrade/rollback/interrupted install, API incl. permissions, GUI, Home Assistant client, Mac acceptance flow). What remains is
this single run on the real router. **Nothing active happens without you typing the confirmation phrase of that step.**

## Start command (on the Mac, in the checkout of this branch)

    sh tools/run-rc3-active-mac.sh --stage "$PWD" accept

Optional separate immediate masquerading repair (read-only without `--apply`):

    sh tools/run-masq-fix-mac.sh --host root --apply

Optional read-only checks of phases 8/9 (without them those lines stay UNVERIFIED):

    TSEM_API_PASSWORD=… sh tools/run-rc3-active-mac.sh --stage "$PWD" --api-user root \
        [--api-url http://10.20.0.1] [--gui-url http://10.20.0.1:8080] \
        [--ha-url http://HA:8123 --ha-token-file ~/ha.token] accept

## Phases and confirmations

| # | phase | active? | phrase |
|---|---|---|---|
| 1 | read-only preflight, node identity check | no | – |
| 2 | backup on the router + verified copy on the Mac, stage of this checkout (side directory) | writes a backup/copy only | `BACKUP`, `STAGE-RC3` |
| 3a | **masquerading check/repair (separate)**: read-only `tsem-masq check`; if LAN → tailscale0 NAT is inconsistent, a repair (backup, `masq=1`, one nat rule, no firewall reload, kill switch untouched) needs its own phrase | only with the phrase | `FIX-MASQ` (only if drift) |
| 3 | install/upgrade (core + api + gui; journaled; user config/intent/remote-site kept; rpcd reload) | yes | `WIRE-RC3` (after the watchdog is armed and proven) |
| 4 | **DIRECT return path proven before anything active**: staged controller simulated (german → direct, both nodes down → BLOCKED, never automatic direct), tools, hook, recovery script, verified backup | no | – (runs before step 3; a FAIL stops the run, nothing was changed) |
| 5 | controller + exit nodes (identity, reachability) | no | – |
| 5b | **DIRECT recovery path on the live router**: `tsem set direct`, then the router's own Internet over the WAN must work, and this computer (as a LAN client) must reach the Internet too (`mac.direct`; without a LAN-client path this is NOT TESTED, never PASS). A FAIL stops the run; no german test starts | yes (opens the kill switch for seconds) | `PROVE-DIRECT` (after `WIRE-RC3`, before `RUN-TESTS`) |
| 6 | active routing/firewall tests t00..t08 | yes | `RUN-TESTS` |
| 7 | hardware switch integration + you flip the switch OFF/ON | yes | `SWITCH-ON/OFF`, `INTEGRATE-SWITCH`, `FLIP-SWITCH`/`SKIP-SWITCH` |
| 8 | API + GUI: router-side `tsem-api-check`, then from this computer (unauthenticated access refused, login, authenticated read + a no-op write, GUI file served) | no (the write is a no-op request) | – |
| 9 | Home Assistant entities vs. router (as far as `--ha-url`/token exist) | no | – |
| 8b | **optional** native GL.iNet GUI (`--native-gui`): adds menu entry/view/RPC bridge only, journaled, rolled back on any failure; then from this computer: view served, unauthenticated DIRECT refused and mode unchanged, and **you attest** in the GL.iNet UI that the entry sits below Tailscale and opens without a LuCI login | yes (adds files) | `NATIVE-GUI`, then `NATIVE-OK`/`NATIVE-SKIP` |
| 10 | report with the PASS/FAIL/UNVERIFIED matrix | no | – |

The order on the Mac is 1, 2 (prepare), then the verification of step 4 right after the read-only checks and **before** the
`WIRE-RC3` prompt; the masquerading check (3a, see docs/masq.md) comes right after the watchdog is armed and before `WIRE-RC3`; then 3, 5b, 6, 7, 8, 9, 10.

**tsem-masq is opt-in.** The default install (`core,api,luci-gui`) installs no masquerading component and never writes
`firewall.tailscale0.masq` or `tailscale.settings.*`. Use `--components core,api,luci-gui,masq` only if the firmware resets masquerading again.
On `root` the read-only diagnosis showed `masq=1` everywhere and an active MASQUERADE rule, so it is not needed.

**Verdict and exit code.** The run ends with `ACCEPTANCE COMPLETE` (exit 0) only if every acceptance criterion has a PASS line.
A skipped switch test, an unread Home Assistant, an unobserved DIRECT or any FAIL gives `ACCEPTANCE INCOMPLETE` and exit code 4:
the router is then wired and operating, but the run is not a successful acceptance. Recovery without any GUI: `docs/emergency-recovery.md`.

On any FAIL the run stops, saves a diagnostic bundle on the Mac (`~/tsem-rc3-active/diag-bundle-…`), runs the recovery
(removes test faults, `tsem reapply` from the saved mode, `tsem tick`) and leaves the guard closed. It **never** switches to
DIRECT by itself; `direct` is a separate command with its own phrase (`OPEN-KILLSWITCH`).

## What stays UNVERIFIED unless the run shows it

Hardware switch call convention and boot position, a real outage of the exit nodes (faults are simulated), a real reboot,
IPv6 of every client, remote-site host reachability, LuCI on the GL firmware (`mac.gui.served`), the API through the GL web
server (`mac.api.reachable`), Home Assistant in a real instance. Simulated or mock tests are never reported as hardware evidence.

## Mapping to the 13 steps of the order

| order step | where in this run |
|---|---|
| 1 read-only preflight | phase 1 (now incl. section 12 "GL.iNet web UI architecture") |
| 2 prerequisites and compatibility | phase 1 + `verify-prepared`; the native prerequisites are checked by the installer itself and refused when missing |
| 3 backup and restore preparation | phase 2 |
| 4 controlled DIRECT return path | phase 4 (before anything active) |
| 5 install and upgrade | phase 3 (core + api + luci-gui); native-gui is its own confirmed step 8b |
| 6 native GUI and LuCI | phase 8 (LuCI served) and 8b (native, only with `--native-gui`) |
| 7 API and permissions | phase 8 |
| 8 exit nodes and egress | phases 5, 6 (t01, t02) |
| 9 failover and fail-closed | phase 6 (t02, t03) |
| 10 hardware switch | phase 7 |
| 11 Home Assistant | phase 9 (as far as `--ha-url`/token exist; a real HA instance is not available to the tests) |
| 12 persistence without an uncontrolled remote reboot | phase 6 `persist-check` (boot link, intent, hooks: configuration only; no reboot) |
| 13 report | phase 10 |

With the native GUI: `sh tools/run-rc3-active-mac.sh --stage "$PWD" --native-gui accept` (optional checks as above).
Details of the native GUI, its gate and what stays UNVERIFIED: `docs/native-gui.md`.

## Two verdicts

The report ends with **ROUTER ACCEPTANCE COMPLETE/INCOMPLETE** (exit code 4 when incomplete) and a separate line
**FULL PRODUCT ACCEPTANCE PASSED/NOT PASSED**. The second needs a complete router acceptance *and* the Home Assistant criterion
(`ha.entities`) with a PASS line. Home Assistant that was not tested never counts as PASS; a passing router is still reported as passed.
Home Assistant setup, backup and rollback: `docs/home-assistant-install.md`.
