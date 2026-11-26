# TSEM 1.0.0: final report (software complete, hardware acceptance pending)

**Statement of completion (read this first).** All requirements that can be implemented and proven without the router are implemented and proven below. The Definition of Done also requires an installation, reboot, failover and recovery run on the GL-MT3000 with firmware 4.11.0, the physical switch, both GUIs on the real firmware, and a real Home Assistant on the production host. **None of that has been done, so the Definition of Done is NOT met and this release is NOT declared error-free or production-ready.** Section 6 lists exactly what the hardware run must show. A `NOT TESTED` in this document never means `PASS`.

Zusammenfassung (Deutsch): Alle Anforderungen, die ohne den Router umsetzbar und beweisbar sind, sind umgesetzt und mit echten Netzwerk-Tests belegt (Kernel-Netfilter in Namespaces, IPv4 und erstmals IPv6). Fehler F01 bis F07 sind behoben (F06 war kein Defekt, sondern eine unsichtbare Hysterese, jetzt sichtbar gemacht). F08 ist durch eine ehrliche Matrix geschlossen: Was nur der Router zeigen kann, steht als Abnahmeschritt da. Die Definition of Done ist erst nach dem Hardwarelauf erfüllt.

## 0000. v1.1 work in progress (branch `feat/v1.1`, not released)

Automated suite on this branch (dash and bash, each 574 passed / 0 failed after the last fix; netns IPv4 59/0, IPv6 7/0; the exact CI
ShellCheck command clean). **Not yet run on real hardware** (the GL-MG1300 was not reachable when this was written): treat v1.1 as untested on routers
until the regression below has been repeated.

| Feature | State |
|---|---|
| Management over a WAN-side private network while protected (`TSEM_ADMIN_SUBNETS4`, `setup.sh --admin-subnet`) | tested with generated rules; the routing side relies on Tailscale's LAN-access rules (as on the GL-E5800) |
| `tsem-notify` (ntfy / webhook on failover, BLOCKED, recovery; queued while the kill switch is closed) | tested with a `curl` stand-in; **no real message was sent** |
| `tsem backup` / `tsem restore` (settings only) | tested, hostile archives refused |
| Ordered exit node list, up to 8 (`TSEM_NODES`), failover walks the ranks, auto-return to the best healthy rank, `setup.sh --fallback`, GUI/LuCI/HA show all nodes | tested with 2 and 3 nodes in the mock suite; the older two-key config and an older running failover state still load. **Hardware regression to repeat:** EXIT, failover (also with an unreachable node in the middle of the list), auto-return, BLOCKED, DIRECT, reboot |

CI note: the GitHub unit job runs the suites as root (one test requires it) and test stubs must carry the executable bit in git.

## 000. Update 2026-11-24 (evening): release `ddc9096`, three routers on real hardware

Code commit `ddc9096` (release `tsem-1.0.0-ddc9096`, reproducible). Full automated run on exactly this tree: dash 552/0, bash 552/0, netns IPv4 59/0, IPv6 7/0, shellcheck clean. Exit nodes are shown and saved under their tailnet name (the name Tailscale shows), the machine's hostname is accepted as a second name.

| Router | What was run | Result |
|---|---|---|
| GL-MG1300 ("Mango 2"), fw 4.11.1 | full regression on `ddc9096`: DIRECT, EXIT, failover, automatic return to the primary, BLOCKED, back to DIRECT | all passed; BLOCKED: router cannot reach 1.1.1.1; selftest 0 failed / 0 warnings |
| GL-MT3000, fw 4.11.x | the same regression on `ddc9096` | all passed; selftest 0/0. The public address behind the secondary was empty in this run (lookup right after failover), the egress proof itself passed |
| GL-E5800 (Mudi 7), fw 4.10.3 | installed with `--adopt-exit-node` (it already used an exit node set in GL.iNet's page) | setup SUCCESS: straight into exit mode, never through DIRECT, GL.iNet page stops setting its own exit node. Primary egress failed once right after the switch, failover to the secondary worked. |
| GL-E5800, kill switch | a simulated LAN client (network namespace on `br-lan`) through the forward path, with nft flow offloading active | EXIT: the client leaves through the exit node (same public address as the router). BLOCKED: client TCP, ping and DNS fail, the router's own traffic fails. An already established download stopped growing within seconds of BLOCKED. Back to EXIT after a few minutes. |

Things found and worth knowing:
- **The Mudi's management address on its WAN side stops answering in exit mode** (it is reached through the Wi-Fi uplink, i.e. a private WAN subnet whose replies would go into the tunnel). Reach it from the LAN side or over Tailscale. This is the same property as every router in exit mode: only the LAN and Tailscale are management paths.
- The Mudi's own DNS resolvers are private addresses behind the uplink: selftest warns, and the router does not use them in exit mode.

Not proven:
- The simulated client does not use the Qualcomm IPA hardware path. A real Wi-Fi client on the Mudi has not been tested; treat the Mudi as **experimental**.
- GL-X3000 (offline), CRITICAL push on phones, `hw_at_boot=switch`, a reboot regression with this release on the Mango, and the one non-reproducible dash failure (see below) remain open.

## 00. Update 2026-11-24: second router (GL-MG1300 "Mango 2") and the firmware-upgrade case

Code commit `95f4c5e` (first part of this section; later changes below) (release `tsem-1.0.0-95f4c5e`, built twice, identical, MANIFEST 0 deviations). Installed on the GL-MG1300 (firmware 4.11.1, mipsel, BusyBox) and on the GL-MT3000.

| Area | Result |
|---|---|
| Automated suite on this tree | dash 541/0, bash 541/0, netns IPv4 59/0, IPv6 7/0, shellcheck clean, bundle in sync |
| Install on a router type it was not built on | works; setup detects the missing `ip6tables`, installs it with opkg and records it in `/etc/tsem/deps` |
| Node names | resolved from Tailscale at setup, nothing hard coded (short peer JSON form of tailscale 1.92 is parsed; BusyBox awk verified) |
| Firmware upgrade 4.10.1 -> 4.11.1 | TSEM restored by `tsem-restore`; opkg packages are removed by the firmware (found: ERROR in DIRECT) |
| Reboot with `ip6tables-nft` removed (simulates the upgrade) | **Found a defect in `95f4c5e`'s predecessor**: guard "inconsistent" and state ERROR for ~3.5 minutes although DIRECT worked. Fixed in `95f4c5e` (open without ip6tables is healthy; protected states stay fail closed). Re-test on `95f4c5e`: no ERROR in the log, package reinstalled by `tsem deps` after ~3.5 minutes, selftest 0/0. Live status during the first minutes of that second boot was not sampled. |
| Hardware switch on the GL-MG1300 (`switch-button func=tailscale-de`, set automatically by setup) | pressed: `set german` accepted, BLOCKED -> CONNECTING_PRIMARY -> PRIMARY_ACTIVE in about 60 s (egress proof 1.1.1.1), no leak; released: back to DIRECT/open. Public address in exit mode was not read on the router in this run. |

Later changes on 2026-11-24 (code commit `c5f109c`, full automated run on exactly that tree: dash 549/0, bash 549/0, netns IPv4 59/0, IPv6 7/0, shellcheck clean):
- An open guard without `ip6tables` is healthy (no IPv6 rule of ours can exist); `_fw_apply` no longer calls `ip6tables-restore` then. Protected modes without `ip6tables` stay fail closed.
- The setup detects an exit node the router already uses (GL.iNet's own Tailscale page). Without a decision it stops before changing anything; `--adopt-exit-node` goes straight to the exit mode (never through DIRECT), hands over the GL.iNet setting after success and gives it back on uninstall; `--ignore-existing-exit-node` accepts direct traffic. Found by reading a GL-E5800: `gl_tailscale` re-applies its own exit node on every interface event, which would fight the failover.
- The GL-E5800 (no hardware switch) gets no switch hook; every other model is unchanged.
- The status reports `active_exit_name`, `primary_name`, `secondary_name`; the Home Assistant entity and the LuCI page show the node name.

Known and open:
- **GL-E5800 (Mudi 7): read only so far, NOT installed, NOT tested.** Read: firmware 4.10.3, OpenWrt 23.05.4, aarch64, fw4 with iptables-nft, dual WAN (Wi-Fi repeater and cellular) with multiwan "balance", software flow offloading (nft flowtable) and Qualcomm IPA offload. Whether the kill switch holds against these is **unproven** and needs a real client test.
- The GL-MT3000 selftest shows one warning (loaded fast-path modules `shortcut_fe`, removed by TSEM when the guard closes); exit mode was not re-tested on the GL-MT3000 with this release.
- One automated dash run once failed a Mac-runner test (rc 1 instead of 4) and passed in 3 repeats and in every later full run; the cause is not known.
- CRITICAL push on phones, `hw_at_boot=switch` and the GL-X3000 are untested.


## 0. Update 2026-11-23 (supersedes the hardware status in the statement above)

Status after the hardware acceptance on a GL-MT3000 (firmware 4.11.0, then 4.11.1) and the real Home Assistant 2026.11.2 (code commit `a61e6fe` plus the `setup.sh` legacy-rule warning).

| Area | Result |
|---|---|
| Exit mode, failover, BLOCKED, switch back to DIRECT (GUI) | PASS on the router, observed by the user |
| Hardware switch (on/off) and reboot in exit mode with policy `last` | PASS. Policy `switch` (hardware always wins): unit tests only, **NOT TESTED on hardware** |
| Firmware update 4.11.0 -> 4.11.1 with automatic restore (`/etc/tsem/last-restore`: all four components restored) | PASS |
| Native GUI (info tiles, failover look, public address via myip.wtf, settings, up to 8 released networks) | PASS, observed by the user |
| Home Assistant: integration setup (port auto-detection), entities, action button, dashboard section, push to both iPhones | PASS. **CRITICAL push in the BLOCKED case: NOT TESTED on the phones** |
| Other routers (Mudi 7, Mango 2, travel router) | **NOT TESTED** (offline) |
| Full automated run on the current tree | unit dash 526 passed / 0 failed; unit bash 525 passed / **1 failed**; netns IPv4 59/0, IPv6 7/0; ShellCheck and bundle check clean. The one failure (`test_f07_mac_stops_after_a_refused_test_and_does_not_claim_a_disarm`, timing-sensitive) passed 3 of 3 times when run alone: **treated as flaky, not yet fixed** |

Second router, GL-MG1300 ("Mango 2", firmware 4.10.1, MIPS, BusyBox awk, nft-based iptables), 2026-11-23, release `4819546`: install PASS after two real findings (both fixed): (1) `ip6tables` was missing while IPv6 is enabled in the config, the self test refused and the setup rolled back cleanly (fix on the router: `opkg install ip6tables-nft`); (2) tailscale 1.92 reports peers in a short form (no HostName/Online), so the node scan found nothing, then a bare brace in the new awk pattern broke BusyBox awk (tests now also run with BusyBox awk). On that router: node identity check PASS, exit mode PASS (exit IP in Germany), manual failover and automatic return PASS, BLOCKED (nonexistent exit node) PASS: kill switch active, no Internet for the router, tailnet access kept, restored to DIRECT. **NOT TESTED there:** reboot, hardware switch (toggle button must be set to the custom function), GUI. Firmware 4.10.1 is the newest listed for this model on GL.iNet's status page; the router's own update check was not seen.

Open before publication: replace the `github.com/mompl/...` placeholders, test on a second router model. (Done in 2026-11-24: the HA `Active exit node` entity shows the Tailscale node name; the address is the attribute `address`; status has `active_exit_name`, `primary_name`, `secondary_name`.)

## 1. Findings F01 to F08

| ID | Root cause (found) | Fix | Evidence |
|---|---|---|---|
| F01 BLOCKED lets router HTTPS out | `converge blocked ''` never cleared the exit node, so tailscale's default route in table 52 stayed and `TSEM_OUT` lets everything through `tailscale0`. Reproduced: old code shows `exit_node=100.64.0.10` in BLOCKED. The path was the VPN tunnel of the unusable node, **not the WAN**; BLOCKED still must not allow it | `tsem` clears the exit node when the target is BLOCKED without a node (closing before clearing); CONNECTING keeps the node so the probe can run | `s_f01_blocked_router_cannot_use_the_tunnel_default_route`, `s_f01_explicit_blocked_mode_clears_the_exit_node`, `s_f01_exit_node_that_cannot_be_cleared_never_opens_the_wan`, IPv6 `s6_router_own_ipv6_is_closed_in_blocked_and_open_in_direct`. The scenarios fail against the RC5 code (run with `OLD=1` in the helper) and pass now. A control proves the router really uses the tunnel while active |
| F02 route in table 52 in BLOCKED | same cause: the route existed because the node stayed selected. Packets could not be forwarded over it (the forward chain only allows tailnet destinations in BLOCKED), but the router's own traffic could use it | same fix; the test checks the packet path and that no default route remains, not just the route | same scenarios; client and router paths checked |
| F03 DNS | the router's resolvers were ISP resolvers from the WAN; in GERMAN router traffic leaves through the exit node, which cannot reach them: timeout. Tailscale DNS stays off (not enabled blindly) | nat/OUTPUT chain `TSEM_DNS_OUT`: router-own port-53 traffic goes to `TSEM_DNS_ROUTER` (default 1.1.1.1, configurable), reachable through the exit node; BLOCKED and DIRECT unchanged; underlay/tailnet/LAN exceptions | `s_f03_*` (5 scenarios incl. the negative control that reproduces the timeout, failover, BLOCKED, marked DNS, repair after a firewall reload, teardown). `docs/rc/dns-ipv6.md` |
| F04 hardware switch not integrated | the RC5 install kept the old prototype, so no event ever reached tsem; the position was never stored across a reboot | hook installed by default (opt-out `--keep-gl-hook`), hook accepts `$1`/`action`/`ACTION`, last position kept in flash (`persisted`), optional readers (`TSEM_HW_GPIO_VALUE`, `TSEM_HW_STATE_FILE`), `tsem hw-probe`, selftest checks hook and toggle-button setting, status shows source and mismatch | `tests/t_hook.sh` (F04 tests), `tests/t_install.sh`, `s_f04_selftest_checks_the_hardware_switch_hook`. **Firmware behaviour is NOT verified** (see 6) |
| F05 autostart | boot links were created only with `--enable`, which the flow did not use | links created by default (`--no-enable` opts out), verified after creation (install aborts and rolls back if they are missing), selftest FAILs without them | `test_f05_autostart_is_default_verified_and_can_be_skipped`, `s_f05_selftest_checks_the_boot_link`, RC4->Final upgrade test. A real reboot is NOT TESTED |
| F06 primary reachable, fallback stays | **not a defect in simulation**: return needs `TSEM_RETURN_N` successes, `TSEM_DWELL` seconds and an expired backoff (up to 300 s after repeated failures), polled every 15 s. It looked stuck because nothing said so | `return_wait` in `tsem status` (JSON and key=value), shown in LuCI and the native GUI: `successes:A/B,dwell:Ns,backoff:Ms`, `disabled`, `primary_not_usable` | `s_f06_*`: return with a direct path and with a DERP-only primary within the bound, the wait is explained, `TSEM_AUTO_RETURN=0` keeps the secondary |
| F07 watchdog and runner | the Mac runner sent no keepalive while a person read and typed the confirmation, so the deadline passed and the watchdog fired and disarmed itself; the router script then refused (`not armed`), but the runner went on, ignored the refusal and offered DISARM for a watchdog that no longer existed | `recovery-ensure` reports armed/fired/dead/absent; the runner keeps the watchdog alive while waiting, checks it before the question and again before the test, re-arms a dead one with the full verified routine, stops after a REFUSED test, and offers DISARM only for a running watchdog | `test_f07_*` in `tests/t_rc3_active.sh` |
| F08 NOT TESTED entries | the matrix could not distinguish "cannot be done here" from "not done" | section 5 and 6 below | this document |

## 2. Requirements A to E: status

| | Requirement | Software | Hardware |
|---|---|---|---|
| A | DIRECT / GERMAN / BLOCKED, failover and return, DERP, no WAN fallback, DNS | PASS (netns IPv4 and IPv6, unit) | NOT TESTED |
| B | physical switch | hook, persistence, status, readers, selftest PASS; **firmware calling convention unverified** | NOT TESTED (acceptance step `hw.event`) |
| C | native GL.iNet GUI under APPLICATIONS (main GUI, installed by default) and LuCI (fallback) | both views tested against the real API plugin and controller; the native GUI uses an undocumented firmware interface, installer, menu entry and bridge tested on a fake GL.iNet layout only | NOT TESTED on firmware 4.11.0 |
| D | Home Assistant | client and entity logic against the real rpcd plugin; see section 4 | NOT TESTED in the production Home Assistant installation |
| E | boot, persistence, restarts | boot fail-closed, tailscaled restart, firewall reload, WAN change, reboot simulation PASS | real reboot NOT TESTED |

## 3. Test evidence (code commit `7c57204`, run in WSL2 Ubuntu 24.04, kernel 6.6 with Netfilter and IPv6)
| Suite | Result |
|---|---|
| Unit and mock suites `tests/run.sh`, dash | **494 passed, 0 failed, 0 skipped** |
| Unit and mock suites `tests/run.sh`, bash | **494 passed, 0 failed, 0 skipped** |
| Packet path in network namespaces, IPv4 (real kernel iptables) | **57 passed, 0 failed** |
| Packet path in network namespaces, IPv6 (real kernel ip6tables) | **7 passed, 0 failed.** First execution ever: the suite had never run before; three defects of the test setup (DAD, V6ONLY responders, neighbour warm-up) were repaired |
| Home Assistant integration in the REAL Home Assistant core 2025.1.4 (`homeassistant/tests_real`) | **8 passed, 0 failed** |
| ShellCheck 0.9.0 with the CI's exact flags over all 69 shell files, `luac -p` of the Lua bridge, native bundle in sync | **0 findings** |
| RC4 -> 1.0.0 upgrade against the real RC4 install tree (`tests/t_upgrade.sh`) | 2 passed (config and intent byte-identical, hook and boot links integrated, rollback to the exact RC4 state, interrupted upgrade recovered) |
| Gitea CI | see the PR; `static` green on this commit; `unit` queued on the runner at the time of writing |
The new scenarios fail against the RC5 code where they should (F01/F02, F03 negative control): the packet tests prove the defect and the fix.

## 4. Home Assistant (requirement D)
Tested inside the real Home Assistant core (not a stand-in): config flow with error mapping, device and 14 entities (mode switch, operating mode, controller state, active exit node, failover status, both exit-node checks, hardware switch, IPv6/DNS protection, kill switch, leak risk, mode reached, controller connection), switching through the real rpcd plugin and controller (the controller records `source=ha`), changes made by CLI and by the switch hook arrive after the next poll (15 s), a router that goes away turns the entities unavailable while the connection sensor reports it, reload and restart recover the state, a read-only router user cannot change anything. **Not tested:** the installation in the Home Assistant (hardware step 5).

## 5. Release artifacts (built from the tree of commit `7c57204`, twice, identical)
```
eb80a1495e75deafceb38bd1056f688851918f9a681a1979fc1e73eddf337a01  tsem-1.0.0-7c57204.tar.gz
d5e3ad0b37a624e4167abe8ff4e4d28cffecc864a85482dddf66305381527a36  tsem-ha-1.0.0-7c57204.tar.gz
```
Git tree id `ff3c159de2148daa92421bc5c963d3575cc74511`. The two builds produce byte-identical `SHA256SUMS`; `sha256sum -c` and `MANIFEST.sha256` verify after extraction. Rebuild: `git archive 7c57204 | tar x -C DIR && sh DIR/tools/build-release.sh --version 1.0.0-7c57204` (GNU tar required). Later commits on this branch change only this report. The earlier rc4/rc5 archives must not be used (D11).

## 6. What only the router, Home Assistant and a person can show (remaining acceptance)
1. Install on the GL-MT3000 (`sh tools/run-rc3-active-mac.sh --stage "$PWD" accept`), reboot with the switch at each position, `tsem status` after boot (`hw_source=persisted`, mode from the intent).
2. `hw.event`: `echo trace > /etc/tsem/hook.mode`, move the switch both ways, read `logread | grep tsem-hook`: shows the real calling convention; then check `uci show switch-button` selects `tailscale-de`. If the firmware calls the hook differently, the hook is the only file to adapt.
3. t01 to t08 of the acceptance run, in particular `t01` (DERP-only primary), `t03` (F01/F02 on the real kernel), `t04` (DNS with the real ISP resolvers), `t05` (IPv6 on the router), `t07`/`t08`.
4. The native GUI on firmware 4.11.0: APPLICATIONS > Tailscale Exit Manager is visible (desktop and phone), opens without a second login, shows the state, switches DIRECT/GERMAN, survives a reload and a reboot (acceptance step NATIVE-GUI, now part of the run; `--no-native-gui` skips it). LuCI is only the fallback.
5. Home Assistant on the production host: install the component, add the integration, switch DIRECT/GERMAN, restart both.
6. CPU and memory over a day (not measured anywhere).
