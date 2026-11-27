# shellcheck shell=sh
# Configuration loader. The config file is NEVER sourced: it is parsed line by
# line, only whitelisted keys are accepted, every value is validated, and the
# value is assigned without eval-interpolation. Environment variables set
# before the call win over the file (used by tests).

_cf_defaults() {
	: "${TSEM_PRIMARY:=}"
	: "${TSEM_SECONDARY:=}"
	: "${TSEM_NODES:=}"
	: "${TSEM_NODE_NAMES:=}"
	: "${TSEM_LAN_IFACES:=br-lan}"
	: "${TSEM_ALLOW_OUT_IFACES:=}"
	: "${TSEM_TS_IFACE:=tailscale0}"
	: "${TSEM_TS_TABLE:=52}"
	: "${TSEM_RT_GUARD:=on}"
	: "${TSEM_RULE_PRIO:=5280}"
	: "${TSEM_RT_DENY:=auto}"
	: "${TSEM_FASTPATH:=unload}"
	: "${TSEM_TAILNET4:=100.64.0.0/10}"
	: "${TSEM_TAILNET6:=fd7a:115c:a1e0::/48}"
	: "${TSEM_ALLOW_SUBNETS4:=}"
	: "${TSEM_ALLOW_SUBNETS6:=}"
	: "${TSEM_ADMIN_SUBNETS4:=}"
	: "${TSEM_ADMIN_SUBNETS6:=}"
	: "${TSEM_DNS_REDIRECT:=}"
	: "${TSEM_DNS_ROUTER:=1.1.1.1}"
	: "${TSEM_DNS_UPSTREAM:=auto}"
	: "${TSEM_OUT_GUARD:=on}"
	: "${TSEM_OUT_LOCAL_IFACES:=}"
	: "${TSEM_ALLOW_NTP:=1}"
	: "${TSEM_ALLOW_UNDERLAY_DNS:=0}"
	: "${TSEM_UNDERLAY_MARK:=0x80000/0xff0000}"
	: "${TSEM_PRIMARY_NAME:=}"
	: "${TSEM_SECONDARY_NAME:=}"
	: "${TSEM_MODE_LABEL:=EXIT}"
	: "${TSEM_INTERVAL:=5}"
	: "${TSEM_INTERVAL_RECOVERY:=15}"
	: "${TSEM_INTERVAL_STEADY:=20}"
	: "${TSEM_INTERVAL_IDLE:=60}"
	: "${TSEM_FAIL_N:=3}"
	: "${TSEM_UP_N:=2}"
	: "${TSEM_RETURN_N:=6}"
	: "${TSEM_DWELL:=60}"
	: "${TSEM_AUTO_RETURN:=1}"
	: "${TSEM_HW_AT_BOOT:=last}"
	: "${TSEM_BACKOFF_MIN:=30}"
	: "${TSEM_BACKOFF_MAX:=300}"
	: "${TSEM_LOCK_TIMEOUT:=10}"
	: "${TSEM_SET_TICKS:=1}"
	: "${TSEM_SET_TICK_DELAY:=2}"
	: "${TSEM_PROBE_URLS:=https://1.1.1.1/cdn-cgi/trace https://9.9.9.9/}"
	: "${TSEM_PROBE_TIMEOUT:=5}"
	: "${TSEM_PROBE_CMD:=}"
	: "${TSEM_DNS_PROBE_HOST:=}"
	: "${TSEM_HW_STATE_FILE:=}"
	: "${TSEM_HW_GPIO_VALUE:=}"
	: "${TSEM_HW_GPIO_ON:=1}"
}

_cf_bad() { log "config: invalid value for $1 (ignored)"; return 0; }

# _cf_set KEY VALUE  (KEY is already whitelisted by the caller)
_cf_set() {
	case " $_cf_envkeys " in *" $1 "*) return 0 ;; esac # environment wins
	eval "$1=\$2"
}

_cf_check_list() { # type value
	for _cl in $2; do
		case $1 in
		iface) valid_iface "$_cl" || return 1 ;;
		cidr4) valid_cidr4 "$_cl" || return 1 ;;
		cidr6) valid_cidr6 "$_cl" || return 1 ;;
		esac
	done
	return 0
}

# The exit nodes are an ORDERED LIST (rank 1 = preferred). TSEM_NODES holds the addresses, TSEM_NODE_NAMES the names ("-" = none).
# TSEM_PRIMARY / TSEM_SECONDARY (and their names) are the older form of rank 1 and 2: they are read when TSEM_NODES is empty and
# are kept equal to rank 1 and 2 afterwards, so older tools keep working.
TSEM_MAX_NODES=8

_cf_check_nodes() { # at most TSEM_MAX_NODES valid, distinct IPv4 addresses
	_cn_n=0 _cn_seen=' '
	for _cn in $1; do
		valid_ip4 "$_cn" || return 1
		case $_cn_seen in *" $_cn "*) return 1 ;; esac
		_cn_seen="$_cn_seen$_cn "
		_cn_n=$((_cn_n + 1))
	done
	[ "$_cn_n" -le "$TSEM_MAX_NODES" ]
}

_cf_check_names() { # each name: letters, digits, dot, hyphen (max 63) or "-" for none
	for _cn in $1; do
		[ "$_cn" = - ] && continue
		case $_cn in *[!A-Za-z0-9.-]* | -* | .*) return 1 ;; esac
		[ "${#_cn}" -le 63 ] || return 1
	done
	return 0
}

node_ip() { # RANK -> address (empty if there is none)
	_nip=$1
	set -- $TSEM_NODES
	eval "printf '%s' \"\${$_nip:-}\""
}

node_name() { # RANK -> name (empty if there is none)
	_nnm=$1
	set -- $TSEM_NODE_NAMES
	_nnv=
	eval "_nnv=\${$_nnm:-}"
	[ "$_nnv" = - ] || printf '%s' "$_nnv"
}

node_rank() { # ADDRESS -> rank (0 = not configured)
	_nrk=0 _nri=0
	for _nr in $TSEM_NODES; do _nri=$((_nri + 1)); [ "$_nr" != "$1" ] || { _nrk=$_nri; break; }; done
	echo "$_nrk"
}

# derive the effective list and keep the older keys equal to rank 1 and 2
_cf_nodes() {
	case " $_cf_envkeys " in
	*" TSEM_PRIMARY "*) [ -n "$TSEM_NODES" ] && case " $_cf_envkeys " in *" TSEM_NODES "*) ;; *) TSEM_NODES='' TSEM_NODE_NAMES='' ;; esac ;;
	esac
	if [ -z "$TSEM_NODES" ]; then
		TSEM_NODES=$TSEM_PRIMARY
		[ -z "$TSEM_PRIMARY" ] || [ -z "$TSEM_SECONDARY" ] || [ "$TSEM_SECONDARY" = "$TSEM_PRIMARY" ] || TSEM_NODES="$TSEM_NODES $TSEM_SECONDARY"
		TSEM_NODE_NAMES=''
		if [ -n "$TSEM_PRIMARY_NAME$TSEM_SECONDARY_NAME" ]; then
			TSEM_NODE_NAMES="${TSEM_PRIMARY_NAME:--}"
			case " $TSEM_NODES " in *" $TSEM_SECONDARY "*) [ -z "$TSEM_SECONDARY" ] || [ -z "$TSEM_PRIMARY" ] || TSEM_NODE_NAMES="$TSEM_NODE_NAMES ${TSEM_SECONDARY_NAME:--}" ;; esac
		fi
	else
		TSEM_PRIMARY=$(node_ip 1)
		TSEM_SECONDARY=$(node_ip 2)
		TSEM_PRIMARY_NAME=$(node_name 1)
		TSEM_SECONDARY_NAME=$(node_name 2)
	fi
	set -- $TSEM_NODES
	TSEM_NODE_COUNT=$#
}

_CF_KEYS="TSEM_NODES TSEM_NODE_NAMES TSEM_PRIMARY TSEM_SECONDARY TSEM_LAN_IFACES TSEM_ALLOW_OUT_IFACES TSEM_TS_IFACE TSEM_TS_TABLE
TSEM_RT_GUARD TSEM_RULE_PRIO TSEM_RT_DENY TSEM_FASTPATH TSEM_TAILNET4 TSEM_TAILNET6 TSEM_ALLOW_SUBNETS4 TSEM_ALLOW_SUBNETS6 TSEM_ADMIN_SUBNETS4 TSEM_ADMIN_SUBNETS6 TSEM_DNS_REDIRECT TSEM_DNS_ROUTER TSEM_DNS_UPSTREAM TSEM_OUT_GUARD TSEM_OUT_LOCAL_IFACES TSEM_ALLOW_NTP TSEM_ALLOW_UNDERLAY_DNS TSEM_UNDERLAY_MARK
TSEM_PRIMARY_NAME TSEM_SECONDARY_NAME TSEM_INTERVAL TSEM_INTERVAL_RECOVERY TSEM_INTERVAL_STEADY TSEM_INTERVAL_IDLE TSEM_FAIL_N TSEM_UP_N TSEM_RETURN_N TSEM_DWELL TSEM_AUTO_RETURN TSEM_BACKOFF_MIN TSEM_BACKOFF_MAX TSEM_LOCK_TIMEOUT
TSEM_SET_TICKS TSEM_SET_TICK_DELAY TSEM_PROBE_URLS TSEM_PROBE_TIMEOUT TSEM_PROBE_CMD TSEM_DNS_PROBE_HOST TSEM_HW_STATE_FILE TSEM_HW_GPIO_VALUE TSEM_HW_GPIO_ON TSEM_MODE_LABEL TSEM_HW_AT_BOOT"

conf_load() {
	_cf_envkeys=''
	for _ck in $_CF_KEYS; do
		eval "[ -z \"\${$_ck+x}\" ]" || _cf_envkeys="$_cf_envkeys $_ck"
	done
	if [ -r "$TSEM_CONF" ]; then
		while IFS= read -r _cf_line || [ -n "$_cf_line" ]; do
			case $_cf_line in '' | '#'* | ' '* | '	'*) continue ;; esac
			_cf_k=${_cf_line%%=*}
			_cf_v=${_cf_line#*=}
			case $_cf_v in
			\"*\") _cf_v=${_cf_v#\"}; _cf_v=${_cf_v%\"} ;;
			\'*\') _cf_v=${_cf_v#\'}; _cf_v=${_cf_v%\'} ;;
			esac
			case $_cf_v in *'$'* | *'`'* | *';'* | *'|'* | *'&'* | *'<'* | *'>'* | *'('* | *')'*)
				_cf_bad "$_cf_k"
				continue
				;;
			esac
			case $_cf_k in
			TSEM_PRIMARY | TSEM_SECONDARY)
				if [ -z "$_cf_v" ] || valid_ip4 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_LAN_IFACES | TSEM_ALLOW_OUT_IFACES | TSEM_OUT_LOCAL_IFACES)
				if _cf_check_list iface "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_TS_IFACE)
				if valid_iface "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_NODES)
				if _cf_check_nodes "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_NODE_NAMES)
				if _cf_check_names "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_PRIMARY_NAME | TSEM_SECONDARY_NAME)
				case $_cf_v in '' | *[!A-Za-z0-9.-]* | -* | .*) if [ -z "$_cf_v" ]; then _cf_set "$_cf_k" ""; else _cf_bad "$_cf_k"; fi ;; *)
					if [ "${#_cf_v}" -le 63 ]; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;; esac ;;
			TSEM_TS_TABLE | TSEM_RULE_PRIO | TSEM_INTERVAL | TSEM_INTERVAL_RECOVERY | TSEM_INTERVAL_STEADY | TSEM_INTERVAL_IDLE | TSEM_FAIL_N | TSEM_UP_N | TSEM_RETURN_N | \
				TSEM_DWELL | TSEM_BACKOFF_MIN | TSEM_BACKOFF_MAX | TSEM_LOCK_TIMEOUT | TSEM_SET_TICKS | \
				TSEM_SET_TICK_DELAY | TSEM_PROBE_TIMEOUT)
				if is_uint "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_MODE_LABEL)
				case $_cf_v in '' | *[!A-Za-z0-9' '_-]*) _cf_bad "$_cf_k" ;; *) if [ "${#_cf_v}" -le 20 ]; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;; esac ;;
			TSEM_HW_AT_BOOT)
				case $_cf_v in last | switch) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_OUT_GUARD)
				case $_cf_v in on | off) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_HW_GPIO_ON)
				case $_cf_v in 0 | 1) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_ALLOW_NTP | TSEM_ALLOW_UNDERLAY_DNS | TSEM_AUTO_RETURN)
				case $_cf_v in 0 | 1) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_UNDERLAY_MARK)
				case $_cf_v in 0x[0-9a-fA-F]*/0x[0-9a-fA-F]* ) case $_cf_v in *[!0-9a-fA-Fx/]*) _cf_bad "$_cf_k" ;; *) _cf_set "$_cf_k" "$_cf_v" ;; esac ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_RT_GUARD)
				case $_cf_v in on | off) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_RT_DENY)
				case $_cf_v in auto | prohibit | unreachable | blackhole) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_FASTPATH)
				case $_cf_v in unload | refuse) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_TAILNET4)
				if valid_cidr4 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_TAILNET6)
				if valid_cidr6 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_ALLOW_SUBNETS4)
				if _cf_check_list cidr4 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_ALLOW_SUBNETS6)
				if _cf_check_list cidr6 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_ADMIN_SUBNETS4)
				if _cf_check_list cidr4 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_ADMIN_SUBNETS6)
				if _cf_check_list cidr6 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_DNS_REDIRECT | TSEM_DNS_ROUTER)
				if [ -z "$_cf_v" ] || valid_ip4 "$_cf_v"; then _cf_set "$_cf_k" "$_cf_v"; else _cf_bad "$_cf_k"; fi ;;
			TSEM_DNS_UPSTREAM)
				case $_cf_v in auto | on | off) _cf_set "$_cf_k" "$_cf_v" ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_PROBE_URLS)
				case $_cf_v in *[!A-Za-z0-9./:_?=\ -]*) _cf_bad "$_cf_k" ;; *) _cf_set "$_cf_k" "$_cf_v" ;; esac ;;
			TSEM_PROBE_CMD | TSEM_HW_STATE_FILE | TSEM_HW_GPIO_VALUE)
				case $_cf_v in '' | /*) case $_cf_v in *[!A-Za-z0-9./_-]*) _cf_bad "$_cf_k" ;; *) _cf_set "$_cf_k" "$_cf_v" ;; esac ;; *) _cf_bad "$_cf_k" ;; esac ;;
			TSEM_DNS_PROBE_HOST)
				case $_cf_v in *[!A-Za-z0-9.-]*) _cf_bad "$_cf_k" ;; *) _cf_set "$_cf_k" "$_cf_v" ;; esac ;;
			*) log "config: unknown key '$(safe_word "$_cf_k")' (ignored)" ;;
			esac
		done <"$TSEM_CONF"
	fi
	_cf_defaults
	_cf_nodes
	# sanity: counters must be >= 1, timing relations
	[ "$TSEM_FAIL_N" -ge 1 ] || TSEM_FAIL_N=3
	[ "$TSEM_UP_N" -ge 1 ] || TSEM_UP_N=2
	[ "$TSEM_RETURN_N" -ge "$TSEM_UP_N" ] || TSEM_RETURN_N=$TSEM_UP_N
	[ "$TSEM_BACKOFF_MAX" -ge "$TSEM_BACKOFF_MIN" ] || TSEM_BACKOFF_MAX=$TSEM_BACKOFF_MIN
	[ "$TSEM_INTERVAL" -ge 1 ] || TSEM_INTERVAL=5
	# slower intervals may never be faster than the fast one
	[ "$TSEM_INTERVAL_RECOVERY" -ge "$TSEM_INTERVAL" ] || TSEM_INTERVAL_RECOVERY=$TSEM_INTERVAL
	[ "$TSEM_INTERVAL_STEADY" -ge "$TSEM_INTERVAL" ] || TSEM_INTERVAL_STEADY=$TSEM_INTERVAL
	[ "$TSEM_INTERVAL_IDLE" -ge "$TSEM_INTERVAL" ] || TSEM_INTERVAL_IDLE=$TSEM_INTERVAL
	return 0
}
