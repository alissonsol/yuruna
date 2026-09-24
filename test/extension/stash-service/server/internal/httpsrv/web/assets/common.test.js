// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
/*
  Framework-free checks for the browser runtime this page set is built on. Run:
  node common.test.js (exit 0 = pass). There is no JS test runner in the repo,
  so this uses the Node built-in assert + vm modules with a minimal shim.

  Two files are loaded, in the order a page loads them: the shared runtime from
  extension-sdk/webui/assets/yuruna.core.js, then this directory's common.js on
  top of it. Loading common.js alone would fail the way a page missing its
  <script> tag fails, which is itself worth knowing.

  Covers:
    - pathTail guards a missing/non-string permalink and rawURL/downloadURL/stashApiURL
      propagate the null, so a malformed row drops its link (and never issues a DELETE at
      a guessed path) instead of crashing every row's render;
    - Y.api bounds the fetch with a timeout, clears it once the call settles, and
      rejects with a message a page can show rather than the browser's own;
    - Y.api serializes a plain object as JSON but hands FormData over untouched,
      so a multipart upload keeps the boundary the daemon parses the file from;
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
// The shared runtime, four directories up in the SDK. Its path is spelled out
// rather than discovered so this test fails loudly if the layout moves, instead
// of quietly checking a copy that is no longer the one pages load.
const coreFile = path.join(__dirname, '..', '..', '..', '..', '..', '..',
  'extension-sdk', 'webui', 'assets', 'yuruna.core.js');
const coreSource = fs.readFileSync(coreFile, 'utf8');

function makeElement() {
  return {
    setAttribute: function () {}, removeAttribute: function () {}, addEventListener: function () {},
    appendChild: function () {}, insertBefore: function () {}, removeChild: function () {},
    querySelector: function () { return null; }, querySelectorAll: function () { return []; },
    style: {}, textContent: '', className: '', firstChild: null
  };
}

// newPage builds one browser's worth of globals and runs the two scripts in the
// order a page's <script> tags do. Each call is a fresh page: the proof exchange
// and the memoized host read both happen once per load, so sharing a context
// between cases would let one case observe another's.
function newPage(opts) {
  opts = opts || {};
  const box = {
    console: console,
    document: {
      createElement: makeElement,
      getElementById: function () { return null; },
      addEventListener: function () {},
      readyState: 'complete',
      title: 't',
      body: null
    },
    location: {
      origin: 'https://stash.test', href: '',
      hash: opts.hash || '', pathname: '/s/h1/2026/07/06/abc', search: ''
    },
    history: { replaceState: function () { box.replaced++; } },
    AbortController: AbortController,
    FormData: FormData,
    Blob: Blob,
    URLSearchParams: URLSearchParams,
    XMLHttpRequest: function () {},
    replaced: 0,
    timersSet: 0,
    timersCleared: 0,
    posts: []
  };
  box.fetch = function (p, o) {
    box.posts.push({ path: p, body: o && o.body, init: o });
    return box.fetchImpl(p, o);
  };
  box.fetchImpl = opts.fetchImpl || function () { return Promise.reject(new Error('fetch not configured')); };
  box.setTimeout = function (fn, ms) { box.timersSet++; return setTimeout(fn, ms); };
  box.clearTimeout = function (t) { box.timersCleared++; return clearTimeout(t); };
  box.setInterval = function () { return 0; };
  box.clearInterval = function () {};
  box.localStorage = { getItem: function () { return null; }, setItem: function () {}, removeItem: function () {} };
  // The scripts address the browser through `window`, so it has to be the
  // context itself -- a separate object would give the runtime a different
  // setTimeout from the one this test counts.
  box.window = box;
  box.globalThis = box;
  vm.createContext(box);
  vm.runInContext(coreSource, box, { filename: 'yuruna.core.js' });
  vm.runInContext(source, box, { filename: 'common.js' });
  return box;
}

// Values built inside the vm carry that context's Object.prototype, so
// deepStrictEqual -- which compares prototypes -- rejects them against a
// host-realm literal however identical the contents. plain() re-creates the
// value in this realm so the assertion compares what it means to compare.
function plain(v) { return JSON.parse(JSON.stringify(v)); }

const page = newPage();
const Y = page.Y;
assert.ok(Y && typeof Y.api === 'function', 'Y with api should be exposed after both scripts load');

// Named for what the original harness called them, so the cases below read the
// same way they did before the runtime was split out.
function setFetch(fn) { page.fetchImpl = fn; }

// loadWithHash is a fresh page whose URL carries a proof fragment, so the
// load-time exchange can be observed end to end.
function loadWithHash(hash) {
  const box = newPage({
    hash: hash,
    fetchImpl: function () {
      return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ ok: true }); } });
    }
  });
  return {
    Y: box.Y,
    posts: box.posts,
    sandbox: box,
    get replaced() { return box.replaced; }
  };
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
  assert.deepStrictEqual(plain(Y.stashKey({ hostId: 'h1', permalink: '/s/h1/2026/07/06/abc' })),
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
  setFetch(function (p, o) {
    return new Promise(function (_resolve, reject) {
      o.signal.addEventListener('abort', function () { const e = new Error('aborted'); e.name = 'AbortError'; reject(e); });
    });
  });
  // The rejection an operator reads, not the browser's own wording: a caller
  // renders e.message straight into a notice, and "The operation was aborted"
  // describes the mechanism rather than what happened.
  await assert.rejects(function () { return Y.api('/slow', { timeoutMs: 20 }); },
    /took too long/, 'api gives up on a stalled request and says so in words a caller can show');

  // (3b) api returns the parsed body on success and clears its timeout (no leaked timer).
  const setBefore = page.timersSet, clearBefore = page.timersCleared;
  setFetch(function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ value: 7 }); } }); });
  const body = await Y.api('/ok', { timeoutMs: 60000 });
  assert.deepStrictEqual(plain(body), { value: 7 }, 'api returns the parsed body on success');
  assert.strictEqual(page.timersSet - setBefore, 1, 'api arms exactly one timeout');
  assert.strictEqual(page.timersCleared - clearBefore, 1, 'api clears its timeout on success');

  // (3b-ii) A plain object body is serialized and labeled JSON; a FormData one
  // is handed over untouched and unlabeled, because only the browser can name
  // the multipart boundary the daemon parses the uploaded file out of.
  const before = page.posts.length;
  await Y.api('/json', { method: 'POST', body: { a: 1 } });
  const jsonPost = page.posts[page.posts.length - 1];
  assert.strictEqual(jsonPost.body, '{"a":1}', 'a plain object body is serialized as JSON');
  assert.strictEqual(jsonPost.init.headers['Content-Type'], 'application/json', 'and labeled as JSON');
  const form = new FormData();
  form.append('f', 'x');
  await Y.api('/upload', { method: 'POST', body: form });
  const formPost = page.posts[page.posts.length - 1];
  assert.strictEqual(formPost.body, form, 'a FormData body is passed through untouched');
  assert.ok(!formPost.init.headers['Content-Type'], 'and carries no Content-Type of ours');
  assert.strictEqual(page.posts.length - before, 2, 'both bodies went out as one request each');

  // (3c) hostInfo is shared and non-rejecting: every consumer of the host facts
  // (header, footer, and a page deciding whether to offer delete) costs one
  // request between them, a failed read resolves to {} rather than throwing, and
  // that failure is NOT memoized -- controls derived from it must be able to
  // come back without a page reload.
  let hostinfoCalls = 0;
  setFetch(function () { hostinfoCalls++; return Promise.reject(new Error('daemon down')); });
  assert.deepStrictEqual(plain(await Y.hostInfo()), {}, 'a failed hostInfo read resolves to {}');
  setFetch(function () {
    hostinfoCalls++;
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ ok: true, localHostId: 'h1', version: '9.9' }); } });
  });
  const facts = await Y.hostInfo();
  assert.strictEqual(facts.localHostId, 'h1', 'hostInfo returns the parsed body');
  assert.strictEqual((await Y.hostInfo()).version, '9.9', 'a later caller gets the same answer');
  assert.strictEqual(hostinfoCalls, 2, 'the failure was retried; the success is shared');

  // (3d) Y.session never rejects: a daemon that cannot be asked reports a
  // locked, unconfigured gate, which is what makes a page withhold its delete
  // controls rather than offer ones it cannot vouch for.
  setFetch(function () { return Promise.reject(new Error('daemon down')); });
  assert.deepStrictEqual(plain(await Y.session()), { authed: false, labToken: false, configured: false },
    'an unreachable daemon reads as a locked gate');
  setFetch(function () {
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ ok: true, authed: true, labToken: true, configured: true }); } });
  });
  assert.strictEqual((await Y.session()).authed, true, 'an unlocked session is reported as such');

  // (4) Source-structure guards, each against the file that now holds the code
  // (non-tautological -- each fails if its guard is removed).
  assert.match(source, /function pathTail\(view\)[\s\S]*?typeof view\.permalink !== 'string'/, 'pathTail guards a non-string permalink');
  assert.match(source, /Y\.rawURL = function[\s\S]*?tail === null \? null/, 'rawURL propagates pathTail null');
  assert.match(source, /Y\.stashApiURL = function[\s\S]*?tail === null \? null/, 'stashApiURL propagates pathTail null');
  assert.match(source, /Y\.session = function[\s\S]*?Y\.proofUnlock\.then/, 'session spends a carried proof BEFORE reading the gate, so an arriving operator is not prompted for a code they do not need');
  assert.match(coreSource, /if \(paused && paused\(\)\)[\s\S]*?return;[\s\S]*?countdown = Math\.max/, 'a paused page parks the countdown before it ticks down to a refresh');
  assert.match(coreSource, /Y\.api = function[\s\S]*?AbortController/, 'api bounds the fetch and cancels it when the bound is reached');
  assert.match(coreSource, /Y\.humanSize = function[\s\S]*?Number\.isFinite\(v\)/, 'humanSize guards non-finite sizes');

  // (5) The control-proof handoff. A page reached from the Yuruna hosts
  // dashboard carries the proof in the fragment; it is spent once, at load, and
  // stripped from the address bar so it cannot be reused out of history or a
  // copied URL. A page with no fragment must send nothing at all.
  // Counted by route, not by total: a loading page also reads /api/hostinfo for
  // its header and footer, and that read is not what is under test here.
  const unlockPosts = function (page) {
    return page.posts.filter(function (p) { return p.path === '/api/unlock-proof'; });
  };

  const spent = loadWithHash('#yctl=1900000000.QUJD');
  assert.strictEqual(await spent.Y.proofUnlock, true, 'a carried proof unlocks the page');
  assert.strictEqual(unlockPosts(spent).length, 1, 'a carried proof is spent exactly once');
  assert.deepStrictEqual(JSON.parse(unlockPosts(spent)[0].body), { proof: '1900000000.QUJD' }, 'the proof is sent verbatim');
  assert.strictEqual(spent.replaced, 1, 'the fragment is stripped from the address bar, so it cannot be reused from history');

  const clean = loadWithHash('');
  assert.strictEqual(await clean.Y.proofUnlock, false, 'no fragment, no unlock attempt');
  assert.deepStrictEqual(unlockPosts(clean), [], 'a page with no proof spends nothing');

  console.log('PASS: yuruna.core.js + common.js');
})().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
