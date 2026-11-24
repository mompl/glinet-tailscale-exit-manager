#!/bin/sh
# Packet-path tests in network namespaces: IPv4 (netns_test.py) and IPv6 (netns6_test.py).
# Needs root, python3 >= 3.12 and iptables/ip6tables.
# Without TSEM_STRICT=1 a missing capability exits 77 (skipped, never a pass). With TSEM_STRICT=1 (CI) it is a FAIL (exit 1).
# The IPv6 suite is mandatory: a kernel without IPv6 FAILS it (exit 1) in every mode.
HERE=$(cd "$(dirname "$0")" && pwd)
missing() { echo "MISSING: $1"; if [ "${TSEM_STRICT:-0}" = 1 ]; then echo "FAIL: the mandatory packet-path tests cannot run: $1"; exit 1; fi; echo "SKIPPED: $1"; exit 77; }
command -v python3 >/dev/null 2>&1 || missing "python3 missing"
python3 -c 'import os; os.unshare; os.setns' 2>/dev/null || missing "python3 >= 3.12 needed"
command -v iptables >/dev/null 2>&1 || missing "iptables missing"
command -v ip6tables >/dev/null 2>&1 || missing "ip6tables missing"
python3 "$HERE/netns_test.py" "$@"; rc4=$?
[ "$rc4" -ne 77 ] || missing "the IPv4 suite reported 'skipped' (no root or no namespace capability)"
python3 "$HERE/netns6_test.py"; rc6=$?
echo "netns IPv4 rc=$rc4, IPv6 rc=$rc6"
[ "$rc4" -eq 0 ] && [ "$rc6" -eq 0 ]
