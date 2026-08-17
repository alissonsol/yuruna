// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
/*
  Framework-free checks for this directory's common.js. Run: node common.test.js
  (exit 0 = pass). There is no JS test runner in the repo, so this uses the Node
  built-in assert + vm modules with a minimal shim.

  Covers:
    - pathTail guards a missing/non-string permalink and rawURL/downloadURL/stashApiURL
      propagate the null, so a malformed row drops its link (and never issues a DELETE at
      a guessed path) instead of crashing every row's render;
    - Y.api bounds the fetch with an AbortController + timeout and clears it in finally;
    - humanSize returns an empty string for a non-finite size instead of 'NaN B';
    - hostInfo shares one /api/hostinfo read between callers, never rejects, and
      does not memoize a failure;
    - stashKey renders a row as the bulk-delete API's field form, and propagates
      the same null a malformed permalink produces everywhere else;
    - guid spells a full host id 8-4-4-4-12 for display and passes anything else
      through, so no dashed value can leak into a URL built from view.hostId;
    - a control proof in the URL fragment is spent once, at load, and is taken
      out of the address bar; a page with no fragment sends nothing;
    - Y.session reports a locked, unconfigured gate when the daemon cannot be
      asked, so a page withholds controls it cannot vouch for;
    - the footer countdown parks while a page reports itself paused.
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

// loadWithHash runs common.js in a fresh context whose URL carries hash, so the
// load-time proof exchange can be observed. It has to be a new context: the
// exchange is a module-level IIFE that runs once per page.
function loadWithHash(hash) {
  const posts = [];
  const box = {
    console: console,
    document: { createElement: sandbox.document.createElement, getElementById: function () { return null; }, title: 't' },
    location: { origin: 'https://stash.test', href: '', hash: hash, pathname: '/s/h1/2026/07/06/abc', search: '' },
    history: { replaceState: function () { box.replaced++; } },
    fetch: function (p, o) { posts.push({ path: p, body: o && o.body }); return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ ok: true }); } }); },
    AbortController: AbortController,
    URL: URL,
    setTimeout: setTimeout,
    clearTimeout: clearTimeout,
    replaced: 0,
  };
  box.globalThis = box;
  vm.createContext(box);
  vm.runInContext(loaded, box, { filename: 'common.js' });
  return { Y: box.__Y, posts: posts, sandbox: box, get replaced() { return box.replaced; } };
}

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
  assert.strictEqual(Y.stashApiURL(null), null, 'stashApiURL(null) -> null');
  assert.strictEqual(Y.stashApiURL({ hostId: 'h', permalink: 42 }), null, 'stashApiURL(non-string permalink) -> null');
  assert.strictEqual(Y.stashApiURL({ hostId: 'h1', permalink: '/s/h1/2026/07/06/abc' }), '/api/stashes/h1/2026/07/06/abc', 'stashApiURL(valid) targets the REST endpoint');

  // (2b) stashKey: the same row as the bulk-delete body's field form, and the
  // same null for a row that cannot be addressed -- a stash named imprecisely
  // must never reach a request that destroys things.
  assert.deepStrictEqual(Y.stashKey({ hostId: 'h1', permalink: '/s/h1/2026/07/06/abc' }),
    { hostId: 'h1', year: '2026', month: '07', day: '06', id: 'abc' }, 'stashKey(valid) is the API field form');
  assert.strictEqual(Y.stashKey(null), null, 'stashKey(null) -> null');
  assert.strictEqual(Y.stashKey({ hostId: 'h', permalink: 42 }), null, 'stashKey(non-string permalink) -> null');
  assert.strictEqual(Y.stashKey({ hostId: 'h', permalink: '/s/h/2026/07' }), null, 'stashKey(short permalink) -> null');

  // (2c) guid renders a full host id the way every operator-facing surface spells
  // one, and leaves anything that is not 32 hex alone -- the URL builders above
  // are fed view.hostId itself, so a dashed value must never reach a request.
  assert.strictEqual(Y.guid('426d17ef0b88426b922180dad1a9e921'), '426d17ef-0b88-426b-9221-80dad1a9e921',
    'guid(32 hex) is spelled 8-4-4-4-12');
  assert.strictEqual(Y.guid('426d17ef-0b88-426b-9221-80dad1a9e921'), '426d17ef-0b88-426b-9221-80dad1a9e921',
    'guid(already dashed) is unchanged');
  assert.strictEqual(Y.guid('h1'), 'h1', 'guid(short opaque id) is unchanged');
  assert.strictEqual(Y.guid(null), '', 'guid(null) -> empty');
  assert.strictEqual(Y.shortHost('426d17ef0b88426b922180dad1a9e921'), '426d17ef',
    'shortHost still names the row: its text is the first field of guid()');

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

  // (3c) hostInfo is shared and non-rejecting: every consumer of the host facts
  // (header, footer, and a page deciding whether to offer delete) costs one
  // request between them, a failed read resolves to {} rather than throwing, and
  // that failure is NOT memoized -- controls derived from it must be able to
  // come back without a page reload.
  let hostinfoCalls = 0;
  fetchImpl = function () { hostinfoCalls++; return Promise.reject(new Error('daemon down')); };
  assert.deepStrictEqual(await Y.hostInfo(), {}, 'a failed hostInfo read resolves to {}');
  fetchImpl = function () {
    hostinfoCalls++;
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ ok: true, localHostId: 'h1', version: '9.9' }); } });
  };
  const facts = await Y.hostInfo();
  assert.strictEqual(facts.localHostId, 'h1', 'hostInfo returns the parsed body');
  assert.strictEqual((await Y.hostInfo()).version, '9.9', 'a later caller gets the same answer');
  assert.strictEqual(hostinfoCalls, 2, 'the failure was retried; the success is shared');

  // (3d) Y.session never rejects: a daemon that cannot be asked reports a
  // locked, unconfigured gate, which is what makes a page withhold its delete
  // controls rather than offer ones it cannot vouch for.
  fetchImpl = function () { return Promise.reject(new Error('daemon down')); };
  assert.deepStrictEqual(await Y.session(), { authed: false, labToken: false, configured: false },
    'an unreachable daemon reads as a locked gate');
  fetchImpl = function () {
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ ok: true, authed: true, labToken: true, configured: true }); } });
  };
  assert.strictEqual((await Y.session()).authed, true, 'an unlocked session is reported as such');

  // (4) Source-structure guards (non-tautological -- each fails if its guard is removed from common.js).
  assert.match(source, /function pathTail\(view\)[\s\S]*?typeof view\.permalink !== 'string'/, 'pathTail guards a non-string permalink');
  assert.match(source, /rawURL\(view\)[\s\S]*?tail === null \? null/, 'rawURL propagates pathTail null');
  assert.match(source, /stashApiURL\(view\)[\s\S]*?tail === null \? null/, 'stashApiURL propagates pathTail null');
  assert.match(source, /if \(paused && paused\(\)\)[\s\S]*?return;[\s\S]*?countdown = Math\.max/, 'a paused page parks the countdown before it ticks down to a refresh');
  assert.match(source, /async api\(path, opts\)[\s\S]*?new AbortController\(\)/, 'api bounds the fetch with an AbortController');
  assert.match(source, /humanSize\(n\)[\s\S]*?Number\.isFinite\(v\)/, 'humanSize guards non-finite sizes');
  assert.match(source, /Y\.session = async function[\s\S]*?await Y\.proofUnlock/, 'session spends a carried proof BEFORE reading the gate, so an arriving operator is not prompted for a code they do not need');

  // (5) The control-proof handoff. A page reached from the Yuruna hosts
  // dashboard carries the proof in the fragment; it is spent once, at load, and
  // stripped from the address bar so it cannot be re-used out of history or a
  // copied URL. A page with no fragment must send nothing at all.
  const spent = loadWithHash('#yctl=1900000000.QUJD');
  assert.strictEqual(await spent.Y.proofUnlock, true, 'a carried proof unlocks the page');
  assert.strictEqual(spent.posts.length, 1, 'a carried proof is spent exactly once');
  assert.strictEqual(spent.posts[0].path, '/api/unlock-proof', 'the proof goes to the unlock route');
  assert.deepStrictEqual(JSON.parse(spent.posts[0].body), { proof: '1900000000.QUJD' }, 'the proof is sent verbatim');
  assert.strictEqual(spent.replaced, 1, 'the fragment is stripped from the address bar, so it cannot be re-used from history');

  const clean = loadWithHash('');
  assert.strictEqual(await clean.Y.proofUnlock, false, 'no fragment, no unlock attempt');
  assert.deepStrictEqual(clean.posts, [], 'a page with no proof sends nothing');

  console.log('PASS: common.js');
})().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
