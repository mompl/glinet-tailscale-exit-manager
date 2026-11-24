# TSEM 0.2.1: defect audit, traceability, release readiness

Rule applied throughout: **CI or simulated is not hardware-validated.** Columns say what actually ran and where.
PASS = executed. NOT TESTED = could not be executed with the infrastructure that exists (no router, no real Home Assistant, no IPv6 kernel here). HW = only the real GL-MT3000 can show it.
Evidence comes from three places: CI (Gitea Actions: static, unit dash, unit bash, collector), a local run of the same suites in the cloud sandbox (bash 483/0, collector 403/0, discovery 121/0, IPv4 netns 44/0), and nothing from hardware.

## 1. Defect audit

| # | Severity | Finding | Root cause | Resolution | Evidence |
|---|---|---|---|---|---|
| D1 | **Critical** (confirmed on hardware, RC4) | Primary `exit-a` reported `primary_probe=unreachable`; the controller stayed on the secondary | `be_probe_reach()` used the exit code of `tailscale ping -c 1`. A node reachable only through a DERP relay prints `pong from ... via DERP(nue) in 224ms` and still exits 1 (no direct path). | Reachability is decided from the output: a pong line naming exactly this node's address. Identity (ExitNodeStatus), exit-node approval and the real egress proof are separate gates and are unchanged. | `tests/t_probe.sh`: DERP-only (exit 1), direct, peer relay, microsecond latency, pong from another node, no matching peer, timeout, garbage, silent exit 0, invalid address, reach without egress. CI run 439. The fix against the real node is HW. |
| D2 | Medium | The `tailscale ping` test stubs only returned an exit code, so the suite shared the wrong assumption and could not catch D1 | stubs did not mirror the real CLI | `tests/stubs/tailscale` and the `t_probe` stub print what the CLI prints (including DERP-only with exit 1) | CI |
| D3 | Low/Medium | `tsem selftest` always warned about resolver `0.0.0.0` | deliberately never interpreted | PASS only when `ip route get 0.0.0.0` answers `local ... dev lo`; any other answer or an error stays WARN | `tests/t_rc3.sh` (2 tests), CI. On the router: HW. |
| D4 | High (process) | Release credential scan was a silent no-op on busybox | scan errors swallowed | fail-closed portable scan | `tests/t_release.sh` (planted key refused), fixed earlier, CI |
| D5 | Medium | `tools/collect.sh` index wrong on busybox | non-portable constructs | portable | CI collector tests |
| D6 | Medium | CI unit failed on a kernel netfilter test | no CAP_NET_ADMIN in the job | `kernel_skip`: reported NOT RUN, never PASS | CI |
| D7 | Info | `hw_state=unknown`, `hw_source=none` on the router | not a code defect: the hardware-switch hook is wired by the acceptance step INTEGRATE-SWITCH, which was not reached because t01 failed (D1) | repeat the acceptance (section 4) | HW |
| D8 | Info | Fast path (SFE/shortcut-fe/flow offload) | handled: `TSEM_FASTPATH=unload` removes the modules before the guard closes and verifies; `refuse` reports the guard inconsistent | netns scenarios, acceptance t06 | real modules: HW |
| D9 | Info | Tailscale health warning about DNS server reachability | reported by tailscaled, not produced by TSEM; cause not determined | unchanged; acceptance t04 shows DNS behaviour per mode | HW |
| D10 | Low (test infrastructure; not a product defect) | `tests/t_preflight.sh::test_wrapper_stage_is_a_labelled_write...` failed in the cloud sandbox (staging directory left behind); it always passed in CI | **Reproduced and explained.** The test linked whatever `command -v rm` returned into its isolated fake-router PATH. In a sandbox that puts an `rm` guard wrapper first on PATH, that wrapper needs a further `rm` on PATH, finds none in the fake PATH and refuses, so the wrapper's cleanup could not delete the staging directory. The test also counted `/tmp/tsem-pf.*` globally, so stray directories or a concurrent run changed the count. CI (Alpine/busybox) has no such wrapper. The tool under test (`tools/run-preflight-mac.sh`) was correct: with a plain ssh shim it removes its own directory. | `pf_realcmd` resolves real binaries and skips guard wrappers; the stage tests now check the exact directory named in the ssh log. New regression tests: stage removed after a failed preflight run, cleanup never touches a foreign directory and is guarded by the marker file and the name pattern, guard wrappers are never linked into the fake PATH. | Local before the fix: failed deterministically (twice in a row, stray directory left). After: `t_preflight` 68 passed, 0 failed under dash and bash, no stray directories. CI on the fix commit. |
| D11 | Medium (release process) | The earlier rc4 archives were not exact copies of the git tree of their commit (a few files differed) | they were assembled in a sandbox that had no checkout | **disclosed; rc4 must not be used.** rc5 is built from a working tree whose git tree id was verified equal to the pushed commit tree (`git write-tree` against the remote tree) | the build twice yields identical `SHA256SUMS` (reproducibility check), `MANIFEST.sha256` verifies after extraction |

Scope: the confirmed defect, every use of external-command exit codes in the backend, the hardware findings, test stubs, release and CI path. This is **not** a proof that no other defect exists; the remaining risk is concentrated in what only the router can show.

## 2. Requirements → tests

| Requirement | Automated tests (executed in CI) | Hardware |
|---|---|---|
| DIRECT / GERMAN / BLOCKED, never the WAN in GERMAN | `s_german_active_tunnel_only`, `s_both_down_blocked_then_recovers`, `s_boot_without_intent_is_blocked_never_direct`, `t_failover: test_tailscale_down_is_never_direct, test_both_down_blocks_and_never_opens` | t01–t03 |
| Primary `100.64.0.30`, fallback `100.64.0.31`, auto fallback | `t_failover: test_primary_down_fails_over_to_secondary` | t02 |
| Reachability over DERP or direct | `t_probe: test_reach_*` | t01 |
| Identity, approval, egress proof before a node is used | `t_failover: test_reachable_peer_without_egress_is_never_accepted, test_no_advertise_exit_node_is_ever_used`; `t_probe: test_reach_does_not_replace_egress_proof` | t01 |
| Return to primary with hysteresis | `t_failover: test_return_*`, `test_flapping_primary_does_not_cause_switching` | t02 |
| Kill switch fail-closed (both layers, reload, reboot, tailscaled restart) | netns scenarios (run on ht-dev via `tools/run-netns-vm.sh`, **not in CI**); mock-backend tests in CI | t07, t08 |
| IPv6 does not bypass the kill switch | `netns6_test.py` (6 scenarios) | **never executed**; needs ht-dev; t05 on the router |
| DNS and router-own traffic leak-free | `t_rc3` DNS tests (string/evidence logic in CI); netns DNS scenarios (not in CI) | t04 |
| remote-site routes and `masq=1` untouched | `t_masq` | acceptance masq check |
| Physical switch ON=GERMAN, OFF=DIRECT, consistent state | `t_hook` (hook logic, concurrency, rapid toggling) | **HW only**: the GL firmware calling the hook |
| API, LuCI GUI, native GUI bridge | `t_api`, `t_gui`, `t_native_gui`, `t_install_components` | native GUI is an undocumented firmware interface: HW |
| Home Assistant | `homeassistant/tests` (client against the rpcd plugin and ACL, entity logic), `t_ha` | **not run in a real Home Assistant** |
| Transactional install, backup, rollback, interrupted install | `t_install`, `t_install_components` | acceptance phases |
| Release package, checksums, no credentials | `t_release` | – |

## 3. Requirements → test matrix (PASS / FAIL / NOT TESTED)

"Local" = the cloud sandbox (real Linux kernel with IPv4 netfilter in network namespaces, but not the router's kernel/firmware). Nothing below is a hardware result.

| ID | Requirement | Automated result | Hardware |
|---|---|---|---|
| R01 | Modes DIRECT / GERMAN / BLOCKED; GERMAN never reaches the WAN | **PASS** (mock suites; netns `s_german_active_tunnel_only`, `s_transition_direct_to_german_no_leak`, `s_direct_baseline`) | NOT TESTED |
| R02 | Primary `100.64.0.30`, fallback `100.64.0.31`, automatic failover | **PASS** (`t_failover` 40, netns `s_failover_with_no_leak`) | NOT TESTED |
| R03 | Reachability decided correctly for DERP-only, direct, relay | **PASS** (`t_probe` 17 tests) against a stub that mirrors the real CLI output | NOT TESTED against the real node |
| R04 | Identity, approval and egress proof gate every node | **PASS** (`t_failover`, `t_probe: test_reach_does_not_replace_egress_proof`) | NOT TESTED |
| R05 | Return to primary only with hysteresis, no flapping | **PASS** (`t_failover: test_return_*`, flapping test) | NOT TESTED |
| R06 | Kill switch fail-closed: both layers, firewall reload, tailscaled death/restart, reboot, empty/invalid intent | **PASS** locally: IPv4 netns suite 44/0 (e.g. `s_layer1_alone_*`, `s_layer2_alone_*`, `s_firewall_reload_*`, `s_tailscaled_dead_blocks`, `s_tailscaled_restart_*`, `s_reboot_fail_closed_*`, `s_boot_without_intent_*`, `s_rc3_invalid_intent_*`); not in CI | NOT TESTED (t07, t08, reboot) |
| R07 | IPv6 cannot bypass the kill switch | rule logic in mock suites **PASS**; packet-path suite `netns6_test.py` **NOT TESTED**: the sandbox kernel has no IPv6 (`/proc/net/if_inet6` missing); it needs `tools/run-netns-vm.sh` on `ht-dev` | NOT TESTED (t05) |
| R08 | DNS and router-own traffic leak-free | **PASS** locally: netns `s_dns_redirect*`, `s_router_own_*`, `s_router_underlay_dns_exception_is_opt_in`; evidence logic in `t_rc3` | NOT TESTED (t04) |
| R09 | Fast path (SFE/offload) unloaded before the guard closes | **PASS** netns `s_rc3_fastpath_*` with simulated modules | NOT TESTED (t06, real modules) |
| R10 | remote-site routes and `masq=1` untouched | **PASS** (`t_masq` 21, netns `s_extnet_*`, `s_masquerade_untouched_*`) | NOT TESTED |
| R11 | Physical switch ON=GERMAN, OFF=DIRECT, consistent state | hook logic **PASS** (`t_hook` 15: on/off, unknown input ignored, trace mode, idempotence, rapid toggling, no race with API/GUI, `hw_state` recorded as an event); the hook is installed by `install.sh --replace-gl-hook` (`t_install`) | **NOT TESTED**: how the GL firmware calls `/etc/gl-switch.d/*` is unverified; software cannot read the physical position; no polling adapter exists (MT3000 only) |
| R12 | GL.iNet GUI: LuCI view | **PASS** (`t_gui`, `tests/gui/gui_test.js`, `t_install_components`) | NOT TESTED |
| R13 | GL.iNet GUI: native view (undocumented firmware interface) | **PASS** logic only (`t_native_gui` 12: additive install, rollback, bundle in sync, Lua bridge executed with `texlua`, whitelist equals API plugin) | NOT TESTED; optional; firmware interface unverified |
| R14 | API: rpcd plugin, ACL, no login refused | **PASS** (`t_api` 17) | NOT TESTED |
| R15 | Home Assistant integration | **PASS** (`t_ha`, `homeassistant/tests`: client against the rpcd plugin and ACL, entity logic: mode switch, sensors, binary sensors, config-flow errors, diagnostics redaction) against a **minimal stand-in** for Home Assistant | **NOT TESTED in a real Home Assistant** (not installed here) |
| R16 | Install: dry run, additive, idempotent, preserves config/intent, components | **PASS** (`t_install` 26, `t_install_components` 12) | NOT TESTED on the router |
| R17 | Update: upgrade keeps config, intent and remote-site routes, reversible | **PASS** (`t_install: test_upgrade_then_rollback_*`, `t_install_components: test_upgrade_from_rc3_*`, `test_repeated_full_install_*`) | NOT TESTED |
| R18 | Rollback: `install.sh --rollback` | **PASS** (`test_successful_rollback_*`, `test_rollback_without_install_refuses`, `test_rollback_of_an_api_install_*`) | NOT TESTED |
| R19 | Recovery: interrupted/killed install, lost ssh | **PASS** (`test_killed_install_leaves_a_marker_and_recover_*`, `test_rollback_also_handles_a_pending_*`, `test_lost_ssh_session_*`, `test_aborted_install_leaves_clean_system_at_every_failure_point`; Mac side `t_rc3_active`, `t_rc3_accept`, `t_rc3_readonly`) | NOT TESTED (needs the router) |
| R20 | Uninstall restores the system; modified files are kept | **PASS** (`test_full_uninstall_*`, `test_purge_*`, `test_modified_files_are_kept_*`, `test_uninstall_tears_down_guard_before_removing_files`) | NOT TESTED |
| R21 | Release package: reproducible, checksums, no credentials | **PASS** (`t_release`; the rc5 build run twice gives identical `SHA256SUMS`; `sha256sum -c` and `MANIFEST.sha256` verified after extraction) | – |
| R22 | Discovery/collector tools | **PASS** (`tools/test-collect.sh` 403/0, `tools/test-discovery.sh` 121/0) | – |
| R23 | ShellCheck, Lua syntax | **PASS in CI** (not available in the sandbox) | – |

## 3a. Test runs and what could not run

| Suite | Where | Result |
|---|---|---|
| `tests/run.sh` under bash | local, final test tree | 483 passed, 0 failed, 0 skipped |
| `tests/run.sh` under dash | local, rc5 package before the D10 fix | 479 passed, 1 failed (D10, now fixed; `t_preflight` re-run 68/0 under dash and bash) |
| `tests/run.sh` dash + bash, ShellCheck, luac, collector | CI | see the CI run named for the final commit in the PR |
| `tools/test-collect.sh` | local | 403 passed, 0 failed |
| `tools/test-discovery.sh` | local | 121 passed, 0 failed |
| `tests/netns/netns_test.py` (IPv4) | local, real kernel netfilter in namespaces | 44 passed, 0 failed; **not in CI** (no CAP_NET_ADMIN); still to be run on `ht-dev` |
| `tests/netns/netns6_test.py` (IPv6) | NOT TESTED | sandbox kernel has no IPv6; written, never executed |
| ShellCheck / `luac` | NOT TESTED locally (not installed, no package install allowed); executed in CI | – |
| Real Home Assistant, real GL-MT3000, real Tailscale, GL firmware switch events | NOT TESTED | no access / not allowed without approval |

## 3b. Release-readiness report

- **PASS:** every suite listed above that could run; no FAIL is open in the executed suites.
- **NOT TESTED:** the whole HW column, IPv6 packet path, real Home Assistant, native GUI on the firmware.
- **WARN:** D9 (Tailscale DNS health warning, not produced by TSEM; cause not determined).
- **rc5 package:** built by `tools/build-release.sh` from a working tree whose git tree id was verified equal to the pushed commit tree (see `docs/release.md`, "Reproducible build"). The version string names that commit. The archives and `SHA256SUMS` are delivered with the report and in the PR comment; they are not stored in git.
- **Production readiness is NOT declared.** Statement: ready for a controlled hardware acceptance run of 0.2.1, not for production, until section 4 passes on the device.

## 4. Hardware acceptance (only what needs the device)
Run from the Mac as described in `docs/release.md`; nothing active happens without the typed phrase.
1. t01: `primary_probe=reach` (not `unreachable`) and PRIMARY_ACTIVE with exit node `100.64.0.30` while the path is DERP-only.
2. t02 failover and return; t03 both nodes down = BLOCKED, no Internet for LAN clients.
3. t04 DNS; t05 IPv6 (no v6 leak in GERMAN/BLOCKED); t06 fast path; t07 firewall reload; t08 tailscaled restart.
4. Hardware switch: flip OFF and ON; `hw_state` and `hw_source=event` appear; mode follows.
5. API, GUI, LuCI show the same mode; Home Assistant (`docs/home-assistant-install.md`).
6. Reboot persistence.
7. Recovery: `docs/emergency-recovery.md`, installer `--rollback` and `--recover`.
