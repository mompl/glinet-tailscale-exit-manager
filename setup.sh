#!/bin/sh
# tsem one-step setup for GL.iNet / OpenWrt routers: checks, installs, configures, tests, activates, reports.
#
#   sh setup.sh                     interactive: asks only what it cannot detect (the exit nodes)
#   sh setup.sh --yes --primary NAME [--secondary NAME]      no questions
#
# Options
#   --primary NAME|IP       exit node that is preferred (a Tailscale peer name or its 100.x address)
#   --secondary NAME|IP     exit node used when the primary fails (optional)
#   --fallback NAME|IP      further exit node, tried in the order given after the secondary (repeatable, up to 6)
#   --allow-subnets "A B"   IPv4 subnets behind your nodes that stay reachable while protected (optional)
#   --exit                  after the setup, switch to the exit-node mode (automatically back to DIRECT if it does not come up); --german is an alias
#   --mode-label NAME       the name shown in the GUI, Home Assistant and messages for that mode (default: EXIT), e.g. "Germany" or "Office VPN"
#   --no-activate           install and test only; do not start the service
#   --no-native-gui         do not add the GL.iNet UI entry (APPLICATIONS)       --no-hw-switch   do not install the switch hook
#   --keep-on-failure       do not undo the installation if the self test fails
#   --no-deps               do not install missing packages (ip6tables) with opkg; --remove-legacy-rule  remove the old 'ts_block_lan_leak' rule (a backup is kept)
#   --adopt-exit-node       the router already uses an exit node (GL.iNet's Tailscale page): take it over as the primary and go
#                           straight to the exit-node mode (never through DIRECT); the GL.iNet setting is given back by uninstall.sh
#   --ignore-existing-exit-node   install anyway: the existing exit node is cleared when tsem starts in DIRECT (traffic leaves directly)
#   --admin-subnet NET      keep the router reachable over this private network of a WAN-side link (for example the Wi-Fi uplink of a
#                           GL-E5800: 10.50.0.0/24) while protected; repeatable (TSEM_ADMIN_SUBNETS4)
#   --report FILE           where to write the report (default /etc/tsem/last-setup-report.txt)
#   --yes                   never ask; every choice comes from the options
#   --root DIR              install into DIR (tests)
#
# What it does, in order (each step prints OK, WARN or FAIL):
#   1 check the router   2 install (transactional: any failure restores the previous state)   3 exit nodes
#   4 self test          5 start the service in DIRECT mode and prove the router still has Internet   6 optional GERMAN
# At the end: one result (SUCCESS / SUCCESS WITH WARNINGS / FAILED), what to do next, and a report file.
# A failed setup never leaves the kill switch half-installed: before activation the installation is undone, after
# activation the router is put back to DIRECT. Nothing is ever downloaded; everything comes from this directory.

set -u
umask 022
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=/ YES=0 PRIMARY='' SECONDARY='' SUBNETS='' GERMAN=0 MODE_LABEL='' ACTIVATE=1 KEEP=0 REPORT='' INST_ARGS='' HAVE_SUBNETS=0 DEPS=1 RMRULE=0 ADOPT='' ADMIN='' FALLBACKS=''
while [ $# -gt 0 ]; do
	case $1 in
	--yes) YES=1; shift ;;
	--primary) [ $# -ge 2 ] || { echo "--primary needs a value" >&2; exit 2; }; PRIMARY=$2; shift 2 ;;
	--secondary) [ $# -ge 2 ] || { echo "--secondary needs a value" >&2; exit 2; }; SECONDARY=$2; shift 2 ;;
	--allow-subnets) [ $# -ge 2 ] || { echo "--allow-subnets needs a value" >&2; exit 2; }; SUBNETS=$2; HAVE_SUBNETS=1; shift 2 ;;
	--fallback) [ $# -ge 2 ] || { echo "--fallback needs a value" >&2; exit 2; }; FALLBACKS="${FALLBACKS:+$FALLBACKS }$2"; shift 2 ;;
	--admin-subnet) [ $# -ge 2 ] || { echo "--admin-subnet needs a value" >&2; exit 2; }; ADMIN="${ADMIN:+$ADMIN }$2"; shift 2 ;;
	--exit | --german) GERMAN=1; shift ;;
	--mode-label) [ $# -ge 2 ] || { echo "--mode-label needs a value" >&2; exit 2; }; MODE_LABEL=$2; shift 2 ;;
	--no-activate) ACTIVATE=0; shift ;;
	--no-native-gui) INST_ARGS="$INST_ARGS --no-native-gui"; shift ;;
	--no-hw-switch) INST_ARGS="$INST_ARGS --no-hw-switch"; shift ;;
	--keep-on-failure) KEEP=1; shift ;;
	--no-deps) DEPS=0; shift ;;
	--remove-legacy-rule) RMRULE=1; shift ;;
		--adopt-exit-node) ADOPT=1; shift ;;
		--ignore-existing-exit-node) ADOPT=0; shift ;;
	--report) [ $# -ge 2 ] || { echo "--report needs a value" >&2; exit 2; }; REPORT=$2; shift 2 ;;
	--root) [ $# -ge 2 ] || { echo "--root needs a value" >&2; exit 2; }; ROOT=$2; shift 2 ;;
	-h | --help) sed -n '2,34p' "$0"; exit 0 ;;
	*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
	esac
done
case $MODE_LABEL in *[!A-Za-z0-9' '_-]*) echo "--mode-label: letters, digits, space, - and _ only (max 20)" >&2; exit 2 ;; esac
[ ${#MODE_LABEL} -le 20 ] || { echo "--mode-label: at most 20 characters" >&2; exit 2; }
case $SUBNETS in *[!0-9./\ ]*) echo "--allow-subnets: only IPv4 subnets like '10.0.0.0/24 10.0.1.0/24'" >&2; exit 2 ;; esac
case $ADMIN in *[!0-9./\ ]*) echo "--admin-subnet: only IPv4 networks like 10.50.0.0/24" >&2; exit 2 ;; esac
[ "$GERMAN" -eq 0 ] || [ "$ACTIVATE" -eq 1 ] || { echo "--german needs the activation (do not combine with --no-activate)" >&2; exit 2; }

R=${ROOT%/}
p() { printf '%s%s' "$R" "$1"; }
TSEM=${TSEM_BIN:-$(p /usr/sbin/tsem)}
INITD=${SETUP_INITD:-$(p /etc/init.d/tsem)}
CONF=${TSEM_CONF:-$(p /etc/tsem/tsem.conf)}
[ -n "$REPORT" ] || REPORT=$(p /etc/tsem/last-setup-report.txt)
WORK=${TMPDIR:-/tmp}/tsem-setup.$$
mkdir -p "$WORK" || { echo "cannot create $WORK" >&2; exit 1; }
LOG=$WORK/log
: >"$LOG"
RESULTS=$WORK/results
: >"$RESULTS"
trap 'rm -rf "$WORK"' EXIT
trap 'echo; echo "setup interrupted: the installer finishes or undoes its transaction itself; see: sh install.sh --recover --yes"; exit 130' INT TERM HUP

TOTAL=6
N=0
FAILED=0 WARNED=0 INSTALLED=0 STARTED=0
say() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$LOG"; }
step() { N=$((N + 1)); STEP_TITLE=$1; printf '\n[%s/%s] %s\n' "$N" "$TOTAL" "$1"; printf '\n[%s/%s] %s\n' "$N" "$TOTAL" "$1" >>"$LOG"; }
info() { say "      $*"; }
ok() { say "      OK    $*"; printf 'OK|%s|%s\n' "$STEP_TITLE" "$*" >>"$RESULTS"; }
warn() { say "      WARN  $*"; printf 'WARN|%s|%s\n' "$STEP_TITLE" "$*" >>"$RESULTS"; WARNED=$((WARNED + 1)); }
fail() { say "      FAIL  $*"; printf 'FAIL|%s|%s\n' "$STEP_TITLE" "$*" >>"$RESULTS"; FAILED=$((FAILED + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }
interactive() { [ "$YES" -eq 0 ] && [ -t 0 ]; }
ask() { # PROMPT DEFAULT -> answer on stdout
	printf '%s [%s]: ' "$1" "$2" >&2
	read -r _a || _a=''
	printf '%s' "${_a:-$2}"
}
st() { "$TSEM" status 2>/dev/null | sed -n "s/^$1=//p" | head -n 1; }

# ---------------------------------------------------------------- finish
finish() {
	_res=SUCCESS
	[ "$WARNED" -eq 0 ] || _res="SUCCESS WITH WARNINGS"
	[ "$FAILED" -eq 0 ] || _res=FAILED
	{
		echo
		echo "================================================================"
		echo " RESULT: $_res"
		echo "================================================================"
		while IFS='|' read -r _s _t _m; do printf ' %-4s %-26s %s\n' "$_s" "$_t" "$_m"; done <"$RESULTS"
	} | tee -a "$LOG"
	if [ "$FAILED" -eq 0 ]; then
		cat <<EOF | tee -a "$LOG"

 Next steps
   * GL.iNet web UI > APPLICATIONS > Tailscale Exit Manager (reload the page once). LuCI: Services > Tailscale Exit Manager.
   * Command line: tsem status   (mode, state, exit node)      tsem set exit | direct
   * Mode after a reboot: the intent is stored; the kill switch is installed before the network comes up.
   * Undo everything: sh uninstall.sh --yes      Undo only this installation: sh install.sh --rollback --yes
EOF
		[ "$GERMAN" -eq 1 ] || [ "$ACTIVATE" -eq 0 ] || [ -n "${KEEP:-}" ] || echo " * The router is in DIRECT mode (nothing is rerouted yet). Switch to the exit-node mode in the GUI or with: tsem set exit" | tee -a "$LOG"
	else
		cat <<EOF | tee -a "$LOG"

 The setup did not complete. The details are in the report: $REPORT
 Please attach that file when you ask for help (it contains no passwords or keys).
EOF
	fi
	{
		echo "tsem setup report"
		echo "result: $_res"
		echo "date: $(date 2>/dev/null)"
		echo "version: $(cat "$HERE/VERSION" 2>/dev/null || sed -n 's/^TSEM_VERSION=//p' "$HERE/src/usr/lib/tsem/common.sh" 2>/dev/null | head -n 1)"
		echo
		cat "$LOG"
		if [ "$FAILED" -ne 0 ] && [ -x "$TSEM" ]; then
			echo
			echo "---- tsem status"
			"$TSEM" status 2>&1 | head -n 60
			echo "---- tsem diag"
			"$TSEM" diag 2>&1 | head -n 150
		fi
	} >"$WORK/report" 2>&1
	mkdir -p "$(dirname "$REPORT")" 2>/dev/null
	cp "$WORK/report" "$REPORT" 2>/dev/null && echo " Report written: $REPORT" || echo " (could not write the report to $REPORT)"
	[ "$FAILED" -eq 0 ]
	exit $?
}

# give the toggle button back if this setup set it (only when it still has our value)
hw_func_undo() {
	[ -e "$(p /etc/tsem/hw-func-set)" ] || return 0
	_uci=${SETUP_UCI:-uci}
	if have "$_uci" && [ "$("$_uci" -q get switch-button.@main[0].func 2>/dev/null)" = tailscale-de ]; then
		"$_uci" -q delete switch-button.@main[0].func && "$_uci" commit switch-button
	fi
	rm -f "$(p /etc/tsem/hw-func-set)"
}
# undo what this run installed (only before activation)
undo_install() {
	[ "$INSTALLED" -eq 1 ] || return 0
	hw_func_undo
	say "      undoing the installation (sh install.sh --rollback) ..."
	if sh "$HERE/install.sh" --root "$ROOT" --rollback --yes >"$WORK/rollback.out" 2>&1; then say "      the previous state is restored"; INSTALLED=0
	else say "      ROLLBACK FAILED: $(tail -n 3 "$WORK/rollback.out" | tr '\n' ' ')"; say "      run: sh install.sh --recover --yes"; fi
}

# ---------------------------------------------------------------- 1 check
step "Check the router"
if [ "$R" = "" ] && [ "$(id -u 2>/dev/null)" != 0 ]; then fail "run as root (on the router: ssh root@router)"; finish; fi
[ -f "$HERE/install.sh" ] && [ -d "$HERE/src" ] || { fail "install.sh or src/ not found next to setup.sh: unpack the whole package"; finish; }
_miss=''
for _c in iptables ip awk sed flock md5sum; do have "$_c" || _miss="$_miss $_c"; done
if [ -n "$_miss" ]; then fail "missing tools:$_miss (this does not look like an OpenWrt/GL.iNet router with iptables)"; finish; fi
_model=$(cat /tmp/sysinfo/model 2>/dev/null || cat "$(p /tmp/sysinfo/model)" 2>/dev/null || echo unknown)
_fw=$(sed -n 's/^\([0-9][0-9.]*\).*/\1/p' "$(p /etc/glversion)" 2>/dev/null | head -n 1)
info "router: $_model, GL.iNet firmware: ${_fw:-not detected}"
if [ -d "$(p /usr/share/oui/menu.d)" ]; then info "GL.iNet web UI found: the entry goes to APPLICATIONS"; else info "no GL.iNet web UI found: only LuCI will be installed (if present)"; fi
if [ -d "$(p /etc/gl-switch.d)" ] || [ -e "$(p /etc/config/switch-button)" ]; then info "hardware switch support found: the switch hook will be installed"; else info "no hardware switch on this router: modes are set by the GUI, the CLI or Home Assistant"; fi
# devices known to have a display or buttons but NO hardware toggle switch: the hook would never be called
case $_model in
*E5800*)
	case $INST_ARGS in *--no-hw-switch*) ;; *) INST_ARGS="$INST_ARGS --no-hw-switch"; info "this model (GL-E5800, Mudi 7) has no hardware toggle switch: the switch hook is not installed" ;; esac ;;
esac
if have tailscale; then
	if tailscale status >/dev/null 2>&1; then info "tailscale is running"; else warn "tailscale is installed but not running or not logged in: exit nodes cannot be listed until it is"; fi
else warn "tailscale not found: install and log in to Tailscale first (GL.iNet UI > APPLICATIONS > Tailscale)"; fi
_free=$(df -k "$(p /)" 2>/dev/null | awk 'NR==2 {print $4}')
case $_free in
'' | *[!0-9]*) ;;
*) if [ "$_free" -lt 1024 ]; then fail "only ${_free} kB free on the router: at least 1024 kB are needed"; finish; elif [ "$_free" -lt 4096 ]; then warn "only ${_free} kB free"; fi ;;
esac
# IPv6: tsem must be able to close IPv6 too. A router with IPv6 in the kernel but without ip6tables cannot be protected, so the
# package that matches the router's iptables flavour (nft or legacy) is installed. Skip with --no-deps.
_opk=${SETUP_OPKG:-opkg}
case $(iptables -V 2>/dev/null) in *nf_tables*) _pkg=ip6tables-nft ;; *legacy*) _pkg=ip6tables-zz-legacy ;; *) _pkg=ip6tables ;; esac
remember_dep() { mkdir -p "$(p /etc/tsem)" && { grep -qx "$1" "$(p /etc/tsem/deps)" 2>/dev/null || echo "$1" >>"$(p /etc/tsem/deps)"; }; } # 'tsem deps' reinstalls it after a firmware upgrade
if [ -e "$(p /proc/net/if_inet6)" ] && have "${SETUP_IP6T:-ip6tables}" && have "$_opk" && "$_opk" status "$_pkg" 2>/dev/null | grep -q '^Status:.* installed'; then
	remember_dep "$_pkg" # installed by hand or by an earlier setup: a firmware upgrade would remove it as well
fi
if [ -e "$(p /proc/net/if_inet6)" ] && ! have "${SETUP_IP6T:-ip6tables}"; then
	if [ "$DEPS" -eq 0 ]; then
		fail "IPv6 is enabled but ip6tables is missing: install it (opkg update && opkg install $_pkg) or run setup without --no-deps"; finish
	elif ! have "$_opk"; then
		fail "IPv6 is enabled but ip6tables is missing and there is no opkg: install ip6tables yourself or disable IPv6"; finish
	else
		info "IPv6 is enabled but ip6tables is missing: installing $_pkg with opkg (--no-deps skips this)"
		if "$_opk" update >>"$LOG" 2>&1 && "$_opk" install "$_pkg" >>"$LOG" 2>&1 && have "${SETUP_IP6T:-ip6tables}"; then
			ok "installed $_pkg (ip6tables)"
			remember_dep "$_pkg"
		else
			fail "could not install $_pkg with opkg (no Internet on the router, or the package list has no $_pkg): see the report"; finish
		fi
	fi
fi
# the old prototype rule: it blackholes LAN traffic at boot ("guard inconsistent"). Removed only on request, with a backup.
_lr=$(p /etc/config/network)
if [ -f "$_lr" ] && grep -q "ts_block_lan_leak" "$_lr" 2>/dev/null; then
	_uci=${SETUP_UCI:-uci}
	_go=$RMRULE
	if [ "$_go" -eq 0 ] && interactive; then [ "$(ask "      The old rule 'ts_block_lan_leak' (LAN blackhole at boot) was found. Remove it? (backup is kept) (y/n)" n)" != y ] || _go=1; fi
	if [ "$_go" -eq 1 ] && have "$_uci"; then
		mkdir -p "$(p /root)" 2>/dev/null
		_bk=$(p /root/network.before-ts_block_lan_leak)
		if cp -p "$_lr" "$_bk" && "$_uci" -q delete network.ts_block_lan_leak && "$_uci" commit network; then
			ip rule del priority 5280 iif br-lan blackhole >/dev/null 2>&1 || true
			ok "removed the old rule 'ts_block_lan_leak' (backup: /root/network.before-ts_block_lan_leak)"
		else
			warn "could not remove the old rule 'ts_block_lan_leak'; remove it yourself (uci delete network.ts_block_lan_leak && uci commit network)"
		fi
	else
		warn "old rule 'ts_block_lan_leak' found in /etc/config/network: it can block the LAN briefly at boot. Remove it with --remove-legacy-rule (a backup is kept)"
	fi
fi
# An exit node the router ALREADY uses (GL.iNet's own Tailscale page, or set by hand). tsem starts in DIRECT and clears the exit node, so
# without a decision the traffic would suddenly leave directly. GL.iNet's gl_tailscale also re-applies its own setting on every
# interface event (tailscale up --reset --exit-node=...), which would fight with tsem's failover. Never decided silently.
_uci=${SETUP_UCI:-uci}
_tsc=${SETUP_TSC:-tailscale}
GL_EXIT=''
if have "$_uci"; then GL_EXIT=$("$_uci" -q get tailscale.settings.exit_node_ip 2>/dev/null | tr -cd '0-9.'); fi
LIVE_EXIT=0
if have "$_tsc" && "$_tsc" debug prefs 2>/dev/null | grep -q '"ExitNode\(ID\|IP\)": *"[^"]'; then LIVE_EXIT=1; fi
if [ "$FAILED" -eq 0 ] && [ ! -e "$(p /etc/tsem/intent)" ] && { [ -n "$GL_EXIT" ] || [ "$LIVE_EXIT" -eq 1 ]; }; then
	info "this router already uses an exit node${GL_EXIT:+ (GL.iNet setting: $GL_EXIT)}"
	if [ -z "$ADOPT" ]; then
		if interactive; then
			[ "$(ask "      Take it over (tsem keeps the traffic protected and goes straight to the exit-node mode)? (y/n)" y)" = y ] && ADOPT=1 || ADOPT=0
		else
			fail "this router already uses an exit node. Installing tsem now would clear it and the traffic would leave directly. Run again with --adopt-exit-node (tsem takes it over and goes straight to the exit-node mode, nothing leaves directly) or with --ignore-existing-exit-node (you accept the direct traffic). Nothing was changed."
			finish
		fi
	fi
	if [ "$ADOPT" -eq 1 ]; then
		[ "$ACTIVATE" -eq 1 ] || { fail "--adopt-exit-node needs the activation (do not combine with --no-activate)"; finish; }
		GERMAN=1
		[ -n "$PRIMARY" ] || PRIMARY=$GL_EXIT
		[ -n "$PRIMARY" ] || [ -n "$(sed -n 's/^TSEM_PRIMARY=//p' "$(p /etc/tsem/tsem.conf)" 2>/dev/null)" ] || { fail "the exit node in use cannot be read: give it with --primary"; finish; }
		info "adopting the exit node: tsem will go straight to the exit-node mode"
	else
		warn "the existing exit node is cleared when tsem starts: the traffic leaves directly until you switch to the exit-node mode"
	fi
fi
[ "$FAILED" -ne 0 ] || ok "the router can run tsem"

# ---------------------------------------------------------------- 2 install
step "Install (transactional)"
if sh "$HERE/install.sh" --root "$ROOT" --yes $INST_ARGS >"$WORK/install.out" 2>&1; then
	INSTALLED=1
	cat "$WORK/install.out" >>"$LOG"
	_n=$(grep -c '^  \(add\|update\)' "$WORK/install.out")
	grep -i 'note:\|skipped\|WARNING' "$WORK/install.out" | while IFS= read -r _l; do info "$_l"; done
	ok "$_n files installed; the boot link and the web UI entries are in place; nothing is started yet"
	# the hardware switch only calls the hook when the router's toggle button is set to it (the GUI writes the same setting)
	_uci=${SETUP_UCI:-uci}
	if [ -e "$(p /etc/gl-switch.d/tailscale-de.sh)" ] && have "$_uci"; then
		_hf=$("$_uci" -q get switch-button.@main[0].func 2>/dev/null)
		if [ -z "$_hf" ] && "$_uci" -q get switch-button.@main[0] >/dev/null 2>&1; then
			if "$_uci" set switch-button.@main[0].func=tailscale-de && "$_uci" commit switch-button; then
				mkdir -p "$(p /etc/tsem)"; : >"$(p /etc/tsem/hw-func-set)"
				info "the router's toggle button now runs the tsem hook (set switch-button func=tailscale-de)"
			fi
		elif [ "$_hf" != tailscale-de ] && [ -n "$_hf" ]; then
			warn "the toggle button is set to '$_hf': choose Tailscale in the GL web UI (Toggle button) to use the hardware switch for tsem"
		fi
	fi
else
	cat "$WORK/install.out" >>"$LOG"
	grep -i 'MISSING\|REFUSED\|CLASH\|failed\|rolled' "$WORK/install.out" | head -n 8 | while IFS= read -r _l; do info "$_l"; done
	fail "the installer stopped; it restored the previous state itself (see the report)"
	finish
fi

# ---------------------------------------------------------------- 3 exit nodes
step "Exit nodes"
conf_get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d '"'; }
resolve_node() { # NAME|IP -> "ip|name" (from tailscale), or "ip|" when only an address is given and tailscale cannot say
	_q=$1
	"$TSEM" nodes 2>/dev/null | awk -v q="$_q" '$1 == q || $2 == q { print $2 "|" $1; exit }'
}
NODES=$WORK/nodes
"$TSEM" nodes >"$NODES" 2>/dev/null || : >"$NODES"
_cur_p=$(conf_get TSEM_PRIMARY)
if [ -z "$PRIMARY" ] && [ -n "$_cur_p" ]; then
	ok "keeping the configured exit nodes (primary $_cur_p, secondary $(conf_get TSEM_SECONDARY))"
	# the saved names must be the tailnet names Tailscale shows now (an older setup may have saved the machine's own hostname)
	for _role in PRIMARY SECONDARY; do
		_ri=$(conf_get TSEM_$_role); _rn=$(conf_get TSEM_${_role}_NAME)
		[ -n "$_ri" ] || continue
		_rr=$(resolve_node "$_ri")
		if [ -n "${_rr#*|}" ] && [ "${_rr#*|}" != "$_rn" ] && [ "${_rr%%|*}" = "$_ri" ]; then
			"$TSEM" config set "TSEM_$_role=$_ri" "TSEM_${_role}_NAME=${_rr#*|}" >>"$LOG" 2>&1 && info "the name of the $_role exit node is now the one Tailscale shows: ${_rn:-none} -> ${_rr#*|}"
		fi
	done
else
	if [ -z "$PRIMARY" ] && interactive; then
		if [ -s "$NODES" ]; then
			say "      Exit nodes found in your tailnet:"
			_i=0
			while IFS= read -r _l; do _i=$((_i + 1)); say "        $_i) $_l"; done <"$NODES"
			_pick=$(ask "      Primary exit node (number or name)" 1)
			case $_pick in *[!0-9]*) PRIMARY=$_pick ;; *) PRIMARY=$(sed -n "${_pick}p" "$NODES" | awk '{print $1}') ;; esac
			_pick=$(ask "      Secondary exit node (number, name, or - for none)" -)
			case $_pick in -) SECONDARY='' ;; *[!0-9]*) SECONDARY=$_pick ;; *) SECONDARY=$(sed -n "${_pick}p" "$NODES" | awk '{print $1}') ;; esac
		else
			warn "no exit nodes can be listed (tailscale not running?)"
			PRIMARY=$(ask "      Primary exit node (Tailscale name or 100.x address, empty to skip)" "")
			[ -z "$PRIMARY" ] || SECONDARY=$(ask "      Secondary exit node (empty for none)" "")
		fi
		[ "$HAVE_SUBNETS" -eq 1 ] || { SUBNETS=$(ask "      IPv4 subnets behind your nodes that stay reachable while protected (empty for none)" ""); HAVE_SUBNETS=1; }
	fi
	if [ -z "$PRIMARY" ]; then
		warn "no exit node chosen: DIRECT works, the exit-node mode cannot start until you run: tsem config set TSEM_PRIMARY=<ip> TSEM_PRIMARY_NAME=<name>"
	else
		_pr=$(resolve_node "$PRIMARY")
		case $PRIMARY in *[!0-9.]*) [ -n "$_pr" ] || { fail "'$PRIMARY' is not a peer of this tailnet (tsem nodes lists them)"; undo_install; finish; } ;; esac
		[ -n "$_pr" ] || _pr="$PRIMARY|"
		_set="TSEM_PRIMARY=${_pr%%|*} TSEM_PRIMARY_NAME=${_pr#*|}"
		if [ -n "$SECONDARY" ]; then
			_sr=$(resolve_node "$SECONDARY")
			case $SECONDARY in *[!0-9.]*) [ -n "$_sr" ] || { fail "'$SECONDARY' is not a peer of this tailnet"; undo_install; finish; } ;; esac
			[ -n "$_sr" ] || _sr="$SECONDARY|"
			_set="$_set TSEM_SECONDARY=${_sr%%|*} TSEM_SECONDARY_NAME=${_sr#*|}"
		fi
		# shellcheck disable=SC2086
		if _o=$("$TSEM" config set $_set 2>&1); then ok "primary ${_pr%%|*}${SECONDARY:+, secondary ${_sr%%|*}} saved"; else fail "could not save the exit nodes: $_o"; undo_install; finish; fi
		if [ -n "$FALLBACKS" ]; then
			_nl="${_pr%%|*}${SECONDARY:+ ${_sr%%|*}}" _nn="${_pr#*|}"; _nn="${_nn:--}"
			[ -z "$SECONDARY" ] || { _x="${_sr#*|}"; _nn="$_nn ${_x:--}"; }
			for _fb in $FALLBACKS; do
				_fr=$(resolve_node "$_fb")
				case $_fb in *[!0-9.]*) [ -n "$_fr" ] || { fail "'$_fb' is not a peer of this tailnet"; undo_install; finish; } ;; esac
				[ -n "$_fr" ] || _fr="$_fb|"
				_x="${_fr#*|}"; _nl="$_nl ${_fr%%|*}"; _nn="$_nn ${_x:--}"
			done
			if _o=$("$TSEM" config set "TSEM_NODES=$_nl" "TSEM_NODE_NAMES=$_nn" 2>&1); then ok "exit nodes in order: $_nl"; else fail "could not save the exit node list: $_o"; undo_install; finish; fi
		fi
	fi
fi
if [ "$HAVE_SUBNETS" -eq 1 ]; then
	_t=$WORK/conf.new
	{ [ -f "$CONF" ] && cat "$CONF"; true; } | awk -v v="$SUBNETS" 'BEGIN{d=0} index($0,"TSEM_ALLOW_SUBNETS4=")==1 && !d {print "TSEM_ALLOW_SUBNETS4=\"" v "\""; d=1; next} {print} END{if(!d) print "TSEM_ALLOW_SUBNETS4=\"" v "\""}' >"$_t" &&
		cp "$_t" "$CONF" && ok "subnets that stay reachable while protected: ${SUBNETS:-none}" || fail "could not write the subnets"
fi

# the display name of the exit-node mode (GUI, Home Assistant, messages); the internal mode id stays "german"
conf_put() { # KEY VALUE (quoted)
	_t=$WORK/conf.put
	{ [ -f "$CONF" ] && cat "$CONF"; true; } | awk -v k="$1" -v v="$2" 'BEGIN{d=0} index($0,k "=")==1 && !d {print k "=\"" v "\""; d=1; next} {print} END{if(!d) print k "=\"" v "\""}' >"$_t" && cp "$_t" "$CONF"
}
if [ -n "$ADMIN" ]; then
	if conf_put TSEM_ADMIN_SUBNETS4 "$ADMIN"; then ok "the router stays reachable over: $ADMIN"; else fail "could not save the admin networks"; fi
fi
if [ -z "$MODE_LABEL" ] && interactive; then MODE_LABEL=$(ask "      Name for the exit-node mode shown in the GUI (e.g. Germany, Office VPN)" EXIT); fi
if [ -n "$MODE_LABEL" ] && [ "$MODE_LABEL" != "$(conf_get TSEM_MODE_LABEL)" ]; then
	if conf_put TSEM_MODE_LABEL "$MODE_LABEL"; then ok "the exit-node mode is called: $MODE_LABEL"; else fail "could not save the mode name"; fi
fi

# ---------------------------------------------------------------- 4 self test
step "Self test"
if [ -n "${SETUP_SELFTEST_CMD:-}" ]; then _o=$(sh -c "$SETUP_SELFTEST_CMD" 2>&1); _rc=$?; else _o=$("$TSEM" selftest 2>&1); _rc=$?; fi
printf '%s\n' "$_o" >>"$LOG"
printf '%s\n' "$_o" | grep '^WARN' | while IFS= read -r _l; do info "$_l"; done
if [ "$_rc" -eq 0 ]; then
	ok "$(printf '%s\n' "$_o" | tail -n 1)"
else
	printf '%s\n' "$_o" | grep '^FAIL' | while IFS= read -r _l; do info "$_l"; done
	fail "the self test found problems ($(printf '%s\n' "$_o" | tail -n 1))"
	if [ "$KEEP" -eq 1 ]; then say "      --keep-on-failure: the installation stays"; else undo_install; fi
	finish
fi
if [ -n "$(conf_get TSEM_PRIMARY)" ]; then
	if _o=$("$TSEM" verify-nodes 2>&1); then info "exit nodes verified (name, address, online, approved as exit node)"; else warn "exit node check: $(printf '%s\n' "$_o" | grep -v '^PASS' | head -n 2 | tr '\n' ' ')"; fi
fi

# adopting: put the previous exit node back when the setup fails (GL.iNet's own setting was not touched yet)
restore_exit() {
	[ "$ADOPT" = 1 ] || return 0
	# a running tsem would clear it again (DIRECT mode): stop it and do not start it at boot until the problem is solved
	"$INITD" stop >>"$LOG" 2>&1 || true
	"$INITD" disable >>"$LOG" 2>&1 || true
	say "      tsem is stopped and not started at boot (the installation stays): start it with /etc/init.d/tsem enable && /etc/init.d/tsem start"
	if [ -n "$GL_EXIT" ] && "$_tsc" set --exit-node="$GL_EXIT" >>"$LOG" 2>&1; then say "      the previous exit node $GL_EXIT is set again"
	else say "      WARNING: the previous exit node could not be set again; set it in the GL.iNet Tailscale page"; fi
}
# adopting, after the exit-node mode is proven: GL.iNet must not re-apply its own exit node (tailscale up --reset) and fight the failover
adopt_finish() {
	[ "$ADOPT" = 1 ] && [ -n "$GL_EXIT" ] && [ "$FAILED" -eq 0 ] || return 0
	case $(st state) in PRIMARY_ACTIVE | SECONDARY_ACTIVE) ;; *) return 0 ;; esac
	if have "$_uci" && mkdir -p "$(p /etc/tsem)" && printf '%s
' "$GL_EXIT" >"$(p /etc/tsem/gl-exit-node)" && "$_uci" -q delete tailscale.settings.exit_node_ip && "$_uci" commit tailscale; then
		ok "the GL.iNet Tailscale page no longer sets an exit node (was $GL_EXIT); uninstall.sh gives it back"
	else
		warn "could not clear the GL.iNet exit-node setting: clear it in the GL.iNet Tailscale page, otherwise it may fight tsem's failover"
	fi
}

# ---------------------------------------------------------------- 5 activate in DIRECT
step "Start the service (DIRECT mode)"
if [ "$ACTIVATE" -eq 0 ]; then
	warn "not started (--no-activate). Start later: /etc/init.d/tsem start"
else
	"$INITD" enable >>"$LOG" 2>&1 || true
	# adopting an exit node in use: the intent is the exit-node mode BEFORE the service starts, so DIRECT never happens
	if [ "$ADOPT" = 1 ]; then "$TSEM" set german --no-wait >>"$LOG" 2>&1 || true; fi
	# a running service keeps the OLD code in memory: after an update it must be restarted (stopping does not open the kill switch)
	_cmd=start
	# an update of a router that is protected right now keeps its mode: DIRECT is never passed through (kill switch stays on)
	KEEP=''
	if [ "$ADOPT" != 1 ] && "$INITD" running >/dev/null 2>&1; then
		case $(st mode) in german) KEEP=german ;; blocked) KEEP=blocked ;; esac
	fi
	if "$INITD" running >/dev/null 2>&1; then _cmd=restart; info "tsem was already running: restarting it so that the new version is used"; fi
	if "$INITD" "$_cmd" >>"$LOG" 2>&1; then STARTED=1; else fail "the service did not start"; fi
	if [ "$STARTED" -eq 1 ] && [ "$ADOPT" = 1 ]; then
		ok "service started; the exit-node mode follows next (the router already used an exit node, DIRECT is skipped)"
	elif [ "$STARTED" -eq 1 ] && [ -n "$KEEP" ]; then
		_i=0
		while [ "$_i" -lt "${SETUP_GERMAN_WAIT:-90}" ]; do
			[ "$KEEP" = blocked ] && break
			case $(st state) in PRIMARY_ACTIVE | SECONDARY_ACTIVE) break ;; esac
			_i=$((_i + 3)); sleep 3
		done
		if [ "$(st mode)" = "$KEEP" ] && [ "$(st guard)" != open ]; then
			ok "updated; the router stayed protected (mode $KEEP, state $(st state)); it was not switched to DIRECT"
		else
			fail "after the restart the mode is $(st mode) / guard $(st guard) instead of $KEEP"
		fi
	elif [ "$STARTED" -eq 1 ]; then
		"$TSEM" set direct --no-wait >>"$LOG" 2>&1 || true
		_i=0
		while [ "$_i" -lt 20 ]; do
			[ "$(st mode)" = direct ] && [ "$(st guard)" = open ] && break
			_i=$((_i + 1)); sleep 1
		done
		if [ "$(st mode)" = direct ] && [ "$(st guard)" = open ]; then
			_net=${SETUP_NETCHECK:-"ping -c 1 -W 3 1.1.1.1 || ping -c 1 -W 3 8.8.8.8"}
			if sh -c "$_net" >/dev/null 2>&1; then ok "running in DIRECT mode; the router still reaches the Internet"
			else fail "the service runs but the router no longer reaches the Internet"; fi
		else
			fail "the service did not reach DIRECT mode (mode=$(st mode), guard=$(st guard))"
		fi
	fi
	if [ "$FAILED" -ne 0 ] && [ -n "$KEEP" ]; then
		say "      the router was protected before the update and stays so (no switch to DIRECT); check: tsem status"
	elif [ "$FAILED" -ne 0 ]; then
		say "      putting the router back to DIRECT and stopping the service ..."
		"$TSEM" set direct --no-wait >>"$LOG" 2>&1 || true
		"$INITD" stop >>"$LOG" 2>&1 || true
		restore_exit
	fi
fi

# ---------------------------------------------------------------- 6 GERMAN
step "Exit-node mode"
if [ "$FAILED" -ne 0 ]; then say "      skipped (an earlier step failed)"
elif [ "$GERMAN" -eq 0 ]; then
	if [ "$ACTIVATE" -eq 1 ]; then ok "not requested: switch it on in the GUI or with 'tsem set german' when you are ready"; else say "      skipped"; fi
elif [ -z "$(conf_get TSEM_PRIMARY)" ]; then
	fail "the exit-node mode needs an exit node (use --primary)"
else
	"$TSEM" set german --no-wait >>"$LOG" 2>&1 || true
	_i=0
	while [ "$_i" -lt "${SETUP_GERMAN_WAIT:-90}" ]; do
		case $(st state) in PRIMARY_ACTIVE | SECONDARY_ACTIVE) break ;; esac
		_i=$((_i + 3)); sleep 3
	done
	case $(st state) in
	PRIMARY_ACTIVE | SECONDARY_ACTIVE) ok "the exit-node mode is active through $(st active_exit) (state $(st state))" ;;
	*)
		fail "the exit-node mode did not come up within ${SETUP_GERMAN_WAIT:-90}s (state $(st state)): going back to DIRECT so the router keeps working"
		"$TSEM" set direct --no-wait >>"$LOG" 2>&1 || true
		restore_exit ;;
	esac
	adopt_finish
fi
finish
