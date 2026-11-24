# shellcheck shell=sh
# Failover state machine with hysteresis. fo_step is a pure function over
# global variables so it can be unit-tested without any backend.
#
# Variables (persisted in $TSEM_RUN_DIR/failover, tmpfs => reset on reboot):
#   FO_CUR      primary|secondary|none      selected exit node (none => BLOCKED)
#   FO_VER      1 once the selected node passed TSEM_UP_N egress checks
#   FO_OKP/FO_FAILP/FO_OKS/FO_FAILS   consecutive ok/fail counters per node
#   FO_LAST     time of last node switch
#   FO_DEADP/FO_DEADS   node not selectable before this time (backoff)
#   FO_BOP/FO_BOS       current backoff seconds per node
#   FO_DNS      ok|fail|skip   last DNS probe of the active node
#   FO_CHK      time of last completed probe round
#   FO_ERR      last apply error (empty = none)
#
# Signals (inputs to fo_step): SIG_P / SIG_S = 1 usable, 0 not usable, 2 no signal; usable means:
#   selected node  -> real internet egress through it works
#   other node     -> reachable (tailscale ping) and not in backoff
#
# Rules:
#  - a node counts as dead after TSEM_FAIL_N consecutive failures
#  - a node may be selected after TSEM_UP_N consecutive successes
#  - secondary -> primary needs TSEM_RETURN_N successes AND TSEM_DWELL seconds
#  - failover primary -> secondary is never delayed by DWELL
#  - a dead node is not selectable again before its backoff expires
#    (TSEM_BACKOFF_MIN doubling up to TSEM_BACKOFF_MAX)
#  - no usable node => none (BLOCKED); never "direct"
#  - TSEM_AUTO_RETURN=0: a secondary stays selected until it fails (no automatic return to the primary)
#  - failover=off: only the primary is ever used

fo_reset() {
	FO_CUR=none FO_VER=0 FO_OKP=0 FO_FAILP=0 FO_OKS=0 FO_FAILS=0 FO_LAST=0
	FO_DEADP=0 FO_DEADS=0 FO_BOP=$TSEM_BACKOFF_MIN FO_BOS=$TSEM_BACKOFF_MIN
	FO_DNS=skip FO_CHK=0 FO_ERR=''
	FO_CHANGED=0
	rm -f "$TSEM_RUN_DIR/failover"
}

_fo_cap() { [ "$1" -gt 100000 ] && echo 100000 || echo "$1"; }

_fo_selectable() { # node
	case $1 in
	primary)
		[ -n "$TSEM_PRIMARY" ] && [ "$FO_OKP" -ge "$TSEM_UP_N" ] && [ "$NOW" -ge "$FO_DEADP" ] ;;
	secondary)
		[ -n "$TSEM_SECONDARY" ] && [ "$FO_FAILOVER_MODE" = auto ] &&
			[ "$FO_OKS" -ge "$TSEM_UP_N" ] && [ "$NOW" -ge "$FO_DEADS" ] ;;
	*) return 1 ;;
	esac
}

_fo_kill() { # node: back off (doubling)
	case $1 in
	primary) FO_DEADP=$((NOW + FO_BOP)); FO_BOP=$((FO_BOP * 2)); [ "$FO_BOP" -le "$TSEM_BACKOFF_MAX" ] || FO_BOP=$TSEM_BACKOFF_MAX ;;
	secondary) FO_DEADS=$((NOW + FO_BOS)); FO_BOS=$((FO_BOS * 2)); [ "$FO_BOS" -le "$TSEM_BACKOFF_MAX" ] || FO_BOS=$TSEM_BACKOFF_MAX ;;
	esac
}

_fo_select() { # node|none: counters of the new node restart (egress must be proven)
	FO_CUR=$1 FO_VER=0 FO_LAST=$NOW FO_CHANGED=1
	case $1 in
	primary) FO_OKP=0 FO_FAILP=0 ;;
	secondary) FO_OKS=0 FO_FAILS=0 ;;
	esac
}

_fo_pick() { # choose best selectable node, preferred = primary
	if _fo_selectable primary; then _fo_select primary
	elif _fo_selectable secondary; then _fo_select secondary
	else _fo_select none; fi
}

# fo_step: input SIG_P SIG_S NOW FO_FAILOVER_MODE FORCE; updates FO_*; FO_CHANGED=1 on node/verify change
fo_step() {
	FO_CHANGED=0
	# SIG 2 = "no signal" (we could not apply the exit node ourselves): counters unchanged,
	# so our own apply errors never count as a node failure.
	case $SIG_P in
	1) FO_OKP=$(_fo_cap $((FO_OKP + 1))) FO_FAILP=0 ;;
	2) ;;
	*) FO_OKP=0 FO_FAILP=$(_fo_cap $((FO_FAILP + 1))) ;;
	esac
	case $SIG_S in
	1) FO_OKS=$(_fo_cap $((FO_OKS + 1))) FO_FAILS=0 ;;
	2) ;;
	*) FO_OKS=0 FO_FAILS=$(_fo_cap $((FO_FAILS + 1))) ;;
	esac

	_fs_c=$FO_CUR
	case $_fs_c in
	primary) _fs_ok=$FO_OKP _fs_fail=$FO_FAILP _fs_o=secondary ;;
	secondary) _fs_ok=$FO_OKS _fs_fail=$FO_FAILS _fs_o=primary ;;
	*) _fs_ok=0 _fs_fail=0 _fs_o='' ;;
	esac

	# manual failover: only if the other node is selectable (never self-inflict a block)
	if [ "${FORCE:-0}" = 1 ] && [ "$FO_VER" = 1 ] && [ -n "$_fs_o" ]; then
		if _fo_selectable "$_fs_o"; then
			case $_fs_c in
			primary) FO_DEADP=$((NOW + TSEM_BACKOFF_MIN)) ;;
			secondary) FO_DEADS=$((NOW + TSEM_BACKOFF_MIN)) ;;
			esac
			_fo_select "$_fs_o"
			return 0
		fi
		FO_FORCE_REFUSED=1
	fi

	case $_fs_c in
	none)
		_fo_pick
		;;
	primary | secondary)
		if [ "$FO_VER" = 0 ]; then
			if [ "$_fs_ok" -ge "$TSEM_UP_N" ]; then
				FO_VER=1 FO_CHANGED=1
				case $_fs_c in primary) FO_BOP=$TSEM_BACKOFF_MIN ;; secondary) FO_BOS=$TSEM_BACKOFF_MIN ;; esac
			elif [ "$_fs_fail" -ge "$TSEM_FAIL_N" ]; then
				_fo_kill "$_fs_c"
				_fo_pick
			fi
		else
			if [ "$_fs_fail" -ge "$TSEM_FAIL_N" ]; then
				_fo_kill "$_fs_c"
				_fo_pick
			elif [ "$_fs_c" = secondary ] && [ "$FO_FAILOVER_MODE" = auto ] &&
				[ "${TSEM_AUTO_RETURN:-1}" = 1 ] && [ "$FO_OKP" -ge "$TSEM_RETURN_N" ] && [ $((NOW - FO_LAST)) -ge "$TSEM_DWELL" ] &&
				[ "$NOW" -ge "$FO_DEADP" ] && [ -n "$TSEM_PRIMARY" ]; then
				_fo_select primary
			fi
		fi
		;;
	esac
	return 0
}

# fo_state_name MODE -> DISABLED|CONNECTING_PRIMARY|PRIMARY_ACTIVE|CONNECTING_SECONDARY|
#                       SECONDARY_ACTIVE|DEGRADED|BLOCKED|ERROR
fo_state_name() {
	if [ "$1" = direct ]; then
		if [ -n "$FO_ERR" ]; then echo ERROR; else echo DISABLED; fi
		return
	fi
	[ -z "$FO_ERR" ] || { echo ERROR; return; }
	if [ "$1" = blocked ]; then echo BLOCKED; return; fi # explicit BLOCKED intent: no exit node, no failover
	case $FO_CUR in
	primary) _fn_n=PRIMARY ;;
	secondary) _fn_n=SECONDARY ;;
	*) echo BLOCKED; return ;;
	esac
	if [ "$FO_VER" != 1 ]; then echo "CONNECTING_$_fn_n"; return; fi
	_fn_f=$FO_FAILP
	[ "$FO_CUR" = secondary ] && _fn_f=$FO_FAILS
	if [ "$_fn_f" -gt 0 ] || [ "$FO_DNS" = fail ]; then echo DEGRADED; return; fi
	echo "${_fn_n}_ACTIVE"
}

# fo_guard_for STATE -> open|german|blocked   (the ONLY place that maps state to guard)
fo_guard_for() {
	case $1 in
	DISABLED) echo open ;;
	PRIMARY_ACTIVE | SECONDARY_ACTIVE | DEGRADED) echo german ;;
	*) echo blocked ;;
	esac
}

fo_load() {
	FO_CUR=none FO_VER=0 FO_OKP=0 FO_FAILP=0 FO_OKS=0 FO_FAILS=0 FO_LAST=0
	FO_DEADP=0 FO_DEADS=0 FO_BOP=$TSEM_BACKOFF_MIN FO_BOS=$TSEM_BACKOFF_MIN
	FO_DNS=skip FO_CHK=0 FO_ERR='' FO_PS=unknown FO_SS=unknown FO_PK=unknown FO_SK=unknown FO_CHANGED=0
	_fl_f=$TSEM_RUN_DIR/failover
	[ -f "$_fl_f" ] || return 0
	while IFS='=' read -r _fl_k _fl_v; do
		case $_fl_k in
		cur) case $_fl_v in primary | secondary | none) FO_CUR=$_fl_v ;; esac ;;
		ver) case $_fl_v in 0 | 1) FO_VER=$_fl_v ;; esac ;;
		okp) is_uint "$_fl_v" && FO_OKP=$_fl_v ;;
		failp) is_uint "$_fl_v" && FO_FAILP=$_fl_v ;;
		oks) is_uint "$_fl_v" && FO_OKS=$_fl_v ;;
		fails) is_uint "$_fl_v" && FO_FAILS=$_fl_v ;;
		last) is_epoch "$_fl_v" && FO_LAST=$_fl_v ;;
		deadp) is_epoch "$_fl_v" && FO_DEADP=$_fl_v ;;
		deads) is_epoch "$_fl_v" && FO_DEADS=$_fl_v ;;
		bop) is_uint "$_fl_v" && FO_BOP=$_fl_v ;;
		bos) is_uint "$_fl_v" && FO_BOS=$_fl_v ;;
		dns) case $_fl_v in ok | fail | skip) FO_DNS=$_fl_v ;; esac ;;
		chk) is_epoch "$_fl_v" && FO_CHK=$_fl_v ;;
		ps) case $_fl_v in ok | fail | unknown) FO_PS=$_fl_v ;; esac ;;
		ss) case $_fl_v in ok | fail | unknown) FO_SS=$_fl_v ;; esac ;;
		pk) case $_fl_v in egress | egress-fail | reach | unreachable | rejected | pending | unknown) FO_PK=$_fl_v ;; esac ;;
		sk) case $_fl_v in egress | egress-fail | reach | unreachable | rejected | pending | unknown) FO_SK=$_fl_v ;; esac ;;
		err) FO_ERR=$(printf '%s' "$_fl_v" | tr -cd 'A-Za-z0-9 ._:-' | cut -c1-80) ;;
		esac
	done <"$_fl_f"
	# a verified flag without a node is impossible; fail closed
	[ "$FO_CUR" != none ] || FO_VER=0
	return 0
}

fo_save() {
	mkdir -p "$TSEM_RUN_DIR" || return 1
	printf 'cur=%s\nver=%s\nokp=%s\nfailp=%s\noks=%s\nfails=%s\nlast=%s\ndeadp=%s\ndeads=%s\nbop=%s\nbos=%s\ndns=%s\nchk=%s\nps=%s\nss=%s\npk=%s\nsk=%s\nerr=%s\n' \
		"$FO_CUR" "$FO_VER" "$FO_OKP" "$FO_FAILP" "$FO_OKS" "$FO_FAILS" "$FO_LAST" "$FO_DEADP" "$FO_DEADS" \
		"$FO_BOP" "$FO_BOS" "$FO_DNS" "$FO_CHK" "${FO_PS:-unknown}" "${FO_SS:-unknown}" "${FO_PK:-unknown}" "${FO_SK:-unknown}" "$FO_ERR" \
		>"$TSEM_RUN_DIR/failover.tmp" && mv -f "$TSEM_RUN_DIR/failover.tmp" "$TSEM_RUN_DIR/failover"
}
