# shellcheck shell=sh
# RC4 -> Final upgrade against the REAL RC4 installer and files (tests/fixtures/rc4-d2d441b-install-tree.tar.gz, version 0.2.0).

_up_setup() {
	[ -n "$(command -v mkroot)" ] || . "$ROOT/tests/t_install.sh"
	rm -rf "$T/root" "$T/mock" "$T/rc4"
	mkroot
	mkdir -p "$T/rc4" && tar xzf "$ROOT/tests/fixtures/rc4-d2d441b-install-tree.tar.gz" -C "$T/rc4" || fail "cannot unpack the RC4 fixture"
	_rc4v=$(sed -n 's/^TSEM_VERSION=//p' "$T/rc4/src/usr/lib/tsem/common.sh" | head -n 1 | tr -d '"')
	assert_eq fixture-version 0.2.0 "$_rc4v"
	_fin=$(sed -n 's/^TSEM_VERSION=//p' "$ROOT/src/usr/lib/tsem/common.sh" | head -n 1 | tr -d '"')
	[ "$_fin" != "$_rc4v" ] || fail "the tree under test still has the RC4 version"
}
_up_files() { (cd "$RT" && find . \( -type f -o -type l \) -not -path './etc/tsem/backup/*' -not -name 'install.manifest' | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$( [ -L "$f" ] && readlink "$f" || md5sum <"$f" | cut -c1-32 )"; done); }

test_rc4_to_final_upgrade_keeps_config_and_intent_integrates_hook_and_boot_link_and_rolls_back() {
	_up_setup
	# the router as RC4 left it: RC4's own installer, boot link and GL hook as used on the hardware
	"$SH" "$T/rc4/install.sh" --root "$RT" --yes --enable --replace-gl-hook --initial-mode german >"$T/rc4.out" 2>&1 || fail "RC4 install failed: $(cat "$T/rc4.out")"
	assert_eq rc4-installed 0.2.0 "$(sed -n 's/^version=//p' "$RT/etc/tsem/install.manifest")"
	# the user's own configuration (nodes with names, remote-site subnets, a customised DNS setting) must survive byte for byte
	printf 'TSEM_PRIMARY=100.64.0.30\nTSEM_PRIMARY_NAME=exit-a\nTSEM_SECONDARY=100.64.0.31\nTSEM_SECONDARY_NAME=exit-b\nTSEM_ALLOW_SUBNETS4="10.30.0.0/24 10.30.1.0/24 10.30.2.0/24"\nTSEM_DNS_REDIRECT=""\nTSEM_HW_STATE_FILE=""\n' >"$RT/etc/tsem/tsem.conf"
	_conf=$(md5sum <"$RT/etc/tsem/tsem.conf"); _intent=$(md5sum <"$RT/etc/tsem/intent")
	_rc4state=$(_up_files)
	_rc4hook=$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")
	# upgrade with the Final installer, default options
	TSEM_INSTALL_STAMP=20260101-000007 "$SH" "$ROOT/install.sh" --root "$RT" --yes >"$T/up.out" 2>&1 || fail "upgrade failed: $(cat "$T/up.out")"
	assert_eq version "$_fin" "$(sed -n 's/^version=//p' "$RT/etc/tsem/install.manifest")"
	assert_eq conf-byte-for-byte "$_conf" "$(md5sum <"$RT/etc/tsem/tsem.conf")"
	assert_eq intent-byte-for-byte "$_intent" "$(md5sum <"$RT/etc/tsem/intent")"
	grep -q "mode=german" "$RT/etc/tsem/intent" 2>/dev/null || grep -q german "$RT/etc/tsem/intent" || fail "the german intent was lost"
	# F04/F05: hook (v2) and boot links integrated, no manual step
	grep -q 'tsem-switch-hook v2' "$RT/etc/gl-switch.d/tailscale-de.sh" || fail "the Final hook was not installed by the upgrade"
	[ -L "$RT/etc/rc.d/S18tsem" ] && [ -L "$RT/etc/rc.d/K10tsem" ] || fail "boot links missing after the upgrade"
	[ -x "$RT/usr/libexec/rpcd/tsem" ] && [ -f "$RT/usr/lib/tsem/backend_ipt.sh" ] || fail "components missing"
	# new settings reach an old config through defaults (the user's file is never rewritten)
	_dr=$(TSEM_CONF=$RT/etc/tsem/tsem.conf TSEM_LIBDIR=$RT/usr/lib/tsem "$SH" -c '. "$TSEM_LIBDIR/common.sh"; . "$TSEM_LIBDIR/conf.sh"; conf_load >/dev/null 2>&1; echo "$TSEM_DNS_ROUTER|$TSEM_HW_GPIO_ON|$TSEM_PRIMARY_NAME"')
	assert_eq defaults-and-user-values "1.1.1.1|1|exit-a" "$_dr"
	_after=$(_up_files)
	# rollback returns to the exact RC4 state, including the RC4 hook and without the new boot links
	"$SH" "$ROOT/install.sh" --root "$RT" --rollback --yes >"$T/rb1.out" 2>&1 || fail "rollback failed: $(cat "$T/rb1.out")"
	assert_eq rc4-state-restored "$_rc4state" "$(_up_files)"
	assert_eq rc4-hook-restored "$_rc4hook" "$(md5sum <"$RT/etc/gl-switch.d/tailscale-de.sh")"
	# the upgrade can be done again and ends in exactly the same state (idempotent)
	TSEM_INSTALL_STAMP=20260101-000008 "$SH" "$ROOT/install.sh" --root "$RT" --yes >"$T/up2.out" 2>&1 || fail "second upgrade failed: $(cat "$T/up2.out")"
	assert_eq same-final-state "$_after" "$(_up_files)"
}

test_rc4_to_final_upgrade_killed_midway_is_repaired_by_recover_and_can_be_repeated() {
	_up_setup
	"$SH" "$T/rc4/install.sh" --root "$RT" --yes --enable --replace-gl-hook --initial-mode german >"$T/rc4.out" 2>&1 || fail "RC4 install failed"
	printf 'TSEM_PRIMARY=100.64.0.30\nTSEM_SECONDARY=100.64.0.31\n' >"$RT/etc/tsem/tsem.conf"
	_rc4state=$(_up_files)
	TSEM_INSTALL_KILL_AFTER=3 TSEM_INSTALL_STAMP=20260101-000007 "$SH" "$ROOT/install.sh" --root "$RT" --yes >/dev/null 2>&1
	[ -f "$RT/etc/tsem/backup/INPROGRESS" ] || fail "no marker after the kill"
	# a new install refuses to start on top of a half-done one ...
	TSEM_INSTALL_STAMP=20260101-000008 "$SH" "$ROOT/install.sh" --root "$RT" --yes >"$T/refuse.out" 2>&1 && fail "install ran over an interrupted one"
	# ... the journal restores exactly the RC4 state ...
	"$SH" "$ROOT/install.sh" --root "$RT" --recover --yes >"$T/rec.out" 2>&1 || fail "recover failed: $(cat "$T/rec.out")"
	assert_eq rc4-state "$_rc4state" "$(_up_files)"
	[ ! -e "$RT/etc/tsem/backup/INPROGRESS" ] || fail "marker must be gone"
	# ... and the upgrade can simply be run again
	TSEM_INSTALL_STAMP=20260101-000009 "$SH" "$ROOT/install.sh" --root "$RT" --yes >"$T/again.out" 2>&1 || fail "repeat failed: $(cat "$T/again.out")"
	assert_eq version "$_fin" "$(sed -n 's/^version=//p' "$RT/etc/tsem/install.manifest")"
}
