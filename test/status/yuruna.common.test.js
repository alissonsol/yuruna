/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.07.14

  Framework-free checks for test/status/yuruna.common.js. Run: node yuruna.common.test.js
  (exit 0 = pass). No package.json / test runner in the repo, so this uses the Node
  built-in assert + vm modules and a minimal document/window shim -- enough to load the
  browser IIFE and exercise its exported surface plus source-structure guards.

  Covers two yuruna.common.js invariants:
    - renderStatus guards banner/noData (matching applyBanner) so an id drift degrades
      gracefully instead of throwing out of the poll loop;
    - bootIndex reuses the shared BANNER_TEXT via Object.assign instead of a duplicate
      literal, so the two banner tables cannot silently diverge.
*/
'use strict';
var fs = require('fs');
var vm = require('vm');
var assert = require('assert');
var path = require('path');

var file = path.join(__dirname, 'yuruna.common.js');
var src = fs.readFileSync(file, 'utf8');

// U+2014 em-dash via char code so this test file stays plain ASCII.
var EMDASH = String.fromCharCode(0x2014);

function makeEl() {
  return {
    textContent: '', innerHTML: '', className: '', value: '', style: {},
    addEventListener: function () {}, appendChild: function () {},
    setAttribute: function () {}, getAttribute: function () { return null; },
    querySelector: function () { return null; }, querySelectorAll: function () { return []; },
    classList: { add: function () {}, remove: function () {}, toggle: function () {} }
  };
}

// getElementById returns null for every id -> simulates the DOM-id drift the guard defends.
var documentShim = {
  getElementById: function () { return null; },
  createElement: function () { return makeEl(); },
  addEventListener: function () {},
  querySelector: function () { return null; },
  querySelectorAll: function () { return []; },
  title: '', body: makeEl()
};
var windowShim = {
  location: { hostname: 'test', href: '', search: '', pathname: '/' },
  addEventListener: function () {}, removeEventListener: function () {},
  navigator: { userAgent: 'node' },
  localStorage: { getItem: function () { return null; }, setItem: function () {}, removeItem: function () {} },
  setTimeout: function () { return 0; }, clearTimeout: function () {},
  setInterval: function () { return 0; }, clearInterval: function () {}
};
windowShim.window = windowShim;
var sandbox = {
  window: windowShim, document: documentShim, console: console,
  navigator: windowShim.navigator, localStorage: windowShim.localStorage,
  location: windowShim.location,
  fetch: function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve({}); }, text: function () { return Promise.resolve('{}'); } }); },
  setTimeout: function () { return 0; }, clearTimeout: function () {},
  setInterval: function () { return 0; }, clearInterval: function () {}
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: 'yuruna.common.js' });

var Y = sandbox.window.Yuruna;
assert.ok(Y, 'window.Yuruna should be mounted after load');

// (1) Defensive contract: applyBanner tolerates a missing #banner (getElementById -> null).
//     renderStatus mirrors this contract for banner + noData.
assert.doesNotThrow(function () {
  Y.applyBanner({ overallStatus: 'pass', guests: [{}] }, null, null);
}, 'applyBanner must not throw when #banner is absent');

// (2) The shared BANNER_TEXT is exported with the five expected keys.
assert.deepStrictEqual(
  Object.keys(Y.BANNER_TEXT).sort(),
  ['fail', 'idle', 'pass', 'running', 'stopped'],
  'BANNER_TEXT must expose idle/running/pass/fail/stopped'
);

// (3) Behavioral equivalence: reusing BANNER_TEXT with only fail overridden must
//     reproduce the index dashboard BANNER table exactly (all five keys identical).
var rebuilt = Object.assign({}, Y.BANNER_TEXT, { fail: 'Incident detected ' + EMDASH + ' see details below' });
var expected = {
  idle: 'No test data available',
  running: 'Test in progress',
  pass: 'All guests operational',
  fail: 'Incident detected ' + EMDASH + ' see details below',
  stopped: 'Test runner stopped'
};
assert.deepStrictEqual(rebuilt, expected, 'Object.assign over BANNER_TEXT must reproduce the index BANNER table');

// (4) Source-structure guards (non-tautological -- they fail if the guards are removed from the source).
//     renderStatus is loop-internal (not exported), so its guard is verified here
//     structurally and behaviorally via the applyBanner contract it mirrors (see 1).
assert.match(src, /function renderStatus[\s\S]*?if \(!banner \|\| !noData \|\| !headerMachine\)/,
  'renderStatus must guard banner/noData/headerMachine before dereferencing them');
assert.match(src, /var BANNER = Object\.assign\(\{\}, BANNER_TEXT,/,
  'bootIndex must build BANNER by reusing BANNER_TEXT, not a duplicate literal');

// The cycle-folder lifecycle-suffix strip is a single shared helper, so a
// history-row URL and a perf-icicle deep-link URL cannot drift apart. The
// trailing-slash-capturing .incomplete strip must appear exactly once (in the
// helper); logFileUrl's bare-anchor variant is a distinct regex and not counted.
assert.match(src, /function stripCycleFolderSuffix\(u\)/,
  'stripCycleFolderSuffix must be defined once as the shared cycle-folder strip');
assert.strictEqual(src.split(".replace(/\\.incomplete(\\/?)$/, '$1')").length - 1, 1,
  'the trailing-slash .incomplete strip must appear once (in stripCycleFolderSuffix), not re-inlined at the two call sites');

// The optional-endpoint "fetch -> JSON or null" shape is the single
// module-level fetchJson; the per-handler jsonOrNull closures are gone, and no
// caller passes a manual ?_= cache-buster into fetchJson (which appends its own),
// so the poll URLs cannot carry a double ?_=X?_=Y.
assert.doesNotMatch(src, /function jsonOrNull/,
  'the per-handler jsonOrNull closures must be consolidated onto module-level fetchJson');
assert.doesNotMatch(src, /fetchJson\([^)]*\?_=/,
  'no fetchJson caller may append its own ?_= buster (fetchJson adds one) -- avoids a double cache-buster');

console.log('PASS: yuruna.common.js -- 10 assertions');
