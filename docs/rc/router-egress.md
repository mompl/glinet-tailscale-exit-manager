# Router-own traffic (RC2)

Problem in RC1: only forwarded LAN traffic was filtered. dnsmasq, tailscaled, NTP, and any process on the router could still reach the WAN directly (DNS leak), even in BLOCKED.

## Layer
Chain `TSEM_OUT` (iptables and ip6tables), jumped to from OUTPUT position 1. Single layer: policy routing cannot cover router-own packets because connected WAN-subnet routes stay usable. Rules, in order:
1. `-o lo`, `-o tailscale0`, `-o <TSEM_LAN_IFACES + TSEM_OUT_LOCAL_IFACES>` → RETURN (local, tunnel, LAN replies/management).
2. tailscaled underlay: packets with fwmark `TSEM_UNDERLAY_MARK`, udp (any port: WireGuard/STUN/DERP discovery) and tcp 80/443 (DERP/control) → RETURN. Marked port 53 is REJECTed first, unless `TSEM_ALLOW_UNDERLAY_DNS=1`.
3. DHCP client (v4 udp 68→67; v6 546→547) and IPv6 ND (router/neighbour solicitation, neighbour advertisement) → RETURN.
4. `TSEM_ALLOW_NTP=1`: udp/123 → RETURN.
5. REJECT (comment `tsem:<state>`).
In DIRECT the chain holds one RETURN (`tsem:open`). No ACCEPT, no ESTABLISHED/RELATED shortcut.

## What this does NOT allow
Unmarked DNS, HTTP(S) or any other WAN traffic from router processes. Router updates, opkg, DDNS, GL cloud and similar stop working in GERMAN/BLOCKED unless they leave through tailscale0.
The mark exception allows any process that sets the same fwmark; only tailscaled is expected to. This is a documented, narrow risk.

## Ordering
The chain is installed before exit-node changes and opened only after real egress through the exit is proven. Tests prove no router-own leak across state transitions, tailscaled death/restart, WAN change and both-exits-down (IPv4, netns).

## Unconfirmed
Mark value on tailscale 1.92.5; fw3 OUTPUT flush behaviour; IPv6 packets.

## BLOCKED means "no exit node" (F01/F02, 1.0.0)
RC5 kept the last exit node selected in BLOCKED. tailscale's default route in table 52 therefore stayed, and rule 1 above (`-o tailscale0 -> RETURN`) let the router's own HTTPS leave through the tunnel of a node tsem had just declared unusable (hardware test `t03_both_down`: `FAIL t03.router_egress`, `FAIL t03.lan_route`). That was not a WAN leak, but it contradicted what BLOCKED promises. `tsem` now clears the exit node whenever the target state is BLOCKED with no node (the guard is already closed at that moment: closing before clearing). Consequences:
- no default route in table 52, so router-own traffic falls through to the main table, where `TSEM_OUT` rejects it;
- the tailnet stays reachable (the `100.64.0.0/10` route is not a default route), so management over Tailscale keeps working;
- `CONNECTING_*` (an exit node chosen but not yet proven) is unchanged: the node must stay selected so the egress probe can run through it.
If tailscaled refuses to clear the node, the result is `ERROR` with the guard closed: clients stay blocked and the router can at most reach the Internet through that node's tunnel, never through the WAN.

Proof (real kernel netfilter in network namespaces, `tests/netns/netns_test.py`, `tests/netns/netns6_test.py`): `s_f01_*` and `s6_router_own_ipv6_is_closed_in_blocked_and_open_in_direct`. The scenarios do NOT delete the route by hand (the old test helper did, which hid the defect); they first prove with a control that the router really uses the tunnel while active, and the same scenarios FAIL against the RC5 code.

## Underlay exceptions in one list
Everything the router may send while GERMAN or BLOCKED without going through the tunnel, and why. Nothing else is allowed.
| Exception | Scope | Reason | Can be switched off |
|---|---|---|---|
| tailscaled's own sockets (fwmark `TSEM_UNDERLAY_MARK`) | udp any port; tcp 80/443; **not** port 53 | WireGuard/STUN/DERP and the control plane must work to build any tunnel at all | no (without it no exit node can ever come up) |
| DHCP client / IPv6 ND | udp 68->67, udp 546->547, router/neighbour solicitation/advertisement | the WAN link must keep its address | no |
| NTP | udp 123 | the clock must not drift (certificates, WireGuard) | `TSEM_ALLOW_NTP=0` |
| tailscaled underlay DNS | marked udp/tcp 53 | optional | opt-in `TSEM_ALLOW_UNDERLAY_DNS=1` (default off) |
| loopback, LAN interfaces, tailscale0 | local and tunnel traffic | management and the tunnel itself | no |
None of these lets an unmarked process reach the Internet over the WAN. The mark is the one trust assumption: any process that sets the same fwmark would pass; only tailscaled is expected to.
