#!/bin/sh
umask 077
# tsem collector v4 - READ-ONLY, single pass.
#
# Collects the facts the glinet-tailscale-exit-manager design needs from a
# GL.iNet / OpenWrt router (GL-MT3000, GL-MG1300, ...) into ONE structured
# report. It only READS. It never changes configuration, firewall, routing or
# Tailscale settings, never restarts services, never installs packages, never
# sends traffic to other hosts (no ping/curl/netcheck) and never reads
# Tailscale state files or key material.
#
# Privacy design (allowlist first, redaction second):
#   - no process arguments (only process names; tailscaled: allowlisted flags)
#   - no raw system log (only allowlisted netifd/firewall/procd/tailscale events)
#   - scripts: metadata + allowlisted command lines, secret-like lines suppressed;
#     full contents only for the switch/button scripts and only with --full-scripts
#   - uci: key allowlists (no keys, passwords, SSIDs, static leases)
#   - redaction and a leak check are a safety net, NOT a guarantee
#
# Usage (see docs/discovery/README-collector.md):
#   ssh root@ROUTER 'sh -s' < collect.sh > report.txt
#   options after "sh -s --":  --keep  keep the 600 report in /tmp
#                              --full-scripts  include full switch/button scripts
#
# Report format: sections "## [ID] title", each followed by a status line
# "# [ID] status=ok|partial ...". The tail is "## SUMMARY", "## INDEX" and
# "## END lines=N sha256=H". An END line alone is NOT proof of completeness:
# check "completeness=complete" in the SUMMARY and the lines/sha256 values.

set -u

VERSION=4
LIMIT=${TSEM_LIMIT:-300}          # default max lines per section
BIGLIMIT=${TSEM_BIGLIMIT:-1200}   # firewall dumps etc.
PROC=${TSEM_PROC:-/proc}          # overridable for tests only
KEEP=0
FULL=0
OUT=''
CAP=''
SEC=''
TO=''
NI=''

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
		-e "s/([Ss][Ss][Ii][Dd][[:space:]=:]+).*/\\1<redacted>/" \
		-e "s/tskey-[A-Za-z0-9_-]+/tskey-<redacted>/g" \
		-e "s/(--?[Aa]uth-?[Kk]ey[[:space:]]+)[^[:space:]]+/\\1<redacted>/g" \
		-e "s/(privkey|nodekey|mkey|discokey|nlpub|nlpriv):[0-9a-fA-F]+/\\1:<redacted>/g" \
		-e "s#(tailscale\\.com/a/)[A-Za-z0-9]+#\\1<redacted>#g" \
		-e "s#([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/=-]+#\\1<redacted>#g" \
		-e "s#[A-Za-z0-9+/]{43}=#<redacted key>#g" \
		-e "s/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g" \
		-e "s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/<email>/g" \
		-e "s/[A-Za-z0-9-]+\\.ts\\.net/<tailnet>.ts.net/g" \
		-e "s/[A-Za-z0-9-]+\\.glddns\\.com/<ddns>.glddns.com/g"
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

# emit N: redact stdin, keep at most N lines, then ALWAYS write a status line
# for the current section. Failure markers ("!! failed", "!! n/a") and
# truncation are counted before limiting, so nothing is hidden.
emit() {
	redact | awk -v m="$1" -v id="$SEC" '
		{ raw++ }
		/^!! failed/ { f++ }
		/^!! n\/a/ { na++ }
		raw <= m { print }
		END {
			t = (raw > m)
			if (t) print "[... truncated at " m " of " raw " lines ...]"
			printf "# [%s] status=%s issues=%d na=%d lines=%d truncated=%d\n", id, ((f || t) ? "partial" : "ok"), f + 0, na + 0, raw + 0, t
		}' >>"$OUT"
}

have() { command -v "$1" >/dev/null 2>&1; }
note() { printf '%s\n' "$*" >&2; }

# tcap CMD ARGS...: run an EXTERNAL command (nice + timeout), stdout+stderr go to
# $CAP. Prints a marker on stdout if the command is missing or fails; callers
# then filter $CAP. Never pipe tcap itself into a filter (markers must survive).
tcap() {
	: >"$CAP"
	if ! have "$1"; then
		echo "!! n/a: $1"
		return 1
	fi
	$TO "$@" >"$CAP" 2>&1
	_tc_rc=$?
	if [ "$_tc_rc" -ne 0 ]; then
		echo "!! failed rc=$_tc_rc: $*"
	fi
	return "$_tc_rc"
}

# try CMD ARGS...: tcap + show everything
try() {
	tcap "$@"
	cat "$CAP"
}

cat_file() {
	if [ -r "$1" ]; then head -n 300 "$1"; else echo "(absent: $1)"; fi
}

section() {
	SEC=$1
	printf '\n## [%s] %s\n' "$1" "$2" >>"$OUT"
	note "collecting [$1] $2"
}

detect_wrappers() {
	NI=''
	if have nice && nice -n 19 true >/dev/null 2>&1; then NI='nice -n 19'; fi
	_dw_t=''
	if have timeout; then
		if timeout 1 true >/dev/null 2>&1; then
			_dw_t='timeout 30'
		elif timeout -t 1 true >/dev/null 2>&1; then
			_dw_t='timeout -t 30'
		fi
	fi
	TO="$NI $_dw_t"
}

# Second line of defence on the finished report. Prints only COUNTS to stderr.
# Returns 0 if clean, 1 if a secret-like pattern survived redaction.
leak_check() {
	_lc_a=$(grep -E 'tskey-[A-Za-z0-9]|(privkey|nodekey|mkey|nlpriv):[0-9a-fA-F]{8}|BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9+/]{43}=' "$1" 2>/dev/null | grep -vc 'redacted')
	_lc_b=$(grep -Ei "(passw(or)?d|passphrase|secret|psk|token|api_?key|auth_?key|private_?key)[A-Za-z0-9_]*[\"']?[[:space:]]*[=:][[:space:]]*[\"']?[^[:space:]<\"']{4,}" "$1" 2>/dev/null | grep -vc 'redacted')
	if [ "${_lc_a:-0}" -ne 0 ] || [ "${_lc_b:-0}" -ne 0 ]; then
		echo "leak check: key-pattern lines=${_lc_a:-0}, assignment-pattern lines=${_lc_b:-0}" >&2
		return 1
	fi
	return 0
}

cleanup() {
	if [ -n "$CAP" ]; then rm -f "$CAP"; fi
	if [ "$KEEP" != 1 ] && [ -n "$OUT" ]; then rm -f "$OUT"; fi
}

# ---- allowlist helpers ----------------------------------------------------------

# uci_allow CONFIG KEY_REGEX: section lines + options whose last key segment
# matches KEY_REGEX (values still pass through redact).
uci_allow() {
	tcap uci show "$1"
	awk -v re="$2" '{
		k = $0; sub(/=.*/, "", k); n = split(k, a, ".")
		if (n <= 2) { print; next }
		if (a[n] ~ re) print
	}' "$CAP" | drop_secret_lines
}

# uci key names only (inventory), no values
uci_keys() {
	tcap uci show "$1"
	awk -F= '{ print $1 }' "$CAP"
}

# Process names with counts (never arguments).
proc_names() {
	cat "$PROC"/[0-9]*/comm 2>/dev/null | sort | uniq -c | sort -rn
}

# tailscaled: only allowlisted flags (never --auth-key & co).
tailscaled_args() {
	for _ta_c in $(grep -lx tailscaled "$PROC"/[0-9]*/comm 2>/dev/null); do
		_ta_d=${_ta_c%/comm}
		echo "tailscaled pid_dir=$(basename "$_ta_d")"
		tr '\0' '\n' <"$_ta_d/cmdline" 2>/dev/null | grep -E '^(/|--(state|socket|port|tun|statedir|cleanup|no-logs-no-support|verbose|debug)(=|$))'
	done
}

# Script view: metadata + allowlisted lines. Full contents only if $2 = 1.
SV_PAT='iptables|ip6tables|nft |ipset|tailscale|ip rule|ip route|ip -[46]|uci |gpio|switch|button|action|flock|init.d|firewall|exit-node|exec |start_service|stop_service|service_triggers|procd|hotplug|^#!|ubus|logger|sleep|mqtt|/tmp/|/var/run|/etc/|iface|reload|restart'
SV_BAD='pass|secret|token|key|auth|psk|cred|user|login|cookie|bearer'
script_view() {
	[ -f "$1" ] || { echo "(absent: $1)"; return 0; }
	_sv_sum=n/a
	if have sha256sum; then _sv_sum=$(sha256sum <"$1" 2>/dev/null | cut -d' ' -f1); fi
	echo "# ===== $1 bytes=$(wc -c <"$1" | tr -d ' ') lines=$(wc -l <"$1" | tr -d ' ') sha256=$_sv_sum"
	if [ "${2:-0}" = 1 ]; then
		echo "# (full contents, --full-scripts)"
		head -n 200 "$1"
		return 0
	fi
	awk -v pat="$SV_PAT" -v bad="$SV_BAD" '
		{ l = tolower($0) }
		l ~ bad { if (l ~ pat) sup++; next }
		l ~ pat { if (++n <= 80) print NR ": " substr($0, 1, 200) }
		END {
			if (n > 80) print "# ... " n - 80 " more matching lines not shown"
			if (sup) print "# " sup " matching line(s) suppressed (secret-like words)"
		}' "$1"
}

# Full contents only for the user-relevant switch/button scripts and only on request.
sv_auto() {
	_sa_full=0
	if [ "$FULL" = 1 ]; then
		case $1 in
		/etc/gl-switch.d/* | /etc/hotplug.d/button/* | /etc/hotplug.d/switch/* | /etc/rc.button/*) _sa_full=1 ;;
		esac
	fi
	script_view "$1" "$_sa_full"
}

# Resource-bounded script discovery: small regular files in relevant dirs only.
list_small() { $NI find "$@" -type f -size -128 2>/dev/null | head -n 500; }
scan_stdin() { head -n 500 | $NI xargs grep -lE "$1" /dev/null 2>/dev/null | head -n 100; }

lan_dev() {
	_ld=$(uci -q get network.lan.device 2>/dev/null)
	[ -n "$_ld" ] || _ld=$(uci -q get network.lan.ifname 2>/dev/null)
	[ -n "$_ld" ] || _ld=br-lan
	echo "$_ld"
}

# stdin: iptables-save output -> "<fam> <table> <chain> policy=<p> rules=<n>"
chain_summary() {
	awk -v fam="$1" '
		/^\*/ { t = substr($0, 2); next }
		/^:/ { c = substr($1, 2); key = t " " c; if (!(key in seen)) { seen[key] = 1; order[++n] = key }; pol[key] = $2; next }
		/^-A / { key = t " " $2; cnt[key]++ }
		END { for (i = 1; i <= n; i++) printf "%s %s policy=%s rules=%d\n", fam, order[i], pol[order[i]], cnt[order[i]] + 0 }'
}

# stdin: iptables-save output -> base-chain rules in file order
base_jumps() {
	awk -v fam="$1" '
		/^\*/ { t = substr($0, 2); next }
		/^-A (INPUT|FORWARD|OUTPUT|PREROUTING|POSTROUTING) / { print fam " " t " " $0 }'
}

# tailscale prefs: allowlisted fields only (full prefs can contain node keys)
ts_prefs() {
	tcap tailscale debug prefs || return 0
	awk '
		/"(ExitNodeID|ExitNodeIP|ExitNodeAllowLANAccess|CorpDNS|RouteAll|ShieldsUp|AdvertiseRoutes|NoSNAT|NetfilterMode|WantRunning|RunSSH|AutoUpdate)"/ {
			print
			if ($0 ~ /\[$/) arr = 1
			next
		}
		arr { print; if ($0 ~ /\]/) arr = 0 }' "$CAP"
}

# tailscale status --json: allowlisted fields only (no keys, no endpoints, no AuthURL)
ts_status_json() {
	tcap tailscale status --json || return 0
	awk '
		/"ExitNodeStatus": \{/ { print; blk = 1; next }
		blk { print; if ($0 ~ /^[ \t]*\},?$/) blk = 0; next }
		/"(BackendState|HostName|OS|Online|ExitNode|ExitNodeOption|Relay|LastHandshake|LastSeen|Active|InNetworkMap|InEngine)"/ { print; next }
		/"(TailscaleIPs|AllowedIPs|PrimaryRoutes|Health)": \[/ { print; if ($0 !~ /\]/) arr = 1; next }
		arr { print; if ($0 ~ /\]/) arr = 0 }' "$CAP"
}

# procd services: name + running/stopped counts only (no command lines, no env).
svc_summary() {
	tcap ubus call service list || return 0
	awk '
		/^\t"[^"]+": \{$/ { s = $1; gsub(/[":]/, "", s); next }
		/"running": (true|false)/ { r = ($0 ~ /true/) ? "running" : "stopped"; c[s " " r]++ }
		END { for (k in c) print k, c[k] }' "$CAP" | sort
}

# ---- sections ------------------------------------------------------------------

s00() {
	section 00 "identity and platform"
	{
		echo "collector_version=$VERSION"
		echo "collector_args=keep:$KEEP full_scripts:$FULL"
		echo "date_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "uptime_seconds=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
		echo "loadavg=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
		echo "id=$(id 2>&1)"
		echo "uname=$(uname -a 2>&1)"
		if have busybox; then echo "busybox=$(busybox 2>&1 | head -n 1)"; else echo "busybox=-"; fi
		echo "wrappers=$TO"
		for _f in /tmp/sysinfo/model /tmp/sysinfo/board_name /proc/device-tree/model /etc/glversion /etc/openwrt_version; do
			[ -r "$_f" ] && echo "$_f=$(tr -d '\000' <"$_f" | head -n 1)"
		done
		echo "--- /etc/openwrt_release"
		cat_file /etc/openwrt_release
		echo "--- ubus system board"
		try ubus call system board
		echo "--- opkg architectures"
		try opkg print-architecture
		echo "--- kernel cmdline"
		cat_file /proc/cmdline
		echo "--- cpu"
		head -n 14 /proc/cpuinfo 2>&1
		echo "--- memory"
		head -n 5 /proc/meminfo 2>&1
		echo "--- df"
		try df -h
		echo "--- mounts (root, overlay, tmp)"
		grep -E ' (/|/overlay|/tmp|/rom) ' /proc/mounts 2>&1
	} 2>&1 | emit "$LIMIT"
}

s01() {
	section 01a "netfilter tools, versions, loaded tables"
	{
		for _t in iptables ip6tables iptables-restore ip6tables-restore iptables-save ip6tables-save iptables-legacy iptables-legacy-save iptables-nft xtables-nft-multi xtables-legacy-multi ebtables ebtables-save arptables ipset nft conntrack fw3 fw4; do
			if _p=$(command -v "$_t" 2>/dev/null); then echo "$_t -> $(readlink -f "$_p" 2>/dev/null || echo "$_p")"; else echo "$_t: -"; fi
		done
		echo "--- versions"
		try iptables -V
		try ip6tables -V
		try nft --version
		try ipset --version
		echo "--- /proc/net/ip_tables_names"
		cat_file /proc/net/ip_tables_names
		echo "--- /proc/net/ip6_tables_names"
		cat_file /proc/net/ip6_tables_names
		echo "--- nft tables"
		try nft list tables
	} 2>&1 | emit "$LIMIT"

	section 01b "iptables-save -c (IPv4: filter, nat, mangle, raw; with counters)"
	{ try iptables-save -c; } 2>&1 | emit "$BIGLIMIT"

	section 01c "ip6tables-save -c (IPv6)"
	{ try ip6tables-save -c; } 2>&1 | emit "$BIGLIMIT"

	section 01d "ebtables / nft ruleset"
	{
		try ebtables-save
		echo "--- nft list ruleset"
		try nft list ruleset
	} 2>&1 | emit "$LIMIT"

	section 01e "chain summary (policy, rule count) and base-chain order"
	{
		tcap iptables-save
		chain_summary ip4 <"$CAP"
		base_jumps ip4 <"$CAP"
		tcap ip6tables-save
		chain_summary ip6 <"$CAP"
		base_jumps ip6 <"$CAP"
	} 2>&1 | emit "$BIGLIMIT"

	section 01f "fw3 configuration (uci export, ordered)"
	{ try uci export firewall; } 2>&1 | emit "$BIGLIMIT"

	section 01g "firewall includes and hook scripts (metadata + allowlisted lines)"
	{
		echo "--- includes in uci"
		tcap uci show firewall
		grep -Ei 'include|\.path=|\.script=' "$CAP"
		echo "--- listing"
		ls -la /etc/firewall.user /etc/firewall.d /lib/firewall /usr/share/firewall /etc/hotplug.d/firewall /etc/nftables.d 2>&1
		sv_auto /etc/firewall.user
		for _f in /etc/hotplug.d/firewall/* /etc/firewall.d/*; do
			[ -f "$_f" ] && sv_auto "$_f"
		done
		for _f in $(grep -E '\.path=' "$CAP" | cut -d= -f2 | tr -d "'" | head -n 10); do
			[ -f "$_f" ] && sv_auto "$_f"
		done
	} 2>&1 | emit "$BIGLIMIT"

	section 01h "scripts referencing iptables/nft (names; small files in relevant dirs only)"
	{
		_fw_files=$({
			list_small /etc/init.d /etc/hotplug.d /etc/gl-switch.d /etc/firewall.d /etc/rc.button /lib/firewall /usr/share/firewall
			$NI find /usr/bin /usr/sbin -maxdepth 1 -type f -name 'gl*' -size -128 2>/dev/null | head -n 100
		} | scan_stdin 'iptables|ip6tables|nft |ipset')
		echo "$_fw_files"
		echo "--- allowlisted lines of GL/VPN/tailscale related ones (max 8 files)"
		_n=0
		for _f in $(echo "$_fw_files" | grep -Ei 'gl|tailscale|vpn|kill|block|switch'); do
			[ "$_n" -lt 8 ] || break
			_n=$((_n + 1))
			sv_auto "$_f"
		done
	} 2>&1 | emit "$BIGLIMIT"

	section 01i "ipset and conntrack"
	{
		try ipset list -n
		echo "--- ipset terse"
		try ipset list -t
		echo "--- conntrack"
		for _k in nf_conntrack_count nf_conntrack_max; do
			echo "$_k=$(cat /proc/sys/net/netfilter/$_k 2>/dev/null)"
		done
	} 2>&1 | emit "$LIMIT"

	section 01j "forwarding, rp_filter, IPv6 sysctls (read from /proc/sys)"
	{
		for _f in /proc/sys/net/ipv4/ip_forward /proc/sys/net/ipv4/conf/all/forwarding /proc/sys/net/ipv6/conf/all/forwarding \
			/proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/all/accept_ra /proc/sys/net/bridge/bridge-nf-call-iptables \
			/proc/sys/net/bridge/bridge-nf-call-ip6tables; do
			echo "$_f=$(cat "$_f" 2>/dev/null || echo n/a)"
		done
		for _f in /proc/sys/net/ipv4/conf/*/rp_filter /proc/sys/net/ipv6/conf/*/disable_ipv6 /proc/sys/net/ipv6/conf/*/accept_ra; do
			[ -r "$_f" ] && echo "$_f=$(cat "$_f" 2>/dev/null)"
		done
	} 2>&1 | emit "$LIMIT"

	section 01k "kernel modules, iptables extensions, kernel config symbols"
	{
		echo "--- lsmod (netfilter/tunnel related)"
		tcap lsmod
		awk '{ print $1, $3 }' "$CAP" | grep -E '^(nf_|nft_|xt_|ipt_|ip6t_|ip_set|iptable_|ip6table_|br_netfilter|ebt|tun |wireguard|tailscale)'
		echo "--- iptables extension libraries"
		ls /usr/lib/iptables /usr/lib/xtables 2>&1 | tr '\n' ' '
		echo
		echo "--- kernel config"
		if [ -r /proc/config.gz ]; then
			tcap zcat /proc/config.gz
			grep -E '^(# )?CONFIG_(NF_TABLES|NFT_|NETFILTER_XT_(MATCH|TARGET)_|IP_SET|IP_NF_|IP6_NF_|NF_CONNTRACK_MARK|NF_NAT|BRIDGE_NETFILTER|IP_MULTIPLE_TABLES|IPV6_MULTIPLE_TABLES|TUN|WIREGUARD)' "$CAP"
		else
			echo "(absent: /proc/config.gz)"
		fi
	} 2>&1 | emit "$BIGLIMIT"
}

s02() {
	section 02a "tailscale processes (names; allowlisted tailscaled flags), binaries, files (names only)"
	{
		echo "--- processes (names only)"
		proc_names | grep -E 'tailscale'
		tailscaled_args
		echo "--- binaries and directories (state files are NOT read)"
		ls -la /usr/sbin/tailscale /usr/sbin/tailscaled /usr/bin/tailscale /usr/bin/tailscaled /var/lib/tailscale /etc/tailscale /var/run/tailscale /tmp/tailscale 2>&1
		echo "--- versions"
		try tailscale version
		try tailscaled --version
	} 2>&1 | emit "$LIMIT"

	section 02b "tailscale status (human)"
	{ try tailscale status; } 2>&1 | emit "$LIMIT"

	section 02c "tailscale status --json (allowlisted fields)"
	ts_status_json 2>&1 | emit "$LIMIT"

	section 02d "tailscale prefs (allowlisted fields)"
	ts_prefs 2>&1 | emit "$LIMIT"

	section 02e "exit nodes, DNS, addresses"
	{
		echo "--- exit-node list"
		try tailscale exit-node list
		echo "--- dns status"
		try tailscale dns status
		echo "--- ip"
		try tailscale ip -4
		try tailscale ip -6
	} 2>&1 | emit "$LIMIT"

	section 02f "tailscale0 interface"
	{ try ip -d addr show tailscale0; try ip -s link show tailscale0; } 2>&1 | emit "$LIMIT"

	section 02g "tailscale service integration (init script, uci allowlist, callers)"
	{
		sv_auto /etc/init.d/tailscale
		echo "--- uci tailscale (allowlisted keys)"
		uci_allow tailscale '^(enabled|enable|port|fw_mode|firewall_mode|exit|exit_node|advertise_routes|routes|accept_dns|accept_routes|ssh|shields_up|state_dir|statedir|state_file|mode|listen)$'
		echo "--- who calls tailscale set/up/down (allowlisted command lines)"
		list_small /etc/init.d /etc/hotplug.d /etc/gl-switch.d /etc/rc.button | head -n 400 >"$CAP"
		[ -f /etc/rc.local ] && echo /etc/rc.local >>"$CAP"
		for _f in $(scan_stdin 'tailscale +(set|up|down)|--exit-node' <"$CAP" | head -n 20); do
			grep -nE 'tailscale +(set|up|down)|--exit-node' "$_f" | cut -c1-200 | sed "s#^#$_f:#"
		done
	} 2>&1 | emit "$LIMIT"
}

s03() {
	section 03a "gl-switch directory and prototype scripts (allowlisted lines; full with --full-scripts)"
	{
		ls -la /etc/gl-switch.d 2>&1
		for _f in /etc/gl-switch.d/*; do
			[ -f "$_f" ] && sv_auto "$_f"
		done
	} 2>&1 | emit "$BIGLIMIT"

	section 03b "button/switch hotplug scripts and who references gl-switch.d"
	{
		ls -la /etc/hotplug.d/button /etc/hotplug.d/switch /etc/rc.button 2>&1
		for _f in /etc/hotplug.d/button/* /etc/hotplug.d/switch/* /etc/rc.button/*; do
			[ -f "$_f" ] && sv_auto "$_f"
		done
		echo "--- files referencing gl-switch"
		{
			list_small /etc/init.d /etc/hotplug.d /etc/gl-switch.d /etc/rc.button /etc/rc.d /lib/functions
			$NI find /usr/bin /usr/sbin -maxdepth 1 -type f -name 'gl*' -size -128 2>/dev/null | head -n 100
		} | scan_stdin 'gl-switch|gl_switch'
	} 2>&1 | emit "$BIGLIMIT"

	section 03c "hardware: input devices, GPIO, device tree keys"
	{
		echo "--- /proc/bus/input/devices"
		cat_file /proc/bus/input/devices
		echo "--- /dev/input"
		ls -la /dev/input 2>&1
		echo "--- /sys/class/gpio"
		ls -la /sys/class/gpio 2>&1
		for _g in /sys/class/gpio/gpio*; do
			if [ -d "$_g" ]; then echo "$_g direction=$(cat "$_g/direction" 2>/dev/null) value=$(cat "$_g/value" 2>/dev/null)"; fi
		done
		echo "--- debugfs gpio (only if already mounted)"
		cat_file /sys/kernel/debug/gpio
		echo "--- device tree gpio-keys"
		for _d in /proc/device-tree/gpio-keys*/*; do
			if [ -d "$_d" ]; then echo "$_d label=$(tr -d '\000' <"$_d/label" 2>/dev/null)"; fi
		done
		echo "--- platform devices (gpio/key/switch/button)"
		ls /sys/devices/platform 2>&1 | grep -iE 'gpio|key|switch|button'
		echo "--- interrupts (gpio/key/button/switch)"
		grep -iE 'gpio|key|button|switch' /proc/interrupts 2>&1
	} 2>&1 | emit "$LIMIT"

	section 03d "ubus objects related to GL/switch/button/vpn/tailscale"
	{
		tcap ubus list
		grep -iE 'gl|switch|button|tailscale|vpn|wireguard|openvpn' "$CAP"
		echo "--- method signatures (ubus -v list)"
		try ubus -v list
	} 2>&1 | emit "$LIMIT"
}

s04() {
	section 04a "command availability"
	{
		for _c in busybox flock ipset iptables-restore ip6tables-restore iptables-save ip6tables-save nft ip bridge brctl iw iwinfo ss netstat timeout nice xargs find \
			md5sum sha256sum awk sed grep tr cut head tail wc date readlink mktemp od zcat jsonfilter jq ucode lua curl wget uclient-fetch openssl logger \
			mosquitto_pub mosquitto_sub nc tcpdump conntrack ethtool tc sysctl hotplug-call procd ubus uci opkg apk; do
			if _p=$(command -v "$_c" 2>/dev/null); then echo "$_c: $_p"; else echo "$_c: -"; fi
		done
	} 2>&1 | emit "$LIMIT"

	section 04b "busybox applets"
	{ tcap busybox --list; tr '\n' ' ' <"$CAP"; echo; } 2>&1 | emit "$LIMIT"

	section 04c "feature probes (no side effects)"
	{
		_p=$(echo abc | sed -E 's/(b)+/X/' 2>&1); echo "sed -E group: $_p"
		_p=$(echo 'a  b' | sed -E 's/[[:space:]]+/_/' 2>&1); echo "sed -E posix class: $_p"
		_p=$(echo aaaa | sed -E 's/a{3}/X/' 2>&1); echo "sed -E interval: $_p"
		_p=$(printf 'x\nBEGIN\ny\nEND\nz\n' | sed -E '/BEGIN/,/END/s/.*/R/' 2>&1 | tr '\n' ','); echo "sed range+s: $_p"
		_p=$(echo 'k=v' | sed -E 's#(k)=#\1:#' 2>&1); echo "sed -E # delimiter: $_p"
		_p=$(echo ABC=1 | awk '{ l = tolower($0); sub(/=.*/, "", l); print l }' 2>&1); echo "awk tolower+sub: $_p"
		_p=$(awk -v m=3 'BEGIN { print m + 1 }' 2>&1); echo "awk -v: $_p"
		_p=$(echo x | grep -E 'x|y' 2>&1); echo "grep -E: $_p"
		_p=$(echo x | grep -lx x /dev/null 2>&1; echo "rc=$?"); echo "grep -l/-x: $_p"
		_p=$(echo x | grep -vc y 2>&1); echo "grep -vc: $_p"
		_p=$(echo x | grep -I x 2>&1); echo "grep -I (not used by collector): $_p"
		_p=$(date +%s 2>&1); echo "date +%s: $_p"
		_p=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>&1); echo "date -u format: $_p"
		_p=$(readlink -f /bin/sh 2>&1); echo "readlink -f /bin/sh: $_p"
		_p=$(echo x | md5sum 2>&1); echo "md5sum: $_p"
		_p=$(echo x | sha256sum 2>&1); echo "sha256sum: $_p"
		_p=$(timeout 1 true >/dev/null 2>&1 && echo ok || echo no); echo "timeout SECS cmd: $_p"
		_p=$(timeout -t 1 true >/dev/null 2>&1 && echo ok || echo no); echo "timeout -t SECS cmd: $_p"
		_p=$(nice -n 19 true >/dev/null 2>&1 && echo ok || echo no); echo "nice -n 19: $_p"
		_p=$(echo a | xargs echo 2>&1); echo "xargs: $_p"
		_p=$(find /etc -maxdepth 1 -type f -size -128 2>&1 | head -n 1); echo "find -maxdepth/-size: $_p"
		_p=$(flock 2>&1 | head -n 3 | tr '\n' ' '); echo "flock usage: $_p"
		_p=$(flock 2>&1 | grep -c -- '-w'); echo "flock usage mentions -w (count): $_p"
		_p=$(printf 'a\nb\n' | head -n 1 2>&1); echo "head -n: $_p"
		_p=$(echo abc | tr -cd 'a-b' 2>&1); echo "tr -cd: $_p"
		_p=$(echo a b a | tr ' ' '\n' | sort | uniq -c 2>&1 | tr '\n' ';'); echo "sort|uniq -c: $_p"
	} 2>&1 | emit "$LIMIT"

	section 04d "package manager, feeds, installed packages"
	{
		try opkg --version
		echo "--- print-architecture"
		try opkg print-architecture
		echo "--- feeds"
		cat_file /etc/opkg.conf
		cat_file /etc/opkg/distfeeds.conf
		cat_file /etc/opkg/customfeeds.conf
		echo "--- /var/opkg-lists (opkg update is NOT run by this collector)"
		ls -la /var/opkg-lists 2>&1 | head -n 20
		echo "--- installed packages"
		try opkg list-installed
	} 2>&1 | emit 1500
}

s05() {
	section 05a "init order: /etc/rc.d (S=start order, K=stop order)"
	{ ls /etc/rc.d 2>&1; } 2>&1 | emit 250

	section 05b "START/STOP/USE_PROCD of all init scripts"
	{ grep -HE '^(START|STOP|USE_PROCD)=' /etc/init.d/* 2>&1; } 2>&1 | emit 400

	section 05c "init scripts: firewall, network, tailscale, GL/VPN related (allowlisted lines)"
	{
		_n=0
		for _f in /etc/init.d/firewall /etc/init.d/network /etc/init.d/tailscale $(ls /etc/init.d 2>/dev/null | grep -Ei 'gl|vpn|kill|wireguard|ovpn|mwan|repeater|switch' | sed 's#^#/etc/init.d/#'); do
			[ -f "$_f" ] || continue
			[ "$_n" -lt 12 ] || break
			_n=$((_n + 1))
			sv_auto "$_f"
		done
	} 2>&1 | emit "$BIGLIMIT"

	section 05d "rc.local and cron (allowlisted lines), inittab (names)"
	{
		sv_auto /etc/rc.local
		echo "--- /etc/crontabs"
		ls -la /etc/crontabs 2>&1
		for _f in /etc/crontabs/*; do
			[ -f "$_f" ] && sv_auto "$_f"
		done
		echo "--- /etc/inittab (non-comment line count and actions)"
		[ -r /etc/inittab ] && awk -F: '!/^#/ && NF >= 3 { print $1 ":" $3 }' /etc/inittab
	} 2>&1 | emit "$LIMIT"

	section 05e "hotplug scripts (iface/net) that may touch routing/firewall/VPN (allowlisted lines)"
	{
		ls -la /etc/hotplug.d/iface /etc/hotplug.d/net /etc/hotplug.d/ntp 2>&1
		_n=0
		for _f in $(ls /etc/hotplug.d/iface/* /etc/hotplug.d/net/* 2>/dev/null | grep -Ei 'gl|tailscale|vpn|wg|ovpn|ddns|kill|block|mwan|repeater|wan'); do
			[ -f "$_f" ] || continue
			[ "$_n" -lt 10 ] || break
			_n=$((_n + 1))
			sv_auto "$_f"
		done
	} 2>&1 | emit "$BIGLIMIT"

	section 05f "procd services (name, running/stopped counts) and process names"
	{
		svc_summary
		echo "--- process names (count name; no arguments)"
		proc_names
	} 2>&1 | emit 600

	section 05g "network/firewall/tailscale events from the system log (allowlisted event types only)"
	{
		tcap logread
		echo "--- first matching events"
		grep -E "netifd: Interface '[A-Za-z0-9_.-]+' (is now (up|down)|is setting up|is disabled)|netifd: Network device '[A-Za-z0-9_.-]+' (is now|link is)|firewall: (Reloading|Automatically reloading)|fw3: (Reloading|Automatically)|procd: .*(Instance|Started|Stopping|Killing) " "$CAP" | head -n 80
		echo "--- last matching events"
		grep -E "netifd: Interface '[A-Za-z0-9_.-]+' (is now (up|down)|is setting up|is disabled)|netifd: Network device '[A-Za-z0-9_.-]+' (is now|link is)|firewall: (Reloading|Automatically reloading)|fw3: (Reloading|Automatically)|procd: .*(Instance|Started|Stopping|Killing) " "$CAP" | tail -n 40
		echo "--- tailscale events (message text omitted)"
		grep -E 'tailscaled?(\[[0-9]+\])?:' "$CAP" | awk '{ print $1, $2, $3, $4, $5, $6, $7 }' | tail -n 10
	} 2>&1 | emit 250
}

s06() {
	section 06a "links (detailed, with statistics)"
	{ try ip -s -d link; echo "--- /sys/class/net"; for _i in /sys/class/net/*; do echo "$(basename "$_i") operstate=$(cat "$_i/operstate" 2>/dev/null) mtu=$(cat "$_i/mtu" 2>/dev/null)"; done; } 2>&1 | emit "$LIMIT"

	section 06b "addresses"
	{ try ip -4 addr; try ip -6 addr; } 2>&1 | emit "$LIMIT"

	section 06c "routes (all tables, IPv4 and IPv6)"
	{
		try ip -4 route show table all
		echo "--- ipv6"
		try ip -6 route show table all
		echo "--- default routes"
		try ip -4 route show default
		try ip -6 route show default
		echo "--- table 52 (tailscale)"
		try ip -4 route show table 52
		try ip -6 route show table 52
	} 2>&1 | emit "$BIGLIMIT"

	section 06d "policy routing rules"
	{ try ip -4 rule; echo "--- ipv6"; try ip -6 rule; } 2>&1 | emit "$LIMIT"

	section 06e "neighbour table: state counts only (no client addresses)"
	{
		tcap ip neigh
		awk '{ s[$NF]++ } END { for (k in s) print k, s[k] }' "$CAP"
	} 2>&1 | emit 40

	section 06f "route lookups (read-only, no packets sent)"
	{
		try ip route get 1.1.1.1
		echo "--- with tailscale bypass mark"
		try ip route get 1.1.1.1 mark 0x80000
		echo "--- ipv6"
		try ip -6 route get 2606:4700:4700::1111
		echo "--- as forwarded LAN client"
		_lan=$(lan_dev)
		_c=$(ip -4 neigh show dev "$_lan" 2>/dev/null | awk '$NF != "FAILED" { print $1; exit }')
		echo "lan_dev=$_lan client_found=$([ -n "$_c" ] && echo yes || echo no)"
		if [ -n "$_c" ]; then try ip route get 1.1.1.1 from "$_c" iif "$_lan"; fi
	} 2>&1 | emit "$LIMIT"

	section 06g "bridges and wireless interfaces"
	{ try brctl show; try bridge link; echo "--- iw dev"; try iw dev; } 2>&1 | emit "$LIMIT"

	section 06h "netifd view (interfaces, devices)"
	{ try ubus call network.interface dump; echo "--- devices"; try ubus call network.device status; } 2>&1 | emit 700

	section 06i "uci network / wireless / dhcp (key allowlists; no keys, SSIDs, static leases)"
	{
		echo "--- network"
		uci_allow network '^(proto|device|ifname|type|ports|ipaddr|netmask|gateway|dns|peerdns|metric|disabled|auto|mtu|ip6assign|ip6addr|ip6gw|ipv6|delegate|force_link|defaultroute|ip4table|ip6table|multipath|bridge_empty|name|vid|dhcp_pd|reqaddress|reqprefix|stp|igmp_snooping|packet_steering|target|interface|table|route)$'
		echo "--- wireless"
		uci_allow wireless '^(device|mode|network|disabled|band|channel|htmode|encryption|type|country|hidden|ifname|wds|ieee80211w|txpower|legacy_rates)$'
		echo "--- dhcp"
		uci_allow dhcp '^(interface|start|limit|leasetime|dhcpv4|dhcpv6|ra|ignore|server|noresolv|port|domainneeded|localise_queries|rebind_protection|resolvfile|cachesize|dnsforwardmax|localservice|nonwildcard|boguspriv|filterwin2k|authoritative|readethers|leasefile|logqueries|confdir)$'
	} 2>&1 | emit "$BIGLIMIT"

	section 06j "DNS: resolver settings, dnsmasq settings (no host/lease entries), listeners"
	{
		echo "--- resolv.conf files"
		for _f in /etc/resolv.conf /tmp/resolv.conf.d/* /tmp/resolv.conf.auto /tmp/resolv.conf; do
			[ -f "$_f" ] && grep -HE '^(nameserver|search|domain)' "$_f"
		done
		echo "--- dnsmasq conf (allowlisted directives)"
		for _f in /var/etc/dnsmasq.conf* /tmp/etc/dnsmasq.conf*; do
			[ -f "$_f" ] && grep -HE '^(server|no-resolv|resolv-file|port|local|domain|dhcp-range|cache-size|interface|except-interface|bind-|listen-address|rebind|dnssec|dhcp-leasefile|conf-dir|min-cache-ttl|edns|stop-dns-rebind|filterwin2k|localise-queries|no-poll|no-hosts|expand-hosts|boguspriv|domain-needed|log-queries)' "$_f"
		done
		echo "--- listening sockets"
		try netstat -lntu
	} 2>&1 | emit "$LIMIT"
}

s07() {
	section 07a "rules that can block single devices (MAC/ipset matches, REJECT/DROP)"
	{
		echo "--- ipv4"
		tcap iptables-save -c
		grep -Ei -- '-m mac|--mac-source|-m set|--match-set|-j (REJECT|DROP)' "$CAP"
		echo "--- ipv6"
		tcap ip6tables-save -c
		grep -Ei -- '-m mac|--mac-source|-m set|--match-set|-j (REJECT|DROP)' "$CAP"
	} 2>&1 | emit "$BIGLIMIT"

	section 07b "fw3 rules with MAC or block/deny wording"
	{
		tcap uci show firewall
		grep -Ei 'src_mac|mac|block|deny|target=.(REJECT|DROP)' "$CAP"
	} 2>&1 | emit "$LIMIT"

	section 07c "GL.iNet access-control related configs (key inventory + allowlisted values)"
	{
		ls /etc/config 2>&1 | grep -Ei 'mac|block|parental|access|client|filter|kid|limit|schedule'
		echo "--- glconfig key names"
		uci_keys glconfig | head -n 200
		echo "--- glconfig allowlisted values"
		uci_allow glconfig '^(enable|enabled|disabled|status|mode|type|policy|block.*|blocked|access.*|internet.*|limit.*|schedule.*|kill.*|zone|interface|ifname|device|mac|macaddr|src_mac)$'
	} 2>&1 | emit "$LIMIT"
}

s08() {
	section 08a "all uci config files (names, sizes)"
	{ ls -la /etc/config 2>&1; } 2>&1 | emit 200

	section 08b "GL.iNet web/RPC surface (names only)"
	{
		ls /usr/lib/oui-httpd 2>&1
		echo "--- rpc modules"
		ls /usr/lib/oui-httpd/rpc 2>&1 | head -n 150
		echo "--- rpc modules mentioning tailscale/vpn/firewall (small files, one level)"
		$NI find /usr/lib/oui-httpd/rpc -maxdepth 1 -type f -size -256 2>/dev/null | head -n 150 | $NI xargs grep -liE 'tailscale|wireguard|openvpn|firewall' /dev/null 2>/dev/null | head -n 40
		echo "--- gl processes (names only)"
		proc_names | grep -E 'gl_|gl-|oui-httpd|nginx|uhttpd'
	} 2>&1 | emit "$LIMIT"

	section 08c "GL VPN configs: key names, then allowlisted non-secret values"
	{
		for _c in glconfig wireguard ovpnclient ovpnserver wgserver; do
			if [ -r "/etc/config/$_c" ]; then
				echo "--- $_c (key names)"
				uci_keys "$_c" | head -n 150
				echo "--- $_c (allowlisted values)"
				uci_allow "$_c" '^(enable|enabled|disabled|mode|status|type|proto|policy|kill.*|block.*|zone|ifname|device|metric|route.*|tailscale.*)$'
			fi
		done
	} 2>&1 | emit "$LIMIT"

	section 08d "tunnels and VPN processes"
	{
		tcap ip -d link
		grep -E 'wg|tun|tailscale|ovpn' "$CAP"
		echo "--- processes (names only)"
		proc_names | grep -E 'wg|openvpn|ovpn|tailscale|ddns'
		echo "--- directories (names only)"
		ls /etc/openvpn /etc/wireguard /etc/gl-wireguard 2>&1
	} 2>&1 | emit "$LIMIT"
}

s09() {
	section 09a "listening services (API/HTTP/SSH/MQTT candidates)"
	{ try netstat -lntup; } 2>&1 | emit 100

	section 09b "RPC/ACL surface"
	{
		tcap ubus list
		grep -iE 'rpc|session|system' "$CAP"
		echo "--- rpcd acl"
		ls /usr/share/rpcd/acl.d 2>&1
	} 2>&1 | emit "$LIMIT"

	section 09c "MQTT/HTTP client capabilities and TLS"
	{
		for _c in mosquitto_pub mosquitto_sub nc curl wget uclient-fetch openssl jq ucode lua jsonfilter logger; do
			if _p=$(command -v "$_c" 2>/dev/null); then echo "$_c: $_p"; else echo "$_c: -"; fi
		done
		echo "--- relevant installed packages"
		tcap opkg list-installed
		grep -E 'mosquitto|mqtt|libmosq|curl|libcurl|uclient|ca-bundle|ca-certificates|openssl|mbedtls|wolfssl|ucode|jq|lua|jsonfilter' "$CAP"
		echo "--- available packages from cached lists (opkg update NOT run)"
		{ $TO opkg list 2>&1 || echo "!! failed: opkg list"; } | grep -E '^(mosquitto|libmosquitto|ucode|ucode-mod-[a-z]+|jq|curl) |^!!'
		echo "--- CA certificates"
		echo "ca_files=$(ls /etc/ssl/certs 2>/dev/null | wc -l)"
	} 2>&1 | emit "$LIMIT"

	section 09d "time and system settings (allowlisted)"
	{
		echo "date_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		proc_names | grep -E 'ntpd|sysntpd|chrony'
		echo "--- uci system"
		uci_allow system '^(timezone|zonename|log_size|log_proto|conloglevel|cronloglevel)$'
	} 2>&1 | emit "$LIMIT"

	section 09e "storage and memory headroom"
	{ try df -h /overlay /tmp; echo "--- free"; try free; } 2>&1 | emit "$LIMIT"
}

s10() {
	section 10 "derived facts for the fail-closed kill switch (facts only, no conclusions)"
	{
		echo "fw_backend_iptables=$(iptables -V 2>&1)"
		echo "fw_backend_ip6tables=$(ip6tables -V 2>&1)"
		echo "nft_tables=$(nft list tables 2>/dev/null | wc -l)"
		echo "lan_dev=$(lan_dev)"
		echo "tailscale_chains_v4=$(iptables-save 2>/dev/null | grep -oE '^:ts-[a-z-]+' | tr '\n' ' ')"
		echo "tailscale_chains_v6=$(ip6tables-save 2>/dev/null | grep -oE '^:ts-[a-z-]+' | tr '\n' ' ')"
		echo "--- tailscale netfilter mode and exit node (prefs)"
		ts_prefs | grep -E 'NetfilterMode|ExitNode|NoSNAT'
		echo "--- ip rules with marks or table 52"
		ip -4 rule 2>/dev/null | grep -E 'fwmark|lookup 52'
		ip -6 rule 2>/dev/null | grep -E 'fwmark|lookup 52'
		echo "--- default routes"
		ip -4 route show default 2>/dev/null
		ip -6 route show default 2>/dev/null
		echo "--- fw3 forwardings (src -> dest)"
		uci export firewall 2>/dev/null | awk -v q="'" '
			/^config / { if (f) print "forwarding " src " -> " dst; f = ($2 == "forwarding"); src = ""; dst = ""; next }
			f && $1 == "option" && $2 == "src" { gsub(q, "", $3); src = $3 }
			f && $1 == "option" && $2 == "dest" { gsub(q, "", $3); dst = $3 }
			END { if (f) print "forwarding " src " -> " dst }'
		echo "--- iptables rules that use marks, owner or ts- chains"
		iptables-save 2>/dev/null | grep -E 'mark|owner|ts-'
		echo "--- iptables extension libs for mark/owner/comment/mac/set/connmark"
		ls /usr/lib/iptables /usr/lib/xtables 2>/dev/null | grep -E 'mark|owner|comment|mac|set|connmark|REJECT|multiport'
		echo "--- resolvers"
		grep -hE '^(nameserver|server=)' /etc/resolv.conf /tmp/resolv.conf.d/* /tmp/resolv.conf.auto /var/etc/dnsmasq.conf* 2>/dev/null | sort -u
	} 2>&1 | emit "$BIGLIMIT"
}

# ---- main --------------------------------------------------------------------------

# Completeness summary: every section header needs a status line; sections with
# issues/truncation are listed. Written BEFORE the INDEX.
summary() {
	_su_h=$(grep -c '^## \[' "$OUT")
	_su_s=$(grep -c '^# \[[0-9a-z]*\] status=' "$OUT")
	_su_bad=$(grep '^# \[[0-9a-z]*\] status=partial' "$OUT")
	_su_nost=$(awk '
		/^## \[/ { id = $2; gsub(/\[|\]/, "", id); h[++n] = id; next }
		/^# \[[0-9a-z]+\] status=/ { id = $2; gsub(/\[|\]/, "", id); s[id] = 1 }
		END { for (i = 1; i <= n; i++) if (!(h[i] in s)) print "no-status: " h[i] }' "$OUT")
	_su_c=complete
	[ -n "$_su_bad" ] && _su_c=partial
	{ [ -n "$_su_nost" ] || [ "$_su_h" -ne "$_su_s" ]; } && _su_c=incomplete
	{
		printf '\n## SUMMARY\n'
		echo "sections=$_su_h statuses=$_su_s"
		echo "completeness=$_su_c"
		[ -n "$_su_bad" ] && echo "$_su_bad"
		[ -n "$_su_nost" ] && echo "$_su_nost"
	} >>"$OUT"
}

main() {
	# Never let any command read the remainder of a script piped via "sh -s".
	exec </dev/null

	for _a in "$@"; do
		case $_a in
		--keep) KEEP=1 ;;
		--full-scripts) FULL=1 ;;
		*)
			echo "usage: sh -s -- [--keep] [--full-scripts]" >&2
			exit 2
			;;
		esac
	done

	_host=$(tr -cd 'A-Za-z0-9._-' </proc/sys/kernel/hostname 2>/dev/null)
	[ -n "$_host" ] || _host=router
	OUT=$(mktemp "/tmp/tsem-collect-$_host.XXXXXX") || {
		echo "error: cannot create report file" >&2
		exit 1
	}
	CAP="$OUT.cap"
	trap cleanup EXIT
	trap 'exit 130' INT TERM HUP
	chmod 600 "$OUT" || {
		echo "error: cannot set report permissions" >&2
		exit 1
	}
	: >"$CAP" && chmod 600 "$CAP" || {
		echo "error: cannot create scratch file" >&2
		exit 1
	}
	detect_wrappers

	echo "# tsem collector v$VERSION (read-only)" >>"$OUT"
	echo "# allowlist extraction + best-effort redaction; review before sharing" >>"$OUT"

	s00
	s01
	s02
	s03
	s04
	s05
	s06
	s07
	s08
	s09
	s10

	summary
	printf '\n## INDEX\n' >>"$OUT"
	# read first, append afterwards: a grep that reads the file while it is being appended to (busybox grep) would list the index lines too
	_ix=$(grep '^## \[' "$OUT" | cut -c1-90)
	printf '%s\n' "$_ix" >>"$OUT"

	_n=$(wc -l <"$OUT" | tr -d ' ')
	_h=none
	if have sha256sum; then _h=$(sha256sum <"$OUT" | cut -d' ' -f1); fi
	printf '## END lines=%s sha256=%s\n' "$_n" "$_h" >>"$OUT"

	if ! leak_check "$OUT"; then
		rm -f "$OUT" "$CAP"
		echo "error: secret-like content survived redaction; report deleted, nothing was sent" >&2
		exit 3
	fi
	if [ "$KEEP" = 1 ]; then
		echo "report kept: $OUT (mode 600)" >&2
	else
		cat "$OUT"
	fi
}

# Allow tests to source the helper functions without running main.
if [ "${TSEM_COLLECT_NOEXEC:-0}" != 1 ]; then
	main "$@"
fi
