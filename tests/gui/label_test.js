'use strict';
// The exit-node mode has a user-chosen display name (status.mode_label); the default is neutral.
const fs = require('fs'), path = require('path'), assert = require('assert');
const src = fs.readFileSync(path.join(__dirname, '../../src/www/luci-static/resources/tsem/logic.js'), 'utf8');
const mk = () => new Function(src)();
const base = { state: 'PRIMARY_ACTIVE', mode: 'german', guard: 'exit', intent: 'ok', leak_risk: false };
let L = mk();
assert.ok(/^EXIT is active/.test(L.Logic.describe(base, 'en').headline), 'default name is neutral');
assert.strictEqual(L.T('to_german', 'en'), 'Switch to EXIT');
L = mk();
assert.ok(/^Germany is active/.test(L.Logic.describe(Object.assign({ mode_label: 'Germany' }, base), 'en').headline));
assert.strictEqual(L.T('to_german', 'en'), 'Switch to Germany');
assert.ok(/^Germany ist aktiv/.test(L.Logic.describe(Object.assign({ mode_label: 'Germany' }, base), 'de').headline));
L = mk();
assert.ok(/^EXIT is active/.test(L.Logic.describe(Object.assign({ mode_label: '<img onerror=x>' }, base), 'en').headline), 'an invalid name is ignored (no markup from the controller)');
console.log('label test ok');
