# shellcheck shell=sh
# Backend dispatcher. A backend implements:
#   be_guard_set open|german|blocked   apply kill-switch state, idempotent, verified (rc 0 only if the
#                                      kernel state matches afterwards)
#   be_guard_get                       open|german|blocked|inconsistent|none  (reads the real state)
#   be_guard_remove                    remove every tsem rule (uninstall)
#   be_exit_set <ip>|none              select/clear the Tailscale exit node (never touches
#                                      --advertise-exit-node)
#   be_exit_get                        <ip>|none|pending|unavailable
#   be_probe_egress                    rc 0 if real internet egress works through the selected exit node
#   be_probe_reach <ip>                rc 0 if the node answers (tailscale ping)
#   be_probe_detail                    one line: per-URL result and failure class of the last be_probe_egress
#   be_probe_dns                       rc 0 if name resolution works (rc 0 if not configured)
#
#   mock  tests only (events log, fault injection)
#   ipt   iptables-legacy/fw3 + ip rule + tailscale CLI (GL-MT3000)

backend_load() {
	case ${TSEM_BACKEND:-ipt} in
	mock)
		: "${TSEM_MOCK_DIR:?TSEM_MOCK_DIR must be set for the mock backend}"
		# shellcheck disable=SC1091
		. "$TSEM_LIBDIR/backend_mock.sh"
		;;
	ipt)
		# shellcheck disable=SC1091
		. "$TSEM_LIBDIR/backend_ipt.sh"
		;;
	*) DIE_RC=3 die "unknown backend '$TSEM_BACKEND'" ;;
	esac
}
