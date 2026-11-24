# Hardware preflight for root (read-only)

`tools/tsem-preflight.sh` checks the GL-MT3000 before anything is installed. `tools/run-preflight-mac.sh` runs it over
SSH (alias `root`) and saves the report on the Mac (`~/tsem-preflight/`).

Read-only guarantee: no install, no file/UCI/firewall/NAT/routing/Tailscale change, no service restart, no switch toggle, no exit-node change, no active
probes, no temp files on the router, no upload. The script is streamed through `ssh ... sh -s` (nothing is copied). The only program it runs from the
repository is the installer's dry run (no option). Secrets are never printed (Tailscale status/prefs are reduced to a few flags). Tests enforce this
(`tests/t_preflight.sh`: call log of all stubs, snapshot of the fake router, static scan for mutating commands).

Result lines: `PASS` checked and fine, `WARN` limitation or incomplete proof, `FAIL` concrete installation obstacle, `SKIP` not runnable or deliberately
left out (`(evidence missing)` = the missing proof matters for the recommendation).

| Recommendation | Rule |
|---|---|
| NEEDS_FIX | at least one FAIL |
| INSUFFICIENT_EVIDENCE | no FAIL, but essential evidence missing (tailscaled/uci/iptables/ip/repo/installer guard not usable) |
| READY_FOR_PASSIVE_INSTALL | no FAIL, no essential evidence missing |

`READY_FOR_PASSIVE_INSTALL` means only: an install WITHOUT autostart, firewall include and hardware-switch replacement looks acceptable.
It is NOT a release for the kill switch or GERMAN mode. Boot window, fw3 reload gap, flow offloading, IPv6 and the switch calling convention
still need the hardware proofs of `docs/rc/test-plan.md`.

Requirements the report treats as FAIL: not OpenWrt, not a GL-MT3000, fw4 or nf_tables iptables, missing required tools, missing
`firewall.tailscale0.masq='1'`, `zone_tailscale0_postrouting` without MASQUERADE or not hooked into POSTROUTING, no enabled LAN to tailscale0
forwarding, a remote-site route (10.30.0.0/24, 10.30.1.0/24, 10.30.2.0/24) missing in table 52, a foreign rule on priority 5280/5290, repository missing,
failed installer dry run, too little RAM/overlay space.

## Section 12: GL.iNet web UI architecture (read-only)

The preflight also reads the GL.iNet UI layout (menu entries and the order under APPLICATIONS, stock view bundle strings, RPC object shape, web ports, LuCI, ubus, keep lists, installed TSEM version) to decide whether `native-gui` can be installed. Missing prerequisites are warnings only; they never block the passive install. See `docs/native-gui.md`.
