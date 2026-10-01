/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.09.30

  Framework-free checks for the host-refresh, start-cycle and diagnostics
  flows in test/status/yuruna.common.js. Run: node host-refresh.test.js
  (exit 0 = pass).

  The page script is loaded into a vm context with a small DOM, a scripted
  fetch router, a manual timer queue and a controllable clock, so every poll,
  every wait and every reply can be driven one step at a time. The catalog
  seam is replaced by one that echoes the key and its arguments: these checks
  are about which message a state produces, not about its English.
*/
'use strict';
var fs = require('fs');
var vm = require('vm');
var assert = require('assert');
var path = require('path');
var nodeCrypto = require('crypto');

var src = fs.readFileSync(path.join(__dirname, 'yuruna.common.js'), 'utf8');
var ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function makeEl(id, hidden) {
  var el = {
    id: id, textContent: '', innerHTML: '', className: '', hidden: !!hidden, disabled: false, value: '', style: {},
    listeners: {},
    addEventListener: function (type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    removeEventListener: function () {},
    click: function () { (this.listeners.click || []).forEach(function (fn) { fn({}); }); },
    setAttribute: function (name, value) { this['attr:' + name] = String(value); },
    getAttribute: function (name) { var v = this['attr:' + name]; return (v === undefined) ? null : v; },
    removeAttribute: function (name) { delete this['attr:' + name]; },
    querySelector: function () { return null; }, querySelectorAll: function () { return []; },
    appendChild: function () {}, contains: function () { return false; },
    classList: { add: function () {}, remove: function () {}, toggle: function () {}, contains: function () { return false; } }
  };
  return el;
}

// One page environment. route(url, init, call) answers each fetch with
// {status, body, headers} or {pending: true} (resolved later with release()).
function createEnv(opts) {
  var clock = { now: opts.startMs || 1790000000000 };
  var timers = [];
  var nextTimer = 1;
  var calls = [];
  var marks = [];
  var measures = [];
  var confirms = [];
  var store = {};
  var ids = opts.ids || [];
  var elements = {};
  ids.forEach(function (id) { elements[id] = makeEl(id, id === 'host-refresh' || id === 'host-refresh-retry'); });

  function FakeDate() {
    var args = Array.prototype.slice.call(arguments);
    if (args.length === 0) { return new Date(clock.now); }
    return new (Function.prototype.bind.apply(Date, [null].concat(args)))();
  }
  FakeDate.now = function () { return clock.now; };
  FakeDate.parse = Date.parse;
  FakeDate.UTC = Date.UTC;
  FakeDate.prototype = Date.prototype;

  function respond(spec) {
    var status = spec.status || 200;
    var headers = spec.headers || {};
    var body = spec.body;
    return {
      ok: status >= 200 && status < 300, status: status,
      headers: { get: function (name) { return headers[name] || headers[name.toLowerCase()] || null; } },
      text: function () { return Promise.resolve(typeof body === 'string' ? body : JSON.stringify(body)); },
      json: function () { return Promise.resolve().then(function () { return typeof body === 'string' ? JSON.parse(body) : body; }); }
    };
  }
  function fetchShim(url, init) {
    var call = { url: String(url), init: init || {}, storedAtCall: store.yurunaHostRefresh };
    calls.push(call);
    var spec = opts.route(call.url.replace(/\?_=\d+$/, ''), call.init, call) || { status: 404, body: '' };
    if (spec.pending) {
      return new Promise(function (resolve) { call.release = function (later) { resolve(respond(later)); }; });
    }
    if (spec.reject) { return Promise.reject(new Error(spec.reject)); }
    return Promise.resolve(respond(spec));
  }

  var documentShim = {
    readyState: opts.boot ? 'complete' : 'loading', hidden: false, title: '',
    documentElement: makeEl('html'),
    getElementById: function (id) { return elements[id] || null; },
    createElement: function (tag) { return makeEl(tag); },
    addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; },
    body: makeEl('body')
  };
  documentShim.documentElement.setAttribute('lang', 'en-US');
  documentShim.documentElement.setAttribute('dir', 'ltr');
  var windowShim = {
    location: { hostname: 'lab', href: 'http://lab:8080/status/config.html', search: '', pathname: '/status/config.html', hash: '', port: '8080', replace: function (u) { windowShim.replaced = u; } },
    history: { replaceState: function () {} },
    navigator: { userAgent: 'node' },
    localStorage: opts.noStorage ? {
      getItem: function () { throw new Error('denied'); }, setItem: function () { throw new Error('denied'); }, removeItem: function () { throw new Error('denied'); }
    } : {
      getItem: function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
      setItem: function (k, v) { store[k] = String(v); }, removeItem: function (k) { delete store[k]; }
    },
    sessionStorage: { getItem: function () { return null; }, setItem: function () {}, removeItem: function () {} },
    crypto: { getRandomValues: function (a) { var b = nodeCrypto.randomBytes(a.length); for (var i = 0; i < a.length; i++) { a[i] = b[i]; } return a; } },
    confirm: function (message) { confirms.push(message); return opts.confirm !== false; },
    addEventListener: function () {}, removeEventListener: function () {},
    YurunaFirstUsable: {
      hold: function () {}, release: function () {},
      measure: function (page, state, callback) { measures.push(state); return callback(); },
      mark: function (page, state) { marks.push(state); }
    }
  };
  var sandbox = {
    window: windowShim, document: documentShim, console: { log: function () {}, warn: function () {}, error: function () {} },
    fetch: fetchShim, Date: FakeDate, Uint8Array: Uint8Array, JSON: JSON, Math: Math, Promise: Promise,
    setTimeout: function (fn, ms) { var id = nextTimer++; timers.push({ id: id, at: clock.now + (ms || 0), fn: fn }); return id; },
    clearTimeout: function (id) { timers = timers.filter(function (x) { return x.id !== id; }); },
    setInterval: function () { return 0; }, clearInterval: function () {}
  };
  Object.keys(windowShim).forEach(function (k) { if (!(k in sandbox)) { sandbox[k] = windowShim[k]; } });
  windowShim.fetch = fetchShim;
  windowShim.setTimeout = sandbox.setTimeout;
  windowShim.clearTimeout = sandbox.clearTimeout;
  windowShim.setInterval = sandbox.setInterval;
  windowShim.document = documentShim;
  sandbox.window = sandbox;
  Object.keys(windowShim).forEach(function (k) { sandbox[k] = windowShim[k]; });
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'yuruna.common.js' });
  // Echo the key and its arguments so a check can see which message, and
  // with what, a state produced.
  sandbox.YurunaI18n.t = function (key, args) { return key + (args ? ' ' + JSON.stringify(args) : ''); };
  if (opts.stored) { store.yurunaHostRefresh = JSON.stringify(opts.stored); }

  function settle() {
    var chain = Promise.resolve();
    for (var i = 0; i < 30; i++) { chain = chain.then(function () { return new Promise(function (r) { setImmediate(r); }); }); }
    return chain;
  }
  // Run every timer due within ms, in time order, settling promises between.
  function advance(ms) {
    var target = clock.now + ms;
    function step() {
      timers.sort(function (a, b) { return a.at - b.at; });
      var due = timers.length && timers[0].at <= target ? timers.shift() : null;
      if (!due) { clock.now = target; return settle(); }
      clock.now = Math.max(clock.now, due.at);
      due.fn();
      return settle().then(step);
    }
    return settle().then(step);
  }
  return {
    box: sandbox, Y: sandbox.Yuruna, byId: elements, calls: calls, marks: marks, measures: measures, confirms: confirms, store: store,
    clock: clock, settle: settle, advance: advance,
    fetched: function (fragment) { return calls.filter(function (c) { return c.url.indexOf(fragment) !== -1; }); }
  };
}

var HR_IDS = ['host-refresh', 'host-refresh-title', 'host-refresh-note', 'host-refresh-start', 'host-refresh-retry', 'host-refresh-status'];
function capabilityReply(refresh) { return { status: 200, body: refresh === undefined ? { ok: true } : { ok: true, refresh: refresh } }; }
var AVAILABLE = { protocol: 1, availability: 'available', ceiling: 'start-if-stopped', reason: '', remote: 'missing', state: 'idle' };
function isoAt(ms) { return new Date(ms).toISOString(); }

var checks = [];
function check(name, fn) { checks.push({ name: name, fn: fn }); }

// --- REGION: Pure helpers
check('mints canonical version-4 request ids from getRandomValues', function () {
  var env = createEnv({ route: function () { return null; } });
  var seen = {};
  for (var i = 0; i < 50; i++) {
    var id = env.Y.newRequestId();
    assert.ok(ID_RE.test(id), 'not canonical: ' + id);
    assert.strictEqual(id.charAt(14), '4', 'version nibble');
    assert.ok('89ab'.indexOf(id.charAt(19)) !== -1, 'variant nibble');
    assert.ok(!seen[id]); seen[id] = true;
  }
  assert.ok(!/\.randomUUID\s*\(/.test(src), 'randomUUID exists only in a secure context and must not be called');
});

check('judges staleness from the server clock with the heartbeat, step bound and skew allowances', function () {
  var env = createEnv({ route: function () { return null; } });
  var hb = Date.UTC(2026, 8, 25, 12, 0, 0);
  var state = { heartbeatUtc: new Date(hb).toISOString(), step: { boundMs: 60000 } };
  assert.strictEqual(env.Y.hostRefreshIsStale(state, hb + 85000, 0), false, 'inside 15 s + 60 s bound + 10 s skew');
  assert.strictEqual(env.Y.hostRefreshIsStale(state, hb + 85001, 0), true, 'past the allowance');
  assert.strictEqual(env.Y.hostRefreshIsStale(state, NaN, hb + 90000), true, 'the client clock is the fallback');
  assert.strictEqual(env.Y.hostRefreshIsStale({ heartbeatUtc: new Date(hb).toISOString() }, hb + 26000, 0), true, 'no step bound: 25 s allowance');
  assert.strictEqual(env.Y.hostRefreshIsStale({ heartbeatUtc: 'garbage' }, hb + 999999, 0), false);
  assert.strictEqual(env.Y.hostRefreshIsStale(null, hb, hb), false);
});

check('maps every verdict to its own message and anything else to the unknown one', function () {
  var env = createEnv({ route: function () { return null; } });
  ['repaired', 'already_healthy', 'refused', 'failed', 'partial', 'still_unresponsive', 'abandoned'].forEach(function (v) {
    assert.strictEqual(env.Y.hostRefreshVerdictKey(v), 'status.host_refresh_verdict_' + v);
  });
  ['already-healthy', 'preview', '', undefined, 'REPAIRED'].forEach(function (v) {
    assert.strictEqual(env.Y.hostRefreshVerdictKey(v), 'status.host_refresh_verdict_unknown');
  });
});

check('reads a start-cycle record as waiting unless it is this operation and completed', function () {
  var env = createEnv({ route: function () { return null; } });
  var O = env.Y.startCycleOutcome;
  assert.strictEqual(O(null, 'a').kind, 'waiting');
  assert.strictEqual(O({ operationId: 'b', phase: 'completed', action: 'spawned' }, 'a').kind, 'waiting', 'another operation is never this outcome');
  assert.strictEqual(O({ operationId: 'a', phase: 'cleanup' }, 'a').kind, 'waiting');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(O({ operationId: 'a', phase: 'completed', result: 'succeeded', action: 'spawned' }, 'a'))), { kind: 'started', action: 'spawned', key: '', reason: '' });
  assert.strictEqual(O({ operationId: 'a', phase: 'completed', result: 'incomplete', action: 'restarted', reason: 'cleanup_failed' }, 'a').kind, 'started');
  assert.strictEqual(O({ operationId: 'a', phase: 'completed', result: 'incomplete', action: 'not_spawned', reason: 'runner_unknown' }, 'a').key, 'status.start_cycle_not_spawned');
  var failed = O({ operationId: 'a', phase: 'completed', result: 'failed', reason: 'lock_busy' }, 'a');
  assert.strictEqual(failed.key, 'status.start_cycle_failed');
  assert.strictEqual(failed.reason, 'lock_busy');
});

check('follows the queued start-cycle and keeps no English literal for its outcome', function () {
  // The generated catalog block carries the English messages themselves, so
  // only the hand-written code outside it must be free of the literal words.
  var handWritten = src.replace(/\/\/ >>> yuruna-i18n embedded block[\s\S]*?\/\/ <<< yuruna-i18n embedded block/g, '');
  assert.ok(handWritten.length < src.length, 'the embedded catalog block was found and set aside');
  assert.ok(!/['"]Runner started['"]|['"]Cycle restarted['"]/.test(handWritten), 'the outcome words come from the catalog');
  assert.match(src, /body\.action === 'queued' && body\.operationId/, 'a queued reply is followed');
  assert.match(src, /body\.activeKind === 'start_cycle' && body\.activeRequestId/, 'a busy start-cycle is adopted');
  assert.match(src, /status\.start_cycle_blocked_by_refresh/, 'a busy host refresh is explained');
});

// --- REGION: The host-refresh control
check('stays hidden and posts nothing for an old server, a newer protocol or an unavailable capability', function () {
  var cases = [undefined, { protocol: 2, availability: 'available', ceiling: 'reclaim' }, { protocol: 1, availability: 'unavailable', ceiling: '', reason: 'no_qualified_rung' }];
  return cases.reduce(function (chain, refresh) {
    return chain.then(function () {
      var env = createEnv({ ids: HR_IDS, route: function (url) { return url.indexOf('control/control-status') === 0 ? capabilityReply(refresh) : null; } });
      env.Y.bootHostRefresh();
      return env.settle().then(function () {
        assert.strictEqual(env.byId['host-refresh'].hidden, true, 'hidden for ' + JSON.stringify(refresh));
        assert.strictEqual(env.byId['host-refresh-title'].textContent, '', 'a hidden section renders no text');
        env.byId['host-refresh-start'].click();
        return env.settle();
      }).then(function () {
        assert.strictEqual(env.fetched('control/host-refresh').length, 0, 'no POST without an available capability');
      });
    });
  }, Promise.resolve());
});

check('confirms the ceiling, stores the id before the POST and sends exactly the three keys', function () {
  var env = createEnv({ ids: HR_IDS, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url === 'control/host-refresh') {
      var sent = JSON.parse(init.body);
      return { status: 202, body: { ok: true, requestId: sent.requestId, action: 'spawned', ceiling: sent.maxRung, stateUrl: '/runtime/host-refresh.state.json' } };
    }
    return { status: 404, body: '' };
  } });
  env.Y.bootHostRefresh();
  return env.settle().then(function () {
    assert.strictEqual(env.byId['host-refresh'].hidden, false);
    assert.strictEqual(env.byId['host-refresh-start'].disabled, false);
    assert.strictEqual(env.byId['host-refresh-start'].textContent, 'status.host_refresh_start');
    env.byId['host-refresh-start'].click();
    return env.settle();
  }).then(function () {
    assert.strictEqual(env.confirms.length, 1);
    assert.match(env.confirms[0], /^status\.host_refresh_confirm .*"ceiling":"start-if-stopped"/);
    var post = env.fetched('control/host-refresh')[0];
    assert.ok(post, 'the request was posted');
    var sent = JSON.parse(post.init.body);
    assert.deepStrictEqual(Object.keys(sent).sort(), ['maxRung', 'requestId', 'tier']);
    assert.ok(ID_RE.test(sent.requestId));
    assert.strictEqual(sent.tier, 'restart');
    assert.strictEqual(sent.maxRung, 'start-if-stopped');
    assert.strictEqual(post.init.headers['X-Yuruna'], '1');
    assert.strictEqual(post.init.headers['Content-Type'], 'application/json');
    assert.ok(post.storedAtCall && JSON.parse(post.storedAtCall).id === sent.requestId, 'the id was stored before the POST');
  });
});

check('polls every three seconds without overlap and never reads a 404 or another request as success', function () {
  var myId = null;
  var stateReplies = [];
  var env = createEnv({ ids: HR_IDS, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url === 'control/host-refresh') { myId = JSON.parse(init.body).requestId; return { status: 202, body: { ok: true, requestId: myId, action: 'spawned', ceiling: 'start-if-stopped' } }; }
    if (url.indexOf('/runtime/host-refresh.state.json') === 0) { return stateReplies.shift() || { status: 404, body: '' }; }
    return null;
  } });
  env.Y.bootHostRefresh();
  return env.settle().then(function () {
    env.byId['host-refresh-start'].click();
    stateReplies.push({ status: 404, body: '' });
    return env.advance(0);
  }).then(function () {
    assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, 1, 'the first poll follows the accepted reply');
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_waiting /);
    stateReplies.push({ status: 200, body: { requestId: '00000000-0000-4000-8000-000000000000', phase: 'terminal', state: 'completed', verdict: 'repaired' } });
    return env.advance(2999);
  }).then(function () {
    assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, 1, 'no poll before three seconds');
    return env.advance(1);
  }).then(function () {
    assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, 2);
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_waiting /, "another request's success is not this one's");
    stateReplies.push({ pending: true });
    return env.advance(3000);
  }).then(function () {
    var pending = env.fetched('/runtime/host-refresh.state.json');
    assert.strictEqual(pending.length, 3);
    return env.advance(15000).then(function () {
      assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, 3, 'a poll in flight is never overlapped');
      var nowMs = env.clock.now;
      pending[2].release({ status: 200, headers: { Date: new Date(nowMs).toUTCString() }, body: {
        requestId: myId, phase: 'climbing', state: 'running', heartbeatUtc: isoAt(nowMs - 1000), step: { index: 2, count: 5, name: 'reclaim', boundMs: 60000 }, remainingBudgetMs: 540000 } });
      return env.settle();
    });
  }).then(function () {
    var text = env.byId['host-refresh-status'].textContent;
    assert.match(text, /^status\.host_refresh_progress /);
    assert.match(text, /"step":2/); assert.match(text, /"count":5/); assert.match(text, /"stepName":"reclaim"/); assert.match(text, /"remainingSeconds":540/);
    assert.strictEqual(env.byId['host-refresh-start'].disabled, true, 'no second request while one is followed');
    var serverNow = env.clock.now + 3000;
    stateReplies.push({ status: 200, headers: { Date: new Date(serverNow).toUTCString() }, body: {
      requestId: myId, phase: 'climbing', state: 'running', heartbeatUtc: isoAt(serverNow - 86000), step: { index: 3, count: 5, name: 'restart-if-hung', boundMs: 60000 } } });
    return env.advance(3000);
  }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_stale /, 'stale by the server clock');
    stateReplies.push({ status: 200, body: { requestId: myId, phase: 'terminal', state: 'completed', verdict: 'repaired', reasonCodes: [] } });
    return env.advance(3000);
  }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_verdict_repaired /);
    assert.strictEqual(env.byId['host-refresh-status'].className, 'host-refresh-status ok');
    assert.strictEqual(env.store.yurunaHostRefresh, undefined, 'a terminal request is forgotten');
    var polls = env.fetched('/runtime/host-refresh.state.json').length;
    return env.advance(30000).then(function () {
      assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, polls, 'polling stops at the terminal state');
      assert.strictEqual(env.byId['host-refresh-start'].disabled, false);
    });
  });
});

check('keeps a recovery-pending request for Retry and names the operator action', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var env = createEnv({ ids: HR_IDS, stored: { id: id, ceiling: 'start-if-stopped', acceptedMs: 1, observe: false }, route: function (url) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url.indexOf('/runtime/host-refresh.state.json') === 0) {
      return { status: 200, body: { requestId: id, phase: 'terminal', state: 'recovery_pending', verdict: 'partial', reasonCodes: ['service_unrestored'], operatorAction: 'resume_request' } };
    }
    if (url === 'control/host-refresh') { return { status: 202, body: { ok: true, requestId: id, action: 'spawned', ceiling: 'start-if-stopped' } }; }
    return null;
  } });
  env.Y.bootHostRefresh();
  return env.advance(10).then(function () {
    assert.strictEqual(env.fetched('control/host-refresh').length, 0, 'a stored request is followed on load, never resent');
    var text = env.byId['host-refresh-status'].textContent;
    assert.match(text, /status\.host_refresh_verdict_partial .*"reason":"service_unrestored"/);
    assert.match(text, /status\.host_refresh_action_resume_request/);
    assert.match(text, /status\.host_refresh_recovery_pending/);
    assert.match(text, /status\.host_refresh_check_host/);
    assert.strictEqual(env.byId['host-refresh-retry'].hidden, false);
    assert.strictEqual(JSON.parse(env.store.yurunaHostRefresh).id, id, 'the id is kept for Retry');
    env.byId['host-refresh-retry'].click();
    return env.settle();
  }).then(function () {
    var post = env.fetched('control/host-refresh')[0];
    assert.ok(post);
    assert.strictEqual(JSON.parse(post.init.body).requestId, id, 'Retry resends the same request');
  });
});

check('renders a completed replay by its verdict, partial included', function () {
  var env = createEnv({ ids: HR_IDS, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url === 'control/host-refresh') { var id = JSON.parse(init.body).requestId; return { status: 200, body: { ok: true, requestId: id, action: 'completed', state: 'completed', verdict: 'partial' } }; }
    return null;
  } });
  env.Y.bootHostRefresh();
  return env.settle().then(function () { env.byId['host-refresh-start'].click(); return env.settle(); }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_verdict_partial /, 'ok:true with a partial verdict is not success');
    assert.strictEqual(env.byId['host-refresh-status'].className, 'host-refresh-status error');
    assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, 0, 'a replay needs no polling');
  });
});

check('adopts a busy refresh, offers Retry after a failed launch and explains a proof refusal', function () {
  var active = '7d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a';
  var replies = [
    { status: 409, body: { ok: false, reason: 'busy', activeKind: 'host_refresh', activeRequestId: active, stateUrl: '/runtime/host-refresh.state.json' } },
    { status: 503, body: { ok: false, reason: 'launcher_failed', requestId: 'x' } },
    { status: 403, body: { ok: false, code: 'status.api_host_refresh_authorization_refused', reason: 'refresh_proof_missing' } }
  ];
  function run(reply) {
    var env = createEnv({ ids: HR_IDS, route: function (url) {
      if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
      if (url === 'control/host-refresh') { return reply; }
      if (url.indexOf('/runtime/host-refresh.state.json') === 0) { return { status: 404, body: '' }; }
      return null;
    } });
    env.Y.bootHostRefresh();
    return env.settle().then(function () { env.byId['host-refresh-start'].click(); return env.advance(10); }).then(function () { return env; });
  }
  return run(replies[0]).then(function (env) {
    var stored = JSON.parse(env.store.yurunaHostRefresh);
    assert.strictEqual(stored.id, active, 'the busy request is followed');
    assert.strictEqual(stored.observe, true);
    assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, 1);
    return run(replies[1]);
  }).then(function (env) {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_launcher_failed/);
    assert.strictEqual(env.byId['host-refresh-retry'].hidden, false);
    var firstId = JSON.parse(env.fetched('control/host-refresh')[0].init.body).requestId;
    env.byId['host-refresh-retry'].click();
    return env.settle().then(function () {
      assert.strictEqual(JSON.parse(env.fetched('control/host-refresh')[1].init.body).requestId, firstId, 'Retry keeps the queued id');
      return run(replies[2]);
    });
  }).then(function (env) {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_authorization_refused .*refresh_proof_missing/);
    assert.strictEqual(env.store.yurunaHostRefresh, undefined);
    env.fetched('/runtime/host-refresh.state.json').forEach(function (poll) {
      assert.ok(!poll.init.headers || !poll.init.headers['X-Yuruna-Control'], 'polling carries no proof');
    });
  });
});

check('calls a request superseded only by another request that ended after it was accepted', function () {
  var env = createEnv({ route: function () { return null; } });
  var S = env.Y.hostRefreshSuperseded;
  var mine = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var other = '7d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a';
  var accepted = Date.UTC(2026, 8, 25, 12, 0, 0);
  function terminalAt(ms, id) { return { requestId: id || other, phase: 'terminal', state: 'completed', verdict: 'repaired', terminalUtc: isoAt(ms) }; }
  assert.strictEqual(S(terminalAt(accepted + 10001), mine, accepted, NaN, accepted), true, 'ended past the skew allowance');
  assert.strictEqual(S(terminalAt(accepted + 10000), mine, accepted, NaN, accepted), false, 'inside the skew allowance');
  assert.strictEqual(S(terminalAt(accepted - 60000), mine, accepted, NaN, accepted), false, 'an older verdict still on file is not this request resolving');
  assert.strictEqual(S(terminalAt(accepted + 60000, mine), mine, accepted, NaN, accepted), false, "this request's own record is never superseding");
  assert.strictEqual(S({ requestId: other, phase: 'climbing', terminalUtc: isoAt(accepted + 60000) }, mine, accepted, NaN, accepted), false, 'another request still running');
  assert.strictEqual(S({ requestId: other, phase: 'terminal' }, mine, accepted, NaN, accepted), false, 'no end instant');
  assert.strictEqual(S(terminalAt(accepted + 60000), mine, 0, NaN, accepted), false, 'no acceptance instant');
  assert.strictEqual(S(null, mine, accepted, NaN, accepted), false);
  // The server clock runs five minutes ahead of this browser: a record that
  // ended one minute after acceptance (server time) is past it, and one
  // that ended before acceptance (server time) is not, whatever the local
  // clock says.
  var skew = 300000;
  assert.strictEqual(S(terminalAt(accepted + skew + 60000), mine, accepted, accepted + 5000 + skew, accepted + 5000), true);
  assert.strictEqual(S(terminalAt(accepted + skew - 60000), mine, accepted, accepted + 5000 + skew, accepted + 5000), false);
});

check('stops following a request whose record never appears, offers Retry, and stays unwedged across a reload', function () {
  var id = null;
  var posts = [];
  var env = createEnv({ ids: HR_IDS, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url === 'control/host-refresh') {
      var sent = JSON.parse(init.body);
      posts.push(sent.requestId);
      id = sent.requestId;
      return posts.length === 1
        ? { status: 202, body: { ok: true, requestId: id, action: 'spawned', ceiling: sent.maxRung } }
        : { status: 409, body: { ok: false, reason: 'request_closed', requestId: id, state: 'refused', verdict: 'refused' } };
    }
    // The worker died before its first report: the listener's queued
    // projection is all the file ever shows.
    if (url.indexOf('/runtime/host-refresh.state.json') === 0) { return { status: 200, body: { requestId: id, phase: 'queued', state: 'queued' } }; }
    return null;
  } });
  var accepted = 0;
  env.Y.bootHostRefresh();
  return env.settle().then(function () {
    env.byId['host-refresh-start'].click();
    return env.advance(10);
  }).then(function () {
    accepted = JSON.parse(env.store.yurunaHostRefresh).acceptedMs;
    assert.ok(accepted > 0);
    return env.advance(1070000);
  }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_waiting_long /, 'still waiting inside the longest worker budget');
    assert.strictEqual(env.byId['host-refresh-start'].disabled, true);
    return env.advance(15000);
  }).then(function () {
    var text = env.byId['host-refresh-status'].textContent;
    assert.match(text, /^status\.host_refresh_lost /, 'past the longest worker budget the request is lost to this page');
    assert.strictEqual(env.byId['host-refresh-status'].className, 'host-refresh-status error');
    assert.strictEqual(env.byId['host-refresh-retry'].hidden, false, 'Retry is offered');
    assert.strictEqual(env.byId['host-refresh-start'].disabled, false, 'Start is usable again');
    assert.strictEqual(JSON.parse(env.store.yurunaHostRefresh).id, id, 'the id is kept for Retry');
    var polls = env.fetched('/runtime/host-refresh.state.json').length;
    assert.ok(polls < 400, 'polls are bounded: ' + polls);
    return env.advance(600000).then(function () {
      assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, polls, 'polling stopped');
    });
  }).then(function () {
    // A reload with the same stored id: the first poll already knows the
    // request is lost, so the page never wedges again.
    var reloaded = createEnv({ ids: HR_IDS, startMs: env.clock.now, stored: JSON.parse(env.store.yurunaHostRefresh), route: function (url) {
      if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
      if (url.indexOf('/runtime/host-refresh.state.json') === 0) { return { status: 404, body: '' }; }
      return null;
    } });
    reloaded.Y.bootHostRefresh();
    return reloaded.advance(10).then(function () {
      assert.match(reloaded.byId['host-refresh-status'].textContent, /^status\.host_refresh_lost /);
      assert.strictEqual(reloaded.fetched('/runtime/host-refresh.state.json').length, 1, 'one poll, then stopped');
      assert.strictEqual(reloaded.byId['host-refresh-start'].disabled, false);
      assert.strictEqual(reloaded.byId['host-refresh-retry'].hidden, false);
      assert.strictEqual(reloaded.fetched('control/host-refresh').length, 0, 'nothing is resent without the operator');
    });
  }).then(function () {
    env.byId['host-refresh-retry'].click();
    return env.settle();
  }).then(function () {
    assert.deepStrictEqual(posts, [id, id], 'Retry re-sends the same id');
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_closed .*"state":"refused"/, "the host's own answer for the id is shown");
    assert.strictEqual(env.store.yurunaHostRefresh, undefined, 'a closed request is forgotten');
    assert.strictEqual(env.byId['host-refresh-start'].disabled, false);
  });
});

check('stops at once when a later request replaced the record, and Retry reads the replay', function () {
  var id = null;
  var other = '7d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a';
  var stateReplies = [];
  var env = createEnv({ ids: HR_IDS, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url === 'control/host-refresh') {
      var sent = JSON.parse(init.body);
      if (!id) { id = sent.requestId; return { status: 202, body: { ok: true, requestId: id, action: 'spawned', ceiling: sent.maxRung } }; }
      return { status: 200, body: { ok: true, requestId: sent.requestId, action: 'completed', state: 'completed', verdict: 'repaired', ceiling: sent.maxRung } };
    }
    if (url.indexOf('/runtime/host-refresh.state.json') === 0) { return stateReplies.shift() || { status: 404, body: '' }; }
    return null;
  } });
  var startedAt = env.clock.now;
  env.Y.bootHostRefresh();
  return env.settle().then(function () {
    // The previous request's verdict is still on file when this one is
    // accepted: that is waiting, not an outcome.
    stateReplies.push({ status: 200, headers: { Date: new Date(startedAt).toUTCString() }, body: {
      requestId: other, phase: 'terminal', state: 'completed', verdict: 'repaired', terminalUtc: isoAt(startedAt - 600000) } });
    env.byId['host-refresh-start'].click();
    return env.advance(10);
  }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_waiting /);
    stateReplies.push({ status: 200, body: { requestId: id, phase: 'climbing', state: 'running', heartbeatUtc: isoAt(env.clock.now), step: { index: 1, count: 3, name: 'probe', boundMs: 30000 } } });
    return env.advance(3000);
  }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_progress /);
    // This request finished while the tab was hidden, and a later request
    // ran and finished after it: its terminal record is all that is left.
    var later = env.clock.now + 120000;
    env.clock.now = later;
    stateReplies.push({ status: 200, headers: { Date: new Date(later + 3000).toUTCString() }, body: {
      requestId: other, phase: 'terminal', state: 'completed', verdict: 'already_healthy', terminalUtc: isoAt(later - 30000) } });
    return env.advance(3000);
  }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_lost /, "another request's later verdict ends the wait at once");
    assert.strictEqual(env.byId['host-refresh-retry'].hidden, false);
    assert.strictEqual(env.byId['host-refresh-start'].disabled, false);
    var polls = env.fetched('/runtime/host-refresh.state.json').length;
    return env.advance(30000).then(function () {
      assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, polls, 'polling stopped');
      env.byId['host-refresh-retry'].click();
      return env.settle();
    });
  }).then(function () {
    var posts = env.fetched('control/host-refresh');
    assert.strictEqual(posts.length, 2);
    assert.strictEqual(JSON.parse(posts[1].init.body).requestId, id, 'Retry asks about the same request');
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_verdict_repaired /, 'the replay gives this request its own verdict');
    assert.strictEqual(env.store.yurunaHostRefresh, undefined);
  });
});

check('bounds a request whose worker stopped reporting mid-run', function () {
  var id = null;
  var env = createEnv({ ids: HR_IDS, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url === 'control/host-refresh') { id = JSON.parse(init.body).requestId; return { status: 202, body: { ok: true, requestId: id, action: 'spawned', ceiling: 'start-if-stopped' } }; }
    if (url.indexOf('/runtime/host-refresh.state.json') === 0) {
      return { status: 200, body: { requestId: id, phase: 'climbing', state: 'running', heartbeatUtc: isoAt(1790000000000), step: { index: 2, count: 5, name: 'reclaim', boundMs: 60000 } } };
    }
    return null;
  } });
  env.Y.bootHostRefresh();
  return env.settle().then(function () { env.byId['host-refresh-start'].click(); return env.advance(600000); }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_stale /, 'a stopped heartbeat is stale while the budget could still be running');
    return env.advance(500000);
  }).then(function () {
    assert.match(env.byId['host-refresh-status'].textContent, /^status\.host_refresh_lost /, 'and lost once no budget could still be running');
    assert.strictEqual(env.byId['host-refresh-retry'].hidden, false);
    assert.strictEqual(env.byId['host-refresh-start'].disabled, false);
  });
});

check('keeps working without storage', function () {
  var env = createEnv({ ids: HR_IDS, noStorage: true, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return capabilityReply(AVAILABLE); }
    if (url === 'control/host-refresh') { var id = JSON.parse(init.body).requestId; return { status: 202, body: { ok: true, requestId: id, action: 'spawned' } }; }
    return { status: 404, body: '' };
  } });
  env.Y.bootHostRefresh();
  return env.settle().then(function () { env.byId['host-refresh-start'].click(); return env.advance(10); }).then(function () {
    assert.strictEqual(env.fetched('control/host-refresh').length, 1);
    assert.strictEqual(env.fetched('/runtime/host-refresh.state.json').length, 1, 'identity lasts for the page even when storage throws');
  });
});

// --- REGION: Diagnostics
check('follows a pending diagnostic until its report and marks first-usable once', function () {
  var replies = [
    { status: 202, body: { ok: true, action: 'pending', runId: 'r', retryAfterSeconds: 3 } },
    { status: 202, body: { ok: true, action: 'pending', runId: 'r', retryAfterSeconds: 3 } },
    { status: 200, body: 'host report' }
  ];
  var env = createEnv({ ids: ['diagnostics-output'], boot: true, route: function (url) {
    if (url.indexOf('control/host-diagnostic') === 0) { return replies.shift(); }
    return { status: 404, body: '' };
  } });
  var out = env.byId['diagnostics-output'];
  return env.settle().then(function () {
    assert.strictEqual(out.textContent, 'status.host_diagnostic_pending');
    assert.strictEqual(env.marks.length, 0, 'pending is not an outcome');
    return env.advance(3000);
  }).then(function () {
    assert.strictEqual(env.fetched('control/host-diagnostic').length, 2);
    return env.advance(3000);
  }).then(function () {
    assert.strictEqual(out.textContent, 'host report');
    assert.deepStrictEqual(env.marks, ['data']);
    assert.deepStrictEqual(env.measures, ['data']);
    return env.advance(30000);
  }).then(function () {
    assert.strictEqual(env.fetched('control/host-diagnostic').length, 3, 'no poll after the report');
  });
});

check('gives up on a diagnostic that never finishes and marks it an error', function () {
  var env = createEnv({ ids: ['diagnostics-output'], boot: true, route: function (url) {
    if (url.indexOf('control/host-diagnostic') === 0) { return { status: 202, body: { ok: true, action: 'pending', runId: 'r', retryAfterSeconds: 3 } }; }
    return { status: 404, body: '' };
  } });
  return env.advance(361000).then(function () {
    assert.match(env.byId['diagnostics-output'].textContent, /^status\.host_diagnostic_timeout /);
    assert.deepStrictEqual(env.marks, ['error']);
    var polls = env.fetched('control/host-diagnostic').length;
    return env.advance(30000).then(function () { assert.strictEqual(env.fetched('control/host-diagnostic').length, polls); });
  });
});

var failed = 0;
checks.reduce(function (chain, item) {
  return chain.then(function () { return item.fn(); }).then(function () { /* passed */ }, function (error) {
    failed++;
    console.error('FAIL: ' + item.name + '\n' + (error && error.stack ? error.stack : error));
  });
}, Promise.resolve()).then(function () {
  if (failed) { console.error(failed + ' host-refresh check(s) failed'); process.exit(1); }
  console.log('PASS: host-refresh, start-cycle and diagnostics flows -- ' + checks.length + ' checks');
});
