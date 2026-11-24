# shellcheck shell=sh
# Minimal POSIX test helpers (no bats dependency). Each test_* function runs in
# its own subshell with a fresh temp environment and the mock backend.

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
SH=${SH:-sh}
P1=100.64.0.10
P2=100.64.0.11

t_setup() {
	T=$(mktemp -d)
	# The git transport may drop the executable bit: stubs are executed directly.
	chmod +x "$ROOT"/tests/stubs/* "$ROOT"/tests/netns/bin/* "$ROOT"/src/usr/libexec/rpcd/tsem "$ROOT"/src/usr/sbin/tsem-api-check 2>/dev/null || true
	export TSEM_STATE_DIR=$T/state TSEM_RUN_DIR=$T/run TSEM_MOCK_DIR=$T/mock
	export TSEM_BACKEND=mock TSEM_LIBDIR=$ROOT/src/usr/lib/tsem TSEM_CONF=$T/none.conf
	export TSEM_PRIMARY=$P1 TSEM_SECONDARY=$P2 TSEM_SYSLOG=0 TSEM_SET_TICK_DELAY=0
	export TSEM_NOW=1790000000 TSEM_LOCK_TIMEOUT=10
	mkdir -p "$TSEM_STATE_DIR" "$TSEM_RUN_DIR" "$TSEM_MOCK_DIR"
	trap 'pkill -9 -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
}

tsem() { "$SH" "$ROOT/src/usr/sbin/tsem" "$@"; }
fail() { echo "    FAIL: $*" >&2; exit 1; }
# skip REASON: the test could not run here. Counted and reported as SKIPPED, never as passed.
skip() { echo "    SKIPPED: $*" >&2; exit 77; }
# need_skip REASON: a REQUIRED tool is missing. In CI (TSEM_STRICT=1) that is a FAIL, never a skip.
# kernel_skip REASON: the test needs a real kernel netfilter. With TSEM_NO_KERNEL=1 (the container CI job has no CAP_NET_ADMIN) it is
# listed as NOT RUN and belongs to the ht-dev VM suite (tools/run-netns-vm.sh runs it for real); otherwise it is a strict FAIL.
kernel_skip() { if [ "${TSEM_NO_KERNEL:-0}" = 1 ]; then skip "NOT RUN here (needs kernel netfilter; run by tools/run-netns-vm.sh on ht-dev): $*"; fi; need_skip "$@"; }
need_skip() { [ "${TSEM_STRICT:-0}" != 1 ] || fail "required dependency missing (TSEM_STRICT=1): $*"; skip "$@"; }
assert_eq() { [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"; }
assert_rc() { _n=$1 _e=$2; shift 2; "$@" >/dev/null 2>&1; _g=$?; [ "$_g" -eq "$_e" ] || fail "$_n: expected rc $_e, got $_g"; }
assert_contains() { case $3 in *"$2"*) ;; *) fail "$1: '$3' does not contain '$2'" ;; esac; }
st() { tsem status | sed -n "s/^$1=//p"; }
guard() { cat "$TSEM_MOCK_DIR/guard" 2>/dev/null || echo none; }
mexit() { cat "$TSEM_MOCK_DIR/exit" 2>/dev/null || echo none; }
isum() { md5sum <"$TSEM_STATE_DIR/intent" 2>/dev/null || echo none; }

# tk N: N ticks, 5 s apart
tk() {
	_tn=${1:-1}
	while [ "$_tn" -gt 0 ]; do
		tsem tick >/dev/null 2>&1
		export TSEM_NOW=$((TSEM_NOW + 5))
		_tn=$((_tn - 1))
	done
}
go_german() { tsem set german --no-wait >/dev/null 2>&1; tk "${1:-8}"; }

mdown() { mkdir -p "$TSEM_MOCK_DIR/down"; : >"$TSEM_MOCK_DIR/down/$1"; }
mup() { rm -f "$TSEM_MOCK_DIR/down/$1"; }
mflag() { : >"$TSEM_MOCK_DIR/$1"; }
munflag() { rm -f "$TSEM_MOCK_DIR/$1"; }

ev_seq() { cat "$TSEM_MOCK_DIR/seq" 2>/dev/null || echo 0; }
# number of "guard open" events after event number $1
opens_after() {
	awk -v s="$1" '$1 > s && $2 == "guard" && $3 == "open" { n++ } END { print n + 0 }' "$TSEM_MOCK_DIR/events" 2>/dev/null
}
assert_never_open_after() { _o=$(opens_after "$1"); [ "$_o" -eq 0 ] || fail "guard was opened $_o time(s) after event $1 (leak window)"; }

# ev_line "guard blocked" first|last -> event number (0 if none)
ev_line() {
	awk -v p="$1" '{ l = $0; sub(/^[0-9]+ /, "", l); if (l == p) print NR }' "$TSEM_MOCK_DIR/events" 2>/dev/null |
		{ if [ "${2:-first}" = last ]; then tail -n 1; else head -n 1; fi; } | { read -r x; echo "${x:-0}"; }
}

run_file() {
	_file=$1 _fail=0 _pass=0 _skip=0
	for _fn in $(grep -o '^test_[a-z0-9_]*' "$_file"); do
		[ -z "${TEST_ONLY:-}" ] || case $_fn in *$TEST_ONLY*) ;; *) continue ;; esac # local filter: TEST_ONLY=wd_ sh tests/run.sh
		( t_setup; "$_fn" )
		case $? in
		0) echo "  ok   $_fn"; _pass=$((_pass + 1)) ;;
		77) echo "  SKIP $_fn"; _skip=$((_skip + 1)) ;;
		*) echo "  FAIL $_fn"; _fail=$((_fail + 1)) ;;
		esac
	done
	echo "$_pass passed, $_fail failed, $_skip skipped ($_file)"
	[ "$_fail" -eq 0 ]
}
