# Firmware upgrades (GL.iNet / OpenWrt)

A firmware upgrade (`sysupgrade`, also the "Upgrade" button of the GL.iNet UI) replaces the whole system image. Everything
that is not on the keep list is gone afterwards: `/usr/sbin/tsem`, the GUI files, the boot links, the switch hook.

## What TSEM does about it (since the upgrade-protection change)

`install.sh` / `setup.sh` add three things (all removed again by `uninstall.sh`):

| What | Where | Purpose |
|---|---|---|
| Copy of the install package | `/etc/tsem/pkg/` | the source for the restore (offline, nothing is downloaded) |
| Keep list block | `/etc/sysupgrade.conf` (`# tsem-keep-begin ... # tsem-keep-end`) | `/etc/tsem/` (config, intent, package) and the restore boot script survive the upgrade |
| Restore boot script | `/etc/init.d/tsem-restore`, link `/etc/rc.d/S17tsem-restore` | runs at boot **before** tsem (18), firewall (19) and network (20) |

After the first boot on the new firmware the boot script notices that TSEM is missing and runs
`/etc/tsem/pkg/restore.sh`: it re-installs the components that were installed before (core, api, GUI parts), keeps the stored
mode (DIRECT / exit mode / BLOCKED) and the configuration, and starts the service. The kill switch is therefore back before
LAN traffic is forwarded. The result is in `/etc/tsem/restore.log` and `/etc/tsem/last-restore`.

If the new firmware refuses the GUI part (for example because the GL.iNet UI changed), the restore falls back to fewer
components (without the native GUI, then without the LuCI GUI, then core only), so the protection always comes back first.
The log then contains a `WARNING` line; install the matching release later to get the GUI back.

## Manual restore (if the automatic one did not work)

```sh
sh /etc/tsem/pkg/restore.sh --force      # same as the automatic run
# or, with a fresh release unpacked on the router:
sh setup.sh --yes                        # keeps the configuration, starts in DIRECT mode
```

## Limits (read this)

* **"Keep settings" must stay ticked** in the upgrade dialog (or use `sysupgrade` without `-n`). A reset to factory defaults
  removes `/etc/tsem` too; then run `setup.sh` again.
* Until the boot script has run, the router has no TSEM protection. On a normal upgrade this is the time of the first boot
  before service 17; if the restore itself fails (`CRITICAL` in the log), the router stays unprotected until you fix it.
  Check `tsem status` and `/etc/tsem/restore.log` after every upgrade.
* The restored TSEM is the version that was installed before the upgrade. It was tested on the old firmware only.
  After the upgrade run `tsem selftest` and check the GUI.
* Opt out with `sh install.sh --no-upgrade-keep`.

## Field notes (v1.1)

- **GL-MG1300 (Mango 2), 4.11.1 -> 4.11.2, online upgrade with "Keep Settings":** `/etc/tsem` and the restore boot script were kept, tsem restored
  its files by itself and reinstalled `ip6tables` after about three minutes. Mode (DIRECT) and settings were unchanged.
- **GL-E5800 (Mudi 7), 4.10.3 -> 4.10.4:** after the upgrade tsem was gone completely (no `/etc/tsem`, no service, no kill switch) and the router
  sent traffic directly for hours. `/etc/sysupgrade.conf` was the firmware default again. Tailscale itself was kept. The cause is not known
  (it can depend on "Keep Settings" or on the firmware). A router cannot report its own wipe.
- **What to do after EVERY firmware upgrade:** `tsem status` (mode and state as before?), `tsem selftest`. If `tsem` is not found, run `setup.sh` again
  with your exit nodes (`--exit` to go back to the protected mode at once). On a router that is protected, an update with `setup.sh` (v1.1) keeps it protected.

## Two uplinks (GL-E5800 Mudi 7): multi-WAN "balance" can break DIRECT for some destinations
With two uplinks (Wi-Fi repeater and cellular) the firmware's multi-WAN (`kmwan`, mode `balance`) hashes every connection to one of them. On the Mudi 7 the
cellular uplink got no answer for Cloudflare addresses (SYN out, nothing back, ping fine) so `example.com`/`myip.wtf` timed out while other sites worked,
in DIRECT only. The exit-node mode is not affected (everything goes through the tunnel). Fix: `uci set kmwan.global.mode=failover; uci commit kmwan;
/etc/init.d/kmwan reload` (Wi-Fi first, cellular only when the Wi-Fi uplink is down). `tsem selftest` warns (`multiwan`) when it sees balance mode with two uplinks.

## Two keep lists (v1.1)
The installer writes the list of files that must survive a firmware upgrade (`/etc/tsem/`, the restore boot script) twice: as a block in
`/etc/sysupgrade.conf` and as `/lib/upgrade/keep.d/tsem` (the mechanism packages use; the file keeps itself). Some firmware flows honour only keep.d
(GL-E5800 4.10.4: the dropbear keys of keep.d survived, the user block in sysupgrade.conf did not, and tsem was gone). Either one is enough.
Check on the router: `sysupgrade -b /tmp/k.tar.gz && tar tzf /tmp/k.tar.gz | grep tsem` lists what an upgrade would keep (nothing is upgraded).
