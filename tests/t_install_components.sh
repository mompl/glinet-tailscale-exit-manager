# shellcheck shell=sh
# Component installs (core / api / gui), upgrade from an RC3-style install, rollback, interrupted installs,
# service reload, and "existing router settings are not touched". Everything runs in a throw-away root.

_inst_helpers() {
	[ -n "$(command -v mkroot)" ] || . "$ROOT/tests/t_install.sh"
}
_files() { snap | grep -v '/backup/' | grep -v 'install.manifest'; }

# an "RC3-style" source tree: the same installer, without the files that came with the API/GUI
_rc3_tree() {
	RC3=$T/rc3src
	mkdir -p "$RC3"
	cp -r "$ROOT/src" "$ROOT/contrib" "$RC3/"
	cp "$ROOT/install.sh" "$RC3/install.sh"
	rm -rf "$RC3/src/usr/libexec" "$RC3/src/usr/share" "$RC3/src/www" "$RC3/src/usr/sbin/tsem-api-check"
	sed -i 's/^TSEM_VERSION=.*/TSEM_VERSION=0.1.0-rc3.1/' "$RC3/src/usr/lib/tsem/common.sh"
}

test_api_or_gui_alone_needs_core() {
	_inst_helpers; mkroot; _s=$(snap)
	if inst --yes --components api; then fail "api without core must be refused"; fi
	assert_contains why "need the core component" "$(cat "$T/inst.out")"
	if inst --yes --components gui; then fail "gui without core must be refused"; fi
	assert_eq "nothing changed" "$_s" "$(snap)"
	if inst --yes --components bogus; then fail "unknown component must be refused"; fi
}

test_core_only_has_no_api_or_gui_files() {
	_inst_helpers; mkroot
	inst --yes --components core || fail "core install failed: $(cat "$T/inst.out")"
	[ -f "$RT/usr/sbin/tsem" ] || fail "core missing"
	[ ! -e "$RT/usr/libexec/rpcd/tsem" ] || fail "api file in a core-only install"
	[ ! -e "$RT/www/luci-static/resources/view/tsem/status.js" ] || fail "gui file in a core-only install"
	grep -q '^C|core$' "$RT/etc/tsem/install.manifest" || fail "component not recorded"
}

test_api_and_gui_can_be_added_later_without_touching_the_controller() {
	_inst_helpers; mkroot
	inst --yes --components core || fail "core failed"
	tsem_conf_sum=$(md5sum <"$RT/etc/tsem/tsem.conf")
	_intent=$(md5sum <"$RT/etc/tsem/intent")
	_core=$(_files)
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes --components api || fail "api failed: $(cat "$T/inst.out")"
	[ -x "$RT/usr/libexec/rpcd/tsem" ] || fail "plugin not executable"
	assert_eq plugin-mode 755 "$(stat -c %a "$RT/usr/libexec/rpcd/tsem")"
	[ -f "$RT/usr/share/rpcd/acl.d/tsem.json" ] || fail "acl missing"
	[ ! -e "$RT/www/luci-static/resources/view/tsem/status.js" ] || fail "gui installed without being asked"
	TSEM_INSTALL_STAMP=20260101-000003 inst --yes --components gui || fail "gui failed: $(cat "$T/inst.out")"
	[ -f "$RT/www/luci-static/resources/view/tsem/status.js" ] || fail "gui missing"
	[ -f "$RT/usr/share/luci/menu.d/luci-app-tsem.json" ] || fail "menu missing"
	assert_eq conf "$tsem_conf_sum" "$(md5sum <"$RT/etc/tsem/tsem.conf")"
	assert_eq intent "$_intent" "$(md5sum <"$RT/etc/tsem/intent")"
	assert_eq "stanza count" 1 "$(grep -c tsem-begin "$RT/etc/config/firewall")"
	# every core file is still in the manifest (uninstall needs them) together with the new ones
	for f in usr/sbin/tsem usr/lib/tsem/common.sh usr/libexec/rpcd/tsem www/luci-static/resources/view/tsem/status.js; do
		grep -q "^F|$f|" "$RT/etc/tsem/install.manifest" || fail "manifest lost $f"
	done
	grep -q '^S|firewall' "$RT/etc/tsem/install.manifest" || fail "manifest lost the firewall stanza record"
	for c in core api luci-gui; do grep -q "^C|$c\$" "$RT/etc/tsem/install.manifest" || fail "component $c not recorded"; done
	# the files that came from the core install are unchanged
	for f in $(printf '%s\n' "$_core" | cut -d' ' -f1); do
		case $f in ./etc/tsem/intent | ./etc/config/firewall) continue ;; esac
		printf '%s\n' "$(_files)" | grep -qF "$f " || fail "lost $f"
	done
}

test_rollback_of_an_api_install_returns_to_the_core_state() {
	_inst_helpers; mkroot
	inst --yes --components core || fail "core failed"
	_before=$(_files)
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes --components api,gui || fail "api,gui failed"
	TSEM_INSTALL_STAMP=20260101-000002 inst --rollback --yes || fail "rollback failed: $(cat "$T/inst.out")"
	assert_eq "state after rollback" "$_before" "$(_files)"
	if grep -q '^C|api$' "$RT/etc/tsem/install.manifest"; then fail "manifest still lists api"; fi
	[ -x "$RT/usr/sbin/tsem" ] || fail "core must survive"
}

test_full_install_then_uninstall_leaves_no_api_or_gui_file() {
	_inst_helpers; mkroot; _orig=$(_files)
	inst --yes || fail "install failed"
	[ -x "$RT/usr/sbin/tsem-api-check" ] || fail "api-check missing"
	TSEM_BACKEND=mock uninst --yes --purge || fail "uninstall failed: $(cat "$T/uninst.out")"
	_left=$(_files | grep -E 'rpcd|luci|www|tsem' | grep -v 'gl-switch.d')
	[ -z "$_left" ] || fail "left behind: $_left"
	[ ! -d "$RT/www/luci-static/resources/view/tsem" ] || fail "empty gui directory left behind"
}

test_interrupted_component_install_is_recovered() {
	_inst_helpers; mkroot
	inst --yes --components core || fail "core failed"
	_before=$(_files)
	TSEM_INSTALL_STAMP=20260101-000002 TSEM_INSTALL_KILL_AFTER=3 "$SH" "$ROOT/install.sh" --root "$RT" --yes --components api,gui >/dev/null 2>&1
	[ -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "interrupted install must leave its marker"
	if inst --yes --components api; then fail "a new install must refuse while one is pending"; fi
	inst --recover --yes || fail "recover failed: $(cat "$T/inst.out")"
	assert_eq "state after recover" "$_before" "$(_files)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker must be gone"
	TSEM_INSTALL_STAMP=20260101-000009 inst --yes --components api,gui || fail "install after recovery failed"
}

test_upgrade_from_rc3_keeps_config_intent_and_extnet_routes_and_is_reversible() {
	_inst_helpers; mkroot; _rc3_tree
	"$SH" "$RC3/install.sh" --root "$RT" --yes --enable --initial-mode german >"$T/rc3.out" 2>&1 || fail "rc3 install failed: $(cat "$T/rc3.out")"
	[ ! -e "$RT/usr/libexec/rpcd/tsem" ] || fail "fixture is not RC3-like"
	# the user's own configuration (incl. the remote-site subnets) must survive the upgrade byte for byte
	printf 'TSEM_PRIMARY=100.64.0.30\nTSEM_SECONDARY=100.64.0.31\nTSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24"\n' >"$RT/etc/tsem/tsem.conf"
	_conf=$(md5sum <"$RT/etc/tsem/tsem.conf")
	_intent=$(md5sum <"$RT/etc/tsem/intent")
	_rc3=$(_files)
	TSEM_INSTALL_STAMP=20260101-000005 inst --yes --enable || fail "upgrade failed: $(cat "$T/inst.out")"
	assert_eq conf "$_conf" "$(md5sum <"$RT/etc/tsem/tsem.conf")"
	assert_eq intent "$_intent" "$(md5sum <"$RT/etc/tsem/intent")"
	assert_eq version 1.0.0 "$(sed -n 's/^version=//p' "$RT/etc/tsem/install.manifest")"
	[ -x "$RT/usr/libexec/rpcd/tsem" ] || fail "api missing after upgrade"
	[ -L "$RT/etc/rc.d/S18tsem" ] || fail "boot link lost"
	grep -q "10.30.2.0/24" "$RT/etc/tsem/tsem.conf" || fail "remote-site subnets lost"
	# the upgraded installation answers (mock backend, real controller)
	_o=$(TSEM_LIBDIR=$RT/usr/lib/tsem TSEM_STATE_DIR=$RT/etc/tsem TSEM_CONF=$RT/etc/tsem/tsem.conf "$SH" "$RT/usr/sbin/tsem" status)
	assert_contains mode 'mode=german' "$_o"
	# rollback returns to the exact RC3 state
	TSEM_INSTALL_STAMP=20260101-000005 inst --rollback --yes || fail "rollback failed: $(cat "$T/inst.out")"
	assert_eq "rc3 state restored" "$_rc3" "$(_files)"
}

test_install_leaves_other_router_settings_untouched() {
	_inst_helpers; mkroot
	for f in tailscale glconfig network wireless rpcd uhttpd system; do printf 'config %s foo\n\toption x "%s"\n' "$f" "$f" >"$RT/etc/config/$f"; done
	mkdir -p "$RT/etc/gl-switch.d" "$RT/etc/init.d"
	printf '#!/bin/sh\necho other\n' >"$RT/etc/gl-switch.d/other.sh"
	_before=$(cd "$RT/etc/config" && for f in tailscale glconfig network wireless rpcd uhttpd system; do printf '%s %s\n' "$f" "$(md5sum <"$f")"; done; md5sum "$RT/etc/gl-switch.d/other.sh")
	inst --yes || fail "install failed"
	_after=$(cd "$RT/etc/config" && for f in tailscale glconfig network wireless rpcd uhttpd system; do printf '%s %s\n' "$f" "$(md5sum <"$f")"; done; md5sum "$RT/etc/gl-switch.d/other.sh")
	assert_eq "other settings unchanged" "$_before" "$_after"
}

test_service_reload_happens_once_and_restart_only_when_needed() {
	_inst_helpers; mkroot
	mkdir -p "$T/svc"
	printf '#!/bin/sh\necho "$1" >>%s/calls\n' "$T/svc" >"$T/svc/rpcd"; chmod +x "$T/svc/rpcd"
	# ubus: knows the object only after a "restart"
	printf '#!/bin/sh\n[ -e %s/restarted ] && { "%s" list; exit 0; }\nexit 1\n' "$T/svc" "$RT/usr/libexec/rpcd/tsem" >"$T/svc/ubus"; chmod +x "$T/svc/ubus"
	printf '#!/bin/sh\ncase "$1" in restart) : >%s/restarted ;; esac\necho "$1" >>%s/calls\n' "$T/svc" "$T/svc" >"$T/svc/rpcd"
	export PATH=$T/svc:$PATH TSEM_TEST_SERVICES=1 TSEM_RPCD_INIT=$T/svc/rpcd TSEM_RELOAD_WAIT=0
	inst --yes --components core || fail "core failed"
	[ ! -e "$T/svc/calls" ] || fail "core-only install must not touch rpcd"
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes --components api || fail "api failed"
	assert_eq calls "reload
restart" "$(cat "$T/svc/calls")"
	# plugin already known to rpcd -> reload is enough
	rm -f "$T/svc/calls"
	printf '#!/bin/sh\n"%s" list\n' "$RT/usr/libexec/rpcd/tsem" >"$T/svc/ubus"
	TSEM_INSTALL_STAMP=20260101-000003 inst --yes --components api,gui || fail "api,gui failed"
	assert_eq calls "reload" "$(cat "$T/svc/calls")"
	# plugin known but with an OLD method list (upgrade) -> restart is needed
	rm -f "$T/svc/calls"
	printf '#!/bin/sh\necho set_mode\n' >"$T/svc/ubus"
	TSEM_INSTALL_STAMP=20260101-000005 inst --yes --components api,gui || fail "stale-list install failed"
	assert_eq calls "reload
restart" "$(cat "$T/svc/calls")"
	# --no-service-reload never calls it
	rm -f "$T/svc/calls"
	TSEM_INSTALL_STAMP=20260101-000004 inst --yes --components api --no-service-reload || fail "failed"
	[ ! -e "$T/svc/calls" ] || fail "rpcd called despite --no-service-reload"
}

test_a_failing_service_reload_does_not_undo_the_install() {
	_inst_helpers; mkroot
	mkdir -p "$T/svc"
	printf '#!/bin/sh\nexit 1\n' >"$T/svc/rpcd"; chmod +x "$T/svc/rpcd"
	printf '#!/bin/sh\nexit 1\n' >"$T/svc/ubus"; chmod +x "$T/svc/ubus"
	export PATH=$T/svc:$PATH TSEM_TEST_SERVICES=1 TSEM_RPCD_INIT=$T/svc/rpcd TSEM_RELOAD_WAIT=0
	inst --yes || fail "install must succeed even if rpcd cannot be reloaded: $(cat "$T/inst.out")"
	assert_contains warn "WARNING" "$(cat "$T/inst.out")"
	[ -x "$RT/usr/libexec/rpcd/tsem" ] || fail "files must stay"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "no pending marker"
}

test_repeated_full_install_is_idempotent_and_keeps_api_files() {
	_inst_helpers; mkroot
	inst --yes; _a=$(_files)
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes || fail "second install failed"
	TSEM_INSTALL_STAMP=20260101-000003 inst --yes || fail "third install failed"
	assert_eq "files identical" "$_a" "$(_files)"
	for c in core api luci-gui; do assert_eq "C|$c once" 1 "$(grep -c "^C|$c\$" "$RT/etc/tsem/install.manifest")"; done
}

test_installed_api_answers_through_the_installed_controller() {
	command -v python3 >/dev/null 2>&1 || need_skip "python3 is not installed"
	_inst_helpers; mkroot
	inst --yes || fail "install failed"
	export PATH=$ROOT/tests/stubs:$PATH
	printf '#!/bin/sh\nTSEM_LIBDIR=%s TSEM_STATE_DIR=%s TSEM_CONF=%s exec "%s" "%s" "$@"\n' "$RT/usr/lib/tsem" "$RT/etc/tsem" "$RT/etc/tsem/tsem.conf" "$SH" "$RT/usr/sbin/tsem" >"$T/tsem-wrap"
	chmod +x "$T/tsem-wrap"
	_o=$(printf '{}' | TSEM_BIN=$T/tsem-wrap "$SH" "$RT/usr/libexec/rpcd/tsem" call status)
	assert_contains ok '"ok":true' "$_o"
	assert_contains mode '"mode":"direct"' "$_o"
}

# ---------------------------------------------------------------- firmware-upgrade protection
_wipe_like_sysupgrade() { # what a sysupgrade removes: everything except the kept files
	rm -rf "$RT/usr" "$RT/www" "$RT/etc/init.d/tsem" "$RT/etc/init.d/tsem-masq" "$RT/etc/hotplug.d" "$RT/etc/rc.d/S18tsem" "$RT/etc/rc.d/K10tsem" "$RT/etc/gl-switch.d/tailscale-de.sh" "$RT/etc/gl-switch.d/tsem"* "$RT/etc/rcd-keep-check"
}

test_install_keeps_a_package_copy_and_lists_it_for_sysupgrade() {
	_inst_helpers; mkroot
	printf '/etc/dropbear/\n/etc/other-user-entry' >"$RT/etc/sysupgrade.conf"
	inst --yes || fail "install failed: $(cat "$T/inst.out")"
	for f in install.sh setup.sh uninstall.sh restore.sh src/usr/sbin/tsem contrib/tsem-switch.sh; do [ -f "$RT/etc/tsem/pkg/$f" ] || fail "pkg/$f missing"; done
	[ -L "$RT/etc/rc.d/S17tsem-restore" ] || fail "restore boot link missing"
	[ -x "$RT/etc/init.d/tsem-restore" ] || fail "restore init script missing"
	_c=$(cat "$RT/etc/sysupgrade.conf")
	assert_contains user "/etc/other-user-entry" "$_c"
	assert_contains keep1 "/etc/tsem/" "$_c"
	assert_contains keep2 "/etc/init.d/tsem-restore" "$_c"
	assert_contains keep3 "/etc/rc.d/S17tsem-restore" "$_c"
	# idempotent: a second install keeps exactly one block
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes || fail "second install failed"
	assert_eq "one block" 1 "$(grep -c 'tsem-keep-begin' "$RT/etc/sysupgrade.conf")"
	assert_eq "user lines intact" 1 "$(grep -c '^/etc/other-user-entry$' "$RT/etc/sysupgrade.conf")"
}

test_no_upgrade_keep_option_adds_nothing() {
	_inst_helpers; mkroot
	inst --yes --no-upgrade-keep || fail "install failed"
	[ ! -e "$RT/etc/tsem/pkg" ] && [ ! -e "$RT/etc/sysupgrade.conf" ] && [ ! -e "$RT/etc/rc.d/S17tsem-restore" ] || fail "upgrade protection present despite --no-upgrade-keep"
}

test_rollback_and_uninstall_remove_the_upgrade_protection() {
	_inst_helpers; mkroot
	printf '/etc/dropbear/\n' >"$RT/etc/sysupgrade.conf"
	_before=$(md5sum <"$RT/etc/sysupgrade.conf")
	inst --yes || fail "install failed"
	inst --rollback --yes || fail "rollback failed"
	[ ! -e "$RT/etc/tsem/pkg" ] || fail "pkg left after rollback"
	[ ! -e "$RT/etc/rc.d/S17tsem-restore" ] || fail "link left after rollback"
	assert_eq "sysupgrade.conf restored" "$_before" "$(md5sum <"$RT/etc/sysupgrade.conf")"
	inst --yes || fail "reinstall failed"
	TSEM_BACKEND=mock uninst --yes || fail "uninstall failed: $(cat "$T/uninst.out")"
	[ ! -e "$RT/etc/tsem/pkg" ] || fail "pkg left after uninstall"
	[ ! -e "$RT/etc/rc.d/S17tsem-restore" ] || fail "link left after uninstall"
	[ ! -e "$RT/etc/init.d/tsem-restore" ] || fail "restore init script left after uninstall"
	if grep -q tsem "$RT/etc/sysupgrade.conf"; then fail "keep list left after uninstall"; fi
	assert_contains user "/etc/dropbear/" "$(cat "$RT/etc/sysupgrade.conf")"
}

test_restore_after_a_simulated_upgrade_brings_back_tsem_and_keeps_the_intent() {
	_inst_helpers; mkroot
	inst --yes || fail "install failed"
	printf 'TSEM_PRIMARY=100.64.0.7\n' >>"$RT/etc/tsem/tsem.conf"
	_intent=$(cat "$RT/etc/tsem/intent"); _conf=$(cat "$RT/etc/tsem/tsem.conf")
	_wipe_like_sysupgrade
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "wipe failed"
	# healthy installs are left alone
	TSEM_RESTORE_LOCK=$T/lock "$SH" "$RT/etc/tsem/pkg/restore.sh" --root "$RT" --no-start >"$T/restore.out" 2>&1 || fail "restore failed: $(cat "$T/restore.out")"
	[ -x "$RT/usr/sbin/tsem" ] && [ -f "$RT/usr/lib/tsem/common.sh" ] || fail "controller not restored: $(cat "$T/restore.out")"
	[ -f "$RT/usr/libexec/rpcd/tsem" ] || fail "api not restored"
	[ -L "$RT/etc/rc.d/S18tsem" ] || fail "boot link not restored"
	assert_eq "intent kept" "$_intent" "$(cat "$RT/etc/tsem/intent")"
	assert_contains conf "TSEM_PRIMARY=100.64.0.7" "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_contains log "restore finished" "$(cat "$RT/etc/tsem/restore.log")"
	assert_eq "components restored" "$(sed -n 's/^C|//p' "$RT/etc/tsem/install.manifest" | sort -u | tr '\n' ',' | sed 's/,$//')" "$(sed -n 's/^restored=//p' "$RT/etc/tsem/last-restore")"
	# a second run is a no-op
	_l=$(wc -l <"$RT/etc/tsem/restore.log")
	TSEM_RESTORE_LOCK=$T/lock "$SH" "$RT/etc/tsem/pkg/restore.sh" --root "$RT" --no-start >/dev/null 2>&1 || fail "second run failed"
	assert_eq "no-op when healthy" "$_l" "$(wc -l <"$RT/etc/tsem/restore.log")"
}

test_restore_does_nothing_without_a_manifest_and_reports_a_broken_package() {
	_inst_helpers; mkroot
	inst --yes || fail "install failed"
	_wipe_like_sysupgrade
	mv "$RT/etc/tsem/install.manifest" "$T/manifest.save"
	TSEM_RESTORE_LOCK=$T/lock "$SH" "$RT/etc/tsem/pkg/restore.sh" --root "$RT" --no-start >/dev/null 2>&1 || fail "must exit 0 without manifest"
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "must not install when tsem was never installed here"
	mv "$T/manifest.save" "$RT/etc/tsem/install.manifest"
	rm -rf "$RT/etc/tsem/pkg/src"
	if TSEM_RESTORE_LOCK=$T/lock "$SH" "$RT/etc/tsem/pkg/restore.sh" --root "$RT" --no-start >"$T/restore.out" 2>&1; then fail "a broken package must fail"; fi
	assert_contains critical "CRITICAL" "$(cat "$T/restore.out")"
}

test_restore_falls_back_to_fewer_components_when_the_gui_part_is_refused() {
	_inst_helpers; mkroot
	inst --yes || fail "install failed"
	_wipe_like_sysupgrade
	# make the full component set fail: the new firmware has no usable GL.iNet UI reference
	printf '#!/bin/sh\ncase "$*" in *luci-gui*) echo "refused (test)"; exit 1 ;; esac\nexec sh "%s" "$@"\n' "$RT/etc/tsem/pkg/install.real.sh" >"$T/wrap"
	mv "$RT/etc/tsem/pkg/install.sh" "$RT/etc/tsem/pkg/install.real.sh"
	cp "$T/wrap" "$RT/etc/tsem/pkg/install.sh"
	TSEM_RESTORE_LOCK=$T/lock "$SH" "$RT/etc/tsem/pkg/restore.sh" --root "$RT" --no-start >"$T/restore.out" 2>&1 || fail "fallback failed: $(cat "$T/restore.out")"
	[ -x "$RT/usr/sbin/tsem" ] || fail "controller must come back even if the GUI part is refused"
	assert_contains warn "WARNING" "$(cat "$T/restore.out")"
	_r=$(sed -n 's/^restored=//p' "$RT/etc/tsem/last-restore")
	case ",$_r," in *,luci-gui,*) fail "luci-gui must be dropped: $_r" ;; esac
	case ",$_r," in *,core,*) ;; *) fail "core missing: $_r" ;; esac
}
