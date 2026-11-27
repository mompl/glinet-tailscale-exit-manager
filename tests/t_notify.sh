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
	assert_contains ok "sent via ntfy.example" "$(_nt test)"
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

# a curl stand-in that logs URL and the token header per request, and fails for every URL that contains the text in $T/curl.failurl
_nt_curl_per_url() {
	cat >"$T/bin/curl" <<CURL
#!/bin/sh
cfg='' body='' url=''
while [ \$# -gt 0 ]; do case \$1 in -K) cfg=\$2; shift 2 ;; -d) body=\$2; shift 2 ;; -s|-f) shift ;; -m) shift 2 ;; *) url=\$1; shift ;; esac; done
printf 'URL=%s AUTH=%s\n' "\$url" "\$(sed -n 's/^header = "Authorization: Bearer \(.*\)"\$/\1/p' "\$cfg")" >>"$T/curl.log"
[ -s "$T/curl.failurl" ] && case \$url in *\$(cat "$T/curl.failurl")*) exit 22 ;; esac
exit 0
CURL
	chmod +x "$T/bin/curl"
}

test_notify_every_address_uses_its_own_token_and_the_fallback_never_gets_the_main_token() {
	_nt_setup; _nt_curl_per_url
	printf 'main-token\n' >"$T/tok1"; printf 'lan-token\n' >"$T/tok2"; printf 'public\n' >"$T/curl.failurl"
	printf 'NOTIFY_URL=https://public.example/t\nNOTIFY_URL_FALLBACK=http://lan.example:8098/t\nNOTIFY_TOKEN_FILE=%s\nNOTIFY_TOKEN_FILE_FALLBACK=%s\nNOTIFY_NAME=r1\n' "$T/tok1" "$T/tok2" >"$T/notify.conf"
	_nt tick PRIMARY_ACTIVE BLOCKED
	assert_contains main "URL=https://public.example/t AUTH=main-token" "$(cat "$T/curl.log")"
	assert_contains fallback "URL=http://lan.example:8098/t AUTH=lan-token" "$(cat "$T/curl.log")"
	case $(cat "$T/curl.log") in *"lan.example:8098/t AUTH=main-token"*) fail "the fallback must not receive the main token" ;; esac
}

test_notify_fallback_uses_the_main_token_when_it_has_none_of_its_own() {
	_nt_setup; _nt_curl_per_url
	printf 'main-token\n' >"$T/tok1"; printf 'public\n' >"$T/curl.failurl"
	printf 'NOTIFY_URL=https://public.example/t\nNOTIFY_URL_FALLBACK=http://lan.example:8098/t\nNOTIFY_TOKEN_FILE=%s\nNOTIFY_NAME=r1\n' "$T/tok1" >"$T/notify.conf"
	_nt tick PRIMARY_ACTIVE BLOCKED
	assert_contains fallback "URL=http://lan.example:8098/t AUTH=main-token" "$(cat "$T/curl.log")"
}

test_notify_setup_writes_a_private_config_for_an_own_server_with_a_fallback() {
	_nt_setup
	_o=$(_nt setup --server https://ntfy.example --topic my-topic --fallback-server http://192.0.2.10:8098 --token-file "$T/tok1" --fallback-token-file "$T/tok2" --name r9 --events "blocked failover")
	assert_contains saved "saved" "$_o"
	_c=$(cat "$T/notify.conf")
	assert_contains url "NOTIFY_URL=https://ntfy.example/my-topic" "$_c"
	assert_contains fb "NOTIFY_URL_FALLBACK=http://192.0.2.10:8098/my-topic" "$_c"
	assert_contains tok "NOTIFY_TOKEN_FILE=$T/tok1" "$_c"
	assert_contains tok2 "NOTIFY_TOKEN_FILE_FALLBACK=$T/tok2" "$_c"
	assert_contains name "NOTIFY_NAME=r9" "$_c"
	assert_contains ev 'NOTIFY_EVENTS="blocked failover"' "$_c"
	assert_eq mode 600 "$(stat -c %a "$T/notify.conf" 2>/dev/null || stat -f %Lp "$T/notify.conf")"
	# what was written must be accepted by the sender
	: >"$T/curl.log"; printf '' >"$T/curl.fail.none"
	_nt test >/dev/null 2>&1 || fail "the written config must work"
	assert_contains sent "URL=https://ntfy.example/my-topic" "$(cat "$T/curl.log")"
}

test_notify_setup_public_makes_a_random_topic_on_ntfy_sh_and_warns() {
	_nt_setup
	_o=$(_nt setup --public --name r1)
	assert_contains warn "public server" "$_o"
	_u=$(sed -n 's/^NOTIFY_URL=//p' "$T/notify.conf")
	case $_u in https://ntfy.sh/tsem-[a-z0-9]*) ;; *) fail "public setup must use ntfy.sh with a tsem-... topic, got $_u" ;; esac
	_t=${_u#https://ntfy.sh/tsem-}
	assert_eq "24 random characters" 24 "${#_t}"
	_nt setup --public --name r1 >/dev/null
	_u2=$(sed -n 's/^NOTIFY_URL=//p' "$T/notify.conf")
	[ "$_u" != "$_u2" ] || fail "two public setups must not give the same topic"
}

test_notify_setup_refuses_unsafe_or_incomplete_input_and_keeps_the_old_config() {
	_nt_setup; _nt_conf ''
	_before=$(cat "$T/notify.conf")
	for _a in "--server ftp://x/y --topic t" "--server https://x.example --topic bad/topic" "--server https://x.example" \
		"--server https://x.example/a;reboot --topic t" "--server https://x.example --topic t --token-file relative" \
		"--server https://x.example --topic t --name a;b" "--public --server https://x.example" "--server https://x.example --topic t --events X;Y" \
		"--bogus"; do
		# shellcheck disable=SC2086
		if _nt setup $_a >/dev/null 2>&1; then fail "setup must refuse: $_a"; fi
		assert_eq "config untouched after: $_a" "$_before" "$(cat "$T/notify.conf")"
	done
}

test_notify_token_command_stores_the_token_privately_and_never_prints_it() {
	_nt_setup
	_o=$(printf 'tk_abc123XYZ\n' | _nt token "$T/the.token")
	assert_contains ok "stored" "$_o"
	case $_o in *abc123XYZ*) fail "the token must not be printed" ;; esac
	assert_eq content "tk_abc123XYZ" "$(cat "$T/the.token")"
	assert_eq mode 600 "$(stat -c %a "$T/the.token" 2>/dev/null || stat -f %Lp "$T/the.token")"
	if printf '\n' | _nt token "$T/e.token" >/dev/null 2>&1; then fail "an empty token must be refused"; fi
	if printf 'a;b\n' | _nt token "$T/e.token" >/dev/null 2>&1; then fail "an odd token must be refused"; fi
	[ ! -e "$T/e.token" ] || fail "nothing may be written for a refused token"
	if printf 'abc\n' | _nt token relative.token >/dev/null 2>&1; then fail "a relative file name must be refused"; fi
}

test_notify_show_and_test_never_print_the_topic_or_a_token() {
	_nt_setup
	printf 'sekret-token\n' >"$T/tok1"
	printf 'NOTIFY_URL=https://ntfy.example/very-secret-topic\nNOTIFY_URL_FALLBACK=http://192.0.2.10:8098/very-secret-topic\nNOTIFY_TOKEN_FILE=%s\nNOTIFY_NAME=r1\n' "$T/tok1" >"$T/notify.conf"
	_s=$(_nt show)
	assert_contains host "ntfy.example" "$_s"
	assert_contains fb "192.0.2.10:8098" "$_s"
	assert_contains tokflag "token: yes" "$_s"
	case $_s in *very-secret-topic* | *sekret-token*) fail "show must not print the topic or the token" ;; esac
	_t=$(_nt test 2>&1)
	case $_t in *very-secret-topic* | *sekret-token*) fail "test must not print the topic or the token" ;; esac
}

test_notify_report_sends_a_clean_one_line_text_even_when_the_event_is_not_listed() {
	_nt_setup; _nt_conf 'NOTIFY_EVENTS="blocked"'
	_nt report 'week report (7 d): EXIT 99%|, 1 failover(s)' || fail "report must succeed"
	_l=$(cat "$T/curl.log")
	assert_contains url "URL=https://ntfy.example/topic-abc" "$_l"
	assert_contains text "r1: week report (7 d): EXIT 99%, 1 failover(s)" "$_l"
	assert_contains title "Title: tsem report" "$_l"
	assert_contains tag "Tags: bar_chart" "$_l"
	assert_eq "queue empty" "(empty)" "$(_nt queue)"
	assert_rc "needs a text" 2 _nt report
}
