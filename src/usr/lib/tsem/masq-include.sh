#!/bin/sh
# fw3 firewall include (option reload '1') of the tsem-masq component: fw3 rebuilds the zone chains from
# /etc/config/firewall on every reload. If the GL.iNet firmware wrote masq=0 for the tailscale0 zone, repair it
# right after the reload. NEVER fails the firewall run, NEVER reloads (that would recurse), touches no kill-switch rule.
[ -x /usr/sbin/tsem-masq ] || exit 0
TSEM_MASQ_NORELOAD=1 /usr/sbin/tsem-masq ensure >/dev/null 2>&1
exit 0
