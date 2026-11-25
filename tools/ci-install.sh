#!/bin/sh
# Provide missing tools INSIDE a CI job (never by hand on the runner host) and say exactly why it failed if that is impossible.
# usage: tools/ci-install.sh PKG...   with Debian-style names (iptables python3 nodejs curl dash bash lua5.4 shellcheck)
# Supports apk (Alpine, the runner today) and apt. Exit 0 only if every package is installed afterwards.
echo "== ci-install: user=$(id -un) uid=$(id -u) host=$(uname -n) kernel=$(uname -r)"
[ -r /etc/os-release ] && . /etc/os-release && echo "== os: ${PRETTY_NAME:-unknown}"
if [ "$(id -u)" = 0 ]; then S=""; elif command -v sudo >/dev/null 2>&1; then S="sudo -n"; else S=""; echo "== no root and no sudo"; fi
if command -v apk >/dev/null 2>&1; then
	want=""
	for p in "$@"; do
		case $p in
		iptables) want="$want iptables ip6tables iptables-legacy" ;;
		*) want="$want $p" ;;
		esac
	done
	echo "== apk add:$want"
	# shellcheck disable=SC2086
	$S apk add --no-cache $want 2>&1 | tail -n 15
	rc=0
	for p in $want; do apk info -e "$p" >/dev/null 2>&1 && echo "== installed: $p" || { echo "== MISSING after install: $p"; rc=1; }; done
	exit $rc
fi
command -v apt-get >/dev/null 2>&1 || { echo "== neither apk nor apt-get is available on this runner"; exit 1; }
echo "== apt update"; $S apt-get update -y 2>&1 | tail -n 15
echo "== apt install: $*"; $S env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 2>&1 | tail -n 15
rc=0
for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 && echo "== installed: $p" || { echo "== MISSING after install: $p"; rc=1; }; done
exit $rc
