'use strict';
'require view';
'require dom';
'require rpc';
'require poll';
'require ui';
'require tsem.logic as TL';

/*
 * TSEM - Tailscale Exit Manager: router GUI (LuCI).
 *
 * The page only talks to the local API (ubus object "tsem", authenticated by the LuCI session
 * and the rpcd ACL). It never invents a success: every statement is derived from the status the
 * controller reports, and DESIRED (what was requested) and REACHED (what the controller
 * has actually verified) are always shown separately.
 */

var callStatus = rpc.declare({ object: 'tsem', method: 'status', expect: { '': {} } });
var callConfig = rpc.declare({ object: 'tsem', method: 'config_get', expect: { '': {} } });
var callNodes = rpc.declare({ object: 'tsem', method: 'nodes', expect: { '': {} } });
var callEvents = rpc.declare({ object: 'tsem', method: 'events', expect: { '': {} } });
var callDiag = rpc.declare({ object: 'tsem', method: 'diag', expect: { '': {} } });
var callSetMode = rpc.declare({ object: 'tsem', method: 'set_mode', params: [ 'mode', 'source', 'confirm' ], expect: { '': {} } });
var callSetFailover = rpc.declare({ object: 'tsem', method: 'set_failover', params: [ 'mode', 'source' ], expect: { '': {} } });
var callFailoverNow = rpc.declare({ object: 'tsem', method: 'failover_now', expect: { '': {} } });
var callConfigSet = rpc.declare({ object: 'tsem', method: 'config_set',
	params: [ 'primary', 'primary_name', 'secondary', 'secondary_name', 'auto_return' ], expect: { '': {} } });

var TEXTS = TL.TEXTS, lang = TL.lang, T = TL.T, Logic = TL.Logic;

function row(label, value, cls) {
	return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'style': 'width:38%' }, label), E('td', { 'class': 'td left ' + (cls || '') }, value) ]);
}

return view.extend({
	logic: Logic,
	texts: TEXTS,

	load: function() {
		return Promise.all([
			callStatus().catch(function() { return null; }),
			callConfig().catch(function() { return null; }),
			callNodes().catch(function() { return null; }),
			callEvents().catch(function() { return null; })
		]);
	},

	render: function(data) {
		var self = this, l = lang();
		self.l = l;
		self.data = { status: data[0] && data[0].status, config: data[1] && data[1].config, nodes: data[2] && data[2].result, events: data[3] && data[3].events };
		self.root = E('div', { 'class': 'cbi-map', 'id': 'tsem-root' });
		self.result = E('div', { 'class': 'alert-message', 'id': 'tsem-result', 'style': 'display:none' });
		self.paint();
		poll.add(function() {
			return Promise.all([ callStatus().catch(function() { return null; }), callEvents().catch(function() { return null; }) ]).then(function(r) {
				self.data.status = r[0] && r[0].status;
				if (r[1]) self.data.events = r[1].events;
				self.paintStatus();
			});
		}, 5);
		return self.root;
	},

	say: function(text, bad) {
		var r = this.result;
		r.style.display = '';
		r.className = bad ? 'alert-message error' : 'alert-message info';
		dom.content(r, text);
	},

	/* act: run a change, show the reply, then keep refreshing until the status settles (max ~40 s) */
	act: function(promise) {
		var self = this;
		return promise.then(function(reply) {
			self.say(Logic.resultText(reply, self.l), reply.ok === false);
			if (reply.status) self.data.status = reply.status;
			self.paintStatus();
			var tries = 0;
			(function again() {
				if (tries++ >= 8) return;
				callStatus().then(function(r) {
					self.data.status = r.status;
					self.paintStatus();
					var d = Logic.describe(r.status, self.l);
					if (!d.reachedOk && d.tone === 'info') setTimeout(again, 5000);
				}).catch(function() {});
			})();
		}).catch(function(e) {
			self.say(T('error', self.l) + ': ' + (e && e.message ? e.message : e), true);
		});
	},

	paintStatus: function() {
		var self = this, l = self.l, st = self.data.status, d = Logic.describe(st, l);
		var tone = { ok: 'success', warn: 'warning', bad: 'error', info: 'info' }[d.tone] || 'info';
		var kids = [];
		kids.push(E('div', { 'class': 'alert-message ' + tone, 'id': 'tsem-headline' }, [ E('strong', {}, d.headline) ]));
		d.alerts.forEach(function(a) { kids.push(E('div', { 'class': 'alert-message error' }, a)); });
		if (st && st.state) {
			var rows = [
				row(T('desired', l), T('mode.' + (st.mode || 'none'), l)),
				row(T('reached', l), d.reachedOk ? 'yes: ' + st.state : 'no (' + st.state + ')'),
				row(T('active_exit', l), (st.active_exit && st.active_exit !== 'none') ? ((st.active_exit_name && st.active_exit_name !== 'none') ? st.active_exit_name + ' (' + st.active_exit + ')' : st.active_exit) : T('none', l)),
				row(T('primary', l), (st.primary || '-') + ' - ' + Logic.probeText(st.primary_probe, l)),
				row(T('secondary', l), (st.secondary && st.secondary !== 'none') ? st.secondary + ' - ' + Logic.probeText(st.secondary_probe, l) : T('none', l)),
			].concat((st.node_list || []).filter(function(n) { return n.rank > 2; }).map(function(n) {
				return row(T('fallback', l) + ' ' + (n.rank - 2), n.ip + (n.name ? ' (' + n.name + ')' : '') + ' - ' + Logic.probeText(n.probe, l));
			}), [
				row(T('kill_switch', l), st.kill_switch_active ? T('on', l) : T('off', l)),
				row(T('ipv6', l), T('v6.' + (st.ipv6_protection || 'unverified'), l)),
				row(T('dns', l), T('dns.' + (st.dns_protection || 'unverified'), l) + (st.dns && st.dns !== 'skip' ? ' (probe: ' + st.dns + ')' : '')),
				row(T('failover_policy', l), st.failover),
				row(T('auto_return', l), st.auto_return ? T('on', l) : T('off', l)),
				row(T('return_wait', l), Logic.returnWaitText(st, l)),
				row(T('hw', l), Logic.hwText(st, l)),
				row(T('last_action', l), Logic.lastAction(st, l))
			]);
			if (st.boot_failed === 'yes') rows.push(row(T('boot_failed', l), 'yes', 'cbi-value-error'));
			if (st.error) rows.push(row(T('error_label', l), st.error, 'cbi-value-error'));
			kids.push(E('table', { 'class': 'table', 'id': 'tsem-status' }, rows));
		}
		if (!self.status) self.status = E('div', { 'id': 'tsem-statusbox' });
		dom.content(self.status, kids);
		if (self.eventsBox) dom.content(self.eventsBox, (self.data.events || []).join('\n'));
	},

	paint: function() {
		var self = this, l = self.l, cfg = self.data.config || {};
		var nodes = (self.data.nodes && self.data.nodes.nodes) || [];
		self.status = null;
		self.paintStatus();

		var opts = Logic.nodeOptions(nodes, cfg);
		function picker(id, cur, allowNone) {
			var s = E('select', { 'class': 'cbi-input-select', 'id': id });
			if (allowNone) s.appendChild(E('option', { value: '' }, '- ' + T('none', l) + ' -'));
			opts.forEach(function(o) { s.appendChild(E('option', { value: o.ip, selected: o.ip === cur ? 'selected' : null }, o.name + ' (' + o.ip + ')')); });
			return s;
		}
		var pSel = picker('tsem-primary', cfg.primary, false), sSel = picker('tsem-secondary', cfg.secondary, true);
		var arBox = E('input', { type: 'checkbox', id: 'tsem-autoreturn', checked: cfg.auto_return ? 'checked' : null });
		var foBox = E('input', { type: 'checkbox', id: 'tsem-failover', checked: cfg.failover === 'off' ? null : 'checked' });
		function nameOf(ip) { var n = opts.filter(function(o) { return o.ip === ip; })[0]; return n && n.name !== ip ? n.name : ''; }

		var btnGerman = E('button', { 'class': 'btn cbi-button cbi-button-action', id: 'tsem-btn-german', click: function() {
			return self.act(callSetMode('german', 'gui', false)); } }, T('to_german', l));
		var btnDirect = E('button', { 'class': 'btn cbi-button cbi-button-negative', id: 'tsem-btn-direct', click: function() {
			if (!window.confirm(T('confirm_direct', l))) return;
			return self.act(callSetMode('direct', 'gui', true)); } }, T('to_direct', l));
		var btnBlocked = E('button', { 'class': 'btn cbi-button', id: 'tsem-btn-blocked', click: function() {
			return self.act(callSetMode('blocked', 'gui', false)); } }, T('to_blocked', l));
		var btnNow = E('button', { 'class': 'btn cbi-button', id: 'tsem-btn-failnow', click: function() { return self.act(callFailoverNow()); } }, T('failover_now', l));
		var btnSave = E('button', { 'class': 'btn cbi-button cbi-button-save', id: 'tsem-btn-save', click: function() {
			var p = pSel.value, s = sSel.value;
			return self.act(callConfigSet(p, nameOf(p), s, nameOf(s), arBox.checked).then(function(r) {
				if (r.ok === false) return r;
				return callSetFailover(foBox.checked ? 'auto' : 'off', 'gui').then(function(r2) { return r2.ok === false ? r2 : r; });
			}));
		} }, T('save', l));

		self.eventsBox = E('pre', { id: 'tsem-events', style: 'max-height:14em;overflow:auto' }, (self.data.events || []).join('\n'));
		var diagBox = E('pre', { id: 'tsem-diag', style: 'max-height:20em;overflow:auto' });
		var btnDiag = E('button', { 'class': 'btn cbi-button', id: 'tsem-btn-diag', click: function() {
			return callDiag().then(function(r) { dom.content(diagBox, (r.diag || []).join('\n')); }).catch(function(e) { dom.content(diagBox, String(e)); }); } }, T('load_diag', l));

		dom.content(self.root, [
			E('h2', {}, T('title', l)),
			self.result,
			self.status,
			E('h3', {}, T('change_mode', l)),
			E('div', { 'class': 'cbi-page-actions', style: 'text-align:left' }, [ btnGerman, ' ', btnDirect, ' ', btnBlocked, ' ', btnNow ]),
			E('h3', {}, T('exit_nodes', l)),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, T('primary', l)), E('div', { 'class': 'cbi-value-field' }, pSel) ]),
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, T('secondary', l)), E('div', { 'class': 'cbi-value-field' }, sSel) ]),
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, T('failover_policy', l)), E('div', { 'class': 'cbi-value-field' }, foBox) ]),
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, T('auto_return', l)), E('div', { 'class': 'cbi-value-field' }, arBox) ]),
				btnSave
			]),
			E('h3', {}, T('params', l)),
			E('table', { 'class': 'table', 'id': 'tsem-params' }, Logic.paramRows(cfg, l).map(function(r) { return row(r[0], r[1]); })),
			E('h3', {}, T('events', l)), self.eventsBox,
			E('h3', {}, T('diag', l)), btnDiag, diagBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
