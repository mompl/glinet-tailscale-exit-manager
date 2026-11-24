# Emergency recovery without the TSEM GUI

Use this when the GL.iNet UI, LuCI, the API or Home Assistant are unusable. Everything below runs in an SSH shell on the
router (`ssh root@10.20.0.1` from the LAN, or over Tailscale). The management address `10.20.0.1` stays reachable from the LAN in
every mode (packet-tested in the netns suite, `s_control_and_management_in_all_states`). Nothing here has been run on the
GL-MT3000 by this project: the commands are checked against the code and the netns suite only.

**Principle:** recovery never opens the kill switch by itself. A closed kill switch (GERMAN with no working exit node = BLOCKED)
is not a fault of the router, it is the protection working. You open it only by an explicit step below.

## 1. Look first (read-only)

    tsem status          # mode, state, guard, exit_node, leak_risk
    tsem diag            # more detail, no changes

## 2. The LAN has no Internet and you want it back, now (DIRECT = your WAN, no exit node)

    tsem set direct

This is the only step that opens the kill switch. Check with `tsem status` (`mode=direct`, `guard=open`).
The physical GL.iNet switch in the OFF position does the same thing through the installed hook.

## 3. You want GERMAN back

    tsem set german      # or: tsem set blocked   (closed on purpose, no exit node)
    tsem status

If both exit nodes are down the state is BLOCKED and stays so until one comes back; it never falls back to the WAN.

## 4. The controller itself misbehaves

    /etc/init.d/tsem stop        # stops the daemon; the guard STAYS as it is (never opens it)
    tsem reapply                 # re-applies the saved mode from /etc/tsem/intent
    /etc/init.d/tsem start

## 5. tsem is broken and the LAN must work: remove all rules

    tsem teardown                # removes the tsem chains, hooks and ip rules: kill switch OFF, Internet direct
    rm -f /etc/rc.d/S18tsem      # so that a reboot does not close the guard again from the saved intent

Do this only when you accept unprotected Internet. A reboot WITHOUT removing `S18tsem` brings the guard back from the saved
mode (fail-closed by design); that is why a reboot alone does not restore access.

## 6. Go back to the version before the upgrade

From the Mac (the acceptance runner keeps a verified backup in `~/tsem-rc3-active/`):

    sh tools/run-rc3-active-mac.sh --stage "$PWD" rollback

or on the router, from a staged copy of the repository: `sh install.sh --rollback --yes`. Complete removal:
`sh uninstall.sh --yes` (this removes the kill switch; Tailscale's own settings and the masquerading are left unchanged).

## 7. Masquerading (only if LAN clients reach the tailnet or the exit node without NAT)

    uci get firewall.tailscale0.masq ; iptables -t nat -S zone_tailscale0_postrouting

TSEM never changes these. `tsem-masq` is an optional component and is not installed by default.
