#!/bin/sh
# tsem-switch-hook v2 (marker: install/uninstall recognise this file as the tsem hook)
# GL.iNet hardware-switch hook for tsem. Thin wrapper: the ONLY thing it does is
# call the central controller (`tsem set ... --source hw --no-wait`). No firewall, no tailscale.
#
# Calling convention (community-documented, NOT confirmed by GL.iNet): the firmware's switch handler runs the
# script selected as the toggle-button function from /etc/gl-switch.d/ and passes the position as the first
# argument (on|off); some firmware versions define it as the variable `action` instead. This hook therefore
# accepts, in this order, $1, $action, $ACTION as on|off|1|0|true|false|german|direct and does NOTHING for anything
# else (fail-safe: an unknown input never changes the state; OpenWrt "pressed"/"released" button events are ignored).
#
# Trace mode: `echo trace > /etc/tsem/hook.mode` logs the arguments/environment names
# to syslog and changes NOTHING. Use it once on the real device to learn how the
# firmware calls the script, then remove the file (acceptance test hw.event does this and says what it saw).

MODE_FILE=${TSEM_HOOK_MODE_FILE:-/etc/tsem/hook.mode}
TSEM_BIN=${TSEM_BIN:-/usr/sbin/tsem}
arg=${1:-${action:-${ACTION:-}}}

if [ -r "$MODE_FILE" ] && [ "$(head -n 1 "$MODE_FILE" 2>/dev/null)" = trace ]; then
	logger -t tsem-hook "TRACE args='$*' action='${action:-}' ACTION='${ACTION:-}' BUTTON='${BUTTON:-}' env=$(env | cut -d= -f1 | tr '\n' ' ')"
	exit 0
fi

case $arg in
on | ON | 1 | true | german) mode=german ;;
off | OFF | 0 | false | direct) mode=direct ;;
*)
	logger -t tsem-hook "ignored unknown switch argument '$arg'"
	exit 0
	;;
esac
# Remember what the firmware reported. Software cannot read the physical position unless a reader is configured
# (TSEM_HW_GPIO_VALUE / TSEM_HW_STATE_FILE), so two records are kept:
#  - hw_event  (tmpfs): the position reported since this boot  -> `tsem status` hw_source=event
#  - hw_last   (flash, rewritten only when the position changes): survives a reboot -> hw_source=persisted
#    (a position from before the boot may be outdated: the switch can move while the router is off)
case $mode in german) _hw=on ;; *) _hw=off ;; esac
_hwd=${TSEM_RUN_DIR:-/var/run/tsem}
_now=$(date +%s)
mkdir -p "$_hwd" 2>/dev/null && printf '%s %s\n' "$_now" "$_hw" >"$_hwd/hw_event.new" 2>/dev/null && mv -f "$_hwd/hw_event.new" "$_hwd/hw_event" 2>/dev/null
_hwl=${TSEM_STATE_DIR:-/etc/tsem}/hw_last
_boot=${TSEM_BOOT_ID:-$(tr -d '-' </proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-12)}
# The firmware replays the switch position at every boot. Same position as before the reboot and the first event of this
# boot = a replay, not a user action (the switch cannot move without a new position; one flipped while the router was off
# differs and is always applied).
_replay=0
if [ -r "$_hwl" ] && [ -n "$_boot" ] && [ "$(awk '{ print $2 }' "$_hwl" 2>/dev/null)" = "$_hw" ] && [ "$(awk '{ print $3 }' "$_hwl" 2>/dev/null)" != "$_boot" ]; then _replay=1; fi
if [ "$(awk '{ print $2 }' "$_hwl" 2>/dev/null)" != "$_hw" ] || [ "$(awk '{ print $3 }' "$_hwl" 2>/dev/null)" != "${_boot:-unknown}" ]; then
	printf '%s %s %s\n' "$_now" "$_hw" "${_boot:-unknown}" >"$_hwl.new" 2>/dev/null && mv -f "$_hwl.new" "$_hwl" 2>/dev/null
fi
# Policy (tsem config set TSEM_HW_AT_BOOT=last|switch, GUI: "Hardware switch at boot"):
#   last    (default) a replay of an unchanged position keeps the stored mode: a reboot never drops the protection by itself
#   switch  the switch position always wins, also right after a boot
if [ "$_replay" = 1 ] && [ "$("$TSEM_BIN" hw-policy 2>/dev/null)" != switch ]; then
	logger -t tsem-hook "boot: switch position '$_hw' unchanged since before the reboot: stored mode kept (policy last)"
	exit 0
fi
# Synchronous on purpose: events must reach the controller IN ORDER ("last user action wins").
# --no-wait only records the intent and applies the immediate guard (no probing), so this takes
# well under a second; the daemon does the slow part. A timeout keeps a hung controller from
# blocking the firmware's handler forever.
if timeout 1 true >/dev/null 2>&1; then
	timeout 30 "$TSEM_BIN" set "$mode" --source hw --no-wait >/dev/null 2>&1
else
	"$TSEM_BIN" set "$mode" --source hw --no-wait >/dev/null 2>&1
fi
exit 0
