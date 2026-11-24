# shellcheck shell=sh
# Installer / uninstaller / rollback, into a throw-away root (--root).

mkroot() {
	RT=$T/root
	mkdir -p "$RT/etc/config" "$RT/etc/gl-switch.d" "$RT/etc/rc.d"
	printf "config defaults\n\toption input 'ACCEPT'\n\nconfig zone\n\toption name 'lan'\n" >"$RT/etc/config/firewall"
	printf '#!/bin/sh\n# GL prototype\necho proto\n' >"$RT/etc/gl-switch.d/tailscale-de.sh"
	chmod 755 "$RT/etc/gl-switch.d/tailscale-de.sh"
	export TSEM_INSTALL_STAMP=20260101-000001
	export PATH=$ROOT/tests/netns/bin:$PATH # `ip` shim: the sandbox has no iproute2
	# The installer only checks that iptables/ip6tables exist (preflight); runners
	# without them get presence-only stubs. They are never executed by the installer.
	mkdir -p "$T/fakebin"
	for _t in iptables ip6tables; do
		command -v $_t >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 0\n' >"$T/fakebin/$_t"; chmod +x "$T/fakebin/$_t"; }
	done
	PATH=$PATH:$T/fakebin; export PATH
}
inst() { "$SH" "$ROOT/install.sh" --root "$RT" "$@" >"$T/inst.out" 2>&1; }
uninst() { TSEM_BACKEND=mock "$SH" "$ROOT/uninstall.sh" --root "$RT" "$@" >"$T/uninst.out" 2>&1; }
snap() { (cd "$RT" && find . \( -type f -o -type l \) | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(md5sum <"$f" 2>/dev/null | cut -c1-32)"; done); }

_fresh() { rm -rf "$T/root" "$T/mock"; mkroot; }

test_dry_run_changes_nothing() {
	mkroot; _s=$(snap)
	inst || fail "dry run failed"
	assert_eq unchanged "$_s" "$(snap)"
	assert_contains plan "dry run only" "$(cat "$T/inst.out")"
}

test_install_creates_everything_and_starts_nothing() {
	mkroot
	inst --yes || fail "install failed: $(cat "$T/inst.out")"
	for f in usr/sbin/tsem usr/sbin/tsem-mqtt usr/lib/tsem/common.sh usr/lib/tsem/backend_ipt.sh usr/lib/tsem/fw-include.sh \
		usr/lib/tsem/tsem-switch.sh etc/init.d/tsem etc/hotplug.d/iface/50-tsem etc/tsem/tsem.conf etc/tsem/intent etc/tsem/install.manifest; do
		[ -f "$RT/$f" ] || fail "missing /$f"
	done
	assert_eq tsem-mode 755 "$(stat -c %a "$RT/usr/sbin/tsem")"
	assert_eq init-mode 755 "$(stat -c %a "$RT/etc/init.d/tsem")"
	assert_eq conf-mode 644 "$(stat -c %a "$RT/etc/tsem/tsem.conf")"
	assert_eq intent-mode 600 "$(stat -c %a "$RT/etc/tsem/intent")"
	[ -L "$RT/etc/rc.d/S18tsem" ] && [ -L "$RT/etc/rc.d/K10tsem" ] || fail "F05: the boot links must be created by default (the kill switch has to be in place after a reboot)"
	assert_eq "stanza count" 1 "$(grep -c "tsem-begin" "$RT/etc/config/firewall")"
	grep -q "option reload '1'" "$RT/etc/config/firewall" || fail "include must reload"
	grep -q "option name 'lan'" "$RT/etc/config/firewall" || fail "existing firewall config lost"
	[ ! -e "$T/mock/events" ] || fail "installer must not call any backend"
}

test_installed_controller_runs() {
	mkroot; inst --yes
	_o=$(TSEM_LIBDIR=$RT/usr/lib/tsem TSEM_STATE_DIR=$RT/etc/tsem "$SH" "$RT/usr/sbin/tsem" status)
	assert_contains intent 'intent=ok' "$_o"
	assert_contains mode 'mode=direct' "$_o"
	assert_contains src 'source=install' "$_o"
}

test_install_is_idempotent() {
	mkroot; inst --yes; _a=$(snap)
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes || fail "second install failed"
	_b=$(snap | grep -v '/backup/')
	assert_eq "files identical" "$(printf '%s\n' "$_a" | grep -v '/backup/' | grep -v 'install.manifest')" "$(printf '%s\n' "$_b" | grep -v 'install.manifest')"
	assert_eq "stanza count" 1 "$(grep -c "tsem-begin" "$RT/etc/config/firewall")"
	assert_eq seq 1 "$(sed -n 's/^seq=//p' "$RT/etc/tsem/intent")"
}

test_existing_config_and_intent_are_preserved() {
	mkroot; inst --yes
	printf 'TSEM_PRIMARY=100.1.2.3\n' >"$RT/etc/tsem/tsem.conf"
	( TSEM_STATE_DIR=$RT/etc/tsem TSEM_LIBDIR=$RT/usr/lib/tsem TSEM_RUN_DIR=$T/r TSEM_BACKEND=mock TSEM_MOCK_DIR=$T/m TSEM_CONF=/x TSEM_PRIMARY=100.1.2.3 TSEM_SYSLOG=0 \
		sh -c 'mkdir -p $TSEM_RUN_DIR $TSEM_MOCK_DIR; sh '"$RT"'/usr/sbin/tsem set german --no-wait --source ha' >/dev/null 2>&1 )
	_i=$(md5sum <"$RT/etc/tsem/intent")
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes
	assert_eq conf 'TSEM_PRIMARY=100.1.2.3' "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_eq intent "$_i" "$(md5sum <"$RT/etc/tsem/intent")"
}

test_gl_hook_is_installed_by_default_and_kept_on_request() {
	mkroot; _orig=$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")
	# F04: the hardware switch is a required function, so the default install puts the hook in place (original backed up)
	inst --yes || fail "default install failed: $(cat "$T/inst.out")"
	grep -q 'tsem-switch-hook v2' "$RT/etc/gl-switch.d/tailscale-de.sh" || fail "the hook was not installed by default"
	[ -f "$RT/etc/tsem/backup/20260101-000001/files/etc/gl-switch.d/tailscale-de.sh" ] || fail "original not backed up"
	uninst --yes || fail "uninstall failed: $(cat "$T/uninst.out")"
	assert_eq restored "$_orig" "$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")"
	# --keep-gl-hook is the explicit opt-out (the prototype stays untouched)
	_fresh; _orig=$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")
	inst --yes --keep-gl-hook || fail "keep-hook install failed: $(cat "$T/inst.out")"
	assert_eq untouched "$_orig" "$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")"
	grep -q "NOT replaced" "$T/inst.out" || true
	# the old flag still works
	_fresh; TSEM_INSTALL_STAMP=20260101-000002 inst --yes --replace-gl-hook || fail "replace failed"
	grep -q 'tsem set' "$RT/etc/gl-switch.d/tailscale-de.sh" || fail "hook not installed"
}

test_router_without_a_hardware_switch_gets_no_hook_and_still_installs() {
	mkroot; rm -rf "$RT/etc/gl-switch.d"
	inst --yes || fail "install on a router without switch support failed: $(cat "$T/inst.out")"
	[ ! -e "$RT/etc/gl-switch.d/tailscale-de.sh" ] || fail "a hook was installed although the router has no switch support"
	assert_contains note "no hardware switch support found" "$(cat "$T/inst.out")"
	[ -x "$RT/usr/sbin/tsem" ] || fail "the controller must be installed"
	# explicit --no-hw-switch also works where the support exists
	_fresh; inst --yes --no-hw-switch || fail "--no-hw-switch failed"
	grep -q 'tsem-switch-hook' "$RT/etc/gl-switch.d/tailscale-de.sh" && fail "hook installed despite --no-hw-switch"
	true
}

test_replaced_gl_hook_is_executable_and_original_mode_is_restored() {
	# GL's switch handler only runs executable scripts in /etc/gl-switch.d (it logs "can't be exec").
	mkroot; chmod 755 "$RT/etc/gl-switch.d/tailscale-de.sh"
	inst --yes --replace-gl-hook || fail "install failed: $(cat "$T/inst.out")"
	assert_eq hook-mode 755 "$(stat -c %a "$RT/etc/gl-switch.d/tailscale-de.sh")"
	uninst --yes || fail "uninstall failed"
	assert_eq restored-mode 755 "$(stat -c %a "$RT/etc/gl-switch.d/tailscale-de.sh")"
}

test_enable_creates_symlinks_without_starting() {
	mkroot; inst --yes --enable
	[ -L "$RT/etc/rc.d/S18tsem" ] && [ -L "$RT/etc/rc.d/K10tsem" ] || fail "boot symlinks missing"
	[ ! -e "$T/mock/events" ] || fail "nothing may be started or applied"
}

test_upgrade_then_rollback_restores_previous_version() {
	mkroot
	_src=$T/srccopy; mkdir -p "$_src"; cp -r "$ROOT/src" "$ROOT/contrib" "$ROOT/install.sh" "$_src/"
	"$SH" "$_src/install.sh" --root "$RT" --yes >/dev/null 2>&1
	_v1=$(md5sum <"$RT/usr/sbin/tsem")
	echo '# v2 change' >>"$_src/src/usr/sbin/tsem"
	TSEM_INSTALL_STAMP=20260101-000002 "$SH" "$_src/install.sh" --root "$RT" --yes >/dev/null 2>&1
	[ "$(md5sum <"$RT/usr/sbin/tsem")" != "$_v1" ] || fail "upgrade did not change the file"
	"$SH" "$_src/install.sh" --root "$RT" --rollback --yes >/dev/null 2>&1 || fail "rollback failed"
	assert_eq "v1 restored" "$_v1" "$(md5sum <"$RT/usr/sbin/tsem")"
}

test_aborted_install_leaves_clean_system_at_every_failure_point() {
	mkroot; _s=$(snap); _n=1; _failed=0
	while [ "$_n" -le 60 ]; do
		if TSEM_INSTALL_FAIL_AFTER=$_n inst --yes; then break; fi
		_failed=$((_failed + 1))
		_a=$(snap)
		[ "$_s" = "$_a" ] || { printf '%s\n' "$_s" >"$T/s.txt"; printf '%s\n' "$_a" >"$T/a.txt"; fail "failure point $_n left changes: $(diff "$T/s.txt" "$T/a.txt" | head -5 | tr '\n' ' ')"; }
		_n=$((_n + 1))
	done
	[ "$_failed" -ge 10 ] || fail "expected many failure points, only $_failed"
}

test_full_uninstall_restores_system() {
	mkroot; _s=$(snap)
	inst --yes --enable --replace-gl-hook
	uninst --yes || fail "uninstall failed: $(cat "$T/uninst.out")"
	_a=$(snap | grep -v '/etc/tsem/')
	assert_eq "system as before (except kept config/backups)" "$(printf '%s\n' "$_s")" "$(printf '%s\n' "$_a")"
	assert_eq "no stanza" 0 "$(grep -c tsem "$RT/etc/config/firewall")"
	[ -f "$RT/etc/tsem/tsem.conf" ] || fail "config must be kept without --purge"
}

test_uninstall_tears_down_guard_before_removing_files() {
	mkroot; inst --yes
	uninst --yes
	[ "$(ev_line 'guard-removed' first)" -gt 0 ] || fail "kill switch teardown was not called"
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "controller still present"
}

test_purge_removes_everything() {
	mkroot; _s=$(snap)
	inst --yes
	uninst --yes --purge
	assert_eq "pristine" "$(printf '%s\n' "$_s")" "$(snap)"
}

test_modified_files_are_kept_not_deleted() {
	mkroot; inst --yes
	echo '# local edit' >>"$RT/usr/lib/tsem/common.sh"
	uninst --yes
	[ ! -e "$RT/usr/lib/tsem/common.sh" ] || fail "modified file should have been moved"
	[ -f "$RT/etc/tsem/backup/uninstall-modified/usr/lib/tsem/common.sh" ] || fail "modified file was lost"
}

test_uninstall_without_yes_is_dry_run() {
	mkroot; inst --yes; _s=$(snap)
	uninst || fail "dry run failed"
	assert_eq unchanged "$_s" "$(snap)"
}

test_uninstall_without_manifest_refuses() {
	mkroot
	uninst --yes && fail "must refuse without a manifest"
	true
}

test_rollback_without_install_refuses() {
	mkroot
	inst --rollback --yes && fail "nothing to roll back"
	true
}

test_install_scripts_never_start_services() {
	! grep -nE '/etc/init.d/tsem (start|restart)|service tsem start|procd|reload_config|fw3 reload|/etc/init.d/firewall|/etc/init.d/network|/etc/init.d/tailscale' "$ROOT/install.sh" | grep -v '^[0-9]*:#' | grep -v 'say ' | grep -q . || fail "installer must not start/restart anything"
}

# fw3 config as found on root: tailscale0 zone with masquerading + LAN -> tailscale0 forwarding
fw3_root() {
	cat >"$RT/etc/config/firewall" <<'FW'
config defaults
	option input 'ACCEPT'
	option forward 'REJECT'

config zone
	option name 'lan'
	list network 'lan'

config zone 'tailscale0'
	option name 'tailscale0'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'
	option masq '1'
	option mtu_fix '1'
	list device 'tailscale0'

config forwarding 'lan_tailscale'
	option src 'lan'
	option dest 'tailscale0'
FW
}

test_installer_and_uninstaller_leave_fw3_masquerade_config_untouched() {
	mkroot; fw3_root; _orig=$(cat "$RT/etc/config/firewall")
	inst --yes --enable --replace-gl-hook || fail "install failed: $(cat "$T/inst.out")"
	grep -q "option masq '1'" "$RT/etc/config/firewall" || fail "masq lost after install"
	grep -q "config forwarding 'lan_tailscale'" "$RT/etc/config/firewall" || fail "lan_tailscale lost after install"
	# everything that was there stays byte-identical as a prefix; only the marker stanza is appended
	_new=$(cat "$RT/etc/config/firewall")
	case $_new in "$_orig"*) ;; *) fail "existing fw3 config was modified by the installer" ;; esac
	_added=${_new#"$_orig"}
	# the stanza holds exactly one include section by default (the controller; tsem-masq is opt-in); the masq OPTION, zones,
	# forwardings and the tailscale0 zone are never defined by it (the repair works on the existing zone at run time)
	_chk=$(printf '%s\n' "$_added" | grep -v "masq-include.sh" | grep -v "config include 'tsem_masq'")
	case $_chk in *masq*|*zone*|*forwarding*|*tailscale0*) fail "installer stanza must not define zones/masq/forwarding: $_added" ;; esac
	# the default component set does NOT contain tsem-masq: no masq include, no tsem-masq files, no masq boot link
	assert_eq "includes" 1 "$(printf '%s\n' "$_added" | grep -c '^config include')"
	[ ! -e "$RT/usr/sbin/tsem-masq" ] && [ ! -e "$RT/usr/lib/tsem/masq-include.sh" ] && [ ! -e "$RT/etc/init.d/tsem-masq" ] || fail "default install put the opt-in masq component on the router"
	case $_added in *tsem_masq*) fail "default install wrote the masq include" ;; esac
	# upgrade (second install) keeps it identical too
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes || fail "reinstall failed"
	case $(cat "$RT/etc/config/firewall") in "$_orig"*) ;; *) fail "reinstall modified the fw3 config" ;; esac
	assert_eq "single stanza" 1 "$(grep -c tsem-begin "$RT/etc/config/firewall")"
	uninst --yes || fail "uninstall failed: $(cat "$T/uninst.out")"
	assert_eq "fw3 config byte-identical after uninstall" "$_orig" "$(cat "$RT/etc/config/firewall")"
}

test_uninstall_purge_also_restores_fw3_masquerade_config() {
	mkroot; fw3_root; _orig=$(cat "$RT/etc/config/firewall")
	inst --yes
	uninst --yes --purge || fail "purge failed: $(cat "$T/uninst.out")"
	assert_eq "fw3 config after purge" "$_orig" "$(cat "$RT/etc/config/firewall")"
}

# ---- B2: interrupted installs are recoverable from the persistent journal ----
_snap_nb() { snap | grep -v '/backup/'; }
# make the installed files differ from the repository (like an older release), so an upgrade has many operations
_age_install() {
	for _f in usr/sbin/tsem usr/lib/tsem/common.sh usr/lib/tsem/state.sh usr/lib/tsem/conf.sh etc/init.d/tsem etc/hotplug.d/iface/50-tsem; do echo '# old release' >>"$RT/$_f"; done
	sed -i 's/^TSEM_VERSION=.*/TSEM_VERSION="0.1.0-rc2"/' "$RT/usr/lib/tsem/common.sh"
}
test_killed_install_leaves_a_marker_and_recover_restores_everything() {
	mkroot; inst --yes; printf 'TSEM_KEEP=1\n' >>"$RT/etc/tsem/tsem.conf"
	_age_install
	_s=$(_snap_nb)
	# the process dies (SIGKILL) in the middle of an upgrade
	TSEM_INSTALL_STAMP=20260101-000002 TSEM_INSTALL_KILL_AFTER=4 inst --yes
	[ -f "$RT/etc/tsem/backup/INPROGRESS" ] || fail "no INPROGRESS marker after a killed install"
	[ "$_s" != "$(_snap_nb)" ] || fail "kill happened before any change: test is void"
	# a new install refuses to run over a half-done one
	TSEM_INSTALL_STAMP=20260101-000003 inst --yes && fail "install ran over an interrupted one"
	assert_contains refuse "--recover" "$(cat "$T/inst.out")"
	inst --recover --yes || fail "recover failed: $(cat "$T/inst.out")"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker survived the recovery"
	assert_eq restored "$_s" "$(_snap_nb)"
	grep -q TSEM_KEEP=1 "$RT/etc/tsem/tsem.conf" || fail "config lost"
}
test_rollback_also_handles_a_pending_interrupted_install() {
	mkroot; inst --yes; _age_install; _s=$(_snap_nb)
	TSEM_INSTALL_STAMP=20260101-000002 TSEM_INSTALL_KILL_AFTER=3 inst --yes
	[ -f "$RT/etc/tsem/backup/INPROGRESS" ] || fail "no marker"
	inst --rollback --yes || fail "rollback with pending marker failed"
	assert_eq restored "$_s" "$(_snap_nb)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker survived"
	# the earlier, completed install is still the one that --rollback would undo
	[ "$(cat "$RT/etc/tsem/backup/LATEST")" = 20260101-000001 ] || fail "LATEST must still name the completed install"
}
test_recover_without_a_pending_install_changes_nothing() {
	mkroot; inst --yes; _s=$(snap)
	inst --recover --yes || fail "recover without pending install failed"
	assert_contains none "nothing to recover" "$(cat "$T/inst.out")"
	assert_eq same "$_s" "$(snap)"
}
test_lost_ssh_session_does_not_stop_a_running_install() {
	mkroot
	# a HUP in the middle of the transaction (ssh dropped) is ignored: the install completes consistently
	TSEM_INSTALL_SIGNAL_AFTER=3 inst --yes || fail "install died on SIGHUP: $(cat "$T/inst.out")"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left behind"
	[ -f "$RT/etc/tsem/install.manifest" ] || fail "no manifest: install did not finish"
	[ -f "$RT/etc/hotplug.d/iface/50-tsem" ] || fail "install incomplete"
}
test_failed_install_removes_its_marker_and_restores_the_manifest() {
	mkroot; inst --yes; _age_install; _s=$(_snap_nb)
	TSEM_INSTALL_STAMP=20260101-000002 TSEM_INSTALL_FAIL_AFTER=3 inst --yes && fail "simulated failure did not fail"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker left after an in-process rollback"
	assert_eq restored "$_s" "$(_snap_nb)"
}
test_successful_rollback_restores_the_previous_manifest() {
	mkroot; inst --yes; _age_install
	_s=$(_snap_nb)
	TSEM_INSTALL_STAMP=20260101-000002 inst --yes || fail "upgrade failed"
	inst --rollback --yes || fail "rollback failed"
	assert_eq restored "$_s" "$(_snap_nb)"
}



test_f05_autostart_is_default_verified_and_can_be_skipped() {
	_fresh; inst --yes
	[ -L "$RT/etc/rc.d/S18tsem" ] && [ -L "$RT/etc/rc.d/K10tsem" ] || fail "F05: no boot links after a default install"
	assert_eq link-target ../init.d/tsem "$(readlink "$RT/etc/rc.d/S18tsem")"
	assert_contains said "boot symlinks S18tsem/K10tsem" "$(cat "$T/inst.out")"
	# the service is never started by the installer
	[ ! -e "$T/mock/events" ] || fail "installer must not call any backend"
	# --no-enable is the explicit opt-out
	_fresh; inst --yes --no-enable
	[ ! -e "$RT/etc/rc.d/S18tsem" ] || fail "--no-enable still created the boot link"
	# the default dry run announces the links
	_fresh; inst >/dev/null 2>&1
	assert_contains plan "boot symlinks" "$(cat "$T/inst.out")"
	[ ! -e "$RT/etc/rc.d/S18tsem" ] || fail "the dry run created a link"
	# rollback removes exactly what the install created
	_fresh; inst --yes; "$SH" "$ROOT/install.sh" --root "$RT" --rollback --yes >/dev/null 2>&1
	[ ! -e "$RT/etc/rc.d/S18tsem" ] || fail "rollback left the boot link"
}
