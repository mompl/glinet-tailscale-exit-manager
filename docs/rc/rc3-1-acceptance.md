# RC3.1: findings, diagnostics and the controlled hardware acceptance

Status: release candidate. Nothing here is accepted until the Mac-side run below reports PASS for it on the real router.
Simulated tests (fake `tailscale`/`curl`/`ip`, mock backend) prove the logic; they are labelled as simulated and are not hardware evidence.

## What the first hardware run showed

- Egress through both exit nodes works (plain `tailscale set --exit-node`, and under the german guard).
- The primary (`exit-a`) is reachable only through DERP (~230 ms). A single 5 s `tailscale ping` and a single egress request were not tolerant enough; the reason a node was rejected was not logged.
- In the failed run the controller reported SECONDARY_ACTIVE while LAN clients and a router-own request had no Internet. `ok` of a node that is *not selected* is only `tailscale ping` (reachability), never egress. The tool and the status output did not make that distinction visible.
- The physical switch did nothing because the tsem switch hook is installed only by `go-live` (INTEGRATE-SWITCH), which never ran; the GL hook only calls tailscale.
- The root cause of the intermittent egress during the failed run is **not proven**. RC3.1 therefore records the evidence needed to prove it (below) instead of guessing.

## Changes in RC3.1 (src)

- `be_probe_reach`: up to 3 pings (4 s each). `be_probe_egress`: two rounds over all probe URLs; each URL result is classified (`ok|dns|connect|timeout|tls|http|reset|rcN`) and kept in `probe.detail`.
- Every verdict is logged once per change with its concrete reason (`logread | grep 'tsem: probe'`): `rejected: <why>`, `exit node not applied yet`, `egress ok (<per-URL classes>)`, `egress FAILED through exit node <ip>: <per-URL classes>`, `reachable, not selected (tailscale ping only, no egress proof)`, `not reachable`.
- `tsem status` has `primary_probe` / `secondary_probe` (`egress|egress-fail|reach|unreachable|rejected|pending|unknown`) next to `primary_ok` / `secondary_ok`.
- Every `tsem set` is logged: `set <mode> requested by source=<src> changed=<0|1> apply_rc=<n> wait=<n>`.
- Fail-closed is unchanged: a node whose peer answers but has no Internet is never accepted; with no egress anywhere the guard stays `blocked`. A change GERMAN/BLOCKED -> DIRECT only happens by explicit `direct` (CLI or switch OFF).

## Tool changes (tools)

- `tsem-rc3-active.sh`: read-only `diag-bundle`, `nodes-check`, `extnet-check`, `switch-watch off|on`; `t01` samples egress repeatedly (default 6x 5 s) and reports PASS / WARN (intermittent) / FAIL; in acceptance mode `t01` FAILs unless the state is PRIMARY_ACTIVE.
- `tsem-rc3-recover.sh`: the recovery reports `ok` only if a router-own HTTPS request through the active exit node works; otherwise `degraded` (the guard stays closed either way, nothing is opened).
- `run-rc3-active-mac.sh`:
  - `accept` = `prepare` + `final` in one command (fresh backup + stage of this checkout, then the acceptance).
  - `diag` = read-only diagnostic bundle + node check, saved on the Mac.
  - Before any recovery (`abort_recover`) the diagnostic bundle is saved on the Mac first (`diag-bundle-<host>-<stamp>-before-recovery.txt`); the node check gates `final` before anything is changed.
  - After the persistence check: remote-site route check and the hardware-switch step (`FLIP-SWITCH` / `SKIP-SWITCH`).
  - The result ends with an acceptance table: a criterion is PASS only with a PASS line in the report, otherwise FAIL or UNVERIFIED.

## The single start command (Mac)

    sh tools/run-rc3-active-mac.sh --stage <checkout> accept

Typed confirmations, in this order: `BACKUP`, `STAGE-RC3`, `SWITCH-ON|SWITCH-OFF`, `WIRE-RC3`, `RUN-TESTS`, `INTEGRATE-SWITCH`, then `FLIP-SWITCH` (or `SKIP-SWITCH` = hardware switch UNVERIFIED).
Optional environment on the Mac: `AR_EXTNET_HOSTS="10.30.0.1 ..."` (host ping check; otherwise only the routing decision is checked and host reachability is UNVERIFIED), `AR_SWITCH_MAX` (seconds to wait for a flip, default 120).

## Expected behaviour

Success: all criteria in the table are PASS; the router ends in mode german, guard german, an exit node active, the tsem hook and boot link installed, the recovery watchdog disarmed.
Failure: the first FAIL stops the run; the diagnostic bundle is saved on the Mac, then the recovery runs (never opens the kill switch). No Internet for the LAN afterwards means the kill switch is closed; `ssh root 'tsem set direct'` is the user's explicit way out.

## Not verifiable without the real router (UNVERIFIED until the run says otherwise)

- the call convention of the GL firmware for the hardware switch (`switch-watch` proves it end to end); the switch position at boot (it cannot be read by software);
- a real outage of an exit node and a real reboot (faults are simulated, no remote reboot is done);
- the root cause of the intermittent egress seen in the first run (`t01.series` and the diagnostic bundle collect the evidence);
- IPv6 from every client; host reachability inside the remote-site subnets without `AR_EXTNET_HOSTS`.
