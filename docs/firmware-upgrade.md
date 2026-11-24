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
