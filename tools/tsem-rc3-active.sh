#!/bin/sh
# tsem-rc3-active.sh - router side of the Mac-controlled RC3 upgrade and ACTIVE hardware acceptance.
# Called step by step by tools/run-rc3-active-mac.sh from a staged copy of the repository
# (never run by hand without reading docs/rc/rc3-active.md). Every subcommand states whether it
# changes the router.
#
#   READ-ONLY            preflight | status | recovery-status | diag-bundle | nodes-check | direct-path-check | api-check | extnet-check | switch-watch
#   WRITES A BACKUP      backup                       (new directory below /root, nothing else)
#   WRITES A COPY        stage-rc3                    (side directory below /root; NO live file, hook, include or service is touched)
#   CHANGES LIVE FILES   wire --confirm-wire          (install.sh --yes, journaled, only with the watchdog armed; auto-restore on failed verification)
#                        install-recover --confirm-repair   (replays an interrupted install's journal)
#   RECOVERY             recovery-arm S | recovery-keepalive | recovery-disarm | recover
#   ACTIVE (disruptive)  test t00..t08 | test all     (see docs/rc/rc3-active.md for every effect)
#   EXPLICIT, SEPARATE   rollback --confirm-rollback | return-to-direct --confirm-direct | activate --confirm-activate
#
# Output lines: LEVEL id text   with LEVEL PASS | WARN | FAIL | SKIP | INFO. Exit 0 = no FAIL, 1 = FAIL, 2 = refused/usage.
#
# Hard rules, enforced by tests/t_rc3_active.sh:
#   - nothing here ever runs `tsem set direct` except `return-to-direct --confirm-direct`;
#   - tests refuse to start unless the recovery watchdog is armed;
#   - test faults exist only as environment variables of the foreground `tsem tick` calls (tailnet,
#     firewall, routing and tailscale prefs are never faulted); a lost connection therefore leaves
#     nothing that recovery has to repair except the exit node choice;
#   - after any test the guard is german or blocked, never open.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
R=${PF_ROOT:-}
R=${R%/}
TSEM=${TSEM_BIN:-$R/usr/sbin/tsem}
AR_RUN=${AR_RUN:-/tmp/tsem-rc3-active}
RC_DIR=$AR_RUN/recovery
BK_BASE=${AR_BK_BASE:-$R/root}
INITD=${AR_INITD:-$R/etc/init.d}
FAULT_NAME_P=tsem-rc3-test-no-such-primary
FAULT_NAME_S=tsem-rc3-test-no-such-secondary
NP=0 NW=0 NF=0 NS=0
CURL_CONTROL=none
FP='' FS=''

now() { if [ -n "${TSEM_NOW:-}" ]; then echo "$TSEM_NOW"; else date +%s; fi; }
# waitt SECONDS: sleeps, or advances the fake clock when AR_FAKE_CLOCK=1 (unit tests)
waitt() {
	if [ "${AR_FAKE_CLOCK:-0}" = 1 ]; then TSEM_NOW=$(($(now) + $1)); export TSEM_NOW; else sleep "$1"; fi
}
oneline() { tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-300; }
emit() { printf '%-5s %-24s %s\n' "$1" "$2" "$(printf '%s' "$3" | oneline)"; }
sect() { printf '\n== %s\n' "$1"; }
pass() { NP=$((NP + 1)); emit PASS "$1" "$2"; }
warn() { NW=$((NW + 1)); emit WARN "$1" "$2"; }
fail() { NF=$((NF + 1)); emit FAIL "$1" "$2"; }
skip() { NS=$((NS + 1)); emit SKIP "$1" "$2"; }
info() { emit INFO "$1" "$2"; }
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
have() { case " ${AR_MISSING:-} " in *" $1 "*) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; } # AR_MISSING: test hook, pretends tools are absent
finish() { echo "SUMMARY PASS=$NP WARN=$NW FAIL=$NF SKIP=$NS"; [ "$NF" -eq 0 ] && exit 0 || exit 1; }
refuse() { echo "REFUSED: $1" >&2; exit 2; }

# ---- recovery helpers (the watchdog itself is tsem-rc3-recover.sh, a separate process) ----
# armed = the armed marker AND a fresh heartbeat (written by the running watcher with the real clock): a stale or dead watcher never counts
armed() {
	[ -e "$RC_DIR/armed" ] || return 1
	_hb=$(cat "$RC_DIR/hb" 2>/dev/null)
	case $_hb in '' | *[!0-9]*) return 1 ;; esac
	[ $(($(date +%s) - _hb)) -le "${AR_HB_FRESH:-20}" ]
}
ka() { # keepalive with the real clock (the watcher compares against the real clock); atomic replace
	[ -e "$RC_DIR/armed" ] || return 0
	echo $(($(date +%s) + $(cat "$RC_DIR/timeout" 2>/dev/null || echo 300))) >"$RC_DIR/deadline.new" 2>/dev/null && mv -f "$RC_DIR/deadline.new" "$RC_DIR/deadline" 2>/dev/null
	return 0
}

# ---- controller state ----
snap() { # one `tsem status`; sets S_*
	_s=$("$TSEM" status 2>/dev/null)
	S_state=$(kv "$_s" state) S_guard=$(kv "$_s" guard) S_exit=$(kv "$_s" exit_node) S_leak=$(kv "$_s" leak_risk)
	S_mode=$(kv "$_s" mode) S_ks=$(kv "$_s" kill_switch_active) S_primary=$(kv "$_s" primary) S_secondary=$(kv "$_s" secondary)
	S_active=$(kv "$_s" active_exit) S_intent=$(kv "$_s" intent) S_ps=$(kv "$_s" primary_ok) S_ss=$(kv "$_s" secondary_ok)
	S_ver=$(kv "$_s" version) S_boot=$(kv "$_s" boot_failed)
}
# tick with the current fault simulation (environment of this one call only)
do_tick() {
	_e=''
	[ -z "$FP" ] || _e="$_e TSEM_PRIMARY_NAME=$FP"
	[ -z "$FS" ] || _e="$_e TSEM_SECONDARY_NAME=$FS"
	# shellcheck disable=SC2086
	env $_e "$TSEM" tick >/dev/null 2>&1
}
installed_version() { sed -n 's/^TSEM_VERSION=//p' "$R/usr/lib/tsem/common.sh" 2>/dev/null | head -n 1 | tr -d '"'"'"; }
stage_version() { sed -n 's/^TSEM_VERSION=//p' "$REPO/src/usr/lib/tsem/common.sh" 2>/dev/null | head -n 1 | tr -d '"'"'"; }
hsum() { if have sha256sum; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1; else md5sum "$1" 2>/dev/null | cut -d' ' -f1; fi; }

# ================================================================== preflight (read-only)
cmd_preflight() {
	sect "Preflight (read-only)"
	_iv=$(installed_version)
	info installed.version "${_iv:-none}"
	info stage.version "$(stage_version)"
	case $_iv in
	"$(stage_version)") warn installed.current "the staged version ($_iv) is already installed: wire is skipped, tests run against it" ;;
	*rc2*) pass installed.rc2 "RC2 is installed (upgrade path: install with automatic rollback data)" ;;
	*rc3*) pass installed.rc3 "RC3 ($_iv) is installed (upgrade path: install with automatic rollback data, user configuration kept)" ;;
	'') warn installed.none "no tsem installed: fresh install" ;;
	*) warn installed.other "unexpected installed version $_iv" ;;
	esac
	if ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon'; then
		fail daemon.running "a tsem daemon is running: stop it first (/etc/init.d/tsem stop never opens the guard); its probes would fight the test"
	else pass daemon.stopped "no tsem daemon running"; fi
	have tailscale && pass tailscale.present "$(tailscale version 2>/dev/null | head -n 1)" || fail tailscale.present "tailscale not found"
	if have tailscale && tailscale status >/dev/null 2>&1; then pass tailscale.up "tailscale status answers"; else fail tailscale.up "tailscale status does not answer"; fi
	# how is this SSH session connected? tailnet sessions die when tailscale restarts
	_cl=${SSH_CLIENT:-}
	_cl=${_cl%% *}
	_path=unknown
	if [ -n "$_cl" ] && have ip; then
		case $(ip route get "$_cl" 2>/dev/null | head -n 1) in
		*"dev br-lan"*) _path=lan ;;
		*"dev tailscale0"*) _path=tailnet ;;
		*) _path=other ;;
		esac
	fi
	info "ssh.path" "$_path client=${_cl:-unknown}"
	echo "SSH_PATH=$_path"
	[ "$_path" = lan ] || warn ssh.path "this session does not come from the LAN ($_path): no LAN-client observation, and the Tailscale restart test will be skipped"
	if [ -x "$TSEM" ]; then
		snap
		info controller.state "version=$S_ver mode=$S_mode state=$S_state guard=$S_guard exit=$S_exit intent=$S_intent leak_risk=$S_leak"
		echo "GUARD_BEFORE=$S_guard"
	fi
	# hardware switch and competing controller
	if [ -e "$R/etc/gl-switch.d/tailscale-de.sh" ]; then info hwswitch.hook "present: $R/etc/gl-switch.d/tailscale-de.sh (md5 $(md5sum "$R/etc/gl-switch.d/tailscale-de.sh" 2>/dev/null | cut -c1-32)); do NOT operate the hardware switch during the tests"; fi
	_hwf=$(sed -n 's/^TSEM_HW_STATE_FILE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$R/etc/tsem/tsem.conf" 2>/dev/null | head -n 1)
	if [ -n "$_hwf" ] && [ -r "$R$_hwf" ]; then info hwswitch.state "$_hwf: $(head -n 1 "$R$_hwf")"; else warn hwswitch.state "hardware switch position not readable (TSEM_HW_STATE_FILE unset): note it manually before the tests"; fi
	if [ -e "$R/etc/rc.d/S18tsem" ]; then info boot.link "present (RC2 boot link): kept as is"; else info boot.link "absent: nothing starts tsem at boot"; fi
	_df=$(df -k "$BK_BASE" 2>/dev/null | awk 'NR == 2 { print $4 }')
	[ -n "$_df" ] && [ "$_df" -gt 2048 ] 2>/dev/null && pass backup.space "${_df} KB free for the backup" || warn backup.space "free space for the backup unknown or below 2 MB (${_df:-?} KB)"
	if armed; then info recovery "armed: $(sh "$RC_DIR/../recover.sh" status 2>/dev/null)"; else info recovery "not armed"; fi
	finish
}

# ================================================================== backup
# fsum FILE: hash of a file, "none" if it does not exist
# inst_sh INSTALL_SH ARGS: install.sh against the live root (or $PF_ROOT in the tests)
inst_sh() { _is=$1; shift; if [ -n "$R" ]; then sh "$_is" --root "$R" "$@"; else sh "$_is" "$@"; fi; }
fsum() { if [ -e "$1" ]; then hsum "$1"; else echo none; fi; }
# live handlers: everything that can run or start tsem without an operator (hotplug, fw3 include,
# init script, boot links, GL hook, controller files, config). `prepare` must leave this identical.
live_fingerprint() {
	for _p in usr/sbin/tsem usr/sbin/tsem-mqtt usr/lib/tsem etc/init.d/tsem etc/tsem/tsem.conf etc/tsem/intent etc/hotplug.d etc/rc.d etc/gl-switch.d etc/config/firewall; do
		[ -e "$R/$_p" ] || [ -L "$R/$_p" ] || continue
		find "$R/$_p" \( -type f -o -type l \) 2>/dev/null | sort | while IFS= read -r _f; do
			if [ -L "$_f" ]; then printf '%s -> %s\n' "$_f" "$(readlink "$_f" 2>/dev/null)"; else printf '%s %s\n' "$_f" "$(hsum "$_f")"; fi
		done
	done
}
cmd_backup() {
	sect "Backup (writes only a new directory below $BK_BASE)"
	have tar || { fail backup.tool "tar is missing: no backup possible"; finish; }
	if ! have sha256sum && ! have md5sum; then fail backup.tool "neither sha256sum nor md5sum is available: a backup cannot be verified"; finish; fi
	_stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null)-$$
	BK=$BK_BASE/tsem-rc3-backup-$_stamp
	( umask 077 && mkdir -p "$BK_BASE" && mkdir "$BK" ) || { fail backup.dir "cannot create $BK"; finish; }
	chmod 700 "$BK" 2>/dev/null
	_list=''
	: >"$BK/expected.txt"
	for _p in usr/sbin/tsem usr/sbin/tsem-mqtt usr/lib/tsem etc/init.d/tsem etc/tsem etc/hotplug.d/iface/50-tsem etc/gl-switch.d etc/rc.d/S18tsem etc/rc.d/K10tsem \
		etc/config/firewall etc/config/network etc/config/dhcp etc/config/system etc/config/tailscale etc/crontabs; do
		if [ -e "$R/$_p" ] || [ -L "$R/$_p" ]; then _list="$_list $_p"; echo "$_p" >>"$BK/expected.txt"; fi
	done
	for _g in "$R"/etc/config/gl*; do if [ -e "$_g" ]; then _list="$_list ${_g#"$R"/}"; echo "${_g#"$R"/}" >>"$BK/expected.txt"; fi; done
	# the firewall and network config exist on every OpenWrt/GL.iNet router: absent means this is not what we think it is
	for _need in etc/config/firewall etc/config/network; do
		[ -e "$R/$_need" ] || { fail backup.required "required file /$_need is missing on the router: refusing to continue"; finish; }
	done
	_ver=$(installed_version)
	if [ -n "$_ver" ]; then
		for _need in usr/sbin/tsem usr/lib/tsem/common.sh etc/init.d/tsem; do
			[ -e "$R/$_need" ] || { fail backup.required "tsem $_ver is installed but /$_need is missing: incomplete installation, refusing to continue"; finish; }
		done
	fi
	# shellcheck disable=SC2086
	if ! ( cd "${R:-/}" && tar cf "$BK/files.tar" $_list ) 2>"$BK/tar.err"; then fail backup.tar "tar failed: $(head -n 1 "$BK/tar.err")"; finish; fi
	_hs=$(hsum "$BK/files.tar")
	[ -n "$_hs" ] || { fail backup.hash "cannot hash the archive"; finish; }
	echo "$_hs" >"$BK/files.tar.sum"
	{
		echo "version.installed=$_ver"
		echo "guard.before=$( [ -x "$TSEM" ] && { snap; echo "$S_guard"; } || echo none )"
		echo "mode.before=$( [ -x "$TSEM" ] && { snap; echo "$S_mode"; } || echo none )"
		echo "intent.sum=$(fsum "$R/etc/tsem/intent")"
		echo "tsemconf.sum=$(fsum "$R/etc/tsem/tsem.conf")"
		echo "hook.sum=$(fsum "$R/etc/gl-switch.d/tailscale-de.sh")"
		echo "bootlink=$( [ -e "$R/etc/rc.d/S18tsem" ] && echo yes || echo no )"
		echo "stamp=$_stamp"
	} >"$BK/manifest.txt"
	have iptables-save && iptables-save >"$BK/iptables.txt" 2>/dev/null
	have ip6tables-save && ip6tables-save >"$BK/ip6tables.txt" 2>/dev/null
	if have ip; then { echo "# ip rule"; ip rule show; echo "# ip -6 rule"; ip -6 rule show; echo "# routes"; ip route show table all; echo "# routes6"; ip -6 route show table all; } >"$BK/ip.txt" 2>/dev/null; fi
	have uci && uci export firewall >"$BK/uci-firewall.txt" 2>/dev/null
	have lsmod && lsmod >"$BK/lsmod.txt" 2>/dev/null
	have tailscale && tailscale status >"$BK/tailscale-status.txt" 2>/dev/null
	_hwf=$(sed -n 's/^TSEM_HW_STATE_FILE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$R/etc/tsem/tsem.conf" 2>/dev/null | head -n 1)
	if [ -n "$_hwf" ]; then { echo "file=$_hwf"; head -n 1 "$R$_hwf" 2>/dev/null; } >"$BK/hwswitch.txt"; else echo "state unknown: TSEM_HW_STATE_FILE not set" >"$BK/hwswitch.txt"; fi
	chmod 600 "$BK"/* 2>/dev/null
	if backup_gate "$BK"; then
		echo "BACKUP_DIR=$BK"
		echo "BACKUP_SUM=$(cat "$BK/files.tar.sum")"
		info backup.secret "the archive holds network/firewall config: keep it private (mode 600, never upload)"
		mkdir -p "$AR_RUN" && echo "$BK" >"$AR_RUN/backup.dir"
	else fail backup.verified "the backup did NOT pass verification: nothing may be installed; $BK is incomplete"; fi
	finish
}

# backup_gate DIR: the backup is complete and verified, or this fails. Prints PASS/FAIL lines, returns 0 only if all hold.
# Used after the backup, before staging and again before any live change.
backup_gate() {
	_d=$1 _gf=0
	_gfail() { fail "$1" "$2"; _gf=1; }
	have tar || _gfail backup.tool "tar is missing"
	if ! have sha256sum && ! have md5sum; then _gfail backup.tool "no hash tool (sha256sum/md5sum): the backup cannot be verified"; fi
	for _f in files.tar files.tar.sum manifest.txt expected.txt; do [ -s "$_d/$_f" ] || _gfail "backup.$_f" "$_f missing or empty in $_d"; done
	[ "$_gf" -eq 0 ] || return 1
	_s1=$(hsum "$_d/files.tar")
	if [ -n "$_s1" ] && [ "$_s1" = "$(cat "$_d/files.tar.sum")" ]; then pass backup.checksum "archive checksum matches"; else _gfail backup.checksum "archive checksum does not match or cannot be computed"; fi
	_man=$(cat "$_d/manifest.txt")
	for _k in version.installed guard.before mode.before intent.sum tsemconf.sum hook.sum bootlink stamp; do
		case $_man in *"$_k="*) ;; *) _gfail backup.manifest "manifest lacks $_k" ;; esac
	done
	_ls=$(tar tf "$_d/files.tar" 2>/dev/null) || _gfail backup.list "archive cannot be listed"
	_miss=''
	while IFS= read -r _p; do
		[ -n "$_p" ] || continue
		printf '%s\n' "$_ls" | awk -v p="$_p" '{ sub(/^\.\//, "") } $0 == p || $0 == p "/" || index($0, p "/") == 1 { f = 1 } END { exit !f }' || _miss="$_miss $_p"
	done <"$_d/expected.txt"
	[ -z "$_miss" ] && pass backup.complete "all $(wc -l <"$_d/expected.txt" | tr -d ' ') expected paths are in the archive" || _gfail backup.complete "missing in the archive:$_miss"
	# extract into a scratch dir and compare the three files that must survive an upgrade
	_x=$_d/verify.$$
	if mkdir "$_x" 2>/dev/null && tar xf "$_d/files.tar" -C "$_x" 2>/dev/null; then
		for _pair in "intent.sum:etc/tsem/intent" "tsemconf.sum:etc/tsem/tsem.conf" "hook.sum:etc/gl-switch.d/tailscale-de.sh"; do
			_key=${_pair%%:*} _fp=${_pair#*:}
			_want=$(kv "$_man" "$_key")
			_got=$(fsum "$_x/$_fp")
			[ "$_want" = "$_got" ] || _gfail "backup.$_key" "archived $_fp ($_got) differs from the manifest ($_want)"
		done
		[ "$_gf" -eq 0 ] && pass backup.extract "archive extracts and its intent/config/hook match the manifest"
	else _gfail backup.extract "archive does not extract"; fi
	rm -rf "$_x"
	# firewall/route snapshots (restore data) must exist for every tool the router has
	have iptables-save && { [ -s "$_d/iptables.txt" ] || _gfail backup.iptables "iptables.txt empty although iptables-save exists"; }
	have ip && { [ -s "$_d/ip.txt" ] || _gfail backup.ip "ip.txt empty although ip exists"; }
	have uci && { [ -s "$_d/uci-firewall.txt" ] || _gfail backup.uci "uci-firewall.txt empty although uci exists"; }
	[ "$_gf" -eq 0 ] && pass backup.verified "backup is complete and verified ($_d)"
	return "$_gf"
}

cmd_backup_stream() { # the Mac pulls the backup directory as a tar stream
	_d=${1:-}
	case $_d in "$BK_BASE"/tsem-rc3-backup-[0-9]*) ;; *) refuse "not a backup directory of this tool" ;; esac
	case $_d in *..*) refuse "unsafe path" ;; esac
	[ -d "$_d" ] || refuse "no such backup"
	tar cf - -C "$BK_BASE" "$(basename "$_d")"
}

# ================================================================== stage-rc3 (prepare): a COPY, nothing live changes
# The previous "passive install" ran install.sh on the live router. That installs the hotplug handler and the
# fw3 include, which run `tsem reapply`/`tsem tick` at the next interface or firewall event: RC3 was active at once.
# stage-rc3 only copies the tested tree to a side directory, proves it there (hash manifest, syntax, a trial
# install into a throw-away root) and proves that no live handler changed. Going live is `wire`.
valid_dir() { case $1 in "$BK_BASE"/tsem-rc3-"$2"-[0-9]*) case $1 in *[!A-Za-z0-9._/-]* | *..*) return 1 ;; esac; return 0 ;; esac; return 1; }
cmd_stage_rc3() {
	_bk=${1:-}
	valid_dir "$_bk" backup && [ -d "$_bk" ] || refuse "stage-rc3 needs the directory of a completed backup"
	sect "Stage RC3 $(stage_version) in a side directory (no live file, hook, include, boot link, rule or service is touched)"
	backup_gate "$_bk" || { fail stage.backup "backup gate failed: nothing staged"; finish; }
	_fp1=$(live_fingerprint)
	_sd=$BK_BASE/tsem-rc3-stage-$(date +%Y%m%d-%H%M%S 2>/dev/null)-$$
	( umask 077 && mkdir "$_sd" ) || { fail stage.dir "cannot create $_sd"; finish; }
	( cd "$REPO" && tar cf - install.sh uninstall.sh src contrib ) | ( cd "$_sd" && mkdir repo && cd repo && tar xf - ) || { fail stage.copy "copying the tree failed"; finish; }
	( cd "$_sd/repo" && find . -type f | sort | while IFS= read -r _f; do printf '%s %s\n' "$(hsum "$_f")" "$_f"; done ) >"$_sd/MANIFEST"
	_n=$(wc -l <"$_sd/MANIFEST" | tr -d ' ')
	if [ "${_n:-0}" -gt 5 ] && ! grep -q '^ ' "$_sd/MANIFEST"; then pass stage.manifest "$_n files copied and hashed"; else fail stage.manifest "manifest incomplete ($_n files or an empty hash)"; fi
	stage_gate "$_sd" || { finish; }
	_bad=''
	for _f in "$_sd"/repo/install.sh "$_sd"/repo/src/usr/sbin/tsem "$_sd"/repo/src/usr/lib/tsem/*.sh "$_sd"/repo/src/etc/init.d/tsem "$_sd"/repo/src/etc/hotplug.d/iface/50-tsem; do
		sh -n "$_f" 2>/dev/null || _bad="$_bad ${_f##*/}"
	done
	[ -z "$_bad" ] && pass stage.syntax "all staged shell files parse with this router's sh" || fail stage.syntax "syntax errors:$_bad"
	# trial install into a throw-away root: proves install.sh runs on this BusyBox without touching the router
	_tr=$_sd/trial
	mkdir -p "$_tr/etc/config" "$_tr/etc/rc.d"
	printf "config defaults\n\toption input 'ACCEPT'\n" >"$_tr/etc/config/firewall"
	_to=$(sh "$_sd/repo/install.sh" --root "$_tr" --yes 2>&1 </dev/null); _trc=$?
	if [ "$_trc" -eq 0 ] && [ -x "$_tr/usr/sbin/tsem" ] && [ -f "$_tr/etc/tsem/intent" ] && [ ! -e "$_tr/etc/tsem/backup/INPROGRESS" ]; then pass stage.trial "trial install into a side root works (rc 0, no INPROGRESS marker left)"
	else fail stage.trial "trial install into a side root failed (rc $_trc): $(printf '%s' "$_to" | tail -n 2)"; fi
	_fp2=$(live_fingerprint)
	if [ "$_fp1" = "$_fp2" ]; then pass stage.live_unchanged "live hotplug, fw3 include, init script, boot links, GL hook, tsem files, config and intent are byte-identical to before"
	else fail stage.live_unchanged "a live handler changed while staging: $(printf '%s\n%s\n' "$_fp1" "$_fp2" | sort | uniq -u | head -n 2)"; fi
	if [ "$NF" -eq 0 ]; then
		{ echo "commit=$(printf '%s' "${TSEM_RC3_COMMIT:-unknown}")"; echo "version=$(stage_version)"; echo "backup=$_bk"; echo "files=$_n"; } >"$_sd/.complete"
		echo "STAGE_DIR=$_sd"
		mkdir -p "$AR_RUN" && echo "$_sd" >"$AR_RUN/stage.dir"
	else rm -f "$_sd/.complete"; fi
	finish
}
# stage_gate DIR: staged tree is complete and unmodified
stage_gate() {
	_sg=$1 _gf=0
	[ -s "$_sg/MANIFEST" ] || { fail stage.gate "no MANIFEST in $_sg"; return 1; }
	if ! have sha256sum && ! have md5sum; then fail stage.gate "no hash tool"; return 1; fi
	_now=$( cd "$_sg/repo" 2>/dev/null && find . -type f | sort | while IFS= read -r _f; do printf '%s %s\n' "$(hsum "$_f")" "$_f"; done )
	if [ "$_now" = "$(cat "$_sg/MANIFEST")" ]; then pass stage.verified "staged tree matches its manifest"; return 0; fi
	fail stage.verified "staged tree differs from its manifest"
	return 1
}

# ================================================================== wire / install-recover (the only commands that change live files)
# Both are journaled by install.sh itself (write-ahead journal + INPROGRESS marker, signals ignored).
# They are run only inside the armed-watchdog test phase, after a typed confirmation.
ST_KEYS="intent.sum tsemconf.sum hook.sum bootlink"
preserved_ok() { # BK  -> fails for each of intent/config/hook/boot link that differs from the backup manifest
	_pm=$(cat "$1/manifest.txt")
	_ok=0
	for _pair in "intent.sum:etc/tsem/intent" "tsemconf.sum:etc/tsem/tsem.conf" "hook.sum:etc/gl-switch.d/tailscale-de.sh"; do
		_key=${_pair%%:*} _fp=${_pair#*:}
		[ "$(kv "$_pm" "$_key")" = "$(fsum "$R/$_fp")" ] || { fail "$2.$_key" "/$_fp differs from the backup (before: $(kv "$_pm" "$_key"), now: $(fsum "$R/$_fp"))"; _ok=1; }
	done
	_nl=no; [ -e "$R/etc/rc.d/S18tsem" ] && _nl=yes
	[ "$(kv "$_pm" bootlink)" = "$_nl" ] || { fail "$2.bootlink" "boot link changed ($(kv "$_pm" bootlink) to $_nl)"; _ok=1; }
	[ "$_ok" -eq 0 ] && pass "$2.preserved" "intent, tsem.conf, GL switch hook and boot link are exactly as before"
	return "$_ok"
}
# guard_protective MODE_BEFORE GUARD_BEFORE ID: a closed guard stays closed (never a WAN fallback)
guard_protective() {
	snap
	if [ "$1" != direct ] && [ "$2" != open ] && [ "$2" != none ] && [ "$S_guard" = open ]; then fail "$3.guard" "guard was $2 and is OPEN (mode $S_mode): UNPROTECTED WAN path"; return 1; fi
	pass "$3.guard" "guard $S_guard (before: $2, mode $S_mode)"
}
verify_wired() { # BK STAGE_DIR
	_vb=$1 _vs=$2 _vf=0
	_iv=$(installed_version) _sv=$(stage_version)
	[ "$_iv" = "$_sv" ] && pass verify.version "installed $_iv = staged $_sv" || { fail verify.version "installed '$_iv' differs from staged '$_sv'"; _vf=1; }
	_bad=''
	for _f in $(cd "$_vs/repo/src" && find usr/sbin usr/lib etc/init.d etc/hotplug.d -type f | sort); do
		case $_f in usr/sbin/tsem-mqtt | etc/tsem/* | usr/lib/oui-httpd/*) continue ;; esac
		# tsem-masq is an opt-in component: it is only compared when it was installed
		case $_f in usr/sbin/tsem-masq | usr/lib/tsem/masq-include.sh | etc/init.d/tsem-masq | etc/hotplug.d/iface/51-tsem-masq) [ -e "$R/$_f" ] || continue ;; esac
		[ "$(fsum "$R/$_f")" = "$(fsum "$_vs/repo/src/$_f")" ] || _bad="$_bad $_f"
	done
	[ -z "$_bad" ] && pass verify.files "installed files are identical to the staged copy" || { fail verify.files "differ from the staged copy:$_bad"; _vf=1; }
	preserved_ok "$_vb" verify || _vf=1
	if [ -x "$TSEM" ]; then
		_ic=$("$TSEM" intent-check 2>&1); _irc=$?
		if [ "$_irc" -eq 0 ]; then pass verify.intent "intent valid ($_ic)"; else fail verify.intent "intent not valid (rc $_irc: $_ic)"; _vf=1; fi
		_st=$("$TSEM" selftest 2>&1); _srl=$?
		echo "$_st" | grep -E '^(PASS|WARN|FAIL)' | while IFS= read -r _l; do info selftest "$_l"; done
		[ "$_srl" -eq 0 ] && pass verify.selftest "selftest without failures" || { fail verify.selftest "selftest reported failures (rc $_srl)"; _vf=1; }
		guard_protective "$(kv "$(cat "$_vb/manifest.txt")" mode.before)" "$(kv "$(cat "$_vb/manifest.txt")" guard.before)" verify || _vf=1
	else fail verify.tsem "$TSEM missing"; _vf=1; fi
	[ ! -e "$R/etc/tsem/backup/INPROGRESS" ] && pass verify.journal "no pending install journal" || { fail verify.journal "install journal still pending"; _vf=1; }
	return "$_vf"
}
# wire_restore BK STAGE_DIR HOW: undo exactly the interrupted/failed install, re-assert the guard from the intent. Never opens.
# HOW = journal (an INPROGRESS marker exists) | rollback (install.sh finished: undo that very install) | none (install.sh already undid itself)
wire_restore() {
	_rb=$1 _rs=$2 _how=${3:-none} _wantv=${4:-}
	trap '' HUP INT TERM PIPE
	_pm=$(cat "$_rb/manifest.txt")
	_mode=$(kv "$_pm" mode.before) _gb=$(kv "$_pm" guard.before)
	[ ! -e "$R/etc/tsem/backup/INPROGRESS" ] || _how=journal
	case $_how in
	journal) _o=$(inst_sh "$_rs/repo/install.sh" --recover --yes 2>&1 </dev/null); _rc=$? ;;
	rollback) _o=$(inst_sh "$_rs/repo/install.sh" --rollback --yes 2>&1 </dev/null); _rc=$? ;;
	*) _o="install.sh restored the previous state itself"; _rc=0 ;;
	esac
	printf '%s\n' "$_o" | tail -n 6 | while IFS= read -r _l; do info restore.log "$_l"; done
	if [ "$_rc" -eq 0 ]; then pass restore.install "install journal handled ($_how, rc 0)"; else fail restore.install "install.sh restore failed (rc $_rc): the archive $_rb/files.tar holds the previous files"; fi
	[ -x "$TSEM" ] && "$TSEM" reapply >/dev/null 2>&1
	snap
	if [ "$_mode" != direct ] && [ "$_gb" != open ] && [ "$_gb" != none ] && [ "$S_guard" = open ]; then
		"$TSEM" reapply >/dev/null 2>&1; snap
		if [ "$S_guard" = open ]; then "$TSEM" set "$_mode" >/dev/null 2>&1; snap; fi
	fi
	_iv=$(installed_version) _want=${_wantv:-$(kv "$_pm" version.installed)}
	[ "$_iv" = "$_want" ] && pass restore.version "previous version $_want is installed again" || fail restore.version "installed '$_iv', expected '$_want'"
	preserved_ok "$_rb" restore || true
	if [ "$_mode" != direct ] && [ "$_gb" != open ] && [ "$_gb" != none ] && [ "$S_guard" = open ]; then fail restore.guard "guard is OPEN after the restore (mode $S_mode): run 'tsem set $_mode' NOW"; else pass restore.guard "guard $S_guard after the restore (before: $_gb)"; fi
}
cmd_wire() {
	[ "${1:-}" = --confirm-wire ] || refuse "wire needs --confirm-wire BACKUP_DIR STAGE_DIR"
	_bk=${2:-} _sd=${3:-}
	valid_dir "$_bk" backup && [ -d "$_bk" ] || refuse "wire needs the directory of a completed backup"
	valid_dir "$_sd" stage && [ -s "$_sd/.complete" ] || refuse "wire needs a completed stage directory (run prepare)"
	armed || refuse "recovery watchdog is not armed: wiring never runs without it"
	if ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon'; then refuse "a tsem daemon is running"; fi
	trap '' HUP INT TERM PIPE
	if [ "$(installed_version)" = "$(stage_version)" ] && [ ! -e "$R/etc/tsem/backup/INPROGRESS" ]; then
		sect "WIRE RC3 $(stage_version): already installed (an earlier wire); nothing to do"
		pass wire.already "version $(installed_version) is already live; no install ran"
		echo "WIRE_RESULT=ok"
		finish
	fi
	sect "WIRE RC3 $(stage_version) into the live router (journaled; automatic restore if verification fails)"
	backup_gate "$_bk" || { fail wire.backup "backup gate failed: nothing wired"; echo "WIRE_RESULT=refused"; finish; }
	stage_gate "$_sd" || { fail wire.stage "stage gate failed: nothing wired"; echo "WIRE_RESULT=refused"; finish; }
	[ ! -e "$R/etc/tsem/backup/INPROGRESS" ] || { fail wire.pending "an interrupted install is pending: run install-recover first"; echo "WIRE_RESULT=refused"; finish; }
	_pm=$(cat "$_bk/manifest.txt")
	info wire.before "version=$(kv "$_pm" version.installed) mode=$(kv "$_pm" mode.before) guard=$(kv "$_pm" guard.before)"
	echo wiring >"$_bk/wire.state"
	_lt0=$(cat "$R/etc/tsem/backup/LATEST" 2>/dev/null)
	_o=$(inst_sh "$_sd/repo/install.sh" --yes --no-enable --keep-gl-hook --no-native-gui 2>&1 </dev/null); _rc=$?
	printf '%s\n' "$_o" | tail -n 8 | while IFS= read -r _l; do info install.log "$_l"; done
	_ok=0
	[ "$_rc" -eq 0 ] && pass install.rc "install.sh --yes finished (rc 0)" || { fail install.rc "install.sh failed (rc $_rc)"; _ok=1; }
	if [ "$_ok" -eq 0 ] && ! verify_wired "$_bk" "$_sd"; then _ok=1; fi
	if [ "$_ok" -eq 0 ]; then
		echo wired >"$_bk/wire.state"
		echo "WIRE_RESULT=ok"
	else
		fail wire.verify "wiring failed or did not verify: restoring the previous version"
		echo restoring >"$_bk/wire.state"
		_how=none
		[ "$_rc" -ne 0 ] || [ "$(cat "$R/etc/tsem/backup/LATEST" 2>/dev/null)" = "$_lt0" ] || _how=rollback
		wire_restore "$_bk" "$_sd" "$_how"
		echo restored >"$_bk/wire.state"
		echo "WIRE_RESULT=restored"
	fi
	finish
}
cmd_install_recover() { # after an interrupted wire: replay the journal, re-assert the guard
	[ "${1:-}" = --confirm-repair ] || refuse "install-recover needs --confirm-repair BACKUP_DIR STAGE_DIR"
	_bk=${2:-} _sd=${3:-}
	valid_dir "$_bk" backup && [ -d "$_bk" ] || refuse "needs the backup directory"
	valid_dir "$_sd" stage && [ -s "$_sd/repo/install.sh" ] || refuse "needs the stage directory"
	trap '' HUP INT TERM PIPE
	sect "REPAIR an interrupted install (replays the journal; never opens the guard)"
	if [ -e "$R/etc/tsem/backup/INPROGRESS" ]; then info repair.pending "interrupted install found: $(cat "$R/etc/tsem/backup/INPROGRESS")"; else info repair.pending "no interrupted install pending"; fi
	wire_restore "$_bk" "$_sd" none
	finish
}

# verify-prepared BK SD (read-only): everything the final run relies on, checked again right before it starts
cmd_verify_prepared() {
	_bk=${1:-} _sd=${2:-}
	valid_dir "$_bk" backup && [ -d "$_bk" ] || refuse "verify-prepared needs the backup directory"
	valid_dir "$_sd" stage && [ -s "$_sd/.complete" ] || refuse "verify-prepared needs a completed stage directory"
	sect "Verify the prepared backup and staged RC3 against the live router (read-only)"
	backup_gate "$_bk" || { fail prepared.backup "the backup is not complete and verified: run prepare again (a new backup is made, nothing is overwritten)"; finish; }
	stage_gate "$_sd" || { fail prepared.stage "the staged copy is not intact: run prepare again"; finish; }
	_want=$(cd "$_sd/repo" && find . -type f | sort | while IFS= read -r _f; do printf '%s %s\n' "$(hsum "$_f")" "$_f"; done)
	_have=$(cd "$REPO" && find ./install.sh ./uninstall.sh ./src ./contrib -type f 2>/dev/null | sort | while IFS= read -r _f; do printf '%s %s\n' "$(hsum "$_f")" "$_f"; done)
	if [ -n "$_have" ] && [ "$_want" = "$_have" ]; then pass prepared.payload "the staged RC3 payload is byte-identical to the code that runs this tool ($(wc -l <"$_sd/MANIFEST" | tr -d ' ') files): the earlier backup and staging are still valid"
	else fail prepared.payload "the staged payload differs from this tool's checkout ($(printf '%s\n%s\n' "$_want" "$_have" | sort | uniq -u | head -n 2)): run prepare again"; fi
	_pm=$(cat "$_bk/manifest.txt")
	_iv=$(installed_version)
	case $_iv in
	"$(kv "$_pm" version.installed)") pass prepared.version "installed version $_iv is the one that was backed up" ;;
	"$(stage_version)") warn prepared.version "installed version $_iv is already the staged one (an earlier wire): wiring is skipped" ;;
	*) fail prepared.version "installed version '$_iv' is neither the backed-up one ($(kv "$_pm" version.installed)) nor the staged one: the router changed since the backup" ;;
	esac
	if [ "$_iv" = "$(kv "$_pm" version.installed)" ]; then preserved_ok "$_bk" drift || fail prepared.drift "the router changed since the backup was made: run prepare again"; fi
	[ ! -e "$R/etc/tsem/backup/INPROGRESS" ] && pass prepared.journal "no interrupted install pending" || fail prepared.journal "an interrupted install is pending: run the repair phase first"
	finish
}

# go-live --confirm-golive BK SD: boot links, GL hook replacement (original kept), service start. Journaled like wire; restores on failure.
golive_verify() { # BK SD
	_gb=$1 _gs=$2 _gf=0
	_pm=$(cat "$_gb/manifest.txt")
	[ "$(fsum "$R/etc/gl-switch.d/tailscale-de.sh")" = "$(fsum "$_gs/repo/contrib/tsem-switch.sh")" ] && pass golive.hook "the GL switch hook is now the tsem hook (calls 'tsem set ... --source hw', one controller)" || { fail golive.hook "the GL switch hook is not the tsem hook"; _gf=1; }
	_hk=$(kv "$_pm" hook.sum)
	if [ "$_hk" != none ] && [ -n "$_hk" ]; then
		_bp=$(sed -n 's/^B|etc\/gl-switch.d\/tailscale-de.sh|//p' "$R/etc/tsem/install.manifest" 2>/dev/null | head -n 1)
		if [ -n "$_bp" ] && [ "$(fsum "$_bp")" = "$_hk" ]; then pass golive.hook.original "the previous switch hook is kept unchanged ($_bp) and is restored by rollback/uninstall"; else fail golive.hook.original "the previous switch hook is not recoverable from '$_bp'"; _gf=1; fi
	fi
	{ [ -x "$R/etc/rc.d/S18tsem" ] && [ -x "$R/etc/init.d/tsem" ]; } && pass golive.boot "boot link S18tsem resolves to the executable init script (starts before firewall and network)" || { fail golive.boot "boot link missing or dangling"; _gf=1; }
	[ "$(kv "$_pm" intent.sum)" = "$(fsum "$R/etc/tsem/intent")" ] && [ "$(kv "$_pm" tsemconf.sum)" = "$(fsum "$R/etc/tsem/tsem.conf")" ] && pass golive.preserved "intent and tsem.conf are exactly as before" || { fail golive.preserved "intent or tsem.conf changed"; _gf=1; }
	return "$_gf"
}
golive_up() { # start the service and see the daemon stay alive
	"$INITD/tsem" start >/dev/null 2>&1 || { fail golive.start "the init script did not start the service"; return 1; }
	_i=0
	while ! ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon' && [ "$_i" -lt 20 ]; do waitt 1; _i=$((_i + 1)); ka; done
	ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon' || { fail golive.daemon "no tsem daemon after ${_i}s"; return 1; }
	waitt 5; ka
	ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon' && pass golive.daemon "the tsem daemon runs and stays up" || { fail golive.daemon "the tsem daemon died right after the start"; return 1; }
	return 0
}
cmd_go_live() {
	[ "${1:-}" = --confirm-golive ] || refuse "go-live needs --confirm-golive BACKUP_DIR STAGE_DIR"
	_bk=${2:-} _sd=${3:-}
	valid_dir "$_bk" backup && [ -d "$_bk" ] || refuse "go-live needs the backup directory"
	valid_dir "$_sd" stage && [ -s "$_sd/.complete" ] || refuse "go-live needs a completed stage directory"
	armed || refuse "recovery watchdog is not armed: go-live never runs without it"
	[ "$(installed_version)" = "$(stage_version)" ] || refuse "RC3 is not wired yet (installed '$(installed_version)')"
	if ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon'; then refuse "a tsem daemon is already running"; fi
	trap '' HUP INT TERM PIPE
	sect "GO LIVE: boot links + switch hook + service (journaled; automatic restore if it does not verify)"
	backup_gate "$_bk" || { fail golive.backup "backup gate failed: nothing changed"; echo "GOLIVE_RESULT=refused"; finish; }
	stage_gate "$_sd" || { fail golive.stage "stage gate failed: nothing changed"; echo "GOLIVE_RESULT=refused"; finish; }
	[ ! -e "$R/etc/tsem/backup/INPROGRESS" ] || { fail golive.pending "an interrupted install is pending: run install-recover first"; echo "GOLIVE_RESULT=refused"; finish; }
	snap; _m0=$S_mode _g0=$S_guard
	info golive.before "mode=$_m0 guard=$_g0"
	_lt0=$(cat "$R/etc/tsem/backup/LATEST" 2>/dev/null)
	_nonat=--no-native-gui; [ -f "$R/usr/share/oui/menu.d/tsem.json" ] && _nonat=""
	_o=$(inst_sh "$_sd/repo/install.sh" --yes --enable --replace-gl-hook $_nonat 2>&1 </dev/null); _rc=$?
	printf '%s\n' "$_o" | tail -n 6 | while IFS= read -r _l; do info install.log "$_l"; done
	_ok=0
	[ "$_rc" -eq 0 ] && pass golive.install "install.sh --yes --enable --replace-gl-hook finished (rc 0)" || { fail golive.install "install.sh failed (rc $_rc)"; _ok=1; }
	if [ "$_ok" -eq 0 ]; then golive_verify "$_bk" "$_sd" || _ok=1; fi
	if [ "$_ok" -eq 0 ]; then golive_up || _ok=1; fi
	if [ "$_ok" -eq 0 ]; then
		guard_protective "$_m0" "$_g0" golive || _ok=1
		_st=$("$TSEM" selftest 2>&1); [ $? -eq 0 ] && pass golive.selftest "selftest without failures" || { fail golive.selftest "selftest reported failures"; _ok=1; }
	fi
	if [ "$_ok" -eq 0 ]; then echo "GOLIVE_RESULT=ok"
	else
		fail golive.verify "go-live failed or did not verify: stopping the service and undoing this install (the guard stays closed)"
		"$INITD/tsem" stop >/dev/null 2>&1
		_how=none
		[ "$_rc" -ne 0 ] || [ "$(cat "$R/etc/tsem/backup/LATEST" 2>/dev/null)" = "$_lt0" ] || _how=rollback
		wire_restore "$_bk" "$_sd" "$_how" "$(stage_version)"
		echo "GOLIVE_RESULT=restored"
	fi
	finish
}
# final-state: the operating mode german, set and verified (needs the armed watchdog)
cmd_final_state() {
	armed || refuse "recovery watchdog is not armed"
	[ -x "$TSEM" ] || refuse "tsem is not installed"
	sect "Final operating mode: german (set and verified)"
	"$TSEM" set german >/dev/null 2>&1 || fail final.set "tsem set german returned an error"
	_i=0
	while [ "$_i" -lt 20 ]; do
		snap
		case $S_state in PRIMARY_ACTIVE | SECONDARY_ACTIVE) break ;; esac
		ka; waitt 3; _i=$((_i + 1))
	done
	info final.state "mode=$S_mode state=$S_state guard=$S_guard exit=$S_exit leak_risk=$S_leak"
	{ [ "$S_mode" = german ] && [ "$S_guard" = german ] && { [ "$S_state" = PRIMARY_ACTIVE ] || [ "$S_state" = SECONDARY_ACTIVE ]; } && [ "$S_leak" = false ]; } && pass final.mode "mode german, guard german, exit node $S_exit active, no leak risk" || fail final.mode "not in german with an active exit node (mode=$S_mode state=$S_state guard=$S_guard leak_risk=$S_leak); the guard is $S_guard (never open unless direct)"
	grep -q german "$R/etc/tsem/intent" 2>/dev/null && pass final.intent "the persisted intent says german" || fail final.intent "the persisted intent does not say german"
	"$TSEM" intent-check >/dev/null 2>&1 && pass final.intent.valid "intent is valid" || fail final.intent.valid "intent-check failed"
	ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon' && pass final.daemon "tsem daemon running" || fail final.daemon "no tsem daemon running"
	finish
}
# persist-check [SD] (read-only): what survives a reboot, without rebooting
cmd_persist_check() {
	_sd=${1:-}
	sect "Persistence and boot behaviour (read-only; the router is NOT rebooted)"
	[ -x "$TSEM" ] || { fail persist.tsem "tsem is not installed"; finish; }
	if [ -n "$_sd" ] && valid_dir "$_sd" stage; then
		[ "$(installed_version)" = "$(stage_version)" ] && pass persist.version "installed $(installed_version) = staged" || fail persist.version "installed '$(installed_version)' differs from the staged '$(stage_version)'"
	fi
	[ -s "$R/etc/tsem/intent" ] && "$TSEM" intent-check >/dev/null 2>&1 && pass persist.intent "the intent file exists and is valid (it decides the guard at boot)" || fail persist.intent "intent file missing or invalid"
	[ -s "$R/etc/tsem/tsem.conf" ] && pass persist.conf "tsem.conf exists" || fail persist.conf "tsem.conf missing"
	{ [ -x "$R/etc/init.d/tsem" ] && sh -n "$R/etc/init.d/tsem" 2>/dev/null; } && pass persist.init "init script present and parses" || fail persist.init "init script missing or broken"
	if [ -x "$R/etc/rc.d/S18tsem" ]; then pass persist.bootlink "boot link S18tsem present: 'tsem boot' installs the guard from the intent BEFORE firewall (19) and network (20), then the daemon starts"
	else fail persist.bootlink "no boot link S18tsem: after a reboot nothing starts tsem at boot (only the hotplug/fw3 hooks would act later)"; fi
	grep -q 'START=18' "$R/etc/init.d/tsem" 2>/dev/null && pass persist.order "START=18 (before firewall and network)" || fail persist.order "START=18 not found in the init script"
	grep -q 'fw-include.sh' "$R/etc/config/firewall" 2>/dev/null && [ -x "$R/usr/lib/tsem/fw-include.sh" ] && pass persist.fwinclude "fw3 include persisted: every firewall reload re-asserts the guard" || fail persist.fwinclude "fw3 include missing"
	[ -x "$R/etc/hotplug.d/iface/50-tsem" ] && pass persist.hotplug "hotplug handler present: ifup/ifdown re-asserts the guard" || fail persist.hotplug "hotplug handler missing"
	[ -x "$R/etc/gl-switch.d/tailscale-de.sh" ] && grep -q 'tsem' "$R/etc/gl-switch.d/tailscale-de.sh" 2>/dev/null && pass persist.hook "GL switch hook is the tsem hook" || warn persist.hook "GL switch hook is not (yet) the tsem hook"
	if [ -z "$R" ]; then
		for _f in /etc/tsem/intent /usr/sbin/tsem /etc/rc.d/S18tsem; do
			_mp=$(df -P "$_f" 2>/dev/null | awk 'NR == 2 { print $6 }')
			_ft=$(awk -v m="$_mp" '$2 == m { t = $3 } END { print t }' /proc/mounts 2>/dev/null)
			case $_ft in tmpfs | ramfs | '') fail persist.flash "$_f is on '${_ft:-unknown}' (mount ${_mp:-?}): it would NOT survive a reboot" ;; *) pass persist.flash "$_f lives on $_ft ($_mp): persistent" ;; esac
		done
	else info persist.flash "filesystem check only on the live router"; fi
	info persist.reboot "no reboot was forced. A real reboot test is yours to do later (watchdog gone after reboot, guard from the intent at S18)."
	finish
}

# ================================================================== recovery control
# The watchdog is a procd service with two instances (watch + monitor), added at run time with
# `ubus call service add` (memory only: gone after a reboot, no file below /etc). procd owns the processes, so
# neither an SSH drop, a closed terminal, a tailscale restart nor a firewall reload can end them, and neither
# setsid nor nohup is needed. Before any real arm the SAME mechanism is exercised with a probe (own state
# directory, own service name, a canary file instead of the recovery): process start, parent, heartbeat,
# keepalive, deadline, and the monitor taking over from a hung watcher. A watchdog that was not seen working
# is never armed, and nothing is wired without one.
safe_path() { case $1 in '' | *[!A-Za-z0-9._/-]* | *..*) return 1 ;; esac; return 0; }
# wd_svc_add SERVICE RUNDIR PROBE STEP STALE GRACE
wd_svc_add() {
	have ubus || return 1
	safe_path "$2" || return 1
	_e=$(printf '"env":{"AR_RUN":"%s","AR_SVC":"%s","AR_PROBE":"%s","AR_WATCH_STEP":"%s","AR_HB_STALE":"%s","AR_MON_GRACE":"%s"}' "$2" "$1" "$3" "$4" "$5" "$6")
	_j=$(printf '{"name":"%s","instances":{"watch":{"command":["/bin/sh","%s/recover.sh","watch"],%s,"respawn":[3600,3,10]},"monitor":{"command":["/bin/sh","%s/recover.sh","monitor"],%s,"respawn":[3600,3,10]}}}' "$1" "$2" "$_e" "$2" "$_e")
	ubus call service add "$_j" >/dev/null 2>&1
}
wd_svc_del() { have ubus && ubus call service delete "{\"name\":\"$1\"}" >/dev/null 2>&1; return 0; }
# wd_pids SERVICE: prints "watchpid monitorpid" when procd reports both instances running, else nothing
wd_pids() {
	have ubus || return 1
	_l=$(ubus call service list "{\"name\":\"$1\"}" 2>/dev/null) || return 1
	[ "$(printf '%s\n' "$_l" | grep -c '"running": true')" -ge 2 ] || return 1
	_wpl=$(printf '%s\n' "$_l" | sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' | tr '\n' ' ')
	set -- $_wpl
	[ $# -ge 2 ] || return 1
	echo "$1 $2"
}
# wd_detached PID: the process does not belong to this SSH session: its parent is init/procd, never one of our ancestors
wd_detached() {
	[ -r "/proc/$1/stat" ] || return 1
	_wpar=$(sed 's/^[0-9]* ([^)]*) [A-Za-z] //; s/ .*//' "/proc/$1/stat" 2>/dev/null)
	case $_wpar in '' | *[!0-9]*) return 1 ;; esac
	[ "$_wpar" = 1 ] && return 0
	[ "$(cat "/proc/$_wpar/comm" 2>/dev/null)" = procd ] && return 0
	return 1
}
# wd_wait_file FILE SECONDS
wd_wait_file() { _wi=0; while [ ! -e "$1" ] && [ "$_wi" -lt "$2" ]; do sleep 1; _wi=$((_wi + 1)); done; [ -e "$1" ]; }
# wd_probe: actually uses the mechanism. Returns 0 only when every step was observed.
wd_probe() {
	_pt=${AR_PROBE_TIMEOUT:-8}
	_pd=$AR_RUN/probe _prc=$_pd/recovery _psv=tsem-rc3-wd-probe _pf=0
	_ps() { TSEM_NOW= AR_RUN=$_pd AR_PROBE=1 AR_SVC=$_psv AR_SLEEP=sleep sh "$_pd/recover.sh" "$@"; }
	wd_svc_del "$_psv"; rm -rf "$_pd"
	mkdir -p "$_prc" 2>/dev/null && cp "$HERE/tsem-rc3-recover.sh" "$_pd/recover.sh" || { fail probe.setup "cannot create the probe directory $_pd"; return 1; }
	have ubus || { fail probe.procd "ubus is not available: no procd service can be created, the independent recovery cannot be built here"; return 1; }
	ubus call service list >/dev/null 2>&1 || { fail probe.procd "ubus cannot reach procd (service list failed): no independent recovery possible"; return 1; }
	# 1. start through procd
	_ps prepare "$_pt" 60 >/dev/null 2>&1 # the first deadline is generous: set-up steps must not eat the probe timeout
	wd_svc_add "$_psv" "$_pd" 1 1 5 3 || { fail probe.start "procd refused the probe service"; wd_svc_del "$_psv"; rm -rf "$_pd"; return 1; }
	if ! wd_wait_file "$_prc/hb" 10; then fail probe.start "procd service added, but the watcher never wrote a heartbeat within 10s"; wd_svc_del "$_psv"; rm -rf "$_pd"; return 1; fi
	_pp=$(wd_pids "$_psv") || _pp=''
	if [ -n "$_pp" ]; then pass probe.start "procd runs both instances (watch/monitor pids $_pp)"; else fail probe.start "procd does not report both instances as running"; _pf=1; fi
	# 2. not a child of this session
	if [ -n "$_pp" ]; then
		_dt=ok; for _x in $_pp; do wd_detached "$_x" || _dt=bad; done
		[ "$_dt" = ok ] && pass probe.detached "both processes are children of init/procd, not of this ssh session" || { fail probe.detached "a watchdog process is still tied to this session (parent is not init/procd)"; _pf=1; }
	fi
	# 3. heartbeat moves
	_ps keepalive >/dev/null 2>&1
	_h1=$(cat "$_prc/hb" 2>/dev/null); _i=0
	while [ "$_i" -lt 3 ]; do sleep 1; _ps keepalive >/dev/null 2>&1; _i=$((_i + 1)); done
	_h2=$(cat "$_prc/hb" 2>/dev/null)
	case "$_h1:$_h2" in *[!0-9:]* | :* | *:) _hm=0 ;; *) [ "$_h2" -gt "$_h1" ] && _hm=1 || _hm=0 ;; esac
	[ "$_hm" -eq 1 ] && pass probe.heartbeat "the watcher's heartbeat advances ($_h1 -> $_h2)" || { fail probe.heartbeat "the heartbeat does not advance ($_h1 -> $_h2)"; _pf=1; }
	# 4. keepalives postpone the deadline
	_i=0; _kmax=$((_pt + _pt / 2))
	while [ "$_i" -lt "$_kmax" ]; do _ps keepalive >/dev/null 2>&1; sleep 1; _i=$((_i + 1)); done
	if [ -e "$_prc/canary" ]; then fail probe.keepalive "the recovery fired although keepalives kept arriving"; _pf=1; else pass probe.keepalive "no recovery for ${_kmax}s with a ${_pt}s deadline while keepalives arrive"; fi
	# 5. without keepalive the deadline fires the recovery action
	_t0=$(date +%s)
	if wd_wait_file "$_prc/canary" $((_pt + 12)); then pass probe.timeout "no keepalive: the recovery action ran $(($(date +%s) - _t0))s after the last keepalive (deadline ${_pt}s)"; else fail probe.timeout "the deadline passed and nothing happened: this watchdog would NOT recover"; _pf=1; fi
	sleep 1
	if wd_pids "$_psv" >/dev/null 2>&1; then warn probe.cleanup "the probe service is still running after it fired"; fi
	# 6. the monitor takes over from a hung watcher
	wd_svc_del "$_psv"; rm -rf "$_pd"; mkdir -p "$_prc"; cp "$HERE/tsem-rc3-recover.sh" "$_pd/recover.sh"
	_ps prepare "$_pt" 600 >/dev/null 2>&1
	if wd_svc_add "$_psv" "$_pd" 1 1 5 3 && wd_wait_file "$_prc/hb" 10; then
		_wp=$(cat "$_prc/pid" 2>/dev/null)
		if [ -n "$_wp" ] && kill -STOP "$_wp" 2>/dev/null; then
			if wd_wait_file "$_prc/canary" 20; then pass probe.monitor "the watcher was frozen: the independent monitor noticed the stale heartbeat and ran the recovery action"; else fail probe.monitor "the watcher was frozen and nothing recovered: the monitor does not work"; _pf=1; fi
			kill -CONT "$_wp" 2>/dev/null
		else fail probe.monitor "cannot freeze the watcher (pid '${_wp}') to test the monitor"; _pf=1; fi
	else fail probe.monitor "second probe round did not start"; _pf=1; fi
	wd_svc_del "$_psv"; rm -rf "$_pd"
	return "$_pf"
}
cmd_recovery_verify() { sect "Verify the independent recovery by using it (probe: own directory, own procd service, no tsem and no network change)"; wd_probe && pass recovery.verified "the recovery mechanism was seen working end to end" || fail recovery.verified "the independent recovery could not be verified"; finish; }
cmd_recovery_arm() {
	_t=${1:-300} _stg=${2:-}
	case $_t in '' | *[!0-9]*) refuse "timeout must be seconds" ;; esac
	[ "$_t" -ge 60 ] && [ "$_t" -le 3600 ] || refuse "timeout must be 60..3600 seconds"
	armed && refuse "recovery is already armed (disarm it first)"
	[ -e "$RC_DIR/armed" ] && refuse "a stale watchdog state exists in $RC_DIR (heartbeat is old): run recovery-disarm first"
	mkdir -p "$AR_RUN" || refuse "cannot create $AR_RUN"
	sect "Arm the recovery watchdog (procd service, verified before use)"
	if ! wd_probe; then
		emit FAIL recovery.arm "the independent recovery could NOT be verified: nothing is armed and NOTHING may be wired or tested"
		exit 1
	fi
	cp "$HERE/tsem-rc3-recover.sh" "$AR_RUN/recover.sh" || { emit FAIL recovery.arm "cannot copy the recovery script"; exit 1; }
	rm -rf "$RC_DIR" 2>/dev/null; mkdir -p "$RC_DIR"
	if [ -n "$_stg" ] && [ -f "$_stg/repo/install.sh" ]; then echo "$_stg/repo/install.sh" >"$RC_DIR/install_sh"; fi
	_ck=$(AR_RUN=$AR_RUN sh "$AR_RUN/recover.sh" check 2>&1) || { emit FAIL recovery.check "the recovery cannot work on this router: $_ck"; exit 1; }
	pass recovery.check "recovery prerequisites present ($_ck)"
	TSEM_NOW= AR_RUN=$AR_RUN sh "$AR_RUN/recover.sh" prepare "$_t" >/dev/null 2>&1 || { emit FAIL recovery.arm "cannot write the watchdog state"; exit 1; }
	if ! wd_svc_add tsem-rc3-wd "$AR_RUN" 0 "${AR_WD_STEP:-2}" "${AR_WD_STALE:-20}" "${AR_WD_GRACE:-10}"; then rm -rf "$RC_DIR"; emit FAIL recovery.arm "procd refused the watchdog service"; exit 1; fi
	wd_wait_file "$RC_DIR/hb" 15 >/dev/null
	# wait (up to 12 s) for the heartbeat to move instead of looking once after a fixed 3 s: a slow start under load is not a failure
	_h1=$(cat "$RC_DIR/hb" 2>/dev/null); _h2=$_h1; _hw=0
	while [ "$_hw" -lt 12 ]; do sleep 1; _hw=$((_hw + 1)); _h2=$(cat "$RC_DIR/hb" 2>/dev/null); [ "${_h2:-0}" -gt "${_h1:-0}" ] 2>/dev/null && break; done
	_pp=$(wd_pids tsem-rc3-wd) || _pp=''
	if [ -n "$_pp" ] && armed && [ "${_h2:-0}" -gt "${_h1:-0}" ] 2>/dev/null; then
		emit PASS recovery.arm "watchdog armed under procd (pids $_pp, heartbeat moving): recovery in ${_t}s without keepalive; survives ssh loss, tailscale restart and firewall reload"
		echo "RECOVERY_ARMED=$_t"
	else
		wd_svc_del tsem-rc3-wd; rm -rf "$RC_DIR"
		emit FAIL recovery.arm "the real watchdog did not come up working (instances '$_pp', heartbeat $_h1 -> $_h2): nothing is armed"
		exit 1
	fi
}
cmd_recovery_keepalive() { ka; armed && echo "keepalive ok" || { echo "not armed"; exit 1; }; }
# F07: ONE truthful answer to "is the recovery watchdog protecting this router right now?". Used by the Mac runner
# before every test and before the final disarm question, so a watchdog that fired (deadline passed while a person
# was typing), died or was never armed can no longer be mistaken for an armed one.
#   exit 0  armed and alive (keepalive pushed)
#   exit 1  NOT protecting: the reason is printed (fired / stale heartbeat / absent) with the log tail; nothing is changed
wd_reason() {
	if [ -e "$RC_DIR/fired" ]; then
		echo "the watchdog FIRED (its deadline passed without a keepalive, or its heartbeat went stale) and ran RECOVERY; it is no longer armed"
		[ ! -e "$RC_DIR/recover.log" ] || tail -n 4 "$RC_DIR/recover.log" 2>/dev/null | sed 's/^/    log: /'
	elif [ -e "$RC_DIR/armed" ]; then
		_wh=$(cat "$RC_DIR/hb" 2>/dev/null); case $_wh in '' | *[!0-9]*) _wh=0 ;; esac
		echo "an armed marker exists but the heartbeat is $(($(date +%s) - _wh))s old (limit ${AR_HB_FRESH:-20}s): the watcher process is dead or hung"
	else
		echo "no watchdog state exists (never armed, or disarmed)"
	fi
}
cmd_recovery_ensure() {
	sect "Recovery watchdog state"
	if armed; then
		ka
		pass recovery.alive "watchdog armed and alive (heartbeat fresh), keepalive sent"
		echo "RECOVERY_STATE=armed"
		finish
	fi
	fail recovery.alive "$(wd_reason | head -n 1): critical tests must not run unprotected"
	wd_reason | sed '1d'
	if [ -e "$RC_DIR/armed" ] && [ ! -e "$RC_DIR/fired" ]; then echo "RECOVERY_STATE=dead"; elif [ -e "$RC_DIR/fired" ]; then echo "RECOVERY_STATE=fired"; else echo "RECOVERY_STATE=absent"; fi
	finish
}
cmd_recovery_disarm() { if [ -r "$AR_RUN/recover.sh" ]; then AR_RUN=$AR_RUN sh "$AR_RUN/recover.sh" disarm; else echo "not armed"; fi; wd_svc_del tsem-rc3-wd-probe; }
cmd_recovery_status() { if [ -r "$AR_RUN/recover.sh" ]; then AR_RUN=$AR_RUN sh "$AR_RUN/recover.sh" status; else echo "not armed"; fi; [ ! -e "$RC_DIR/recover.log" ] || tail -n 8 "$RC_DIR/recover.log"; }
cmd_recover() { [ -r "$AR_RUN/recover.sh" ] || cp "$HERE/tsem-rc3-recover.sh" "$AR_RUN/recover.sh" 2>/dev/null || refuse "no recovery script"; AR_RUN=$AR_RUN sh "$AR_RUN/recover.sh" now; }

# ================================================================== explicit, separate commands
cmd_rollback() {
	[ "${1:-}" = --confirm-rollback ] || refuse "rollback needs --confirm-rollback"
	_bk=${2:-}
	[ -n "$_bk" ] && [ -r "$_bk/manifest.txt" ] || refuse "rollback needs a backup directory"
	sect "ROLLBACK to the previous version (this is NOT recovery)"
	snap; _gb=$S_guard
	info rollback.before "version=$S_ver guard=$_gb mode=$S_mode"
	_o=$(inst_sh "$REPO/install.sh" --rollback --yes 2>&1); _rc=$?
	echo "$_o" | tail -n 10 | while IFS= read -r _l; do info rollback.log "$_l"; done
	[ "$_rc" -eq 0 ] && pass rollback.install "install.sh --rollback finished" || fail rollback.install "install.sh --rollback failed (rc $_rc); restore from $_bk/files.tar by hand"
	_want=$(kv "$(cat "$_bk/manifest.txt")" version.installed)
	[ "$(installed_version)" = "$_want" ] && pass rollback.version "restored version $_want" || warn rollback.version "installed '$(installed_version)', backup says '$_want'"
	[ -x "$TSEM" ] && "$TSEM" reapply >/dev/null 2>&1
	snap
	info rollback.after "version=$S_ver guard=$S_guard mode=$S_mode"
	if [ "$_gb" != open ] && [ "$S_guard" = open ]; then fail rollback.killswitch "the guard was $_gb and is OPEN after the rollback: run 'tsem set german' (or fix) before using the network"; else pass rollback.killswitch "guard was $_gb, is $S_guard (rollback did not open the kill switch)"; fi
	finish
}
cmd_return_to_direct() {
	[ "${1:-}" = --confirm-direct ] || refuse "return-to-direct needs --confirm-direct"
	sect "RETURN TO DIRECT (explicit: this OPENS the kill switch)"
	"$TSEM" set direct >/dev/null 2>&1; _rc=$?
	snap
	[ "$_rc" -eq 0 ] && [ "$S_guard" = open ] && pass direct.set "mode=$S_mode guard=$S_guard: the kill switch is now OFF by your explicit decision" || fail direct.set "direct mode command rc $_rc guard=$S_guard"
	[ "$S_mode" = direct ] && [ "$S_exit" = none ] && pass direct.exit "mode direct, no exit node" || fail direct.exit "mode=$S_mode exit=$S_exit: direct must have no exit node"
	# the way back is only proven if the router really reaches the Internet over the WAN now
	_j=0; _eip=''
	while [ "$_j" -lt "${AR_DIRECT_MAX:-30}" ]; do _eip=$(egress_ip) && break; _eip=''; waitt 3; _j=$((_j + 3)); done
	[ -n "$_eip" ] && pass direct.egress "router-own HTTPS request works over the WAN in direct (IP $_eip)" || fail direct.egress "no Internet over the WAN in direct after ${AR_DIRECT_MAX:-30}s: the DIRECT path is NOT proven"
	finish
}
cmd_activate() {
	[ "${1:-}" = --confirm-activate ] || refuse "activate needs --confirm-activate"
	sect "ACTIVATE (boot links, GL hook replacement, initial mode german, start)"
	_o=$(inst_sh "$REPO/install.sh" --yes --enable --replace-gl-hook --initial-mode german 2>&1); _rc=$?
	echo "$_o" | tail -n 10 | while IFS= read -r _l; do info activate.log "$_l"; done
	[ "$_rc" -eq 0 ] && pass activate.install "enabled" || { fail activate.install "install.sh failed (rc $_rc)"; finish; }
	"$INITD/tsem" start >/dev/null 2>&1 && pass activate.start "service started" || fail activate.start "service did not start"
	waitt 10; snap
	info activate.state "mode=$S_mode state=$S_state guard=$S_guard exit=$S_exit leak_risk=$S_leak"
	finish
}
cmd_stop_service() {
	sect "Stop the tsem service (never opens the guard)"
	"$INITD/tsem" stop >/dev/null 2>&1; snap
	[ "$S_guard" = open ] && [ "$S_mode" != direct ] && fail stop.guard "guard open after stop" || pass stop.guard "guard after stop: $S_guard"
	finish
}

# ================================================================== active tests
obs_dir() { mkdir -p "$AR_RUN/obs"; }
# hold NAME: let the Mac observe from a LAN client, if an observer is attached
hold() {
	[ "${AR_OBSERVER:-0}" = 1 ] || { info "observe.$1" "no Mac observer attached (not a LAN client): not observed from the client side"; return 0; }
	obs_dir; rm -f "$AR_RUN/obs/done.$1"; : >"$AR_RUN/obs/hold.$1"
	_h=0
	while [ ! -e "$AR_RUN/obs/done.$1" ] && [ "$_h" -lt "${AR_HOLD_MAX:-90}" ]; do ka; waitt 1; _h=$((_h + 1)); done
	[ -e "$AR_RUN/obs/done.$1" ] || warn "observe.$1" "the Mac did not answer within ${_h}s: no client-side evidence for this point"
	rm -f "$AR_RUN/obs/hold.$1" "$AR_RUN/obs/done.$1"
}

need_tests_ok() {
	[ -x "$TSEM" ] || refuse "tsem is not installed"
	armed || refuse "recovery watchdog is not armed: arm it first (recovery-arm); active tests never run without it"
	if ps w 2>/dev/null | grep -v grep | grep -q 'tsem daemon'; then refuse "a tsem daemon is running"; fi
	[ -n "$(installed_version)" ] && [ "$(installed_version)" = "$(stage_version)" ] || refuse "the staged version ($(stage_version)) is not installed (installed: '$(installed_version)')"
}
need_german() {
	snap
	if [ "$S_mode" = german ] && [ "$S_guard" = german ] && { [ "$S_state" = PRIMARY_ACTIVE ] || [ "$S_state" = SECONDARY_ACTIVE ]; }; then return 0; fi
	fail precondition "need mode german with an active exit node (mode=$S_mode state=$S_state guard=$S_guard): run t00 first"
	return 1
}
# wait_state "STATE1 STATE2" MAXSECONDS: ticks with the fault simulation, samples the guard every round
SAMPLES=0 BADSAMPLES=''
wait_state() {
	_want=$1 _max=$2 _t0=$(now)
	while :; do
		do_tick
		snap
		SAMPLES=$((SAMPLES + 1))
		case $S_guard in german | blocked) ;; *) BADSAMPLES="$BADSAMPLES $S_guard@$((SAMPLES))" ;; esac
		for _w in $_want; do [ "$S_state" = "$_w" ] && return 0; done
		[ $(($(now) - _t0)) -lt "$_max" ] || return 1
		ka
		waitt "${AR_TICK_WAIT:-5}"
	done
}
guard_report() { # id
	if [ -z "$BADSAMPLES" ]; then pass "$1" "guard was german/blocked in all $SAMPLES samples (never open)"; else fail "$1" "guard was not german/blocked in samples:$BADSAMPLES (leak risk)"; fi
}

# ---- leak probes: a probe that cannot run proves nothing, so it is never a PASS ----
# probe_https: classifies one router-own HTTPS request. Prints reached | blocked | inconclusive.
#   curl exit 0 = reached; 6 (resolve), 7 (connect refused/unreachable), 28 (timeout) = blocked evidence;
#   missing curl or any other exit (TLS, usage, 127 ...) = inconclusive.
probe_https() {
	have curl || { echo inconclusive; return 0; }
	curl -fsS -o /dev/null --connect-timeout 5 --max-time 8 "$1" >/dev/null 2>&1; _c=$?
	case $_c in 0) echo reached ;; 6 | 7 | 28) echo blocked ;; *) echo inconclusive ;; esac
}
# route_class OUTPUT RC: denied | tunnel | routed | inconclusive (only recognised ip output counts)
route_class() {
	case $1 in
	*prohibit* | *unreachable* | *blackhole* | *"not permitted"*) echo denied ;;
	*"dev tailscale0"*) echo tunnel ;;
	*" dev "*) echo routed ;;
	*) echo inconclusive ;;
	esac
}
egress_ip() { # public IP of the router's own request (through the exit node when german)
	for _u in https://1.1.1.1/cdn-cgi/trace; do
		_t=$(curl -fsS --connect-timeout 5 --max-time 8 "$_u" 2>/dev/null) && { printf '%s\n' "$_t" | sed -n 's/^ip=//p' | head -n 1; return 0; }
	done
	return 1
}

t00_activate() {
	sect "t00 activate german (CHANGES routing for all LAN clients: they now use the exit node; if both nodes fail they have no Internet)"
	snap; info t00.before "mode=$S_mode state=$S_state guard=$S_guard"
	"$TSEM" set german >/dev/null 2>&1 || warn t00.set "tsem set german returned non-zero"
	FP='' FS=''
	wait_state "PRIMARY_ACTIVE SECONDARY_ACTIVE" "${AR_T00_MAX:-120}" || true
	snap
	case $S_state in
	PRIMARY_ACTIVE) pass t00.state "state PRIMARY_ACTIVE via $S_exit" ;;
	SECONDARY_ACTIVE) warn t00.state "SECONDARY_ACTIVE: the primary exit node is not usable (see status)" ;;
	*) fail t00.state "state $S_state after activation (guard $S_guard: the kill switch holds, but no exit node is active)" ;;
	esac
	[ "$S_guard" = german ] || [ "$S_guard" = blocked ] && pass t00.guard "guard=$S_guard kill_switch_active=$S_ks" || fail t00.guard "guard=$S_guard"
	[ "$S_leak" = false ] && pass t00.leak "leak_risk=false" || fail t00.leak "leak_risk=$S_leak"
	guard_report t00.never_open
	_st=$("$TSEM" selftest 2>&1); _r=$?
	echo "$_st" | grep -E '^(WARN|FAIL)' | while IFS= read -r _l; do info t00.selftest "$_l"; done
	[ "$_r" -eq 0 ] && pass t00.selftest "selftest without failures" || fail t00.selftest "selftest failures (rc $_r)"
	hold german-steady
}

t01_primary() {
	sect "t01 primary exit node in use (read-only evidence in german)"
	need_german || return 0
	if [ "$S_state" = PRIMARY_ACTIVE ]; then pass t01.primary "PRIMARY_ACTIVE"
	elif [ "${AR_STRICT_PRIMARY:-0}" = 1 ]; then fail t01.primary "state $S_state: the primary exit node is not verified (acceptance requires PRIMARY_ACTIVE; see 'primary_probe' in tsem status and the nodes-check output)"
	else warn t01.primary "state $S_state (secondary in use)"; fi
	[ "$S_exit" = "$S_primary" ] && pass t01.exit "tailscale exit node $S_exit = configured primary" || {
		[ "${AR_STRICT_PRIMARY:-0}" = 1 ] && fail t01.exit "exit node '$S_exit', primary '$S_primary'" || warn t01.exit "exit node '$S_exit', primary '$S_primary'"; }
	# time series instead of one sample: an intermittent path (the failure of the first run) must be visible, not hidden by one lucky request
	_n=${AR_T01_SAMPLES:-6} _gap=${AR_T01_GAP:-5} _i=0 _ok=0 _last=fail _ip='' _line=''
	while [ "$_i" -lt "$_n" ]; do
		_i=$((_i + 1))
		if _x=$(egress_ip); then _ok=$((_ok + 1)); _last=ok; _ip=$_x; _line="$_line ok($_x)"; else _last=fail; _line="$_line FAIL"; fi
		[ "$_i" -lt "$_n" ] && ${AR_SLEEP:-sleep} "$_gap"
	done
	info t01.series "router-own HTTPS requests, $_n samples ${_gap}s apart:$_line"
	if [ "$_ok" -eq "$_n" ]; then pass t01.egress "router-own HTTPS request left via IP $_ip in $_ok/$_n samples (compare with the Mac observation and the baseline WAN IP)"
	elif [ "$_last" = ok ] && [ "$_ok" -gt 0 ]; then warn t01.egress "INTERMITTENT egress: $_ok/$_n samples worked (last ok via $_ip): the path through the exit node is unstable"
	else fail t01.egress "router-own HTTPS request failed in german ($_ok/$_n samples worked, last one failed)"; fi
	echo "ROUTER_EGRESS_IP=${_ip:-}"
	ip rule show 2>/dev/null | grep -q 'iif br-lan' && pass t01.rule "policy-routing guard rules present" || fail t01.rule "no 'iif br-lan' ip rule: layer 1 missing"
	ip rule show 2>/dev/null | grep -Eq 'prohibit|unreachable|blackhole' && pass t01.deny "deny rule present (fail-closed layer 1)" || fail t01.deny "no deny rule"
	iptables -S TSEM_FWD >/dev/null 2>&1 && pass t01.chain "netfilter chain TSEM_FWD present" || fail t01.chain "chain TSEM_FWD missing"
}

t02_failover() {
	sect "t02 failover primary -> secondary -> primary (CHANGES the exit node twice; the primary is only SIMULATED as down by an identity mismatch inside the foreground ticks, no tailnet/firewall fault)"
	need_german || return 0
	[ -n "$S_secondary" ] && [ "$S_secondary" != none ] || { skip t02.secondary "no secondary configured"; return 0; }
	SAMPLES=0 BADSAMPLES=''
	FP=$FAULT_NAME_P FS=''
	if wait_state "SECONDARY_ACTIVE" "${AR_T02_MAX:-180}"; then
		pass t02.switch "SECONDARY_ACTIVE reached"
		[ "$S_exit" = "$S_secondary" ] && pass t02.exit "tailscale exit node is the secondary $S_exit" || fail t02.exit "exit node '$S_exit' is not the secondary '$S_secondary'"
	else fail t02.switch "no switch to the secondary (state $S_state)"; fi
	guard_report t02.never_open
	_ip=$(egress_ip) && pass t02.egress "router egress works via the secondary (IP $_ip)" || warn t02.egress "router-own request failed on the secondary"
	hold failover-secondary
	FP=''
	SAMPLES=0 BADSAMPLES=''
	if wait_state "PRIMARY_ACTIVE" "${AR_T02_RETURN_MAX:-300}"; then pass t02.return "returned to PRIMARY_ACTIVE (exit $S_exit)"
	else warn t02.return "no return to the primary within ${AR_T02_RETURN_MAX:-300}s (state $S_state; return needs TSEM_RETURN_N successes and TSEM_DWELL)"; fi
	guard_report t02.never_open_return
	info t02.note "outage detection by a real unreachable node is not exercised (simulation by identity mismatch); to cover it, disable the exit node in the Tailscale admin console and watch 'tsem status'"
}

t03_both_down() {
	sect "t03 BOTH exit nodes down (LAN loses Internet by design; must be BLOCKED, never a WAN fallback)"
	need_german || return 0
	SAMPLES=0 BADSAMPLES=''
	# positive control: the same probe must SUCCEED in german, otherwise a later failure proves nothing
	CURL_CONTROL=none
	if ! have curl; then CURL_CONTROL="curl is not installed"
	elif [ -n "$(egress_ip)" ]; then CURL_CONTROL=ok; pass t03.curl_control "curl reaches the Internet through the exit node in german (positive control)"
	else CURL_CONTROL="curl does not work in german"; fail t03.curl_control "positive control failed: curl does not reach the Internet in german, the BLOCKED leak test cannot be trusted"; fi
	FP=$FAULT_NAME_P FS=$FAULT_NAME_S
	if wait_state "BLOCKED" "${AR_T03_MAX:-240}"; then pass t03.blocked "state BLOCKED reached"; else fail t03.blocked "state $S_state, expected BLOCKED"; fi
	guard_report t03.never_open
	[ "$S_guard" = blocked ] && pass t03.guard "guard=blocked kill_switch_active=$S_ks" || fail t03.guard "guard=$S_guard (expected blocked)"
	[ "$S_leak" = false ] && pass t03.leak "leak_risk=false" || fail t03.leak "leak_risk=$S_leak"
	[ "$S_exit" = none ] || [ -z "$S_exit" ] && pass t03.exit "no exit node selected" || warn t03.exit "exit node '$S_exit' still selected while BLOCKED"
	# router-own traffic must not reach the Internet through the WAN; only a probe that is known to work counts
	case $CURL_CONTROL in
	ok)
		case $(probe_https https://1.1.1.1/cdn-cgi/trace) in
		reached) fail t03.router_egress "router-own HTTPS request SUCCEEDED while BLOCKED: unprotected WAN path" ;;
		blocked) pass t03.router_egress "router-own HTTPS request fails while BLOCKED (curl worked in german before, so this failure is real)" ;;
		*) fail t03.router_egress "curl failed in a way that does not show a blocked path (inconclusive): NOT counted as a pass" ;;
		esac ;;
	*) fail t03.router_egress "no working curl positive control in german ($CURL_CONTROL): the leak test is inconclusive, NOT a pass" ;;
	esac
	have ip || fail t03.lan_route "ip is missing: forwarded LAN traffic cannot be checked"
	if have ip; then
		_rg=$(ip route get 1.1.1.1 from 192.168.8.2 iif br-lan 2>&1)
		case $(route_class "$_rg") in
		denied) pass t03.lan_route "forwarded LAN traffic is denied by policy routing: $_rg" ;;
		routed | tunnel) fail t03.lan_route "LAN traffic would be routed: $_rg" ;;
		*) fail t03.lan_route "unrecognised ip route output, inconclusive (NOT a pass): $_rg" ;;
		esac
		ip rule show 2>/dev/null | grep -Eq 'prohibit|unreachable|blackhole' && pass t03.deny "deny ip rule present" || fail t03.deny "deny ip rule missing"
	fi
	hold blocked
	FP='' FS=''
	SAMPLES=0 BADSAMPLES=''
	if wait_state "PRIMARY_ACTIVE SECONDARY_ACTIVE" "${AR_T03_RETURN_MAX:-300}"; then pass t03.recovered "exit node active again ($S_state)"; else warn t03.recovered "still $S_state after ${AR_T03_RETURN_MAX:-300}s: guard=$S_guard (kill switch remains closed)"; fi
	guard_report t03.never_open_return
}

t04_dns() {
	sect "t04 DNS (german)"
	need_german || return 0
	_st=$("$TSEM" selftest 2>&1)
	echo "$_st" | grep -i 'dns' | while IFS= read -r _l; do info t04.selftest "$_l"; done
	if have nslookup && nslookup example.com >/dev/null 2>&1; then pass t04.resolve "router resolves example.com in german"; else fail t04.resolve "router cannot resolve example.com"; fi
	_rg=$(have ip && ip route get 8.8.8.8 2>&1)
	case $(route_class "$_rg") in
	tunnel) pass t04.hardcoded "a hard-coded resolver (8.8.8.8) is reached through the tunnel: $_rg" ;;
	denied) pass t04.hardcoded "a hard-coded resolver is not reachable via WAN: $_rg" ;;
	routed) fail t04.hardcoded "route to 8.8.8.8 does not use the tunnel: $_rg" ;;
	*) fail t04.hardcoded "no usable ip route output (inconclusive, NOT a pass): '$_rg'" ;;
	esac
	have nslookup || fail t04.tool "nslookup is missing: DNS cannot be tested"
	hold dns
}

t05_ipv6() {
	sect "t05 IPv6 (german)"
	need_german || return 0
	if [ ! -e /proc/net/if_inet6 ] || ! ip -6 addr show scope global 2>/dev/null | grep -q inet6; then warn t05.ipv6 "no global IPv6 on this router: IPv6 leaks cannot be tested here"; hold ipv6; return 0; fi
	have ip6tables && ip6tables -S TSEM_FWD >/dev/null 2>&1 && pass t05.chain "ip6tables chain TSEM_FWD present" || fail t05.chain "ip6tables TSEM_FWD missing: IPv6 is not covered"
	ip -6 rule show 2>/dev/null | grep -Eq 'prohibit|unreachable|blackhole' && pass t05.deny "IPv6 deny rule present" || fail t05.deny "no IPv6 deny rule"
	_rg=$(ip -6 route get 2606:4700:4700::1111 from fe80::1 iif br-lan 2>&1); _rr=$?
	case $(route_class "$_rg") in
	tunnel | denied) pass t05.route "forwarded IPv6 is tunnelled or denied: $_rg" ;;
	routed) fail t05.route "forwarded IPv6 would leave via the WAN: $_rg" ;;
	*) fail t05.route "unrecognised ip -6 route output (rc $_rr), inconclusive (NOT a pass): $_rg" ;;
	esac
	hold ipv6
}

t06_fastpath() {
	sect "t06 SFE / fast path / flow offloading (german)"
	need_german || return 0
	if ! have lsmod || [ -z "$(lsmod 2>/dev/null)" ]; then fail t06.lsmod "lsmod is missing or prints nothing: loaded fast-path modules cannot be checked (NOT a pass)"; hold fastpath; return 0; fi
	_mods=$(lsmod 2>/dev/null | awk '{print $1}' | grep -E '^(shortcut_fe|shortcut_fe_cm|shortcut_fe_drv|shortcut_fe_ipv6|fast_classifier|sfe_|ecm|qca_nss_ecm)' | tr '\n' ' ')
	[ -z "$_mods" ] && pass t06.modules "no fast-path module loaded while the guard is closed" || fail t06.modules "fast-path module(s) loaded in german: $_mods (established flows can bypass the kill switch)"
	if [ -r "${BK:-/nonexistent}/lsmod.txt" ] || [ -s "$AR_RUN/backup.dir" ]; then
		_bd=$(cat "$AR_RUN/backup.dir" 2>/dev/null)
		if [ -r "$_bd/lsmod.txt" ] && grep -Eq '^(shortcut_fe|fast_classifier|sfe_|ecm|qca_nss_ecm)' "$_bd/lsmod.txt"; then
			[ -z "$_mods" ] && pass t06.unloaded "fast path was loaded before (backup) and is gone: tsem unloaded it when the guard closed" || fail t06.unloaded "fast path was loaded before and is still loaded"
		else warn t06.unloaded "no fast-path module was loaded before the tests: the unload path was NOT exercised on this hardware"; fi
	fi
	grep -q "flow_offloading[' ]*'\{0,1\}1" "$R/etc/config/firewall" 2>/dev/null && warn t06.offload "firewall flow_offloading is enabled in /etc/config/firewall" || info t06.offload "firewall flow_offloading not enabled in UCI"
	_fw=$(have iptables && iptables -S FORWARD 2>/dev/null)
	if [ -z "$_fw" ]; then fail t06.flowoffload "iptables is missing or lists no FORWARD rules: flow offloading cannot be checked (NOT a pass)"
	elif printf '%s\n' "$_fw" | grep -q FLOWOFFLOAD; then fail t06.flowoffload "a FLOWOFFLOAD rule is present in FORWARD"
	else pass t06.flowoffload "no FLOWOFFLOAD rule in FORWARD"; fi
	[ "$S_guard" = german ] && pass t06.guard "guard consistent (german): not reported inconsistent by the fast-path check" || fail t06.guard "guard=$S_guard"
}

sampler_start() { # background sampler of both protection layers during a disturbance
	rm -f "$AR_RUN/sampler.stop" "$AR_RUN/sampler.out"
	(
		while [ ! -e "$AR_RUN/sampler.stop" ]; do
			_l1=0 _l2=0
			ip rule show 2>/dev/null | grep -Eq 'iif br-lan.*(prohibit|unreachable|blackhole)' && _l1=1
			iptables -S FORWARD 2>/dev/null | grep -q TSEM_FWD && _l2=1
			echo "$_l1 $_l2" >>"$AR_RUN/sampler.out"
			sleep "${AR_SAMPLE_STEP:-0.3}" 2>/dev/null || sleep 1
		done
	) >/dev/null 2>&1 </dev/null & # never hold the caller's stdout: an ssh session or a pipe would not end while this loop lives
	SAMPLER=$!
}
sampler_stop() {
	: >"$AR_RUN/sampler.stop"
	# sampler_stop usually runs inside $(...): `wait` cannot see a sibling's child there, so poll and, if needed, kill it
	_sw=0
	while kill -0 "$SAMPLER" 2>/dev/null && [ "$_sw" -lt 30 ]; do sleep 0.2 2>/dev/null || sleep 1; _sw=$((_sw + 1)); done
	kill "$SAMPLER" 2>/dev/null
	_tot=$(wc -l <"$AR_RUN/sampler.out" 2>/dev/null | tr -d ' ')
	_both=$(grep -c '^0 0$' "$AR_RUN/sampler.out" 2>/dev/null)
	_l1=$(grep -c '^0 ' "$AR_RUN/sampler.out" 2>/dev/null)
	_l2=$(grep -c ' 0$' "$AR_RUN/sampler.out" 2>/dev/null)
	rm -f "$AR_RUN/sampler.stop"
	echo "SAMPLES=${_tot:-0} L1MISS=${_l1:-0} L2MISS=${_l2:-0} BOTHMISS=${_both:-0}"
}
report_window() { # id TOTAL L1 L2 BOTH
	[ "${2:-0}" -gt 0 ] || { warn "$1.samples" "sampler produced no samples: no window evidence"; return; }
	if [ "${5:-0}" -gt 0 ]; then fail "$1.window" "both protection layers were absent in ${5} of ${2} samples: UNPROTECTED WINDOW observed"
	elif [ "${3:-0}" -gt 0 ]; then fail "$1.window" "policy-routing layer 1 absent in ${3} of ${2} samples (it must stay in place)"
	else pass "$1.window" "layer 1 present in all ${2} samples${4:+ (layer 2 absent in $4: expected during a reload, covered by layer 1)}"; fi
	info "$1.limit" "sampling is periodic (about every 0.3 s): a shorter gap cannot be excluded, this is evidence, not proof"
}

t07_fwreload() {
	sect "t07 firewall reload (fw3 flushes the built-in chains; layer 1 must hold; the include must restore layer 2)"
	need_german || return 0
	SAMPLES=0 BADSAMPLES=''
	hold fwreload-begin
	sampler_start
	"$INITD/firewall" reload >/dev/null 2>&1; _rc=$?
	_t0=$(now)
	_ok=0
	while [ $(($(now) - _t0)) -lt "${AR_RELOAD_WAIT:-15}" ]; do snap; [ "$S_guard" = german ] && { _ok=1; break; }; waitt 1; done
	_r=$(sampler_stop)
	[ "$_rc" -eq 0 ] && pass t07.reload "firewall reload finished (rc 0)" || warn t07.reload "firewall reload rc $_rc"
	[ "$_ok" -eq 1 ] && pass t07.restored "guard back to german after the reload (include re-applied layer 2)" || fail t07.restored "guard=$S_guard after ${AR_RELOAD_WAIT:-15}s: the include did not restore the kill switch"
	# shellcheck disable=SC2046
	set -- $(printf '%s' "$_r" | sed 's/[A-Z0-9]*=//g')
	report_window t07 "${1:-0}" "${2:-0}" "${3:-0}" "${4:-0}"
	hold fwreload-end
	need_german >/dev/null 2>&1 && pass t07.state "state unchanged: $S_state" || warn t07.state "state after reload: $S_state"
}

t08_tsrestart() {
	sect "t08 tailscale restart (the exit node disappears; the guard must stay closed; the exit node must come back)"
	need_german || return 0
	if [ "${AR_SSH_PATH:-unknown}" = tailnet ] && [ "${AR_ALLOW_TAILNET:-0}" != 1 ]; then skip t08.restart "this SSH session runs over Tailscale and would be cut: reconnect via the LAN address"; return 0; fi
	SAMPLES=0 BADSAMPLES=''
	hold tsrestart-begin
	sampler_start
	"$INITD/tailscale" restart >/dev/null 2>&1; _rc=$?
	[ "$_rc" -eq 0 ] && pass t08.restart "tailscale restart finished (rc 0)" || warn t08.restart "tailscale restart rc $_rc"
	FP='' FS=''
	if wait_state "PRIMARY_ACTIVE SECONDARY_ACTIVE" "${AR_T08_MAX:-180}"; then
		[ "$S_state" = PRIMARY_ACTIVE ] && pass t08.recovered "PRIMARY_ACTIVE again (exit $S_exit)" || warn t08.recovered "recovered on the secondary ($S_exit)"
	else fail t08.recovered "no exit node after ${AR_T08_MAX:-180}s (state $S_state guard $S_guard)"; fi
	_r=$(sampler_stop)
	guard_report t08.never_open
	# shellcheck disable=SC2046
	set -- $(printf '%s' "$_r" | sed 's/[A-Z0-9]*=//g')
	report_window t08 "${1:-0}" "${2:-0}" "${3:-0}" "${4:-0}"
	hold tsrestart-end
}

cmd_test() {
	need_tests_ok
	_sel=${1:-}
	[ -n "$_sel" ] || refuse "usage: test t00_activate | t01_primary | t02_failover | t03_both_down | t04_dns | t05_ipv6 | t06_fastpath | t07_fwreload | t08_tsrestart | all"
	[ "$_sel" != all ] || _sel="t00_activate t01_primary t02_failover t03_both_down t04_dns t05_ipv6 t06_fastpath t07_fwreload t08_tsrestart"
	for _t in $_sel; do
		case $_t in t0[0-8]_*) ;; *) refuse "unknown test $_t" ;; esac
		"$_t"
		FP='' FS=''
		ka
		if armed; then pass "$_t.watchdog" "the recovery watchdog is still alive after $_t (heartbeat fresh)"; else fail "$_t.watchdog" "the recovery watchdog is NOT alive after $_t: run 'recover' now and do not continue"; fi
	done
	# the end state of every test run is a closed kill switch
	snap
	case $S_guard in
	german | blocked) pass final.killswitch "end state: guard=$S_guard (kill switch closed)" ;;
	*) fail final.killswitch "end state guard=$S_guard: NOT closed (run: recover)" ;;
	esac
	finish
}

# ================================================================== diagnostics (read-only)
# Both commands only READ state. They send a few probe packets (ping, one HTTPS request per URL, one DNS
# query) and change no route, rule, chain, exit node, mode or file. Secrets are removed before printing.
bundle_redact() { sed -E 's/tskey-[A-Za-z0-9_-]+/tskey-REDACTED/g' | grep -v -i -E 'private ?key|auth ?key|token|password|preshared|psk'; }
bundle_sec() { printf '\n##### %s\n' "$1"; }
bundle_run() { # cmd args...: prints the command, its (redacted, bounded) output and a non-zero exit code
	printf '$ %s\n' "$*"
	if ! have "$1"; then echo "(not available: $1)"; return 0; fi
	_bo=$("$@" 2>&1); _br=$?
	printf '%s\n' "$_bo" | bundle_redact | head -n "${AR_BUNDLE_LINES:-120}"
	[ "$_br" -eq 0 ] || echo "(exit $_br)"
	return 0
}
bundle_grep() { # label, pattern, cmd args...
	_bl=$1 _bp=$2
	shift 2
	printf '$ %s | grep -E %s\n' "$*" "$_bp"
	have "$1" || { echo "(not available: $1)"; return 0; }
	"$@" 2>&1 | grep -E "$_bp" | bundle_redact | head -n "${AR_BUNDLE_LINES:-120}"
	return 0
}
# one HTTPS request with a classified result; $2 = optional source address (the LAN-side address of this router)
bundle_fetch() {
	_bu=$1 _bs=${2:-}
	have curl || { echo "(no curl)"; return 0; }
	if [ -n "$_bs" ]; then
		_bo=$(curl -sS -o /dev/null --interface "$_bs" --connect-timeout 5 --max-time 8 -w 'http=%{http_code} time=%{time_total}s ip=%{remote_ip}' "$_bu" 2>&1); _br=$?
	else
		_bo=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 8 -w 'http=%{http_code} time=%{time_total}s ip=%{remote_ip}' "$_bu" 2>&1); _br=$?
	fi
	printf 'fetch %s%s -> curl_exit=%s %s\n' "$_bu" "${_bs:+ (source $_bs)}" "$_br" "$(printf '%s' "$_bo" | tr '\n' ' ' | cut -c1-200)"
}
cmd_diag_bundle() {
	echo "TSEM DIAGNOSTIC BUNDLE (read-only; secrets removed) $(date '+%Y-%m-%d %H:%M:%S %z')"
	bundle_sec "1 system and tsem"
	bundle_run date
	bundle_run uptime
	[ -r "$R/etc/openwrt_release" ] && sed -n '1,6p' "$R/etc/openwrt_release"
	[ -x "$TSEM" ] || { echo "tsem is not installed ($TSEM)"; return 0; }
	bundle_run "$TSEM" status
	bundle_run "$TSEM" intent-check
	bundle_run "$TSEM" verify-nodes
	_s=$("$TSEM" status 2>/dev/null)
	_p=$(kv "$_s" primary) _q=$(kv "$_s" secondary)
	bundle_sec "2 tailscale (prefs without keys)"
	bundle_run tailscale status
	bundle_grep prefs 'Exit|RouteAll|Netfilter|Shields|CorpDNS|AdvertiseRoutes|AllowLAN|AcceptDNS' tailscale debug prefs
	for _n in $_p $_q; do
		case $_n in none | '') continue ;; esac
		bundle_run tailscale ping -c 3 --timeout=5s "$_n"
	done
	bundle_sec "3 routing (ip rules, tables, the decision for a LAN client)"
	bundle_run ip -4 rule
	bundle_run ip -6 rule
	bundle_run ip route show table all
	bundle_run ip route get 1.1.1.1
	bundle_run ip route get 10.30.0.1
	_cl=$(ip -4 neigh show dev br-lan 2>/dev/null | awk '$1 ~ /^[0-9]/ && $NF != "FAILED" { print $1; exit }')
	[ -z "$_cl" ] || bundle_run ip route get 1.1.1.1 from "$_cl" iif br-lan
	bundle_sec "4 netfilter (packet counters show where traffic is stopped)"
	bundle_run iptables -vnL FORWARD
	bundle_run iptables -vnL TSEM_FWD
	bundle_run iptables -vnL TSEM_OUT
	bundle_run iptables -t nat -vnL POSTROUTING
	bundle_grep ts-zone 'tailscale|ts-' iptables -S
	bundle_run ip6tables -vnL TSEM_FWD
	bundle_run ip6tables -vnL TSEM_OUT
	for _c in count max; do [ -r "/proc/sys/net/netfilter/nf_conntrack_$_c" ] && echo "conntrack_$_c=$(cat "/proc/sys/net/netfilter/nf_conntrack_$_c")"; done
	bundle_grep modules 'shortcut|fast_class|ecm|hnat|flow' lsmod
	bundle_sec "5 egress and DNS right now (probes; classified)"
	_lan=$(ip -4 addr show dev br-lan 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')
	for _u in https://1.1.1.1/cdn-cgi/trace https://9.9.9.9/ https://example.com/; do
		bundle_fetch "$_u"
		[ -z "$_lan" ] || bundle_fetch "$_u" "$_lan"
	done
	have nslookup && { echo '$ nslookup example.com 127.0.0.1'; _tmo_run 8 nslookup example.com 127.0.0.1 2>&1 | tail -n 4; }
	bundle_sec "6 log (tsem, tailscale, switch, hotplug, firewall; last lines)"
	bundle_grep log 'tsem|tailscale|gl-switch|switch|hotplug|firewall' logread | tail -n "${AR_BUNDLE_LOG:-80}"
	bundle_sec "7 hardware switch evidence (how does this firmware call the hook?)"
	bundle_run ls -l /etc/gl-switch.d /etc/rc.button
	[ -f "$R/etc/gl-switch.d/tailscale-de.sh" ] && { echo "hook md5: $(md5sum "$R/etc/gl-switch.d/tailscale-de.sh" 2>/dev/null | cut -d' ' -f1)"; sed -n '1,40p' "$R/etc/gl-switch.d/tailscale-de.sh" | bundle_redact; }
	bundle_grep refs 'gl-switch|gl_switch|BTN' grep -rIs -l -e gl-switch -e gl_switch /etc/init.d /etc/rc.button /usr/bin /usr/sbin /lib/functions
	bundle_grep proc 'switch|button|gl_' ps w
	[ -r /sys/kernel/debug/gpio ] && bundle_grep gpio 'switch|button|btn|mode' cat /sys/kernel/debug/gpio
	bundle_grep gluci 'tailscale' uci show
	bundle_grep fwuci 'tailscale|masq' uci show firewall
	echo
	echo "END OF BUNDLE"
	return 0
}
_tmo_run() { _tt=$1; shift; if timeout 1 true >/dev/null 2>&1; then timeout "$_tt" "$@"; else "$@"; fi; }

# nodes-check: identity (tsem verify-nodes) and reachability of both exit nodes. NO routing/guard/exit-node change.
# A ping proves the peer answers, not that it forwards to the Internet: that is proven only by t00..t02 (egress through the selected node).
cmd_nodes_check() {
	sect "Exit nodes: identity and reachability (read-only; reachability is not egress)"
	[ -x "$TSEM" ] || refuse "tsem is not installed"
	_vn=$("$TSEM" verify-nodes 2>&1); _vr=$?
	printf '%s\n' "$_vn" | while IFS= read -r _l; do [ -z "$_l" ] || info nodes.identity "$_l"; done
	[ "$_vr" -eq 0 ] && pass nodes.identity "both configured exit nodes are the intended, approved, online nodes" || fail nodes.identity "identity verification failed (see lines above)"
	_s=$("$TSEM" status 2>/dev/null)
	for _w in primary secondary; do
		_ip=$(kv "$_s" "$_w")
		case $_ip in none | '') skip "nodes.$_w" "not configured"; continue ;; esac
		_got=0 _path=none _ms=''
		_i=0
		while [ "$_i" -lt 3 ]; do
			_o=$(_tmo_run 9 tailscale ping -c 1 --timeout=5s "$_ip" 2>&1)
			case $_o in
			*"pong from"*)
				_got=$((_got + 1))
				case $_o in *"via DERP("*) _path="relay $(printf '%s' "$_o" | sed -n 's/.*via DERP(\([^)]*\)).*/\1/p' | head -n 1)" ;; *) _path=direct ;; esac
				_ms=$(printf '%s' "$_o" | sed -n 's/.* in \([0-9.]*ms\).*/\1/p' | head -n 1)
				;;
			esac
			_i=$((_i + 1))
		done
		if [ "$_got" -ge 1 ]; then pass "nodes.$_w.ping" "$_ip answers: $_got of 3 pongs, path $_path, last $_ms (reachability only, not egress)"
		else fail "nodes.$_w.ping" "$_ip did not answer 3 tailscale pings"; fi
	done
	info nodes.note "Internet egress through the nodes is proven only while the exit node is selected under a closed guard: tests t00/t01/t02"
	finish
}

# extnet-check (read-only): are the remote-site subnets routed into the tailnet, from the router and from a LAN client's point of view?
cmd_extnet_check() {
	sect "remote-site subnets (${AR_EXTNET_NETS:-10.30.0.0/24 10.30.1.0/24 10.30.2.0/24}) stay routed, also while the exit-node guard is closed"
	_lanip=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)
	_cl=${AR_LAN_CLIENT:-$(echo "${_lanip:-10.20.0.1}" | sed 's/\.[0-9]*$/.2/')}
	for _n in ${AR_EXTNET_NETS:-10.30.0.0/24 10.30.1.0/24 10.30.2.0/24}; do
		_h=$(echo "${_n%/*}" | sed 's/\.[0-9]*$/.1/')
		_r=$(ip route get "$_h" 2>&1 | head -n 1)
		case $_r in *tailscale0*) pass "extnet.$_n.router" "router -> $_h routed via tailscale0" ;; *) fail "extnet.$_n.router" "router -> $_h is not routed via tailscale0: ${_r:-no answer}" ;; esac
		_r=$(ip route get "$_h" from "$_cl" iif br-lan 2>&1 | head -n 1)
		case $_r in *tailscale0*) pass "extnet.$_n.lan" "LAN client $_cl -> $_h routed via tailscale0 (not blocked by the guard)" ;; *) fail "extnet.$_n.lan" "LAN client -> $_h is not routed via tailscale0: ${_r:-no answer}" ;; esac
	done
	for _h in ${AR_EXTNET_HOSTS:-}; do
		ping -c 2 -W 3 "$_h" >/dev/null 2>&1 && pass "extnet.host.$_h" "host $_h answers ping" || fail "extnet.host.$_h" "host $_h does not answer ping"
	done
	[ -n "${AR_EXTNET_HOSTS:-}" ] || info extnet.hosts "no AR_EXTNET_HOSTS given: host reachability is UNVERIFIED (only the routing decision was checked)"
	finish
}

# switch-watch off|on [SECONDS] (read-only: it only polls `tsem status`; the PHYSICAL flip is done by the person)
# Proves the integration chain end to end: physical switch -> GL hook -> tsem hook -> `tsem set <mode> --source hw` -> state.
cmd_switch_watch() {
	_want=${1:-}; _max=${2:-${AR_SWITCH_MAX:-120}}
	case $_want in off) _wmode=direct ;; on) _wmode=german ;; *) refuse "usage: switch-watch off|on [seconds]" ;; esac
	[ -x "$TSEM" ] || refuse "tsem is not installed"
	sect "hardware switch event: position $_want must lead to mode $_wmode (source hw)"
	_s=$("$TSEM" status 2>/dev/null); _b=$(kv "$_s" seq); info switch.baseline "seq=${_b:-?} mode=$(kv "$_s" mode) source=$(kv "$_s" source) hw_state=$(kv "$_s" hw_state) hw_match=$(kv "$_s" hw_match)"
	_i=0 _ev=0
	while [ "$_i" -lt "$_max" ]; do
		_s=$("$TSEM" status 2>/dev/null); _q=$(kv "$_s" seq)
		[ -n "$_q" ] && [ -n "$_b" ] && [ "$_q" != "$_b" ] && { _ev=1; break; }
		armed && ka; waitt 2; _i=$((_i + 2))
	done
	if [ "$_ev" -ne 1 ]; then
		fail switch.event "no tsem event within ${_max}s after the flip: the GL firmware did not call the hook, or the hook is not the tsem hook (hw_state=$(kv "$_s" hw_state)). ls /etc/gl-switch.d, md5sum /etc/gl-switch.d/tailscale-de.sh, logread | grep -i switch"
		finish; return
	fi
	snap
	_src=$(kv "$_s" source)
	info switch.event "seq $_b -> $_q mode=$S_mode source=$_src state=$S_state guard=$S_guard"
	[ "$_src" = hw ] && pass switch.source "event came from the hardware switch (source=hw)" || fail switch.source "event source is '$_src', not hw"
	[ "$S_mode" = "$_wmode" ] && pass switch.mode "mode is $S_mode as the switch position $_want requires" || fail switch.mode "mode is '$S_mode', expected $_wmode"
	if [ "$_wmode" = direct ]; then
		{ [ "$S_guard" = none ] || [ "$S_guard" = open ]; } && pass switch.direct "explicit DIRECT: kill switch off by the user's own switch" || fail switch.direct "mode direct but guard=$S_guard kill_switch=$S_ks"
		waitt 3
		if _ip=$(egress_ip); then pass switch.direct.egress "DIRECT: router-own HTTPS request works via the WAN, public IP $_ip (must be the your WAN IP, not the exit node)"; echo "DIRECT_EGRESS_IP=$_ip"; else fail switch.direct.egress "DIRECT mode but the router-own HTTPS request fails: check the WAN (repeater/uplink), not the exit nodes"; fi
	else
		_j=0
		while [ "$_j" -lt "${AR_SWITCH_ACTIVE_MAX:-90}" ]; do
			snap
			case $S_state in PRIMARY_ACTIVE | SECONDARY_ACTIVE) break ;; esac
			armed && ka; waitt 3; _j=$((_j + 3))
		done
		case $S_guard in none | open | inconsistent) fail switch.guard "guard is $S_guard in mode german" ;; *) pass switch.guard "guard $S_guard stayed closed during activation (fail-closed)" ;; esac
		case $S_state in PRIMARY_ACTIVE | SECONDARY_ACTIVE) pass switch.active "german active via $S_exit ($S_state)" ;; *) fail switch.active "german not active after the switch (state $S_state, guard $S_guard stays closed)" ;; esac
	fi
	finish
}

# ---- DIRECT return path: proven BEFORE any active step (read-only; the simulation runs on a throw-away MOCK backend) ----
cmd_direct_path_check() {
	_bk=${1:-} _sd=${2:-}
	sect "DIRECT return path (read-only): the way back is proven before anything active happens"
	_nf0=$NF
	# 1. the command that opens the kill switch exists in the live controller and in the staged one
	if [ -x "$TSEM" ] && grep -q 'direct' "$TSEM" 2>/dev/null; then pass direct.path.live "live controller $TSEM supports the direct mode"; else fail direct.path.live "live controller $TSEM missing or without direct mode"; fi
	if [ -f "$REPO/src/usr/sbin/tsem" ] && grep -q 'direct' "$REPO/src/usr/sbin/tsem"; then pass direct.path.staged "the controller to be installed supports the direct mode"; else fail direct.path.staged "the staged controller has no direct mode"; fi
	if "$TSEM" intent-check >/dev/null 2>&1; then pass direct.path.intent "the saved mode is readable (no 'blocked because the intent is unreadable' surprise)"; else fail direct.path.intent "the live intent is invalid: fix it with 'tsem set german|direct' first"; fi
	# 2. the tools the real DIRECT switch-over needs
	_miss=''
	for _c in iptables ip flock awk; do have "$_c" || _miss="$_miss $_c"; done
	[ ! -e /proc/net/if_inet6 ] || have ip6tables || _miss="$_miss ip6tables"
	[ -z "$_miss" ] && pass direct.path.tools "iptables, ip, flock, awk present (ip6tables where IPv6 is enabled)" || fail direct.path.tools "missing tools for the DIRECT switch-over:$_miss"
	have tailscale && pass direct.path.tailscale "tailscale CLI present (the exit node is cleared first on DIRECT)" || warn direct.path.tailscale "tailscale CLI not found: clearing the exit node would fail"
	# 3. the staged code, run for real on a MOCK backend in a throw-away directory: german -> direct, and the fail-closed rule
	_sim=$(mktemp -d 2>/dev/null) || { fail direct.path.sim "cannot create a temp directory"; finish; }
	mkdir -p "$_sim/m" "$_sim/r" "$_sim/s"
	_t() { env TSEM_BACKEND=mock TSEM_MOCK_DIR="$_sim/m" TSEM_RUN_DIR="$_sim/r" TSEM_STATE_DIR="$_sim/s" TSEM_LIBDIR="$REPO/src/usr/lib/tsem" \
		TSEM_CONF=/nonexistent TSEM_SYSLOG=0 TSEM_PRIMARY=100.64.0.1 TSEM_SECONDARY=100.64.0.2 TSEM_SET_TICK_DELAY=0 TSEM_NOW="${_sn:-1790000000}" sh "$REPO/src/usr/sbin/tsem" "$@"; }
	_sn=1790000000
	_t set german --no-wait >/dev/null 2>&1
	_i=0; while [ "$_i" -lt 6 ]; do _t tick >/dev/null 2>&1; _sn=$((_sn + 5)); _i=$((_i + 1)); done
	_ss=$(_t status 2>/dev/null)
	[ "$(kv "$_ss" state)" = PRIMARY_ACTIVE ] && pass direct.path.sim.german "simulated german reaches PRIMARY_ACTIVE with the guard $(kv "$_ss" guard)" || fail direct.path.sim.german "simulated german did not become active: state=$(kv "$_ss" state)"
	_dm=direct; _t set "$_dm" >/dev/null 2>&1; _ss=$(_t status 2>/dev/null)
	if [ "$(kv "$_ss" mode)" = direct ] && [ "$(kv "$_ss" guard)" = open ] && [ "$(kv "$_ss" exit_node)" = none ]; then pass direct.path.sim.direct "simulated switch to direct: mode direct, guard open, exit node cleared"; else fail direct.path.sim.direct "simulated switch to direct ended in mode=$(kv "$_ss" mode) guard=$(kv "$_ss" guard) exit=$(kv "$_ss" exit_node)"; fi
	# fail-closed: both nodes down in german must never end in DIRECT by itself
	rm -rf "$_sim/m" "$_sim/r" "$_sim/s"; mkdir -p "$_sim/m/down" "$_sim/r" "$_sim/s"
	: >"$_sim/m/down/100.64.0.1"; : >"$_sim/m/down/100.64.0.2"
	_sn=1790000000; _t set german --no-wait >/dev/null 2>&1
	_i=0; while [ "$_i" -lt 12 ]; do _t tick >/dev/null 2>&1; _sn=$((_sn + 5)); _i=$((_i + 1)); done
	_ss=$(_t status 2>/dev/null)
	if [ "$(kv "$_ss" mode)" = german ] && [ "$(kv "$_ss" guard)" = blocked ] && [ "$(kv "$_ss" state)" = BLOCKED ]; then pass direct.path.sim.noauto "simulated: both exit nodes down -> BLOCKED, mode stays german, no automatic DIRECT"; else fail direct.path.sim.noauto "simulated outage ended in mode=$(kv "$_ss" mode) state=$(kv "$_ss" state) guard=$(kv "$_ss" guard)"; fi
	rm -rf "$_sim"
	# 4. the physical switch OFF position goes the same way, and recovery never opens the kill switch
	if grep -q 'direct' "$REPO/contrib/tsem-switch.sh" 2>/dev/null && grep -q -- '--source hw' "$REPO/contrib/tsem-switch.sh" 2>/dev/null; then pass direct.path.hook "the staged switch hook maps OFF to direct (source hw)"; else fail direct.path.hook "the staged switch hook does not map OFF to direct"; fi
	if [ -f "$R/etc/gl-switch.d/tailscale-de.sh" ] && cmp -s "$REPO/contrib/tsem-switch.sh" "$R/etc/gl-switch.d/tailscale-de.sh" 2>/dev/null; then info direct.path.hook.live "the live GL hook is already the tsem hook"; else info direct.path.hook.live "the live GL hook is not the tsem hook yet (replaced only by INTEGRATE-SWITCH; the original is kept)"; fi
	# (the pattern has two spaces on purpose: this tool's own source must contain the direct-mode command only in return-to-direct)
	if [ -f "$REPO/tools/tsem-rc3-recover.sh" ] && ! awk '!/^[ \t]*#/' "$REPO/tools/tsem-rc3-recover.sh" | grep -q 'set  *direct'; then pass direct.path.recovery "the recovery watchdog never switches to direct"; else fail direct.path.recovery "the recovery script is missing or switches to direct"; fi
	# 5. the previous version can be restored
	if [ -n "$_bk" ]; then
		valid_dir "$_bk" backup && backup_gate "$_bk" && pass direct.path.backup "a verified backup exists: $_bk" || fail direct.path.backup "no verified backup at '$_bk'"
	else warn direct.path.backup "no backup directory given: rollback source not checked"; fi
	if [ "$NF" -eq "$_nf0" ]; then pass direct.path.proven "the way back to DIRECT is proven by the checks above (software proof; the hardware switch itself is tested later)"; else fail direct.path.proven "the DIRECT return path is NOT proven: no active step may start"; fi
	finish
}

# ---- local API (read-only): the installed plugin, its ACL, unauthenticated access refused, not reachable from WAN ----
cmd_api_check() {
	sect "Local API / ubus (read-only)"
	_chk=$R/usr/sbin/tsem-api-check
	if [ ! -x "$_chk" ]; then fail api.installed "tsem-api-check is not installed (api component missing)"; finish; fi
	_tmp=$(mktemp 2>/dev/null) || { fail api.tmp "cannot create a temp file"; finish; }
	TSEM_PLUGIN=$R/usr/libexec/rpcd/tsem TSEM_ACL=$R/usr/share/rpcd/acl.d/tsem.json sh "$_chk" "$@" >"$_tmp" 2>&1
	while IFS=' ' read -r _lv _nm _rest; do
		case $_lv in
		PASS) pass "api.${_nm%:}" "$_rest" ;;
		FAIL) fail "api.${_nm%:}" "$_rest" ;;
		WARN | UNVERIFIED) warn "api.${_nm%:}" "UNVERIFIED: $_rest" ;;
		esac
	done <"$_tmp"
	rm -f "$_tmp"
	# the API reports what the controller reports
	if have ubus && ubus list tsem >/dev/null 2>&1; then
		_u=$(ubus call tsem status 2>/dev/null | tr -d ' \n\t')
		snap
		case $_u in
		*'"ok":true'*"\"mode\":\"$S_mode\""*) pass api.status.match "ubus call tsem status agrees with tsem status (mode=$S_mode)" ;;
		*) fail api.status.match "ubus call tsem status does not match the controller (mode=$S_mode): $(printf '%s' "$_u" | cut -c1-120)" ;;
		esac
	else
		warn api.status.match "UNVERIFIED: ubus object tsem not available"
	fi
	finish
}

# ---- native GL.iNet GUI (optional component "native-gui"): only ADDS files; journaled; undone by itself on failure ----
native_verify() { # [SD]: read-only
	_nf0=$NF
	_nb=$R/www/views/gl-sdk4-ui-tsem.common.js
	for _p in usr/share/oui/menu.d/tsem.json www/views/gl-sdk4-ui-tsem.common.js www/views/gl-sdk4-ui-tsem.common.js.gz usr/lib/oui-httpd/rpc/tsem; do
		if [ -f "$R/$_p" ]; then pass "native.file.$(basename "$_p" | tr -c 'A-Za-z0-9\n' _)" "/$_p present"; else fail "native.file.$(basename "$_p" | tr -c 'A-Za-z0-9\n' _)" "/$_p is missing"; fi
	done
	if [ -f "$_nb" ] && [ -f "$_nb.gz" ] && have gzip; then
		gzip -dc "$_nb.gz" 2>/dev/null | cmp -s - "$_nb" && pass native.gz "the gzip copy of the view equals the view" || fail native.gz "the gzip copy differs from the view or is not valid gzip"
	fi
	_mn=$R/usr/share/oui/menu.d/tsem.json
	if [ -f "$_mn" ]; then
		grep -q '"view" *: *"tsem"' "$_mn" && pass native.menu.view "menu entry points at the view 'tsem'" || fail native.menu.view "menu entry does not name the view 'tsem'"
		_ts=''
		for _f in "$R"/usr/share/oui/menu.d/*.json; do grep -q '"view" *: *"tailscale"' "$_f" 2>/dev/null && { _ts=$_f; break; }; done
		if [ -n "$_ts" ]; then
			_pa=$(sed -n 's/.*"parent" *: *"\([^"]*\)".*/\1/p' "$_ts" | head -n 1)
			_pb=$(sed -n 's/.*"parent" *: *"\([^"]*\)".*/\1/p' "$_mn" | head -n 1)
			_ia=$(sed -n 's/.*"index" *: *\([0-9]*\).*/\1/p' "$_ts" | head -n 1)
			_ib=$(sed -n 's/.*"index" *: *\([0-9]*\).*/\1/p' "$_mn" | head -n 1)
			[ -n "$_pa" ] && [ "$_pa" = "$_pb" ] && pass native.menu.parent "same parent as the Tailscale entry ($_pa)" || fail native.menu.parent "parent '$_pb' differs from the Tailscale entry's '$_pa'"
			info native.menu.index "Tailscale index=$_ia, TSEM index=$_ib (the entry sorts right below Tailscale only if no other entry sits between)"
		else warn native.menu.parent "UNVERIFIED: no Tailscale menu entry to compare with"; fi
	fi
	have lua && { lua -e 'assert(loadfile("'"$R"'/usr/lib/oui-httpd/rpc/tsem"))' >/dev/null 2>&1 && pass native.rpc.syntax "the Lua bridge compiles" || fail native.rpc.syntax "the Lua bridge does not compile"; } || warn native.rpc.syntax "UNVERIFIED: no lua interpreter on the router: the bridge was not compiled"
	[ "$NF" -eq "$_nf0" ]
}
cmd_native_check() { sect "Native GL.iNet GUI files (read-only)"; native_verify || true; finish; }
cmd_native_install() {
	[ "${1:-}" = --confirm-native ] || refuse "native-install needs --confirm-native BACKUP_DIR STAGE_DIR"
	_bk=${2:-} _sd=${3:-}
	valid_dir "$_bk" backup && [ -d "$_bk" ] || refuse "needs the backup directory"
	valid_dir "$_sd" stage && [ -s "$_sd/repo/install.sh" ] || refuse "needs the stage directory"
	trap '' HUP INT TERM PIPE
	sect "Install the native GL.iNet GUI (adds files only; journaled; undone automatically if the check fails)"
	backup_gate "$_bk" || { fail native.backup "backup gate failed: nothing installed"; echo "NATIVE_RESULT=refused"; finish; }
	stage_gate "$_sd" || { fail native.stage "stage gate failed: nothing installed"; echo "NATIVE_RESULT=refused"; finish; }
	[ ! -e "$R/etc/tsem/backup/INPROGRESS" ] || { fail native.pending "an interrupted install is pending: run install-recover first"; echo "NATIVE_RESULT=refused"; finish; }
	_fw0=$(cd "$R/usr/share/oui/menu.d" 2>/dev/null && for _f in *.json; do [ "$_f" = tsem.json ] || printf '%s %s\n' "$_f" "$(hsum "$_f")"; done)
	_lt0=$(cat "$R/etc/tsem/backup/LATEST" 2>/dev/null)
	_o=$(inst_sh "$_sd/repo/install.sh" --yes --components native-gui --accept-undocumented-native-gui --no-service-reload 2>&1 </dev/null); _rc=$?
	printf '%s\n' "$_o" | tail -n 8 | while IFS= read -r _l; do info install.log "$_l"; done
	_ok=0
	[ "$_rc" -eq 0 ] && pass native.install.rc "install.sh finished (rc 0)" || { fail native.install.rc "install.sh refused or failed (rc $_rc); it restored the previous state itself"; _ok=1; }
	if [ "$_ok" -eq 0 ]; then native_verify || _ok=1; fi
	_fw1=$(cd "$R/usr/share/oui/menu.d" 2>/dev/null && for _f in *.json; do [ "$_f" = tsem.json ] || printf '%s %s\n' "$_f" "$(hsum "$_f")"; done)
	[ "$_fw0" = "$_fw1" ] && pass native.foreign "no GL.iNet menu file was changed" || { fail native.foreign "a GL.iNet menu file changed"; _ok=1; }
	if [ "$_ok" -eq 0 ]; then
		echo "NATIVE_RESULT=ok"
	else
		if [ "$_rc" -eq 0 ] && [ "$(cat "$R/etc/tsem/backup/LATEST" 2>/dev/null)" != "$_lt0" ]; then
			_o=$(inst_sh "$_sd/repo/install.sh" --rollback --yes 2>&1 </dev/null) && pass native.rollback "the native GUI install was rolled back" || fail native.rollback "rollback failed: $(printf '%s' "$_o" | tail -n 1)"
		fi
		echo "NATIVE_RESULT=restored"
	fi
	finish
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
preflight) cmd_preflight ;;
backup) cmd_backup ;;
backup-stream) cmd_backup_stream "$@" ;;
stage-rc3) cmd_stage_rc3 "$@" ;;
wire) cmd_wire "$@" ;;
install-recover) cmd_install_recover "$@" ;;
verify-prepared) cmd_verify_prepared "$@" ;;
diag-bundle) cmd_diag_bundle ;;
nodes-check) cmd_nodes_check ;;
direct-path-check) cmd_direct_path_check "$@" ;;
api-check) cmd_api_check "$@" ;;
native-check) cmd_native_check ;;
native-install) cmd_native_install "$@" ;;
extnet-check) cmd_extnet_check ;;
switch-watch) cmd_switch_watch "$@" ;;
go-live) cmd_go_live "$@" ;;
final-state) cmd_final_state ;;
persist-check) cmd_persist_check "$@" ;;
recovery-arm) cmd_recovery_arm "$@" ;;
recovery-verify) cmd_recovery_verify ;;
recovery-keepalive) cmd_recovery_keepalive ;;
recovery-ensure) cmd_recovery_ensure ;;
recovery-disarm) cmd_recovery_disarm ;;
recovery-status) cmd_recovery_status ;;
recover) cmd_recover ;;
rollback) cmd_rollback "$@" ;;
return-to-direct) cmd_return_to_direct "$@" ;;
activate) cmd_activate "$@" ;;
stop-service) cmd_stop_service ;;
test) cmd_test "$@" ;;
status) snap; echo "mode=$S_mode state=$S_state guard=$S_guard exit=$S_exit leak_risk=$S_leak version=$S_ver" ;;
*) echo "usage: tsem-rc3-active.sh preflight|diag-bundle|nodes-check|direct-path-check|api-check|extnet-check|switch-watch|backup|stage-rc3|wire|install-recover|verify-prepared|go-live|final-state|persist-check|recovery-arm|recovery-verify|recovery-keepalive|recovery-ensure|recovery-disarm|recovery-status|recover|rollback|return-to-direct|activate|stop-service|test|status" >&2; exit 64 ;;
esac
