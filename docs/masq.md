# Masquerading LAN -> tailscale0 (tsem-masq)

## Problem
`firewall.tailscale0.masq=0` and no `MASQUERADE` rule in `zone_tailscale0_postrouting`. Replies of private tailnet
subnets (the remote-site networks `10.30.0.0/24`, `10.30.1.0/24`, `10.30.2.0/24`) cannot return without source NAT.
Masquerading and the kill switch are different functions: this repair never changes GERMAN/BLOCKED protection.

## Root cause: what is proven and what is a hypothesis
The router was **not** read for this analysis (no session on it). The sources are the preflight result you reported and
public GL.iNet documentation/forum threads; nothing below was observed on root itself.

| statement | status | basis |
|---|---|---|
| root has `masq=0` and no MASQUERADE rule, but a lan -> tailscale0 forwarding | **proven** | your preflight (`masq.uci`, `masq.nat`, `masq.forward`) |
| tsem never wrote or removed masq/NAT settings | **proven** | code + test `test_sources_never_touch_nat_postrouting_or_masquerade`; the controller has no NAT code |
| The GL.iNet firmware creates the zone `tailscale0` with `masq '0'` by default | documented (public) | GL.iNet forum: stock zone listing; a GL.iNet staff post says the dedicated zone needs no masquerading for the stock exit-node use |
| The firmware (re)writes this zone from its own scripts (`/etc/firewall.tailscale.sh`, `/usr/bin/gl_tailscale`) | documented (public) | forum threads quote that file; staff suggest editing it to `uci set firewall.$TS_ZONE.masq='1'`; another thread reports firewall settings being reset on a captive-portal reconnect |
| **Which** event reset your setting again (Tailscale restart in the GUI, captive portal, firmware script, firewall reset) | **hypothesis, not provable here** | needs `logread`, the mtime of `/etc/config/firewall` and a read of `/etc/firewall.tailscale.sh` and `/usr/bin/gl_tailscale` on the router |

Consequence: the repair does not depend on knowing the trigger. It reconciles after every event that can recreate the
zone (fw3 reload, network up, config change, boot) and by a slow safety net.

To pin down the trigger on the router (read-only), run `sh tools/run-masq-fix-mac.sh` (check) and, on the router:
`ls -l --time-style=full-iso /etc/config/firewall /etc/firewall.tailscale.sh`, `grep -n masq /etc/firewall.tailscale.sh /usr/bin/gl_tailscale`,
`logread | grep -i -E 'tailscale|firewall'`. Doing so is not required for the repair.

## What the repair does (`/usr/sbin/tsem-masq`)
* Desired state: zone `tailscale0`: `masq=1`, and `MASQUERADE` in `zone_tailscale0_postrouting`.
* `check` reads both (read-only; rc 0 consistent, 1 drift, 3 not applicable).
* `ensure` is idempotent: it writes **nothing** when everything is right. On drift: one backup of `/etc/config/firewall`
  (`/etc/tsem/backup/masq/`), `uci set ...masq=1` + `commit` (only if not 1), and one `iptables` rule with the comment
  `tsem-masq` (only if the chain has no MASQUERADE). If fw3 later builds its own rule from UCI, a leftover `tsem-masq`
  duplicate is removed so fw3 stays the owner.
* A firewall reload happens only when the zone chain does not exist, at most once per 120 s, never from the fw3 include,
  never from hotplug, never from the watcher. The component never creates a zone and never creates a forwarding
  (a missing forwarding is only reported as `WARN masq.forward`).
* It touches no `TSEM_FWD`/`TSEM_OUT` chain, no `ip rule`, no exit node, no WAN rule and adds no ACCEPT rule (tested).

## When it runs (event-driven, no periodic reloads)
| trigger | mechanism |
|---|---|
| firewall reload (fw3 flushes and rebuilds the chains) | fw3 include `tsem_masq` (`/usr/lib/tsem/masq-include.sh`, reload=1); never fails fw3 |
| network/WAN/Tailscale interface up | hotplug `51-tsem-masq` (ifup/ifupdate, debounced 5 s, background) |
| firewall config changed through ubus/uci | procd config trigger `config.change firewall` |
| boot | init script `tsem-masq` (START=96, after firewall and network), one pass |
| everything else (e.g. `uci commit` from a script without a trigger) | watcher, one read every 300 s (`TSEM_MASQ_INTERVAL`), writes only on drift |

## With tsem stopped, disabled or not installed
The component is separate: `install.sh --components masq --enable --yes` installs only `tsem-masq`, its include, hotplug
script and init script. It does not source or call the controller (tested). It is part of the default component set,
so a normal install includes it; uninstall removes it (the repaired UCI value `masq=1` stays, it is the desired state).

## Immediate repair of the live router (separate approval)
```
sh tools/run-masq-fix-mac.sh --host root            # read-only check
sh tools/run-masq-fix-mac.sh --host root --apply    # asks for the phrase FIX-MASQ, then repairs and verifies
```
No firewall reload, no install, no kill-switch change. Undo: restore the backup file, delete the `tsem-masq` iptables rule
(printed by the tool).

## Not proven
Behaviour on the real firmware: the rpcd/procd config trigger signature, the exact fw3 include timing, and which GL.iNet
service resets the zone. The tests use fake uci/iptables commands (simulated).
