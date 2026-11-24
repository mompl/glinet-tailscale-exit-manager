'use strict';
// Records what the REAL rpcd plugin and the REAL controller (mock backend, neutral node names) answer for the states the GUI shows,
// so that site/gui-demo.html can run the UNCHANGED GL.iNet GUI bundle against it. Nothing here talks to a router or the network.
//
//   ROOT=<repo> node tools/record-gui-fixtures.js > site/gui-fixtures.json
const fs = require('fs'), os = require('os'), path = require('path'), cp = require('child_process');
const ROOT = process.env.ROOT || path.resolve(__dirname, '..');
const SH = process.env.SH || 'sh';
const PLUGIN = path.join(ROOT, 'src/usr/libexec/rpcd/tsem');
const BIN = path.join(ROOT, 'src/usr/sbin/tsem');
const T = fs.mkdtempSync(path.join(os.tmpdir(), 'tsem-fixtures-'));
const P1 = '100.64.0.10', P2 = '100.64.0.11';
const env = Object.assign({}, process.env, {
	TSEM_STATE_DIR: T + '/state', TSEM_RUN_DIR: T + '/run', TSEM_MOCK_DIR: T + '/mock', TSEM_BACKEND: 'mock',
	TSEM_LIBDIR: path.join(ROOT, 'src/usr/lib/tsem'), TSEM_CONF: T + '/tsem.conf', TSEM_BIN: T + '/bin/tsem', TSEM_LOGREAD: T + '/logread',
	TSEM_SYSLOG: '0', TSEM_SET_TICK_DELAY: '0', TSEM_NOW: '1790000000', TSEM_LOCK_TIMEOUT: '10', TSEM_LAN_IFACES: 'lo', TSEM_TS_IFACE: 'lo'
});
delete env.TSEM_PRIMARY; delete env.TSEM_SECONDARY;
// the plugin reads its arguments with OpenWrt's jsonfilter: the test stand-in is used here
env.PATH = path.join(ROOT, 'tests/stubs') + path.delimiter + env.PATH;
for (const d of ['state', 'run', 'mock', 'bin']) fs.mkdirSync(T + '/' + d, { recursive: true });
fs.writeFileSync(T + '/bin/tsem', '#!/bin/sh\nexec "' + SH + '" "' + BIN + '" "$@"\n', { mode: 0o755 });
fs.writeFileSync(T + '/tsem.conf', 'TSEM_PRIMARY=' + P1 + '\nTSEM_PRIMARY_NAME=exit-de-1\nTSEM_SECONDARY=' + P2 + '\nTSEM_SECONDARY_NAME=exit-de-2\nTSEM_MODE_LABEL="Germany"\n');
fs.writeFileSync(T + '/logread', '#!/bin/sh\ncat "' + T + '/log"\n', { mode: 0o755 });
fs.writeFileSync(T + '/log', '');
fs.writeFileSync(T + '/mock/peers', 'exit-de-1|' + P1 + '|true|true|a\nexit-de-2|' + P2 + '|true|true|b\n');

// the controller's own log lines (stderr when syslog is off) become what the GUI shows as "events", with a syslog-like prefix
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function stamp() {
	const d = new Date(Number(env.TSEM_NOW) * 1000), p = n => String(n).padStart(2, '0');
	return DAYS[d.getUTCDay()] + ' ' + MON[d.getUTCMonth()] + ' ' + p(d.getUTCDate()) + ' ' + p(d.getUTCHours()) + ':' + p(d.getUTCMinutes()) + ':' + p(d.getUTCSeconds()) + ' ' + d.getUTCFullYear();
}
const ctl = (...a) => {
	const r = cp.spawnSync(SH, [BIN, ...a], { encoding: 'utf8', env });
	const lines = ((r.stderr || '') + (r.stdout || '')).split('\n').filter(l => /^tsem: /.test(l));
	if (lines.length) fs.appendFileSync(T + '/log', lines.map(l => stamp() + ' user.notice ' + l + '\n').join(''));
	return r;
};
const tick = n => { for (let i = 0; i < n; i++) { ctl('tick'); env.TSEM_NOW = String(Number(env.TSEM_NOW) + 5); } };
const down = ip => { fs.mkdirSync(T + '/mock/down', { recursive: true }); fs.writeFileSync(T + '/mock/down/' + ip, ''); };
const up = ip => { try { fs.unlinkSync(T + '/mock/down/' + ip); } catch (e) {} };
function call(method, params) {
	const r = cp.spawnSync(SH, [PLUGIN, 'call', method], { input: JSON.stringify(params || {}), encoding: 'utf8', env });
	if (r.error || !r.stdout) throw new Error('plugin ' + method + ' failed: ' + (r.stderr || r.error));
	return JSON.parse(r.stdout);
}
// the public address is asked from the Internet by the real thing; here a documentation address is used and said so
const EG = {
	direct: { ok: true, ip: '198.51.100.23', country: 'Germany', country_code: 'DE', location: 'Berlin, Germany', isp: 'Example ISP', hostname: '', tor: false },
	exit: { ok: true, ip: '203.0.113.45', country: 'Germany', country_code: 'DE', location: 'Frankfurt, Germany', isp: 'Example Hosting', hostname: '', tor: false }
};
function snap(name, eg) {
	const s = {};
	for (const m of ['status', 'nodes', 'config_get', 'events', 'diag', 'subnets']) s[m] = call(m, m === 'events' ? { n: 30 } : {});
	s.egress = { ok: true, result: eg || { ok: false, reason: 'unavailable' } }; // same wrapping as the real plugin's do_egress
	return { name, state: s };
}

const out = { about: 'Recorded from the real tsem controller on its mock backend with neutral node names. Public addresses are documentation addresses.', states: [] };
ctl('set', 'direct', '--no-wait'); tick(3);
out.states.push(snap('direct', EG.direct));
ctl('set', 'german', '--no-wait');
// the real controller starts BLOCKED and moves to CONNECTING_PRIMARY while it verifies the exit node: record that moment
for (let i = 0; i < 20; i++) { tick(1); if (/^CONNECTING/.test(call('status').status.state)) break; }
out.states.push(snap('connecting', null));
tick(12);
out.states.push(snap('exit', EG.exit));
down(P1); tick(24);
out.states.push(snap('failover', EG.exit));
down(P2); tick(24);
out.states.push(snap('blocked', null));
up(P1); up(P2); tick(40);
out.states.push(snap('recovered', EG.exit));
// the answers to the buttons, in the shape the real plugin gives them
out.actions = { set_mode_german: call('set_mode', { mode: 'german' }), set_mode_direct: call('set_mode', { mode: 'direct' }) };
process.stdout.write(JSON.stringify(out, null, 1) + '\n');
fs.rmSync(T, { recursive: true, force: true });
