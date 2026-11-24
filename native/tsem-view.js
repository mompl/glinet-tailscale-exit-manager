/*
 * TSEM native GL.iNet view (source). tools/build-native-view.js turns this into
 * src/www/views/gl-sdk4-ui-tsem.common.js:  (function () { var L = <tsem/logic.js>; <this file> })()
 * so that  component = eval(bundle)  yields the component object (runtime-only Vue 2: render function, no template).
 *
 * The view contains NO business logic: statements come from L.Logic (shared with LuCI) and every change goes through
 * the one controller via the "tsem" RPC object. Nothing is shown as success before the controller's status says so.
 *
 * UNVERIFIED on real firmware (see docs/native-gui.md): the session id source and the /rpc call shape below follow
 * public community reports, not an official GL.iNet interface. If the session id cannot be found the view says so and
 * does nothing (it never falls back to another way of changing anything).
 */
var SID_COOKIE = 'Admin-Token';

function readSid(doc) {
	var m = String((doc && doc.cookie) || '').split(/;\s*/);
	for (var i = 0; i < m.length; i++) {
		var kv = m[i].split('=');
		if (kv[0] === SID_COOKIE && kv[1]) return decodeURIComponent(kv.slice(1).join('='));
	}
	return null;
}

/* env = { fetch, document }: injected so that the contract can be tested without a browser */
function makeTransport(env) {
	var n = 0;
	return function call(method, params) {
		var sid = readSid(env.document);
		if (!sid) return Promise.reject(new Error('no GL.iNet session found (log in again)'));
		n++;
		return env.fetch('/rpc', {
			method: 'POST',
			credentials: 'same-origin',
			headers: { 'Content-Type': 'application/json', 'glinet': '1' },
			body: JSON.stringify({ jsonrpc: '2.0', id: n, method: 'call', params: [ sid, 'tsem', 'call', { m: method, p: params || {} } ] })
		}).then(function(r) {
			if (!r.ok) throw new Error('HTTP ' + r.status);
			return r.json();
		}).then(function(j) {
			if (j && j.error) throw new Error(j.error.message || 'RPC error');
			var res = j && j.result;
			if (!res || typeof res !== 'object') throw new Error('empty reply');
			return res;
		});
	};
}

var T = L.T, Logic = L.Logic;
var CSS = [
	'.tsem{--fg:#1f2430;--mut:#6b7280;--card:#fff;--line:#e5e7eb;--soft:#f3f4f6;--ok:#16a34a;--warn:#d97706;--bad:#dc2626;--info:#2563eb;--acc:#2563eb;color:var(--fg);max-width:62em;padding:8px;box-sizing:border-box}',
	'@media (prefers-color-scheme:dark){.tsem{--fg:#e5e7eb;--mut:#9ca3af;--card:#1f2430;--line:#343b4d;--soft:#2a3042}}',
	'.tsem *{box-sizing:border-box}',
	'.tsem-hero{border-radius:16px;padding:16px 18px;margin:0 0 16px;color:#fff;box-shadow:0 4px 18px rgba(0,0,0,.15);background:linear-gradient(135deg,#475569,#334155)}',
	'.tsem-tone-ok{background:linear-gradient(135deg,#16a34a,#0f766e)}.tsem-tone-warn{background:linear-gradient(135deg,#f59e0b,#d97706)}',
	'.tsem-tone-bad{background:linear-gradient(135deg,#ef4444,#b91c1c)}.tsem-tone-info{background:linear-gradient(135deg,#3b82f6,#4f46e5)}',
	'.tsem-hero-top{display:flex;align-items:center;gap:16px}.tsem-hero-txt{min-width:0}',
	'.tsem-title{font-size:.8em;letter-spacing:.08em;text-transform:uppercase;opacity:.85}',
	'.tsem-headline{font-size:1.25em;font-weight:600;line-height:1.35;margin-top:2px;word-break:break-word}',
	'.tsem-pulse{flex:0 0 auto;width:56px;height:56px;border-radius:50%;background:rgba(255,255,255,.22);display:flex;align-items:center;justify-content:center;color:#fff}',
	'.tsem-anim{animation:tsem-p 1.4s ease-in-out infinite}@keyframes tsem-p{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(1.14);opacity:.6}}',
	'.tsem-hero-rows{margin-top:12px;padding-top:10px;border-top:1px solid rgba(255,255,255,.28)}',
	'.tsem-hero .tsem-k{color:rgba(255,255,255,.8)}.tsem-hero .tsem-v{color:#fff}',
	'.tsem-alert{display:flex;gap:10px;align-items:center;background:rgba(220,38,38,.12);border:1px solid rgba(220,38,38,.5);color:var(--bad);border-radius:12px;padding:10px 14px;margin:0 0 12px;font-weight:600}',
	/* fact tiles: one small coloured card per piece of information */
	'.tsem-facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(9.5em,1fr));gap:12px;margin:0 0 8px}',
	'.tsem-fact{--fc:#9ca3af;--fb:rgba(156,163,175,.18);display:flex;gap:10px;align-items:flex-start;background:var(--card);border:1px solid var(--line);border-left:4px solid var(--fc);border-radius:14px;padding:12px;box-shadow:0 1px 3px rgba(0,0,0,.06);min-width:0}',
	'.tsem-hero.tsem-fail{background-image:linear-gradient(135deg,rgba(255,255,255,.16) 25%,transparent 25%,transparent 50%,rgba(255,255,255,.16) 50%,rgba(255,255,255,.16) 75%,transparent 75%),linear-gradient(120deg,#16a34a 0%,#84cc16 55%,#eab308 100%);background-size:56px 56px,100% 100%;animation:tsem-in .5s ease both,tsem-stripes 2.2s linear infinite}',
	'@keyframes tsem-stripes{from{background-position:0 0,0 0}to{background-position:56px 0,0 0}}',
	'.tsem-f-lime{--fc:#84cc16;--fb:rgba(132,204,22,.2)}',
	'.tsem-card .tsem-msg{margin:14px 0 12px}.tsem-card .tsem-hint{margin-top:14px}',
	'.tsem-eg{display:grid;grid-template-columns:repeat(auto-fit,minmax(11em,1fr));gap:8px 16px;margin-top:8px}.tsem-eg-ip{font-size:1.35em;font-weight:700;letter-spacing:.02em}',
	'.tsem-f-ok{--fc:#16a34a;--fb:rgba(22,163,74,.16)}.tsem-f-warn{--fc:#f59e0b;--fb:rgba(245,158,11,.2)}.tsem-f-bad{--fc:#ef4444;--fb:rgba(239,68,68,.16)}.tsem-f-info{--fc:#3b82f6;--fb:rgba(59,130,246,.16)}.tsem-f-mute{--fc:#9ca3af;--fb:rgba(156,163,175,.2)}.tsem-f-pur{--fc:#8b5cf6;--fb:rgba(139,92,246,.16)}',
	'.tsem-fic{flex:0 0 auto;width:38px;height:38px;border-radius:11px;background:var(--fb);color:var(--fc);display:flex;align-items:center;justify-content:center}',
	'.tsem-fx{min-width:0}.tsem-fl{font-size:.72em;letter-spacing:.07em;text-transform:uppercase;color:var(--mut)}.tsem-fv{font-weight:700;line-height:1.3;word-break:break-word}.tsem-fs{font-size:.8em;color:var(--mut);word-break:break-word}',
	'.tsem-ic{display:block}.tsem-tic{display:inline-flex;width:34px;height:34px;border-radius:10px;align-items:center;justify-content:center;margin-bottom:4px}',
	'.tsem-t-german .tsem-tic{background:rgba(22,163,74,.16);color:#16a34a}.tsem-t-direct .tsem-tic{background:rgba(245,158,11,.2);color:#f59e0b}.tsem-t-blocked .tsem-tic{background:rgba(239,68,68,.16);color:#ef4444}',
	'.tsem-msg{margin:0 0 16px;padding:10px 14px;border-radius:10px;background:var(--soft);border-left:4px solid var(--info)}.tsem-msgbad{border-left-color:var(--bad)}',
	'.tsem-card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 18px;margin:0 0 16px;box-shadow:0 1px 3px rgba(0,0,0,.05)}',
	'.tsem-h{margin:0 0 10px;font-size:1em;font-weight:600}.tsem-sum{cursor:pointer;margin:0}',
	'.tsem-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(18em,1fr));gap:16px;margin:0 0 16px}.tsem-grid .tsem-card{margin:0}',
	'.tsem-row{display:flex;flex-wrap:wrap;align-items:center;gap:4px 12px;padding:5px 0}',
	'.tsem-k{flex:0 0 12em;color:var(--mut)}.tsem-v{flex:1 1 12em;min-width:0;word-break:break-word}.tsem-badtxt{color:var(--bad);font-weight:600}',
	'.tsem-tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(11em,1fr));gap:12px}',
	'.tsem-tile{position:relative;text-align:left;border:2px solid var(--line);background:var(--soft);color:var(--fg);border-radius:14px;padding:14px 16px;cursor:pointer;display:flex;flex-direction:column;gap:4px;font:inherit;transition:transform .12s,border-color .12s,box-shadow .12s}',
	'.tsem-tile:hover:not([disabled]){transform:translateY(-2px);box-shadow:0 6px 14px rgba(0,0,0,.12)}.tsem-tile[disabled]{opacity:.6;cursor:progress}',
	'.tsem-tt{font-size:1.1em;font-weight:700}.tsem-ts{font-size:.85em;color:var(--mut)}',
	'.tsem-on{background:var(--card);box-shadow:0 0 0 3px rgba(37,99,235,.15)}.tsem-t-german.tsem-on{border-color:var(--ok)}.tsem-t-direct.tsem-on{border-color:var(--warn)}.tsem-t-blocked.tsem-on{border-color:var(--bad)}',
	'.tsem-badge{position:absolute;top:10px;right:12px;font-size:.7em;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:#fff;background:var(--acc);border-radius:999px;padding:2px 8px}',
	'.tsem-t-german .tsem-badge{background:var(--ok)}.tsem-t-direct .tsem-badge{background:var(--warn)}.tsem-t-blocked .tsem-badge{background:var(--bad)}',
	'.tsem-pend{border-style:dashed;border-color:var(--warn)}.tsem-badge.tsem-bw{background:var(--warn)}',
	'.tsem-svg{width:100%;height:auto;display:block;color:var(--fg)}.tsem-ev{display:flex;align-items:baseline;gap:10px;padding:5px 0;border-bottom:1px solid var(--line)}.tsem-ev:last-child{border-bottom:0}.tsem-evt{flex:0 0 5.5em;color:var(--mut);font-family:monospace;font-size:.85em}.tsem-evm{min-width:0;word-break:break-word}',
	'.tsem-hint{color:var(--mut);font-size:.82em;padding:2px 0 6px}',
	'.tsem-actions{margin-top:12px;display:flex;flex-wrap:wrap;gap:8px}',
	'.tsem-btn{border:0;border-radius:10px;padding:9px 16px;font:inherit;font-weight:600;cursor:pointer;color:#fff;background:var(--acc)}.tsem-btn[disabled]{opacity:.55;cursor:progress}',
	'.tsem-ghost{background:var(--soft);color:var(--fg);border:1px solid var(--line)}.tsem-primary{background:var(--acc)}',
	'.tsem-node{padding:8px 0;border-bottom:1px solid var(--line)}.tsem-node:last-child{border-bottom:0}',
	'.tsem-node-h{display:flex;justify-content:space-between;gap:8px;margin-bottom:6px}.tsem-ip{color:var(--mut);font-family:monospace}',
	'.tsem-chips{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 8px}',
	'.tsem-chip{display:inline-flex;align-items:center;gap:7px;border-radius:999px;padding:4px 11px;font-size:.88em;background:var(--soft);border:1px solid var(--line)}',
	'.tsem-dot{width:9px;height:9px;border-radius:50%;background:var(--mut);display:inline-block}',
	'.tsem-c-ok .tsem-dot{background:var(--ok)}.tsem-c-warn .tsem-dot{background:var(--warn)}.tsem-c-bad .tsem-dot{background:var(--bad)}',
	'.tsem-select{min-width:14em;max-width:100%;padding:7px 10px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg);font:inherit}',
	'.tsem-switch{position:relative;display:inline-block;width:46px;height:26px}.tsem-switch input{opacity:0;width:100%;height:100%;position:absolute;margin:0;cursor:pointer;z-index:1}',
	'.tsem-slider{position:absolute;inset:0;background:#9ca3af;border-radius:26px;transition:background .15s}',
	'.tsem-slider:before{content:"";position:absolute;left:3px;top:3px;width:20px;height:20px;border-radius:50%;background:#fff;transition:transform .15s}',
	'.tsem-switch input:checked+.tsem-slider{background:var(--ok)}.tsem-switch input:checked+.tsem-slider:before{transform:translateX(20px)}',
	'.tsem-pre{max-height:20em;overflow:auto;background:var(--soft);border-radius:8px;padding:10px;font-size:.82em;white-space:pre-wrap;margin:10px 0 0}',
	/* hero hint, exit-node cards */
	'.tsem-hero-hint{margin-top:8px;font-size:.82em;opacity:.8}',
	'.tsem-node-role{font-size:.75em;letter-spacing:.08em;text-transform:uppercase;color:var(--mut)}.tsem-node-name{font-size:1.2em;font-weight:700;margin:2px 0}.tsem-node .tsem-ip{margin-bottom:6px;font-size:.85em}',
	/* networks reachable while BLOCKED: tap to toggle, green = reachable, red = blocked */
	'.tsem-sub{padding:10px 0 4px}.tsem-sub-h{font-weight:600;margin-bottom:2px}.tsem-nets{display:flex;flex-wrap:wrap;gap:10px;margin:8px 0 4px}',
	'.tsem-net{display:inline-flex;align-items:center;gap:8px;border:2px solid var(--line);background:var(--soft);color:var(--fg);border-radius:12px;padding:8px 12px;font:inherit;cursor:pointer;transition:transform .12s,border-color .2s,background .2s}',
	'.tsem-net:active{transform:scale(.96)}.tsem-net-c{font-family:monospace;font-weight:700}.tsem-net-s{font-size:.78em;font-weight:700;text-transform:uppercase;letter-spacing:.05em}.tsem-net-gone{font-size:.75em;color:var(--mut)}',
	'.tsem-net-on{border-color:var(--ok);background:rgba(22,163,74,.12)}.tsem-net-on .tsem-dot{background:var(--ok)}.tsem-net-on .tsem-net-s{color:var(--ok)}',
	'.tsem-net-off{border-color:var(--bad);background:rgba(220,38,38,.10)}.tsem-net-off .tsem-dot{background:var(--bad)}.tsem-net-off .tsem-net-s{color:var(--bad)}',
	'.tsem-net-lock{opacity:.55;cursor:not-allowed}',
	/* path graphic: wide layout on desktop, stacked layout on phones */
	'.tsem-svg-v{display:none;max-width:340px;margin:0 auto}',
	'@media (max-width:620px){.tsem-svg-h{display:none}.tsem-svg-v{display:block}}',
	/* motion */
	'.tsem-hero{background-size:220% 220%;animation:tsem-in .5s ease both,tsem-bg 14s ease-in-out infinite}',
	'@keyframes tsem-bg{0%,100%{background-position:0% 50%}50%{background-position:100% 50%}}',
	'@keyframes tsem-in{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}',
	'.tsem>.tsem-card,.tsem>.tsem-grid,.tsem>.tsem-msg{animation:tsem-in .5s ease both}',
	'.tsem>:nth-child(3){animation-delay:.05s}.tsem>:nth-child(4){animation-delay:.1s}.tsem>:nth-child(5){animation-delay:.15s}.tsem>:nth-child(6){animation-delay:.2s}.tsem>:nth-child(n+7){animation-delay:.25s}',
	'.tsem-pulse{position:relative}.tsem-pulse:after{content:"";position:absolute;inset:0;border-radius:50%;border:2px solid rgba(255,255,255,.7);animation:tsem-ring 2.4s ease-out infinite}',
	'.tsem-tone-bad .tsem-pulse:after,.tsem-tone-info .tsem-pulse:after{animation-duration:1.1s}',
	'@keyframes tsem-ring{0%{transform:scale(1);opacity:.8}100%{transform:scale(1.9);opacity:0}}',
	'.tsem-flow{stroke-dasharray:5 14;animation:tsem-dash 1.1s linear infinite}@keyframes tsem-dash{to{stroke-dashoffset:-19}}',
	'.tsem-glow{animation:tsem-glow 2.6s ease-in-out infinite}@keyframes tsem-glow{0%,100%{stroke-opacity:1}50%{stroke-opacity:.45}}',
	'.tsem-blink{animation:tsem-blink 1.1s steps(2,jump-none) infinite}@keyframes tsem-blink{50%{opacity:.25}}',
	'.tsem-c-ok .tsem-dot{animation:tsem-beat 2.2s ease-in-out infinite}@keyframes tsem-beat{0%,100%{box-shadow:0 0 0 0 rgba(22,163,74,.55)}50%{box-shadow:0 0 0 5px rgba(22,163,74,0)}}',
	'.tsem-tile:active:not([disabled]){transform:scale(.97)}.tsem-on .tsem-tt{animation:tsem-in .35s ease both}',
	'@media (prefers-reduced-motion:reduce){.tsem *,.tsem *:before,.tsem *:after{animation:none!important;transition:none!important}}'
].join('\n');


return {
	name: 'tsem',
	data: function() {
		return { l: L.lang(), status: null, config: {}, nodes: [], nets: [], events: [], diag: null, msg: '', msgBad: false, msgConn: false, busy: false, sel: { primary: '', secondary: '', failover: true, auto_return: true, mode_label: '', nets: [] }, egress: null, egressBusy: false, egressAuto: '', timer: null };
	},
	created: function() {
		var self = this;
		self.call = makeTransport({ fetch: (typeof window !== 'undefined' && window.fetch) ? window.fetch.bind(window) : null, document: typeof document !== 'undefined' ? document : null });
		self.loadAll();
		self.timer = setInterval(function() { self.refresh(); }, 5000);
	},
	beforeDestroy: function() { if (this.timer) clearInterval(this.timer); },
	methods: {
		/* one failed poll is retried at once (phones suspend pages and drop single requests); a connection message
		   disappears by itself as soon as a poll succeeds again */
		refresh: function(retried) {
			var self = this;
			return Promise.all([ self.call('status'), self.call('events') ]).then(function(r) {
				self.status = r[0].status; self.events = r[1].events || [];
				if (self.msgConn) { self.msg = ''; self.msgConn = false; }
				/* a change made elsewhere (hardware switch, Home Assistant): refresh the address card if it is in use */
				if (self.egress && !self.egressBusy && self.egress.key !== self.pathKey() && self.egressAuto !== self.pathKey() && Logic.describe(self.status, self.l).reachedOk) { self.egressAuto = self.pathKey(); self.checkEgress(); }
			}).catch(function(e) {
				if (!retried) return self.refresh(true);
				self.status = null; self.say(T('conn_lost', self.l) + ' (' + e.message + ')', true); self.msgConn = true;
			});
		},
		say: function(text, bad) { this.msg = text; this.msgBad = !!bad; this.msgConn = false; },
		loadAll: function() {
			var self = this;
			return Promise.all([ self.call('config_get'), self.call('nodes'), self.call('subnets').catch(function() { return {}; }) ]).then(function(r) {
				self.config = r[0].config || {};
				self.nodes = (r[1].result && r[1].result.nodes) || [];
				self.nets = (r[2].result && r[2].result.subnets) || [];
				var on = self.nets.filter(function(n) { return n.allowed; }).map(function(n) { return n.cidr; });
				self.sel = { primary: self.config.primary || '', secondary: self.config.secondary || '', failover: self.config.failover !== 'off', auto_return: !!self.config.auto_return, mode_label: self.config.mode_label || '', hw_at_boot: self.config.hw_at_boot || 'last', nets: on };
			}).catch(function() {}).then(function() { return self.refresh(); });
		},
		toggleNet: function(n) {
			var s = this.sel, i = s.nets.indexOf(n.cidr);
			if (!n.selectable) return;
			if (i >= 0) s.nets = s.nets.filter(function(x) { return x !== n.cidr; });
			else if (s.nets.length >= 8) this.say(T('nets_max', this.l), true);
			else s.nets = s.nets.concat([ n.cidr ]);
		},
		/* run a change, show requested vs. what the controller's status says, keep refreshing until settled (~40 s) */
		act: function(p) {
			var self = this, key0 = self.pathKey();
			self.busy = true;
			return p.then(function(reply) {
				self.say(Logic.resultText(reply, self.l), reply.ok === false);
				if (reply.status) self.status = reply.status;
				var tries = 0;
				(function again() {
					if (tries++ >= 8) return;
					setTimeout(function() {
						self.call('status').then(function(r) {
							self.status = r.status;
							var d = Logic.describe(r.status, self.l);
							/* settled: replace the "requested ... NOT reached yet" line, it would be stale */
							if (d.reachedOk) {
								self.say(T('result_reached', self.l) + ': ' + d.headline, false);
								/* the public address changes with the mode: ask again by itself (a settings save does not change the path) */
								if (self.pathKey() !== key0 && !self.egressBusy) { self.egressAuto = self.pathKey(); self.checkEgress(); }
							}
							else if (d.tone === 'info') again();
						}).catch(function() {});
					}, 5000);
				})();
			}).catch(function(e) { self.say(T('error', self.l) + ': ' + e.message, true); })
				.then(function() { self.busy = false; });
		},
		toBlocked: function() { return this.act(this.call('set_mode', { mode: 'blocked', source: 'gui' })); },
		toGerman: function() { return this.act(this.call('set_mode', { mode: 'german', source: 'gui' })); },
		toDirect: function() {
			if (typeof window !== 'undefined' && !window.confirm(T('confirm_direct', this.l))) return null;
			return this.act(this.call('set_mode', { mode: 'direct', source: 'gui', confirm: true }));
		},
		failNow: function() { return this.act(this.call('failover_now')); },
		save: function() {
			var self = this, s = self.sel;
			function nm(ip) { var o = Logic.nodeOptions(self.nodes, self.config).filter(function(x) { return x.ip === ip; })[0]; return o && o.name !== ip ? o.name : ''; }
			return self.act(self.call('config_set', { primary: s.primary, primary_name: nm(s.primary), secondary: s.secondary, secondary_name: nm(s.secondary), auto_return: !!s.auto_return, mode_label: String(s.mode_label || '').trim(), hw_at_boot: s.hw_at_boot === 'switch' ? 'switch' : 'last', allow_subnets4: (s.nets || []).join(' ') })
				.then(function(r) { return r.ok === false ? r : self.call('set_failover', { mode: s.failover ? 'auto' : 'off', source: 'gui' }).then(function(r2) { return r2.ok === false ? r2 : r; }); })).then(function() { return self.loadAll(); });
		},
		loadDiag: function() { var self = this; return self.call('diag').then(function(r) { self.diag = (r.diag || []).join('\n'); }).catch(function(e) { self.diag = String(e.message || e); }); },
		/* public address as seen from outside (myip.wtf, asked by the router, only on this button) */
		pathKey: function() { var t = this.status || {}; return [ t.mode, t.state, t.active_exit ].join('|'); },
		checkEgress: function() {
			var self = this;
			self.egressBusy = true;
			return self.call('egress').then(function(r) { self.egress = r.result || { ok: false }; self.egress.at = new Date().toLocaleTimeString(); self.egress.key = self.pathKey(); })
				.catch(function() { self.egress = { ok: false, at: new Date().toLocaleTimeString() }; })
				.then(function() { self.egressBusy = false; });
		},
		download: function() {
			var txt = [ 'TSEM report', new Date().toISOString(), '', JSON.stringify(this.status, null, 1), '', this.diag || '', '', (this.events || []).join('\n') ].join('\n');
			var a = document.createElement('a');
			a.href = URL.createObjectURL(new Blob([ txt ], { type: 'text/plain' }));
			a.download = 'tsem-report.txt';
			a.click();
		}
	},
	render: function(h) {
		var self = this, l = self.l, st = self.status, d = Logic.describe(st, l);
		var has = !!(st && st.state);
		var wantKey = !has ? '' : st.mode === 'direct' ? 'direct' : st.mode === 'german' ? 'german' : 'blocked';
		var curKey = !has ? '' : st.mode === 'direct' ? (d.reachedOk ? 'direct' : '') : (st.state === 'PRIMARY_ACTIVE' || st.state === 'SECONDARY_ACTIVE') ? 'german' : (st.state === 'BLOCKED' || st.mode === 'blocked') ? 'blocked' : '';
		function el(tag, cls, kids, attrs) { return h(tag, { class: cls, attrs: attrs || {} }, kids == null ? [] : [].concat(kids)); }
		var ICONS = {
			shield: [ [ 'path', { d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' } ] ],
			shieldok: [ [ 'path', { d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' } ], [ 'path', { d: 'M9 12l2 2 4-4' } ] ],
			shieldoff: [ [ 'path', { d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' } ], [ 'path', { d: 'M9.5 9.5l5 5M14.5 9.5l-5 5' } ] ],
			alert: [ [ 'path', { d: 'M10.3 3.9L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z' } ], [ 'path', { d: 'M12 9v4M12 17h.01' } ] ],
			sync: [ [ 'path', { d: 'M21 12a9 9 0 0 1-15.5 6.2L3 16' } ], [ 'path', { d: 'M3 12a9 9 0 0 1 15.5-6.2L21 8' } ], [ 'path', { d: 'M21 3v5h-5M3 21v-5h5' } ] ],
			target: [ [ 'circle', { cx: 12, cy: 12, r: 9 } ], [ 'circle', { cx: 12, cy: 12, r: 5 } ], [ 'circle', { cx: 12, cy: 12, r: 1 } ] ],
			check: [ [ 'path', { d: 'M22 11.1V12a10 10 0 1 1-5.9-9.1' } ], [ 'path', { d: 'M22 4L12 14l-3-3' } ] ],
			globe: [ [ 'circle', { cx: 12, cy: 12, r: 10 } ], [ 'path', { d: 'M2 12h20' } ], [ 'path', { d: 'M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z' } ] ],
			clock: [ [ 'circle', { cx: 12, cy: 12, r: 10 } ], [ 'path', { d: 'M12 6v6l4 2' } ] ],
			lock: [ [ 'rect', { x: 3, y: 11, width: 18, height: 11, rx: 2 } ], [ 'path', { d: 'M7 11V7a5 5 0 0 1 10 0v4' } ] ],
			unlock: [ [ 'rect', { x: 3, y: 11, width: 18, height: 11, rx: 2 } ], [ 'path', { d: 'M7 11V7a5 5 0 0 1 9.9-1' } ] ]
		};
		function icon(name, size) {
			return h('svg', { class: 'tsem-ic', attrs: { viewBox: '0 0 24 24', width: size || 22, height: size || 22, fill: 'none', stroke: 'currentColor', 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' } },
				(ICONS[name] || []).map(function(p) { return h(p[0], { attrs: p[1] }); }));
		}
		function fact(tone, ic, label, value, sub) { return el('div', 'tsem-fact tsem-f-' + tone, [ el('span', 'tsem-fic', [ icon(ic, 20) ]), el('div', 'tsem-fx', [ el('div', 'tsem-fl', label), el('div', 'tsem-fv', value), sub ? el('div', 'tsem-fs', sub) : null ]) ]); }
		function card(title, kids) { return el('section', 'tsem-card', [ el('h3', 'tsem-h', title) ].concat(kids)); }
		function row(k, v, bad) { return el('div', 'tsem-row', [ el('span', 'tsem-k', k), el('span', 'tsem-v' + (bad ? ' tsem-badtxt' : ''), v) ]); }
		function chip(kind, text) { return el('span', 'tsem-chip tsem-c-' + kind, [ el('i', 'tsem-dot', ''), text ]); }
		function probeKind(p) { return p === 'egress' ? 'ok' : (p === 'unreachable' || p === 'rejected' || p === 'egress-fail') ? 'bad' : p === 'reach' ? 'warn' : 'mute'; }
		function btn(id, label, fn, cls) { return h('button', { class: 'tsem-btn ' + (cls || ''), attrs: { id: id, type: 'button', disabled: self.busy ? 'disabled' : null }, on: { click: fn } }, label); }
		function tile(key, id, title, sub, fn) {
			var on = curKey === key, pend = !on && wantKey === key;
			return h('button', { class: 'tsem-tile tsem-t-' + key + (on ? ' tsem-on' : '') + (pend ? ' tsem-pend' : ''), attrs: { id: id, type: 'button', disabled: self.busy ? 'disabled' : null, 'aria-pressed': on ? 'true' : 'false' }, on: { click: fn } }, [
				el('span', 'tsem-tic', [ icon(key === 'german' ? 'globe' : key === 'direct' ? 'unlock' : 'lock', 20) ]), el('span', 'tsem-tt', title), el('span', 'tsem-ts', sub), on ? el('span', 'tsem-badge', T('tile.current', l)) : (pend ? el('span', 'tsem-badge tsem-bw', T('tile.pending', l)) : null)
			]);
		}
		function sw(id, key) {
			return el('label', 'tsem-switch', [ h('input', { attrs: { id: id, type: 'checkbox' }, domProps: { checked: self.sel[key] }, on: { change: function(e) { self.sel[key] = e.target.checked; } } }), el('span', 'tsem-slider', '') ]);
		}
		var opts = Logic.nodeOptions(self.nodes, self.config);
		function picker(id, key, allowNone) {
			var o = opts.map(function(x) { return h('option', { attrs: { value: x.ip, selected: x.ip === self.sel[key] ? 'selected' : null } }, x.name + ' (' + x.ip + ')'); });
			if (allowNone) o.unshift(h('option', { attrs: { value: '' } }, '- ' + T('none', l) + ' -'));
			return h('select', { class: 'tsem-select', attrs: { id: id }, domProps: { value: self.sel[key] }, on: { change: function(e) { self.sel[key] = e.target.value; } } }, o);
		}
		var kids = [ h('style', {}, CSS) ];

		/* traffic path: devices -> router -> exit node -> internet. The colours and the moving dots show the REACHED state, never the wish. */
		function nodeName(ip) { var o = Logic.nodeOptions(self.nodes, self.config).filter(function(x) { return x.ip === ip; })[0]; return o ? o.name : (ip || ''); }
		var reduced = typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
		function pathSvg(v) {
			var s = has ? st.state : '', viaExit = s === 'PRIMARY_ACTIVE' || s === 'SECONDARY_ACTIVE';
			var direct = has && st.mode === 'direct' && d.reachedOk, cut = has && !viaExit && !direct;
			var exitIp = viaExit ? st.active_exit : (has ? st.primary : '');
			var c = { ok: '#16a34a', warn: '#f59e0b', bad: '#dc2626', off: '#9ca3af' };
			var nw = v ? 240 : 150, nh = v ? 64 : 72;
			var pos = v ? [ { x: 40, y: 8 }, { x: 40, y: 116 }, { x: 40, y: 224 }, { x: 40, y: 332 } ] : [ { x: 6, y: 44 }, { x: 206, y: 44 }, { x: 406, y: 44 }, { x: 606, y: 44 } ];
			var fo = s === 'SECONDARY_ACTIVE', ex = fo ? '#84cc16' : c.ok; /* failover: lime, the exit leg is not the preferred one */
			var col = [ has ? c.ok : c.off, has ? c.ok : c.off, viaExit ? ex : (cut ? c.bad : c.off), viaExit ? ex : direct ? c.warn : c.off ];
			var labels = [ [ T('path_clients', l), '' ], [ T('path_router', l), '' ], [ nodeName(exitIp) || T('none', l), exitIp || '' ], [ T('path_internet', l), direct ? T('path_direct', l) : '' ] ];
			var out = [];
			labels.forEach(function(lb, i) {
				var p = pos[i], on = col[i] !== c.off;
				out.push(h('rect', { class: on && col[i] !== c.bad ? 'tsem-glow' : '', attrs: { x: p.x, y: p.y, width: nw, height: nh, rx: 14, fill: 'none', stroke: col[i], 'stroke-width': 3 } }));
				/* a long node name is squeezed to the box instead of running over its border */
				var tl = { x: p.x + nw / 2, y: p.y + (lb[1] ? nh / 2 - 2 : nh / 2 + 6), 'text-anchor': 'middle', 'font-size': 19, 'font-weight': 700, fill: 'currentColor' };
				if (String(lb[0]).length * 10.6 > nw - 22) { tl.textLength = nw - 22; tl.lengthAdjust = 'spacingAndGlyphs'; }
				out.push(h('text', { attrs: tl }, lb[0]));
				if (lb[1]) out.push(h('text', { attrs: { x: p.x + nw / 2, y: p.y + nh / 2 + 18, 'text-anchor': 'middle', 'font-size': 13, fill: 'currentColor', opacity: 0.65 } }, lb[1]));
			});
			function seg(i, mode, color) { /* mode: flow | idle | cut ; between node i and i+1 */
				var a = pos[i], b = pos[i + 1];
				var x1 = v ? a.x + nw / 2 : a.x + nw, y1 = v ? a.y + nh : a.y + nh / 2, x2 = v ? b.x + nw / 2 : b.x, y2 = v ? b.y : b.y + nh / 2;
				var dpath = 'M' + x1 + ' ' + y1 + ' L' + x2 + ' ' + y2;
				out.push(h('line', { class: mode === 'cut' ? 'tsem-blink' : '', attrs: { x1: x1, y1: y1, x2: x2, y2: y2, stroke: color, 'stroke-width': 4, 'stroke-linecap': 'round', opacity: mode === 'flow' ? 0.35 : 1, 'stroke-dasharray': mode === 'flow' ? null : '4 9' } }));
				if (mode === 'flow') {
					out.push(h('line', { class: 'tsem-flow', attrs: { x1: x1, y1: y1, x2: x2, y2: y2, stroke: color, 'stroke-width': 4, 'stroke-linecap': 'round' } }));
					if (!reduced) [ 0, 1 ].forEach(function(k) { out.push(h('circle', { attrs: { r: 6, fill: color } }, [ h('animateMotion', { attrs: { dur: '1.8s', begin: (k * 0.9) + 's', repeatCount: 'indefinite', path: dpath } }) ])); });
				}
				if (mode === 'cut') {
					var mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
					out.push(h('g', { class: 'tsem-blink' }, [ h('line', { attrs: { x1: mx - 9, y1: my - 9, x2: mx + 9, y2: my + 9, stroke: color, 'stroke-width': 5, 'stroke-linecap': 'round' } }), h('line', { attrs: { x1: mx + 9, y1: my - 9, x2: mx - 9, y2: my + 9, stroke: color, 'stroke-width': 5, 'stroke-linecap': 'round' } }) ]));
				}
			}
			seg(0, has ? 'flow' : 'idle', col[0]);
			seg(1, viaExit ? 'flow' : cut ? 'cut' : 'idle', viaExit ? ex : cut ? c.bad : c.off);
			seg(2, viaExit ? 'flow' : 'idle', viaExit ? ex : c.off);
			if (direct) {
				var r = pos[1], n = pos[3];
				var arc = v ? 'M' + (r.x + nw) + ' ' + (r.y + nh / 2) + ' C' + (r.x + nw + 48) + ' ' + (r.y + nh / 2) + ' ' + (n.x + nw + 48) + ' ' + (n.y + nh / 2) + ' ' + (n.x + nw) + ' ' + (n.y + nh / 2)
					: 'M' + (r.x + nw / 2) + ' ' + r.y + ' C' + (r.x + nw / 2) + ' ' + (r.y - 46) + ' ' + (n.x + nw / 2) + ' ' + (n.y - 46) + ' ' + (n.x + nw / 2) + ' ' + n.y;
				out.push(h('path', { attrs: { d: arc, fill: 'none', stroke: c.warn, 'stroke-width': 4, 'stroke-linecap': 'round', opacity: 0.4 } }));
				out.push(h('path', { class: 'tsem-flow', attrs: { d: arc, fill: 'none', stroke: c.warn, 'stroke-width': 4, 'stroke-linecap': 'round' } }));
				if (!reduced) [ 0, 1 ].forEach(function(k) { out.push(h('circle', { attrs: { r: 6, fill: c.warn } }, [ h('animateMotion', { attrs: { dur: '2.4s', begin: (k * 1.2) + 's', repeatCount: 'indefinite', path: arc } }) ])); });
			}
			return h('svg', { class: 'tsem-svg ' + (v ? 'tsem-svg-v' : 'tsem-svg-h'), attrs: { viewBox: v ? '0 0 320 410' : '0 0 770 150', role: 'img', 'aria-label': d.headline } }, out);
		}
		function pathCard() { return card(T('path_title', l), [ pathSvg(false), pathSvg(true) ]); }
		/* timeline: the controller's own log, newest first, only lines that mean something to a person */
		function timelineCard() {
			var rows = (self.events || []).map(function(line) {
				var m = String(line).split(/ tsem(?:\[\d+\])?: /);
				if (m.length < 2) return null;
				var msg = m.slice(1).join(' ');
				if (!/set |failover|BLOCKED|blocked|primary|secondary|exit node|guard|mode|selftest|daemon started/i.test(msg) || /already in/.test(msg)) return null;
				var kind = /BLOCKED|blocked|fail|error|leak/i.test(msg) ? 'bad' : /failover|secondary|degraded|direct/i.test(msg) ? 'warn' : /primary|active|ok/i.test(msg) ? 'ok' : 'mute';
				return el('div', 'tsem-ev', [ el('i', 'tsem-dot tsem-c-' + kind, ''), el('span', 'tsem-evt', m[0].split(' ')[3] || ''), el('span', 'tsem-evm', msg.replace(/changed=\d+ apply_rc=\d+ wait=\d+/, '').trim()) ]);
			}).filter(Boolean).slice(-8).reverse();
			return card(T('timeline', l), rows.length ? rows : [ el('div', 'tsem-hint', T('timeline_none', l)) ]);
		}

		var heroIcon = !has ? 'alert' : d.tone === 'ok' ? 'shieldok' : d.tone === 'info' ? 'sync' : d.tone === 'bad' ? 'alert' : (st.mode === 'direct' ? 'shieldoff' : 'shield');
		kids.push(el('section', 'tsem-hero tsem-tone-' + d.tone + (has && st.state === 'SECONDARY_ACTIVE' ? ' tsem-fail' : ''), [
			el('div', 'tsem-hero-top', [
				el('span', 'tsem-pulse' + (d.tone === 'info' ? ' tsem-anim' : ''), [ icon(heroIcon, 30) ]),
				el('div', 'tsem-hero-txt', [ el('div', 'tsem-title', T('title', l)), el('div', 'tsem-headline', d.headline, { id: 'tsem-headline' }) ])
			])
		]));
		d.alerts.forEach(function(a) { kids.push(el('div', 'tsem-alert', [ icon('alert', 20), el('span', '', a) ])); });
		if (has) {
			var stName = T('st.' + st.state, l);
			if (stName === 'st.' + st.state) stName = st.state;
			var hasExit = st.active_exit && st.active_exit !== 'none';
			var modeTone = st.mode === 'direct' ? 'warn' : st.mode === 'german' ? 'ok' : 'bad';
			kids.push(el('div', 'tsem-facts', [
				fact(modeTone, 'target', T('desired', l), T('mode.' + (st.mode || 'none'), l)),
				fact(d.reachedOk ? (d.tone === 'ok' ? 'ok' : (st.state === 'SECONDARY_ACTIVE' ? 'lime' : 'warn')) : (d.tone === 'info' ? 'info' : 'bad'), d.reachedOk ? 'check' : (d.tone === 'info' ? 'sync' : 'alert'), T('reached', l), d.reachedOk ? T('yes', l) + ': ' + stName : T('no', l) + ' (' + stName + ')'),
				fact(hasExit ? (st.state === 'SECONDARY_ACTIVE' ? 'lime' : 'ok') : 'mute', 'globe', T('active_exit', l), hasExit ? nodeName(st.active_exit) : T('none', l), hasExit ? st.active_exit : ''),
				fact('pur', 'clock', T('last_action', l), Logic.lastAction(st, l))
			]));
			kids.push(el('div', 'tsem-hero-hint tsem-hint', T('reached_hint', l)));
		}
		if (self.msg) kids.push(el('div', 'tsem-msg' + (self.msgBad ? ' tsem-msgbad' : ''), self.msg, { id: 'tsem-result' }));

		kids.push(pathCard());
		var eg = self.egress;
		kids.push(card(T('egress_title', l), [
			el('div', 'tsem-actions', [ h('button', { class: 'tsem-btn', attrs: { id: 'tsem-btn-egress', type: 'button', disabled: self.egressBusy ? 'disabled' : null }, on: { click: self.checkEgress } }, self.egressBusy ? T('egress_busy', l) : T('egress_btn', l)) ]),
			eg && eg.ok ? el('div', 'tsem-eg', [
				el('div', '', [ el('div', 'tsem-fl', T('egress_ip', l)), el('div', 'tsem-eg-ip', eg.ip, { id: 'tsem-eg-ip' }) ]),
				el('div', '', [ el('div', 'tsem-fl', T('egress_loc', l)), el('div', 'tsem-fv', eg.location || '-') ]),
				el('div', '', [ el('div', 'tsem-fl', T('egress_isp', l)), el('div', 'tsem-fv', eg.isp || '-') ]),
				el('div', '', [ el('div', 'tsem-fl', T('egress_host', l)), el('div', 'tsem-fs', eg.hostname || '-') ]),
				eg.tor ? el('div', '', [ el('div', 'tsem-fl', T('egress_tor', l)), el('div', 'tsem-fv', T('yes', l)) ]) : null,
				el('div', '', [ el('div', 'tsem-fl', T('egress_when', l)), el('div', 'tsem-fs', eg.at || '') ])
			]) : (eg ? el('div', 'tsem-alert', [ icon('alert', 20), el('span', '', T('egress_fail', l)) ]) : null),
			eg && eg.key && eg.key !== self.pathKey() ? el('div', 'tsem-msg', T('egress_stale', l)) : null,
			el('div', 'tsem-hint', T('egress_hint', l))
		]));
		kids.push(card(T('change_mode', l), [
			el('div', 'tsem-tiles', [
				tile('german', 'tsem-btn-german', T('mode.german', l), T('tile.german', l), self.toGerman),
				tile('direct', 'tsem-btn-direct', T('mode.direct', l), T('tile.direct', l), self.toDirect),
				tile('blocked', 'tsem-btn-blocked', T('mode.blocked', l), T('tile.blocked', l), self.toBlocked)
			]),
			el('div', 'tsem-actions', [ h('button', { class: 'tsem-btn tsem-ghost', attrs: { id: 'tsem-btn-failnow', type: 'button', disabled: (self.busy || !(st && st.mode === 'german')) ? 'disabled' : null }, on: { click: self.failNow } }, T('test_failover', l)) ]),
			el('div', 'tsem-hint', T('test_failover_hint', l))
		]));

		if (has) {
			var cap = [ [ T('primary', l), st.primary, st.primary_probe ], [ T('secondary', l), (st.secondary && st.secondary !== 'none') ? st.secondary : '', st.secondary_probe ] ];
			kids.push(el('div', 'tsem-grid', [
				card(T('exit_nodes', l), cap.map(function(c) {
					return c[1] ? el('div', 'tsem-node', [ el('div', 'tsem-node-role', c[0]), el('div', 'tsem-node-name', nodeName(c[1])), el('div', 'tsem-ip', c[1]), chip(probeKind(c[2]), Logic.probeText(c[2], l)) ])
						: row(c[0], T('none', l));
				})),
				card(T('protection', l), [
					el('div', 'tsem-chips', [
						chip(st.kill_switch_active ? 'ok' : 'mute', T('kill_switch', l) + ': ' + (st.kill_switch_active ? T('on', l) : T('off', l))),
						chip(st.ipv6_protection === 'guarded' ? 'ok' : st.ipv6_protection === 'off' ? 'mute' : 'warn', T('ipv6', l) + ': ' + T('v6.' + (st.ipv6_protection || 'unverified'), l)),
						chip(st.dns_protection === 'redirect' ? 'ok' : (st.dns_protection === 'none' || st.dns_protection === 'off') ? 'mute' : 'warn', T('dns', l) + ': ' + T('dns.' + (st.dns_protection || 'unverified'), l))
					]),
					row(T('failover_policy', l), st.failover), row(T('return_wait', l), Logic.returnWaitText(st, l))
				]),
				card(T('hw', l), [ row(T('hw', l), Logic.hwText(st, l), st.hw_match === 'no') ])
			]));
		}

		kids.push(timelineCard());
		kids.push(card(T('settings', l), [
			row(T('primary', l), picker('tsem-primary', 'primary', false)),
			row(T('secondary', l), picker('tsem-secondary', 'secondary', true)),
			row(T('failover_policy', l), sw('tsem-failover', 'failover')),
			row(T('auto_return', l), sw('tsem-autoreturn', 'auto_return')),
			row(T('hw_at_boot', l), h('select', { class: 'tsem-select', attrs: { id: 'tsem-hwboot' }, domProps: { value: self.sel.hw_at_boot }, on: { change: function(e) { self.sel.hw_at_boot = e.target.value; } } }, [
				h('option', { attrs: { value: 'last', selected: self.sel.hw_at_boot !== 'switch' ? 'selected' : null } }, T('hw_boot_last', l)),
				h('option', { attrs: { value: 'switch', selected: self.sel.hw_at_boot === 'switch' ? 'selected' : null } }, T('hw_boot_switch', l))
			])),
			el('div', 'tsem-hint', T('hw_boot_hint', l)),
			row(T('label_mode', l), h('input', { class: 'tsem-select', attrs: { id: 'tsem-modelabel', type: 'text', maxlength: '20', placeholder: 'EXIT' }, domProps: { value: self.sel.mode_label }, on: { input: function(e) { self.sel.mode_label = e.target.value; } } })),
			el('div', 'tsem-sub', [
				el('div', 'tsem-sub-h', T('subnets_edit', l)),
				el('div', 'tsem-hint', T('nets_legend', l)),
				el('div', 'tsem-nets', self.nets.length ? self.nets.map(function(n) {
					var on = self.sel.nets.indexOf(n.cidr) >= 0;
					return h('button', { class: 'tsem-net ' + (on ? 'tsem-net-on' : 'tsem-net-off') + (n.selectable ? '' : ' tsem-net-lock'), attrs: { type: 'button', 'aria-pressed': on ? 'true' : 'false', title: n.selectable ? '' : T('nets_locked', l), 'data-cidr': n.cidr }, on: { click: function() { self.toggleNet(n); } } }, [
						el('i', 'tsem-dot', ''), el('span', 'tsem-net-c', n.cidr), el('span', 'tsem-net-s', on ? T('nets_on', l) : T('nets_off', l)), n.present ? null : el('span', 'tsem-net-gone', T('nets_gone', l))
					]);
				}) : [ el('div', 'tsem-hint', T('nets_none', l)) ])
			]),
			el('div', 'tsem-actions', [ btn('tsem-btn-save', T('save', l), self.save, 'tsem-primary') ])
		]));
		var prm = Logic.paramRows(self.config, l).map(function(r) { return row(r[0], r[1]); });
		if (prm.length) kids.push(h('details', { class: 'tsem-card' }, [ h('summary', { class: 'tsem-h tsem-sum' }, T('params', l)) ].concat(prm)));
		kids.push(h('details', { class: 'tsem-card' }, [ h('summary', { class: 'tsem-h tsem-sum' }, T('diag', l)),
			el('div', 'tsem-actions', [ btn('tsem-btn-diag', T('load_diag', l), self.loadDiag, 'tsem-ghost'), btn('tsem-btn-download', T('download', l), self.download, 'tsem-ghost') ]),
			h('pre', { class: 'tsem-pre', attrs: { id: 'tsem-diag' } }, self.diag || ''),
			h('h4', { class: 'tsem-h' }, T('events', l)), h('pre', { class: 'tsem-pre', attrs: { id: 'tsem-events' } }, (self.events || []).join('\n'))
		]));
		return h('div', { class: 'tsem', attrs: { id: 'tsem-root' } }, kids);
	},
	__test: { readSid: readSid, makeTransport: makeTransport }
};
