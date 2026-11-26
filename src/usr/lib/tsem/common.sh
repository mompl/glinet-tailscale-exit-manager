# shellcheck shell=sh
# Common helpers. POSIX sh only (OpenWrt ash / busybox compatible).

TSEM_VERSION=1.1.0

: "${TSEM_CONF:=/etc/tsem/tsem.conf}"
: "${TSEM_STATE_DIR:=/etc/tsem}"     # persistent (flash): intent only
: "${TSEM_RUN_DIR:=/var/run/tsem}"   # tmpfs: lock, failover state, journal

log() {
	printf 'tsem: %s\n' "$*" >&2
	if [ "${TSEM_SYSLOG:-1}" = 1 ] && command -v logger >/dev/null 2>&1; then
		logger -t tsem -- "$*" 2>/dev/null
	fi
	return 0
}
die() { log "error: $*"; exit "${DIE_RC:-1}"; }

now() {
	if [ -n "${TSEM_NOW:-}" ]; then echo "$TSEM_NOW"; else date +%s; fi
}

is_uint() {
	case $1 in '' | *[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 9 ]
}

# is_epoch: a unix timestamp. is_uint caps at 9 digits (counters, ports); an epoch has 10 digits since 2001,
# so every timestamp read from a state file must use this, never is_uint.
is_epoch() {
	case $1 in '' | *[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 11 ]
}

# valid_ip4 A.B.C.D
valid_ip4() {
	case $1 in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
	(
		IFS=.
		# shellcheck disable=SC2086
		set -- $1
		[ $# -eq 4 ] || exit 1
		for _p in "$@"; do
			[ "${#_p}" -le 3 ] && [ "$_p" -le 255 ] || exit 1
		done
	)
}

# valid_cidr4 A.B.C.D/N
valid_cidr4() {
	case $1 in */*) ;; *) return 1 ;; esac
	valid_ip4 "${1%/*}" || return 1
	is_uint "${1#*/}" && [ "${1#*/}" -le 32 ]
}

# valid_cidr6: conservative charset + one slash + prefix length
valid_cidr6() {
	case $1 in */*) ;; *) return 1 ;; esac
	case ${1%/*} in '' | *[!0-9a-fA-F:]* | *:::*) return 1 ;; esac
	case ${1%/*} in *:*) ;; *) return 1 ;; esac
	is_uint "${1#*/}" && [ "${1#*/}" -le 128 ]
}

valid_iface() {
	case $1 in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
	[ "${#1}" -le 15 ]
}

# valid_word: safe token for status output
safe_word() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._:/,=-' | cut -c1-120; }
