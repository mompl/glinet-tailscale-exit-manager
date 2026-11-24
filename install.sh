#!/bin/sh
# tsem installer. Repeatable, transactional, never starts anything.
#
#   sh install.sh [--root DIR] [--yes] [--enable|--no-enable] [--keep-gl-hook] [--no-firewall-include]
#                 [--initial-mode direct|german] [--force] [--components core,api,luci-gui,masq] [--no-service-reload]
#                 [--no-native-gui] [--no-hw-switch] [--accept-undocumented-native-gui] [--native-index N] [--native-reference FILE]
#   sh install.sh --rollback [--root DIR] [--yes]      undo the LAST install/upgrade
#   sh install.sh --recover  [--root DIR] [--yes]      undo an install that was interrupted (killed, ssh lost)
#
# Without --yes it only prints the plan (dry run). Installation:
#  - copies files from ./src (+ contrib/tsem-switch.sh) after backing up any file it replaces
#  - never overwrites /etc/tsem/tsem.conf or /etc/tsem/mqtt.conf if present
#  - writes an initial intent (direct by default) WITHOUT touching firewall/tailscale
#  - adds a fw3 include stanza (marker-delimited) to /etc/config/firewall (backed up first)
#  - installs the switch hook as /etc/gl-switch.d/tailscale-de.sh (the hardware switch is a required function; --keep-gl-hook skips it)
#    (the original is backed up and restored by uninstall/rollback)
#  - creates the boot symlinks (S18tsem before firewall and network, K10tsem) so the kill switch is in place after every reboot;
#    --no-enable skips that. Installing NEVER starts the service (activation is a separate, verified step)
#  - components (default: core,api,native-gui,luci-gui, each one installable on its own; api and gui need core):
#      core  controller, init script, hotplug, hardware-switch hook, firewall include   (the kill switch)
#      api   local API: rpcd plugin "tsem" + rpcd ACL, tsem-api-check                   (ubus, authenticated)
#      luci-gui    LuCI view + menu entry (talks to the API only; "gui" is accepted as an alias)  [default]
#      masq  OPT-IN only (never part of the default): keeps LAN -> tailscale0 masquerading in place (tsem-masq, fw3 include,
#            hotplug, init). Not needed while the GL.iNet firmware keeps firewall.tailscale0.masq=1 itself.
#      native-gui  entry "Tailscale Exit Manager" in the GL.iNet web UI (APPLICATIONS, below Tailscale):
#                  ONLY ADDS files (menu entry, view bundle, RPC bridge); never edits a firmware file. It uses an
#                  extension interface GL.iNet does not document. It is part of the DEFAULT install (the GL.iNet UI under
#                  APPLICATIONS is the main GUI); where the firmware layout is missing it is skipped with the reason.
#                  --no-native-gui opts out. Named explicitly (--components native-gui) it needs
#                  --accept-undocumented-native-gui and refuses (changing nothing) if a prerequisite is missing.
#    Home Assistant is NOT part of this package (its integration is a separate module).
#  - api/gui files only add an rpcd plugin and static files; the running kill switch is never touched.
#    After installing api the rpcd service is reloaded (restarted if it does not pick the plugin up,
#    which logs out running web-UI sessions); --no-service-reload skips that.
# Any failure rolls the whole transaction back (write-ahead journal). While the transaction runs a
# marker /etc/tsem/backup/INPROGRESS names its journal and HUP/INT/TERM/PIPE are ignored, so a lost
# ssh session does not stop it half way. A process that is killed anyway (SIGKILL, power) leaves the
# marker: a new install refuses to start, and --recover (or --rollback) replays the journal.

set -u
umask 022
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=/ YES=0 ENABLE=1 HOOK=1 HOOK_AUTO=1 FW=1 MODE=install INITIAL=direct FORCE=0 RECOVER=0 COMPONENTS=core,api,native-gui,luci-gui NATIVE_DEFAULT=1 RELOAD=1 NATIVE_ACK=0 NATIVE_INDEX='' NATIVE_REF='' UKEEP=1
while [ $# -gt 0 ]; do
	case $1 in
	--root) [ $# -ge 2 ] || { echo "--root needs a value" >&2; exit 2; }; ROOT=$2; shift 2 ;;
	--yes) YES=1; shift ;;
	--enable) ENABLE=1; shift ;;
	--no-enable) ENABLE=0; shift ;;
	--replace-gl-hook) HOOK=1; HOOK_AUTO=0; shift ;;
	--no-hw-switch) HOOK=0; HOOK_AUTO=0; shift ;;
	--keep-gl-hook) HOOK=0; shift ;;
	--no-firewall-include) FW=0; shift ;;
	--initial-mode) INITIAL=${2:-}; shift 2 ;;
	--force) FORCE=1; shift ;;
	--components) [ $# -ge 2 ] || { echo "--components needs a value" >&2; exit 2; }; COMPONENTS=$2; NATIVE_DEFAULT=0; shift 2 ;;
	--no-native-gui) COMPONENTS=$(printf "%s" ",$COMPONENTS," | sed "s/,native-gui,/,/; s/^,//; s/,$//"); shift ;;
	--no-service-reload) RELOAD=0; shift ;;
	--no-upgrade-keep) UKEEP=0; shift ;;
	--accept-undocumented-native-gui) NATIVE_ACK=1; shift ;;
	--native-index) [ $# -ge 2 ] || { echo "--native-index needs a value" >&2; exit 2; }; NATIVE_INDEX=$2; shift 2 ;;
	--native-reference) [ $# -ge 2 ] || { echo "--native-reference needs a value" >&2; exit 2; }; NATIVE_REF=$2; shift 2 ;;
	--rollback) MODE=rollback; shift ;;
	--recover) MODE=rollback; RECOVER=1; shift ;;
	-h | --help) sed -n '2,26p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
case $INITIAL in direct | german) ;; *) echo "invalid --initial-mode" >&2; exit 2 ;; esac
[ -n "$COMPONENTS" ] || { echo "--components needs at least one of core,api,native-gui,luci-gui,masq" >&2; exit 2; }
_norm=''
for _c in $(printf '%s' "$COMPONENTS" | tr ',' ' '); do
	case $_c in
	gui) _c=luci-gui ;;
	core | api | native-gui | luci-gui | masq) ;;
	home-assistant) echo "home-assistant is a separate module and is not installed by install.sh (see docs/rc/home-assistant.md)" >&2; exit 2 ;;
	*) echo "unknown component: $_c (core, api, native-gui, luci-gui, masq)" >&2; exit 2 ;;
	esac
	_norm=${_norm:+$_norm,}$_c
done
COMPONENTS=$_norm
case $NATIVE_INDEX in '' | *[!0-9]*) [ -z "$NATIVE_INDEX" ] || { echo "--native-index must be a number" >&2; exit 2; } ;; esac
R=${ROOT%/}
p() { printf '%s%s' "$R" "$1"; }

STAMP=${TSEM_INSTALL_STAMP:-$(date +%Y%m%d-%H%M%S)}
CONF_DIR=$(p /etc/tsem)
BK=$CONF_DIR/backup/$STAMP
MANIFEST=$CONF_DIR/install.manifest
MARK_B='# tsem-begin (managed block, removed by uninstall)'
MARK_E='# tsem-end'
OPS=0

say() { printf '%s\n' "$*"; }
md5() { md5sum <"$1" | cut -c1-32; }

# ---------------------------------------------------------------- transaction
J=''
jlog() { printf '%s\n' "$*" >>"$J"; }

tick_fail_point() { # test hook: abort after N operations
	OPS=$((OPS + 1))
	# test hooks (simulate a killed process / a lost ssh session after N operations)
	if [ -n "${TSEM_INSTALL_KILL_AFTER:-}" ] && [ "$OPS" -ge "$TSEM_INSTALL_KILL_AFTER" ]; then kill -9 $$; fi
	if [ -n "${TSEM_INSTALL_SIGNAL_AFTER:-}" ] && [ "$OPS" -eq "$TSEM_INSTALL_SIGNAL_AFTER" ]; then kill -HUP $$; fi
	if [ -n "${TSEM_INSTALL_FAIL_AFTER:-}" ] && [ "$OPS" -ge "$TSEM_INSTALL_FAIL_AFTER" ]; then
		say "simulated failure after $OPS operations"
		return 1
	fi
	return 0
}

replay_back() { # journal file: undo in reverse order
	_rj=$1
	[ -f "$_rj" ] || return 0
	# portable reverse (no tac on busybox): number the lines and sort descending
	awk '{ print NR "\t" $0 }' "$_rj" | sort -rn | cut -f2- | while IFS= read -r _l; do
		_k=${_l%%|*}
		_rest=${_l#*|}
		case $_k in
		created) rm -f "$(p "$_rest")" ;;
		backed) # rel|backupfile
			_rel=${_rest%%|*}
			_bf=${_rest#*|}
			if [ -f "$_bf" ]; then mkdir -p "$(dirname "$(p "$_rel")")"; cp -p "$_bf" "$(p "$_rel")"; fi
			;;
		stanza) strip_stanza ;;
		pkg) # previous copy of the kept package ("" = there was none)
			rm -rf "$(p /etc/tsem/pkg)"
			if [ -n "$_rest" ] && [ -d "$_rest" ]; then mv "$_rest" "$(p /etc/tsem/pkg)"; fi
			;;
		esac
	done
}

strip_stanza() {
	_fwf=$(p /etc/config/firewall)
	[ -f "$_fwf" ] || return 0
	awk -v b="$MARK_B" -v e="$MARK_E" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip { print }' "$_fwf" >"$_fwf.tsem-tmp" &&
		mv -f "$_fwf.tsem-tmp" "$_fwf"
}

abort_rollback() {
	say "ERROR: $1 -- rolling back"
	replay_back "$J"
	rm -rf "$BK"
	rm -f "$CONF_DIR/backup/INPROGRESS"
	rmdir "$CONF_DIR/backup" 2>/dev/null
	exit 1
}

# ------------------------------------------------------------------ file list
list_files_all() { (cd "$HERE/src" && find . -type f | sed 's|^\./||' | sort); }
component_of() {
	case $1 in
	usr/libexec/rpcd/* | usr/share/rpcd/acl.d/* | usr/sbin/tsem-api-check) echo api ;;
	www/luci-static/* | usr/share/luci/*) echo luci-gui ;;
	usr/lib/oui-httpd/rpc/* | www/views/* | usr/share/oui/*) echo native-gui ;;
	usr/sbin/tsem-masq | usr/lib/tsem/masq-include.sh | etc/init.d/tsem-masq | etc/hotplug.d/iface/51-tsem-masq) echo masq ;;
	*) echo core ;;
	esac
}
has_comp() { case ",$COMPONENTS," in *",$1,"*) return 0 ;; esac; return 1; }
list_files() { list_files_all | while IFS= read -r _lf; do if has_comp "$(component_of "$_lf")"; then printf '%s\n' "$_lf"; fi; done; }
mode_of() {
	case $1 in
	usr/sbin/* | usr/libexec/rpcd/* | etc/init.d/* | etc/hotplug.d/*/* | etc/gl-switch.d/* | usr/lib/tsem/fw-include.sh | usr/lib/tsem/masq-include.sh | usr/lib/tsem/tsem-switch.sh) echo 755 ;;
	*) echo 644 ;;
	esac
}
is_user_config() { case $1 in etc/tsem/tsem.conf | etc/tsem/mqtt.conf) return 0 ;; esac; return 1; }

# install_file SRC REL
install_file() {
	_src=$1 _rel=$2
	_dst=$(p "/$_rel")
	if is_user_config "$_rel" && [ -e "$_dst" ]; then say "  keep   /$_rel (existing configuration)"; return 0; fi
	if [ -f "$_dst" ] && [ "$(md5 "$_dst")" = "$(md5 "$_src")" ]; then
		say "  same   /$_rel"
		NEWMAN="$NEWMAN
F|$_rel|$(md5 "$_src")"
		return 0
	fi
	tick_fail_point || return 1
	mkdir -p "$(dirname "$_dst")" || return 1
	if [ -e "$_dst" ]; then
		mkdir -p "$BK/files/$(dirname "$_rel")" || return 1
		cp -p "$_dst" "$BK/files/$_rel" || return 1
		jlog "backed|/$_rel|$BK/files/$_rel"
		# a file we did not install ourselves is a user original: remember it for uninstall
		if ! grep -q "^F|$_rel|" "$MANIFEST" 2>/dev/null; then
			NEWMAN="$NEWMAN
B|$_rel|$BK/files/$_rel"
		fi
		say "  update /$_rel (backup kept)"
	else
		jlog "created|/$_rel"
		say "  add    /$_rel"
	fi
	cp "$_src" "$_dst.tsem-new" || return 1
	chmod "$(mode_of "$_rel")" "$_dst.tsem-new" || return 1
	mv -f "$_dst.tsem-new" "$_dst" || return 1
	NEWMAN="$NEWMAN
F|$_rel|$(md5 "$_dst")"
}

# ---------------------------------------------------------------------- plan
preflight() {
	_bad=0
	# a router without any hardware-switch support gets no hook (the switch is optional; GUI, CLI and Home Assistant switch the mode)
	if [ "$HOOK" -eq 1 ] && [ "$HOOK_AUTO" -eq 1 ] && [ ! -d "$(p /etc/gl-switch.d)" ] && [ ! -e "$(p /etc/config/switch-button)" ]; then
		HOOK=0; say "  note: no hardware switch support found on this router (no /etc/gl-switch.d, no switch-button config): hook not installed; the mode is set by GUI, CLI or Home Assistant"
	fi
	for c in flock md5sum iptables ip awk sed; do
		command -v "$c" >/dev/null 2>&1 || { say "  MISSING required tool: $c"; _bad=1; }
	done
	command -v tailscale >/dev/null 2>&1 || say "  note: tailscale not found in PATH"
	command -v ip6tables >/dev/null 2>&1 || say "  note: ip6tables not found (IPv6 protection impossible if IPv6 is enabled)"
	command -v mosquitto_pub >/dev/null 2>&1 || say "  note: mosquitto-client not installed (needed only for Home Assistant)"
	if [ "$R" = "" ] && [ -e /etc/gl-switch.d/tailscale-de.sh ] && [ "$HOOK" -eq 0 ]; then
		say "  WARNING: /etc/gl-switch.d/tailscale-de.sh exists and is NOT replaced: two controllers would compete."
		say "           Remove --keep-gl-hook (the default replaces it; the original is backed up) or disable the prototype first."
	fi
	_others=$(printf '%s' "$COMPONENTS" | tr ',' '\n' | grep -vx masq)
	if [ -n "$_others" ] && ! has_comp core && [ ! -f "$(p /usr/sbin/tsem)" ]; then
		say "  MISSING: components '$COMPONENTS' need the core component (install core first or add it to --components)"
		_bad=1
	fi
	if has_comp luci-gui && ! has_comp api && [ ! -f "$(p /usr/libexec/rpcd/tsem)" ]; then
		say "  note: the luci-gui needs the api component (not installed, not selected)"
	fi
	if has_comp native-gui; then
		if [ "$NATIVE_DEFAULT" -eq 1 ]; then
			# part of the default install (the GL.iNet UI under APPLICATIONS is the main GUI): choosing the default is the
			# acknowledgement. Where the firmware layout is not there (not a GL.iNet 4.x UI, a clash, no menu reference) the
			# component is skipped with the reason, LuCI and everything else are still installed.
			NATIVE_ACK=1
			if ! native_preflight; then say "  note: native-gui skipped (reasons above); the default install continues without it. Install it later with --components native-gui"; COMPONENTS=$(printf "%s" ",$COMPONENTS," | sed "s/,native-gui,/,/; s/^,//; s/,$//"); fi
		else native_preflight || _bad=1; fi
	fi
	if [ "$_bad" -eq 1 ] && [ "$FORCE" -ne 1 ]; then say "preflight failed (use --force to ignore)"; return 1; fi
	return 0
}

# ---------------------------------------------------------------- native GL.iNet GUI
NATIVE_MENU_REL=usr/share/oui/menu.d/tsem.json
NATIVE_GZ_REL=www/views/gl-sdk4-ui-tsem.common.js.gz
NATIVE_REFERENCE=''

# the Tailscale entry of the GL.iNet menu is the reference: its fields (parent, icon, mode) are copied, not guessed
find_native_reference() {
	NATIVE_FALLBACK=0
	if [ -n "$NATIVE_REF" ]; then NATIVE_REFERENCE=$NATIVE_REF; [ -f "$NATIVE_REFERENCE" ]; return; fi
	# 1. the Tailscale entry itself: view, title or name mentions tailscale (case-insensitive; the firmware's exact key is not
	#    assumed to be view=tailscale). Its fields (parent, icon, level, mode) are copied, not guessed.
	for _mf in "$(p /usr/share/oui/menu.d)"/*.json; do
		[ -f "$_mf" ] || continue
		[ "$(basename "$_mf")" = tsem.json ] && continue
		_mc=$(cat "$_mf")
		for _mk in view title name; do
			_mv=$(jsonfilter -s "$_mc" -e "@.$_mk" 2>/dev/null | tr 'A-Z' 'a-z')
			case $_mv in *tailscale*) NATIVE_REFERENCE=$_mf; return 0 ;; esac
		done
	done
	# 2. no Tailscale entry: copy the fields from a real sibling under APPLICATIONS (never invented values). The new entry
	#    then goes to the END of that group (position below Tailscale cannot be honoured; reported).
	for _mf in "$(p /usr/share/oui/menu.d)"/*.json; do
		[ -f "$_mf" ] || continue
		[ "$(basename "$_mf")" = tsem.json ] && continue
		_mc=$(cat "$_mf")
		if [ "$(jsonfilter -s "$_mc" -e '@.parent' 2>/dev/null | tr 'A-Z' 'a-z')" = applications ]; then NATIVE_REFERENCE=$_mf; NATIVE_FALLBACK=1; return 0; fi
	done
	return 1
}
# highest index among the entries that share the reference's parent (used for the fallback placement)
native_max_index() {
	_par=$(jf parent)
	_max=0
	for _mf in "$(p /usr/share/oui/menu.d)"/*.json; do
		[ -f "$_mf" ] || continue
		[ "$(basename "$_mf")" = tsem.json ] && continue
		_mc=$(cat "$_mf")
		[ "$(jsonfilter -s "$_mc" -e '@.parent' 2>/dev/null)" = "$_par" ] || continue
		_i=$(jsonfilter -s "$_mc" -e '@.index' 2>/dev/null)
		case $_i in '' | *[!0-9]*) continue ;; esac
		[ "$_i" -le "$_max" ] || _max=$_i
	done
	echo "$_max"
}
native_default_index() {
	if [ "${NATIVE_FALLBACK:-0}" -eq 1 ]; then echo $(($(native_max_index) + 1)); else echo $(($(jf index) + 1)); fi
}
jf() { jsonfilter -s "$(cat "$NATIVE_REFERENCE")" -e "@.$1" 2>/dev/null; }

native_preflight() {
	_nb=0
	if [ "$NATIVE_ACK" -ne 1 ]; then
		say "  REFUSED native-gui: it uses an extension interface GL.iNet does not document (menu entry, view bundle and RPC object"
		say "           are only ADDED, no firmware file is changed). Read docs/native-gui.md, run the read-only preflight,"
		say "           then repeat with --accept-undocumented-native-gui. LuCI (luci-gui) stays available without this."
		return 1
	fi
	for _nd in usr/share/oui/menu.d usr/lib/oui-httpd/rpc www/views; do
		[ -d "$(p "/$_nd")" ] || { say "  MISSING for native-gui: /$_nd (this is not a firmware with the expected GL.iNet 4.x UI layout)"; _nb=1; }
	done
	command -v gzip >/dev/null 2>&1 || { say "  MISSING for native-gui: gzip"; _nb=1; }
	command -v jsonfilter >/dev/null 2>&1 || { say "  MISSING for native-gui: jsonfilter"; _nb=1; }
	if ! has_comp api && [ ! -f "$(p /usr/libexec/rpcd/tsem)" ]; then say "  MISSING for native-gui: the api component (the bridge calls it)"; _nb=1; fi
	if [ "$_nb" -eq 0 ]; then
		if find_native_reference; then
			for _k in parent level; do
				[ -n "$(jf $_k)" ] || { say "  MISSING for native-gui: field '$_k' in the reference menu entry $NATIVE_REFERENCE"; _nb=1; }
			done
			if [ "${NATIVE_FALLBACK:-0}" -eq 1 ]; then
				say "  note: no Tailscale entry found; the fields come from the sibling $NATIVE_REFERENCE and the tsem entry goes to the end of APPLICATIONS (UNVERIFIED placement; use --native-index N to choose)"
			elif [ -z "$NATIVE_INDEX" ]; then
				case $(jf index) in '' | *[!0-9]*) say "  MISSING for native-gui: no numeric index in the reference entry; give --native-index N"; _nb=1 ;; esac
			fi
		else
			say "  MISSING for native-gui: no menu entry for Tailscale and no entry under parent \"applications\" found in /usr/share/oui/menu.d (or --native-reference FILE is unreadable)."
			say "           Without it the position and parent of the new entry would be a guess; nothing is installed."
			_nb=1
		fi
	fi
	# never take over a file somebody else put there
	for _nf in $NATIVE_MENU_REL $NATIVE_GZ_REL www/views/gl-sdk4-ui-tsem.common.js usr/lib/oui-httpd/rpc/tsem; do
		if [ -e "$(p "/$_nf")" ] && ! grep -q "^F|$_nf|" "$MANIFEST" 2>/dev/null; then
			say "  CLASH: /$_nf exists and was not installed by tsem; not replacing it"; _nb=1
		fi
	done
	[ "$_nb" -eq 0 ]
}

# writes the generated files (menu entry, gzip copy of the view) into $1; they are then installed like any other file
native_generate() {
	_gd=$1
	mkdir -p "$_gd" || return 1
	_idx=$NATIVE_INDEX
	[ -n "$_idx" ] || _idx=$(native_default_index)
	{
		printf '{\n'
		printf '\t"index": %s,\n' "$_idx"
		printf '\t"view": "tsem",\n'
		printf '\t"title": "Tailscale Exit Manager",\n'
		printf '\t"level": %s,\n' "$(jf level)"
		printf '\t"parent": "%s"' "$(jf parent)"
		for _fk in parent_icon parent_index show_mode; do
			_fv=$(jf $_fk)
			[ -n "$_fv" ] || continue
			case $_fv in '['* | '{'* | [0-9]* | true | false) printf ',\n\t"%s": %s' "$_fk" "$_fv" ;; *) printf ',\n\t"%s": "%s"' "$_fk" "$_fv" ;; esac
		done
		printf '\n}\n'
	} >"$_gd/menu.json" || return 1
	gzip -9nc "$HERE/src/www/views/gl-sdk4-ui-tsem.common.js" >"$_gd/view.gz" || return 1
}

# Make a freshly installed API/GUI visible: rpcd scans its plugins when it starts, LuCI caches its menu.
# Failures here never undo the installation (files are in place, nothing of the kill switch is involved).
# true when rpcd already serves EVERY method the installed plugin advertises (after an upgrade rpcd may keep the old list)
plugin_methods_live() {
	ubus list tsem >/dev/null 2>&1 || return 1
	_pl=$(p /usr/libexec/rpcd/tsem)
	[ -x "$_pl" ] || return 0
	_live=$(ubus -v list tsem 2>/dev/null)
	for _m in $("$_pl" list 2>/dev/null | grep -o '"[a-z_0-9]*":' | tr -d '":'); do
		case "$_live" in *"$_m"*) ;; *) return 1 ;; esac
	done
	return 0
}

reload_services() {
	[ -z "$R" ] || [ -n "${TSEM_TEST_SERVICES:-}" ] || return 0
	if has_comp luci-gui; then rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null; fi
	# The GL.iNet web server (nginx + Lua) keeps the RPC bridge module in memory: a graceful reload makes it load the new one.
	# Sessions stay (they live in gl-ngx-session); nothing is restarted.
	if has_comp native-gui && [ "$RELOAD" -eq 1 ]; then
		_ng=${TSEM_NGINX_INIT:-/etc/init.d/nginx}
		if [ -x "$_ng" ]; then
			_wo=$(pidof nginx 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')
			"$_ng" reload >/dev/null 2>&1
			sleep "${TSEM_RELOAD_WAIT:-1}"
			# the GL.iNet init script's "reload" can return 0 without replacing the workers (they keep the old Lua module):
			# then signal the master process directly (HUP = graceful: new workers start, old ones finish their requests)
			if [ "$_wo" = "$(pidof nginx 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')" ] && [ -z "${TSEM_NGINX_INIT:-}" ]; then
				_mp=$(ps w 2>/dev/null | awk '/nginx: master/ && !/awk/ { print $1; exit }')
				[ -z "$_mp" ] || kill -HUP "$_mp" 2>/dev/null
			fi
			say "  web server reloaded gracefully (it picks up the new GUI bridge; web sessions stay)"
		fi
	fi
	has_comp api || return 0
	if [ "$RELOAD" -ne 1 ]; then say "  note: rpcd not reloaded (--no-service-reload); run: /etc/init.d/rpcd restart"; return 0; fi
	_ri=${TSEM_RPCD_INIT:-/etc/init.d/rpcd}
	[ -x "$_ri" ] || { say "  note: $_ri not found; the API is available after rpcd restarts"; return 0; }
	"$_ri" reload >/dev/null 2>&1
	sleep "${TSEM_RELOAD_WAIT:-1}"
	if command -v ubus >/dev/null 2>&1 && ! plugin_methods_live; then
		say "  rpcd did not pick up the plugin on reload: restarting rpcd (running web-UI sessions are logged out)"
		_old=""; command -v pidof >/dev/null 2>&1 && _old=$(pidof rpcd 2>/dev/null)
		"$_ri" restart >/dev/null 2>&1
		sleep "${TSEM_RELOAD_WAIT:-1}"
		# GL.iNet's rpcd can outlive SIGTERM for several seconds and then keeps the old ubus object (stale method list):
		# give it time, then stop the leftovers of the OLD instance (pids seen before the restart) and restart once more
		if [ -n "$_old" ] && ! plugin_methods_live; then
			sleep "${TSEM_RPCD_STOP_WAIT:-6}"
			_left=""
			for _pid in $_old; do [ -d "/proc/$_pid" ] && _left="$_left $_pid"; done
			if [ -n "$_left" ]; then
				say "  old rpcd process(es) still running ($_left ): stopping them, then restarting rpcd again"
				kill -9 $_left 2>/dev/null
				sleep 1
				"$_ri" restart >/dev/null 2>&1
				sleep "${TSEM_RELOAD_WAIT:-1}"
			fi
		fi
		ubus list tsem >/dev/null 2>&1 || say "  WARNING: 'ubus list tsem' still shows nothing; check /usr/libexec/rpcd/tsem and the rpcd log"
	fi
	return 0
}

KEEP_B='# tsem-keep-begin (managed block, removed by uninstall)'
KEEP_E='# tsem-keep-end'
# Firmware-upgrade protection: a sysupgrade wipes everything that is not listed in /etc/sysupgrade.conf. Keep /etc/tsem
# (config, intent, a copy of this package in /etc/tsem/pkg) and the tiny boot script that re-installs tsem afterwards.
# All changes are journaled (rolled back with the install, removed by uninstall.sh).
upgrade_keep() {
	_pk=$(p /etc/tsem/pkg)
	if [ ! -f "$HERE/src/etc/init.d/tsem-restore" ] || { [ "$HERE" != "$_pk" ] && [ ! -f "$HERE/tools/tsem-restore.sh" ]; }; then
		say "  note   this package has no restore support (older package): no firmware-upgrade protection added"
		return 0
	fi
	if [ "$HERE" != "$_pk" ]; then
		rm -rf "$_pk.new"
		mkdir -p "$_pk.new" || return 1
		cp -R "$HERE/src" "$HERE/contrib" "$_pk.new/" || return 1
		for _f in install.sh setup.sh uninstall.sh README.md LICENSE; do [ ! -f "$HERE/$_f" ] || cp "$HERE/$_f" "$_pk.new/$_f" || return 1; done
		cp "$HERE/tools/tsem-restore.sh" "$_pk.new/restore.sh" || return 1
		if [ -d "$_pk" ]; then
			jlog "pkg|$BK/pkg.prev"
			mv "$_pk" "$BK/pkg.prev" || return 1
		else
			jlog "pkg|"
		fi
		mv "$_pk.new" "$_pk" || return 1
		say "  add    /etc/tsem/pkg (copy of this package; used to restore tsem after a firmware upgrade)"
	fi
	mkdir -p "$(p /etc/rc.d)"
	if [ ! -e "$(p /etc/rc.d/S17tsem-restore)" ]; then
		ln -s ../init.d/tsem-restore "$(p /etc/rc.d/S17tsem-restore)" || return 1
		jlog "created|/etc/rc.d/S17tsem-restore"
	fi
	_sf=$(p /etc/sysupgrade.conf)
	_want=$(printf '%s\n%s\n%s\n%s\n%s\n' "$KEEP_B" "/etc/tsem/" "/etc/init.d/tsem-restore" "/etc/rc.d/S17tsem-restore" "$KEEP_E")
	_have=''
	[ ! -f "$_sf" ] || _have=$(awk -v b="$KEEP_B" -v e="$KEEP_E" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$_sf")
	if [ "$_have" = "$_want" ]; then say "  same   /etc/sysupgrade.conf keep list"; return 0; fi
	mkdir -p "$(dirname "$_sf")"
	if [ -f "$_sf" ]; then
		mkdir -p "$BK/files/etc"
		cp -p "$_sf" "$BK/files/etc/sysupgrade.conf" || return 1
		jlog "backed|/etc/sysupgrade.conf|$BK/files/etc/sysupgrade.conf"
		awk -v b="$KEEP_B" -v e="$KEEP_E" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip { print }' "$_sf" >"$_sf.tsem-tmp" && mv -f "$_sf.tsem-tmp" "$_sf" || return 1
		[ -z "$(tail -c1 "$_sf")" ] || echo >>"$_sf"
	else
		jlog "created|/etc/sysupgrade.conf"
	fi
	printf '%s\n' "$_want" >>"$_sf" || return 1
	say "  add    /etc/sysupgrade.conf keep list (/etc/tsem/ and the restore boot script survive a firmware upgrade)"
	return 0
}

do_install() {
	say "tsem installer: root='${ROOT}' components=$COMPONENTS mode=$([ $YES -eq 1 ] && echo INSTALL || echo DRY-RUN)"
	preflight || exit 1
	say "plan:"
	list_files | while IFS= read -r f; do say "  /$f"; done
	if has_comp core; then
		say "  /usr/lib/tsem/tsem-switch.sh  (hardware switch hook)"
		[ "$HOOK" -eq 1 ] && say "  /etc/gl-switch.d/tailscale-de.sh  (replaces the prototype; original backed up)"
		[ "$FW" -eq 1 ] && say "  firewall include stanza in /etc/config/firewall (backup first)"
		[ "$ENABLE" -eq 1 ] && say "  boot symlinks (service is NOT started)"
		[ "$UKEEP" -eq 1 ] && say "  firmware-upgrade protection: /etc/tsem/pkg, boot script tsem-restore, keep list in /etc/sysupgrade.conf"
		say "  initial intent: $INITIAL (written without applying anything)"
	fi
	if has_comp api; then say "  rpcd plugin + ACL: rpcd is reloaded afterwards (restarted only if it does not pick the plugin up)"; fi
	if has_comp native-gui; then
		say "  /$NATIVE_MENU_REL  (generated from $NATIVE_REFERENCE; index $([ -n "$NATIVE_INDEX" ] && echo "$NATIVE_INDEX" || echo "$(($(jf index) + 1))"))"
		say "  /$NATIVE_GZ_REL  (gzip copy of the view)"
		say "  native-gui only ADDS files; no GL.iNet firmware file is modified; the web server is only reloaded gracefully"
	fi
	if [ "$YES" -ne 1 ]; then say "dry run only; nothing changed. Re-run with --yes."; exit 0; fi

	if [ -e "$CONF_DIR/backup/INPROGRESS" ]; then
		say "ERROR: an interrupted install ($(cat "$CONF_DIR/backup/INPROGRESS" 2>/dev/null)) is pending. Run: sh install.sh --recover --yes"
		exit 1
	fi
	mkdir -p "$CONF_DIR" "$BK" || exit 1
	J=$BK/journal
	: >"$J"
	trap '' HUP INT TERM PIPE
	echo "$STAMP" >"$CONF_DIR/backup/INPROGRESS" || { rm -rf "$BK"; exit 1; }
	NEWMAN=''
	# carry over user-original backups recorded by earlier installs
	if [ -f "$MANIFEST" ]; then NEWMAN=$(grep '^B|' "$MANIFEST"); fi
	CARRY_OLD=0
	[ ! -f "$MANIFEST" ] || CARRY_OLD=1

	list_files >"$BK/.files" || abort_rollback "cannot list sources"
	while IFS= read -r f; do
		install_file "$HERE/src/$f" "$f" || abort_rollback "installing /$f failed"
	done <"$BK/.files"
	rm -f "$BK/.files"
	if has_comp native-gui; then
		native_generate "$BK/gen" || abort_rollback "cannot generate the native GUI files"
		install_file "$BK/gen/menu.json" "$NATIVE_MENU_REL" || abort_rollback "installing the native menu entry failed"
		install_file "$BK/gen/view.gz" "$NATIVE_GZ_REL" || abort_rollback "installing the native view copy failed"
		rm -rf "$BK/gen"
	fi
	if has_comp core; then
		install_file "$HERE/contrib/tsem-switch.sh" usr/lib/tsem/tsem-switch.sh || abort_rollback "installing switch hook failed"
		if [ "$HOOK" -eq 1 ]; then
			install_file "$HERE/contrib/tsem-switch.sh" etc/gl-switch.d/tailscale-de.sh || abort_rollback "replacing GL hook failed"
		fi
	fi

	if { has_comp core || has_comp masq; } && [ "$FW" -eq 1 ]; then
		FWF=$(p /etc/config/firewall)
		# one managed block; its content follows the components that are (now or earlier) installed
		_wc=0 _wm=0
		{ has_comp core || grep -q '^C|core$' "$MANIFEST" 2>/dev/null; } && _wc=1
		{ has_comp masq || grep -q '^C|masq$' "$MANIFEST" 2>/dev/null; } && _wm=1
		stanza_text() {
			printf '%s\n' "$MARK_B"
			[ "$_wc" -eq 0 ] || printf "config include 'tsem'\n\toption type 'script'\n\toption path '/usr/lib/tsem/fw-include.sh'\n\toption reload '1'\n"
			[ "$_wm" -eq 0 ] || printf "config include 'tsem_masq'\n\toption type 'script'\n\toption path '/usr/lib/tsem/masq-include.sh'\n\toption reload '1'\n"
			printf '%s\n' "$MARK_E"
		}
		_have=''
		[ ! -f "$FWF" ] || _have=$(awk -v b="$MARK_B" -v e="$MARK_E" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$FWF")
		_want=$(stanza_text)
		if [ -f "$FWF" ] && [ "$_have" = "$_want" ]; then
			say "  same   firewall include stanza"
			NEWMAN="$NEWMAN
S|firewall|"
		elif [ -f "$FWF" ]; then
			tick_fail_point || abort_rollback "simulated failure"
			mkdir -p "$BK/files/etc/config"
			cp -p "$FWF" "$BK/files/etc/config/firewall" || abort_rollback "firewall backup failed"
			if [ -n "$_have" ]; then
				# existing block with other content (component added later): restore the backup on rollback
				jlog "backed|/etc/config/firewall|$BK/files/etc/config/firewall"
				strip_stanza
			else
				jlog "stanza|"
			fi
			[ -z "$(tail -c1 "$FWF")" ] || echo >>"$FWF"
			stanza_text >>"$FWF" || abort_rollback "firewall include failed"
			say "  add    firewall include stanza"
			NEWMAN="$NEWMAN
S|firewall|$BK/files/etc/config/firewall"
		else
			say "  note: $FWF not found; no firewall include added"
		fi
	fi

	# Real intent code with a throw-away mock backend: nothing on the system is applied.
	intent_tool() { # args for tsem; prints nothing, returns tsem's rc
		_it_tmp=$(mktemp -d) || return 1
		mkdir -p "$_it_tmp/m" "$_it_tmp/r"
		TSEM_BACKEND=mock TSEM_MOCK_DIR=$_it_tmp/m TSEM_RUN_DIR=$_it_tmp/r TSEM_STATE_DIR=$CONF_DIR TSEM_LIBDIR=$(p /usr/lib/tsem) \
			TSEM_CONF=/nonexistent TSEM_SYSLOG=0 TSEM_PRIMARY=${TSEM_PRIMARY:-100.64.0.1} \
			sh "$(p /usr/sbin/tsem)" "$@" >"$_it_tmp/out" 2>&1
		_it_rc=$?
		INTENT_OUT=$(cat "$_it_tmp/out")
		rm -rf "$_it_tmp"
		return "$_it_rc"
	}
	if ! has_comp core; then
		:  # api/gui components only: the controller state (intent, firewall, boot links) is not touched
	elif [ -e "$CONF_DIR/intent" ]; then
		if intent_tool intent-check; then
			say "  keep   /etc/tsem/intent (existing user state, valid)"
		else
			# A leftover/corrupt intent is NOT silently replaced (that could turn an unknown state into DIRECT)
			# and NOT silently kept as if it were fine: a copy is saved, the file stays untouched, and tsem
			# treats it as BLOCKED until the user decides with `tsem set german|direct`.
			cp -p "$CONF_DIR/intent" "$CONF_DIR/intent.invalid-$STAMP" 2>/dev/null && jlog "created|/etc/tsem/intent.invalid-$STAMP"
			say "  WARNING: existing /etc/tsem/intent is INVALID ($(printf '%s' "$INTENT_OUT" | sed -n 's/.*reason=\([a-z-]*\).*/\1/p' | head -n 1)); copy saved as intent.invalid-$STAMP."
			say "           Left untouched. tsem treats it as BLOCKED (never DIRECT). Decide explicitly: tsem set german|direct"
		fi
	else
		tick_fail_point || abort_rollback "simulated failure"
		jlog "created|/etc/tsem/intent"
		if intent_tool set "$INITIAL" --source install --no-wait && intent_tool intent-check; then
			say "  add    /etc/tsem/intent ($INITIAL, verified readable)"
		else
			abort_rollback "could not write a valid initial intent"
		fi
	fi

	if has_comp core && [ "$ENABLE" -eq 1 ]; then
		mkdir -p "$(p /etc/rc.d)"
		for l in S18tsem K10tsem; do
			if [ ! -e "$(p /etc/rc.d/$l)" ]; then
				ln -s ../init.d/tsem "$(p /etc/rc.d/$l)" || abort_rollback "enable failed"
				jlog "created|/etc/rc.d/$l"
			fi
		done
		if [ -L "$(p /etc/rc.d/S18tsem)" ] && [ -L "$(p /etc/rc.d/K10tsem)" ]; then say "  add    boot symlinks S18tsem/K10tsem (autostart at boot; not started now)"; else abort_rollback "boot symlinks were not created"; fi
	fi
	if has_comp core && [ "$UKEEP" -eq 1 ]; then
		upgrade_keep || abort_rollback "firmware-upgrade protection could not be set up"
	fi
	if has_comp masq && [ "$ENABLE" -eq 1 ]; then
		mkdir -p "$(p /etc/rc.d)"
		for l in S96tsem-masq K10tsem-masq; do
			if [ ! -e "$(p /etc/rc.d/$l)" ]; then
				ln -s ../init.d/tsem-masq "$(p /etc/rc.d/$l)" || abort_rollback "enable failed"
				jlog "created|/etc/rc.d/$l"
			fi
		done
		say "  add    boot symlinks for tsem-masq (not started)"
	fi

	if [ -f "$MANIFEST" ]; then
		cp -p "$MANIFEST" "$BK/install.manifest.prev" || abort_rollback "manifest backup failed"
		jlog "backed|/etc/tsem/install.manifest|$BK/install.manifest.prev"
	else
		jlog "created|/etc/tsem/install.manifest"
	fi
	echo "$STAMP" >"$CONF_DIR/backup/LATEST"
	printf '%s\n' "v=1" "version=$(sed -n 's/^TSEM_VERSION=//p' "$HERE/src/usr/lib/tsem/common.sh")" "stamp=$STAMP" >"$MANIFEST.new"
	printf '%s\n' "$NEWMAN" | grep -v '^$' | sort -u >"$MANIFEST.cur"
	if [ "$CARRY_OLD" -eq 1 ]; then
		# entries of components that were not part of this run stay in the manifest (uninstall/rollback need them)
		awk -F'|' 'NR == FNR { if ($1 == "F") have[$2] = 1; if ($1 == "S") haveS = 1; next }
			$1 == "F" && !($2 in have) { print } $1 == "S" && !haveS { print } $1 == "C" { print }' "$MANIFEST.cur" "$MANIFEST" >"$MANIFEST.carry" && cat "$MANIFEST.carry" >>"$MANIFEST.cur"
		rm -f "$MANIFEST.carry"
	fi
	for _c in $(printf '%s' "$COMPONENTS" | tr ',' ' '); do printf 'C|%s\n' "$_c" >>"$MANIFEST.cur"; done
	sort -u "$MANIFEST.cur" >>"$MANIFEST.new"
	rm -f "$MANIFEST.cur"
	mv -f "$MANIFEST.new" "$MANIFEST"
	rm -f "$CONF_DIR/backup/INPROGRESS"
	reload_services
	say "installed ($COMPONENTS). Nothing of the kill switch was started. Next steps (see docs/rc/install-rollback.md):"
	if has_comp core; then
		say "  1. edit /etc/tsem/tsem.conf (set TSEM_PRIMARY / TSEM_SECONDARY) or use the GUI / tsem config set"
		say "  2. sh /usr/sbin/tsem selftest"
		say "  3. /etc/init.d/tsem start    (autostart at boot is already enabled; starting now is a separate, deliberate step)"
	fi
	if has_comp api; then say "  API: ubus call tsem status   (read-only users need the rpcd ACL tsem-read, writers tsem-write; see docs/api.md)"; fi
	if has_comp luci-gui; then say "  GUI: LuCI > Services > Tailscale Exit Manager (needs LuCI; see docs/gui.md)"; fi
	if has_comp native-gui; then say "  Native GUI: GL.iNet UI > APPLICATIONS > Tailscale Exit Manager (reload the page; if it stays empty see docs/native-gui.md)"; fi
	return 0
}

do_rollback() {
	_pending=0
	if [ -f "$CONF_DIR/backup/INPROGRESS" ]; then
		_pending=1
		_st=$(cat "$CONF_DIR/backup/INPROGRESS")
		say "an interrupted install is pending ($_st): undoing exactly that one"
	elif [ "$RECOVER" -eq 1 ]; then
		say "no interrupted install pending; nothing to recover"
		exit 0
	elif [ -f "$CONF_DIR/backup/LATEST" ]; then
		_st=$(cat "$CONF_DIR/backup/LATEST")
	else
		say "nothing to roll back (no install journal)"
		exit 1
	fi
	_j=$CONF_DIR/backup/$_st/journal
	[ -f "$_j" ] || { say "no journal for the last install"; exit 1; }
	say "rollback of install $_st:"
	awk -F'|' '{ print "  undo " $1 " " $2 }' "$_j"
	[ "$YES" -eq 1 ] || { say "dry run only. Re-run with --yes."; exit 0; }
	trap '' HUP INT TERM PIPE
	replay_back "$_j"
	mv -f "$_j" "$_j.rolled-back"
	if [ "$_pending" -eq 1 ]; then rm -f "$CONF_DIR/backup/INPROGRESS"; else rm -f "$CONF_DIR/backup/LATEST"; fi
	say "rolled back. (The service is untouched; run uninstall.sh to remove the kill switch.)"
	COMPONENTS=api,luci-gui reload_services
}

if [ "$MODE" = rollback ]; then do_rollback; else do_install; fi
