# shellcheck shell=sh
# RC3 acceptance phase 1 (tools/tsem-rc3-acceptance.sh + Mac wrapper): read-only guarantees.

ACC=$ROOT/tools/tsem-rc3-acceptance.sh
_acc_code() { grep -v '^[[:space:]]*#' "$1" | sed 's/have [A-Za-z0-9_-]*//g'; }
_snap() { (cd "$1" && find . -type f -o -type l | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(md5sum <"$f" 2>/dev/null | cut -c1-32)"; done); }

_acc_fix() {
	RT=$T/rt
	mkdir -p "$RT/etc/tsem" "$RT/etc/gl-switch.d" "$RT/etc/config"
	printf '#!/bin/sh\ntailscale set --exit-node=100.64.0.30\n' >"$RT/etc/gl-switch.d/tailscale-de.sh"
	printf 'v=1\nmode=german\ncrc=bad\n' >"$RT/etc/tsem/intent"
	printf "config defaults\n" >"$RT/etc/config/firewall"
}

test_acceptance_runs_reports_and_changes_nothing() {
	t_setup; _acc_fix
	_s=$(_snap "$RT")
	_o=$(PF_ROOT=$RT TSEM_RUN_DIR=$RT/var/run/tsem sh "$ACC" --repo "$ROOT" 2>&1 </dev/null); _rc=$?
	case $_rc in 0 | 1 | 2) ;; *) fail "unexpected exit code $_rc" ;; esac
	assert_contains result "RESULT:" "$_o"
	assert_contains ro "PASS  readonly" "$_o"
	assert_eq unchanged "$_s" "$(_snap "$RT")"
	[ ! -e "$RT/var/run/tsem" ] || fail "run dir was created"
}

test_acceptance_reports_invalid_intent_and_competing_controller() {
	t_setup; _acc_fix
	_o=$(PF_ROOT=$RT TSEM_RUN_DIR=$RT/var/run/tsem sh "$ACC" --repo "$ROOT" 2>&1 </dev/null)
	assert_contains intent "INVALID" "$_o"
	assert_contains reason "crc-mismatch" "$_o"
	assert_contains ctl "old prototype controller present and NOT replaced" "$_o"
}

test_acceptance_refuses_active_mode() {
	t_setup
	sh "$ACC" --active >/dev/null 2>&1 && fail "--active must be refused"
	assert_rc usage 64 sh "$ACC" --active
	assert_rc usage2 64 sh "$ACC" --active=yes
	assert_rc unknown 64 sh "$ACC" --bogus
}

test_acceptance_streams_through_sh_s() {
	t_setup; _acc_fix
	_o=$(PF_ROOT=$RT TSEM_RUN_DIR=$RT/var/run/tsem sh -s -- --repo "$ROOT" <"$ACC" 2>&1)
	assert_contains tail "RESULT:" "$_o"
}

test_acceptance_source_contains_no_mutating_action() {
	_c=$(_acc_code "$ACC")
	for _pat in \
		'uci[[:space:]]+(-q[[:space:]]+)?(set|add|add_list|del_list|delete|rename|reorder|commit|revert|import)' \
		'iptables[^|;]*[[:space:]]-[AIDRFNXPZE][[:space:]]' 'iptables-restore|ip6tables-restore|nft[[:space:]]' \
		'ip[[:space:]]+(-6[[:space:]]+)?(rule|route|addr|address|link|neigh)[[:space:]]+(add|del|delete|replace|change|flush|set|append)' \
		'tailscale[[:space:]]+(up|down|set|login|logout|serve|funnel|cert|file|switch|lock|ssh|ping|netcheck|bugreport|configure|update)' \
		'/etc/init\.d/[^[:space:]]+[[:space:]]+(start|stop|restart|reload|enable|disable)' '(^|[;&|(]|\$\()[[:space:]]*fw3[[:space:]]+[a-z]' \
		'(^|[;&|(]|\$\()[[:space:]]*(reboot|poweroff|halt)([[:space:]]|$)|sysctl[[:space:]]+-w' 'ubus[[:space:]]+call' \
		'(^|[;&|(]|\$\()[[:space:]]*(service|rm|mv|cp|mkdir|rmdir|touch|chmod|chown|ln|mktemp|tee|dd|kill|killall|opkg|wget|curl|scp|rsync|ssh|nc|logger|crontab|eval|rmmod|insmod|modprobe)[[:space:]]' \
		'sed[[:space:]]+-i' '--yes|--enable|--replace-gl-hook|--force|--rollback' '(sh|bash|ash|\.)[[:space:]]+"?\$REPO/(un)?install\.sh'; do
		printf '%s\n' "$_c" | grep -Eq -- "$_pat" && fail "forbidden pattern '$_pat': $(printf '%s\n' "$_c" | grep -E -- "$_pat" | head -n 2)"
	done
	_r=$(printf '%s\n' "$_c" | sed 's/2>&1//g; s/>\/dev\/null//g; s/<\/dev\/null//g; s/>&2//g; s/2>\/dev\/null//g' | grep '>' | grep -v '>&' | grep -v "echo \"# hash" )
	[ -z "$_r" ] || fail "file redirect in the script: $_r"
	true
}

test_acceptance_only_calls_read_only_tsem_subcommands() {
	_c=$(_acc_code "$ACC")
	_bad=$(printf '%s\n' "$_c" | grep -E 'rtsem[[:space:]]+[a-z-]+' | grep -Ev 'rtsem (status|intent-check|selftest)' | grep -v '^rtsem()' )
	[ -z "$_bad" ] || fail "rtsem called with a non-read-only subcommand: $_bad"
	printf '%s\n' "$_c" | grep -E 'sbin/tsem"? +(set|boot|reapply|teardown|failover|tick|daemon)' && fail "mutating tsem subcommand"
	true
}

test_acceptance_is_posix_sh_and_parses_everywhere() {
	_c=$(_acc_code "$ACC")
	for _pat in '\[\[[[:space:]]' '(^|[;&|[:space:]])local[[:space:]]' 'echo[[:space:]]+-e' '\$\{[A-Za-z_0-9]+//' '<<<' '&>' '\|&' 'declare[[:space:]]' '\$RANDOM' 'pipefail'; do
		printf '%s\n' "$_c" | grep -Eq -- "$_pat" && fail "non-POSIX construct '$_pat'"
	done
	for _s in "$SH" dash bash ash; do
		command -v "$_s" >/dev/null 2>&1 || continue
		"$_s" -n "$ACC" || fail "acceptance script does not parse in $_s"
		"$_s" -n "$ROOT/tools/run-rc3-acceptance-mac.sh" || fail "wrapper does not parse in $_s"
	done
}

test_wrapper_stage_and_repo_cannot_be_combined() {
	t_setup
	assert_rc both 64 sh "$ROOT/tools/run-rc3-acceptance-mac.sh" --stage "$ROOT" --repo /tmp/glinet-tailscale-exit-manager
	assert_rc neither 64 sh "$ROOT/tools/run-rc3-acceptance-mac.sh"
}

test_wrapper_refuses_dotdot_in_repo_path() {
	t_setup
	assert_rc dotdot 64 sh "$ROOT/tools/run-rc3-acceptance-mac.sh" --repo /tmp/x/../../etc
}

test_acceptance_detects_installed_rc2() {
	t_setup; _acc_fix
	mkdir -p "$RT/usr/lib/tsem"; echo 'TSEM_VERSION=0.1.0-rc2' >"$RT/usr/lib/tsem/common.sh"
	_o=$(PF_ROOT=$RT TSEM_RUN_DIR=$RT/var/run/tsem sh "$ACC" --repo "$ROOT" 2>&1 </dev/null)
	assert_contains rc2 "RC2 is still installed" "$_o"
}

# fake ssh: logs the call, then executes the remote command locally
_fake_ssh() {
	mkdir -p "$T/mbin" "$T/home"
	cat >"$T/mbin/ssh" <<'SSHEOF'
#!/bin/sh
echo "$*" >>"$SSHLOG"
for a; do cmd=$a; done
case $cmd in
"sh -s"*)
	[ -z "${FAKE_RUN_HOOK:-}" ] || sh -c "$FAKE_RUN_HOOK" hook "$cmd"
	[ -z "${FAKE_RUN_FAIL:-}" ] || exit 255 ;;
esac
exec sh -c "$cmd"
SSHEOF
	chmod +x "$T/mbin/ssh"
}

_staged_dir_from_log() { sed -n 's/.*mkdir \(\/tmp\/tsem-rc3-accept\.[0-9.]*\) .*/\1/p' "$T/ssh.log" | head -n 1; }

test_wrapper_cleans_up_even_when_the_run_fails() {
	t_setup; _fake_ssh
	FAKE_RUN_FAIL=1 SSHLOG=$T/ssh.log PATH=$T/mbin:$PATH HOME=$T/home sh "$ROOT/tools/run-rc3-acceptance-mac.sh" --host fake --stage "$ROOT" --out "$T/out" >/dev/null 2>&1
	_sd=$(_staged_dir_from_log)
	[ -n "$_sd" ] || fail "no staged dir in ssh log: $(cat "$T/ssh.log")"
	[ ! -e "$_sd" ] || { rm -rf "$_sd"; fail "staged copy left behind after a failed run"; }
}

test_wrapper_never_touches_the_existing_repository_directory() {
	t_setup; _acc_fix; _fake_ssh
	_old=/tmp/glinet-tailscale-exit-manager; _made=0
	if [ ! -e "$_old" ]; then mkdir -p "$_old" && _made=1; fi
	echo sentinel >"$_old/.tsem-test-sentinel-$$"
	SSHLOG=$T/ssh.log PF_ROOT=$RT TSEM_RUN_DIR=$RT/var/run/tsem PATH=$T/mbin:$PATH HOME=$T/home \
		sh "$ROOT/tools/run-rc3-acceptance-mac.sh" --host fake --stage "$ROOT" --out "$T/out" >/dev/null 2>&1
	_ok=0; [ -f "$_old/.tsem-test-sentinel-$$" ] && _ok=1
	rm -f "$_old/.tsem-test-sentinel-$$"; [ "$_made" -eq 0 ] || rmdir "$_old" 2>/dev/null
	[ "$_ok" -eq 1 ] || fail "existing /tmp/glinet-tailscale-exit-manager was modified"
	case $(cat "$T/ssh.log") in *glinet-tailscale-exit-manager*) fail "ssh call mentions the existing repository directory" ;; esac
	_sd=$(_staged_dir_from_log); [ -n "$_sd" ] || fail "no staged dir"
	case $_sd in /tmp/tsem-rc3-accept.*) ;; *) fail "unexpected stage dir $_sd" ;; esac
}

test_wrapper_does_not_delete_a_directory_without_our_marker() {
	t_setup; _acc_fix; _fake_ssh
	# the run step removes the marker, i.e. the directory is no longer provably ours
	FAKE_RUN_HOOK='d=$(printf %s "$1" | sed "s/.*--repo //"); rm -f "$d/.tsem-rc3-stage"' \
	SSHLOG=$T/ssh.log PF_ROOT=$RT TSEM_RUN_DIR=$RT/var/run/tsem PATH=$T/mbin:$PATH HOME=$T/home \
		sh "$ROOT/tools/run-rc3-acceptance-mac.sh" --host fake --stage "$ROOT" --out "$T/out" >/dev/null 2>&1
	_sd=$(_staged_dir_from_log); [ -n "$_sd" ] || fail "no staged dir"
	if [ -d "$_sd" ]; then rm -rf "$_sd"; else fail "directory without marker was deleted"; fi
}

test_wrapper_stage_and_run_end_to_end_with_fake_ssh() {
	t_setup; _acc_fix; _fake_ssh
	_o=$(SSHLOG=$T/ssh.log PF_ROOT=$RT TSEM_RUN_DIR=$RT/var/run/tsem PATH=$T/mbin:$PATH HOME=$T/home \
		sh "$ROOT/tools/run-rc3-acceptance-mac.sh" --host fake --stage "$ROOT" --out "$T/out" 2>&1); _rc=$?
	assert_contains staged "staging" "$_o"
	assert_contains rc2 "installed.version" "$_o"
	assert_contains result "RESULT:" "$_o"
	assert_contains cmp "repo.compare" "$_o"
	ls "$T/out"/rc3-acceptance-fake-*.txt >/dev/null 2>&1 || fail "no report saved: $(ls "$T/out" 2>&1)"
	# exactly three ssh calls: stage (new unique /tmp dir, mkdir without -p), read-only run, guarded cleanup
	assert_eq ssh-calls 3 "$(wc -l <"$T/ssh.log" | tr -d ' ')"
	_sd=$(_staged_dir_from_log); [ -n "$_sd" ] || fail "no staged dir in ssh log"
	assert_contains mkdir-not-p "mkdir $_sd " "$(cat "$T/ssh.log")"
	case $(cat "$T/ssh.log") in *"mkdir -p"*) fail "stage uses mkdir -p (could reuse an existing directory)" ;; esac
	case $(cat "$T/ssh.log") in *"rm -rf /etc"*|*"rm -rf /usr"*) fail "touches non-/tmp paths" ;; esac
	assert_contains guarded-cleanup ".tsem-rc3-stage" "$(tail -n 1 "$T/ssh.log")"
	assert_contains cleanup-path "d=$_sd;" "$(tail -n 1 "$T/ssh.log")"
	[ ! -e "$_sd" ] || fail "staged copy was not removed"
	[ "$_rc" -le 2 ] || fail "wrapper rc $_rc"
}
