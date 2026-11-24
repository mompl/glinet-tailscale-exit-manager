# /etc/tsem/tsem.conf

Whitelisted `KEY=value` lines only; values containing `$ ` `` ` `` `; | & < > ( )` are rejected, invalid values fall back to defaults. Environment variables override the file. Never executed as shell.

| Key | Meaning |
|---|---|
| TSEM_PRIMARY / TSEM_SECONDARY | exit node Tailscale IPv4 (empty = unset) |
| TSEM_LAN_IFACES | LAN bridges to protect (default `br-lan`) |
| TSEM_TS_IFACE | tailscale interface (`tailscale0`) |
| TSEM_ALLOW_SUBNETS4/6, TSEM_TAILNET4/6 | extra destinations allowed via tailscale0 in BLOCKED (GERMAN allows all via tailscale0). Shipped: `TSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24"` (remote-site). No blanket RFC1918; further advertised subnets (see `ip route show table 52`) must be listed explicitly |
| TSEM_ALLOW_OUT_IFACES | extra egress ifaces allowed in german mode (default none) |
| TSEM_FAIL_N / UP_N / RETURN_N | hysteresis thresholds (clamped: RETURN_N ≥ UP_N) |
| TSEM_BACKOFF_MIN / MAX, TSEM_INTERVAL | retry backoff, fast tick seconds |
| TSEM_PRIMARY_NAME / SECONDARY_NAME | Tailscale hostname or MagicDNS label that must own the IP (`[A-Za-z0-9.-]`, ≤63). Empty = identity NOT verified (reported by `tsem verify-nodes`) |
| TSEM_OUT_GUARD | `on` (default) / `off`: router-own OUTPUT guard |
| TSEM_OUT_LOCAL_IFACES | extra local interfaces the router may use freely |
| TSEM_ALLOW_NTP | `1` (default) allow router NTP udp/123 while protected |
| TSEM_ALLOW_UNDERLAY_DNS | `0` (default); `1` lets tailscaled's marked packets use port 53 |
| TSEM_UNDERLAY_MARK | tailscaled fwmark `0xVAL/0xMASK` (default `0x80000/0xff0000`, unconfirmed on 1.92.5: check `tsem diag`) |
| TSEM_INTERVAL_RECOVERY / STEADY / IDLE | adaptive tick: 15 s (secondary active), 20 s (primary active), 60 s (direct); never below TSEM_INTERVAL (5 s fast) |
| TSEM_DNS_REDIRECT | optional IPv4 resolver LAN DNS is DNAT-ed to while protected |

Run `tsem diag` to see the effective values.

## Masquerading and private Tailscale subnets

SNAT for LAN -> tailscale0 is done by fw3 (`firewall.tailscale0.masq='1'`, chain `zone_tailscale0_postrouting`).
tsem never creates, changes or removes it: it has no nat POSTROUTING/MASQUERADE rule (its only nat chain is
`TSEM_DNS` at PREROUTING), and the installer only appends/removes its marker stanza in `/etc/config/firewall`
(zones, `masq` and `lan_tailscale` stay byte-identical; tested).
If masquerading is missing, remote private networks do not answer (their source 10.20.0.x is unknown there);
the netns suite simulates this and expects exactly that failure.
