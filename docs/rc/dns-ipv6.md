# DNS and IPv6

## IPv6
Same two-layer block as IPv4 (`ip -6` rules + `ip6tables` chain). IPv6 LAN traffic is only allowed via tailscale0 to tailnet destinations; everything else is rejected, so IPv6 is **blocked, not tunnelled**. Exit-node IPv6 is not used.
Verified: generated IPv6 rule text (`tests/t_rules.sh`). **Not verified with packets** (the build sandbox has no IPv6 stack). Test on the router: see test-plan step 8.

## DNS strategy per mode (F03)

**Hardware finding (RC5):** `nslookup example.com` on the router timed out in GERMAN, and tailscaled reported its DNS servers as unreachable. The router's upstream resolvers were `103.100.172.145` and `103.100.173.145` (ISP resolvers from the WAN) plus the local `0.0.0.0`. While protected, router-own traffic leaves through the exit node, and an ISP resolver is normally not reachable from the exit node's network. Tailscale DNS is deliberately disabled (`CorpDNS` off) and is **not** switched on blindly: it would add a second resolver path that tsem cannot verify and that stops working with both exit nodes down.

| Mode | LAN clients | Router itself |
|---|---|---|
| DIRECT | untouched (DHCP-announced resolver, normally the router's dnsmasq) | untouched (ISP resolvers over the WAN) |
| GERMAN | forwarded through the exit node like any other traffic; with `TSEM_DNS_REDIRECT` set, ALL port-53 traffic of clients is redirected to that resolver | **every router-own port-53 query (udp and tcp) is redirected to `TSEM_DNS_ROUTER`** (default `1.1.1.1`), which is reachable through the exit node. dnsmasq therefore resolves even though its configured upstream is an ISP resolver |
| BLOCKED | no Internet, so no DNS leak: the forward chain rejects everything except the tailnet | the redirect is still in place, but the redirected query cannot leave (`TSEM_OUT` rejects it); the exit node is cleared (F01) |

Exceptions that are **not** redirected (chain `TSEM_DNS_OUT`, nat/OUTPUT): loopback, the tailnet range (MagicDNS), the resolver itself, LAN interfaces, and tailscaled's own marked sockets (their DNS stays governed by `TSEM_ALLOW_UNDERLAY_DNS`, default blocked).

Failover between exit nodes keeps DNS working because the target resolver is a plain address reached through whichever node is active; the guard stays closed while the new node is verified.

Evidence (real kernel netfilter, network namespaces): `s_f03_*` in `tests/netns/netns_test.py`: control that DIRECT leaves DNS alone; GERMAN redirects the ISP resolver and any public resolver through the tunnel; negative control with `TSEM_DNS_ROUTER=""` reproduces the timeout; BLOCKED never leaks; failover and recovery; marked and tailnet DNS untouched; the chain is repaired after a firewall reload and removed by teardown. **Not tested on the router** (acceptance t04).

Limits, stated plainly:
- IPv6 DNS from the router to non-tunnel resolvers is rejected by the IPv6 output chain (no ip6tables nat is assumed); dnsmasq falls back to the IPv4 upstream.
- A client that talks DoH/DoT is not DNS-redirected; its traffic goes through the exit node or is blocked like all other traffic.
- tailscaled may still log "DNS server unreachable" for the ISP resolvers it reads from `/etc/resolv.conf`; this is a message about its own probing, not a DNS outage of the router or the clients.
- `TSEM_DNS_ROUTER` is a trust decision (which resolver sees the queries); choose your own in `/etc/tsem/tsem.conf`.

## The `0.0.0.0` resolver
`tsem diag` and `tsem selftest` print the kernel's own answer (`ip route get 0.0.0.0`). Only `local ... dev lo` proves that the address never leaves the router; any other answer is reported as unverified. dnsmasq bound to `0.0.0.0:53` (a listen address, not an upstream) is the usual explanation; it is harmless once the router-own redirect is active.

## Known limitation: a private upstream resolver of the router's own dnsmasq (found on real hardware, v1.2)

If the router's own resolver (dnsmasq on `127.0.0.1`) uses a **private** upstream resolver, typically the router you connect to over Wi-Fi
(a travel router behind another router, `nameserver 10.x.x.x` in `/tmp/resolv.conf.d/resolv.conf.auto` or `/tmp/resolv.conf.auto`), names do
**not resolve while the exit mode is active**: the router and the devices that use its resolver get `REFUSED`. Cause (measured on a
GL-MG1300 behind another router): the query to the private upstream is redirected to `TSEM_DNS_ROUTER`, but its route and source address
stay on the Wi-Fi uplink, and the kill switch correctly rejects it there. `tsem selftest` warns about such an upstream (`dns-resolver`), and
`tsem leaktest` reports `router-dns` when the router cannot resolve names. Nothing leaks: the failure is closed, not open. Messages to a
server **name** fail the same way: use an IP address as the backup address (`NOTIFY_URL_FALLBACK`).

Workaround (measured on the router by pointing the resolver at a public upstream; it works in EXIT, in BLOCKED nothing resolves on purpose):
give dnsmasq a public upstream instead of the DHCP one, for example

```sh
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

Not verified for every model or firmware: GL.iNet firmware may manage DNS itself, check `nslookup example.org 127.0.0.1` in the exit mode.
A fix in tsem itself (a redirect that also works for upstreams inside an admin network) is planned.
