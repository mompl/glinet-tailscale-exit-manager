#!/bin/sh
# tsem uninstaller. Removing tsem REMOVES THE KILL SWITCH: afterwards the router uses its
# normal (direct) internet access. Tailscale's own configuration is left unchanged.
#
#   sh uninstall.sh [--root DIR] --yes [--purge]
#
# Order (so there is never a half-removed, half-protecting state):
#   1. stop the daemon (the guard stays until step 3)
#   2. remove boot symlinks
#   3. `tsem teardown`: remove hooks, chains and ip rules (kill switch off)
#   4. restore the original GL hook, remove the firewall include stanza
#   5. remove installed files that are unmodified (modified ones are moved to the backup dir)
# /etc/tsem/tsem.conf, mqtt.conf and the backup directory are kept unless --purge.

set -u
umask 022
ROOT=/ YES=0 PURGE=0
while [ $# -gt 0 ]; do
	case $1 in
	--root) [ $# -ge 2 ] || { echo "--root needs a value" >&2; exit 2; }; ROOT=$2; shift 2 ;;
	--yes) YES=1; shift ;;
	--purge) PURGE=1; shift ;;
	-h | --help) sed -n '2,16p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
R=${ROOT%/}
p() { printf '%s%s' "$R" "$1"; }
CONF_DIR=$(p /etc/tsem)
MANIFEST=$CONF_DIR/install.manifest
MARK_B='# tsem-begin (managed block, removed by uninstall)'
MARK_E='# tsem-end'
say() { printf '%s\n' "$*"; }
md5() { md5sum <"$1" | cut -c1-32; }

[ -f "$MANIFEST" ] || { say "no install manifest at $MANIFEST: nothing to uninstall"; exit 1; }
say "uninstall plan (root='$ROOT'):"
say "  stop daemon, remove boot symlinks"
say "  remove ALL tsem firewall/routing rules (kill switch OFF, internet becomes direct)"
awk -F'|' '$1 == "F" { print "  remove /" $2 } $1 == "B" { print "  restore original /" $2 }' "$MANIFEST"
grep -q '^S|firewall' "$MANIFEST" && say "  remove firewall include stanza"
[ "$PURGE" -eq 1 ] && say "  PURGE: also remove /etc/tsem (config, intent, backups)"
[ "$YES" -eq 1 ] || { say "dry run only. Re-run with --yes."; exit 0; }

# 1+2
if [ -x "$(p /etc/init.d/tsem-masq)" ] && [ -z "$R" ]; then
	/etc/init.d/tsem-masq stop >/dev/null 2>&1
	/etc/init.d/tsem-masq disable >/dev/null 2>&1
fi
if [ -x "$(p /etc/init.d/tsem)" ] && [ -z "$R" ]; then
	/etc/init.d/tsem stop >/dev/null 2>&1
	/etc/init.d/tsem disable >/dev/null 2>&1
fi
rm -f "$(p /etc/rc.d/S17tsem-restore)" "$(p /etc/rc.d/S18tsem)" "$(p /etc/rc.d/K10tsem)" "$(p /etc/rc.d/S96tsem-masq)" "$(p /etc/rc.d/K10tsem-masq)"

# 3: kill switch off, using the installed controller (works with whatever backend is configured)
if [ -f "$(p /usr/sbin/tsem)" ]; then
	TSEM_LIBDIR=${TSEM_LIBDIR:-$(p /usr/lib/tsem)} TSEM_CONF=${TSEM_CONF:-$(p /etc/tsem/tsem.conf)} \
		TSEM_STATE_DIR=${TSEM_STATE_DIR:-$CONF_DIR} sh "$(p /usr/sbin/tsem)" teardown ||
		{ say "ERROR: teardown failed; files are NOT removed so you can retry (tsem diag)"; exit 1; }
fi

# 4
FWF=$(p /etc/config/firewall)
if [ -f "$FWF" ] && grep -qF "$MARK_B" "$FWF"; then
	awk -v b="$MARK_B" -v e="$MARK_E" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip { print }' "$FWF" >"$FWF.tsem-tmp" && mv -f "$FWF.tsem-tmp" "$FWF"
	say "  removed firewall include stanza"
fi
# firmware-upgrade protection: drop the keep list and the kept package (nothing may restore tsem after this)
KEEP_B='# tsem-keep-begin (managed block, removed by uninstall)'
KEEP_E='# tsem-keep-end'
SUF=$(p /etc/sysupgrade.conf)
if [ -f "$SUF" ] && grep -qF "$KEEP_B" "$SUF"; then
	awk -v b="$KEEP_B" -v e="$KEEP_E" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip { print }' "$SUF" >"$SUF.tsem-tmp" && mv -f "$SUF.tsem-tmp" "$SUF"
	say "  removed the tsem keep list from /etc/sysupgrade.conf"
	grep -q '[^[:space:]]' "$SUF" || rm -f "$SUF" # nothing else in it (we created it)
fi
rm -f "$(p /lib/upgrade/keep.d/tsem)"
# the toggle button setting this setup made (only when it still has our value)
if [ -e "$CONF_DIR/hw-func-set" ] && command -v "${SETUP_UCI:-uci}" >/dev/null 2>&1; then
	_u=${SETUP_UCI:-uci}
	if [ "$("$_u" -q get switch-button.@main[0].func 2>/dev/null)" = tailscale-de ]; then
		"$_u" -q delete switch-button.@main[0].func && "$_u" commit switch-button && say "  gave the toggle button back (switch-button func removed)"
	fi
fi
rm -f "$CONF_DIR/hw-func-set"
# the exit node that GL.iNet's own Tailscale page had before setup took it over (setup --adopt-exit-node): give it back
if [ -s "$CONF_DIR/gl-exit-node" ] && command -v "${SETUP_UCI:-uci}" >/dev/null 2>&1; then
	_u=${SETUP_UCI:-uci}
	_ge=$(tr -cd '0-9.' <"$CONF_DIR/gl-exit-node")
	if [ -n "$_ge" ] && [ -z "$("$_u" -q get tailscale.settings.exit_node_ip 2>/dev/null)" ]; then
		if "$_u" set tailscale.settings.exit_node_ip="$_ge" && "$_u" commit tailscale; then
			say "  gave the exit node back to the GL.iNet Tailscale page ($_ge)"
			if command -v "${SETUP_TSC:-tailscale}" >/dev/null 2>&1; then "${SETUP_TSC:-tailscale}" set --exit-node="$_ge" >/dev/null 2>&1 || true; fi
		fi
	fi
fi
rm -f "$CONF_DIR/gl-exit-node"
rm -f "$CONF_DIR/deps"
rm -rf "$CONF_DIR/pkg" "$CONF_DIR/restore.log" "$CONF_DIR/restore-install.out" "$CONF_DIR/last-restore"
MOD=$CONF_DIR/backup/uninstall-modified
awk -F'|' '$1 == "B" { print $2 "|" $3 }' "$MANIFEST" | while IFS='|' read -r rel bf; do
	if [ -f "$bf" ]; then cp -p "$bf" "$(p "/$rel")" && say "  restored /$rel"; fi
done

# 5
awk -F'|' '$1 == "F" { print $2 "|" $3 }' "$MANIFEST" | while IFS='|' read -r rel sum; do
	f=$(p "/$rel")
	[ -e "$f" ] || continue
	# a file that was restored from a user-original backup above is theirs again: leave it
	if awk -F'|' -v r="$rel" '$1 == "B" && $2 == r { f = 1 } END { exit !f }' "$MANIFEST"; then continue; fi
	case $rel in etc/tsem/tsem.conf | etc/tsem/mqtt.conf) [ "$PURGE" -eq 1 ] || continue ;; esac
	if [ "$(md5 "$f")" = "$sum" ]; then
		rm -f "$f"
	else
		mkdir -p "$MOD/$(dirname "$rel")" && mv -f "$f" "$MOD/$rel" && say "  modified file kept: $MOD/$rel"
	fi
done
rm -f "$CONF_DIR/VERSION"
rmdir "$(p /usr/lib/tsem)" "$(p /www/luci-static/resources/view/tsem)" 2>/dev/null
# the API/GUI are gone: let rpcd/LuCI forget them (nothing else is touched)
if [ -z "$R" ] || [ -n "${TSEM_TEST_SERVICES:-}" ]; then
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	[ ! -x "${TSEM_RPCD_INIT:-/etc/init.d/rpcd}" ] || "${TSEM_RPCD_INIT:-/etc/init.d/rpcd}" reload >/dev/null 2>&1
fi
if [ "$PURGE" -eq 1 ]; then
	rm -rf "$CONF_DIR"
	say "purged /etc/tsem"
else
	rm -f "$MANIFEST" "$CONF_DIR/intent"
	say "kept /etc/tsem/tsem.conf and backups in /etc/tsem/backup"
fi
say "uninstalled. Kill switch is OFF. Tailscale exit-node setting was left unchanged:"
say "  to clear it:  tailscale set --exit-node="
