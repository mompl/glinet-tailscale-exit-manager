# RC3: hardware acceptance and controlled activation (root)

Nothing in this document is executed automatically. Every router change below needs your explicit go. The order is fixed:
**phase 1 (read-only report) → your decision → phase 2 (active tests, separately approved) → phase 3 (activation) → rollback if needed.**

## Phase 1 - read-only acceptance (no change on the router)

`tools/tsem-rc3-acceptance.sh` runs the RC3 code of a *repository copy* (not the installed rc2) with its read-only commands
(`status`, `intent-check`, `selftest`) and reads system state. The Mac wrapper `tools/run-rc3-acceptance-mac.sh` streams the script
through ssh and saves the report on the Mac (`~/tsem-rc3-acceptance/`). With `--stage DIR` it first copies the checkout to the
router into a **new, unique, volatile** directory `/tmp/tsem-rc3-accept.<epoch>.<pid>` (RAM, about 1 MB; created with `mkdir` without `-p`, so nothing existing is reused or overwritten) and **deletes only that directory again** after the run, also when the run fails.
An existing `/tmp/glinet-tailscale-exit-manager` (the earlier repository) is neither used, changed nor deleted. Cleanup runs only after checking on the router that the name matches the pattern, it is a real directory (no symlink) and carries the marker file `.tsem-rc3-stage` written by this run.
This temporary copy is the only thing written on the router; it is needed because the RC3 code
is run from there with read-only commands while RC2 is still the installed version. The run uses exactly 3 ssh calls: stage, read-only run, cleanup.

Single command on the Mac (uses your existing git credentials and the `root` ssh alias, no token):

```
sh -c 'T=$(mktemp -d) && git clone -q --depth 1 --branch main https://github.com/mompl/glinet-tailscale-exit-manager.git "$T/r" && sh "$T/r/tools/run-rc3-acceptance-mac.sh" --stage "$T/r"; rm -rf "$T"'
```

What it covers (report sections): repository version/hash · intent validity **with reason** (item 1) · current state · selftest incl.
fast path (item 3), deny-action capability (item 2) and resolver classification (item 4) · DNS evidence (`ip route get 0.0.0.0`, listeners,
dnsmasq config) · old hardware-switch controller and other exit-node scripts (item 7) · boot/firewall order and fw3 flow offloading
(items 5, 6) · masquerading and the three remote-site routes in table 52 (item 9) · both exit nodes (item 8) · the embedded RC2 preflight ·
read-only proof (state snapshot before/after, compared per component: `uci`, `tsem-files`, `iptables`, `ip6tables`, `ip-rules`, `routes-static`, `routes-dynamic`, `modules`).
Normalised away as runtime noise: the iptables-save timestamp comment and packet/byte counters, route lifetimes (`expires`), lsmod use counts. A real change in any static component is a FAIL and the differing lines are printed (`+` only after, `-` only before). Tailscale routes (table 52, `dev tailscale0`) and routes learned by RA/DHCP are `routes-dynamic`: reported as INFO; if the tailscale default route or an exit-node/remote-site route changed, the result is INSUFFICIENT_EVIDENCE (cannot be attributed to the run). A component that already changes by itself between two snapshots taken one second before the run is reported as SKIP (evidence missing), never as a silent pass.

Result: `RC3_READ_ONLY_OK` (only: no blocker found by reading), `NEEDS_FIX`, `INSUFFICIENT_EVIDENCE`. It is **not** proof of leak-freedom.
`--active` is refused by design.

## Phase 2 - active tests (only after your separate approval)

Scripted, with backup, passive install, an independent recovery watchdog and a typed confirmation per phase: see `rc3-active.md`. The manual steps below remain valid as reference (and the reboot test is manual).

Each step is a change on the live router and is run by hand, one at a time, with `tsem set direct` as the way out:
1. Install passively into the normal paths: `sh install.sh --yes` (no `--enable`, no `--replace-gl-hook`). Check `tsem intent-check`.
2. `tsem set german`; verify `tsem status` (`guard=german`, `leak_risk=false`, fast path gone: `lsmod | grep -i -E 'shortcut|sfe|fast_classifier'` empty).
3. From a LAN client: `curl -4 https://ifconfig.co` shows the German exit; DNS: `nslookup example.com` works; a client with a hard-coded DNS (`nslookup example.com 8.8.8.8`) goes through the tunnel (check on the exit node) and **never** leaves via the WAN (`tcpdump -ni apclix0 port 53` on the router stays silent).
4. Router-own traffic: `wget -qO- https://ifconfig.co` on the router shows the exit address or fails; `tcpdump -ni apclix0` shows only tailscaled's own underlay traffic.
5. remote-site: ping/connect to hosts in 10.30.0.0/24, 10.30.1.0/24, 10.30.2.0/24; masquerade untouched (`iptables-save -t nat` identical before/after).
6. Fail-over: tsem switches to the Secondary (100.64.0.31) when the Primary (100.64.0.30) dies; block Primary reachability, expect `SECONDARY_ACTIVE`, then block both, expect `BLOCKED` (LAN has no internet, no WAN fallback), restore the Primary, expect return after `TSEM_DWELL`/`TSEM_RETURN_N`.
7. fw3 reload (`/etc/init.d/firewall reload`) while a client runs a continuous probe: expect no WAN answer at any time; then `/etc/init.d/tailscale restart`.
8. Reboot with `german` intent and a probe running from a LAN client: expect no WAN answer during boot (`logread | grep tsem`, `tsem status`).
A window that was not observed closed on the hardware is **open until proven otherwise**, whatever the netns tests say.

## Phase 3 - activation (after phase 2 passed)

```
sh install.sh --yes --enable --replace-gl-hook --initial-mode german   # backs up the GL prototype script, adds boot links + fw3 include
/etc/init.d/tsem start
tsem status && tsem selftest
```
Stopping the service never opens the guard. The hardware switch then calls `tsem set german|direct` (the prototype is no longer a second controller;
`/etc/gl-switch.d/tailscale-de.sh` is replaced and the original is kept under `/etc/tsem/backup/<stamp>/`).

## Rollback

| Situation | Command (on the router) |
|---|---|
| Back to plain internet immediately | `tsem set direct` (preferred) or `tsem teardown`; `tailscale set --exit-node=` |
| Undo the last install/upgrade (files, include, boot links, original switch script) | `sh install.sh --rollback --yes` |
| Remove tsem completely | `sh uninstall.sh --yes` (add `--purge` to drop config and backups) |
| LAN has no internet / no access | ssh over the tailnet or the LAN address still works in every state (management is allowed); run `tsem set direct`. The hardware switch is only an input to `tsem set`; it cannot override a BLOCKED guard by itself |

An invalid or missing `/etc/tsem/intent` is treated as **BLOCKED** (never DIRECT). Repair it explicitly with `tsem set german|direct`;
the installer keeps an invalid file untouched and stores `intent.invalid-<stamp>`.
