// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
/*
  Framework-free checks for this directory's common.js. Run: node common.test.js
  (exit 0 = pass). There is no JS test runner in the repo, so this uses the Node
  built-in assert + vm modules with a minimal shim.

  Covers:
    - pathTail guards a missing/non-string permalink and rawURL/downloadURL propagate
      the null, so a malformed row drops its link instead of crashing every row's render;
    - Y.api bounds the fetch with an AbortController + timeout and clears it in finally;
    - humanSize returns an empty string for a non-finite size instead of 'NaN B'.
*/
'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');

const file = path.join(__dirname, 'common.js');
const source = fs.readFileSync(file, 'utf8');
// Y is a top-level `const` (classic-script scope), which a vm script does not attach
// to the context global; append an assignment so the test can reach it.
const loaded = source + '\n;globalThis.__Y = Y;';

let timersSet = 0, timersCleared = 0;
let fetchImpl = function () { return Promise.reject(new Error('fetch not configured')); };

const sandbox = {
  console: console,
  document: {
    createElement: function () { return { setAttribute: function () {}, append: function () {}, addEventListener: function () {}, style: {}, textContent: '', className: '' }; },
    getElementById: function () { return null; }
  },
  location: { origin: 'https://stash.test', href: '' },
  fetch: function (p, o) { return fetchImpl(p, o); },
  AbortController: AbortController,
  URL: URL,
  setTimeout: function (fn, ms) { timersSet++; return setTimeout(fn, ms); },
  clearTimeout: function (t) { timersCleared++; return clearTimeout(t); }
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(loaded, sandbox, { filename: 'common.js' });

const Y = sandbox.__Y;
assert.ok(Y && typeof Y.api === 'function', 'Y with api should be exposed after load');

(async function () {
  // (1) humanSize: non-finite sizes fall back to '' (not 'NaN B'); valid sizes unchanged.
  assert.strictEqual(Y.humanSize('abc'), '', "humanSize('abc') -> ''");
  assert.strictEqual(Y.humanSize(NaN), '', 'humanSize(NaN) -> empty');
  assert.strictEqual(Y.humanSize(Infinity), '', 'humanSize(Infinity) -> empty');
  assert.strictEqual(Y.humanSize(null), '', 'humanSize(null) -> empty (existing contract)');
  assert.strictEqual(Y.humanSize(512), '512 B', 'humanSize(512) unchanged');
  assert.strictEqual(Y.humanSize(1536), '1.5 KB', 'humanSize(1536) unchanged');

  // (2) rawURL / downloadURL: a bad permalink yields null; a valid view is unchanged.
  assert.strictEqual(Y.rawURL(null), null, 'rawURL(null) -> null');
  assert.strictEqual(Y.rawURL({}), null, 'rawURL(no permalink) -> null');
  assert.strictEqual(Y.rawURL({ hostId: 'h', permalink: 42 }), null, 'rawURL(non-string permalink) -> null');
  assert.strictEqual(Y.rawURL({ hostId: 'h1', permalink: '/s/h1/2026/07/06/abc' }), '/raw/h1/2026/07/06/abc', 'rawURL(valid) unchanged');
  assert.strictEqual(Y.downloadURL(null), null, 'downloadURL(null) -> null');
  assert.strictEqual(Y.downloadURL({ hostId: 'h1', permalink: '/s/h1/2026/07/06/abc' }), '/download/h1/2026/07/06/abc', 'downloadURL(valid) unchanged');

  // (3a) api aborts a never-resolving request once the timeout fires.
  fetchImpl = function (p, o) {
    return new Promise(function (_resolve, reject) {
      o.signal.addEventListener('abort', function () { const e = new Error('aborted'); e.name = 'AbortError'; reject(e); });
    });
  };
  await assert.rejects(function () { return Y.api('/slow', { timeoutMs: 20 }); }, /aborted/, 'api aborts a stalled request');

  // (3b) api returns the parsed body on success and clears its timeout (no leaked timer).
  const setBefore = timersSet, clearBefore = timersCleared;
  fetchImpl = function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ value: 7 }); } }); };
  const body = await Y.api('/ok', { timeoutMs: 60000 });
  assert.deepStrictEqual(body, { value: 7 }, 'api returns the parsed body on success');
  assert.strictEqual(timersSet - setBefore, 1, 'api arms exactly one timeout');
  assert.strictEqual(timersCleared - clearBefore, 1, 'api clears its timeout on success');

  // (4) Source-structure guards (non-tautological -- each fails if its guard is removed from common.js).
  assert.match(source, /function pathTail\(view\)[\s\S]*?typeof view\.permalink !== 'string'/, 'pathTail guards a non-string permalink');
  assert.match(source, /rawURL\(view\)[\s\S]*?tail === null \? null/, 'rawURL propagates pathTail null');
  assert.match(source, /async api\(path, opts\)[\s\S]*?new AbortController\(\)/, 'api bounds the fetch with an AbortController');
  assert.match(source, /humanSize\(n\)[\s\S]*?Number\.isFinite\(v\)/, 'humanSize guards non-finite sizes');

  console.log('PASS: common.js');
})().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
