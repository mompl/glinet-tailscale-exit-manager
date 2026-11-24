'use strict';

/*
 * TSEM UI logic shared by the LuCI view and the native GL.iNet view (single place that turns the controller's
 * status into statements; no DOM, no RPC). tools/build-native-view.js embeds this file into the native bundle.
 */

var TEXTS = {
	en: {
		title: 'Tailscale Exit Manager', desired: 'Desired mode', reached: 'Actually reached', controller: 'Controller state',
		unreachable: 'The controller cannot be reached (API error). Nothing below is current.',
		'mode.german': '{mode}', 'mode.direct': 'DIRECT', 'mode.none': 'none (BLOCKED)', 'mode.blocked': 'BLOCKED',
		'r.german_ok': '{mode} is active via the primary exit node.',
		'r.german_secondary': '{mode} is active via the SECONDARY exit node (failover).',
		'r.german_degraded': '{mode} is held, but the current exit node fails its checks. The kill switch keeps traffic from leaking.',
		'r.connecting': 'Not reached yet: the controller is still verifying the exit node. Traffic is blocked until it is proven.',
		'r.blocked': 'NOT reached: BLOCKED (fail-closed). No usable exit node; LAN traffic to the Internet is blocked on purpose.',
		'r.direct_ok': 'DIRECT is active: the kill switch is OFF, traffic leaves directly.',
		'r.direct_not': 'DIRECT was requested but is NOT confirmed (guard is not open).',
		'r.error': 'The controller reports an error.', 'r.intent': 'The saved mode is missing or invalid: the controller stays BLOCKED (never DIRECT).',
		'r.leak': 'LEAK RISK: the protection is not fully installed. Check the diagnostics.',
		'r.inconsistent': 'The firewall guard is in an inconsistent state.',
		'r.node_mismatch': 'Tailscale reports a different exit node than the controller expects',
		active_exit: 'Active exit node', none: 'none', primary: 'Primary', secondary: 'Secondary',
		'p.egress': 'Internet through this node works (verified)', 'p.egress-fail': 'node answers, but no Internet through it',
		'p.reach': 'reachable (ping only, Internet not tested)', 'p.unreachable': 'not reachable', 'p.rejected': 'rejected (not approved or wrong identity)',
		'p.pending': 'being applied', 'p.unknown': 'no data yet',
		protection: 'Protection', kill_switch: 'Kill switch', on: 'on', off: 'off', ipv6: 'IPv6 protection', dns: 'DNS protection',
		'v6.guarded': 'active (checked)', 'v6.off': 'off (DIRECT)', 'v6.unverified': 'NOT verified',
		'dns.none': 'no DNS redirect configured', 'dns.redirect': 'LAN DNS is redirected', 'dns.off': 'off (DIRECT)', 'dns.unverified': 'NOT verified',
		failover: 'Failover', failover_policy: 'Automatic failover', auto_return: 'Return to primary automatically',
		hw: 'Hardware switch', hw_on: 'ON ({mode})', hw_off: 'OFF (DIRECT)', hw_unknown: 'unknown (no switch state available)',
		hw_event: 'last reported by the firmware', hw_gpio: 'read from the switch (GPIO)', hw_file: 'read from the state file', hw_persisted: 'last known before the reboot, may be outdated', return_wait: 'Return to primary', rw_none: 'nothing to wait for', rw_disabled: 'off: the secondary stays until it fails', rw_not_usable: 'waiting: the primary does not answer right now', rw_counting: 'waiting (hysteresis)', hw_match_yes: 'matches the mode', hw_match_no: 'DIFFERS from the mode', hw_match_unknown: 'cannot be compared',
		last_action: 'Last mode change', by: 'by',
		change_mode: 'Change mode', to_german: 'Switch to {mode}', to_direct: 'Switch to DIRECT', to_blocked: 'Block all traffic (BLOCKED)',
		confirm_direct: 'DIRECT switches the kill switch off: all traffic leaves without the exit node. Really switch to DIRECT?',
		failover_now: 'Fail over now', save: 'Save', exit_nodes: 'Exit nodes', manual_ip: 'IP', online: 'online', offline: 'offline',
		no_exit_option: 'does not offer exit-node', events: 'Event log', diag: 'Diagnostics', load_diag: 'Load diagnostics', params: 'Parameters (read-only)', allow_subnets: 'Allowed internal subnets', p_interval: 'Check interval (s)', p_fail: 'Failures before failover', p_up: 'Successes before an exit node counts as up', p_return: 'Successes before return to primary', p_dwell: 'Minimum dwell time (s)', p_backoff: 'Backoff (s)', p_timeout: 'Probe timeout (s)', download: 'Download report',
		requested: 'Requested', result_reached: 'Result', refused: 'Refused', saved: 'Saved', error: 'Error',
		still_waiting: 'The controller is still working on it; the status above shows what has really been reached.',
		conn_lost: 'Connection to the router interrupted, trying again', nets_max: 'At most 8 networks can be allowed.',
		'st.DISABLED': 'DIRECT (no protection active)', 'st.PRIMARY_ACTIVE': 'primary exit node active', 'st.SECONDARY_ACTIVE': 'backup exit node active',
		'st.DEGRADED': 'exit node unstable', 'st.CONNECTING_PRIMARY': 'connecting to the primary node', 'st.CONNECTING_SECONDARY': 'connecting to the backup node',
		'st.BLOCKED': 'blocked (BLOCKED)', 'st.ERROR': 'error',
		yes: 'yes', no: 'no',
		hw_at_boot: 'Hardware switch at boot', hw_boot_last: 'Keep the last mode (only a moved switch counts)', hw_boot_switch: 'Switch position always wins', hw_boot_hint: 'After every reboot the firmware reports the switch position again. "Keep the last mode": a reboot never drops the protection by itself; a switch that was moved while the router was off is applied. "Switch position always wins": the position decides after every reboot, even if it contradicts the mode you set here (then a reboot can end in DIRECT).',
		egress_title: 'Public address', egress_btn: 'Check now', egress_busy: 'Asking myip.wtf ...', egress_hint: 'Asks myip.wtf which address the Internet sees for this router. Only after a mode change and when you press the button. Through an exit node this is the exit node\'s address; in DIRECT mode it is your own.', egress_fail: 'No answer (BLOCKED, no Internet path, or the service is unreachable).', egress_ip: 'Address', egress_loc: 'Location', egress_isp: 'Provider', egress_host: 'Host name', egress_tor: 'Tor exit node', egress_when: 'Checked', egress_stale: 'The mode or exit node has changed since this check: press "Check now" again.',
		reached_hint: 'Desired = what you chose. Reached = what the router has proven it is doing right now. They can differ for a moment.',
		test_failover: 'Test: switch to the backup node', test_failover_hint: 'Moves traffic to the backup exit node right now, to test what happens when the primary fails. With automatic return on, it goes back to the primary once that is healthy again. Only available while the exit-node mode is on.',
		nets_legend: 'Tap a network: green = stays reachable even when no exit node works, red = blocked. Then press Save.', nets_on: 'reachable', nets_off: 'blocked',
		nets_none: 'No networks are advertised by your tailnet right now.', nets_locked: 'Too large to release safely (only /16 or smaller)', nets_gone: '(no longer advertised)',
		settings: 'Settings', path_title: 'Traffic path', path_clients: 'Your devices', path_router: 'Router', path_internet: 'Internet', path_direct: 'direct', timeline: 'Recent events', timeline_none: 'Nothing to report yet.', label_mode: 'Name of the exit-node mode', subnets_edit: 'Networks reachable while BLOCKED', subnets_hint: 'Space separated, e.g. the LANs behind your exit nodes (each /16 or smaller, at most 8). Only these stay reachable when no exit node works. Leave empty for none.', 'tile.current': 'active', 'tile.pending': 'waiting', 'tile.german': 'All traffic through your exit node', 'tile.direct': 'Normal internet, no protection', 'tile.blocked': 'Nothing gets out', last_check: 'Last check', error_label: 'Last error', boot_failed: 'Protection missing at boot'
	},
	de: {
		title: 'Tailscale Exit Manager', desired: 'Gewünschter Modus', reached: 'Tatsächlich erreicht', controller: 'Controller-Zustand',
		unreachable: 'Der Controller ist nicht erreichbar (API-Fehler). Nichts unten ist aktuell.',
		'mode.german': '{mode}', 'mode.direct': 'DIRECT', 'mode.none': 'keiner (BLOCKED)', 'mode.blocked': 'BLOCKED',
		'r.german_ok': '{mode} ist aktiv über den primären Exit-Node.',
		'r.german_secondary': '{mode} ist aktiv über den SEKUNDÄREN Exit-Node (Failover).',
		'r.german_degraded': '{mode} wird gehalten, aber der aktuelle Exit-Node besteht seine Prüfungen nicht. Der Kill-Switch verhindert Leaks.',
		'r.connecting': 'Noch nicht erreicht: der Controller prüft den Exit-Node. Bis zum Nachweis ist der Verkehr gesperrt.',
		'r.blocked': 'NICHT erreicht: BLOCKED (fail-closed). Kein nutzbarer Exit-Node; Internetverkehr der LAN-Clients ist absichtlich gesperrt.',
		'r.direct_ok': 'DIRECT ist aktiv: Kill-Switch AUS, Verkehr geht direkt hinaus.',
		'r.direct_not': 'DIRECT wurde angefordert, ist aber NICHT bestätigt (Guard nicht offen).',
		'r.error': 'Der Controller meldet einen Fehler.', 'r.intent': 'Der gespeicherte Modus fehlt oder ist ungültig: der Controller bleibt BLOCKED (nie DIRECT).',
		'r.leak': 'LEAK-RISIKO: der Schutz ist nicht vollständig installiert. Diagnose prüfen.',
		'r.inconsistent': 'Der Firewall-Guard ist in einem inkonsistenten Zustand.',
		'r.node_mismatch': 'Tailscale meldet einen anderen Exit-Node als der Controller erwartet',
		active_exit: 'Aktiver Exit-Node', none: 'keiner', primary: 'Primär', secondary: 'Sekundär',
		'p.egress': 'Internet über diesen Node funktioniert (nachgewiesen)', 'p.egress-fail': 'Node antwortet, aber kein Internet darüber',
		'p.reach': 'erreichbar (nur Ping, Internet nicht getestet)', 'p.unreachable': 'nicht erreichbar', 'p.rejected': 'abgelehnt (nicht freigegeben oder falsche Identität)',
		'p.pending': 'wird gerade gesetzt', 'p.unknown': 'noch keine Daten',
		protection: 'Schutz', kill_switch: 'Kill-Switch', on: 'an', off: 'aus', ipv6: 'IPv6-Schutz', dns: 'DNS-Schutz',
		'v6.guarded': 'aktiv (geprüft)', 'v6.off': 'aus (DIRECT)', 'v6.unverified': 'NICHT verifiziert',
		'dns.none': 'keine DNS-Umleitung konfiguriert', 'dns.redirect': 'LAN-DNS wird umgeleitet', 'dns.off': 'aus (DIRECT)', 'dns.unverified': 'NICHT verifiziert',
		failover: 'Failover', failover_policy: 'Automatischer Failover', auto_return: 'Automatisch zum Primary zurückkehren',
		hw: 'Hardware-Schalter', hw_on: 'AN ({mode})', hw_off: 'AUS (DIRECT)', hw_unknown: 'unbekannt (kein Schalterstatus verfügbar)',
		hw_event: 'zuletzt von der Firmware gemeldet', hw_gpio: 'direkt am Schalter gelesen (GPIO)', hw_file: 'aus der Statusdatei gelesen', hw_persisted: 'zuletzt vor dem Neustart bekannt, evtl. veraltet', return_wait: 'Rückkehr zum Primary', rw_none: 'nichts abzuwarten', rw_disabled: 'aus: der Secondary bleibt, bis er ausfällt', rw_not_usable: 'wartet: der Primary antwortet gerade nicht', rw_counting: 'wartet (Hysterese)', hw_match_yes: 'passt zum Modus', hw_match_no: 'WEICHT vom Modus ab', hw_match_unknown: 'nicht vergleichbar',
		last_action: 'Letzte Moduländerung', by: 'durch',
		change_mode: 'Modus ändern', to_german: 'Auf {mode} schalten', to_direct: 'Auf DIRECT schalten', to_blocked: 'Gesamten Verkehr sperren (BLOCKED)',
		confirm_direct: 'DIRECT schaltet den Kill-Switch aus: aller Verkehr geht ohne Exit-Node hinaus. Wirklich auf DIRECT schalten?',
		failover_now: 'Jetzt Failover', save: 'Speichern', exit_nodes: 'Exit-Nodes', manual_ip: 'IP', online: 'online', offline: 'offline',
		no_exit_option: 'bietet keinen Exit-Node an', events: 'Ereignisprotokoll', diag: 'Diagnose', load_diag: 'Diagnose laden', params: 'Parameter (nur lesend)', allow_subnets: 'Erlaubte interne Subnetze', p_interval: 'Prüfintervall (s)', p_fail: 'Fehlversuche vor Failover', p_up: 'Erfolge bis ein Exit-Node als aktiv gilt', p_return: 'Erfolge bis zur Rückkehr zum Primary', p_dwell: 'Mindestverweildauer (s)', p_backoff: 'Backoff (s)', p_timeout: 'Probe-Timeout (s)', download: 'Bericht herunterladen',
		requested: 'Angefordert', result_reached: 'Ergebnis', refused: 'Abgelehnt', saved: 'Gespeichert', error: 'Fehler',
		still_waiting: 'Der Controller arbeitet noch daran; der Status oben zeigt, was wirklich erreicht ist.',
		conn_lost: 'Verbindung zum Router unterbrochen, versuche es erneut', nets_max: 'Es können höchstens 8 Netze freigegeben werden.',
		'st.DISABLED': 'DIRECT (kein Schutz aktiv)', 'st.PRIMARY_ACTIVE': 'Primär-Exit-Node aktiv', 'st.SECONDARY_ACTIVE': 'Backup-Exit-Node aktiv',
		'st.DEGRADED': 'Exit-Node instabil', 'st.CONNECTING_PRIMARY': 'verbinde mit dem Primär-Node', 'st.CONNECTING_SECONDARY': 'verbinde mit dem Backup-Node',
		'st.BLOCKED': 'gesperrt (BLOCKED)', 'st.ERROR': 'Fehler',
		yes: 'ja', no: 'nein',
		hw_at_boot: 'Hardware-Schalter beim Neustart', hw_boot_last: 'Letzten Modus behalten (nur ein bewegter Schalter zählt)', hw_boot_switch: 'Schalterstellung gewinnt immer', hw_boot_hint: 'Die Firmware meldet nach jedem Neustart die Schalterstellung erneut. "Letzten Modus behalten": ein Neustart hebt den Schutz nie von selbst auf; ein Schalter, der bei ausgeschaltetem Router bewegt wurde, wird umgesetzt. "Schalterstellung gewinnt immer": die Stellung entscheidet nach jedem Neustart, auch wenn sie dem hier gewählten Modus widerspricht (dann kann ein Neustart in DIRECT enden).',
		egress_title: 'Öffentliche Adresse', egress_btn: 'Jetzt prüfen', egress_busy: 'Frage myip.wtf ...', egress_hint: 'Fragt myip.wtf, mit welcher Adresse das Internet diesen Router sieht. Nur nach einem Moduswechsel und wenn du den Knopf drückst. Über einen Exit-Node ist das die Adresse des Exit-Nodes, im DIRECT-Modus deine eigene.', egress_fail: 'Keine Antwort (BLOCKED, kein Internetweg oder der Dienst ist nicht erreichbar).', egress_ip: 'Adresse', egress_loc: 'Standort', egress_isp: 'Anbieter', egress_host: 'Hostname', egress_tor: 'Tor-Exit-Node', egress_when: 'Geprüft', egress_stale: 'Der Modus oder Exit-Node hat sich seit dieser Prüfung geändert: bitte "Jetzt prüfen" erneut drücken.',
		reached_hint: 'Gewünscht = was du eingestellt hast. Erreicht = was der Router gerade nachweislich tut. Beides kann kurz auseinanderliegen.',
		test_failover: 'Test: auf den Backup-Node wechseln', test_failover_hint: 'Schaltet den Verkehr sofort auf den Backup-Exit-Node, um den Ausfall des Primär-Nodes zu testen. Mit automatischer Rückkehr geht es zurück, sobald der Primär-Node wieder gesund ist. Nur verfügbar, solange der Exit-Node-Modus an ist.',
		nets_legend: 'Netz antippen: grün = bleibt erreichbar, auch wenn kein Exit-Node funktioniert, rot = gesperrt. Danach Speichern drücken.', nets_on: 'erreichbar', nets_off: 'gesperrt',
		nets_none: 'Dein Tailnet bewirbt gerade keine Netze.', nets_locked: 'Zu groß für eine sichere Freigabe (nur /16 oder kleiner)', nets_gone: '(wird nicht mehr beworben)',
		settings: 'Einstellungen', path_title: 'Verkehrsweg', path_clients: 'Deine Geräte', path_router: 'Router', path_internet: 'Internet', path_direct: 'direkt', timeline: 'Letzte Ereignisse', timeline_none: 'Noch nichts zu melden.', label_mode: 'Name des Exit-Node-Modus', subnets_edit: 'Netze erreichbar bei BLOCKED', subnets_hint: 'Durch Leerzeichen getrennt, z. B. die LANs hinter deinen Exit-Nodes (je /16 oder kleiner, höchstens 8). Nur diese bleiben erreichbar, wenn kein Exit-Node funktioniert. Leer = keine.', 'tile.current': 'aktiv', 'tile.pending': 'wartet', 'tile.german': 'Aller Verkehr über deinen Exit-Node', 'tile.direct': 'Normales Internet, kein Schutz', 'tile.blocked': 'Nichts geht hinaus', last_check: 'Letzte Prüfung', error_label: 'Letzter Fehler', boot_failed: 'Schutz beim Booten nicht installiert'
	}
};

function lang() {
	var l = (typeof document !== 'undefined' && document.documentElement && document.documentElement.lang) ||
		(typeof navigator !== 'undefined' && navigator.language) || 'en';
	return /^de/i.test(l) ? 'de' : 'en';
}

var MODE_LABEL = 'EXIT';
function T(key, l) { var d = TEXTS[l || lang()]; var s = (d && d[key] != null) ? d[key] : (TEXTS.en[key] != null ? TEXTS.en[key] : key); return String(s).replace(/{mode}/g, MODE_LABEL); }

/*
 * describe(status): the single place that turns the controller's status into statements.
 * tone: ok | warn | bad | info.  Returns { headline, tone, alerts[] }.
 */
var Logic = {
	describe: function(st, l) {
		if (st && typeof st.mode_label === 'string' && /^[A-Za-z0-9 _-]{1,20}$/.test(st.mode_label)) MODE_LABEL = st.mode_label;
		var out = { headline: '', tone: 'bad', alerts: [], reachedOk: false };
		if (!st || typeof st !== 'object' || !st.state) {
			out.headline = T('unreachable', l);
			return out;
		}
		if (st.leak_risk === true) out.alerts.push(T('r.leak', l));
		if (st.guard === 'inconsistent') out.alerts.push(T('r.inconsistent', l));
		if (st.intent && st.intent !== 'ok') out.alerts.push(T('r.intent', l));
		if (st.error) out.alerts.push(T('r.error', l) + ' ' + st.error);
		var s = st.state;
		if (st.mode === 'direct') {
			if (st.guard === 'open' && s === 'DISABLED') { out.headline = T('r.direct_ok', l); out.tone = 'warn'; out.reachedOk = true; }
			else { out.headline = T('r.direct_not', l); out.tone = 'bad'; }
		}
		else if (s === 'PRIMARY_ACTIVE') { out.headline = T('r.german_ok', l); out.tone = 'ok'; out.reachedOk = true; }
		else if (s === 'SECONDARY_ACTIVE') { out.headline = T('r.german_secondary', l); out.tone = 'warn'; out.reachedOk = true; }
		else if (s === 'DEGRADED') { out.headline = T('r.german_degraded', l); out.tone = 'warn'; }
		else if (s === 'CONNECTING_PRIMARY' || s === 'CONNECTING_SECONDARY') { out.headline = T('r.connecting', l); out.tone = 'info'; }
		else if (s === 'ERROR') { out.headline = T('r.error', l); out.tone = 'bad'; }
		else { out.headline = T('r.blocked', l); out.tone = 'warn'; }
		if (out.alerts.length && out.tone !== 'bad') out.tone = (st.leak_risk === true || st.guard === 'inconsistent') ? 'bad' : out.tone;
		var active = (s === 'PRIMARY_ACTIVE' || s === 'SECONDARY_ACTIVE' || s === 'DEGRADED');
		// "unavailable"/"unknown" = the controller could not read tailscale for a moment (e.g. while it reconnects): not a mismatch
		if (active && st.exit_node && st.exit_node !== 'unavailable' && st.exit_node !== 'unknown' && st.active_exit && st.exit_node !== st.active_exit)
			out.alerts.push(T('r.node_mismatch', l) + ': ' + st.exit_node + ' / ' + st.active_exit);
		return out;
	},

	probeText: function(kind, l) { return T('p.' + (kind || 'unknown'), l); },

	hwText: function(st, l) {
		var h = st.hw_state === 'on' ? T('hw_on', l) : st.hw_state === 'off' ? T('hw_off', l) : T('hw_unknown', l);
		var m = st.hw_match === 'yes' ? T('hw_match_yes', l) : st.hw_match === 'no' ? T('hw_match_no', l) : T('hw_match_unknown', l);
		var when = st.hw_event_ts ? ' ' + new Date(st.hw_event_ts * 1000).toISOString().replace('T', ' ').slice(0, 19) + ' UTC' : '';
		var src = st.hw_source === 'event' ? ' [' + T('hw_event', l) + when + ']'
			: st.hw_source === 'persisted' ? ' [' + T('hw_persisted', l) + when + ']'
			: st.hw_source === 'gpio' ? ' [' + T('hw_gpio', l) + ']'
			: st.hw_source === 'file' ? ' [' + T('hw_file', l) + ']' : '';
		return h + src + ' - ' + m;
	},

	/* F06: why a healthy primary is not selected again yet */
	returnWaitText: function(st, l) {
		var w = st.return_wait || 'none';
		if (w === 'none') return T('rw_none', l);
		if (w === 'disabled') return T('rw_disabled', l);
		if (w === 'primary_not_usable') return T('rw_not_usable', l);
		return T('rw_counting', l) + ': ' + w.replace(/,/g, ', ');
	},

	lastAction: function(st, l) {
		if (!st.seq || !st.last_change) return '-';
		var d = new Date(st.last_change * 1000);
		return (st.mode || '?').toUpperCase() + ' ' + T('by', l) + ' ' + (st.source || '?') + ', ' + d.toISOString().replace('T', ' ').slice(0, 19) + ' UTC (#' + st.seq + ')';
	},

	/* result line of a change: requested vs. what the status AFTER the change says */
	resultText: function(reply, l) {
		if (!reply) return T('error', l);
		var s = reply.status ? Logic.describe(reply.status, l) : null;
		if (reply.code === 'refused') return T('refused', l) + ': ' + reply.error;
		if (reply.ok === false) return T('error', l) + ': ' + (reply.error || reply.message || '?');
		var t = T('requested', l) + ': ' + (reply.requested || '?');
		if (s) t += ' - ' + T('result_reached', l) + ': ' + (s.reachedOk ? s.headline : s.headline + ' ' + T('still_waiting', l));
		return t;
	},

	/* read-only parameter rows [label, value] from config.params */
	paramRows: function(cfg, l) {
		var p = (cfg && cfg.params) || null;
		if (!p) return [];
		return [
			[ T('p_interval', l), p.interval + ' / ' + p.interval_recovery ],
			[ T('p_fail', l), String(p.fail_n) ], [ T('p_up', l), String(p.up_n) ], [ T('p_return', l), String(p.return_n) ],
			[ T('p_dwell', l), String(p.dwell) ], [ T('p_backoff', l), p.backoff_min + ' - ' + p.backoff_max ], [ T('p_timeout', l), String(p.probe_timeout) ],
			[ T('allow_subnets', l), p.allow_subnets4 || T('none', l) ]
		];
	},

	/* node option list for the pickers: only online exit-capable peers, plus the configured IPs themselves */
	nodeOptions: function(nodes, cfg) {
		var out = [], seen = {};
		(nodes || []).forEach(function(n) { if (n.exit_option && n.online) { out.push({ ip: n.ip, name: n.name }); seen[n.ip] = 1; } });
		[ [ cfg.primary, cfg.primary_name ], [ cfg.secondary, cfg.secondary_name ] ].forEach(function(c) {
			if (c[0] && !seen[c[0]]) { out.push({ ip: c[0], name: c[1] || c[0] }); seen[c[0]] = 1; }
		});
		return out;
	}
};

return { TEXTS: TEXTS, lang: lang, T: T, Logic: Logic };
