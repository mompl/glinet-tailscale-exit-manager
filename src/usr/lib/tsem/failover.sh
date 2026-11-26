# shellcheck shell=sh
# Failover state machine with hysteresis. fo_step is a pure function over
# global variables so it can be unit-tested without any backend.
#
# The exit nodes are an ORDERED LIST: rank 1 is preferred, the others are fallbacks in order (see TSEM_NODES). Per rank i:
#   FO_OK_i/FO_FAIL_i   consecutive ok/fail counters      FO_DEAD_i   not selectable before this time (backoff)
#   FO_BO_i             current backoff seconds           FO_PS_i / FO_PK_i   last verdict and what it rests on (for status)
# Global (persisted in $TSEM_RUN_DIR/failover, tmpfs => reset on reboot):
#   FO_CUR      rank (1..TSEM_MAX_NODES) or none      selected exit node (none => BLOCKED)
#   FO_VER      1 once the selected node passed TSEM_UP_N egress checks
#   FO_LAST     time of last node switch
#   FO_DNS      ok|fail|skip   last DNS probe of the active node
#   FO_CHK      time of last completed probe round
#   FO_ERR      last apply error (empty = none)
#
# Signals (inputs to fo_step): SIG_<rank> = 1 usable, 0 not usable, 2 no signal; usable means:
#   selected node  -> real internet egress through it works
#   other node     -> reachable (tailscale ping) and not in backoff
#
# Rules:
#  - a node counts as dead after TSEM_FAIL_N consecutive failures
#  - a node may be selected after TSEM_UP_N consecutive successes
#  - the lowest rank that is selectable is chosen (rank 1 first)
#  - a fallback -> a better rank needs TSEM_RETURN_N successes of that rank AND TSEM_DWELL seconds
#  - failover to a lower rank is never delayed by DWELL
#  - a dead node is not selectable again before its backoff expires
#    (TSEM_BACKOFF_MIN doubling up to TSEM_BACKOFF_MAX)
#  - no usable node => none (BLOCKED); never "direct"
#  - TSEM_AUTO_RETURN=0: a fallback stays selected until it fails (no automatic return to a better rank)
#  - failover=off: only rank 1 is ever used

# shared getters/setters for the per-rank variables (rank numbers are validated digits, never user text)
_fo_v() { eval "printf '%s' \"\${$1_$2:-0}\""; } # NAME RANK
_fo_set() { eval "$1_$2=\$3"; }                  # NAME RANK VALUE
_fo_n() { printf '%s' "${TSEM_NODE_COUNT:-0}"; }

fo_reset() {
	fo_reset_vars
	rm -f "$TSEM_RUN_DIR/failover"
}

_fo_cap() { [ "$1" -gt 100000 ] && echo 100000 || echo "$1"; }

_fo_selectable() { # rank
	[ -n "$(node_ip "$1")" ] || return 1
	[ "$1" -eq 1 ] || [ "$FO_FAILOVER_MODE" = auto ] || return 1
	[ "$(_fo_v FO_OK "$1")" -ge "$TSEM_UP_N" ] && [ "$NOW" -ge "$(_fo_v FO_DEAD "$1")" ]
}

_fo_kill() { # rank: back off (doubling)
	_fk_b=$(_fo_v FO_BO "$1")
	_fo_set FO_DEAD "$1" $((NOW + _fk_b))
	_fk_b=$((_fk_b * 2))
	[ "$_fk_b" -le "$TSEM_BACKOFF_MAX" ] || _fk_b=$TSEM_BACKOFF_MAX
	_fo_set FO_BO "$1" "$_fk_b"
}

_fo_select() { # rank|none: counters of the new node restart (egress must be proven)
	FO_CUR=$1 FO_VER=0 FO_LAST=$NOW FO_CHANGED=1
	case $1 in none) ;; *) _fo_set FO_OK "$1" 0; _fo_set FO_FAIL "$1" 0 ;; esac
}

_fo_pick() { # choose the best selectable node (lowest rank)
	_fp_i=1 _fp_n=$(_fo_n)
	while [ "$_fp_i" -le "$_fp_n" ]; do
		if _fo_selectable "$_fp_i"; then _fo_select "$_fp_i"; return 0; fi
		_fp_i=$((_fp_i + 1))
	done
	_fo_select none
}

# fo_step: input SIG_<rank> NOW FO_FAILOVER_MODE FORCE; updates FO_*; FO_CHANGED=1 on node/verify change
fo_step() {
	FO_CHANGED=0
	_fs_n=$(_fo_n)
	# SIG 2 = "no signal" (we could not apply the exit node ourselves): counters unchanged,
	# so our own apply errors never count as a node failure.
	_fs_i=1
	while [ "$_fs_i" -le "$_fs_n" ]; do
		_fs_sig=0
		eval "_fs_sig=\${SIG_$_fs_i:-0}"
		case $_fs_sig in
		1) _fo_set FO_OK "$_fs_i" "$(_fo_cap $(($(_fo_v FO_OK "$_fs_i") + 1)))"; _fo_set FO_FAIL "$_fs_i" 0 ;;
		2) ;;
		*) _fo_set FO_OK "$_fs_i" 0; _fo_set FO_FAIL "$_fs_i" "$(_fo_cap $(($(_fo_v FO_FAIL "$_fs_i") + 1)))" ;;
		esac
		_fs_i=$((_fs_i + 1))
	done

	_fs_c=$FO_CUR
	case $_fs_c in
	none | '') _fs_c=none _fs_ok=0 _fs_fail=0 ;;
	*) _fs_ok=$(_fo_v FO_OK "$_fs_c") _fs_fail=$(_fo_v FO_FAIL "$_fs_c") ;;
	esac

	# manual failover: only to another node that is selectable (never self-inflict a block)
	if [ "${FORCE:-0}" = 1 ] && [ "$FO_VER" = 1 ] && [ "$_fs_c" != none ]; then
		_fs_i=1
		while [ "$_fs_i" -le "$_fs_n" ]; do
			if [ "$_fs_i" != "$_fs_c" ] && _fo_selectable "$_fs_i"; then
				_fo_set FO_DEAD "$_fs_c" $((NOW + TSEM_BACKOFF_MIN))
				_fo_select "$_fs_i"
				return 0
			fi
			_fs_i=$((_fs_i + 1))
		done
		FO_FORCE_REFUSED=1
	fi

	case $_fs_c in
	none)
		_fo_pick
		;;
	*)
		if [ "$FO_VER" = 0 ]; then
			if [ "$_fs_ok" -ge "$TSEM_UP_N" ]; then
				FO_VER=1 FO_CHANGED=1
				_fo_set FO_BO "$_fs_c" "$TSEM_BACKOFF_MIN"
			elif [ "$_fs_fail" -ge "$TSEM_FAIL_N" ]; then
				_fo_kill "$_fs_c"
				_fo_pick
			fi
		else
			if [ "$_fs_fail" -ge "$TSEM_FAIL_N" ]; then
				_fo_kill "$_fs_c"
				_fo_pick
			elif [ "$_fs_c" -gt 1 ] && [ "$FO_FAILOVER_MODE" = auto ] && [ "${TSEM_AUTO_RETURN:-1}" = 1 ] &&
				[ $((NOW - FO_LAST)) -ge "$TSEM_DWELL" ]; then
				# back to the best rank that has been healthy long enough (lowest rank wins)
				_fs_i=1
				while [ "$_fs_i" -lt "$_fs_c" ]; do
					if [ -n "$(node_ip "$_fs_i")" ] && [ "$(_fo_v FO_OK "$_fs_i")" -ge "$TSEM_RETURN_N" ] && [ "$NOW" -ge "$(_fo_v FO_DEAD "$_fs_i")" ]; then
						_fo_select "$_fs_i"
						break
					fi
					_fs_i=$((_fs_i + 1))
				done
			fi
		fi
		;;
	esac
	return 0
}

# fo_state_name MODE -> DISABLED|CONNECTING_PRIMARY|PRIMARY_ACTIVE|CONNECTING_SECONDARY|
#                       SECONDARY_ACTIVE|DEGRADED|BLOCKED|ERROR
# Rank 1 is reported as PRIMARY, every other rank as SECONDARY (the number is `active_rank` in the status).
fo_state_name() {
	if [ "$1" = direct ]; then
		if [ -n "$FO_ERR" ]; then echo ERROR; else echo DISABLED; fi
		return
	fi
	[ -z "$FO_ERR" ] || { echo ERROR; return; }
	if [ "$1" = blocked ]; then echo BLOCKED; return; fi # explicit BLOCKED intent: no exit node, no failover
	case $FO_CUR in
	1) _fn_n=PRIMARY ;;
	[2-8]) _fn_n=SECONDARY ;;
	*) echo BLOCKED; return ;;
	esac
	if [ "$FO_VER" != 1 ]; then echo "CONNECTING_$_fn_n"; return; fi
	_fn_f=$(_fo_v FO_FAIL "$FO_CUR")
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
	fo_reset_vars
	_fl_f=$TSEM_RUN_DIR/failover
	[ -f "$_fl_f" ] || return 0
	while IFS='=' read -r _fl_k _fl_v; do
		case $_fl_k in
		# the older two-node file (a router that was not rebooted during the upgrade): primary = rank 1, secondary = rank 2
		cur) case $_fl_v in primary) FO_CUR=1 ;; secondary) FO_CUR=2 ;; none) FO_CUR=none ;; [1-8]) FO_CUR=$_fl_v ;; esac ;;
		ver) case $_fl_v in 0 | 1) FO_VER=$_fl_v ;; esac ;;
		okp) is_uint "$_fl_v" && FO_OK_1=$_fl_v ;;
		failp) is_uint "$_fl_v" && FO_FAIL_1=$_fl_v ;;
		oks) is_uint "$_fl_v" && FO_OK_2=$_fl_v ;;
		fails) is_uint "$_fl_v" && FO_FAIL_2=$_fl_v ;;
		deadp) is_epoch "$_fl_v" && FO_DEAD_1=$_fl_v ;;
		deads) is_epoch "$_fl_v" && FO_DEAD_2=$_fl_v ;;
		bop) is_uint "$_fl_v" && FO_BO_1=$_fl_v ;;
		bos) is_uint "$_fl_v" && FO_BO_2=$_fl_v ;;
		ps) case $_fl_v in ok | fail | unknown) FO_PS_1=$_fl_v ;; esac ;;
		ss) case $_fl_v in ok | fail | unknown) FO_PS_2=$_fl_v ;; esac ;;
		pk) case $_fl_v in egress | egress-fail | reach | unreachable | rejected | pending | unknown) FO_PK_1=$_fl_v ;; esac ;;
		sk) case $_fl_v in egress | egress-fail | reach | unreachable | rejected | pending | unknown) FO_PK_2=$_fl_v ;; esac ;;
		ok_[1-8]) is_uint "$_fl_v" && _fo_set FO_OK "${_fl_k#ok_}" "$_fl_v" ;;
		fail_[1-8]) is_uint "$_fl_v" && _fo_set FO_FAIL "${_fl_k#fail_}" "$_fl_v" ;;
		dead_[1-8]) is_epoch "$_fl_v" && _fo_set FO_DEAD "${_fl_k#dead_}" "$_fl_v" ;;
		bo_[1-8]) is_uint "$_fl_v" && _fo_set FO_BO "${_fl_k#bo_}" "$_fl_v" ;;
		ps_[1-8]) case $_fl_v in ok | fail | unknown) _fo_set FO_PS "${_fl_k#ps_}" "$_fl_v" ;; esac ;;
		pk_[1-8]) case $_fl_v in egress | egress-fail | reach | unreachable | rejected | pending | unknown) _fo_set FO_PK "${_fl_k#pk_}" "$_fl_v" ;; esac ;;
		last) is_epoch "$_fl_v" && FO_LAST=$_fl_v ;;
		dns) case $_fl_v in ok | fail | skip) FO_DNS=$_fl_v ;; esac ;;
		chk) is_epoch "$_fl_v" && FO_CHK=$_fl_v ;;
		err) FO_ERR=$(printf '%s' "$_fl_v" | tr -cd 'A-Za-z0-9 ._:-' | cut -c1-80) ;;
		esac
	done <"$_fl_f"
	# a verified flag without a node is impossible; fail closed
	[ "$FO_CUR" != none ] || FO_VER=0
	return 0
}

# the same defaults as fo_reset, without touching the file
fo_reset_vars() {
	FO_CUR=none FO_VER=0 FO_LAST=0 FO_DNS=skip FO_CHK=0 FO_ERR='' FO_CHANGED=0
	_fr_i=1
	while [ "$_fr_i" -le "$TSEM_MAX_NODES" ]; do
		_fo_set FO_OK "$_fr_i" 0; _fo_set FO_FAIL "$_fr_i" 0; _fo_set FO_DEAD "$_fr_i" 0; _fo_set FO_BO "$_fr_i" "$TSEM_BACKOFF_MIN"
		_fo_set FO_PS "$_fr_i" unknown; _fo_set FO_PK "$_fr_i" unknown
		_fr_i=$((_fr_i + 1))
	done
}

fo_save() {
	mkdir -p "$TSEM_RUN_DIR" || return 1
	{
		printf 'cur=%s\nver=%s\nlast=%s\ndns=%s\nchk=%s\nerr=%s\n' "$FO_CUR" "$FO_VER" "$FO_LAST" "$FO_DNS" "$FO_CHK" "$FO_ERR"
		_fv_i=1
		while [ "$_fv_i" -le "$TSEM_MAX_NODES" ]; do
			printf 'ok_%s=%s\nfail_%s=%s\ndead_%s=%s\nbo_%s=%s\nps_%s=%s\npk_%s=%s\n' \
				"$_fv_i" "$(_fo_v FO_OK "$_fv_i")" "$_fv_i" "$(_fo_v FO_FAIL "$_fv_i")" "$_fv_i" "$(_fo_v FO_DEAD "$_fv_i")" \
				"$_fv_i" "$(_fo_v FO_BO "$_fv_i")" "$_fv_i" "$(_fo_v FO_PS "$_fv_i")" "$_fv_i" "$(_fo_v FO_PK "$_fv_i")"
			_fv_i=$((_fv_i + 1))
		done
	} >"$TSEM_RUN_DIR/failover.tmp" && mv -f "$TSEM_RUN_DIR/failover.tmp" "$TSEM_RUN_DIR/failover"
}
