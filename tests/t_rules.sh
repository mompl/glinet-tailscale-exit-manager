# shellcheck shell=sh
# Golden rule-text tests for the production backend (IPv4 and IPv6).
# These prove what we *generate*; the netns suite proves what the kernel does (IPv4 only).

_rules() { ( . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load
	. "$TSEM_LIBDIR/backend_ipt.sh"; _g_fw_rules "$1" "$2" ); }

test_v6_german_has_no_unconditional_accept() {
	_r=$(_rules 6 german)
	assert_contains hdr '*filter' "$_r"
	assert_contains tail 'COMMIT' "$_r"
	assert_contains ts '-o tailscale0 -j RETURN' "$_r"
	assert_contains reject '-j REJECT' "$_r"
	case $_r in *'-j ACCEPT'*) fail "ACCEPT rule would bypass later chains" ;; esac
	case $_r in *ESTABLISHED*|*RELATED*) fail "conntrack bypass present" ;; esac
	# the last rule for each LAN iface must be the REJECT
	_last=$(printf '%s\n' "$_r" | grep -v '^COMMIT' | tail -1)
	assert_contains lastrule '-j REJECT' "$_last"
}

test_v6_and_v4_have_same_shape() {
	_a=$(_rules 4 german | sed 's/-d [0-9./]*//' | grep -c .)
	_b=$(_rules 6 german | sed 's/-d [0-9a-f:./]*//' | grep -c .)
	assert_eq "rule count" "$_a" "$_b"
}

test_blocked_state_only_allows_tailnet_destinations() {
	for f in 4 6; do
		_r=$(_rules $f blocked)
		case $_r in *"-i br-lan -o tailscale0 -j RETURN"*) fail "v$f blocked state allows all via tailscale0" ;; esac
	done
}

test_open_state_is_only_return_and_marked() {
	for f in 4 6; do
		_r=$(_rules $f open)
		assert_contains open "tsem:open" "$_r"
		assert_contains ret "-j RETURN" "$_r"
		case $_r in *REJECT*) fail "open state must not reject" ;; esac
	done
}

test_every_state_flushes_before_filling() {
	for s in open german; do for f in 4 6; do
		_r=$(_rules $f $s)
		assert_eq "flush first v$f $s" '-F TSEM_FWD' "$(printf '%s\n' "$_r" | sed -n 3p)"
	done; done
}

test_each_lan_iface_gets_its_own_reject() {
	_r=$( ( TSEM_LAN_IFACES="br-lan br-guest"; export TSEM_LAN_IFACES; _rules 6 german ) )
	assert_eq "reject count" 2 "$(printf '%s\n' "$_r" | grep -c -- '-j REJECT')"
}

_out() { ( . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load
	. "$TSEM_LIBDIR/backend_ipt.sh"; _g_out_rules "$1" "$2" ); }

test_out_chain_never_accepts_or_trusts_conntrack() {
	for f in 4 6; do for s in german blocked; do
		_r=$(_out $f $s)
		case $_r in *'-j ACCEPT'*) fail "v$f $s: ACCEPT in the router OUTPUT chain" ;; esac
		case $_r in *ESTABLISHED*|*RELATED*) fail "v$f $s: conntrack shortcut in the router OUTPUT chain" ;; esac
		assert_contains reject "-m comment --comment tsem:$s -j REJECT" "$(printf '%s\n' "$_r" | grep -v '^COMMIT' | tail -1)"
		assert_eq "flush first v$f $s" '-F TSEM_OUT' "$(printf '%s\n' "$_r" | sed -n 3p)"
	done; done
}

test_out_chain_open_state_is_only_return() {
	for f in 4 6; do
		_r=$(_out $f open)
		assert_contains open 'tsem:open' "$_r"
		case $_r in *REJECT*) fail "open state must not reject" ;; esac
		assert_eq "rules" 1 "$(printf '%s\n' "$_r" | grep -c '^-A')"
	done
}

test_out_chain_exceptions_are_narrow_and_ordered() {
	_r=$(_out 4 blocked)
	assert_contains lo '-A TSEM_OUT -o lo -j RETURN' "$_r"
	assert_contains ts '-A TSEM_OUT -o tailscale0 -j RETURN' "$_r"
	assert_contains lan '-A TSEM_OUT -o br-lan -j RETURN' "$_r"
	assert_contains dhcp '--sport 68 --dport 67 -j RETURN' "$_r"
	assert_contains tcp 'multiport --dports 80,443 -j RETURN' "$_r"
	# marked DNS must be rejected BEFORE the generic marked-udp RETURN
	_d=$(printf '%s\n' "$_r" | grep -n -- '--mark .* -p udp --dport 53 -j REJECT' | cut -d: -f1)
	_u=$(printf '%s\n' "$_r" | grep -n -- '--mark [^ ]* -p udp -j RETURN' | cut -d: -f1)
	[ -n "$_d" ] && [ -n "$_u" ] && [ "$_d" -lt "$_u" ] || fail "marked DNS reject must precede the marked udp RETURN ($_d/$_u)"
	# no rule may return generically for the mark (all marked RETURNs name a protocol)
	printf '%s\n' "$_r" | grep -- '--mark' | grep -- 'RETURN' | grep -qv -- '-p ' && fail "a marked RETURN without protocol restriction"
	# no unmarked rule may open dns or generic wan egress
	case $_r in *'-p udp --dport 53 -j RETURN'*|*'-p tcp --dport 53 -j RETURN'*) fail "DNS exception present" ;; esac
	assert_eq "no catch-all RETURN" 0 "$(printf '%s\n' "$_r" | grep -c -- '^-A TSEM_OUT -j RETURN')"
}

test_out_chain_v6_has_nd_and_dhcpv6_not_dhcpv4() {
	_r=$(_out 6 blocked)
	assert_contains dhcp6 '--sport 546 --dport 547 -j RETURN' "$_r"
	assert_contains ns '--icmpv6-type neighbour-solicitation -j RETURN' "$_r"
	assert_contains na '--icmpv6-type neighbour-advertisement -j RETURN' "$_r"
	assert_contains rs '--icmpv6-type router-solicitation -j RETURN' "$_r"
	case $_r in *'--sport 68'*) fail "dhcpv4 rule in the v6 chain" ;; esac
	case $_r in *'-p ipv6-icmp -j RETURN'*) fail "all icmpv6 allowed" ;; esac
}

test_out_ntp_and_underlay_dns_toggles() {
	_a=$( ( TSEM_ALLOW_NTP=0; export TSEM_ALLOW_NTP; _out 4 blocked ) )
	case $_a in *'--dport 123'*) fail "NTP exception present although disabled" ;; esac
	_b=$(_out 4 blocked)
	assert_contains ntp '-p udp --dport 123 -j RETURN' "$_b"
	_c=$( ( TSEM_ALLOW_UNDERLAY_DNS=1; export TSEM_ALLOW_UNDERLAY_DNS; _out 4 blocked ) )
	case $_c in *'--dport 53 -j REJECT'*) fail "underlay dns reject present although opted in" ;; esac
	assert_contains dns '--dport 53 -j REJECT' "$_b"
}

test_out_extra_local_ifaces() {
	_r=$( ( TSEM_OUT_LOCAL_IFACES="br-guest wgs0"; export TSEM_OUT_LOCAL_IFACES; _out 4 blocked ) )
	assert_contains guest '-A TSEM_OUT -o br-guest -j RETURN' "$_r"
	assert_contains wg '-A TSEM_OUT -o wgs0 -j RETURN' "$_r"
}

test_out_guard_off_makes_the_chain_open() {
	_w=$( ( TSEM_OUT_GUARD=off; export TSEM_OUT_GUARD; . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load
		. "$TSEM_LIBDIR/backend_ipt.sh"; _out_want german ) )
	assert_eq want open "$_w"
	_w=$( ( . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load
		. "$TSEM_LIBDIR/backend_ipt.sh"; _out_want german ) )
	assert_eq default german "$_w"
}

test_out_rules_pass_the_xtables_syntax_check() {
	# iptables-restore --test validates the text against the real xtables (IPv4 only).
	command -v iptables-restore >/dev/null 2>&1 || need_skip "iptables-restore missing"
	[ "$(id -u)" = 0 ] || need_skip "needs root"
	_o=$(_out 4 german | iptables-restore --test -n 2>&1) && _rc=0 || _rc=$?
	if [ "$_rc" -ne 0 ]; then
		case $_o in *ermission* | *"can't initialize"* | *"Table does not exist"* | *"Operation not supported"*) kernel_skip "netfilter not usable here: $_o" ;; esac
		fail "iptables-restore rejected the german OUTPUT rules: $_o"
	fi
	for s in open blocked; do
		_out 4 $s | iptables-restore --test -n >/dev/null 2>&1 || fail "iptables-restore rejected the $s OUTPUT rules"
	done
}

# ---- private tailscale subnets (remote-site) behind tailscale0; fw3 masquerading is NOT ours ----
_rules_conf() { ( TSEM_CONF=$1; export TSEM_CONF; . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load
	. "$TSEM_LIBDIR/backend_ipt.sh"; _g_fw_rules "$2" "$3" ); }

test_blocked_releases_exactly_the_configured_private_subnets() {
	printf 'TSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24"\n' >"$T/extnet.conf"
	_r=$(_rules_conf "$T/extnet.conf" 4 blocked)
	for n in 10.30.0.0/24 10.30.1.0/24 10.30.2.0/24; do
		assert_contains "rule $n" "-i br-lan -o tailscale0 -d $n -j RETURN" "$(printf '%s\n' "$_r" | sed 's/ -d \([^ ]*\) -i br-lan -o tailscale0/ -i br-lan -o tailscale0 -d \1/')"
	done
	assert_contains tailnet "100.64.0.0/10" "$_r"
	case $_r in *10.0.0.0/8*|*172.16.0.0/12*|*192.168.0.0/16*|*10.20.*|*0.0.0.0/0*) fail "no blanket RFC1918 / unlisted network may be released" ;; esac
	# the REJECT stays the last rule of the LAN iface
	assert_contains last '-j REJECT' "$(printf '%s\n' "$_r" | grep -v '^COMMIT' | tail -1)"
	# no conntrack shortcut, no ACCEPT
	case $_r in *ESTABLISHED*|*RELATED*|*'-j ACCEPT'*) fail "bypass in blocked rules" ;; esac
}

test_blocked_without_allow_config_releases_only_tailnet() {
	: >"$T/empty.conf"
	_r=$(_rules_conf "$T/empty.conf" 4 blocked)
	case $_r in *10.30.*) fail "nothing private may be released by default rules" ;; esac
}

test_german_passes_everything_via_tailscale0_independent_of_allow_list() {
	printf 'TSEM_ALLOW_SUBNETS4="10.30.0.0/24"\n' >"$T/a.conf"; : >"$T/b.conf"
	assert_eq "german does not depend on allow list" "$(_rules_conf "$T/b.conf" 4 german)" "$(_rules_conf "$T/a.conf" 4 german)"
	assert_contains all "-i br-lan -o tailscale0 -j RETURN" "$(_rules_conf "$T/a.conf" 4 german)"
}

test_shipped_config_is_neutral_and_releases_no_private_range_by_default() {
	# the public template carries no site-specific subnets and never a blanket RFC1918 release
	_l=$(grep '^TSEM_ALLOW_SUBNETS4=' "$ROOT/src/etc/tsem/tsem.conf")
	assert_eq shipped 'TSEM_ALLOW_SUBNETS4=""' "$_l"
	_r=$(_rules_conf "$ROOT/src/etc/tsem/tsem.conf" 4 blocked)
	case $_r in *10.0.0.0/8*|*172.16.0.0/12*|*192.168.0.0/16*) fail "blanket RFC1918 release in the shipped config" ;; esac
}

test_invalid_allow_subnet_is_rejected_not_released() {
	printf 'TSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.0.0.0/8;reboot"\n' >"$T/bad.conf"
	_r=$(_rules_conf "$T/bad.conf" 4 blocked 2>/dev/null) || true
	case $_r in *reboot*|*10.0.0.0/8*) fail "invalid entry must never reach the rules" ;; esac
}

test_admin_subnets_release_router_own_traffic_to_exactly_those_networks() {
	printf 'TSEM_ADMIN_SUBNETS4="10.50.0.0/24 192.168.9.0/28"
' >"$T/adm.conf"
	_r=$( ( TSEM_CONF=$T/adm.conf; export TSEM_CONF; . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"; _g_out_rules 4 german ) )
	assert_contains a "-A TSEM_OUT -d 10.50.0.0/24 -j RETURN" "$_r"
	assert_contains b "-A TSEM_OUT -d 192.168.9.0/28 -j RETURN" "$_r"
	# before the final REJECT, and no blanket network
	 assert_contains last "-j REJECT" "$(printf '%s
' "$_r" | grep -v '^COMMIT' | tail -1)"
	case $_r in *10.0.0.0/8*|*0.0.0.0/0*) fail "no blanket network may be released" ;; esac
	# default: nothing
	: >"$T/none.conf"
	_r=$( ( TSEM_CONF=$T/none.conf; export TSEM_CONF; . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"; _g_out_rules 4 german ) )
	case $_r in *" -d "*) fail "no destination exception by default" ;; esac
	# invalid entries are rejected
	printf 'TSEM_ADMIN_SUBNETS4="10.50.0.0/24 10.0.0.0/8;reboot"
' >"$T/admbad.conf"
	_r=$( ( TSEM_CONF=$T/admbad.conf; export TSEM_CONF; . "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"; _g_out_rules 4 german ) 2>/dev/null) || true
	case $_r in *reboot*|*10.0.0.0/8*) fail "invalid entry must never reach the rules" ;; esac
}

test_sources_never_touch_nat_postrouting_or_masquerade() {
	# fw3 owns SNAT (zone tailscale0 masq=1). tsem only has its own TSEM_DNS chain at PREROUTING.
	# The ONLY files that may touch the zone NAT are the separate tsem-masq component (tests/t_masq.sh covers it);
	# the kill-switch controller and everything else must not.
	_ex='--exclude=tsem-masq --exclude=masq-include.sh --exclude=51-tsem-masq'
	# shellcheck disable=SC2086
	! grep -rnE $_ex 'POSTROUTING|MASQUERADE|(^|[^A-Za-z])SNAT|option masq|masq_' "$ROOT/src" "$ROOT/install.sh" "$ROOT/uninstall.sh" | grep -v ':[0-9]*:[[:space:]]*#' | grep -q . \
		|| fail "tsem must not reference POSTROUTING/MASQUERADE/SNAT/masq options outside comments"
}
