'use strict';
// Native GL.iNet view: loads the GENERATED bundle exactly like the GL.iNet loader does (component = eval(text)) and drives
// it with a minimal Vue-2-like harness. fetch() is wired to the REAL rpcd plugin and through it to the REAL controller
// (mock backend). Not covered here (UNVERIFIED): real Vue, real browser, real oui-httpd, the Lua bridge.
const fs = require('fs'), path = require('path'), cp = require('child_process'), assert = require('assert');
const ROOT = process.env.ROOT, SH = process.env.SH || 'sh';
const PLUGIN = path.join(ROOT, 'src/usr/libexec/rpcd/tsem');
const bundle = fs.readFileSync(path.join(ROOT, 'src/www/views/gl-sdk4-ui-tsem.common.js'), 'utf8');
const P1 = process.env.P1, P2 = process.env.P2, mock = process.env.TSEM_MOCK_DIR;

function plugin(method, params) {
	const r = cp.spawnSync(SH, [PLUGIN, 'call', method], { input: JSON.stringify(params || {}), encoding: 'utf8', env: process.env });
	return JSON.parse(r.stdout);
}
function ctl(...a) { return cp.spawnSync(SH, [path.join(ROOT, 'src/usr/sbin/tsem'), ...a], { encoding: 'utf8', env: process.env }); }
const tick = n => { for (let i = 0; i < n; i++) { ctl('tick'); process.env.TSEM_NOW = String(Number(process.env.TSEM_NOW) + 5); } };
const down = ip => { fs.mkdirSync(mock + '/down', { recursive: true }); fs.writeFileSync(mock + '/down/' + ip, ''); };
const up = ip => { try { fs.unlinkSync(mock + '/down/' + ip); } catch (e) {} };

// ---- environment of the page
const requests = [];
let confirmAnswer = true, httpOk = true;
global.document = { cookie: 'foo=bar; Admin-Token=sid-abc%3D123; x=y', documentElement: { lang: 'en' } };
global.window = {
	confirm: () => confirmAnswer,
	fetch: (url, opts) => {
		requests.push({ url, opts });
		const body = JSON.parse(opts.body);
		const call = body.params[3];
		const res = httpOk ? { ok: true, status: 200, json: async () => ({ jsonrpc: '2.0', id: body.id, result: plugin(call.m, call.p) }) } : { ok: false, status: 403, json: async () => ({}) };
		return Promise.resolve(res);
	}
};

// ---- minimal Vue-2-like harness
function h(tag, data, children) {
	if (Array.isArray(data) || typeof data === 'string') { children = data; data = {}; }
	const kids = [].concat(children == null ? [] : children).flat();
	return { tag, data: data || {}, children: kids };
}
const text = n => n == null ? '' : typeof n !== 'object' ? String(n) : n.children.map(text).join(' ');
const find = (n, id) => { if (!n || typeof n !== 'object') return null; if (n.data && n.data.attrs && n.data.attrs.id === id) return n; for (const c of n.children || []) { const r = find(c, id); if (r) return r; } return null; };
function mount(comp) {
	const vm = Object.assign({}, comp.data.call({}), { $forceUpdate() {} });
	for (const k of Object.keys(comp.methods)) vm[k] = comp.methods[k].bind(vm);
	comp.created.call(vm);
	return { vm, tree: () => comp.render.call(vm, h), stop: () => comp.beforeDestroy.call(vm) };
}
const click = (tree, id) => find(tree(), id).data.on.click();
const settle = () => new Promise(r => setTimeout(r, 30));

async function main() {
	// ---------- eval contract
	const comp = eval(bundle);
	assert.strictEqual(typeof comp, 'object'); assert.strictEqual(comp.name, 'tsem');
	assert.strictEqual(typeof comp.render, 'function'); assert.ok(!('template' in comp), 'runtime-only Vue: no template');
	assert.ok(!/\bmodule\.exports\b|\brequire\(/.test(bundle), 'bundle must not depend on CommonJS');
	assert.ok(!/innerHTML|document\.write/.test(bundle), 'no HTML injection primitives');
	assert.ok(!/[^\x00-\x7f]/.test(bundle), 'bundle must be pure ASCII (umlauts as escapes): the web server may send no charset');
	assert.ok(!/\\ufffd/i.test(bundle), 'no U+FFFD replacement characters (broken umlauts) in the texts');
	assert.ok(bundle.includes('R\\u00fcckkehr'), 'umlaut texts are present as escapes');

	// ---------- transport shape: session id in the body (not a cookie-only credential), custom header, JSON content type
	fs.writeFileSync(mock + '/peers', `alpha|${P1}|true|true|alpha\nbeta|${P2}|true|true|beta\nlaptop|100.64.0.99|true|false|laptop\n`);
	let m = mount(comp);
	await settle();
	assert.ok(requests.length >= 3, 'initial load calls the API');
	for (const r of requests) {
		assert.strictEqual(r.url, '/rpc');
		assert.strictEqual(r.opts.method, 'POST');
		assert.strictEqual(r.opts.headers['Content-Type'], 'application/json');
		assert.strictEqual(r.opts.headers.glinet, '1');
		const b = JSON.parse(r.opts.body);
		assert.deepStrictEqual(b.params.slice(0, 3), ['sid-abc=123', 'tsem', 'call']);
		assert.ok(['status', 'events', 'config_get', 'nodes', 'subnets', 'notify_get'].includes(b.params[3].m), 'only read methods at load: ' + b.params[3].m);
		assert.ok(!JSON.stringify(b).includes('http'), 'no URLs/secrets in the request');
	}
	let t = text(m.tree());
	assert.ok(/Messages \(ntfy\)/.test(t), 'the message settings card is shown');
	assert.ok(find(m.tree(), 'tsem-btn-nsave') && find(m.tree(), 'tsem-btn-ntest'), 'save and test buttons exist');
	assert.ok(!find(m.tree(), 'tsem-btn-nclear'), 'no backup server yet: no remove button');
	assert.ok(find(m.tree(), 'tsem-direct-for'), 'DIRECT duration choice exists');
	assert.ok(find(m.tree(), 'tsem-btn-leak'), 'leak test button exists');
	assert.ok(find(m.tree(), 'tsem-btn-report'), 'statistics button exists');
	assert.ok(!find(m.tree(), 'tsem-btn-keepdirect'), 'no timer running: no keep-DIRECT button');
	assert.ok(/saved mode is missing|BLOCKED/.test(t), 'fresh controller shows BLOCKED/missing intent: ' + t);
	assert.ok(/Reached\s+no \(/.test(t.replace(/\s+/g, ' ').replace('Actually reached', 'Reached')), 'reached must be "no"');

	// ---------- GERMAN while both nodes are down: requested != reached, no invented success
	down(P1); down(P2);
	requests.length = 0;
	await click(m.tree, 'tsem-btn-german'); await settle();
	let b = JSON.parse(requests[0].opts.body).params[3];
	assert.deepStrictEqual(b, { m: 'set_mode', p: { mode: 'german', source: 'gui' } });
	t = text(m.tree());
	assert.ok(/Requested: german/.test(t), t);
	assert.ok(!/EXIT is active/.test(t), 'no invented success: ' + t);
	tick(8); await m.vm.refresh();
	assert.ok(/BLOCKED/.test(text(find(m.tree(), 'tsem-headline'))));

	// ---------- primary returns: only now "reached"
	up(P1); tick(8); await m.vm.refresh();
	assert.ok(/EXIT is active via the primary/.test(text(find(m.tree(), 'tsem-headline'))), text(find(m.tree(), 'tsem-headline')));
	t = text(m.tree());
	assert.ok(/Internet through this node works \(verified\)/.test(t), t);
	assert.ok(/IPv6 protection\s+active \(checked\)/.test(t.replace(/\s+/g, ' ').replace(/ +/g, ' ')) || /active \(checked\)/.test(t));

	// ---------- DIRECT: declined confirmation sends NOTHING; accepted one sends confirm=true
	confirmAnswer = false; requests.length = 0;
	await m.vm.toDirect();
	assert.strictEqual(requests.length, 0, 'declined confirmation must not call the API');
	assert.strictEqual(plugin('status').status.mode, 'german');
	confirmAnswer = true;
	await click(m.tree, 'tsem-btn-direct'); await settle();
	b = JSON.parse(requests[0].opts.body).params[3];
	assert.deepStrictEqual(b, { m: 'set_mode', p: { mode: 'direct', source: 'gui', confirm: true } });
	assert.strictEqual(plugin('status').status.mode, 'direct');
	assert.ok(/DIRECT is active/.test(text(find(m.tree(), 'tsem-headline'))));
	// the server side refuses DIRECT without the confirmation, whatever the view sends
	const refused = plugin('set_mode', { mode: 'direct', source: 'gui' });
	assert.strictEqual(refused.ok, false); assert.strictEqual(refused.code, 'confirmation_required');

	// ---------- back to GERMAN, then save the configuration
	await click(m.tree, 'tsem-btn-german'); await settle(); tick(8);
	await m.vm.loadAll();
	const tr = JSON.stringify(m.tree());
	assert.ok(!tr.includes('100.64.0.99'), 'non-exit peer must not be offered');
	m.vm.sel.primary = P2; m.vm.sel.secondary = P1; m.vm.sel.auto_return = false; m.vm.sel.failover = false;
	await click(m.tree, 'tsem-btn-save'); await settle();
	const cfg = plugin('config_get').config;
	assert.strictEqual(cfg.primary, P2); assert.strictEqual(cfg.secondary, P1); assert.strictEqual(cfg.auto_return, false); assert.strictEqual(cfg.failover, 'off');
	assert.strictEqual(cfg.hw_at_boot, 'last', 'default policy for the boot replay of the hardware switch');
	m.vm.sel.hw_at_boot = 'switch';
	await click(m.tree, 'tsem-btn-save'); await settle();
	assert.strictEqual(plugin('config_get').config.hw_at_boot, 'switch', 'the policy can be chosen in the GUI');

	// ---------- public address: nothing is asked at load, only the button asks (stub curl, never the real service)
	assert.ok(!requests.some(r => JSON.parse(r.opts.body).params[3].m === 'egress'), 'egress must not be requested without the button');
	fs.writeFileSync(mock + '/curl', '#!/bin/sh\necho \'{ "YourFuckingIPAddress": "203.0.113.7", "YourFuckingLocation": "Bonn, Germany", "YourFuckingISP": "Example ISP" }\'\n', { mode: 0o755 });
	process.env.TSEM_CURL = mock + '/curl';
	requests.length = 0;
	await click(m.tree, 'tsem-btn-egress'); await settle();
	assert.deepStrictEqual(JSON.parse(requests[0].opts.body).params[3], { m: 'egress', p: {} });
	assert.ok(/203\.0\.113\.7/.test(text(find(m.tree(), 'tsem-eg-ip'))), 'public address is shown');
	assert.ok(/Bonn, Germany/.test(text(m.tree())) && /Example ISP/.test(text(m.tree())), 'location and provider are shown');

	// ---------- diagnostics + report: no secrets
	await click(m.tree, 'tsem-btn-diag'); await settle();
	const diag = text(find(m.tree(), 'tsem-diag'));
	assert.ok(diag.length > 0, 'diagnostics loaded');
	assert.ok(!/tskey-|authkey\s*[=:]|password\s*[=:]|\btoken\s*[=:]|Bearer /i.test(diag), 'no secrets in diagnostics');
	m.stop();

	// ---------- a mode change asks for the public address by itself (about 5 s later, when the new path is reached)
	m.vm.egress = null; requests.length = 0;
	await click(m.tree, 'tsem-btn-direct'); await settle();
	await new Promise(r => setTimeout(r, 5600));
	assert.ok(requests.some(r => JSON.parse(r.opts.body).params[3].m === 'egress'), 'the public address is requested after a mode change');
	assert.ok(m.vm.egress && m.vm.egress.ok, 'and shown');
	m.stop();

	// ---------- failure modes never look like success
	httpOk = false;
	m = mount(comp); await settle();
	t = text(m.tree());
	assert.ok(/Connection to the router interrupted.*HTTP 403/.test(t), t);
	assert.ok(/cannot be reached/.test(text(find(m.tree(), 'tsem-headline'))), 'unreachable controller is shown as such');
	m.stop();
	httpOk = true;
	global.document.cookie = 'foo=bar';
	requests.length = 0;
	m = mount(comp); await settle();
	assert.strictEqual(requests.length, 0, 'without a GL.iNet session nothing is sent');
	assert.ok(/no GL\.iNet session/.test(text(m.tree())), text(m.tree()));
	m.stop();

	// ---------- German texts
	global.document = { cookie: 'Admin-Token=x', documentElement: { lang: 'de' } };
	m = mount(comp); await settle();
	assert.ok(/Gewünschter Modus|Controller-Zustand/.test(text(m.tree())), 'German UI');
	m.stop();
	console.log('native ok');
	process.exit(0);
}
main().catch(e => { console.error(e); process.exit(1); });
