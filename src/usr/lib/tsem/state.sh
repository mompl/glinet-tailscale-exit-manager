# shellcheck shell=sh
# Intent (desired state) storage. Single write path, protected by one lock.
#
# Intent file (never sourced; parsed key by key):
#   v=1
#   mode=direct|german|blocked
#   failover=auto|off
#   seq=<monotonic counter>
#   ts=<unix time>
#   source=<hw|ha|cli|install|...>
#   crc=<md5 of all other lines>
#
# Only real user actions (tsem set / tsem failover auto|off) write this file.
# status/tick/boot/reapply/mqtt-publish never do, so a restart or a status sync
# can never be mistaken for a new user action.

# Global lock on fd 9. Child processes inherit fd 9, so long-lived children
# must be started with "9>&-".
lock_acquire() {
	mkdir -p "$TSEM_RUN_DIR" || die "cannot create $TSEM_RUN_DIR"
	exec 9>"$TSEM_RUN_DIR/lock"
	_la_i=0
	# Portable: -n retry loop works with util-linux AND busybox flock.
	while ! flock -x -n 9; do
		_la_i=$((_la_i + 1))
		[ "$_la_i" -lt "$TSEM_LOCK_TIMEOUT" ] || die "lock timeout"
		sleep 1
	done
}
lock_release() { exec 9>&-; }

# intent_read: sets I_MODE I_FAILOVER I_SEQ I_TS I_SRC and I_WHY (reason code, for diagnosis only).
# Returns 0 = valid, 1 = missing, 2 = invalid (corrupt/tampered/old format).
# An invalid intent is NEVER interpreted as DIRECT: every caller treats it as BLOCKED.
# I_WHY: ok | missing | unreadable | no-crc | crc-mismatch | version | mode | failover | seq-ts | source
intent_read() {
	I_MODE='' I_FAILOVER=auto I_SEQ=0 I_TS=0 I_SRC='' I_WHY=ok
	_ir_f=$TSEM_STATE_DIR/intent
	[ -f "$_ir_f" ] || { I_WHY=missing; return 1; }
	[ -r "$_ir_f" ] || { I_WHY=unreadable; return 2; }
	_ir_want=$(sed -n 's/^crc=//p' "$_ir_f" | head -n 1)
	[ -n "$_ir_want" ] || { I_WHY=no-crc; return 2; }
	_ir_have=$(grep -v '^crc=' "$_ir_f" | md5sum | cut -c1-32)
	[ "$_ir_want" = "$_ir_have" ] || { I_WHY=crc-mismatch; return 2; }
	_ir_v='' _ir_mode='' _ir_fo=auto _ir_seq='' _ir_ts='' _ir_src=''
	while IFS='=' read -r _ir_k _ir_val; do
		case $_ir_k in
		v) _ir_v=$_ir_val ;;
		mode) _ir_mode=$_ir_val ;;
		failover) _ir_fo=$_ir_val ;;
		seq) _ir_seq=$_ir_val ;;
		ts) _ir_ts=$_ir_val ;;
		source) _ir_src=$_ir_val ;;
		esac
	done <"$_ir_f"
	[ "$_ir_v" = 1 ] || { I_WHY=version; return 2; }
	case $_ir_mode in direct | german | blocked) ;; *) I_WHY=mode; return 2 ;; esac
	case $_ir_fo in auto | off) ;; *) I_WHY=failover; return 2 ;; esac
	is_uint "$_ir_seq" && is_epoch "$_ir_ts" || { I_WHY=seq-ts; return 2; }
	case $_ir_src in '' | *[!a-z0-9_-]*) I_WHY=source; return 2 ;; esac
	I_MODE=$_ir_mode I_FAILOVER=$_ir_fo I_SEQ=$_ir_seq I_TS=$_ir_ts I_SRC=$_ir_src
	return 0
}

# intent_write MODE FAILOVER SOURCE. Caller holds the lock and has just called
# intent_read (so I_SEQ is current, or 0 when missing/invalid).
intent_write() {
	mkdir -p "$TSEM_STATE_DIR" || return 1
	_iw_seq=$((I_SEQ + 1))
	_iw_body="v=1
mode=$1
failover=$2
seq=$_iw_seq
ts=$(now)
source=$3"
	_iw_crc=$(printf '%s\n' "$_iw_body" | md5sum | cut -c1-32)
	_iw_tmp=$TSEM_STATE_DIR/.intent.$$
	if (umask 077; printf '%s\ncrc=%s\n' "$_iw_body" "$_iw_crc" >"$_iw_tmp") && mv -f "$_iw_tmp" "$TSEM_STATE_DIR/intent"; then
		_iw_j=$TSEM_RUN_DIR/journal
		printf '%s %s %s %s %s\n' "$_iw_seq" "$1" "$2" "$3" "$(now)" >>"$_iw_j"
		if [ "$(wc -l <"$_iw_j")" -gt 500 ]; then
			tail -n 200 "$_iw_j" >"$_iw_j.tmp" && mv -f "$_iw_j.tmp" "$_iw_j"
		fi
		return 0
	fi
	rm -f "$_iw_tmp"
	return 1
}
