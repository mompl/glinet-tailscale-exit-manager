# Install, rollback, uninstall

Copy the repo (or tarball) to the router, then **on the router, as root**. Nothing below is executed by CI or by Claude.

```
sh install.sh                      # DRY RUN: preflight + plan, changes nothing
sh install.sh --yes               # default: boot symlinks S18tsem/K10tsem and the GL switch hook are installed (still no start)
sh install.sh --yes --no-enable # skip the boot symlinks
sh install.sh --yes --keep-gl-hook  # keep the existing /etc/gl-switch.d/tailscale-de.sh (default: replaced, original backed up and restored by rollback/uninstall)
sh install.sh --rollback --yes     # restore the state before the last install
sh uninstall.sh --yes [--purge]    # remove tsem (keeps config + backups unless --purge)
```
Options: `--root DIR` (install into a staging root), `--force` (ignore preflight), `--no-firewall-include`, `--initial-mode`.

## Guarantees (covered by `tests/t_install.sh`)
- dry run by default; idempotent; `tsem.conf`, `mqtt.conf` and the intent file are never overwritten;
- transactional: a failure at any injected point leaves the system byte-identical;
- backups in `/etc/tsem/backup/<stamp>`; manifest `/etc/tsem/install.manifest`;
- the firewall include is a marked block (`# tsem-begin` … `# tsem-end`) removed by uninstall;
- the installer never starts/restarts firewall, network, tailscale or tsem; activation is a separate step: `/etc/init.d/tsem enable && /etc/init.d/tsem start`;
- uninstall: stop daemon → `tsem teardown` (opens the kill switch, i.e. back to plain internet) → restore GL hook → remove files; locally modified files are moved to `backup/uninstall-modified`.

## Emergency exit (any time, on the router)
```
/usr/sbin/tsem set direct          # preferred
/usr/sbin/tsem teardown            # removes all tsem rules
tailscale set --exit-node=         # clears the exit node
```
Stopping the service intentionally does NOT open the kill switch (fail closed).
