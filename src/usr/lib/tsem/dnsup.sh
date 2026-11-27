# shellcheck shell=sh
# The router's own resolver (dnsmasq) while a protected mode is active.
#
# Problem (found on real hardware, v1.2): when dnsmasq forwards to a PRIVATE upstream resolver that sits behind the uplink (a travel router
# behind another router: nameserver 10.x.x.x), the F03 redirect (TSEM_DNS_OUT) cannot help. dnsmasq binds its upstream sockets to the uplink
# interface (bind-dynamic), the rewritten packet keeps that interface, and the kill switch correctly rejects it there. Names do not resolve
# in the exit mode (REFUSED), for the router and for every device that uses its resolver.
#
# Fix: while a protected mode is active, dnsmasq gets one more small config file in its temporary config directory (RAM, gone after a reboot)
# that names TSEM_DNS_ROUTER, a resolver that is reachable through the exit node, as its upstream. DIRECT removes the file again. Nothing
# in /etc is touched, so a firmware upgrade or a crash can never leave a changed resolver behind. Fail-closed rules are not involved:
# this only helps names resolve, it never opens anything.
#
# TSEM_DNS_UPSTREAM: auto (default: only when an upstream resolver is private and not reachable through the LAN or the tailnet),
#                    on (always while protected), off (never).

_dnsup_file() { echo "${TSEM_DNSMASQ_DIR:-/tmp/dnsmasq.d}/tsem-dns.conf"; }

_dnsup_private() { # IPv4 address -> 0 if it is a private (RFC 1918) address
	case $1 in 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;; esac
	return 1
}

# 0 if one upstream resolver of the router is private and its route does not lead into the LAN, the tailnet or the host itself.
# An unknown route counts as "needed": a private resolver we cannot reach locally is exactly the case that fails.
_dnsup_needed() {
	for _du_f in ${TSEM_RESOLV_FILES:-/tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf.auto}; do
		[ -r "$_du_f" ] || continue
		for _du_ns in $(sed -n 's/^nameserver[[:space:]][[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$_du_f" 2>/dev/null); do
			_dnsup_private "$_du_ns" || continue
			_du_d=$("${TSEM_IP:-ip}" route get "$_du_ns" 2>/dev/null | sed -n '1s/.* dev \([^ ]*\).*/\1/p')
			[ -n "$_du_d" ] || return 0
			case " $TSEM_LAN_IFACES $TSEM_TS_IFACE lo " in *" $_du_d "*) continue ;; esac
			return 0
		done
	done
	return 1
}

# dnsup_sync STATE   (open|german|blocked): makes the file match the state. Idempotent; restarts dnsmasq only when the file changed,
# detached, so a mode change never waits for it. Never fails: a missing dnsmasq or directory simply means there is nothing to do.
dnsup_sync() {
	_ds_dir=${TSEM_DNSMASQ_DIR:-/tmp/dnsmasq.d}
	_ds_file=$(_dnsup_file)
	_ds_want=0
	if [ "$1" != open ] && [ -n "$TSEM_DNS_ROUTER" ]; then
		case ${TSEM_DNS_UPSTREAM:-auto} in
		on) _ds_want=1 ;;
		off) ;;
		*) _dnsup_needed && _ds_want=1 ;;
		esac
	fi
	if [ "$_ds_want" = 1 ]; then
		[ -d "$_ds_dir" ] || return 0
		_ds_body="# managed by tsem: the exit mode is active, the upstream must be reachable through the exit node
no-resolv
server=$TSEM_DNS_ROUTER"
		[ "$(cat "$_ds_file" 2>/dev/null)" != "$_ds_body" ] || return 0
		printf '%s\n' "$_ds_body" >"$_ds_file.new" 2>/dev/null && mv -f "$_ds_file.new" "$_ds_file" 2>/dev/null || { rm -f "$_ds_file.new" 2>/dev/null; return 0; }
		log "dnsmasq: upstream $TSEM_DNS_ROUTER while protected (a private upstream is not reachable through the exit node)"
	else
		[ -e "$_ds_file" ] || return 0
		rm -f "$_ds_file" 2>/dev/null
		log "dnsmasq: own upstream removed"
	fi
	# shellcheck disable=SC2086
	( ${TSEM_DNSMASQ_RESTART:-/etc/init.d/dnsmasq restart} >/dev/null 2>&1 9>&- </dev/null & )
	return 0
}

# dnsup_tick MODE: called by the controller's tick. DIRECT only checks that the file is gone (cheap); a protected mode re-evaluates at most
# every 30 s, so a new uplink (other upstream resolver) or a dnsmasq that started after tsem at boot is picked up without extra load.
dnsup_tick() {
	case $1 in
	direct) dnsup_sync open; return 0 ;;
	esac
	_dt_n=$(now)
	_dt_l=''; read -r _dt_l <"$TSEM_RUN_DIR/dnsup" 2>/dev/null || _dt_l=''
	if is_epoch "$_dt_l" && is_epoch "$_dt_n" && [ "$_dt_n" -ge "$_dt_l" ] && [ $((_dt_n - _dt_l)) -lt 30 ]; then return 0; fi
	is_epoch "$_dt_n" && printf '%s\n' "$_dt_n" >"$TSEM_RUN_DIR/dnsup" 2>/dev/null
	dnsup_sync german
	return 0
}
