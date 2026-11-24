# tsem – Tailscale Exit Manager (Release Candidate 0.1.0-rc2)

Target: GL.iNet GL-MT3000 "root" only (FW 4.11.0, OpenWrt 21.02, fw3 + iptables-legacy, Tailscale 1.92.5).
Exit nodes: primary `exit-a` (100.64.0.30), secondary `exit-b` (100.64.0.31), set in `/etc/tsem/tsem.conf` and checked by name+IP+online+exit-node-approved (`tsem verify-nodes`).

**Status: RC, validated with mocks and network namespaces only. Nothing has been run on a real MT3000.**
Do not install productively before working through [test-plan.md](test-plan.md).

## One controller
`/usr/sbin/tsem` is the only component that touches firewall, routes or the Tailscale exit node.
Hardware switch (`tsem-switch.sh`), Home Assistant (`tsem-mqtt`, MQTT only), CLI and the daemon all call
`tsem set|failover`. Calls are serialised by a lock; the desired state is a single atomic file (`/etc/tsem/intent`).

| Command | Purpose |
|---|---|
| `tsem set german\|direct [--source X] [--no-wait]` | switch on/off (ON = exit manager, OFF = plain internet) |
| `tsem failover auto\|off\|now` | auto-failover on/off, or trigger a manual failover now (refused if the other node is not usable) |
| `tsem status [--json]` | state, kill switch, leak_risk (rc 1 if a leak is possible) |
| `tsem diag` | read-only evidence (DNS, rules, hook) |
| `tsem selftest` | read-only environment checks for the router |
| `tsem teardown` | remove all tsem rules (used by uninstall) |

## Kill switch (fail closed)
Forwarded LAN traffic has two independent layers (the tests prove this by disabling each); router-originated traffic has one (chain `TSEM_OUT`, see [router-egress.md](router-egress.md)):
1. policy routing: `ip rule` 5280/5290 for LAN ingress, `prohibit` after Tailscale's table 52;
2. netfilter chain `TSEM_FWD` at FORWARD position 1: only LAN→tailscale0 (and LAN→LAN) are returned, everything else `REJECT`. No ACCEPT, no ESTABLISHED/RELATED shortcuts.
Router-originated traffic is filtered by `TSEM_OUT` (OUTPUT, IPv4+IPv6): only loopback, tailscale0, LAN/local interfaces, tailscaled underlay (marked, udp + tcp 80/443, never DNS), DHCP/ND and optional NTP are allowed. Everything else is rejected, also with both exits down.
fw3 reload flushes FORWARD → fw include + hotplug + daemon tick re-assert the hook; layer 1 covers the gap. Drift is detected by checksum and repaired.

## State machine
DISABLED, CONNECTING_PRIMARY, PRIMARY_ACTIVE, CONNECTING_SECONDARY, SECONDARY_ACTIVE, DEGRADED, BLOCKED, ERROR.
Health = real egress through the exit node (not just a Tailscale ping). Hysteresis: `FAIL_N` failures to leave, `UP_N`
successes to accept, `RETURN_N` successes before returning to primary, exponential backoff, flap guard. Both exits down → BLOCKED (traffic stays blocked, never opens).

## Docs
[router-egress.md](router-egress.md) · [boot-sequence.md](boot-sequence.md) · [operations.md](operations.md) · [install-rollback.md](install-rollback.md) · [config.md](config.md) · [dns-ipv6.md](dns-ipv6.md) · [home-assistant.md](home-assistant.md) · [test-plan.md](test-plan.md) · [risks.md](risks.md)

## RC3 (0.1.0-rc3)
- Intent: `tsem intent-check` / `intent_reason` in status; installer keeps (and copies) an invalid intent, never writes DIRECT silently.
- Layer 1 deny action: `prohibit`, falling back to `unreachable` / `blackhole` (`TSEM_RT_DENY`), verified by reading the rule back; selftest no longer reports the false `ip-rule-prohibit` warning.
- Fast path: SFE/shortcut-fe modules are removed when the guard closes (`TSEM_FASTPATH=unload`, default) or make the guard "inconsistent" (`refuse`); fw3 flow offloading is detected and reported.
- Boot: a failed protection setup is logged as CRITICAL, marked (`boot_failed=yes`, `leak_risk=true`) and retried by the daemon; it is no longer ignored.
- DNS: resolver classification in `selftest`/`diag`; `0.0.0.0` is reported as UNVERIFIED with kernel route evidence, not interpreted.
- Acceptance: `tools/tsem-rc3-acceptance.sh` (read-only) + `tools/run-rc3-acceptance-mac.sh`; activation and rollback: `rc3-activation.md`.

## RC3.1 (0.1.0-rc3.1)
Found on the real GL-MT3000 (hardware acceptance, 2026-11-17): with the guard `german`, internet egress through both exit nodes works, but tsem rejected the primary (reachable only through a DERP relay at ~230 ms) and, in the failed run, both nodes.
- Probe tolerance: `be_probe_reach` tries `tailscale ping` up to 3 times (4 s each); `be_probe_egress` runs two rounds over all probe URLs. A node that never answers still fails; fail-closed is unchanged (no success, no `german` guard).
- Visibility: every probe verdict is logged once per change (`logread | grep "tsem: probe"`), e.g. `probe primary: rejected: node is offline` or `probe primary: egress FAILED`. Before this, a rejected node left no trace.
- The version is bumped so that the acceptance tool's wire step installs the fix on a router that already runs 0.1.0-rc3 (the tool skips wiring when installed == staged version).
- Mac tool: the abort message names the way back to the internet (`tsem set direct`, the user's decision) and where to read the reason.
