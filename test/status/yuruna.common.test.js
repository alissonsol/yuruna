/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.07.22

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

// (5) Nested-run subtree rendering. The nested helpers are loop-internal (not
//     exported), so verify their presence + wiring structurally. `nestedChildrenIndex`
//     is a pure map->index builder; exercise it directly by evaluating just that
//     function in the sandbox so a real behavioral check backs the source guards.
assert.match(src, /function nestedChildrenIndex\(nested\)/,
  'nestedChildrenIndex must build the parentId -> children index for nested tiles');
assert.match(src, /function renderNestedNode\(node, byParent, data, depth\)/,
  'renderNestedNode must render a nested sub-tile recursively');
assert.match(src, /function renderOrphanNested\(byParent, sequences, guests, data\)/,
  'renderOrphanNested must be the safety net for parentless nested nodes');
assert.match(src, /renderNestedChildren\(seq\.name, byParent, data, 1\)/,
  'each sequence card must graft nested children matched by parentId === seq.name');
assert.match(src, /data\.cycleFolderUrl \+ node\.logRel/,
  'a nested tile must deep-link via the LIVE cycleFolderUrl + node.logRel (survives the .incomplete rename)');

// Behavioral: pull nestedChildrenIndex out of the source and confirm it groups
// by parentId and stable-sorts by startedAt. Non-tautological -- fails if the
// grouping/sort logic regresses.
var nciSrc = src.match(/function nestedChildrenIndex\(nested\)[\s\S]*?\n    \}/);
assert.ok(nciSrc, 'nestedChildrenIndex source must be extractable for the behavioral check');
var nci = new Function(nciSrc[0] + '\nreturn nestedChildrenIndex;')();
var idx = nci({
  'p/b': { id: 'p/b', parentId: 'p', name: 'b', startedAt: '2026-01-01T00:00:02Z' },
  'p/a': { id: 'p/a', parentId: 'p', name: 'a', startedAt: '2026-01-01T00:00:01Z' },
  'p/a/deep': { parentId: 'p/a', name: 'deep' }
});
assert.strictEqual(idx['p'].length, 2, 'two children group under parent p');
assert.strictEqual(idx['p'][0].name, 'a', 'children sort by startedAt (a before b)');
assert.strictEqual(idx['p/a'][0].id, 'p/a/deep', 'a deeper node groups under its own parent id');
assert.strictEqual(idx['p/a'][0].id && idx['p/a'][0].name, 'deep', 'missing id is backfilled from the map key');

console.log('PASS: yuruna.common.js -- 19 assertions');
