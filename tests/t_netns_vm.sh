# shellcheck shell=sh
# tools/run-netns-vm.sh: the verdict logic of the ht-dev packet-test runner. The real suites are NOT run here (they need the VM);
# these tests prove that a missing capability or a skipped/short run can never become PASSED and that Gitea only gets "success"
# for PASSED. Fake suites are only possible with TSEM_VM_SELFTEST=1, which marks the result and refuses to post.

_vm() { # args...  (runs the script with a private out dir)
	"$SH" "$ROOT/tools/run-netns-vm.sh" --out "$T/out" "$@"
}
_nofw_path() { # a PATH with the basics but WITHOUT ip6tables: preflight must fail
	mkdir -p "$T/bin"
	for _t in sh dash bash awk sed cat date python3 uname id grep tee mkdir wc head tr dirname tail cut sort git; do
		_p=$(command -v "$_t" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_t"
	done
	for _t in iptables iptables-restore ip6tables-restore; do _p=$(command -v "$_t" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_t"; done
	echo "$T/bin"
}

test_vm_missing_tool_is_not_run_and_never_a_pass() {
	_o=$(PATH=$(_nofw_path) _vm 2>&1); _rc=$?
	assert_eq rc 2 "$_rc"
	assert_contains fail "FAIL  tool:ip6tables" "$_o"
	assert_contains verdict "VERDICT: NOT-RUN" "$_o"
	case $_o in *"VERDICT: PASSED"*) fail "a run without ip6tables was reported PASSED" ;; esac
	assert_contains result "NOT-RUN" "$(cat "$T/out/result.md")"
}

test_vm_selftest_full_counts_pass_but_are_marked_and_never_posted() {
	_o=$(TSEM_VM_SELFTEST=1 TSEM_VM_FAKE_SUITE='echo "60 passed, 0 failed (fake)"' _vm --post --sha abc --token-file /nonexistent 2>&1); _rc=$?
	assert_eq rc 0 "$_rc"
	assert_contains verdict "VERDICT: PASSED" "$_o"
	assert_contains marked "selftest: 1" "$(cat "$T/out/result.md")"
	assert_contains refused "post: refused in selftest mode" "$_o"
}

test_vm_too_few_passed_scenarios_is_failed() {
	_o=$(TSEM_VM_SELFTEST=1 TSEM_VM_FAKE_SUITE='echo "3 passed, 0 failed (fake)"' _vm 2>&1); _rc=$?
	assert_eq rc 1 "$_rc"
	assert_contains verdict "VERDICT: FAILED" "$_o"
}

test_vm_a_failed_scenario_is_failed() {
	_o=$(TSEM_VM_SELFTEST=1 TSEM_VM_FAKE_SUITE='echo "60 passed, 1 failed (fake)"; exit 1' _vm 2>&1); _rc=$?
	assert_eq rc 1 "$_rc"
	assert_contains verdict "VERDICT: FAILED" "$_o"
}

test_vm_skipped_or_silent_suites_are_not_run() {
	_o=$(TSEM_VM_SELFTEST=1 TSEM_VM_FAKE_SUITE='echo SKIPPED; exit 77' _vm 2>&1); _rc=$?
	assert_eq rc-skip 2 "$_rc"
	assert_contains verdict "VERDICT: NOT-RUN" "$_o"
	_o=$(TSEM_VM_SELFTEST=1 TSEM_VM_FAKE_SUITE='echo "no summary line at all"' _vm 2>&1); _rc=$?
	assert_eq rc-silent 2 "$_rc"
	assert_contains verdict2 "VERDICT: NOT-RUN" "$_o"
}

test_vm_a_pass_that_skipped_something_is_not_run() {
	_o=$(TSEM_VM_SELFTEST=1 TSEM_VM_FAKE_SUITE='echo "    SKIPPED: x"; echo "60 passed, 0 failed (fake)"' _vm 2>&1); _rc=$?
	assert_eq rc 2 "$_rc"
	assert_contains verdict "VERDICT: NOT-RUN" "$_o"
}

test_vm_posts_error_never_success_for_a_not_run() {
	mkdir -p "$T/stub"
	printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >"%s/curl.args"\nprintf 201\n' "$T" >"$T/stub/curl"
	chmod +x "$T/stub/curl"
	_o=$(GITEA_TOKEN=secret-token-value PATH="$T/stub:$(_nofw_path)" _vm --post --sha 0123abc 2>&1); _rc=$?
	assert_eq rc 2 "$_rc"
	assert_contains posted "commit status netns-vm/ht-dev = error on 0123abc" "$_o"
	assert_contains url "/statuses/0123abc" "$(cat "$T/curl.args")"
	assert_contains body '"state":"error"' "$(cat "$T/curl.args")"
	case $(cat "$T/curl.args") in *'"state":"success"'*) fail "NOT-RUN was posted as success" ;; esac
	case $_o in *secret-token-value*) fail "the token was printed" ;; esac
}

test_vm_without_token_does_not_post_and_says_so() {
	_o=$(PATH=$(_nofw_path) _vm --post --sha 0123abc 2>&1)
	assert_contains hint "not posted" "$_o"
}

test_vm_script_makes_no_changes_outside_namespaces_and_out_dir() {
	! grep -nE '(^|[^a-z-])(ip (route|rule|addr|link) (add|del|set)|sysctl -w|iptables-save|systemctl|rm -rf /)' "$ROOT/tools/run-netns-vm.sh" || fail "script changes host state"
}

test_vm_sha_that_is_not_the_checkout_cannot_be_passed() {
	command -v git >/dev/null 2>&1 || need_skip "git is not installed"
	mkdir -p "$T/repo/tools" && cp "$ROOT/tools/run-netns-vm.sh" "$T/repo/tools/" && mkdir -p "$T/repo/tests/netns" && cp "$ROOT"/tests/netns/netns_test.py "$ROOT"/tests/netns/netns6_test.py "$T/repo/tests/netns/"
	( cd "$T/repo" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t commit -qm x ) >/dev/null 2>&1 || fail "cannot make a repo"
	_o=$(TSEM_VM_SELFTEST=1 TSEM_VM_FAKE_SUITE='echo "60 passed, 0 failed (fake)"' "$SH" "$T/repo/tools/run-netns-vm.sh" --out "$T/o2" --sha deadbeef 2>&1); _rc=$?
	assert_contains note "uncommitted changes: mismatch" "$_o"
	assert_eq rc 0 "$_rc"   # selftest ignores attribution, the note proves it was detected
	_o=$(TSEM_VM_FAKE_SUITE='x' PATH=$(_nofw_path) "$SH" "$T/repo/tools/run-netns-vm.sh" --out "$T/o3" --sha deadbeef 2>&1); _rc=$?
	assert_eq rc-real 2 "$_rc"
}
