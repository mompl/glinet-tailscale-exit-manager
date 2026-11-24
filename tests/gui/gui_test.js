'use strict';
// GUI test: loads the REAL LuCI view file with a tiny LuCI/DOM shim. rpc.declare() is wired to the REAL rpcd plugin
// (src/usr/libexec/rpcd/tsem) and through it to the REAL controller on the mock backend, so this exercises
// GUI -> API -> controller. It is a software test; it says nothing about a real browser or real router.
const fs = require('fs'), path = require('path'), cp = require('child_process'), assert = require('assert');
const ROOT = process.env.ROOT, SH = process.env.SH || 'sh';
const PLUGIN = path.join(ROOT, 'src/usr/libexec/rpcd/tsem');
let confirmAnswer = true;

function api(method, obj) {
	const r = cp.spawnSync(SH, [PLUGIN, 'call', method], { input: JSON.stringify(obj || {}), encoding: 'utf8', env: process.env });
	if (r.error) throw r.error;
	return JSON.parse(r.stdout);
}
function ctl(...a) { return cp.spawnSync(SH, [path.join(ROOT, 'src/usr/sbin/tsem'), ...a], { encoding: 'utf8', env: process.env }); }

// ---- LuCI / DOM shim
function E(tag, attrs, children) {
	if (Array.isArray(attrs) || typeof attrs === 'string' || (attrs && attrs.nodeType)) { children = attrs; attrs = {}; }
	const n = { nodeType: 1, tag, attrs: attrs || {}, children: [], style: {}, className: (attrs && attrs['class']) || '', value: (attrs && attrs.value) || '',
		checked: !!(attrs && attrs.checked) };
	if (attrs && attrs.style) n.style = {};
	if (attrs && attrs.click) n.click = attrs.click;
	add(n, children);
	n.appendChild = c => { add(n, c); return c; };
	return n;
}
function add(n, c) {
	if (c == null) return;
	if (Array.isArray(c)) return c.forEach(x => add(n, x));
	n.children.push(c);
}
function text(n) { if (n == null) return ''; if (typeof n !== 'object') return String(n); return n.children.map(text).join(' '); }
function find(n, id) { if (!n || typeof n !== 'object') return null; if (n.attrs && n.attrs.id === id) return n; for (const c of n.children || []) { const r = find(c, id); if (r) return r; } return null; }
const domShim = { content(node, c) { node.children = []; add(node, c); } };
const polls = [];
const rpcShim = { declare(spec) {
	return (...args) => {
		const o = {}; (spec.params || []).forEach((p, i) => { if (args[i] !== undefined) o[p] = args[i]; });
		return new Promise((res, rej) => { try { res(api(spec.method, o)); } catch (e) { rej(e); } });
	};
} };
global.E = E;
global.window = { confirm: () => confirmAnswer };
global.document = { documentElement: { lang: process.env.GUI_LANG || 'en' } };

const src = fs.readFileSync(path.join(ROOT, 'src/www/luci-static/resources/view/tsem/status.js'), 'utf8');
const viewShim = { extend: spec => spec };
const TL = new Function(fs.readFileSync(path.join(ROOT, 'src/www/luci-static/resources/tsem/logic.js'), 'utf8'))();
const mod = new Function('view', 'dom', 'rpc', 'poll', 'ui', 'E', 'TL', src.replace(/^'use strict';/, ''));
const View = mod(viewShim, domShim, rpcShim, { add: fn => polls.push(fn) }, {}, E, TL);
const Logic = View.logic;

async function main() {
	// ---------- pure logic: every state is described truthfully
	const base = { state: 'BLOCKED', mode: 'german', guard: 'blocked', intent: 'ok', leak_risk: false, kill_switch_active: true };
	let d = Logic.describe(Object.assign({}, base, { state: 'PRIMARY_ACTIVE', exit_node: '1.1.1.1', active_exit: '1.1.1.1' }), 'en');
	assert.strictEqual(d.tone, 'ok'); assert.ok(d.reachedOk);
	d = Logic.describe(Object.assign({}, base, { state: 'SECONDARY_ACTIVE' }), 'en'); assert.strictEqual(d.tone, 'warn'); assert.ok(d.reachedOk); assert.ok(/SECONDARY/.test(d.headline));
	d = Logic.describe(Object.assign({}, base, { state: 'CONNECTING_PRIMARY' }), 'en'); assert.ok(!d.reachedOk); assert.strictEqual(d.tone, 'info');
	d = Logic.describe(Object.assign({}, base, { state: 'DEGRADED' }), 'en'); assert.ok(!d.reachedOk);
	d = Logic.describe(base, 'en'); assert.ok(!d.reachedOk); assert.ok(/NOT reached/.test(d.headline));
	d = Logic.describe(Object.assign({}, base, { mode: 'direct', state: 'DISABLED', guard: 'open' }), 'en'); assert.ok(d.reachedOk); assert.strictEqual(d.tone, 'warn');
	d = Logic.describe(Object.assign({}, base, { mode: 'direct', state: 'DISABLED', guard: 'blocked' }), 'en'); assert.ok(!d.reachedOk, 'DIRECT with a closed guard must not be reported as reached');
	d = Logic.describe(Object.assign({}, base, { leak_risk: true }), 'en'); assert.strictEqual(d.tone, 'bad'); assert.ok(d.alerts.some(a => /LEAK/.test(a)));
	d = Logic.describe(Object.assign({}, base, { state: 'PRIMARY_ACTIVE', exit_node: '9.9.9.9', active_exit: '1.1.1.1' }), 'en'); assert.ok(d.alerts.some(a => /different exit node/.test(a)));
	d = Logic.describe(null, 'en'); assert.strictEqual(d.tone, 'bad'); assert.ok(!d.reachedOk);
	d = Logic.describe({ intent: 'invalid' }, 'en'); assert.ok(!d.reachedOk);
	assert.ok(/ping only/.test(Logic.probeText('reach', 'en'))); assert.ok(/verified/.test(Logic.probeText('egress', 'en')));
	assert.ok(/NOT/.test(Logic.probeText('egress-fail', 'en')) || /no Internet/.test(Logic.probeText('egress-fail', 'en')));
	// every text key exists in both languages
	const en = Object.keys(View.texts.en).sort().join(), de = Object.keys(View.texts.de).sort().join();
	assert.strictEqual(en, de, 'EN/DE text keys differ');
	// node picker: offline / non-exit peers are not offered; configured IPs always stay selectable
	const opts = Logic.nodeOptions([{ ip: '100.64.0.10', name: 'a', online: true, exit_option: true }, { ip: '100.64.0.11', name: 'b', online: false, exit_option: true },
		{ ip: '100.64.0.12', name: 'c', online: true, exit_option: false }], { primary: '100.64.0.10', secondary: '100.64.0.11', secondary_name: 'b' });
	assert.deepStrictEqual(opts.map(o => o.ip), ['100.64.0.10', '100.64.0.11']);
	// result text: a refused / failed change is never rendered as success
	assert.ok(/Refused/.test(Logic.resultText({ ok: false, code: 'refused', error: 'x' }, 'en')));
	assert.ok(/Error/.test(Logic.resultText({ ok: false, error: 'bad' }, 'en')));

	// ---------- live: GUI -> API -> controller (mock backend)
	const P1 = process.env.P1, P2 = process.env.P2;
	const mock = process.env.TSEM_MOCK_DIR;
	const down = ip => { fs.mkdirSync(mock + '/down', { recursive: true }); fs.writeFileSync(mock + '/down/' + ip, ''); };
	const up = ip => { try { fs.unlinkSync(mock + '/down/' + ip); } catch (e) {} };
	const tick = n => { for (let i = 0; i < n; i++) { ctl('tick'); process.env.TSEM_NOW = String(Number(process.env.TSEM_NOW) + 5); } };
	fs.writeFileSync(mock + '/peers', `alpha|${P1}|true|true|alpha\nbeta|${P2}|true|true|beta\nlaptop|100.64.0.99|true|false|laptop\n`);

	const data = await View.load();
	const root = View.render(data);
	const status = () => text(find(root, 'tsem-statusbox'));
	const headline = () => text(find(root, 'tsem-headline'));
	assert.ok(/saved mode is missing|BLOCKED/.test(status()), 'fresh controller must show BLOCKED/missing intent, got: ' + status());
	assert.ok(/no \(/.test(status()), 'reached must be "no"');
	assert.strictEqual(polls.length, 1, 'status polling registered');

	// GERMAN requested while BOTH exit nodes are down -> must not claim success
	down(P1); down(P2);
	await find(root, 'tsem-btn-german').click();
	let res = text(find(root, 'tsem-result'));
	assert.ok(/Requested: german/.test(res), res);
	assert.ok(!/EXIT is active/.test(res + status()), 'no invented success: ' + res);
	assert.ok(/NOT reached|BLOCKED|Not reached/.test(headline()), headline());
	assert.ok(/no \(/.test(status()));
	tick(8);
	await polls[0]();
	assert.ok(/BLOCKED/.test(headline()));
	assert.ok(/Kill switch\s+on/.test(status()), 'kill switch shown on while blocked: ' + status());

	// primary returns -> only now "reached"
	up(P1); tick(8);
	await polls[0]();
	assert.ok(/EXIT is active via the primary/.test(headline()), headline());
	assert.ok(/yes: PRIMARY_ACTIVE/.test(status()));
	assert.ok(status().includes(P1));
	assert.ok(/Internet through this node works \(verified\)/.test(status()), status());
	assert.ok(/IPv6 protection\s+active \(checked\)/.test(status()), status());

	// DIRECT: declined confirmation changes nothing; accepted confirmation switches
	confirmAnswer = false;
	await find(root, 'tsem-btn-direct').click();
	assert.strictEqual(api('status').status.mode, 'german');
	confirmAnswer = true;
	await find(root, 'tsem-btn-direct').click();
	assert.strictEqual(api('status').status.mode, 'direct');
	assert.ok(/DIRECT is active/.test(headline()), headline());
	assert.strictEqual(api('status').status.source, 'gui');

	// back to GERMAN, then save the configuration (nodes picked from the tailnet list)
	await find(root, 'tsem-btn-german').click();
	tick(8);
	const pSel = find(root, 'tsem-primary'), sSel = find(root, 'tsem-secondary');
	assert.ok(pSel.children.length >= 2 && !JSON.stringify(pSel).includes('100.64.0.99'), 'non-exit peer must not be offered');
	pSel.value = P2; sSel.value = P1;
	find(root, 'tsem-autoreturn').checked = false;
	find(root, 'tsem-failover').checked = false;
	await find(root, 'tsem-btn-save').click();
	const cfg = api('config_get').config;
	assert.strictEqual(cfg.primary, P2); assert.strictEqual(cfg.secondary, P1); assert.strictEqual(cfg.auto_return, false); assert.strictEqual(cfg.failover, 'off');
	assert.strictEqual(api('status').status.guard !== 'open', true, 'saving the configuration must never open the guard');
	// an invalid configuration is shown as an error, not as success
	pSel.value = '999.1.1.1'; sSel.value = '';
	await find(root, 'tsem-btn-save').click();
	assert.ok(/Error/.test(text(find(root, 'tsem-result'))), text(find(root, 'tsem-result')));
	assert.strictEqual(api('config_get').config.primary, P2);

	// diagnostics + events are loaded on demand / by polling
	await find(root, 'tsem-btn-diag').click();
	assert.ok(find(root, 'tsem-diag') !== null);

	// ---------- API failure: nothing is shown as OK
	const saveBin = process.env.TSEM_BIN;
	process.env.TSEM_BIN = '/nonexistent/tsem';
	await polls[0]();
	assert.ok(/cannot be reached|Controller/.test(headline()) || /reach/.test(headline()), headline());
	assert.ok(!/EXIT is active/.test(status()));
	process.env.TSEM_BIN = saveBin;

	// ---------- German texts
	global.document.documentElement.lang = 'de';
	const rootDe = View.render(await View.load());
	assert.ok(/Gewünschter Modus/.test(text(find(rootDe, 'tsem-statusbox'))), text(find(rootDe, 'tsem-statusbox')));
	console.log('gui ok'); process.exit(0);
}
main().catch(e => { console.error(e && e.stack || e); process.exit(1); });
