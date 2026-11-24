#!/bin/sh
# Full IPv4 + IPv6 packet-path suite on the isolated Linux VM `ht-dev` (real network namespaces, real iptables/ip6tables).
#
#   sudo sh tools/run-netns-vm.sh [--sha COMMIT] [--post] [--token-file FILE] [--gitea-url URL] [--out DIR]
#
# 1. PREFLIGHT proves kernel features, capabilities and tools. Any failure => verdict NOT-RUN (exit 2). There is no bypass.
# 2. RUN executes the IPv4 and IPv6 netns suites and tests/t_rules.sh (real iptables-restore syntax check), TSEM_STRICT=1.
# 3. VERDICT: PASSED only if every suite ran, 0 failed, nothing was skipped, and the number of passed scenarios equals the number of
#    scenarios in the source. Anything else is FAILED or NOT-RUN. NOT-RUN is never a pass.
# 4. --post: sets a Gitea commit status "netns-vm/ht-dev" on the tested commit (success only for PASSED; failure for FAILED;
#    error for NOT-RUN). The token comes from GITEA_TOKEN or --token-file (never from the repo, never printed).
# Exit codes: 0 PASSED, 1 FAILED, 2 NOT-RUN.
# Makes no changes outside its own temporary namespaces and the --out directory; the VM's own network is untouched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SHA=""; POST=0; TOKEN_FILE=""; GITEA_URL=${GITEA_URL:-https://gitea.example.org}; OUT=""
REPO_PATH=${TSEM_REPO_PATH:-dev/glinet-tailscale-exit-manager}
while [ $# -gt 0 ]; do
	case $1 in
	--sha) SHA=${2:-}; shift 2 ;;
	--post) POST=1; shift ;;
	--token-file) TOKEN_FILE=${2:-}; shift 2 ;;
	--gitea-url) GITEA_URL=${2:-}; shift 2 ;;
	--out) OUT=${2:-}; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 64 ;;
	esac
done
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
[ -n "$OUT" ] || OUT=${TMPDIR:-/tmp}/tsem-netns-vm-$STAMP
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 64; }
LOG=$OUT/run.log
: >"$LOG"
say() { echo "$*" | tee -a "$LOG"; }
PF_FAIL=0
pf() { # PASS|FAIL name detail
	say "$(printf '%-5s %-22s %s' "$1" "$2" "$3")"
	[ "$1" = PASS ] || PF_FAIL=$((PF_FAIL + 1))
}

SELFTEST=${TSEM_VM_SELFTEST:-0}   # unit tests of this script only: fake suites, result is marked selftest and is never posted

say "== TSEM netns suite on $(uname -n) at $STAMP (code: $ROOT)"
# ---- commit under test
SHA_GIVEN=0; [ -z "$SHA" ] || SHA_GIVEN=1
DIRTY=unknown
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
	HEADSHA=$(git -C "$ROOT" rev-parse HEAD)
	[ -n "$SHA" ] || SHA=$HEADSHA
	DIRTY=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
	case $HEADSHA in "$SHA"*) ;; *) DIRTY=mismatch ;; esac   # --sha names another commit than the checkout
fi
say "commit: ${SHA:-unknown}   uncommitted changes: $DIRTY"

# ---- PREFLIGHT
say; say "### PREFLIGHT (kernel, capabilities, tools)"
[ "$(id -u)" = 0 ] && pf PASS root "uid 0" || pf FAIL root "run as root (sudo)"
capeff=$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null)
if [ -n "$capeff" ]; then
	# CAP_NET_ADMIN = bit 12, CAP_SYS_ADMIN = bit 21
	python3 - "$capeff" <<'PY' >/dev/null 2>&1 && pf PASS capabilities "CAP_NET_ADMIN and CAP_SYS_ADMIN present" || pf FAIL capabilities "CAP_NET_ADMIN/CAP_SYS_ADMIN missing (CapEff=$capeff): not a VM with full root?"
import sys
v = int(sys.argv[1], 16)
sys.exit(0 if (v >> 12) & 1 and (v >> 21) & 1 else 1)
PY
else
	pf FAIL capabilities "cannot read CapEff"
fi
command -v python3 >/dev/null 2>&1 && python3 -c 'import sys,os; assert sys.version_info>=(3,12); os.unshare; os.setns' 2>/dev/null \
	&& pf PASS python "$(python3 --version 2>&1) with os.unshare/os.setns" || pf FAIL python "python3 >= 3.12 with os.unshare/os.setns required"
for t in iptables ip6tables iptables-restore ip6tables-restore dash bash sh; do
	command -v "$t" >/dev/null 2>&1 && pf PASS "tool:$t" "$(command -v "$t")" || pf FAIL "tool:$t" "missing"
done
[ -e /proc/net/if_inet6 ] && pf PASS ipv6-kernel "/proc/net/if_inet6 exists" || pf FAIL ipv6-kernel "kernel has no IPv6"
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = 0 ]; then pf PASS ipv6-enabled "disable_ipv6=0"; else pf FAIL ipv6-enabled "IPv6 is disabled (sysctl net.ipv6.conf.all.disable_ipv6)"; fi
# real proof inside a throw-away namespace: create a chain with iptables AND ip6tables, enable v6 forwarding
python3 - <<'PY' >>"$LOG" 2>&1 && pf PASS netns-netfilter "namespace + iptables + ip6tables + ipv6 forwarding work" || pf FAIL netns-netfilter "cannot use iptables/ip6tables inside a new network namespace (see $LOG)"
import os, subprocess, sys
pid = os.fork()
if pid == 0:
    try:
        os.unshare(os.CLONE_NEWNET)
        for cmd in (["iptables", "-w", "5", "-N", "TSEMCHK"], ["ip6tables", "-w", "5", "-N", "TSEMCHK"]):
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode:
                print("%s failed: %s" % (" ".join(cmd), r.stderr.strip()))
                os._exit(2)
        open("/proc/sys/net/ipv6/conf/all/forwarding", "w").write("1")
        os._exit(0)
    except Exception as e:
        print("namespace check failed: %r" % e)
        os._exit(3)
sys.exit(0 if os.waitpid(pid, 0)[1] == 0 else 1)
PY
backend=$(iptables --version 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')
say "info  iptables backend: ${backend:-unknown} (the router uses iptables-legacy; a mismatch is reported, not hidden)"
say "info  kernel: $(uname -r)   $(iptables --version 2>/dev/null | head -n 1)   $(python3 --version 2>&1)"

# ---- expected scenario counts, taken from the source (so a skipped scenario cannot hide)
EXP4=$(grep -c '^def s_' "$ROOT/tests/netns/netns_test.py" 2>/dev/null || echo 0)
EXP6=$(grep -c '^def s6_' "$ROOT/tests/netns/netns6_test.py" 2>/dev/null || echo 0)
say "info  expected scenarios: IPv4=$EXP4 IPv6=$EXP6"

V4=notrun; V6=notrun; VR=notrun; P4=0; P6=0; PR=0
if [ "$PF_FAIL" -gt 0 ] && [ "$SELFTEST" != 1 ]; then
	say; say "PREFLIGHT FAILED ($PF_FAIL): nothing was run. Verdict NOT-RUN (this is NOT a pass)."
else
	[ "$PF_FAIL" -eq 0 ] || say "(selftest: preflight failures ignored for the fake-suite test only)"
	say; say "### RUN"
	export TSEM_STRICT=1
	if [ "$SELFTEST" = 1 ] && [ -n "${TSEM_VM_FAKE_SUITE:-}" ]; then
		RUN4=$TSEM_VM_FAKE_SUITE; RUN6=$TSEM_VM_FAKE_SUITE; RUNR="echo 'fake rules suite'; echo '1 passed, 0 failed, 0 skipped (fake)'"
	else
		RUN4="python3 '$ROOT/tests/netns/netns_test.py'"
		RUN6="python3 '$ROOT/tests/netns/netns6_test.py'"
		RUNR="SH=dash sh -c \". '$ROOT/tests/lib.sh'; . '$ROOT/tests/t_rules.sh'; ROOT='$ROOT' run_file '$ROOT/tests/t_rules.sh'\""
	fi
	run_suite() { # name cmd -> sets RC and logs
		say "-- $1"
		( cd "$ROOT" && ROOT=$ROOT eval "$2" ) >"$OUT/$1.log" 2>&1; _rc=$?
		cat "$OUT/$1.log" >>"$LOG"
		return $_rc
	}
	count_passed() { sed -n 's/^\([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*/\1 \2/p' "$OUT/$1.log" | tail -n 1; }
	for s in ipv4 ipv6 rules; do
		case $s in ipv4) c=$RUN4 ;; ipv6) c=$RUN6 ;; rules) c=$RUNR ;; esac
		run_suite "$s" "$c"; rc=$?
		# shellcheck disable=SC2046
		set -- $(count_passed "$s")
		p=${1:-0}; f=${2:-x}
		case $s in ipv4) P4=$p; exp=$EXP4 ;; ipv6) P6=$p; exp=$EXP6 ;; rules) PR=$p; exp=1 ;; esac
		if [ "$rc" -eq 0 ] && [ "$f" = 0 ] && [ "$p" -ge "$exp" ] && [ "$p" -gt 0 ]; then v=passed
		elif [ "$rc" -eq 77 ] || [ -z "${1:-}" ]; then v=notrun
		else v=failed; fi
		# a suite that passed but skipped something did not run everything: never a pass
		if [ "$v" = passed ] && grep -q 'SKIPPED' "$OUT/$s.log"; then v=notrun; fi
		say "   $s: rc=$rc passed=$p failed=$f expected>=$exp => $v"
		case $s in ipv4) V4=$v ;; ipv6) V6=$v ;; rules) VR=$v ;; esac
	done
fi

# ---- VERDICT
if [ "$V4" = passed ] && [ "$V6" = passed ] && [ "$VR" = passed ]; then VERDICT=PASSED; RC=0
elif [ "$V4" = failed ] || [ "$V6" = failed ] || [ "$VR" = failed ]; then VERDICT=FAILED; RC=1
else VERDICT=NOT-RUN; RC=2; fi
[ "$VERDICT" != PASSED ] || [ "$DIRTY" = 0 ] || { [ "$DIRTY" = unknown ] && [ "$SHA_GIVEN" = 1 ]; } || { say "note: the working tree has uncommitted changes: the result cannot be attributed to the commit"; [ "$SELFTEST" = 1 ] || { VERDICT=NOT-RUN; RC=2; }; }
say; say "VERDICT: $VERDICT   (IPv4 $V4 $P4/$EXP4, IPv6 $V6 $P6/$EXP6, iptables-restore syntax $VR)"

cat >"$OUT/result.md" <<MD
# netns suite on $(uname -n): $VERDICT
- commit: ${SHA:-unknown} (uncommitted changes: $DIRTY)
- time: $STAMP, kernel $(uname -r), $(iptables --version 2>/dev/null | head -n 1)
- preflight failures: $PF_FAIL
- IPv4 netns: $V4 ($P4 of $EXP4 scenarios passed)
- IPv6 netns: $V6 ($P6 of $EXP6 scenarios passed)
- iptables-restore syntax (t_rules.sh): $VR
- selftest: $SELFTEST
NOT-RUN and FAILED are not passes.
MD
say "result: $OUT/result.md   log: $LOG"

# ---- hand over to Gitea (commit status). Success only for PASSED.
if [ "$POST" = 1 ]; then
	TOK=${GITEA_TOKEN:-}
	[ -n "$TOK" ] || { [ -n "$TOKEN_FILE" ] && [ -r "$TOKEN_FILE" ] && TOK=$(head -n 1 "$TOKEN_FILE" | tr -d ' \r\n'); }
	if [ "$SELFTEST" = 1 ]; then say "post: refused in selftest mode"
	elif [ -z "$SHA" ]; then say "post: no commit sha known (use --sha or run inside a git checkout): not posted"
	elif [ -z "$TOK" ]; then say "post: no token (GITEA_TOKEN or --token-file): not posted. Copy $OUT/result.md into PR #7 by hand."
	elif ! command -v curl >/dev/null 2>&1; then say "post: curl missing: not posted"
	else
		case $VERDICT in PASSED) st=success ;; FAILED) st=failure ;; *) st=error ;; esac
		desc="netns ht-dev: $VERDICT (IPv4 $P4/$EXP4, IPv6 $P6/$EXP6)"
		code=$(curl -sS -o "$OUT/post.json" -w '%{http_code}' -X POST "$GITEA_URL/api/v1/repos/$REPO_PATH/statuses/$SHA" \
			-H "Authorization: token $TOK" -H 'Content-Type: application/json' \
			-d "{\"state\":\"$st\",\"context\":\"netns-vm/ht-dev\",\"description\":\"$desc\"}" 2>>"$LOG") || code=000
		case $code in 200 | 201) say "post: commit status netns-vm/ht-dev = $st on ${SHA}" ;; *) say "post: FAILED (http $code, see $OUT/post.json): the result is NOT recorded in Gitea" ;; esac
	fi
fi
exit "$RC"
