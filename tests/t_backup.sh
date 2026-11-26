# shellcheck shell=sh
# tsem backup / restore: settings only, never the mode or secrets, hostile archives are refused.

_bk_setup() {
	t_setup
	mkdir -p "$T/etc"
	export TSEM_CONF=$T/etc/tsem.conf
	printf 'TSEM_PRIMARY=%s\nTSEM_PRIMARY_NAME=node-a\nTSEM_MODE_LABEL="Germany"\n' "$P1" >"$TSEM_CONF"
	printf 'NOTIFY_URL=https://ntfy.example/topic\n' >"$T/etc/notify.conf"
	printf 'sekret\n' >"$T/etc/notify.token"
	printf 'seq=1\n' >"$T/etc/intent"
}

test_backup_contains_only_settings_not_tokens_or_the_mode() {
	_bk_setup
	_o=$(tsem backup "$T/b.tar.gz") || fail "backup failed: $_o"
	_l=$(tar tzf "$T/b.tar.gz" | sort | tr '\n' ' ')
	assert_eq files "notify.conf tsem.conf " "$_l"
	assert_eq mode 600 "$(stat -c %a "$T/b.tar.gz")"
}

test_restore_brings_settings_back_keeps_the_old_ones_and_never_touches_the_mode() {
	_bk_setup
	tsem backup "$T/b.tar.gz" >/dev/null
	printf 'TSEM_PRIMARY_NAME=changed\n' >"$TSEM_CONF"
	rm -f "$T/etc/notify.conf"
	_i=$(cat "$T/etc/intent")
	_o=$(tsem restore "$T/b.tar.gz") || fail "restore failed: $_o"
	assert_contains name "TSEM_PRIMARY_NAME=node-a" "$(cat "$TSEM_CONF")"
	assert_contains kept "TSEM_PRIMARY_NAME=changed" "$(cat "$TSEM_CONF.before-restore")"
	assert_contains notify "NOTIFY_URL=https://ntfy.example/topic" "$(cat "$T/etc/notify.conf")"
	assert_eq intent "$_i" "$(cat "$T/etc/intent")"
	assert_eq token "sekret" "$(cat "$T/etc/notify.token")"
}

test_restore_refuses_foreign_names_commands_and_garbage() {
	_bk_setup
	mkdir -p "$T/x/etc"
	# a name that is not one of ours
	printf 'x\n' >"$T/x/passwd"; ( cd "$T/x" && tar czf "$T/evil1.tar.gz" passwd )
	if tsem restore "$T/evil1.tar.gz" >/dev/null 2>&1; then fail "a foreign file name must be refused"; fi
	# command substitution in a setting
	printf 'TSEM_PRIMARY_NAME=$(reboot)\n' >"$T/x/tsem.conf"; ( cd "$T/x" && tar czf "$T/evil2.tar.gz" tsem.conf )
	if tsem restore "$T/evil2.tar.gz" >/dev/null 2>&1; then fail "command substitution must be refused"; fi
	# a line that is not a setting
	printf 'reboot\n' >"$T/x/tsem.conf"; ( cd "$T/x" && tar czf "$T/evil3.tar.gz" tsem.conf )
	if tsem restore "$T/evil3.tar.gz" >/dev/null 2>&1; then fail "a non-setting line must be refused"; fi
	# not an archive, and a missing file
	printf 'junk' >"$T/junk.tar.gz"
	if tsem restore "$T/junk.tar.gz" >/dev/null 2>&1; then fail "junk must be refused"; fi
	if tsem restore "$T/nonexistent" >/dev/null 2>&1; then fail "a missing file must be refused"; fi
	# nothing was changed by any refusal
	assert_contains intact "TSEM_PRIMARY_NAME=node-a" "$(cat "$TSEM_CONF")"
}
