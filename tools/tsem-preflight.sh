#!/bin/sh
# tsem-preflight.sh - READ-ONLY hardware preflight for the GL.iNet GL-MT3000 "root".
#
#   sh tsem-preflight.sh [--repo DIR]
#   ssh root 'sh -s -- --repo /tmp/glinet-tailscale-exit-manager' < tools/tsem-preflight.sh
#
# What it does: reads system state and prints a PASS / WARN / FAIL / SKIP report.
# What it never does: install, write or delete files, change UCI, firewall, NAT,
# routing or Tailscale, restart services, toggle the hardware switch, switch exit
# nodes, send packets to other hosts, upload anything. It creates no temporary files
# (everything is held in shell variables). The only program it executes besides
# read-only queries is the installer's own DRY RUN (`sh install.sh` without any option).
# Secrets are never printed: Tailscale status/prefs are parsed into a few booleans.
#
# Result: READY_FOR_PASSIVE_INSTALL means ONLY that an installation WITHOUT autostart,
# firewall include and hardware-switch replacement looks acceptable. It is NOT a release
# for the kill switch or GERMAN mode.
#
# Exit code: 0 READY_FOR_PASSIVE_INSTALL, 1 NEEDS_FIX, 2 INSUFFICIENT_EVIDENCE, 64 usage.
#
# Everything lives in functions and main runs with stdin from /dev/null, so no command
# can swallow the rest of the script when it is streamed through `sh -s`.
# Test hooks: PF_ROOT prefixes file paths (fixtures); commands are found through PATH.

set -u

R=${PF_ROOT:-}
R=${R%/}
REPO=/tmp/glinet-tailscale-exit-manager
PRIMARY_IP=100.64.0.30
PRIMARY_NAME=exit-a
SECONDARY_IP=100.64.0.31
SECONDARY_NAME=exit-b
EXTNET_NETS="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24"

NP=0 NW=0 NF=0 NS=0 NE=0
FAILS='' ESSL='' WARNL=''

# ------------------------------------------------------------------ output
oneline() { tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-360; }
emit() { printf '%-5s %-16s %s\n' "$1" "$2" "$(printf '%s' "$3" | oneline)"; }
sect() { printf '\n== %s\n' "$1"; }
pass() { NP=$((NP + 1)); emit PASS "$1" "$2"; }
warn() {
	NW=$((NW + 1))
	WARNL="$WARNL $1"
	emit WARN "$1" "$2"
}
fail() {
	NF=$((NF + 1))
	FAILS="$FAILS
  $1: $2"
	emit FAIL "$1" "$2"
}
skip() { NS=$((NS + 1)); emit SKIP "$1" "$2"; }
# skipe: the check could not run and the missing evidence matters for the recommendation
skipe() {
	NS=$((NS + 1))
	NE=$((NE + 1))
	ESSL="$ESSL
  $1: $2"
	emit SKIP "$1" "$2 (evidence missing)"
}

have() { command -v "$1" >/dev/null 2>&1; }
# uv TEXT KEY: value of a `uci show` line KEY='value' (quotes removed)
uv() { printf '%s\n' "$1" | awk -v q="'" -v k="$2" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); gsub(q, ""); print; exit }'; }
words_have() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }
rc_prio() { ls "$R/etc/rc.d" 2>/dev/null | sed -n "s/^S\([0-9][0-9]*\)$1\$/\1/p" | head -n 1; }

fingerprint() {
	(
		md5sum "$R"/etc/config/* "$R"/etc/rc.d/* "$R"/etc/gl-switch.d/* "$R"/etc/tsem/* "$R"/etc/init.d/tsem "$R"/usr/sbin/tsem 2>/dev/null
		ls -la "$R/etc/rc.d" "$R/etc/gl-switch.d" "$R/etc/tsem" "$R/usr/lib/tsem" 2>/dev/null
	) | md5sum | cut -c1-32
}

# ------------------------------------------------------------ state gathering
# Only read-only queries. Failures leave the variable empty and are judged by the checks.
gather() {
	TMO=''
	have timeout && TMO='timeout 10'
	HAVE_IP=0 HAVE_IPT=0 HAVE_UCI=0 HAVE_TS=0
	have ip && HAVE_IP=1
	have iptables && HAVE_IPT=1
	have uci && HAVE_UCI=1
	have tailscale && HAVE_TS=1
	IPRULE='' T52='' MAINDEF='' IPTS='' NAT='' FWUCI='' DHCPU='' NETU='' TSJ='' PEERS='' PREFS='' PSOUT=''
	if [ "$HAVE_IP" -eq 1 ]; then
		IPRULE=$($TMO ip rule show 2>/dev/null)
		T52=$($TMO ip route show table 52 2>/dev/null)
		MAINDEF=$($TMO ip route show default 2>/dev/null)
	fi
	if [ "$HAVE_IPT" -eq 1 ]; then
		IPTS=$($TMO iptables -w 5 -S 2>/dev/null)
		NAT=$($TMO iptables -w 5 -t nat -S 2>/dev/null)
	fi
	if [ "$HAVE_UCI" -eq 1 ]; then
		FWUCI=$(uci -q show firewall 2>/dev/null)
		DHCPU=$(uci -q show dhcp 2>/dev/null)
		NETU=$(uci -q show network 2>/dev/null)
	fi
	if [ "$HAVE_TS" -eq 1 ]; then
		TSJ=$($TMO tailscale status --json 2>/dev/null)
		PREFS=$($TMO tailscale debug prefs 2>/dev/null)
	fi
	PSOUT=$(ps w 2>/dev/null || ps 2>/dev/null)
	# peers: host|ip,ip|online|exitoption|dnslabel (Peer section only, never Self)
	if [ -n "$TSJ" ]; then
		PEERS=$(printf '%s\n' "$TSJ" | awk '
			function flush() { if (host != "") print tolower(host) "|" ips "|" online "|" eno "|" tolower(dns); host = ""; dns = ""; ips = ""; online = "false"; eno = "false" }
			/"Peer": *\{/ { inpeer = 1; next }
			!inpeer { next }
			/"ExitNodeStatus": *\{/ { skip = 1; next }
			skip { if ($0 ~ /^ {0,4}\}/) skip = 0; next }
			/"HostName": *"/ { flush(); s = $0; sub(/.*"HostName": *"/, "", s); sub(/".*/, "", s); host = s; next }
			/"DNSName": *"/ { s = $0; sub(/.*"DNSName": *"/, "", s); sub(/".*/, "", s); sub(/\..*/, "", s); dns = s; next }
			/"TailscaleIPs": *\[/ { inip = 1; next }
			inip && /\]/ { inip = 0; next }
			inip { if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) { ip = substr($0, RSTART, RLENGTH); ips = (ips == "" ? ip : ips "," ip) }; next }
			/"Online": *true/ { online = "true"; next }
			/"ExitNodeOption": *true/ { eno = "true"; next }
			END { flush() }')
	fi
	load_conf
}

# Parse (never source) the tsem configuration: installed file first, else the repo default.
load_conf() {
	CONF_FILE=''
	CONF_KIND=none
	if [ -r "$R/etc/tsem/tsem.conf" ]; then
		CONF_FILE=$R/etc/tsem/tsem.conf
		CONF_KIND=installed
	elif [ -r "$REPO/src/etc/tsem/tsem.conf" ]; then
		CONF_FILE=$REPO/src/etc/tsem/tsem.conf
		CONF_KIND=repo-default
	fi
	ALLOW4='' CONF_PRIMARY='' CONF_SECONDARY=''
	if [ -n "$CONF_FILE" ]; then
		ALLOW4=$(conf_val "$CONF_FILE" TSEM_ALLOW_SUBNETS4)
		CONF_PRIMARY=$(conf_val "$CONF_FILE" TSEM_PRIMARY)
		CONF_SECONDARY=$(conf_val "$CONF_FILE" TSEM_SECONDARY)
	fi
	REPO_ALLOW4=''
	[ -r "$REPO/src/etc/tsem/tsem.conf" ] && REPO_ALLOW4=$(conf_val "$REPO/src/etc/tsem/tsem.conf" TSEM_ALLOW_SUBNETS4)
}
conf_val() { grep "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | tr -d "\"'" | sed 's/^ *//; s/ *$//'; }

zone_opt() {
	printf '%s\n' "$FWUCI" | awk -v q="'" -v n="$1" -v o="$2" '
		{ k = $0; sub(/=.*$/, "", k); x = $0; sub(/^[^=]*=/, "", x); gsub(q, "", x); v[k] = x; key[NR] = k; c = NR }
		END { for (i = 1; i <= c; i++) if (key[i] ~ /\.name$/ && v[key[i]] == n) { p = key[i]; sub(/\.name$/, "", p); if (v[p] == "zone") { print v[p "." o]; exit } } }'
}

# ============================================================ 1 system / tools
sec_system() {
	sect "1 Firmware, OpenWrt, fw3, iptables-legacy, Tailscale, tools"
	if [ -r "$R/etc/openwrt_release" ]; then
		_v=$(grep '^DISTRIB_RELEASE=' "$R/etc/openwrt_release" | head -n 1 | cut -d= -f2 | tr -d "'\"")
		case $_v in
		21.02*) pass sys.openwrt "OpenWrt $_v" ;;
		'') warn sys.openwrt "OpenWrt release not readable" ;;
		*) warn sys.openwrt "OpenWrt $_v (only 21.02 was assumed during development)" ;;
		esac
	else
		fail sys.openwrt "/etc/openwrt_release missing: not an OpenWrt system"
	fi
	_m=$(head -n 1 "$R/tmp/sysinfo/model" 2>/dev/null)
	case $_m in
	*MT3000* | *mt3000*) pass sys.model "$_m" ;;
	'') warn sys.model "model not readable (/tmp/sysinfo/model): cannot confirm GL-MT3000" ;;
	*) fail sys.model "model is '$_m': tsem is for the GL-MT3000 only" ;;
	esac
	_g=$(head -n 1 "$R/etc/glversion" 2>/dev/null)
	case $_g in
	4.11.0*) pass sys.firmware "GL.iNet firmware $_g" ;;
	'') warn sys.firmware "GL.iNet firmware version not readable (/etc/glversion)" ;;
	*) warn sys.firmware "GL.iNet firmware $_g (4.11.0 was the reference)" ;;
	esac
	if [ -e "$R/sbin/fw4" ]; then
		fail sys.fw3 "fw4 (nftables firewall) present: tsem needs fw3 with iptables"
	elif [ -e "$R/sbin/fw3" ]; then
		pass sys.fw3 "fw3 firewall present, no fw4"
	else
		fail sys.fw3 "fw3 not found (/sbin/fw3)"
	fi
	if [ "$HAVE_IPT" -eq 0 ]; then
		fail sys.iptables "iptables not found"
	else
		_iv=$(iptables -V 2>&1 | head -n 1)
		case $_iv in
		*legacy*) pass sys.iptables "$_iv" ;;
		*nf_tables*) fail sys.iptables "$_iv: tsem is built for iptables-legacy" ;;
		*) warn sys.iptables "backend of '$_iv' not identifiable as legacy" ;;
		esac
	fi
	if have ip6tables; then pass sys.ip6tables "ip6tables present"; else warn sys.ip6tables "ip6tables missing: IPv6 cannot be guarded"; fi
	if [ "$HAVE_TS" -eq 0 ]; then
		fail sys.tailscale "tailscale CLI not found"
	else
		_tv=$($TMO tailscale version 2>/dev/null | head -n 1)
		case $_tv in
		1.92.5*) pass sys.tailscale "Tailscale $_tv" ;;
		'') warn sys.tailscale "tailscale version not readable (daemon down?)" ;;
		*) warn sys.tailscale "Tailscale $_tv (1.92.5 was the reference; JSON layout unverified)" ;;
		esac
	fi
	_miss=''
	for _c in flock md5sum iptables ip awk sed grep; do have "$_c" || _miss="$_miss $_c"; done
	if [ -z "$_miss" ]; then pass sys.tools "required tools present (flock md5sum iptables ip awk sed grep)"; else fail sys.tools "missing required tools:$_miss"; fi
	_om=''
	for _c in timeout logger sort cut tr head tail; do have "$_c" || _om="$_om $_c"; done
	if [ -z "$_om" ]; then pass sys.optional "timeout, logger and text tools present"; else warn sys.optional "missing:$_om (probes or logging degrade, tsem fails closed)"; fi
	if have curl || have uclient-fetch || have wget; then pass sys.http "HTTP client for egress probes present"; else warn sys.http "no curl/uclient-fetch/wget: egress probes fail, GERMAN would never open (fail-closed)"; fi
	if [ "$HAVE_IP" -eq 1 ]; then
		if $TMO ip rule help 2>&1 | grep -q suppress_prefixlength; then pass sys.ip_rule "ip rule supports suppress_prefixlength"; else warn sys.ip_rule "ip rule help does not mention suppress_prefixlength (busybox ip?)"; fi
	else
		fail sys.ip_rule "ip not found"
	fi
}

# ============================================================ 2 existing TSEM
sec_tsem() {
	sect "2 Existing TSEM installation, processes, hooks"
	_f=''
	for _p in usr/sbin/tsem usr/sbin/tsem-mqtt usr/lib/tsem etc/tsem/install.manifest etc/init.d/tsem etc/hotplug.d/iface/50-tsem; do
		[ -e "$R/$_p" ] && _f="$_f /$_p"
	done
	if [ -z "$_f" ]; then pass tsem.files "no TSEM files installed"; else warn tsem.files "TSEM files already present:$_f (an install would be an upgrade)"; fi
	_ps=$(printf '%s\n' "$PSOUT" | grep -E '/usr/sbin/tsem|tsem-mqtt|[ /]tsem (tick|daemon|boot|set|reapply)' | grep -v 'tsem-preflight' | grep -v grep | head -n 3)
	if [ -z "$PSOUT" ]; then skip tsem.proc "ps not usable: running TSEM processes not checked"; elif [ -z "$_ps" ]; then pass tsem.proc "no TSEM process running"; else warn tsem.proc "TSEM process running: $_ps"; fi
	if grep -q 'tsem-begin' "$R/etc/config/firewall" 2>/dev/null; then warn tsem.fwhook "tsem firewall include stanza present in /etc/config/firewall"; else pass tsem.fwhook "no tsem firewall include stanza"; fi
	_rc=$(ls "$R/etc/rc.d" 2>/dev/null | grep tsem | head -n 3)
	if [ -z "$_rc" ]; then pass tsem.autostart "no tsem autostart link in /etc/rc.d"; else warn tsem.autostart "tsem autostart present: $_rc"; fi
	_ch=$(printf '%s\n%s\n' "$IPTS" "$NAT" | grep -c 'TSEM_')
	if [ "$HAVE_IPT" -eq 0 ]; then skipe tsem.chains "iptables unavailable"; elif [ "$_ch" -eq 0 ]; then pass tsem.chains "no TSEM_* firewall chains active"; else warn tsem.chains "$_ch active TSEM_* rule lines: guard may already be active"; fi
	if [ "$HAVE_IP" -eq 0 ]; then skipe tsem.rules "ip unavailable"; elif printf '%s\n' "$IPRULE" | grep -Eq '^(5280|5290):.*(suppress_prefixlength|prohibit)'; then warn tsem.rules "tsem policy rules 5280/5290 already active"; else pass tsem.rules "no tsem policy rules active"; fi
}

# ============================================================ 3 policy routing
sec_policy() {
	sect "3 Policy routing, table 52, rule priorities"
	if [ "$HAVE_IP" -eq 0 ] || [ -z "$IPRULE" ]; then
		skipe pr.rules "ip rule show unavailable"
		skipe pr.table52 "ip route show table 52 unavailable"
		return 0
	fi
	pass pr.list "rules: $(printf '%s\n' "$IPRULE" | sed 's/[[:space:]][[:space:]]*/ /g' | tr '\n' ';')"
	if printf '%s\n' "$IPRULE" | grep -Eq '^5270:.*lookup 52'; then pass pr.tailscale "Tailscale rule 5270 lookup 52 present (before the tsem guard at 5280/5290)"; else warn pr.tailscale "no '5270 lookup 52' rule (tailscaled stopped or a different layout)"; fi
	_foreign=$(printf '%s\n' "$IPRULE" | grep -E '^(5280|5290):' | grep -Ev 'iif [^ ]+ lookup main suppress_prefixlength 0|iif [^ ]+ prohibit')
	if [ -n "$_foreign" ]; then fail pr.collision "foreign rule on tsem priority 5280/5290: $_foreign"; else pass pr.collision "priorities 5280 and 5290 are free or used by tsem only"; fi
	_between=$(printf '%s\n' "$IPRULE" | awk -F: '5270 < $1 + 0 && $1 + 0 < 5280 { print $1 }' | tr '\n' ' ')
	if [ -n "$_between" ]; then warn pr.between "rules between Tailscale (5270) and the tsem guard (5280):  $_between"; else pass pr.between "no other rule between 5270 and 5280"; fi
	if [ -z "$T52" ]; then
		warn pr.table52 "table 52 is empty (Tailscale not running or no routes accepted)"
	elif printf '%s\n' "$T52" | grep -q '^100\.64\.0\.0/10 dev tailscale0'; then
		pass pr.table52 "table 52 has 100.64.0.0/10 via tailscale0 ($(printf '%s\n' "$T52" | grep -c .) routes)"
	else
		warn pr.table52 "table 52 has no 100.64.0.0/10 route via tailscale0"
	fi
	if printf '%s\n' "$T52" | grep -q '^default '; then pass pr.exit "table 52 has a default route: an exit node is currently selected (nothing is changed)"; else pass pr.exit "no default route in table 52: no exit node selected right now"; fi
	if [ -n "$MAINDEF" ]; then pass pr.maindef "main default: $MAINDEF"; else warn pr.maindef "no default route in the main table"; fi
	if [ "$HAVE_IP" -eq 1 ]; then
		_r6=$($TMO ip -6 rule show 2>&1)
		case $_r6 in
		*"not supported"* | *"Cannot"* | '') skip pr.rules6 "IPv6 policy rules not readable" ;;
		*) pass pr.rules6 "IPv6 rules: $(printf '%s\n' "$_r6" | grep -c .) lines" ;;
		esac
	fi
}

# ============================================================ 4 primary / secondary
node_check() { # role ip name
	_ip=$2 _nm=$3
	_res=$(printf '%s\n' "$PEERS" | awk -F'|' -v ip="$_ip" -v n="$_nm" '
		BEGIN { n = tolower(n) }
		{ c = split($2, a, ","); has = 0; for (i = 1; i <= c; i++) if (a[i] == ip) has = 1
		  if (has) { found = 1; host = $1; on = $3; eno = $4; dns = $5 } }
		END { if (!found) { print "missing"; exit }
		      print (on == "true" ? "online" : "offline") " " (eno == "true" ? "exit-ok" : "no-exit-option") " " ((host == n || dns == n) ? "name-ok" : "name-differs:" host) }')
	case $_res in
	missing) warn "node.$1" "$_ip ($_nm) is not a peer in 'tailscale status'" ;;
	"online exit-ok name-ok") pass "node.$1" "$_nm $_ip: online, approved exit node, name matches" ;;
	*) warn "node.$1" "$_nm $_ip: $_res" ;;
	esac
}

sec_nodes() {
	sect "4 Primary $PRIMARY_IP / secondary $SECONDARY_IP (Tailscale status, no active probes)"
	if [ "$HAVE_TS" -eq 0 ]; then
		skipe node.status "tailscale CLI missing"
		return 0
	fi
	if [ -z "$TSJ" ]; then
		skipe node.status "tailscale status --json gave no answer (tailscaled not running?)"
		return 0
	fi
	_bs=$(printf '%s' "$TSJ" | grep -o '"BackendState": *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//')
	if [ "$_bs" = Running ]; then pass node.backend "BackendState Running"; else warn node.backend "BackendState '${_bs:-unknown}' (not Running)"; fi
	if [ -z "$PEERS" ]; then
		warn node.parse "no peers parsed from status JSON (empty tailnet or unexpected layout)"
	else
		pass node.parse "$(printf '%s\n' "$PEERS" | grep -c .) peers parsed"
	fi
	node_check primary "$PRIMARY_IP" "$PRIMARY_NAME"
	node_check secondary "$SECONDARY_IP" "$SECONDARY_NAME"
	if [ -n "$PREFS" ]; then
		_p=$(printf '%s\n' "$PREFS" | awk '
			/"RouteAll": *true/ { ra = 1 }
			/"AdvertiseRoutes": *\[/ { inadv = 1; if ($0 ~ /\]/) inadv = 0; if ($0 ~ /0\.0\.0\.0\/0|::\/0/) adv = 1; next }
			inadv { if ($0 ~ /0\.0\.0\.0\/0|::\/0/) adv = 1; if ($0 ~ /\]/) inadv = 0; next }
			/"ExitNodeID": *"[^"]+"/ { ex = 1 }
			/"ExitNodeIP": *"[^"]+"/ { ex = 1 }
			END { print "routeall=" (ra ? "yes" : "no") " advertise_exit=" (adv ? "yes" : "no") " exit_selected=" (ex ? "yes" : "no") }')
		case $_p in
		*advertise_exit=yes*) warn node.prefs "router advertises itself as exit node ($_p): tsem never changes that, review it" ;;
		*routeall=no*) warn node.prefs "accept-routes is off ($_p): the remote-site subnets would not be routed" ;;
		*) pass node.prefs "$_p (only derived flags, prefs are not printed)" ;;
		esac
	else
		skip node.prefs "tailscale debug prefs not readable"
	fi
	if [ "$HAVE_IP" -eq 1 ]; then
		if $TMO ip link show tailscale0 >/dev/null 2>&1; then pass node.iface "interface tailscale0 exists"; else warn node.iface "interface tailscale0 missing (userspace networking or tailscaled down)"; fi
	fi
	if printf '%s\n' "$PSOUT" | grep tailscaled | grep -q 'userspace-networking'; then fail node.userspace "tailscaled runs in userspace-networking: no tailscale0 and no table 52"; fi
	skip node.ping "no active reachability probe to the exit nodes (deliberately not done)"
}

# ============================================================ 5 masquerading
sec_masq() {
	sect "5 Existing masquerading, LAN to tailscale0, remote-site subnets (nothing is changed)"
	if [ "$HAVE_UCI" -eq 0 ] || [ -z "$FWUCI" ]; then
		skipe masq.uci "uci show firewall unavailable"
		skipe masq.forward "uci show firewall unavailable"
	else
		_masq=$(zone_opt tailscale0 masq)
		if [ "$_masq" = 1 ]; then pass masq.uci "firewall zone tailscale0 has masq=1"; else fail masq.uci "firewall zone tailscale0: masq='${_masq:-unset}' (expected 1; remote-site replies would not return)"; fi
		_fw=$(printf '%s\n' "$FWUCI" | awk -v q="'" '
			{ key[NR] = $0; sub(/=.*$/, "", key[NR]); val[NR] = $0; sub(/^[^=]*=/, "", val[NR]); gsub(q, "", val[NR]); n = NR; v[key[NR]] = val[NR] }
			END { for (i = 1; i <= n; i++) if (key[i] ~ /\.src$/ && val[i] == "lan") { p = key[i]; sub(/\.src$/, "", p); if (v[p] == "forwarding" && v[p ".dest"] == "tailscale0" && v[p ".enabled"] != "0") { print "yes"; exit } } }')
		if [ "$_fw" = yes ]; then pass masq.forward "forwarding lan to tailscale0 configured"; else fail masq.forward "no enabled forwarding lan to tailscale0 in /etc/config/firewall"; fi
	fi
	if [ "$HAVE_IPT" -eq 0 ] || [ -z "$NAT" ]; then
		skipe masq.nat "iptables nat table unavailable"
	else
		if printf '%s\n' "$NAT" | grep -q '^-A zone_tailscale0_postrouting .*-j MASQUERADE'; then
			pass masq.nat "chain zone_tailscale0_postrouting contains MASQUERADE"
		elif printf '%s\n' "$NAT" | grep -q '^-N zone_tailscale0_postrouting'; then
			fail masq.nat "chain zone_tailscale0_postrouting exists but has no MASQUERADE rule"
		else
			fail masq.nat "chain zone_tailscale0_postrouting missing"
		fi
		if printf '%s\n' "$NAT" | grep -q '^-A POSTROUTING .*-j zone_tailscale0_postrouting'; then pass masq.hook "POSTROUTING jumps to zone_tailscale0_postrouting"; else fail masq.hook "POSTROUTING does not jump to zone_tailscale0_postrouting"; fi
	fi
	if [ "$HAVE_IPT" -eq 1 ] && [ -n "$IPTS" ]; then
		if printf '%s\n' "$IPTS" | grep -q '^-A forwarding_lan_rule .*-j zone_tailscale0_dest_ACCEPT'; then pass masq.live "live FORWARD path lan to tailscale0 accepted by fw3"; else warn masq.live "no live forwarding_lan_rule to zone_tailscale0_dest_ACCEPT found"; fi
	fi
	if [ -z "$IPRULE" ] && [ -z "$T52" ]; then
		skipe masq.routes "table 52 unavailable"
	else
		_i=0
		for _n in $EXTNET_NETS; do
			if printf '%s\n' "$T52" | grep -q "^$_n dev tailscale0"; then pass "route.extnet$_i" "table 52 has $_n via tailscale0"; else fail "route.extnet$_i" "table 52 has no route $_n via tailscale0"; fi
			if words_have "$ALLOW4" "$_n"; then pass "allow.extnet$_i" "$_n is in TSEM_ALLOW_SUBNETS4 ($CONF_KIND config)"; else warn "allow.extnet$_i" "$_n is NOT in TSEM_ALLOW_SUBNETS4 ($CONF_KIND config): unreachable in BLOCKED"; fi
			_i=$((_i + 1))
		done
		_priv=$(printf '%s\n' "$T52" | awk '{ d = $1; if (d ~ /^10\./ || d ~ /^192\.168\./ || d ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) print d }')
		_unc=''
		for _d in $_priv; do words_have "$ALLOW4" "$_d" || _unc="$_unc $_d"; done
		if [ -z "$_unc" ]; then pass masq.private "every private route in table 52 is listed in TSEM_ALLOW_SUBNETS4"; else warn masq.private "private routes in table 52 not in TSEM_ALLOW_SUBNETS4 (blocked in BLOCKED):$_unc"; fi
	fi
}

# ============================================================ 6 hardware switch
sec_switch() {
	sect "6 GL.iNet hardware switch, UCI mapping, existing hook"
	_gd=$R/etc/gl-switch.d
	_hk=$_gd/tailscale-de.sh
	if [ ! -d "$_gd" ]; then
		warn sw.dir "/etc/gl-switch.d missing: switch handler location unknown"
	else
		pass sw.dir "/etc/gl-switch.d: $(ls "$_gd" 2>/dev/null | tr '\n' ' ')"
	fi
	if [ ! -e "$_hk" ]; then
		warn sw.hook "no hook /etc/gl-switch.d/tailscale-de.sh: the installer assumes this prototype name"
	else
		_mode=$(ls -l "$_hk" | cut -c1-10)
		if grep -q 'tsem' "$_hk" 2>/dev/null; then
			warn sw.hook "hook is already a tsem hook ($_mode)"
		elif [ ! -x "$_hk" ]; then
			warn sw.hook "prototype hook present but NOT executable ($_mode): GL cannot call it"
		else
			_calls=$(grep -oE 'tailscale|iptables|uci |ip route|ip rule|fw3' "$_hk" 2>/dev/null | sort -u | tr '\n' ' ')
			pass sw.hook "prototype hook present, executable ($_mode), untouched by a passive install; it calls: ${_calls:-nothing recognisable}"
		fi
	fi
	_map=''
	if [ "$HAVE_UCI" -eq 0 ]; then
		skipe sw.uci "uci unavailable"
	else
		for _c in $(ls "$R/etc/config" 2>/dev/null | grep -iE 'gl|switch|button'); do
			_l=$(uci -q show "$_c" 2>/dev/null | grep -iE 'switch|button|tailscale' | grep -viE 'key|pass|psk|secret|token|auth|sn=|mac|ssid' | head -n 4)
			[ -n "$_l" ] && _map="$_map $_l"
		done
		if [ -z "$_map" ]; then
			warn sw.uci "no UCI option about the hardware switch found (unknown mapping): the passive install does not depend on it, hook replacement does"
		elif printf '%s\n' "$_map" | grep -qi tailscale; then
			pass sw.uci "switch mapping mentions tailscale: $_map"
		else
			warn sw.uci "switch mapping does not mention tailscale (deviates from the expected function): $_map"
		fi
	fi
	skip sw.toggle "hardware switch is never toggled; calling convention stays unverified (docs/rc/test-plan.md step 4)"
}

# ============================================================ 7 DNS / IPv6
classify_dns() {
	_loc='' _tn='' _ext=''
	for _s in $1; do
		case $_s in
		127.* | ::1 | 0.0.0.0) _loc="$_loc $_s" ;;
		100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) _tn="$_tn $_s" ;;
		*) _ext="$_ext $_s" ;;
		esac
	done
	DNS_LOCAL=$_loc DNS_TN=$_tn DNS_EXT=$_ext
}

sec_dns_ipv6() {
	sect "7 DNS and IPv6 (potential leak paths)"
	_ns=''
	for _f in "$R/etc/resolv.conf" "$R/tmp/resolv.conf" "$R/tmp/resolv.conf.auto" "$R/tmp/resolv.conf.d/resolv.conf.auto"; do
		[ -r "$_f" ] && _ns="$_ns $(awk '$1 == "nameserver" { print $2 }' "$_f" 2>/dev/null | tr '\n' ' ')"
	done
	_up=$(uv "$DHCPU" 'dhcp.@dnsmasq[0].server')
	_ns="$_ns $_up"
	_ns=$(printf '%s\n' "$_ns" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
	if [ -z "$_ns" ]; then
		warn dns.upstream "no resolver found in resolv.conf or dnsmasq (cannot judge DNS paths)"
	else
		classify_dns "$_ns"
		if [ -n "$DNS_EXT" ]; then
			warn dns.upstream "external resolvers:$DNS_EXT (local:${DNS_LOCAL:- none} tailnet:${DNS_TN:- none}). Router DNS over WAN is rejected by TSEM_OUT in GERMAN/BLOCKED; client DNS needs the exit node or TSEM_DNS_REDIRECT (docs/rc/dns-ipv6.md)"
		else
			pass dns.upstream "resolvers local:${DNS_LOCAL:- none} tailnet:${DNS_TN:- none}; none reach the internet directly"
		fi
		case " $_ns " in *" 0.0.0.0 "*) warn dns.zero "resolver 0.0.0.0 present: its meaning is an open point and must be verified on the device" ;; esac
	fi
	_rd=$(printf '%s\n' "$NAT" | grep -E -- '--dport 53' | grep -E 'REDIRECT|DNAT' | grep -v TSEM_DNS | head -n 3)
	if [ "$HAVE_IPT" -eq 0 ]; then skipe dns.redirect "iptables unavailable"; elif [ -n "$_rd" ]; then warn dns.redirect "existing DNS redirect in nat: $_rd (check ordering against TSEM_DNS)"; else pass dns.redirect "no foreign DNS redirect in nat"; fi
	_ls=$( (netstat -lnup 2>/dev/null; netstat -lntp 2>/dev/null) | grep ':53 ' | awk '{ print $NF }' | sort -u | tr '\n' ' ')
	if have netstat; then pass dns.listen "port 53 listeners: ${_ls:-none found}"; else skip dns.listen "netstat missing: DNS listeners not listed"; fi
	if [ -r "$R/proc/sys/net/ipv6/conf/all/disable_ipv6" ] && [ "$(cat "$R/proc/sys/net/ipv6/conf/all/disable_ipv6")" = 1 ]; then
		pass ipv6.state "IPv6 disabled by sysctl"
		return 0
	fi
	if [ "$HAVE_IP" -eq 0 ]; then skipe ipv6.state "ip unavailable"; return 0; fi
	_gl=$($TMO ip -6 addr show scope global 2>/dev/null | awk '
		/^[0-9]+: / { i = $2; sub(/:$/, "", i) }
		/inet6 / { a = $2; if (a !~ /^f[cd]/) seen[i] = 1 }
		END { for (k in seen) printf "%s ", k }')
	_ra=$(uv "$DHCPU" 'dhcp.lan.ra')
	_d6=$(uv "$DHCPU" 'dhcp.lan.dhcpv6')
	_as=$(uv "$NETU" 'network.lan.ip6assign')
	_dr6=$($TMO ip -6 route show default 2>/dev/null | head -n 1)
	if [ -z "$_gl" ] && [ -z "$_dr6" ] && [ "$_ra" != server ] && [ "$_ra" != hybrid ] && [ -z "$_as" ]; then
		pass ipv6.state "no global IPv6, no default v6 route, no RA on lan"
	else
		warn ipv6.state "IPv6 active: global on: ${_gl:-none} default:${_dr6:- none} ra=${_ra:-unset} dhcpv6=${_d6:-unset} ip6assign=${_as:-unset}. Clients can bypass an IPv4-only exit; the ip6tables guard exists but is untested on hardware"
	fi
}

# ============================================================ 8 includes, autostart, resources
sec_fw_res() {
	sect "8 Firewall includes, autostart, memory, installation prerequisites"
	if [ "$HAVE_UCI" -eq 0 ] || [ -z "$FWUCI" ]; then
		skipe fw.includes "uci show firewall unavailable"
	else
		_inc=$(printf '%s\n' "$FWUCI" | awk -v q="'" '
			{ k = $0; sub(/=.*$/, "", k); v = $0; sub(/^[^=]*=/, "", v); gsub(q, "", v); if (v == "include") inc[k] = 1; key[NR] = k; val[NR] = v; n = NR }
			END { for (i = 1; i <= n; i++) { p = key[i]; sub(/\.[^.]*$/, "", p); if ((p in inc) && key[i] ~ /\.path$/) print val[i] } }')
		_other=$(printf '%s\n' "$_inc" | grep -v '^$' | grep -v '^/etc/firewall.user$')
		if [ -z "$_other" ]; then pass fw.includes "firewall includes: ${_inc:-none} (no foreign custom include)"; else warn fw.includes "foreign firewall includes: $_other (review ordering with the tsem include)"; fi
		_fo=$(uv "$FWUCI" 'firewall.@defaults[0].flow_offloading')
		_fh=$(uv "$FWUCI" 'firewall.@defaults[0].flow_offloading_hw')
		if [ "$_fo" = 1 ] || [ "$_fh" = 1 ]; then warn fw.offload "flow offloading enabled (sw=${_fo:-0} hw=${_fh:-0}): established flows can bypass the FORWARD guard. Must be disabled or proven harmless before any kill switch approval"; else pass fw.offload "flow offloading not enabled in firewall defaults"; fi
	fi
	if grep -qE 'shortcut_fe|fast_classifier|sfe_' "$R/proc/modules" 2>/dev/null; then warn fw.fastpath "kernel fast-path module loaded (shortcut-fe/SFE): may bypass iptables for established flows"; else pass fw.fastpath "no shortcut-fe/SFE kernel module loaded"; fi
	_fu=$(grep -vcE '^[[:space:]]*(#|$)' "$R/etc/firewall.user" 2>/dev/null)
	if [ "${_fu:-0}" -eq 0 ]; then pass fw.user "/etc/firewall.user has no active lines"; else warn fw.user "/etc/firewall.user has $_fu active lines (custom rules may interact)"; fi
	_ts=$(rc_prio tsem)
	_tsp=$(sed -n 's/^START=//p' "$REPO/src/etc/init.d/tsem" 2>/dev/null | head -n 1)
	_fwp=$(rc_prio firewall)
	_nwp=$(rc_prio network)
	if [ -n "$_ts" ]; then warn boot.autostart "tsem autostart link S$_ts already exists"; else pass boot.autostart "no tsem autostart link (passive install adds none)"; fi
	if [ -z "$_tsp" ] || [ -z "$_fwp" ] || [ -z "$_nwp" ]; then
		warn boot.order "boot order not provable (tsem START='${_tsp:-?}' firewall S='${_fwp:-?}' network S='${_nwp:-?}')"
	elif [ "$_tsp" -lt "$_fwp" ] && [ "$_tsp" -lt "$_nwp" ]; then
		pass boot.order "tsem START=$_tsp runs before firewall S$_fwp and network S$_nwp (real boot leak window still needs a hardware proof)"
	else
		warn boot.order "tsem START=$_tsp does not run before firewall S$_fwp and network S$_nwp"
	fi
	_mem=$(awk '/^MemAvailable:/ { print $2; exit }' "$R/proc/meminfo" 2>/dev/null)
	[ -n "$_mem" ] || _mem=$(awk '/^MemFree:/ { print $2; exit }' "$R/proc/meminfo" 2>/dev/null)
	if [ -z "$_mem" ]; then
		warn res.mem "memory not readable"
	elif [ "$_mem" -lt 10000 ]; then
		fail res.mem "only $_mem kB available memory"
	elif [ "$_mem" -lt 30000 ]; then
		warn res.mem "low memory: $_mem kB available"
	else
		pass res.mem "$_mem kB available memory"
	fi
	_dp=$R/overlay
	[ -d "$_dp" ] || _dp=$R/
	_free=$(df -kP "$_dp" 2>/dev/null | awk 'NR == 2 { print $4 }')
	if [ -z "$_free" ]; then
		warn res.disk "free space of $_dp not readable"
	elif [ "$_free" -lt 512 ]; then
		fail res.disk "only $_free kB free on the overlay (install needs about 200 kB plus backups)"
	elif [ "$_free" -lt 2048 ]; then
		warn res.disk "low free space on the overlay: $_free kB"
	else
		pass res.disk "$_free kB free on the overlay"
	fi
	if [ -f "$REPO/install.sh" ] && [ -f "$REPO/src/usr/sbin/tsem" ] && [ -f "$REPO/contrib/tsem-switch.sh" ]; then
		_rv=$(sed -n 's/^TSEM_VERSION=//p' "$REPO/src/usr/lib/tsem/common.sh" 2>/dev/null | head -n 1)
		pass repo.present "repository at $REPO (tsem ${_rv:-unknown version})"
		REPO_OK=1
	else
		fail repo.present "repository files not found at $REPO (install.sh, src/, contrib/)"
		REPO_OK=0
	fi
}

# ============================================================ 9 tsem configuration
sec_conf() {
	sect "9 TSEM configuration, TSEM_ALLOW_SUBNETS4"
	if [ -z "$CONF_FILE" ]; then
		skipe conf.file "neither /etc/tsem/tsem.conf nor the repository default is readable"
		return 0
	fi
	pass conf.file "using $CONF_KIND config $CONF_FILE (parsed, never executed)"
	_miss=''
	for _n in $EXTNET_NETS; do words_have "$ALLOW4" "$_n" || _miss="$_miss $_n"; done
	if [ -z "$_miss" ]; then pass conf.allow "TSEM_ALLOW_SUBNETS4 contains all three remote-site subnets: $ALLOW4"; else warn conf.allow "TSEM_ALLOW_SUBNETS4='$ALLOW4' lacks:$_miss"; fi
	_bad=''
	for _a in $ALLOW4; do
		case $_a in
		0.0.0.0/0 | 10.0.0.0/8 | 172.16.0.0/12 | 192.168.0.0/16) _bad="$_bad $_a" ;;
		[0-9]*.[0-9]*.[0-9]*.[0-9]*/[0-9] | [0-9]*.[0-9]*.[0-9]*.[0-9]*/[0-9][0-9]) ;;
		*) _bad="$_bad $_a(invalid)" ;;
		esac
	done
	if [ -z "$_bad" ]; then pass conf.blanket "no blanket RFC1918 or invalid entry in TSEM_ALLOW_SUBNETS4"; else warn conf.blanket "blanket or invalid entries in TSEM_ALLOW_SUBNETS4:$_bad"; fi
	if [ "$CONF_PRIMARY" = "$PRIMARY_IP" ] && [ "$CONF_SECONDARY" = "$SECONDARY_IP" ]; then pass conf.nodes "TSEM_PRIMARY/SECONDARY match $PRIMARY_IP / $SECONDARY_IP"; else warn conf.nodes "TSEM_PRIMARY='${CONF_PRIMARY:-}' TSEM_SECONDARY='${CONF_SECONDARY:-}' differ from the expected nodes"; fi
	if [ "$CONF_KIND" = installed ] && [ -n "$REPO_ALLOW4" ] && [ "$REPO_ALLOW4" != "$ALLOW4" ]; then warn conf.drift "installed TSEM_ALLOW_SUBNETS4 differs from the repository default ($REPO_ALLOW4); an upgrade keeps your file"; fi
	_all=1
	for _n in $EXTNET_NETS; do words_have "$REPO_ALLOW4" "$_n" || _all=0; done
	if [ "$_all" -eq 1 ]; then pass conf.repo "repository default config lists the remote-site subnets"; else warn conf.repo "repository default config at $REPO lacks the remote-site subnets: the copy on the router is older than the reviewed head"; fi
	for _lan in br-lan; do
		if [ "$HAVE_IP" -eq 1 ]; then
			if $TMO ip link show "$_lan" >/dev/null 2>&1; then pass conf.lan "LAN interface $_lan exists"; else fail conf.lan "LAN interface $_lan (TSEM_LAN_IFACES default) not found"; fi
		fi
	done
}

# ============================================================ 10 installer dry run
sec_dryrun() {
	sect "10 Installer dry run (no option: nothing is changed)"
	if [ "${REPO_OK:-0}" -ne 1 ]; then
		skipe dry.run "repository missing: no dry run possible"
		return 0
	fi
	if ! grep -q 'dry run only; nothing changed' "$REPO/install.sh" 2>/dev/null; then
		skipe dry.run "installer has no verifiable dry-run guard: refusing to execute it"
		return 0
	fi
	if [ -n "$R" ]; then
		_o=$(sh "$REPO/install.sh" --root "$R" 2>&1)
	else
		_o=$(sh "$REPO/install.sh" 2>&1)
	fi
	_rc=$?
	if [ "$_rc" -eq 0 ] && printf '%s\n' "$_o" | grep -q 'dry run only; nothing changed'; then
		pass dry.run "dry run ok: $(printf '%s\n' "$_o" | grep -c '^  /') files planned"
	else
		fail dry.run "dry run failed (rc=$_rc): $(printf '%s\n' "$_o" | grep -iE 'MISSING|failed|ERROR|unknown|invalid' | head -n 3)"
	fi
	# the optional native GUI is skipped softly on routers without a GL.iNet UI: that is a normal outcome, not a warning here
	_w=$(printf '%s\n' "$_o" | grep -E 'WARNING|note:' | grep -v 'native-gui skipped' | head -n 3)
	if [ -n "$_w" ]; then warn dry.notes "installer notes: $_w"; fi
}

# ============================================================ 11 known risks
# ============================================================ native GL.iNet GUI architecture (read-only)
# Collects, in this one pass, everything needed to decide whether the optional native-gui component can be installed
# and what is still unverified. It only READS: file lists, grep -c on the stock UI bundle (counts, never content),
# /proc/net/tcp, `ubus list`, `uci show`. Nothing is written, no request is sent to any web server.
listeners_portable() { # same without strtonum (busybox awk lacks it): hex by hand
	awk 'function hx(s,   i, c, v) { v = 0; s = toupper(s); for (i = 1; i <= length(s); i++) { c = index("0123456789ABCDEF", substr(s, i, 1)) - 1; v = v * 16 + c } return v }
		NR != 1 && $4 == "0A" { split($2, a, ":"); h = a[1]; printf "%d.%d.%d.%d:%d\n", hx(substr(h, 7, 2)), hx(substr(h, 5, 2)), hx(substr(h, 3, 2)), hx(substr(h, 1, 2)), hx(a[2]) }' "$R/proc/net/tcp" 2>/dev/null
}

sec_native() {
	sect "12 GL.iNet web UI architecture and native-gui feasibility (read-only; decides whether native-gui may be installed)"
	_menu=$R/usr/share/oui/menu.d _views=$R/www/views _rpcdir=$R/usr/lib/oui-httpd/rpc
	_nmiss=''
	for _d in "$_menu" "$_views" "$_rpcdir"; do
		if [ -d "$_d" ]; then pass "ui.dir" "${_d#"$R"} exists"; else _nmiss="$_nmiss ${_d#"$R"}"; warn "ui.dir" "${_d#"$R"} missing: the expected GL.iNet 4.x UI layout is not there"; fi
	done
	_n=$(ls "$_menu" 2>/dev/null | wc -l | tr -d ' ')
	[ -d "$_menu" ] && pass ui.menu.count "$_n menu files: $(ls "$_menu" 2>/dev/null | tr '\n' ' ')"
	# Every menu file in compact form: the real structure of this firmware is what the installer must match.
	_mkey() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1; }
	_mnum() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" | head -n 1; }
	_dump=''
	for _f in "$_menu"/*.json; do
		[ -f "$_f" ] || continue
		_dump="$_dump $(basename "$_f")[parent=$(_mkey "$_f" parent) index=$(_mnum "$_f" index) view=$(_mkey "$_f" view) title=$(_mkey "$_f" title)]"
	done
	[ -n "$_dump" ] && pass ui.menu.files "menu entries (what the native-gui placement is derived from):$_dump"
	# The Tailscale entry: view, title or name mentions tailscale (case-insensitive; the key is not assumed to be view=tailscale).
	# The installer copies parent/level/icon/mode from it and places tsem right below it.
	_tsf='' _fbf=''
	for _f in "$_menu"/*.json; do
		[ -f "$_f" ] || continue
		[ "$(basename "$_f")" = tsem.json ] && continue
		for _k in view title name; do
			case $(_mkey "$_f" $_k | tr 'A-Z' 'a-z') in *tailscale*) _tsf=$_f; break ;; esac
		done
		[ -n "$_tsf" ] && break
		[ -z "$_fbf" ] && [ "$(_mkey "$_f" parent | tr 'A-Z' 'a-z')" = applications ] && _fbf=$_f
	done
	if [ -n "$_tsf" ]; then
		pass ui.menu.tailscale "reference entry ${_tsf#"$R"}: $(tr -d '\n\t' <"$_tsf" | cut -c1-300)"
		_par=$(sed -n 's/.*"parent"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_tsf" | head -n 1)
		if [ -n "$_par" ]; then
			_sib=''
			for _f in "$_menu"/*.json; do
				[ -f "$_f" ] || continue
				grep -q "\"parent\"[[:space:]]*:[[:space:]]*\"$_par\"" "$_f" 2>/dev/null || continue
				_sib="$_sib $(sed -n 's/.*"index"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$_f" | head -n 1):$(sed -n 's/.*"view"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_f" | head -n 1)"
			done
			pass ui.menu.order "entries under parent '$_par' (index:view): $(printf '%s\n' $_sib | sort -n | tr '\n' ' ')"
		fi
	elif [ -n "$_fbf" ]; then
		warn ui.menu.tailscale "no menu file whose view/title/name mentions tailscale; native-gui would copy the fields from the APPLICATIONS sibling ${_fbf#"$R"} and put the entry at the END of that group (position below Tailscale cannot be honoured; see ui.menu.files for the real structure)"
	elif [ -d "$_menu" ]; then
		warn ui.menu.tailscale "no Tailscale menu entry and no entry under parent 'applications' (see ui.menu.files): position/parent of a new entry would be a guess (native-gui refuses to install)"
		_nmiss="$_nmiss tailscale-menu-entry"
	fi
	[ -f "$_menu/tsem.json" ] && pass ui.menu.tsem "tsem menu entry present: $(tr -d '\n\t' <"$_menu/tsem.json" | cut -c1-200)"
	# stock view bundle of Tailscale: how does the UI authenticate and call its RPC? (counts only)
	_bundle=$_views/gl-sdk4-ui-tailscale.common.js.gz
	if [ -f "$_bundle" ] && have gzip; then
		for _pat in 'Admin-Token' '/rpc' 'glinet' '"call"'; do
			_c=$(gzip -dc "$_bundle" 2>/dev/null | grep -c -F -- "$_pat")
			if [ "${_c:-0}" -gt 0 ]; then pass "ui.bundle.$(printf '%s' "$_pat" | tr -c 'A-Za-z' '_')" "stock Tailscale view mentions $_pat ($_c lines)"; else warn "ui.bundle.$(printf '%s' "$_pat" | tr -c 'A-Za-z' '_')" "stock Tailscale view does not mention $_pat: the native view's assumption about it is NOT confirmed"; fi
		done
	else
		skip ui.bundle "stock Tailscale view bundle not readable or no gzip: session/RPC call shape stays UNVERIFIED"
	fi
	# RPC object shape of the stock Tailscale backend
	_rt=$_rpcdir/tailscale
	if [ -f "$_rt" ]; then
		_ret=$(grep -c '^return' "$_rt" 2>/dev/null)
		_loc=$(grep -c '^local M *= *{}' "$_rt" 2>/dev/null)
		if [ "${_ret:-0}" -gt 0 ] && [ "${_loc:-0}" -gt 0 ]; then pass ui.rpc.shape "stock rpc object is a Lua module table (M = {} ... return M)"; else warn ui.rpc.shape "stock rpc object does not look like a module table (M = {} ... return M): the bridge's module shape is NOT confirmed"; fi
		grep -q 'cjson' "$_rt" 2>/dev/null && pass ui.rpc.cjson "stock rpc object uses cjson (the bridge requires it)" || warn ui.rpc.cjson "stock rpc object does not mention cjson"
	elif [ -d "$_rpcdir" ]; then
		warn ui.rpc.shape "no stock rpc/tailscale object to compare with"
	fi
	[ -d "$_rpcdir" ] && pass ui.rpc.list "rpc objects: $(ls "$_rpcdir" 2>/dev/null | tr '\n' ' ')"
	[ -d "$R/usr/share/oui" ] && pass ui.share "/usr/share/oui contains: $(ls "$R/usr/share/oui" 2>/dev/null | tr '\n' ' ')"
	have lua && pass ui.lua "lua interpreter present" || skip ui.lua "no lua interpreter on the router: the bridge cannot be syntax-checked here"
	# web servers, LuCI, ports (WAN exposure is judged by the bound addresses)
	[ -x "$R/etc/init.d/nginx" ] && pass web.nginx "nginx init script present (GL.iNet UI server)" || skip web.nginx "no nginx init script"
	[ -d "$R/usr/lib/lua/luci" ] || [ -f "$R/www/luci-static/resources/luci.js" ] && pass web.luci "LuCI present (luci-gui fallback possible)" || warn web.luci "LuCI not found: the luci-gui fallback cannot be used on this router"
	_ls=$(listeners_portable)
	if [ -n "$_ls" ]; then
		pass web.listeners "TCP listeners: $(printf '%s\n' "$_ls" | sort -u | tr '\n' ' ')"
		_wild=$(printf '%s\n' "$_ls" | grep '^0\.0\.0\.0:' | grep -E ':(80|443|8080|8443)$' | tr '\n' ' ')
		[ -n "$_wild" ] && warn web.wan_exposure "web ports listen on all addresses ($_wild): whether the WAN side is closed depends on the firewall input rules (checked in section fw)" || pass web.wan_exposure "no web port bound to 0.0.0.0"
	else
		skip web.listeners "cannot read /proc/net/tcp"
	fi
	# ubus / rpcd
	if have ubus; then
		_u=$(ubus list 2>/dev/null)
		[ -n "$_u" ] && pass ubus.list "$(printf '%s\n' "$_u" | wc -l | tr -d ' ') ubus objects; tsem object: $(printf '%s\n' "$_u" | grep -x tsem || echo absent); gl-sdk objects: $(printf '%s\n' "$_u" | grep -c -E '^(gl|oui)') "
	else
		skip ubus.list "ubus not available"
	fi
	[ -d "$R/usr/share/rpcd/acl.d" ] && pass rpcd.acl "rpcd ACL directory: $(ls "$R/usr/share/rpcd/acl.d" 2>/dev/null | tr '\n' ' ')"
	# firmware-upgrade behaviour: which of our paths would survive a sysupgrade with settings kept
	_keep=$(cat "$R/etc/sysupgrade.conf" "$R"/lib/upgrade/keep.d/* 2>/dev/null)
	for _kp in /etc/tsem /usr/share/oui /www/views /usr/lib/oui-httpd /usr/libexec/rpcd; do
		if printf '%s\n' "$_keep" | grep -q "^$_kp"; then pass "upg.keep" "$_kp is preserved by a settings-keeping upgrade"; else skip "upg.keep" "$_kp is NOT in the keep lists: after a firmware upgrade it is the firmware's version again (reinstall the component)"; fi
	done
	# installed TSEM version (RC3 / RC3.1 / current)
	_tv=$(sed -n 's/^version=//p' "$R/etc/tsem/install.manifest" 2>/dev/null | head -n 1)
	[ -n "$_tv" ] || _tv=$(sed -n 's/^TSEM_VERSION=//p' "$R/usr/lib/tsem/common.sh" 2>/dev/null | head -n 1)
	[ -n "$_tv" ] && pass tsem.version "installed TSEM version $_tv; components: $(sed -n 's/^C|//p' "$R/etc/tsem/install.manifest" 2>/dev/null | tr '\n' ' ')" || skip tsem.version "tsem is not installed"
	# verdict
	if [ -z "$_nmiss" ]; then
		pass native.verdict "static prerequisites for native-gui are present (still UNVERIFIED: session id source, RPC call shape, auth of a new RPC object, behaviour after a firmware upgrade; see docs/native-gui.md)"
	else
		warn native.verdict "native-gui would be refused by the installer: missing$_nmiss. The LuCI fallback is unaffected."
	fi
}

sec_risks() {
	sect "11 Known boot and firewall-reload risks (not measurable read-only)"
	skip risk.boot "boot leak window needs a reboot: not done; full boot freedom is NOT claimed"
	skip risk.reload "fw3 reload flush gap of INPUT/OUTPUT/FORWARD needs a reload: not done"
	skip risk.failover "failover and exit-node switching are active tests: not done"
	skip risk.packet "packet-path and IPv6 packet tests were only run in namespaces, never on the device"
	skip risk.masq "masquerade return path was simulated in namespaces; here only configuration is read"
}

# ============================================================ summary
summary() {
	sect "Summary"
	printf 'PASS=%d WARN=%d FAIL=%d SKIP=%d (essential evidence missing: %d)\n' "$NP" "$NW" "$NF" "$NS" "$NE"
	if [ "$NF" -gt 0 ]; then
		REC=NEEDS_FIX
		CODE=1
	elif [ "$NE" -gt 0 ]; then
		REC=INSUFFICIENT_EVIDENCE
		CODE=2
	else
		REC=READY_FOR_PASSIVE_INSTALL
		CODE=0
	fi
	[ -n "$FAILS" ] && printf 'Blocking (FAIL):%s\n' "$FAILS"
	[ -n "$ESSL" ] && printf 'Evidence missing:%s\n' "$ESSL"
	[ -n "$WARNL" ] && printf 'Warnings:%s\n' "$WARNL"
	printf 'RECOMMENDATION: %s\n' "$REC"
	printf 'Scope: READY_FOR_PASSIVE_INSTALL covers an install WITHOUT autostart, firewall include and hardware-switch replacement only.\n'
	printf 'It is NOT a release for the kill switch or GERMAN mode (flow offloading, boot and reload windows, IPv6 and the switch convention need hardware proof).\n'
	printf 'RESULT %s pass=%d warn=%d fail=%d skip=%d missing=%d\n' "$REC" "$NP" "$NW" "$NF" "$NS" "$NE"
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		--repo)
			[ $# -ge 2 ] || { echo "--repo needs a value" >&2; exit 64; }
			REPO=$2
			shift 2
			;;
		-h | --help)
			sed -n '2,22p' "$0" 2>/dev/null
			exit 0
			;;
		*)
			echo "unknown option: $1 (this tool is read-only and has no other options)" >&2
			exit 64
			;;
		esac
	done
	FP0=$(fingerprint)
	REPO_OK=0
	echo "TSEM PREFLIGHT v1 (read-only; no install, no change)"
	echo "host: $(uname -n 2>/dev/null)  date: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)  repo: $REPO"
	gather
	_hs=sha256sum
	have sha256sum || _hs=md5sum
	echo "# hashalg $_hs"
	for _f in install.sh uninstall.sh src/etc/tsem/tsem.conf src/usr/lib/tsem/backend_ipt.sh src/usr/lib/tsem/conf.sh src/usr/sbin/tsem contrib/tsem-switch.sh; do
		[ -f "$REPO/$_f" ] && echo "# hash $($_hs "$REPO/$_f" 2>/dev/null | cut -d' ' -f1) $_f"
	done
	sec_system
	sec_tsem
	sec_policy
	sec_nodes
	sec_masq
	sec_switch
	sec_dns_ipv6
	sec_fw_res
	sec_conf
	sec_dryrun
	sec_native
	sec_risks
	sect "Read-only proof"
	FP1=$(fingerprint)
	if [ "$FP0" = "$FP1" ]; then pass proof.readonly "fingerprint of /etc/config, rc.d, gl-switch.d and tsem files unchanged during this run"; else warn proof.readonly "fingerprint changed during the run (a concurrent change; this tool writes nothing)"; fi
	summary
	exit "$CODE"
}

main "$@" </dev/null
