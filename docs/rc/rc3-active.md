# RC3 upgrade and active hardware acceptance (Mac-controlled)

Draft tooling for phase 2 of `rc3-activation.md`. **Nothing here runs by itself.** The Mac wrapper
`tools/run-rc3-active-mac.sh` drives the router over `ssh` (alias `root`), and every phase that changes
something waits for a phrase you type. There is no `--yes`/`--force` option. Reports are saved on the Mac in
`~/tsem-rc3-active/` (mode 600, directory 700).

## Final acceptance: one command

`prepare` (backup + stage) was already done and is **reused, never repeated or overwritten**. The final run is one command; the
only things you type are the confirmations below.

```
T=$(mktemp -d) && git clone -q --depth 1 --branch main https://github.com/mompl/glinet-tailscale-exit-manager.git "$T/r" && \
sh "$T/r/tools/run-rc3-active-mac.sh" --stage "$T/r" \
  --backup-dir /root/tsem-rc3-backup-20261117-123151-12057 --stage-dir /root/tsem-rc3-stage-20261117-123203-12585 final; rm -rf "$T"
```

| Step | What happens | You type |
|---|---|---|
| 1 | read-only preflight; the backup copy on this Mac is verified again; `verify-prepared`: backup gate, stage manifest, **stage payload byte-identical to this checkout**, router not changed since the backup, no pending install journal | nothing |
| 2 | hardware switch gate (its position cannot be read by software) | `SWITCH-ON` or `SWITCH-OFF` |
| 3 | procd watchdog **proved by use** (see below), armed, then `install.sh --yes` from the stage (journaled, verified, auto-restore) | `WIRE-RC3` |
| 4 | t00 .. t08 in one go, watchdog health checked after every test; the first FAIL stops the run and starts the recovery | `RUN-TESTS` |
| 5 | `install.sh --yes --enable --replace-gl-hook` (journaled): boot link S18tsem, the GL switch hook becomes the tsem hook (old file kept, restored by rollback), service start; verified, auto-restore | `INTEGRATE-SWITCH` |
| 6 | `tsem set german` and verification (mode, guard, active exit node, intent, daemon); persistence/boot check without a reboot; watchdog disarmed; report | nothing |

Any FAIL: the run stops, `recover` runs (never opens the kill switch), the state is shown, the watchdog is disarmed, and the options
`repair` / `rollback` / `direct` are named. Declining a phrase changes nothing of that step.

## Recovery watchdog (SSH-independent)

The router has no `setsid`/`nohup`. The watchdog is a **procd service** added at run time with `ubus call service add` (memory only, nothing under
`/etc`, gone at reboot) with two instances: `watch` (heartbeat, deadline, recovery) and `monitor` (a second process that runs the recovery itself when
the watcher's heartbeat is stale or the deadline is long past). Both belong to procd, so an SSH drop, a closed terminal, a tailscale restart or a
firewall reload cannot end them, and `procd` respawns them (they resume the persisted deadline).

It is not trusted because a PID exists. Before every arm a **probe** uses the same mechanism with its own directory and service name (a canary file
instead of the recovery): procd reports both instances running, their parent is init/procd and not this SSH session, the heartbeat advances,
keepalives postpone the deadline, the deadline fires the action, and a frozen watcher (SIGSTOP) is taken over by the monitor. Any missing step is a FAIL:
nothing is armed and **nothing is wired or tested**. After the real arm the heartbeat is read again; `armed` means marker **and** a fresh heartbeat.
If an install was interrupted (`INPROGRESS`), the recovery first replays its journal (`install.sh --recover --yes` of the stage), then re-applies the
guard from the intent; it never opens the kill switch.

## Individual phases (advanced)

Prerequisite: the read-only acceptance (phase 1) passed. Sit at a **LAN client** so the Mac can observe the Internet from the client side.
Do not operate the GL hardware switch during the tests.

```
sh tools/run-rc3-active-mac.sh --stage "$T/r" prepare     # A: verified backup, B: STAGE only (nothing live)
sh tools/run-rc3-active-mac.sh --stage "$T/r" test all     # watchdog + wire + tests (per-test phrases)
```

Optional: `--host NAME`, `--out DIR`, `--timeout SECONDS` (watchdog, default 300, 120..3600), `--no-observe`.
The staged copy on the router is a new unique `/tmp/tsem-rc3-active-stage.<epoch>.<pid>` (created with `mkdir`
without `-p`, marker file, removed only after the path pattern, directory type and marker are re-checked).
`/tmp/glinet-tailscale-exit-manager` is never touched.

## Phases and confirmations

| Phase | Command | Confirmation | Effect on the router |
|---|---|---|---|
| A | `prepare` | `BACKUP` | preflight (read-only), then writes **only** `/root/tsem-rc3-backup-<time>/` (RC files, tsem config + intent, GL switch hook, boot links, firewall/network/dhcp/system/tailscale/gl* UCI, crontabs, iptables/ip6tables/ip rules/routes/modules as text) and copies it to the Mac. The backup is **gated**: no hash tool, no `tar`, a missing required file, an archive that lacks an expected path, a checksum/manifest mismatch or an empty firewall/route snapshot is a FAIL and stops everything. The copy on the Mac is verified again (checksum, manifest). |
| B | `prepare` | `STAGE-RC3` | copies the tested tree to a **side directory** `/root/tsem-rc3-stage-<time>/` and proves it there: hash manifest, `sh -n`, a trial install into a throw-away root, and that every live handler (tsem files, hotplug handler, fw3 include/UCI firewall, init script, boot links, GL hook, config, intent) is byte-identical afterwards. **RC3 is not installed and not active after `prepare`**: no hotplug event, firewall reload or boot can start it. |
| C | `test` | `ARM-RECOVERY` | starts the procd recovery watchdog after the probe proved it (copy of `tsem-rc3-recover.sh` in `/tmp/tsem-rc3-active/`) |
| C2 | `test` | `WIRE-RC3` | after the watchdog is armed: `install.sh --yes` from the verified stage into the live router (write-ahead journal, `INPROGRESS` marker, HUP/INT/TERM/PIPE ignored). Verified: version, file hashes vs. the stage, intent/tsem.conf/GL hook/boot link exactly as in the backup, intent valid, selftest, guard not open, no pending journal. **Any failure restores the previous version automatically** and re-asserts the guard from the intent (never opens it). Only now RC3 is live. |
| D | `test <names>` | `START <test>` for every test | the test, see below |
| end | `test` | `DISARM` | stops the watchdog (otherwise it runs RECOVERY at its deadline, harmless) |
| - | `recover` | `RECOVER` | recovery now |
| - | `repair` | `REPAIR` | replays the journal of an interrupted wire/install (`install.sh --recover`), restores the previous files, `tsem reapply`; never opens the guard |
| - | `rollback` | `ROLLBACK` | `install.sh --rollback`, uses the backup of `prepare` |
| - | `direct` | `OPEN-KILLSWITCH` | `tsem set direct`: the only command that opens the kill switch |

Active tests refuse to start unless the watchdog is armed, RC3 is installed, and no `tsem daemon` runs.
After a declined phase nothing of that phase was done. `status` is read-only.

## Recovery, rollback, return to direct

| | Recovery | Rollback | Return to direct |
|---|---|---|---|
| Purpose | get the router working again after a test or a lost session | go back to the previous tsem version | deliberately give up the kill switch |
| Triggered by | watchdog deadline, or `recover` | `rollback` + `ROLLBACK` | `direct` + `OPEN-KILLSWITCH` |
| Kill switch | **never opened**, never removed | not opened; reported as FAIL if the guard is open afterwards although it was closed before | opened |
| Does | removes test fault state, starts tailscaled if down, `tsem reapply` (guard from the intent), `tsem tick` until an exit node is active | `install.sh --rollback`, `tsem reapply` | `tsem set direct` |
| Never does | `tsem set direct`, `teardown`, chain/rule/module changes, install or boot-link changes | opens the Internet | - |

Result lines of recovery: `ok` (german, exit node active), `degraded` (german, no exit node yet), `blocked` (no node
usable: **no Internet for the LAN by design**, management via LAN/tailnet still works), `direct` (the intent was
direct, nothing changed), `failed` (guard open or inconsistent although the intent is german: nothing was opened or
removed, see `tsem diag`). Manual call on the router at any time: `sh /tmp/tsem-rc3-active/recover.sh now`.
With a dead router and a ssh session: the watchdog needs no Mac and no tsem service.

## Tests (all in `tools/tsem-rc3-active.sh`)

| Test | What it does | Disturbs LAN? |
|---|---|---|
| t00_activate | `tsem set german`, waits for an exit node, checks guard, leak_risk, selftest, never-open samples | switches clients to the exit node |
| t01_primary | primary in use, exit = configured primary, router egress IP, deny rule, TSEM chains | no |
| t02_failover | primary -> secondary -> primary; primary only **simulated** down | brief exit switch |
| t03_both_down | both nodes simulated down: state BLOCKED, guard blocked, no leak, router-own HTTPS fails, LAN route denied, deny rule present, Mac sees no Internet; then recovery to an exit node | **LAN has no Internet on purpose** |
| t04_dns | router resolves, hard-coded resolver route goes through the tunnel or is denied | no |
| t05_ipv6 | ip6tables chain, IPv6 deny rule, forwarded IPv6 tunnelled or denied (WARN if the router has no global IPv6) | no |
| t06_fastpath | no SFE/fast-path module or FLOWOFFLOAD in german; unload path covered if it was loaded before (backup) | no |
| t07_fwreload | `firewall reload` with a sampler: policy routing (layer 1) must hold, the include must restore layer 2 | connections may stall |
| t08_tsrestart | `tailscale restart`: guard stays closed, exit node returns; SKIP when the ssh session itself runs over Tailscale | LAN has no Internet for some seconds |

Fault injection: only as environment variables of the foreground `tsem tick` calls (a wrong node name, so the
identity check fails at once). Tailscale, firewall, routes and the tailnet are not faulted, so a lost connection
leaves nothing to repair except the exit node choice, which recovery does.

**Both nodes down, no WAN fallback.** Evidence per run: state BLOCKED and guard=blocked in every sample (an `open` sample
is a FAIL), `ip rule` deny entry, `ip route get` for forwarded LAN traffic is denied, the router's own HTTPS request
fails, the Mac (as LAN client) gets no IPv4/IPv6 Internet and no DNS answer. Any success is a FAIL.

A probe that cannot run is **never** a pass: `curl` missing, a curl exit other than 6/7/28 (resolve/connect/timeout) or a missing positive control (the same probe must succeed in german first, on the router in t03 and on the Mac before the tests start) is a FAIL; unrecognised `ip route get` output, missing `ip`, `nslookup`, `lsmod` or empty `iptables -S FORWARD` output are FAILs too.

## Reading the report

Lines are `PASS`, `WARN`, `FAIL`, `SKIP`, `INFO` with an id and the evidence. The Mac wrapper prints a `SUMMARY` and exits 1 if
there is any `FAIL`. Limits, stated in the report itself:
- the outages are **simulated** (identity mismatch), a really unreachable exit node is not exercised; do it by hand by
  disabling the exit node in the Tailscale admin console and watching `tsem status`;
- leak evidence is **sampled** (about every 0.3 s on the router, a few probes from the Mac): a shorter gap cannot be excluded;
- IPv6 and SFE paths are only exercised if the hardware has them (WARN says so);
- the reboot test (phase 2, item 8) is not scripted: it needs a power cycle and is run by hand after this passes.

Not a result of this tooling: activation (phase 3), merge, a permanent service. `prepare` leaves the router exactly as it was (plus two new directories below `/root`).

## Interrupted installs (SSH or process lost)

`install.sh` writes a journal before every change and an `/etc/tsem/backup/INPROGRESS` marker (naming that journal) for the whole transaction; HUP/INT/TERM/PIPE are ignored while it runs, so a dropped SSH session does not stop it half way. Only SIGKILL or a power loss can interrupt it, and then the marker stays:
a new install refuses to start (`--recover` hint), `install.sh --recover --yes` / `--rollback --yes` and the Mac phase `repair` replay exactly that journal (files, symlinks, fw3 stanza, intent created by the install, `install.manifest`), and the watchdog's recovery log names a pending marker. The previous completed install stays the target of a later `--rollback`.

## What the tests cannot prove (final acceptance)

Simulated, not real: exit-node failures are faults injected into foreground ticks (a real outage of `exit-a`/`exit-b` is not caused).
Not proven by the run: a real reboot (the boot link, `START=18` and the intent are checked statically), the firmware's call convention of the hardware
switch (flip it once after the run and look at `tsem status`; `echo trace > /etc/tsem/hook.mode` logs the arguments), IPv6 from every client, and that
procd accepts the service JSON on this firmware (the probe proves it at run time; if it does not, nothing is wired).

## What the tests cannot prove (earlier phases)

The fixtures use fake `tsem`/`ip`/`curl`; the shell is dash, an `ash` shim and a BusyBox `ash`, but not a real OpenWrt userland. Still unverified on root: `setsid`/`nohup` availability, how dropbear treats a dropped session (the wire process ignores HUP, but this was not tried live), `ip route get ... iif br-lan` output on the GL.iNet kernel, and `curl` on the router (without it the leak test FAILs, it is never a pass).
