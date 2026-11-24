# Risks and open points

- RC2: router-own traffic is protected by ONE layer (TSEM_OUT). Policy routing cannot cover it. If fw3 flushes OUTPUT and the re-assert (fw include / hotplug / tick) is late, a window exists whose size is unmeasured. fw3 flushing built-in chains is assumed from fw3 source, unconfirmed on hardware.
- RC2: boot sequence has no proven leak-free window. See boot-sequence.md; full boot-leak-freedom is NOT claimed.
- RC2: `tailscale status --json` layout (peers, Online, ExitNodeOption, DNSName) and the underlay fwmark are assumed, unconfirmed on 1.92.5. A mismatch fails closed (node counts as unusable), i.e. may cause BLOCKED, not a leak.
- RC2: IPv6 router-own rules have text tests only, no packet tests (sandbox has no IPv6).
- RC2: GL switch calling convention (`$1`=on|off, executable) is community-documented, not official; unconfirmed.
- **Not run on hardware.** Mock + network-namespace (IPv4, own kernel) tests do not prove router compatibility.
- netns suite needs CAP_NET_ADMIN; CI reports SKIPPED (not pass) without it.
- IPv6: rule text only, no packet test.
- `0.0.0.0` resolver unexplained (report unavailable); router's own DNS via WAN is a residual non-client path.
- Unknown until test plan: how GL invokes the switch script, real table-52 return path, tool output formats on 1.92.5, `suppress_prefixlength` support, BusyBox flock/timeout/nslookup.
- If the router itself advertises as exit node, `--exit-node` conflicts.
- Paths may collide with PR #6 (M1); never run the GL prototype and tsem as competing controllers.
- Exec bits are lost when files are pushed via the API; the installer sets modes itself.
- BusyBox ash was not available in the build sandbox for this run (dash and bash were).

## Open risks after RC3 (no hardware proof yet)
- Boot window: guard installed at START=18 with retries; real ordering against fw3/netifd/tailscaled on firmware 4.11.0 is only proven in netns. Hardware reboot test required.
- fw3 reload: covered by include + tick + layer 1 in netns; the instant between FORWARD flush and re-assertion is closed only by layer 1 (policy routing) and only if the kernel accepts the deny rule. Hardware proof required.
- Fast path: removal of SFE modules is verified by reading `/proc/modules`; whether the GL-MT3000 kernel re-loads them (e.g. a GL service) is unknown. fw3 flow offloading cannot be unloaded by tsem (reported as inconsistent).
- Resolver `0.0.0.0` on the router: effect unverified; documented only by evidence (`tsem diag`).
- Router DNS depends on a resolver reachable through the tunnel in GERMAN mode; a resolver reachable only via WAN is rejected (fail-closed, but DNS stops).
- IPv6: guard rules exist and are golden-tested, netns packet tests are IPv4 only.
- The hardware-switch calling convention is community-documented, not confirmed.
