#!/bin/sh
# fw3 firewall include (option reload '1'): fw3 flushes the built-in chains on every
# reload. Re-assert the kill switch right after it. The policy-routing layer is not
# touched by fw3, so there is no unprotected window while this runs.
exec /usr/sbin/tsem reapply
