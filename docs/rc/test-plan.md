# Real GL-MT3000 test plan (needs explicit approval, run by the operator on the router)

Prepare: keep a second SSH session open; know the emergency exit (install-rollback.md). Do each step, record output.
1. `sh install.sh` (dry run) – read plan; backup `/etc/config/firewall`, `/etc/gl-switch.d/`.
2. `sh install.sh --yes`; set TSEM_PRIMARY/SECONDARY in tsem.conf. Still nothing active.
3. `tsem selftest`, `tsem diag` – check: `ip` supports `suppress_prefixlength`, iptables-legacy output format, flock/timeout present, `tailscale status --json`/`debug prefs` parse, router NOT advertising an exit node, rule priority 5270 vs 5280, table 52.
4. Hook discovery: set `/etc/tsem/hook.mode` to trace, flip the hardware switch, read the trace to learn how GL calls the script (args/ACTION). Then `--replace-gl-hook`.
5. `tsem set german` with a laptop on LAN: confirm exit IP is the primary's; return path/replies work; `tsem status` leak_risk=false.
6. Failover: disable primary route/stop its Tailscale → expect SECONDARY_ACTIVE after hysteresis, no leak (run `ping` continuously from LAN: loss ok, no direct-IP appearance). Both down → BLOCKED. Recover → return to primary after RETURN_N.
7. DNS: `tsem diag`; from client `nslookup` + dnsleaktest; resolve the `0.0.0.0` question; set TSEM_DNS_REDIRECT if needed.
8. IPv6: from client `curl -6 ifconfig.co` must FAIL while protected.
9. `fw3 reload` and `/etc/init.d/network restart` while a ping runs: no leak, hook restored within one tick.
10. WAN change (switch uplink / apclix0 reconnect); `/etc/init.d/tailscale restart`; reboot (kill switch up before LAN traffic: START=18).
11. Hardware switch rapid toggling + HA toggle concurrently; end state consistent (`hw_match=yes`).
12. Rollback: `tsem set direct`, `uninstall.sh --yes`, verify plain internet and original GL hook.
RC2 hardware-only proofs (cannot be shown in mocks/netns): fw3 flush behaviour of OUTPUT and measured gap; boot ordering with real init/firewall/network; tailscaled fwmark value and JSON layout; real GL switch invocation; IPv6 router-own behaviour; busybox ash/flock/timeout behaviour; real `dnsmasq` upstream behaviour; load of the 5/15/20/60 s ticks (`top`, expected: a few short forks per tick).
Additional steps: `tsem verify-nodes` must PASS both nodes before `tsem set german`; while GERMAN, from the router: `nslookup example.com 1.1.1.1` must fail/time out when both exits are down; `ping -6` from the router to a public address must fail; `tsem interval`.
Abort criteria: any leak, lost router management, or unexplained state → emergency exit, report.

## Masquerade / private subnets (remote-site)

netns: `s_extnet_subnets_reachable_with_masq_in_german_and_blocked`, `s_extnet_policy_routing_does_not_block_allowed_subnets`,
`s_extnet_missing_masquerade_is_detected` (masq deliberately off -> no answer), `s_extnet_blocked_without_allow_config_is_closed`,
`s_masquerade_untouched_by_state_changes_reload_and_teardown`. The remote responder only answers sources in 100.x, so missing SNAT
shows up as no reply. Unit: `t_rules.sh` (exact rules, no blanket RFC1918, no POSTROUTING/MASQUERADE in sources),
`t_install.sh` (fw3 masquerade config byte-identical after install, reinstall, uninstall, purge).
Masquerade is simulated in a namespace; it is not verified on root.
