#!/usr/bin/env python3
"""Router-side egress probe for the netns tests (TSEM_PROBE_CMD).
Succeeds iff a UDP request to the 'internet' address is answered by the TUNNEL
side. Flags in $TS_STUB_DIR simulate an exit node without internet."""
import os, socket, sys
d = os.environ["TS_STUB_DIR"]
exit_ip = open(d + "/exit").read().strip() if os.path.exists(d + "/exit") else ""
if os.path.exists(d + "/egress_down_all") or (exit_ip and os.path.exists(d + "/egress_down_" + exit_ip)):
    sys.exit(1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(0.8)
try:
    s.sendto(b"?", ("203.0.113.9", 9000))
    data, _ = s.recvfrom(64)
    sys.exit(0 if data == b"TUN" else 1)
except OSError:
    sys.exit(1)
