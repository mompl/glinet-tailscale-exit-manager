#!/bin/sh
umask 077
# tsem discovery - READ-ONLY.
#
# Collects facts needed for design decisions on a GL.iNet / OpenWrt router.
# It only READS: no configuration changes, no service restarts, no firewall
# changes. The only things it creates are the report file and (on failure of
# the safety check) it removes that report again.
#
# Safety properties:
#  - report is created with mode 600 (umask 077 + explicit chmod) via mktemp
#  - every command output passes through redact(), which masks auth keys,
#    preauth keys, tokens, passwords, private/preshared keys, key blocks,
#    URL credentials, bearer tokens, MACs, e-mail addresses and tailnet names
#  - config dumps (uci) drop secret-bearing lines first, then are redacted
#  - tailscale prefs are an allowlist of fields, never the full prefs dump
#  - glconfig is filtered to tailscale/switch/button/mode related lines
#  - after writing, the report is scanned for leftover secret patterns; if any
#    is found the report is deleted and the script exits with an error
#  - no dynamic code execution: every section is an ordinary function call
#  - POSIX sh / BusyBox ash compatible (no bashisms, no local, no [[ ]])
#
# Redaction is best effort. Still review the report before sharing it: it
# contains local IP addresses, routes, interface names and peer host names.

set -u

VERSION=2
LIMIT=400   # max lines kept per section

# Key-name fragments that mark a value as secret (case-insensitive via classes).
W='[Pp][Aa][Ss][Ss]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Aa][Uu][Tt][Hh]|[Pp][Ss][Kk]|[Cc][Rr][Ee][Dd]|[Uu][Ss][Ee][Rr][Nn][Aa][Mm][Ee]'

# Mask secrets on stdin. Order matters: block, URL and Authorization-header
# forms first (they would otherwise be half-masked by the generic key rule).
redact() {
	sed -E \
		-e '/-----BEGIN [A-Z ]*KEY-----/,/-----END [A-Z ]*KEY-----/s/.*/<redacted key block>/' \
		-e "s#(://)[^/@[:space:]]+:[^/@[:space:]]*@#\\1<redacted>@#g" \
		-e "s/([Aa]uthorization[[:space:]]*[:=][[:space:]]*).*/\\1<redacted>/" \
		-e "s/([\"']?[A-Za-z0-9_.-]*(${W})[A-Za-z0-9_.-]*[\"']?[[:space:]]*[=:][[:space:]]*)(\"[^\"]*\"|'[^']*'|[^[:space:],;]+)/\\1<redacted>/g" \
		-e "s/^([[:space:]]*(option|list)[[:space:]]+[A-Za-z0-9_.-]*(${W})[A-Za-z0-9_.-]*[[:space:]]+).*/\\1<redacted>/" \
		-e "s/tskey-[A-Za-z0-9_-]+/tskey-<redacted>/g" \
		-e "s/(--?[Aa]uth-?[Kk]ey[[:space:]]+)[^[:space:]]+/\\1<redacted>/g" \
		-e "s/(privkey|nodekey|mkey|discokey|nlpub|nlpriv):[0-9a-fA-F]+/\\1:<redacted>/g" \
		-e "s#(tailscale\\.com/a/)[A-Za-z0-9]+#\\1<redacted>#g" \
		-e "s#([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/=-]+#\\1<redacted>#g" \
		-e "s#[A-Za-z0-9+/]{43}=#<redacted key>#g" \
		-e "s/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g" \
		-e "s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/<email>/g" \
		-e "s/[A-Za-z0-9-]+\\.ts\\.net/<tailnet>.ts.net/g"
}

# Keep at most $LIMIT lines.
limit() {
	awk -v m="$LIMIT" 'NR <= m { print } NR == m + 1 { print "[... truncated at " m " lines ...]" }'
}

# Drop lines whose KEY NAME (text before the first "=") looks secret-bearing.
drop_secret_lines() {
	awk '{
		l = tolower($0); k = l; sub(/=.*/, "", k)
		if (k ~ /(private_?key|preshared_?key|pass(word|wd)?|psk|secret|token|auth_?key)/) { n++; next }
		print
	}
	END { if (n) print "# " n " secret-bearing line(s) omitted" }'
}

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n===== %s =====\n' "$1" >>"$OUT"; }

# out: redact + limit stdin into the report
out() { redact | limit >>"$OUT"; }

# try CMD ARGS...: run CMD only if it exists
try() {
	if have "$1"; then "$@"; else echo "(n/a: $1 not installed)"; fi
}

uci_show() {
	if have uci; then
		uci show "$1" 2>&1 | drop_secret_lines
	else
		echo "(n/a: uci not installed)"
	fi
}

# tailscale prefs: allowlisted fields only (full prefs can contain node keys)
ts_prefs() {
	if have tailscale; then
		tailscale debug prefs 2>&1 | awk '
			/"(ExitNodeID|ExitNodeIP|ExitNodeAllowLANAccess|CorpDNS|RouteAll|ShieldsUp|AdvertiseRoutes|NoSNAT|NetfilterMode|WantRunning|RunSSH|AutoUpdate)"/ {
				print
				if ($0 ~ /\[$/) arr = 1
				next
			}
			arr { print; if ($0 ~ /\]/) arr = 0 }'
	else
		echo "(n/a: tailscale not installed)"
	fi
}

# Returns 0 if FILE looks clean, 1 if a secret-like pattern survived redaction.
leak_check() {
	_lc_hits=$(grep -E 'tskey-[A-Za-z0-9]|(privkey|nodekey|mkey|nlpriv):[0-9a-fA-F]{8}|BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9+/]{43}=' "$1" 2>/dev/null | grep -vc 'redacted')
	[ "${_lc_hits:-0}" -eq 0 ]
}

main() {
	_host=$(tr -cd 'A-Za-z0-9._-' </proc/sys/kernel/hostname 2>/dev/null)
	[ -n "$_host" ] || _host=router
	OUT=$(mktemp "/tmp/tsem-discovery-$_host.XXXXXX") || {
		echo "error: cannot create report file" >&2
		exit 1
	}
	chmod 600 "$OUT" || {
		echo "error: cannot set report permissions" >&2
		exit 1
	}

	{
		echo "# tsem discovery v$VERSION (read-only)"
		echo "# date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "# secrets are masked on a best-effort basis; review before sharing"
	} >>"$OUT"

	section "openwrt_release"
	{ try cat /etc/openwrt_release; } 2>&1 | out
	section "glversion / model"
	{
		[ -r /etc/glversion ] && cat /etc/glversion
		[ -r /tmp/sysinfo/model ] && cat /tmp/sysinfo/model
	} 2>&1 | out
	section "uname"
	{ try uname -a; } 2>&1 | out
	section "ubus system board"
	{ try ubus call system board; } 2>&1 | out
	section "disk / memory"
	{ try df -h; try free; } 2>&1 | out
	section "tools present"
	for _c in opkg apk nft iptables ip6tables fw4 fw3 ucode jsonfilter ubus mosquitto_pub tailscale curl wget tcpdump flock md5sum mktemp; do
		if _p=$(command -v "$_c" 2>/dev/null); then echo "$_c: $_p"; else echo "$_c: -"; fi
	done 2>&1 | out
	section "relevant packages"
	{ try opkg list-installed | grep -Ei 'tailscale|firewall|nftables|iptables|kmod-nft|dnsmasq|mosquitto|ucode|gl-|glinet'; } 2>&1 | out
	section "tailscale version"
	{ try tailscale version; } 2>&1 | out
	section "tailscale status"
	{ try tailscale status; } 2>&1 | out
	section "tailscale prefs (allowlist)"
	ts_prefs 2>&1 | out
	section "ip addr"
	{ try ip -4 addr; try ip -6 addr; } 2>&1 | out
	section "ip route (all tables)"
	{ try ip -4 route show table all; try ip -6 route show table all; } 2>&1 | out
	section "ip rule"
	{ try ip -4 rule; try ip -6 rule; } 2>&1 | out
	section "uci network (secret lines omitted)"
	uci_show network 2>&1 | out
	section "uci firewall (secret lines omitted)"
	uci_show firewall 2>&1 | out
	section "uci dhcp (secret lines omitted)"
	uci_show dhcp 2>&1 | out
	section "uci tailscale (secret lines omitted)"
	uci_show tailscale 2>&1 | out
	section "uci glconfig (filtered: tailscale|switch|button|mode)"
	uci_show glconfig 2>&1 | grep -Ei 'tailscale|switch|button|mode' | out
	section "nft ruleset"
	{ try nft list ruleset; } 2>&1 | out
	section "iptables-save"
	{ try iptables-save; try ip6tables-save; } 2>&1 | out
	section "gl-switch / hotplug directories"
	{ ls -la /etc/gl-switch.d/ /etc/hotplug.d/ /etc/hotplug.d/button /etc/hotplug.d/switch; } 2>&1 | out
	section "init scripts of interest"
	{ ls -la /etc/init.d/ | grep -Ei 'tailscale|gl_|gl-|firewall|dnsmasq|network|tsem'; } 2>&1 | out
	section "files mentioning tailscale (names only)"
	{ grep -rIl -i tailscale /etc/init.d /etc/hotplug.d /etc/gl-switch.d /usr/bin /usr/sbin /usr/lib/oui-httpd | head -n 50; } 2>&1 | out
	section "processes of interest"
	{ ps w | grep -E 'tailscale|gl_|gl-|dnsmasq|procd|rpcd|uhttpd|nginx|oui' | grep -v grep; } 2>&1 | out
	section "sysupgrade keep list"
	{ [ -r /etc/sysupgrade.conf ] && cat /etc/sysupgrade.conf; ls /lib/upgrade/keep.d/; } 2>&1 | out
	section "gpio / input (switch candidates)"
	{ cat /sys/class/gpio/gpio*/value; ls /sys/class/gpio; ls /dev/input; } 2>&1 | out
	section "ubus objects"
	{ try ubus list | head -n 60; } 2>&1 | out
	section "log excerpts (tailscale|switch|firewall)"
	{ try logread | grep -Ei 'tailscale|switch|firewall' | tail -n 60; } 2>&1 | out

	if ! leak_check "$OUT"; then
		rm -f "$OUT"
		echo "error: secret-like content survived redaction; report deleted" >&2
		exit 3
	fi
	echo "Report: $OUT (mode 600)"
}

# Allow tests to source the helper functions without running main.
if [ "${TSEM_DISCOVERY_NOEXEC:-0}" != 1 ]; then
	main "$@"
fi
