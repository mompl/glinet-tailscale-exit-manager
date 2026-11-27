# shellcheck shell=sh
# Production backend for OpenWrt/GL.iNet (fw3 + iptables-legacy + Tailscale).
#
# KILL SWITCH = TWO INDEPENDENT LAYERS (either one alone stops a leak):
#
#  Layer 1  policy routing  (survives fw3 reload and a dead userspace monitor)
#      ip rule  prio P    iif <lan>  lookup main suppress_prefixlength 0
#      ip rule  prio P+10 iif <lan>  prohibit   (or unreachable/blackhole: see TSEM_RT_DENY)
#    P defaults to 5280, i.e. AFTER tailscale's "5270: lookup 52". Traffic from
#    the protected interface can therefore use table 52 (tunnel, tailnet) and
#    connected routes, but never a default route of the main table (WAN). If
#    tailscaled dies or the exit node is unset, there is no default route left
#    for LAN traffic: it is prohibited, not sent out via WAN.
#
#  Layer 2  netfilter       (own chain, jumped to from FORWARD position 1)
#      TSEM_FWD:  german   LAN -> tailscale0 | LAN -> LAN | else REJECT
#                 blocked  LAN -> tailnet only | LAN -> LAN | else REJECT
#                 open     RETURN
#    The jump is the FIRST rule of FORWARD, so later fw3 ACCEPT / RELATED /
#    ESTABLISHED rules cannot bypass it. fw3 flushes FORWARD on reload; the
#    firewall include (reload=1) and `tsem tick` re-assert the hook, and layer 1
#    covers the gap.
#
#  Router-originated traffic (RC2): chain TSEM_OUT, jumped to from OUTPUT position 1
#      TSEM_OUT:  german|blocked  lo | tailscale0 | LAN ifaces | tailscaled underlay (marked)
#                                 | DHCP/ND | optional NTP  -> RETURN, everything else REJECT
#                 open            RETURN
#    This is the ONLY layer for router-own traffic (policy routing cannot cover it: connected
#    routes such as the WAN subnet stay usable). The tailscaled exception is the fwmark that
#    tailscaled sets on its own sockets, restricted to udp and tcp/80,443 and NOT to port 53.
#    See docs/rc/router-egress.md.
#
# DNS redirection of LAN clients (TSEM_DNS_REDIRECT) is separate. See docs/rc/dns-ipv6.md.
#
# Each apply is verified by reading the kernel state back; be_guard_set returns
# non-zero unless the state really matches.

_have_v6() { [ -e /proc/net/if_inet6 ] && command -v ip6tables >/dev/null 2>&1; }
_v6_kernel() { [ -e /proc/net/if_inet6 ]; }

_ipt() { _ic=$1; shift; "$_ic" -w 5 "$@"; }
_fams() { echo 4; if _v6_kernel; then echo 6; fi; }
_ipcmd() { if [ "$1" = 4 ]; then echo iptables; else echo ip6tables; fi; }
_restore_cmd() { if [ "$1" = 4 ]; then echo iptables-restore; else echo ip6tables-restore; fi; }

_tmo_form=''
_tmo() { # _tmo SECONDS cmd...
	_t=$1; shift
	if [ -z "$_tmo_form" ]; then
		if timeout 1 true >/dev/null 2>&1; then _tmo_form=new
		elif timeout -t 1 true >/dev/null 2>&1; then _tmo_form=old
		else _tmo_form=none; fi
	fi
	case $_tmo_form in
	new) timeout "$_t" "$@" ;;
	old) timeout -t "$_t" "$@" ;;
	*) "$@" ;;
	esac
}

# ---------------------------------------------------------------- rule text

_g_fw_rules() { # family state
	if [ "$1" = 4 ]; then _tn=$TSEM_TAILNET4 _as=$TSEM_ALLOW_SUBNETS4
	else _tn=$TSEM_TAILNET6 _as=$TSEM_ALLOW_SUBNETS6; fi
	echo '*filter'
	echo ':TSEM_FWD - [0:0]'
	echo '-F TSEM_FWD'
	if [ "$2" = open ]; then
		echo '-A TSEM_FWD -m comment --comment tsem:open -j RETURN'
	else
		for _l in $TSEM_LAN_IFACES; do
			if [ "$2" = german ]; then
				echo "-A TSEM_FWD -i $_l -o $TSEM_TS_IFACE -j RETURN"
				for _x in $TSEM_ALLOW_OUT_IFACES; do echo "-A TSEM_FWD -i $_l -o $_x -j RETURN"; done
			else
				echo "-A TSEM_FWD -i $_l -o $TSEM_TS_IFACE -d $_tn -j RETURN"
				for _s in $_as; do echo "-A TSEM_FWD -i $_l -o $TSEM_TS_IFACE -d $_s -j RETURN"; done
			fi
			for _x in $TSEM_LAN_IFACES; do echo "-A TSEM_FWD -i $_l -o $_x -j RETURN"; done
			echo "-A TSEM_FWD -i $_l -m comment --comment tsem:$2 -j REJECT"
		done
	fi
	echo COMMIT
}

_g_nat_rules() { # state (IPv4 only)
	echo '*nat'
	echo ':TSEM_DNS - [0:0]'
	echo '-F TSEM_DNS'
	echo ':TSEM_DNS_OUT - [0:0]'
	echo '-F TSEM_DNS_OUT'
	if [ "$1" != open ] && [ -n "$TSEM_DNS_REDIRECT" ]; then
		for _l in $TSEM_LAN_IFACES; do
			for _p in udp tcp; do
				echo "-A TSEM_DNS -i $_l -p $_p --dport 53 ! -d $TSEM_DNS_REDIRECT -j DNAT --to-destination $TSEM_DNS_REDIRECT"
			done
		done
	fi
	# F03: the ROUTER's own DNS. dnsmasq/nslookup on the router use the upstream resolvers it got from the WAN
	# (DHCP/PPP: ISP resolvers). While protected, router-own traffic leaves through the exit node, and an ISP
	# resolver is typically NOT reachable from there (hardware: nslookup timed out, tailscaled reported the
	# resolvers 103.100.x unreachable). Every router-own port-53 query is therefore redirected to a resolver
	# that is reachable through the exit node (TSEM_DNS_ROUTER). In BLOCKED the redirected query still has no
	# way out (TSEM_OUT rejects it), so this never opens anything. DIRECT leaves the chain empty.
	if [ "$1" != open ] && [ -n "$TSEM_DNS_ROUTER" ]; then
		echo "-A TSEM_DNS_OUT -m mark --mark $TSEM_UNDERLAY_MARK -j RETURN"
		echo '-A TSEM_DNS_OUT -d 127.0.0.0/8 -j RETURN'
		echo "-A TSEM_DNS_OUT -d $TSEM_TAILNET4 -j RETURN"
		for _l in $TSEM_LAN_IFACES; do echo "-A TSEM_DNS_OUT -o $_l -j RETURN"; done
		echo "-A TSEM_DNS_OUT -d $TSEM_DNS_ROUTER -j RETURN"
		for _p in udp tcp; do
			echo "-A TSEM_DNS_OUT -p $_p --dport 53 -j DNAT --to-destination $TSEM_DNS_ROUTER"
		done
	fi
	echo COMMIT
}

_out_want() { # state -> state the OUTPUT chain must have
	if [ "$TSEM_OUT_GUARD" = on ]; then echo "$1"; else echo open; fi
}

_g_out_rules() { # family state  (state already passed through _out_want)
	echo '*filter'
	echo ':TSEM_OUT - [0:0]'
	echo '-F TSEM_OUT'
	if [ "$2" = open ]; then
		echo '-A TSEM_OUT -m comment --comment tsem:open -j RETURN'
	else
		_om=$TSEM_UNDERLAY_MARK
		echo '-A TSEM_OUT -o lo -j RETURN'
		echo "-A TSEM_OUT -o $TSEM_TS_IFACE -j RETURN"
		for _l in $TSEM_LAN_IFACES $TSEM_OUT_LOCAL_IFACES; do echo "-A TSEM_OUT -o $_l -j RETURN"; done
		# v1.1: management of the router over a WAN-side private network (e.g. a Wi-Fi uplink): replies and connections to these
		# destination networks only (never a default route, never the Internet). Empty by default.
		if [ "$1" = 4 ]; then _am=$TSEM_ADMIN_SUBNETS4; else _am=$TSEM_ADMIN_SUBNETS6; fi
		for _s in $_am; do echo "-A TSEM_OUT -d $_s -j RETURN"; done
		# tailscaled underlay: only its own marked sockets, udp or tcp/80,443, never DNS
		if [ "$TSEM_ALLOW_UNDERLAY_DNS" != 1 ]; then
			echo "-A TSEM_OUT -m mark --mark $_om -p udp --dport 53 -j REJECT"
			echo "-A TSEM_OUT -m mark --mark $_om -p tcp --dport 53 -j REJECT"
		fi
		echo "-A TSEM_OUT -m mark --mark $_om -p udp -j RETURN"
		echo "-A TSEM_OUT -m mark --mark $_om -p tcp -m multiport --dports 80,443 -j RETURN"
		# address assignment on the WAN link
		if [ "$1" = 4 ]; then
			echo '-A TSEM_OUT -p udp --sport 68 --dport 67 -j RETURN'
		else
			echo '-A TSEM_OUT -p udp --sport 546 --dport 547 -j RETURN'
			for _t in router-solicitation neighbour-solicitation neighbour-advertisement; do
				echo "-A TSEM_OUT -p ipv6-icmp --icmpv6-type $_t -j RETURN"
			done
		fi
		[ "$TSEM_ALLOW_NTP" != 1 ] || echo '-A TSEM_OUT -p udp --dport 123 -j RETURN'
		echo "-A TSEM_OUT -m comment --comment tsem:$2 -j REJECT"
	fi
	echo COMMIT
}

# ------------------------------------------------------------------- hooks

_hook_last() { # cmd table parent chain -> number of the last matching rule (0 = none)
	_ipt "$1" -t "$2" -S "$3" 2>/dev/null | awk -v r="-A $3 -j $4" 'NR>1 && $0==r { l=NR-1 } END { print l+0 }'
}

_hook_ok() { # cmd table parent chain: exactly one jump, at position 1
	_hk_first=$(_ipt "$1" -t "$2" -S "$3" 2>/dev/null | sed -n '2p')
	[ "$_hk_first" = "-A $3 -j $4" ] && [ "$(_hook_last "$1" "$2" "$3" "$4")" = 1 ]
}

_hook_ensure() {
	_hook_ok "$@" && return 0
	_ipt "$1" -t "$2" -I "$3" 1 -j "$4" || return 1
	while :; do
		_hk_n=$(_hook_last "$1" "$2" "$3" "$4")
		[ "$_hk_n" -gt 1 ] || break
		_ipt "$1" -t "$2" -D "$3" "$_hk_n" || return 1
	done
	_hook_ok "$@"
}

_hook_remove() {
	while :; do
		_hk_n=$(_hook_last "$1" "$2" "$3" "$4")
		[ "$_hk_n" -gt 0 ] || break
		_ipt "$1" -t "$2" -D "$3" "$_hk_n" || return 1
	done
	return 0
}

# --------------------------------------------------------- policy routing

_rule_has() { # family prio iface word
	ip -"$1" rule show 2>/dev/null | awk -v p="$2:" -v i="$3" -v w="$4" '
		$1 == p { a = 0; b = 0
			for (k = 2; k <= NF; k++) { if ($k == "iif" && $(k+1) == i) a = 1; if ($k == w) b = 1 }
			if (a && b) f = 1 }
		END { exit !f }'
}

# The deny action of layer 1. "prohibit" (EACCES) is preferred; "unreachable"/"blackhole" are equally
# fail-closed (traffic is dropped, never routed) and are used when the kernel/iproute2 refuses the
# preferred one. _rule_deny matches any of the three.
_rule_deny() { # family prio iface
	ip -"$1" rule show 2>/dev/null | awk -v p="$2:" -v i="$3" '
		$1 == p { a = 0; b = 0
			for (k = 2; k <= NF; k++) { if ($k == "iif" && $(k+1) == i) a = 1; if ($k == "prohibit" || $k == "unreachable" || $k == "blackhole") b = 1 }
			if (a && b) f = 1 }
		END { exit !f }'
}

_rule_deny_add() { # family iface prio : first accepted action wins; none accepted = failure (caller blocks)
	case $TSEM_RT_DENY in auto) _da_list="prohibit unreachable blackhole" ;; *) _da_list=$TSEM_RT_DENY ;; esac
	for _da in $_da_list; do
		ip -"$1" rule add iif "$2" priority "$3" "$_da" 2>/dev/null && _rule_deny "$1" "$3" "$2" && return 0
	done
	return 1
}

# A deny rule on the suppress priority (P) is never ours in this layout (ours is P+10). It is a leftover of an
# older release or a manual rule and would block every LAN client even in DIRECT: treat it as stray, remove it.
_rt_stray() { # family iface
	_rule_deny "$1" "$TSEM_RULE_PRIO" "$2"
}
_rt_stray_del() {
	for _f in $(_fams); do
		for _l in $TSEM_LAN_IFACES; do
			while _rt_stray "$_f" "$_l"; do
				ip -"$_f" rule del iif "$_l" priority "$TSEM_RULE_PRIO" 2>/dev/null || break
				log "removed stray deny rule at priority $TSEM_RULE_PRIO ($_l, IPv$_f)"
			done
		done
	done
	return 0
}

_rt_on() {
	_rt_stray_del
	[ "$TSEM_RT_GUARD" = on ] || return 0
	_p2=$((TSEM_RULE_PRIO + 10))
	for _f in $(_fams); do
		for _l in $TSEM_LAN_IFACES; do
			_rule_has "$_f" "$TSEM_RULE_PRIO" "$_l" suppress_prefixlength ||
				ip -"$_f" rule add iif "$_l" priority "$TSEM_RULE_PRIO" lookup main suppress_prefixlength 0 || return 1
			_rule_deny "$_f" "$_p2" "$_l" ||
				_rule_deny_add "$_f" "$_l" "$_p2" || return 1
		done
	done
}

_rt_off() {
	_rt_stray_del
	_p2=$((TSEM_RULE_PRIO + 10))
	for _f in $(_fams); do
		for _l in $TSEM_LAN_IFACES; do
			while _rule_has "$_f" "$TSEM_RULE_PRIO" "$_l" suppress_prefixlength; do
				ip -"$_f" rule del iif "$_l" priority "$TSEM_RULE_PRIO" || return 1
			done
			while _rule_deny "$_f" "$_p2" "$_l"; do
				ip -"$_f" rule del iif "$_l" priority "$_p2" || return 1
			done
		done
	done
	return 0
}

_rt_state() { # -> all|none|partial
	[ "$TSEM_RT_GUARD" = on ] || { echo n/a; return; }
	_p2=$((TSEM_RULE_PRIO + 10)) _have=0 _miss=0
	for _f in $(_fams); do
		for _l in $TSEM_LAN_IFACES; do
			if _rule_has "$_f" "$TSEM_RULE_PRIO" "$_l" suppress_prefixlength; then _have=$((_have + 1)); else _miss=$((_miss + 1)); fi
			if _rule_deny "$_f" "$_p2" "$_l"; then _have=$((_have + 1)); else _miss=$((_miss + 1)); fi
			if _rt_stray "$_f" "$_l"; then _have=$((_have + 1)); _miss=$((_miss + 1)); fi
		done
	done
	if [ "$_miss" -eq 0 ]; then echo all; elif [ "$_have" -eq 0 ]; then echo none; else echo partial; fi
}

# --------------------------------------------------------------- fast path
# Hardware/software fast paths (Qualcomm/MediaTek "SFE"/shortcut-fe/fast_classifier, fw3 flow
# offloading) cache established flows and forward them WITHOUT traversing iptables or re-evaluating
# ip rules. A LAN->WAN flow that was set up while the guard was open (or via a now-dead exit node)
# would then keep leaking after the guard closes. Therefore, while the guard is german|blocked:
#   TSEM_FASTPATH=unload  the modules are removed (rmmod) and the result is VERIFIED; failure = guard not installed
#   TSEM_FASTPATH=refuse  nothing is touched; a loaded fast path simply makes the guard "inconsistent" (leak_risk)
# Offload flows from fw3 (FLOWOFFLOAD target in FORWARD) are detected too; they cannot be unloaded,
# so they are reported as inconsistent as well. Never assumed away.
_FP_MODS="shortcut_fe_cm shortcut_fe_drv shortcut_fe_ipv6 shortcut_fe fast_classifier sfe_ipv4 sfe_ipv6 sfe_cm ecm qca_nss_ecm"
_fp_loaded() { # prints loaded fast-path module names, one per line
	_fp_f=${TSEM_PROC_MODULES:-/proc/modules}
	[ -r "$_fp_f" ] || return 0
	for _fp_m in $_FP_MODS; do
		awk -v m="$_fp_m" '$1 == m { f = 1 } END { exit !f }' "$_fp_f" && echo "$_fp_m"
	done
	return 0
}
_fp_offload() { # fw3 flow offloading present in FORWARD?
	for _fo_f in $(_fams); do
		_ipt "$(_ipcmd "$_fo_f")" -S FORWARD 2>/dev/null | grep -q -- 'FLOWOFFLOAD' && return 0
	done
	return 1
}
be_fastpath_state() { # -> none | loaded:<mods> | offload
	_fs=$(_fp_loaded | tr '\n' ',' | sed 's/,$//')
	if [ -n "$_fs" ]; then echo "loaded:$_fs"; return 0; fi
	if _fp_offload; then echo offload; return 0; fi
	echo none
}
_fp_unload() {
	[ "$TSEM_FASTPATH" = unload ] || return 0
	_fu=$(_fp_loaded)
	[ -n "$_fu" ] || return 0
	log "fast path loaded ($(echo $_fu)): removing it so established flows cannot bypass the kill switch"
	for _fu_m in $_fu; do "${TSEM_RMMOD:-rmmod}" "$_fu_m" >/dev/null 2>&1 || true; done
	_fu2=$(_fp_loaded)
	[ -z "$_fu2" ] || { log "fast path still loaded after rmmod: $(echo $_fu2)"; return 1; }
	return 0
}

# ------------------------------------------------------------------- guard

_sum_file() { echo "$TSEM_RUN_DIR/fwsum.$1"; }

_fw_dump() { _ipt "$(_ipcmd "$1")" -S TSEM_FWD 2>/dev/null; }
_out_dump() { _ipt "$(_ipcmd "$1")" -S TSEM_OUT 2>/dev/null; }
_out_sum_file() { echo "$TSEM_RUN_DIR/outsum.$1"; }

_fw_apply() { # state
	_af=$(_fams)
	# without ip6tables only an open guard is ever applied (be_guard_set refuses the rest): there is no IPv6 rule of ours to write
	if _v6_kernel && ! _have_v6; then _af=4; fi
	for _f in $_af; do
		_g_fw_rules "$_f" "$1" | "$(_restore_cmd "$_f")" -w 5 -n || return 1
		_hook_ensure "$(_ipcmd "$_f")" filter FORWARD TSEM_FWD || return 1
		_g_out_rules "$_f" "$(_out_want "$1")" | "$(_restore_cmd "$_f")" -w 5 -n || return 1
		_hook_ensure "$(_ipcmd "$_f")" filter OUTPUT TSEM_OUT || return 1
	done
	# DNS redirect chain (IPv4). Always (re)written so config changes take effect.
	_g_nat_rules "$1" | iptables-restore -w 5 -n || return 1
	_hook_ensure iptables nat PREROUTING TSEM_DNS || return 1
	_hook_ensure iptables nat OUTPUT TSEM_DNS_OUT || return 1
	mkdir -p "$TSEM_RUN_DIR" 2>/dev/null
	for _f in $_af; do
		_fw_dump "$_f" | md5sum | cut -c1-32 >"$(_sum_file "$_f")"
		_out_dump "$_f" | md5sum | cut -c1-32 >"$(_out_sum_file "$_f")"
	done
	return 0
}

_chain_state() { # family chain parent sumfile -> open|german|blocked|none|inconsistent
	_c=$(_ipcmd "$1")
	_ipt "$_c" -S "$2" >/dev/null 2>&1 || { echo none; return; }
	_hook_ok "$_c" filter "$3" "$2" || { echo inconsistent; return; }
	_st=$(_ipt "$_c" -S "$2" 2>/dev/null | sed -n 's/.*--comment "\{0,1\}\(tsem:[a-z]*\)"\{0,1\}.*/\1/p' | sort -u)
	case $_st in
	tsem:open) _r=open ;;
	tsem:german) _r=german ;;
	tsem:blocked) _r=blocked ;;
	*) echo inconsistent; return ;;
	esac
	# tamper/drift: chain content must equal what we applied (when we know it)
	if [ -f "$4" ] && [ "$(_ipt "$_c" -S "$2" 2>/dev/null | md5sum | cut -c1-32)" != "$(cat "$4")" ]; then
		echo inconsistent
		return
	fi
	echo "$_r"
}

_fw_state() { _chain_state "$1" TSEM_FWD FORWARD "$(_sum_file "$1")"; }
_out_state() { _chain_state "$1" TSEM_OUT OUTPUT "$(_out_sum_file "$1")"; }

be_guard_get() {
	_g4=$(_fw_state 4)
	_g=$_g4
	_gf=$(_fams)
	if _v6_kernel && ! _have_v6; then
		# ip6tables is missing (e.g. removed by a firmware upgrade): an open guard needs no IPv6 rule of ours, so DIRECT
		# is healthy; any protected state cannot be verified (fail closed: reported inconsistent).
		case $_g4 in open) ;; none) echo none; return 0 ;; *) echo inconsistent; return 0 ;; esac
		_gf=4
	elif _v6_kernel; then
		_g6=$(_fw_state 6)
		[ "$_g4" = "$_g6" ] || { echo inconsistent; return 0; }
	fi
	case $_g in none | inconsistent) echo "$_g"; return 0 ;; esac
	if [ "$_g" != open ] && [ "$(be_fastpath_state)" != none ]; then echo inconsistent; return 0; fi
	for _f in $_gf; do
		[ "$(_out_state "$_f")" = "$(_out_want "$_g")" ] || { echo inconsistent; return 0; }
	done
	_rs=$(_rt_state)
	case $_g in
	open) [ "$_rs" = none ] || [ "$_rs" = n/a ] || { echo inconsistent; return 0; } ;;
	*) [ "$_rs" = all ] || [ "$_rs" = n/a ] || { echo inconsistent; return 0; } ;;
	esac
	if [ -n "$TSEM_DNS_REDIRECT" ] && [ "$_g" != open ]; then
		_hook_ok iptables nat PREROUTING TSEM_DNS &&
			_ipt iptables -t nat -S TSEM_DNS 2>/dev/null | grep -q -- '-j DNAT' || { echo inconsistent; return 0; }
	fi
	if [ -n "$TSEM_DNS_ROUTER" ] && [ "$_g" != open ]; then
		_hook_ok iptables nat OUTPUT TSEM_DNS_OUT &&
			_ipt iptables -t nat -S TSEM_DNS_OUT 2>/dev/null | grep -q -- '-j DNAT' || { echo inconsistent; return 0; }
	fi
	echo "$_g"
}

be_guard_set() {
	case $1 in open | german | blocked) ;; *) return 1 ;; esac
	[ -n "$TSEM_LAN_IFACES" ] || { log "TSEM_LAN_IFACES is empty"; return 1; }
	if _v6_kernel && ! _have_v6; then
		# a protected mode cannot be guaranteed without ip6tables (fail closed), but DIRECT must always be reachable: there is
		# nothing to protect and no IPv6 rule of ours can exist. (A firmware upgrade removes opkg packages: see 'tsem deps'.)
		if [ "$1" != open ]; then
			log "IPv6 is enabled but ip6tables is missing: cannot guarantee IPv6 protection"
			return 1
		fi
		log "IPv6 is enabled but ip6tables is missing: IPv6 is not covered (DIRECT only); reinstall it: tsem deps"
	fi
	if [ "$1" = open ]; then
		# Any order is safe: each layer alone still blocks until both are gone.
		_rt_off || return 1
		_fw_apply open || return 1
	else
		# Closing: restrictive layer first, so there is no open window.
		_rt_on || return 1
		_fp_unload || return 1
		_fw_apply "$1" || return 1
	fi
	[ "$(be_guard_get)" = "$1" ] || { log "guard verification failed (wanted $1, kernel says $(be_guard_get))"; return 1; }
	command -v dnsup_sync >/dev/null 2>&1 && dnsup_sync "$1"
	return 0
}

be_guard_remove() {
	_rt_off
	for _f in $(_fams); do
		_c=$(_ipcmd "$_f")
		_hook_remove "$_c" filter FORWARD TSEM_FWD
		_ipt "$_c" -F TSEM_FWD 2>/dev/null
		_ipt "$_c" -X TSEM_FWD 2>/dev/null
		rm -f "$(_sum_file "$_f")"
		_hook_remove "$_c" filter OUTPUT TSEM_OUT
		_ipt "$_c" -F TSEM_OUT 2>/dev/null
		_ipt "$_c" -X TSEM_OUT 2>/dev/null
		rm -f "$(_out_sum_file "$_f")"
	done
	_hook_remove iptables nat PREROUTING TSEM_DNS
	_hook_remove iptables nat OUTPUT TSEM_DNS_OUT
	_ipt iptables -t nat -F TSEM_DNS_OUT 2>/dev/null
	_ipt iptables -t nat -X TSEM_DNS_OUT 2>/dev/null
	_ipt iptables -t nat -F TSEM_DNS 2>/dev/null
	_ipt iptables -t nat -X TSEM_DNS 2>/dev/null
	command -v dnsup_sync >/dev/null 2>&1 && dnsup_sync open
	return 0
}

# --------------------------------------------------------------- tailscale

_tsc() { _tmo 15 "${TSEM_TAILSCALE:-tailscale}" "$@"; }

be_exit_set() {
	case $1 in
	none) _tsc set --exit-node= ;;
	*) valid_ip4 "$1" || return 1; _tsc set --exit-node="$1" ;;
	esac
}

# Reads the active exit node from `tailscale status --json` (ExitNodeStatus),
# falling back to the prefs when the node is selected but not yet in the netmap.
be_exit_get() {
	_js=$(_tsc status --json 2>/dev/null) || { echo unavailable; return 0; }
	[ -n "$_js" ] || { echo unavailable; return 0; }
	_ip=$(printf '%s\n' "$_js" | awk '
		/"ExitNodeStatus": *null/ { exit }
		/"ExitNodeStatus": *\{/ { inb = 1 }
		inb && match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')
	if [ -n "$_ip" ]; then echo "$_ip"; return 0; fi
	_pf=$(_tsc debug prefs 2>/dev/null) || { echo none; return 0; }
	_pip=$(printf '%s\n' "$_pf" | sed -n 's/.*"ExitNodeIP": *"\([0-9.]*\)".*/\1/p' | head -n 1)
	_pid=$(printf '%s\n' "$_pf" | sed -n 's/.*"ExitNodeID": *"\([^"]*\)".*/\1/p' | head -n 1)
	if [ -n "$_pip" ]; then echo "$_pip"
	elif [ -n "$_pid" ]; then echo pending
	else echo none; fi
}

# Networks that tailnet peers advertise to this router (subnet routes): the routes in the tailscale table that are
# neither single hosts nor the tailnet's own 100.64.0.0/10 range. Read-only; one CIDR per line.
be_subnets_scan() {
	ip -4 route show table "$TSEM_TS_TABLE" 2>/dev/null | awk '$1 ~ /^[0-9.]+\/[0-9]+$/ && $1 !~ /\/32$/ && $1 !~ /^100\./ { print $1 }' | sort -u
	return 0
}

# Exit-node identity. `tailscale status --json` is parsed WITHOUT jq under the ASSUMPTION
# (unverified on 1.92.5, see docs/rc/test-plan.md) that it is pretty-printed with one key per
# line. Some tailscale builds (seen: 1.92 on a GL-MG1300) describe peers in a short form without HostName and Online until
# a connection exists: a peer starts at its node key, the DNS label stands in for the host name and online is "unknown"
# (identity and exit-node option are still verified; reachability is decided by the probe).
# The name shown and saved is the TAILNET name (the MagicDNS label that `tailscale status` and the admin console show, so every router
# agrees); the machine's own HostName stays valid as a second name for identity checks (older configs). Line: name|ips|online|exit|hostname. Result: $TSEM_RUN_DIR/peers, one line per node: name|ip,ip|online|exitoption|dnslabel
be_nodes_scan() {
	mkdir -p "$TSEM_RUN_DIR" 2>/dev/null
	# tailscaled can fail a single `status` call while it is busy (seen on the first mode change after a route/prefs
	# change): retry a few times before the nodes count as "unavailable", and log WHY if it still fails.
	_nj='' _na=0
	while [ "$_na" -lt "${TSEM_SCAN_TRIES:-3}" ]; do
		_nj=$(_tsc status --json 2>"$TSEM_RUN_DIR/ts.err") && [ -n "$_nj" ] && break
		_nj=''
		_na=$((_na + 1))
		[ "$_na" -ge "${TSEM_SCAN_TRIES:-3}" ] || sleep "${TSEM_SCAN_RETRY_DELAY:-1}"
	done
	if [ -z "$_nj" ]; then
		log "tailscale status failed after $_na tries: $(head -n 1 "$TSEM_RUN_DIR/ts.err" 2>/dev/null | cut -c1-120)"
		rm -f "$TSEM_RUN_DIR/peers"
		return 1
	fi
	printf '%s\n' "$_nj" | awk '
		function flush() { nm = (dns != "") ? dns : host; hn = (host != "") ? host : dns; if (nm != "") print tolower(nm) "|" ips "|" online "|" eno "|" tolower(hn); host = ""; dns = ""; ips = ""; online = "unknown"; eno = "false" }
		/"Peer": *\{/ { inpeer = 1; next }
		!inpeer { next }
		/"ExitNodeStatus": *\{/ { skip = 1; next }
		skip { if ($0 ~ /^ {0,4}\}/) skip = 0; next }
		/"nodekey:[0-9a-f]+": *\{/ { flush(); next }
		/"HostName": *"/ { s = $0; sub(/.*"HostName": *"/, "", s); sub(/".*/, "", s); host = s; next }
		/"DNSName": *"/ { s = $0; sub(/.*"DNSName": *"/, "", s); sub(/".*/, "", s); sub(/\..*/, "", s); dns = s; next }
		/"TailscaleIPs": *\[/ { inip = 1; next }
		inip && /\]/ { inip = 0; next }
		inip { if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) { ip = substr($0, RSTART, RLENGTH); ips = (ips == "" ? ip : ips "," ip) }; next }
		/"Online": *true/ { online = "true"; next }
		/"Online": *false/ { online = "false"; next }
		/"ExitNodeOption": *true/ { eno = "true"; next }
		END { flush() }' >"$TSEM_RUN_DIR/peers.tmp" && mv -f "$TSEM_RUN_DIR/peers.tmp" "$TSEM_RUN_DIR/peers"
}

# Only the "Peer" section is read (never Self: the router is not its own exit node).
# be_node_why NAME IP -> prints ok | reason ; exit 0 only for ok. Empty NAME = identity not verified (ok).
be_node_why() {
	if [ -z "$1" ]; then echo "ok (no name configured: identity NOT verified)"; return 0; fi
	if [ ! -r "$TSEM_RUN_DIR/peers" ]; then echo "tailscale status unavailable"; return 1; fi
	awk -F'|' -v n="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" -v ip="$2" '
		$1 == n || $5 == n { seen = 1; c = split($2, a, ","); has = 0; for (i = 1; i <= c; i++) if (a[i] == ip) has = 1
			if (!has) wrongip = 1; else { hit = 1; if ($3 == "false") off = 1; if ($4 != "true") noexit = 1 } }
		END {
			if (!seen) { print "no node with this name in the tailnet"; exit 1 }
			if (!hit && wrongip) { print "node exists but does not own " ip " (configured IP is wrong or was reassigned)"; exit 1 }
			if (off) { print "node is offline"; exit 1 }
			if (noexit) { print "node is not an approved exit node"; exit 1 }
			print "ok"; exit 0 }' "$TSEM_RUN_DIR/peers"
}

be_node_check() { be_node_why "$1" "$2" >/dev/null; }

# A single `tailscale ping` is not enough evidence: the first packets to a node that is only
# reachable through a DERP relay (no direct path yet) can need several seconds for path discovery
# and the WireGuard handshake. Up to three attempts; success of any one counts.
#
# `tailscale ping` exits 1 whenever no DIRECT path has been established, even though the peer
# answered through a DERP relay (observed on the GL-MT3000: "pong from <name> (<ip>) via DERP(nue)
# in 224ms", exit code 1). The exit code therefore says nothing about reachability; the OUTPUT does:
# only a pong line that names exactly this node's address counts. Identity (be_node_why), exit-node
# approval and the real egress proof (be_probe_egress) are separate gates and are NOT weakened here.
_ping_is_pong() { # ip <output on stdin>
	grep '^pong from ' | grep -F "($1)" | grep -Eq ' via [^ ].* in [0-9]'
}
be_probe_reach() {
	valid_ip4 "$1" || return 1
	_rc_i=0
	while [ "$_rc_i" -lt 3 ]; do
		_rc_o=$(_tmo 9 "${TSEM_TAILSCALE:-tailscale}" ping -c 1 --timeout=4s "$1" 2>&1)
		if printf '%s\n' "$_rc_o" | _ping_is_pong "$1"; then return 0; fi
		_rc_i=$((_rc_i + 1))
	done
	return 1
}

# Real egress check: an HTTPS request from the router. With an exit node set,
# tailscale's table 52 carries the default route, so this request leaves via
# the tunnel. IP-literal URLs avoid a DNS dependency; DNS is probed separately.
# curl exit code -> failure class (what the probe tells the operator instead of a bare "fail")
_pe_class() {
	case $1 in
	0) echo ok ;;
	6) echo dns ;;
	7) echo connect ;;
	28) echo timeout ;;
	35 | 51 | 58 | 60 | 77 | 83) echo tls ;;
	22) echo http ;;
	52 | 56) echo reset ;;
	*) echo "rc$1" ;;
	esac
}
# One line per probe call: "<host>=<class> ..." in the order tried (round 1, then round 2).
be_probe_detail() { cat "$TSEM_RUN_DIR/probe.detail" 2>/dev/null; }
_pe_save() { mkdir -p "$TSEM_RUN_DIR" 2>/dev/null; printf '%s\n' "$1" >"$TSEM_RUN_DIR/probe.detail" 2>/dev/null; return 0; }

be_probe_egress() {
	if [ -n "$TSEM_PROBE_CMD" ]; then
		_tmo $((TSEM_PROBE_TIMEOUT + 5)) "$TSEM_PROBE_CMD" >/dev/null 2>&1
		_pe_c=$?
		_pe_save "cmd=$(_pe_class "$_pe_c")"
		return "$_pe_c"
	fi
	# Two rounds: right after an exit node was selected the first connection can be lost while
	# tailscaled sets up the path (DERP first, direct later). A failure of BOTH rounds over
	# all URLs is a real failure; fail-closed is unchanged (no success = no german guard).
	_pe_r=0 _pe_d=''
	while [ "$_pe_r" -lt 2 ]; do
		for _u in $TSEM_PROBE_URLS; do
			_pe_h=${_u#*://}
			_pe_h=${_pe_h%%/*}
			if command -v curl >/dev/null 2>&1; then
				curl -fsS -o /dev/null --connect-timeout "$TSEM_PROBE_TIMEOUT" --max-time $((TSEM_PROBE_TIMEOUT + 2)) "$_u" >/dev/null 2>&1
				_pe_c=$?
				_pe_k=$(_pe_class "$_pe_c")
			elif command -v uclient-fetch >/dev/null 2>&1; then
				uclient-fetch -q -T "$TSEM_PROBE_TIMEOUT" -O /dev/null "$_u" >/dev/null 2>&1 && _pe_c=0 || _pe_c=1
				_pe_k=$([ "$_pe_c" -eq 0 ] && echo ok || echo fail)
			elif command -v wget >/dev/null 2>&1; then
				wget -q -T "$TSEM_PROBE_TIMEOUT" -O /dev/null "$_u" >/dev/null 2>&1 && _pe_c=0 || _pe_c=1
				_pe_k=$([ "$_pe_c" -eq 0 ] && echo ok || echo fail)
			else
				_pe_c=127 _pe_k=no-fetch-tool
			fi
			_pe_d="$_pe_d $_pe_h=$_pe_k"
			if [ "$_pe_c" -eq 0 ]; then _pe_save "${_pe_d# }"; return 0; fi
		done
		_pe_r=$((_pe_r + 1))
		[ "$_pe_r" -ge 2 ] || sleep 2
	done
	_pe_save "${_pe_d# }"
	return 1
}

be_probe_dns() {
	[ -n "$TSEM_DNS_PROBE_HOST" ] || return 0
	_o=$(_tmo 8 nslookup "$TSEM_DNS_PROBE_HOST" 2>/dev/null) || return 1
	printf '%s\n' "$_o" | awk '/^Name:/ { n = 1 } n && /^Address/ && /[0-9a-fA-F]/ { f = 1 } END { exit !f }'
}
