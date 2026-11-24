# shellcheck shell=sh
# Packages that setup installed with opkg (ip6tables) and a firmware upgrade removed: `tsem deps` reinstalls them and re-asserts the
# guard; DIRECT must stay reachable without ip6tables (found on a GL-MG1300 after its firmware upgrade: the router sat in ERROR).

_deps_env() {
	export TSEM_DEPS_FILE=$T/deps TSEM_OPKG=$T/opkg TSEM_DEPS_DELAY=0 TSEM_DEPS_TRIES=3
	printf 'ip6tables-nft\n' >"$T/deps"
	: >"$T/pkg-state"
	cat >"$T/opkg" <<EOF
#!/bin/sh
echo "\$@" >>"$T/opkg.calls"
case \$1 in
status) grep -qx "\$2" "$T/pkg-state" && printf 'Package: %s\nStatus: install user installed\n' "\$2" ;;
update) [ ! -e "$T/no-internet" ] || exit 1 ;;
install) shift; for p in "\$@"; do echo "\$p" >>"$T/pkg-state"; done ;;
esac
exit 0
EOF
	chmod +x "$T/opkg"
}

test_deps_reinstalls_a_missing_package_and_reasserts_the_guard() {
	_deps_env
	tsem deps || fail "deps failed"
	assert_contains installed "install ip6tables-nft" "$(cat "$T/opkg.calls")"
	grep -qx ip6tables-nft "$T/pkg-state" || fail "package not installed"
}

test_deps_does_nothing_when_nothing_is_missing_or_nothing_is_listed() {
	_deps_env
	echo ip6tables-nft >"$T/pkg-state"
	tsem deps || fail "deps failed"
	case $(cat "$T/opkg.calls") in *update* | *install*) fail "must not touch opkg when nothing is missing" ;; esac
	rm -f "$T/deps" "$T/opkg.calls"
	tsem deps || fail "deps failed without a list"
	[ ! -e "$T/opkg.calls" ] || fail "opkg must not run without a list"
}

test_deps_without_internet_gives_up_after_the_tries_and_says_so() {
	_deps_env
	: >"$T/no-internet"
	tsem deps && fail "must report that it could not reinstall"
	assert_eq tries 3 "$(grep -c '^update' "$T/opkg.calls")"
	[ ! -d "$TSEM_RUN_DIR/deps.lock" ] || fail "the lock must be released"
}

test_guard_open_works_without_ip6tables_but_protected_modes_stay_refused() {
	( TSEM_BACKEND=ipt; export TSEM_BACKEND
	. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"
	_v6_kernel() { return 0; }; _have_v6() { return 1; }
	_rt_off() { return 0; }; _rt_on() { return 0; }; _fw_apply() { return 0; }; _fp_unload() { return 0; }
	be_guard_get() { echo "$_want_g"; }
	TSEM_LAN_IFACES=lo
	_want_g=open; be_guard_set open || { echo "open must work without ip6tables"; exit 1; }
	_want_g=blocked; be_guard_set blocked 2>/dev/null && { echo "blocked must be refused without ip6tables"; exit 1; }
	_want_g=german; be_guard_set german 2>/dev/null && { echo "german must be refused without ip6tables"; exit 1; }
	exit 0 ) || fail "guard behaviour without ip6tables is wrong"
}

test_guard_get_reports_open_as_healthy_without_ip6tables_but_never_a_protected_state() {
	( TSEM_BACKEND=ipt; export TSEM_BACKEND
	. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"
	_v6_kernel() { return 0; }; _have_v6() { return 1; }
	_out_state() { echo open; }; _rt_state() { echo none; }; be_fastpath_state() { echo none; }
	TSEM_OUT_GUARD=on
	_fw_state() { case $1 in 4) echo "$_g4x" ;; *) echo none ;; esac; }
	_g4x=open; [ "$(be_guard_get)" = open ] || { echo "open without ip6tables must be reported open (was: inconsistent => ERROR in the GUI)"; exit 1; }
	_g4x=none; [ "$(be_guard_get)" = none ] || { echo "no chain must stay none"; exit 1; }
	_g4x=blocked; [ "$(be_guard_get)" = inconsistent ] || { echo "blocked cannot be verified without ip6tables"; exit 1; }
	_g4x=german; [ "$(be_guard_get)" = inconsistent ] || { echo "german cannot be verified without ip6tables"; exit 1; }
	exit 0 ) || fail "guard_get without ip6tables is wrong"
}

test_fw_apply_open_without_ip6tables_never_calls_ip6tables_restore() {
	( TSEM_BACKEND=ipt; export TSEM_BACKEND
	. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load; . "$TSEM_LIBDIR/backend_ipt.sh"
	_v6_kernel() { return 0; }; _have_v6() { return 1; }
	_restore_cmd() { if [ "$1" = 4 ]; then echo true; else echo "$T/must-not-run-ip6tables-restore"; fi; }
	_g_fw_rules() { :; }; _g_out_rules() { :; }; _g_nat_rules() { :; }; _hook_ensure() { return 0; }
	mkdir -p "$T/shim"; printf "#!/bin/sh
cat >/dev/null
" >"$T/shim/iptables-restore"; chmod +x "$T/shim/iptables-restore"; PATH=$T/shim:$PATH
	_fw_dump() { :; }; _out_dump() { :; }
	_fw_apply open || { echo "_fw_apply open must succeed without ip6tables"; exit 1; }
	exit 0 ) || fail "_fw_apply open fails without ip6tables"
}
