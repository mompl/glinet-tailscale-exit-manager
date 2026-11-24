# Operations: exit nodes, hardware switch, polling load

## Exit nodes
Primary `exit-a`, secondary `exit-b`: name and IP must match, node online and an approved exit node (`tsem verify-nodes`, read-only, rc 0/1). `tsem set german` is refused (rc 2) without a valid primary IP. A node failing the identity check is never selected; there is no automatic choice of other nodes, and both failing means BLOCKED, never DIRECT. tsem calls only `tailscale set --exit-node=<ip|empty>`, `status --json`, `debug prefs` and `ping`; it never changes the router's own exit-node advertisement (test-enforced).

## Hardware switch (F04)

What is proven and what is not, in one place:

| Fact | Status |
|---|---|
| The hook maps `on|off|1|0|true|false|german|direct` (argument 1, then the variable `action`, then `ACTION`) to `tsem set german|direct --source hw`; anything else is ignored; the controller serialises events, last action wins | **tested** (`tests/t_hook.sh`) |
| The firmware calls `/etc/gl-switch.d/<selected function>` with `on|off` when the toggle button moves, and the router's UI setting selects `tailscale-de` | **community-documented, NOT confirmed on firmware 4.11.0**; acceptance step `hw.event` proves it (see below) |
| The physical position can be read by software | **unknown for the GL-MT3000**; optional readers are provided but not configured by default |

### Installation
`install.sh` now installs the hook by default as `/etc/gl-switch.d/tailscale-de.sh` (the original is backed up and restored by uninstall/rollback; `--keep-gl-hook` opts out). In RC5 the original prototype was kept, so no switch event ever reached tsem: that is why the hardware showed `hw_state=unknown`, `hw_source=none`. `tsem selftest` now FAILs when that file is not the executable tsem hook and WARNs when the firmware's toggle-button function (`uci switch-button.@main[0].func`) is not `tailscale-de`.

### What `tsem status` reports (`hw_state`, `hw_source`, `hw_event_ts`, `hw_match`)
| `hw_source` | meaning | trust |
|---|---|---|
| `gpio` | `TSEM_HW_GPIO_VALUE` (a sysfs value file) read now; `TSEM_HW_GPIO_ON` is the value meaning ON/GERMAN | the physical position |
| `file` | `TSEM_HW_STATE_FILE` read now | whatever writes that file |
| `event` | the position the firmware last reported to the hook since this boot | last report, not a reading |
| `persisted` | the last report from before this boot, kept in flash (`/etc/tsem/hw_last`) | **possibly outdated** (the switch can move while the router is off) |
| `none` | nothing known: `hw_state=unknown`, `hw_match=unknown` | never guessed |

`hw_match` says whether the position agrees with the mode (`yes`, `no`, `unknown`). A mismatch is **displayed, never silently resolved**.

### Defined behaviour
- **Boot:** the persisted intent decides (fail-closed). The hardware position is never used to open the kill switch at boot. A GERMAN intent with the switch at OFF stays GERMAN and shows `hw_match=no` until the switch is moved again.
- **Missed events** (router off, handler not run): the next event wins; until then the mismatch is visible in the CLI, LuCI, the native GUI and Home Assistant.
- **Conflicting actions** (switch, GUI, CLI, Home Assistant at the same time): one controller, one lock, the last action wins; the source (`hw`, `cli`, `gui`, `ha`) is recorded.
- **No polling:** the hook is event-driven. The optional readers are read only when `tsem status` runs.

### Acceptance on the router (cannot be shown without it)
1. `echo trace > /etc/tsem/hook.mode`, move the switch both ways, read `logread | grep tsem-hook`: shows how the firmware really calls the hook (arguments, `action`). Remove the file afterwards.
2. Move the switch ON then OFF: `tsem status` shows `mode=german`/`direct`, `hw_source=event`, `hw_match=yes`, and `source=hw`.
3. Reboot with the switch at each position: `hw_source=persisted` after boot; mode follows the persisted intent.
4. Optional: find a readable position source (`tsem hw-probe` lists sysfs GPIO and input candidates read-only) and set `TSEM_HW_GPIO_VALUE`/`TSEM_HW_GPIO_ON`.
## Polling
Fast 5 s only for connecting/recovery/blocked/error/unknown intent; 15 s with secondary active; 20 s with primary active; 60 s in direct. Events act immediately. Expected load: each tick is one shell run with a few iptables-save/ip calls. Real CPU/wake numbers are not measured (hardware proof pending).
