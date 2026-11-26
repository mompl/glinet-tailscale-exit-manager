# shellcheck shell=sh
# One-step setup (setup.sh): the steps, the choices, the final result and the failure handling, into a throw-away root
# with the mock backend. It proves the orchestration; the real router run is the hardware acceptance.

_su_env() {
	[ -n "$(command -v mkroot)" ] || . "$ROOT/tests/t_install.sh"
	mkroot
	mkdir -p "$RT/etc/init.d" "$RT/etc/rc.d"
	unset TSEM_PRIMARY TSEM_SECONDARY
	export TSEM_CONF="$RT/etc/tsem/tsem.conf" TSEM_BIN="$RT/usr/sbin/tsem" TSEM_INITD="$RT/etc/init.d" TSEM_RC_D="$RT/etc/rc.d"
	export TSEM_LAN_IFACES=lo TSEM_TS_IFACE=lo TSEM_BACKEND=mock
	printf '#!/bin/sh\necho "$@" >>%s/initd.calls\n[ "$1" != running ] || [ -e %s/service-running ]\n' "$T" "$T" >"$T/initd"; chmod +x "$T/initd"
	mkdir -p "$T/ts"; export TS_STUB_DIR="$T/ts"
	printf '#!/bin/sh
echo "PASS stub: the real selftest is covered by the netns suite"
echo "selftest: 0 failed, 0 warnings"
' >"$T/selftest-ok"
	printf '#!/bin/sh
echo "FAIL autostart: stub"
echo "selftest: 1 failed, 0 warnings"
exit 1
' >"$T/selftest-bad"
	chmod +x "$T/selftest-ok" "$T/selftest-bad"
	export SETUP_SELFTEST_CMD="$T/selftest-ok"
	export SETUP_INITD="$T/initd" SETUP_NETCHECK=true SETUP_GERMAN_WAIT=3
	PATH=$ROOT/tests/stubs:$PATH; export PATH
	printf 'node-a|100.64.0.10|true|true|a\nnode-b|100.64.0.11|true|true|b\n' >"$TSEM_MOCK_DIR/peers"
	REPORT=$T/report.txt
}
_su() { "$SH" "$ROOT/setup.sh" --root "$RT" --report "$REPORT" "$@" >"$T/setup.out" 2>&1; }

test_setup_installs_configures_tests_starts_in_direct_and_reports_success() {
	_su_env
	_su --yes --primary node-a --secondary node-b || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains result "RESULT: SUCCESS" "$(cat "$T/setup.out")"
	[ -x "$RT/usr/sbin/tsem" ] || fail "tsem was not installed"
	assert_contains primary "TSEM_PRIMARY=100.64.0.10" "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_contains primary-name "TSEM_PRIMARY_NAME=node-a" "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_contains secondary "TSEM_SECONDARY=100.64.0.11" "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_contains started "start" "$(cat "$T/initd.calls")"
	assert_eq direct direct "$("$TSEM_BIN" status | sed -n 's/^mode=//p')"
	assert_contains report "RESULT: SUCCESS" "$(cat "$REPORT")"
	assert_contains steps "[6/6] Exit-node mode" "$(cat "$T/setup.out")"
}

test_setup_admin_subnet_is_saved_and_a_bad_value_is_refused() {
	_su_env
	_su --yes --primary node-a --admin-subnet 10.50.0.0/24 --admin-subnet 192.168.9.0/28 || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains saved 'TSEM_ADMIN_SUBNETS4="10.50.0.0/24 192.168.9.0/28"' "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_contains said "the router stays reachable over" "$(cat "$T/setup.out")"
	_su_env
	if _su --yes --admin-subnet '10.0.0.0/8;reboot'; then fail "a bad admin network must be refused"; fi
	assert_contains why "only IPv4 networks" "$(cat "$T/setup.out")"
}

test_setup_fallback_adds_further_exit_nodes_in_order() {
	_su_env
	printf 'node-a|100.64.0.10|true|true|a\nnode-b|100.64.0.11|true|true|b\nnode-c|100.64.0.12|true|true|c\n' >"$TSEM_MOCK_DIR/peers"
	_su --yes --primary node-a --secondary node-b --fallback node-c || fail "setup failed: $(cat "$T/setup.out")"
	_f=$(cat "$RT/etc/tsem/tsem.conf")
	assert_contains list "TSEM_NODES=100.64.0.10 100.64.0.11 100.64.0.12" "$_f"
	assert_contains names "TSEM_NODE_NAMES=node-a node-b node-c" "$_f"
	assert_contains older "TSEM_SECONDARY=100.64.0.11" "$_f"
	assert_contains said "exit nodes in order" "$(cat "$T/setup.out")"
	_su_env
	printf 'node-a|100.64.0.10|true|true|a\n' >"$TSEM_MOCK_DIR/peers"
	if _su --yes --primary node-a --fallback not-a-peer; then fail "an unknown fallback must fail the setup"; fi
	assert_contains why "is not a peer of this tailnet" "$(cat "$T/setup.out")"
}

test_setup_with_an_unknown_node_fails_and_restores_the_previous_state() {
	_su_env
	if _su --yes --primary does-not-exist; then fail "an unknown exit node must fail the setup"; fi
	assert_contains result "RESULT: FAILED" "$(cat "$T/setup.out")"
	assert_contains why "not a peer of this tailnet" "$(cat "$T/setup.out")"
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "the installation must be undone after a failed setup"
	assert_contains report "RESULT: FAILED" "$(cat "$REPORT")"
}

test_setup_without_a_chosen_node_installs_direct_and_warns() {
	_su_env
	_su --yes || fail "setup without nodes must still succeed in DIRECT: $(cat "$T/setup.out")"
	assert_contains result "RESULT: SUCCESS WITH WARNINGS" "$(cat "$T/setup.out")"
	assert_contains hint "tsem config set TSEM_PRIMARY" "$(cat "$T/setup.out")"
}

test_setup_failing_internet_check_puts_the_router_back_to_direct_and_stops_the_service() {
	_su_env
	if SETUP_NETCHECK=false _su --yes --primary node-a; then fail "a router without Internet after the start must fail the setup"; fi
	assert_contains result "RESULT: FAILED" "$(cat "$T/setup.out")"
	assert_contains stopped "stop" "$(cat "$T/initd.calls")"
	assert_contains why "no longer reaches the Internet" "$(cat "$T/setup.out")"
	assert_contains diag "tsem status" "$(cat "$REPORT")"
}

test_setup_undoes_the_installation_when_the_selftest_fails() {
	_su_env
	export SETUP_SELFTEST_CMD="$T/selftest-bad"
	if _su --yes --primary node-a; then fail "a failing self test must fail the setup"; fi
	assert_contains why "self test found problems" "$(cat "$T/setup.out")"
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "the installation must be undone after a failed self test"
	[ ! -e "$T/initd.calls" ] || fail "the service must not be started after a failed self test"
	# --keep-on-failure leaves it in place for inspection
	_su_env
	export SETUP_SELFTEST_CMD="$T/selftest-bad"
	_su --yes --primary node-a --keep-on-failure && fail "still a failure"
	[ -x "$RT/usr/sbin/tsem" ] || fail "--keep-on-failure must keep the installation"
}

test_setup_german_that_does_not_come_up_goes_back_to_direct() {
	_su_env
	if _su --yes --primary node-a --german; then fail "GERMAN that does not come up must fail the setup"; fi
	assert_contains why "going back to DIRECT" "$(cat "$T/setup.out")"
	assert_eq direct direct "$("$TSEM_BIN" status | sed -n 's/^mode=//p')"
}

test_setup_no_activate_installs_and_tests_but_does_not_start() {
	_su_env
	_su --yes --primary node-a --no-activate || fail "setup --no-activate failed: $(cat "$T/setup.out")"
	[ ! -e "$T/initd.calls" ] || fail "the service must not be started with --no-activate"
	assert_contains result "RESULT: SUCCESS WITH WARNINGS" "$(cat "$T/setup.out")"
}

test_setup_refuses_bad_options() {
	_su_env
	assert_rc subnets 2 "$SH" "$ROOT/setup.sh" --root "$RT" --yes --allow-subnets 'x;rm'
	assert_rc german-without-activation 2 "$SH" "$ROOT/setup.sh" --root "$RT" --yes --german --no-activate
	assert_rc unknown 2 "$SH" "$ROOT/setup.sh" --nonsense
}

test_setup_names_the_exit_node_mode_and_the_controller_reports_the_name() {
	_su_env
	_su --yes --primary node-a --mode-label "Office VPN" || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains conf 'TSEM_MODE_LABEL="Office VPN"' "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_eq label "Office VPN" "$("$TSEM_BIN" status | sed -n 's/^mode_label=//p')"
	assert_contains json '"mode_label":"Office VPN"' "$("$TSEM_BIN" status --json)"
	assert_rc bad-label 2 "$SH" "$ROOT/setup.sh" --root "$RT" --yes --mode-label 'a;b'
}

test_exit_is_an_alias_for_the_exit_node_mode_and_the_default_name_is_neutral() {
	"$SH" "$ROOT/src/usr/sbin/tsem" set exit --no-wait >/dev/null 2>&1 || fail "tsem set exit failed"
	assert_eq mode german "$(st mode)"
	assert_eq default-label EXIT "$(st mode_label)"
}

# ---- automatic dependencies, the old rule and the toggle button (device differences found on a GL-MG1300) --------------------

_su_dev() { # IPv6 in the kernel, no ip6tables yet; stub opkg that "installs" it; stub uci
	_su_env
	mkdir -p "$RT/proc/net" "$T/uci"
	: >"$RT/proc/net/if_inet6"
	export SETUP_IP6T="$T/fake-ip6tables" SETUP_OPKG="$T/opkg" UCI_STUB_DIR="$T/uci" SETUP_UCI="$ROOT/tests/fixtures/uci-stub" UCI_NETFILE="$RT/etc/config/network"
	printf '#!/bin/sh\necho "$@" >>%s/opkg.calls\n[ "$1" != install ] || { printf "#!/bin/sh\nexit 0\n" >%s/fake-ip6tables; chmod +x %s/fake-ip6tables; }\nexit 0\n' "$T" "$T" "$T" >"$T/opkg"
	chmod +x "$T/opkg"
}

test_setup_installs_ip6tables_with_opkg_when_ipv6_is_on_and_it_is_missing() {
	_su_dev
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains opkg-update "update" "$(cat "$T/opkg.calls")"
	assert_contains opkg-install "install ip6tables" "$(cat "$T/opkg.calls")"
	assert_contains result "RESULT: SUCCESS" "$(cat "$T/setup.out")"
}

test_setup_with_no_deps_or_without_opkg_stops_before_installing_anything() {
	_su_dev
	_su --yes --primary node-a --no-deps && fail "must stop"
	assert_contains nodeps "ip6tables is missing" "$(cat "$T/setup.out")"
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "nothing may be installed when the dependency is missing"
	[ ! -e "$T/opkg.calls" ] || fail "opkg must not run with --no-deps"
	SETUP_OPKG="$T/does-not-exist"; export SETUP_OPKG
	_su --yes --primary node-a && fail "must stop without opkg"
	assert_contains noopkg "no opkg" "$(cat "$T/setup.out")"
}

test_setup_failing_opkg_install_stops_with_a_clear_message() {
	_su_dev
	printf '#!/bin/sh\nexit 1\n' >"$T/opkg"
	_su --yes --primary node-a && fail "must stop"
	assert_contains msg "could not install" "$(cat "$T/setup.out")"
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "nothing may be installed"
}

test_setup_removes_the_old_lan_rule_only_on_request_and_keeps_a_backup() {
	_su_dev
	printf "config interface 'lan'\n\toption proto 'static'\n\nconfig rule 'ts_block_lan_leak'\n\toption in 'lan'\n\toption action 'blackhole'\n\nconfig interface 'wwan'\n\toption proto 'dhcp'\n" >"$RT/etc/config/network"
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains warn "--remove-legacy-rule" "$(cat "$T/setup.out")"
	assert_contains kept "ts_block_lan_leak" "$(cat "$RT/etc/config/network")"
	_su_dev
	printf "config interface 'lan'\n\toption proto 'static'\n\nconfig rule 'ts_block_lan_leak'\n\toption in 'lan'\n\toption action 'blackhole'\n\nconfig interface 'wwan'\n\toption proto 'dhcp'\n" >"$RT/etc/config/network"
	_su --yes --primary node-a --remove-legacy-rule || fail "setup failed: $(cat "$T/setup.out")"
	case $(cat "$RT/etc/config/network") in *ts_block_lan_leak*) fail "the rule must be gone" ;; esac
	assert_contains others "config interface 'wwan'" "$(cat "$RT/etc/config/network")"
	assert_contains backup "ts_block_lan_leak" "$(cat "$RT/root/network.before-ts_block_lan_leak")"
}

test_setup_sets_the_toggle_button_when_it_is_empty_and_uninstall_gives_it_back() {
	_su_dev
	: >"$T/uci/main"
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	assert_eq func tailscale-de "$(cat "$T/uci/func")"
	[ -e "$RT/etc/tsem/hw-func-set" ] || fail "marker missing"
	TSEM_BACKEND=mock "$SH" "$ROOT/uninstall.sh" --root "$RT" --yes >"$T/uninst.out" 2>&1 || fail "uninstall failed: $(cat "$T/uninst.out")"
	[ ! -s "$T/uci/func" ] || fail "the toggle button setting must be removed again"
	[ ! -e "$RT/etc/tsem/hw-func-set" ] || fail "marker must be gone"
}

test_setup_never_overrides_a_toggle_button_the_user_chose() {
	_su_dev
	: >"$T/uci/main"; echo vpn >"$T/uci/func"
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	assert_eq kept vpn "$(cat "$T/uci/func")"
	assert_contains warn "toggle button is set to 'vpn'" "$(cat "$T/setup.out")"
	[ ! -e "$RT/etc/tsem/hw-func-set" ] || fail "no marker when nothing was set"
}

test_setup_remembers_an_already_installed_ip6tables_package_for_the_firmware_upgrade() {
	_su_dev
	printf '#!/bin/sh\nexit 0\n' >"$T/fake-ip6tables"; chmod +x "$T/fake-ip6tables"
	printf '#!/bin/sh\necho "$@" >>%s/opkg.calls\n[ "$1" != status ] || printf "Package: %%s\nStatus: install user installed\n" "$2"\nexit 0\n' "$T" >"$T/opkg"
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	grep -q '^ip6tables' "$RT/etc/tsem/deps" || fail "the package must be remembered: $(cat "$RT/etc/tsem/deps" 2>&1)"
	case $(cat "$T/opkg.calls") in *install*) fail "nothing may be installed when the package is already there" ;; esac
}

test_setup_restarts_a_service_that_is_already_running_so_that_the_new_code_is_used() {
	_su_env
	: >"$T/service-running"
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains restarted "restart" "$(cat "$T/initd.calls")"
}

test_setup_starts_a_service_that_is_not_running_yet() {
	_su_env
	rm -f "$T/service-running" "$T/initd.calls"
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	case $(cat "$T/initd.calls") in *restart*) fail "a service that is not running must be started, not restarted" ;; esac
	assert_contains started "start" "$(cat "$T/initd.calls")"
}

# ---- an exit node the router already uses (GL.iNet's own Tailscale page): never silently dropped (found on a GL-E5800) -----------

_su_adopt() { # exit node 100.64.0.10 set in the GL.iNet page and live; a service stub that runs the daemon's ticks when it starts
	_su_env
	mkdir -p "$T/uci"; : >"$T/uci/main"
	export UCI_STUB_DIR="$T/uci" SETUP_UCI="$ROOT/tests/fixtures/uci-stub" SETUP_TSC="$ROOT/tests/stubs/tailscale"
	echo 100.64.0.10 >"$T/uci/glexit"; echo 100.64.0.10 >"$TS_STUB_DIR/exit"
	cat >"$T/initd" <<EOF2
#!/bin/sh
echo "\$@" >>$T/initd.calls
case \$1 in
running) [ -e $T/service-running ] ;;
start | restart) _i=0; while [ \$_i -lt 12 ]; do "$RT/usr/sbin/tsem" tick >/dev/null 2>&1; TSEM_NOW=\$((TSEM_NOW + 5)); export TSEM_NOW; _i=\$((_i + 1)); done ;;
esac
exit 0
EOF2
	chmod +x "$T/initd"
}

test_setup_stops_before_changing_anything_when_the_router_already_uses_an_exit_node() {
	_su_adopt
	_su --yes && fail "must stop"
	assert_contains why "--adopt-exit-node" "$(cat "$T/setup.out")"
	assert_contains nothing "Nothing was changed" "$(cat "$T/setup.out")"
	[ ! -e "$RT/usr/sbin/tsem" ] || fail "nothing may be installed"
	assert_eq glsetting 100.64.0.10 "$(cat "$T/uci/glexit")"
	assert_eq live 100.64.0.10 "$(cat "$TS_STUB_DIR/exit")"
}

test_setup_adopts_the_exit_node_goes_straight_to_the_exit_mode_and_hands_over_the_gl_setting() {
	_su_adopt
	_su --yes --adopt-exit-node || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains primary "TSEM_PRIMARY=100.64.0.10" "$(cat "$RT/etc/tsem/tsem.conf")"
	assert_eq mode german "$("$TSEM_BIN" status | sed -n 's/^mode=//p')"
	case $("$TSEM_BIN" status | sed -n 's/^state=//p') in PRIMARY_ACTIVE | SECONDARY_ACTIVE) ;; *) fail "not active: $(cat "$T/setup.out")" ;; esac
	assert_contains skipped "DIRECT is skipped" "$(cat "$T/setup.out")"
	case $(cat "$T/setup.out") in *"still reaches the Internet"*) fail "DIRECT must never happen when adopting" ;; esac
	[ ! -s "$T/uci/glexit" ] || fail "the GL.iNet page must not set an exit node any more (it would fight the failover)"
	assert_eq marker 100.64.0.10 "$(cat "$RT/etc/tsem/gl-exit-node")"
	# uninstall gives it back
	TSEM_BACKEND=mock "$SH" "$ROOT/uninstall.sh" --root "$RT" --yes >"$T/uninst.out" 2>&1 || fail "uninstall failed: $(cat "$T/uninst.out")"
	assert_eq given-back 100.64.0.10 "$(cat "$T/uci/glexit")"
	[ ! -e "$RT/etc/tsem/gl-exit-node" ] || fail "marker must be gone"
}

test_setup_adopt_that_does_not_come_up_puts_the_previous_exit_node_back_and_stops_tsem() {
	_su_adopt
	mdown 100.64.0.10
	_su --yes --adopt-exit-node && fail "must fail when the exit node does not come up"
	assert_contains restored "set --exit-node=100.64.0.10" "$(cat "$TS_STUB_DIR/calls")" # the stub cannot add a route without the tailscale0 interface; the call is the evidence
	assert_eq glsetting 100.64.0.10 "$(cat "$T/uci/glexit")"
	assert_eq live 100.64.0.10 "$(cat "$TS_STUB_DIR/exit")"
	assert_contains stopped "stop" "$(cat "$T/initd.calls")"
	assert_contains disabled "disable" "$(cat "$T/initd.calls")"
	[ ! -e "$RT/etc/tsem/gl-exit-node" ] || fail "nothing was handed over"
}

test_setup_ignore_existing_exit_node_installs_in_direct_with_a_warning() {
	_su_adopt
	_su --yes --ignore-existing-exit-node || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains warn "the existing exit node is cleared" "$(cat "$T/setup.out")"
	assert_eq mode direct "$("$TSEM_BIN" status | sed -n 's/^mode=//p')"
	assert_eq glsetting 100.64.0.10 "$(cat "$T/uci/glexit")"
}

test_setup_does_not_ask_again_when_tsem_already_manages_the_exit_node() {
	_su_adopt
	_su --yes --adopt-exit-node || fail "first setup failed: $(cat "$T/setup.out")"
	: >"$T/service-running"
	_su --yes || fail "a re-run (update) must not stop on the exit node that tsem itself set: $(cat "$T/setup.out")"
}

test_setup_installs_no_switch_hook_on_the_gl_e5800_which_has_no_hardware_switch() {
	_su_env
	mkdir -p "$RT/tmp/sysinfo"; echo "GL.iNet E5800, Qualcomm Technologies, Inc. SDXPINN IDP MBB" >"$RT/tmp/sysinfo/model"
	_su --yes --primary node-a || fail "setup failed: $(cat "$T/setup.out")"
	assert_contains info "has no hardware toggle switch" "$(cat "$T/setup.out")"
	case $(cat "$RT/etc/gl-switch.d/tailscale-de.sh") in *tsem-switch-hook*) fail "the tsem hook must not replace the GL.iNet prototype" ;; esac
}

test_setup_refreshes_a_saved_node_name_to_the_one_tailscale_shows() {
	_su_env
	_su --yes --primary node-a --secondary node-b || fail "first setup failed: $(cat "$T/setup.out")"
	sed -i 's/^TSEM_SECONDARY_NAME=.*/TSEM_SECONDARY_NAME=old-hostname/' "$RT/etc/tsem/tsem.conf"
	: >"$T/service-running"
	_su --yes || fail "re-run failed: $(cat "$T/setup.out")"
	assert_contains refreshed "old-hostname -> node-b" "$(cat "$T/setup.out")"
	assert_contains name "TSEM_SECONDARY_NAME=node-b" "$(cat "$RT/etc/tsem/tsem.conf")"
}

test_setup_update_of_a_protected_router_keeps_the_exit_mode_and_never_passes_through_direct() {
	_su_adopt
	_su --yes --adopt-exit-node || fail "first setup failed: $(cat "$T/setup.out")"
	assert_eq mode german "$("$TSEM_BIN" status | sed -n 's/^mode=//p')"
	: >"$T/service-running"
	: >"$T/initd.calls"
	_su --yes --primary node-a || fail "update failed: $(cat "$T/setup.out")"
	assert_eq "still the exit mode" german "$("$TSEM_BIN" status | sed -n 's/^mode=//p')"
	assert_contains kept "stayed protected" "$(cat "$T/setup.out")"
	case $(cat "$T/setup.out") in *"running in DIRECT mode"*) fail "an update must not switch a protected router to DIRECT" ;; esac
	assert_contains restarted "restart" "$(cat "$T/initd.calls")"
}
