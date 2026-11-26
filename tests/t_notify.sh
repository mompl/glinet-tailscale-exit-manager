# shellcheck shell=sh
# tsem-notify: messages without Home Assistant. A curl stand-in records what would be sent; no network is used.

_nt_setup() {
	t_setup
	mkdir -p "$T/bin"
	export TSEM_NOTIFY_CONF=$T/notify.conf TSEM_CURL=$T/bin/curl TSEM_BIN="$T/bin/tsem"
	printf '#!/bin/sh\nexec "%s" "%s/src/usr/sbin/tsem" "$@"\n' "$SH" "$ROOT" >"$T/bin/tsem"; chmod +x "$T/bin/tsem"
	# curl stand-in: appends "ARGS|BODY" lines, succeeds unless $T/curl.fail exists; -K reads the config file passed in
	cat >"$T/bin/curl" <<CURL
#!/bin/sh
[ -e "$T/curl.fail" ] && exit 22
cfg='' body='' url=''
while [ \$# -gt 0 ]; do case \$1 in -K) cfg=\$2; shift 2 ;; -d) body=\$2; shift 2 ;; -s|-f) shift ;; -m) shift 2 ;; *) url=\$1; shift ;; esac; done
printf 'URL=%s BODY=%s CFG=%s\n' "\$url" "\$body" "\$(tr '\n' ';' <"\$cfg")" >>"$T/curl.log"
CURL
	chmod +x "$T/bin/curl"
	: >"$T/curl.log"
}
_nt_conf() { printf 'NOTIFY_URL=https://ntfy.example/topic-abc\nNOTIFY_NAME=r1\n%s\n' "$1" >"$T/notify.conf"; }
_nt() { "$SH" "$ROOT/src/usr/sbin/tsem-notify" "$@"; }

test_notify_sends_for_failover_blocked_and_recovered_only() {
	_nt_setup; _nt_conf ''
	_nt tick PRIMARY_ACTIVE SECONDARY_ACTIVE; _nt tick SECONDARY_ACTIVE BLOCKED; _nt tick BLOCKED PRIMARY_ACTIVE
	_nt tick CONNECTING_PRIMARY CONNECTING_PRIMARY; _nt tick PRIMARY_ACTIVE DISABLED
	assert_eq lines 3 "$(wc -l <"$T/curl.log" | tr -d ' ')"
	assert_contains failover "backup exit node took over" "$(sed -n 1p "$T/curl.log")"
	assert_contains blocked "BLOCKED" "$(sed -n 2p "$T/curl.log")"
	assert_contains prio "Priority: urgent" "$(sed -n 2p "$T/curl.log")"
	assert_contains recovered "back on the primary" "$(sed -n 3p "$T/curl.log")"
	assert_contains url "URL=https://ntfy.example/topic-abc" "$(sed -n 1p "$T/curl.log")"
}

test_notify_does_nothing_without_a_config_and_with_an_invalid_url() {
	_nt_setup; rm -f "$T/notify.conf"
	_nt tick PRIMARY_ACTIVE BLOCKED; [ ! -s "$T/curl.log" ] || fail "no config: nothing may be sent"
	printf 'NOTIFY_URL=ftp://x/y\n' >"$T/notify.conf"; _nt tick PRIMARY_ACTIVE BLOCKED; [ ! -s "$T/curl.log" ] || fail "bad URL: nothing may be sent"
	printf 'NOTIFY_URL=https://x.example/a;reboot\n' >"$T/notify.conf"; _nt tick PRIMARY_ACTIVE BLOCKED; [ ! -s "$T/curl.log" ] || fail "unsafe URL: nothing may be sent"
}

test_notify_queues_while_unreachable_and_sends_later_with_the_original_event() {
	_nt_setup; _nt_conf ''
	: >"$T/curl.fail"
	_nt tick SECONDARY_ACTIVE BLOCKED
	[ ! -s "$T/curl.log" ] || fail "nothing can be sent while curl fails"
	assert_contains queued "|blocked|" "$(_nt queue)"
	rm -f "$T/curl.fail"
	_nt tick BLOCKED BLOCKED
	assert_contains sent "BLOCKED" "$(cat "$T/curl.log")"
	assert_eq empty "(empty)" "$(_nt queue)"
}

test_notify_queue_is_capped_at_twenty_lines() {
	_nt_setup; _nt_conf ''
	: >"$T/curl.fail"
	_i=0; while [ $_i -lt 30 ]; do _nt tick PRIMARY_ACTIVE BLOCKED; _i=$((_i + 1)); done
	assert_eq cap 20 "$(_nt queue | wc -l | tr -d ' ')"
}

test_notify_webhook_posts_json_and_token_goes_in_a_header_file_not_the_command_line() {
	_nt_setup
	printf 'sekret-token\n' >"$T/tok"
	_nt_conf "NOTIFY_TYPE=webhook
NOTIFY_TOKEN_FILE=$T/tok"
	_nt tick PRIMARY_ACTIVE SECONDARY_ACTIVE
	_l=$(cat "$T/curl.log")
	assert_contains json '"event":"failover"' "$_l"
	assert_contains router '"router":"r1"' "$_l"
	assert_contains hdr 'Authorization: Bearer sekret-token' "$_l"
}

test_notify_test_command_reports_success_and_failure() {
	_nt_setup; _nt_conf ''
	assert_contains ok "sent to https://ntfy.example/topic-abc" "$(_nt test)"
	: >"$T/curl.fail"
	if _nt test >/dev/null 2>&1; then fail "a failed send must exit non-zero"; fi
}

test_controller_starts_the_notifier_only_when_configured_and_state_changed() {
	_nt_setup
	printf '#!/bin/sh\necho "$*" >>"%s/notify.calls"\n' "$T" >"$T/bin/fake-notify"; chmod +x "$T/bin/fake-notify"
	export TSEM_NOTIFY_BIN=$T/bin/fake-notify
	rm -f "$T/notify.conf"
	tsem set german --no-wait >/dev/null 2>&1; tick_n 12 2>/dev/null || { _i=0; while [ $_i -lt 12 ]; do tsem tick >/dev/null 2>&1; TSEM_NOW=$((TSEM_NOW + 5)); export TSEM_NOW; _i=$((_i + 1)); done; }
	sleep 1
	[ ! -s "$T/notify.calls" ] || fail "without a config file the notifier must not run"
	_nt_conf ''
	tsem set direct --no-wait >/dev/null 2>&1; tsem tick >/dev/null 2>&1; : >"$T/notify.calls"; tsem set german --no-wait >/dev/null 2>&1; _i=0; while [ $_i -lt 12 ]; do tsem tick >/dev/null 2>&1; TSEM_NOW=$((TSEM_NOW + 5)); export TSEM_NOW; _i=$((_i + 1)); done
	sleep 1
	assert_contains called "tick " "$(cat "$T/notify.calls" 2>/dev/null)"
}

test_switching_to_direct_or_blocked_by_hand_sends_a_message_but_switching_to_exit_does_not_announce_blocked() {
	_nt_setup; _nt_conf ''
	printf '#!/bin/sh\necho "$*" >>"%s/notify.calls"\n' "$T" >"$T/bin/fake-notify"; chmod +x "$T/bin/fake-notify"
	export TSEM_NOTIFY_BIN=$T/bin/fake-notify
	: >"$T/notify.calls"
	tsem set german --no-wait >/dev/null 2>&1
	sleep 1
	[ ! -s "$T/notify.calls" ] || fail "set exit must not announce a transitional BLOCKED"
	go_german
	: >"$T/notify.calls"
	tsem set direct --no-wait >/dev/null 2>&1
	sleep 1
	assert_contains direct "tick PRIMARY_ACTIVE DISABLED" "$(cat "$T/notify.calls" 2>/dev/null)"
	: >"$T/notify.calls"
	tsem set blocked --no-wait >/dev/null 2>&1
	sleep 1
	assert_contains blocked "BLOCKED" "$(cat "$T/notify.calls" 2>/dev/null)"
}

test_notify_tries_the_fallback_address_when_the_main_one_does_not_work() {
	_nt_setup
	# stand-in: the public address fails, every other one works
	cat >"$T/bin/curl" <<CURL
#!/bin/sh
cfg='' body='' url=''
while [ \$# -gt 0 ]; do case \$1 in -K) cfg=\$2; shift 2 ;; -d) body=\$2; shift 2 ;; -s|-f) shift ;; -m) shift 2 ;; *) url=\$1; shift ;; esac; done
printf 'URL=%s\n' "\$url" >>"$T/curl.log"
case \$url in https://public.example/*) exit 22 ;; esac
CURL
	chmod +x "$T/bin/curl"
	printf 'NOTIFY_URL=https://public.example/t\nNOTIFY_URL_FALLBACK=http://192.0.2.10:8098/t\nNOTIFY_NAME=r1\n' >"$T/notify.conf"
	_nt tick PRIMARY_ACTIVE BLOCKED
	assert_contains main "URL=https://public.example/t" "$(cat "$T/curl.log")"
	assert_contains fallback "URL=http://192.0.2.10:8098/t" "$(cat "$T/curl.log")"
	assert_eq "sent, queue empty" "(empty)" "$(_nt queue)"
}
