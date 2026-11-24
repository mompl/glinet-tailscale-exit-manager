# Boot, fw reload, service restart (RC2)

## Order
- `/etc/init.d/tsem` START=18 runs before firewall (19) and network (20). `tsem boot` reads `/etc/tsem/intent`, installs TSEM_FWD, TSEM_OUT and rules for the persisted intent. It makes no probes and no tailscale calls (so it cannot hang or depend on the network). `boot_guard` retries (default 10 tries); if it still fails, state is ERROR and leak_risk is reported, never "functional".
- Missing or corrupt intent means BLOCKED (never DIRECT).
- Intent evaluation needs only flash (`/etc/tsem`), so it is possible before WAN is up.
- fw3 reload: fw include (`reload 1`), hotplug iface events and the daemon tick re-assert hooks and compare chain checksums (drift repair). Stop never opens the guard.
- tailscaled restart: ip rule 5270/table 52 vanish; layer 1 and TSEM_OUT keep blocking; state goes through failover/recovery.

## Possible windows (unproven)
1. Between kernel start and START=18: iptables chains do not exist yet; nothing is filtered. Whether WAN/LAN is already up here depends on boot order. Unmeasured.
2. fw3 start/reload flushing FORWARD/OUTPUT before re-assert: seconds at most; forwarded traffic remains covered by layer 1; router-own traffic is not.
3. A failed `tsem boot` (iptables locked, module missing): ERROR, retried; window persists until success.

**Full boot-leak-freedom is not claimed.** It needs a real MT3000 boot trace (packet capture on WAN during reboot).
