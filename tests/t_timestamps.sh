# shellcheck shell=sh
# Regression: a real unix time has 10 digits; is_uint (9 digits max) must never be used for timestamps.

_mkintent() { # mode failover seq ts source
	_b="v=1
mode=$1
failover=$2
seq=$3
ts=$4
source=$5"
	_c=$(printf '%s\n' "$_b" | md5sum | cut -c1-32)
	printf '%s\ncrc=%s\n' "$_b" "$_c" >"$TSEM_STATE_DIR/intent"
}

# --- timestamps: a real unix time has 10 digits; is_uint (9 digits max) must never be used for it ---
test_intent_written_with_the_real_clock_is_valid() {
	t_setup
	unset TSEM_NOW
	tsem set german --no-wait >/dev/null 2>&1
	_o=$(tsem intent-check); _rc=$?
	assert_eq rc 0 "$_rc"; assert_contains ok 'reason=ok' "$_o"
	_ts=$(sed -n 's/^ts=//p' "$TSEM_STATE_DIR/intent")
	[ "${#_ts}" -ge 10 ] || fail "test did not use a real epoch ($_ts)"
}

test_intent_epoch_boundaries() {
	t_setup
	_mkintent german auto 1 1790000000 test
	assert_contains ten 'reason=ok' "$(tsem intent-check)"
	_mkintent german auto 1 17900000000 test
	assert_contains eleven 'reason=ok' "$(tsem intent-check)"
	_mkintent german auto 1 179000000000 test
	assert_contains twelve 'reason=seq-ts' "$(tsem intent-check)"
	_mkintent german auto 1 17x00 test
	assert_contains alpha 'reason=seq-ts' "$(tsem intent-check)"
	_mkintent german auto 1790000000 1790000000 test
	assert_contains seq10 'reason=seq-ts' "$(tsem intent-check)"
}

test_failover_state_keeps_epoch_valued_fields() {
	t_setup
	printf 'cur=primary\nver=1\nokp=3\nfailp=0\noks=0\nfails=0\nlast=1790000100\ndeadp=1790000200\ndeads=1790000300\nbop=20\nbos=20\ndns=ok\nchk=1790000400\nps=ok\nss=unknown\nerr=\n' >"$TSEM_RUN_DIR/failover"
	_o=$("$SH" -c '. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; . "$TSEM_LIBDIR/failover.sh"; TSEM_BACKOFF_MIN=10; fo_load; echo "$FO_LAST $FO_DEADP $FO_DEADS $FO_CHK"')
	assert_eq epochs "1790000100 1790000200 1790000300 1790000400" "$_o"
}
