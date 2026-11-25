#!/bin/sh
# Run all unit/mock tests:  sh tests/run.sh      (SH=dash sh tests/run.sh to pick a shell)
# Packet-path tests (network namespaces, root needed):  sh tests/netns/run.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT
SH=${SH:-sh}
export SH
rc=0
for f in "$ROOT"/tests/t_*.sh; do
	echo "== $(basename "$f") (shell: $SH)"
	"$SH" -c ". '$ROOT/tests/lib.sh'; . '$f'; run_file '$f'" || rc=1
done
[ "$rc" -eq 0 ] && echo "ALL EXECUTED TESTS PASSED (skipped tests are listed as SKIP above and are NOT passes)" || echo "TESTS FAILED"
exit "$rc"
