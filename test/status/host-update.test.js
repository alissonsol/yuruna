/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  GUID: 424c712c-0915-4223-b5a1-d7e83e12002e
  Version: 2026.11.23

  Framework-free checks for the Diagnostics page's host update (Update host) in
  test/status/yuruna.common.js, and for how the repair (Repair host) and
  start-cycle answer an update that holds the host. Run: node
  host-update.test.js (exit 0 = pass).

  The page script runs in a vm context with a small DOM, a scripted fetch
  router, a manual timer queue and a controllable clock, as in
  host-repair.test.js. The catalog seam echoes the key and its arguments:
  these checks are about which message a state produces, not its English.
*/
'use strict';
var fs = require('fs');
var vm = require('vm');
var assert = require('assert');
var path = require('path');
var nodeCrypto = require('crypto');

var src = fs.readFileSync(path.join(__dirname, 'yuruna.common.js'), 'utf8');
var ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
var STORE_KEY = 'yurunaHostUpdate';

function makeEl(id, hidden) {
  var el = {
    id: id, textContent: '', className: '', hidden: !!hidden, disabled: false, value: '', style: {},
    listeners: {}, children: [],
    get firstChild() { return this.children[0] || null; },
    addEventListener: function (type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    removeEventListener: function () {},
    click: function () { (this.listeners.click || []).forEach(function (fn) { fn({}); }); },
    setAttribute: function (name, value) { this['attr:' + name] = String(value); },
    getAttribute: function (name) { var v = this['attr:' + name]; return (v === undefined) ? null : v; },
    removeAttribute: function (name) { delete this['attr:' + name]; },
    querySelector: function () { return null; }, querySelectorAll: function () { return []; },
    appendChild: function (kid) { this.children.push(kid); return kid; },
    removeChild: function (kid) { this.children = this.children.filter(function (c) { return c !== kid; }); return kid; },
    contains: function () { return false; },
    classList: { add: function () {}, remove: function () {}, toggle: function () {}, contains: function () { return false; } }
  };
  return el;
}

// One page environment. route(url, init, call) answers each fetch with
// {status, body, headers}, {reject: message} or {pending: true}.
function createEnv(opts) {
  var clock = { now: opts.startMs || 1790000000000 };
  var timers = [];
  var nextTimer = 1;
  var calls = [];
  var confirms = [];
  var assigned = [];
  var replaced = [];
  var store = {};
  var elements = {};
  (opts.ids || []).forEach(function (id) { elements[id] = makeEl(id, id === 'host-update' || id === 'host-repair' || id === 'host-repair-retry'); });

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
    var call = { url: String(url), init: init || {}, storedAtCall: store[STORE_KEY] };
    calls.push(call);
    var spec = opts.route(call.url.replace(/\?_=\d+$/, ''), call.init, call) || { status: 404, body: '' };
    if (spec.pending) {
      return new Promise(function (resolve) { call.release = function (later) { resolve(respond(later)); }; });
    }
    if (spec.reject) { return Promise.reject(new Error(spec.reject)); }
    return Promise.resolve(respond(spec));
  }

  var documentShim = {
    readyState: 'loading', hidden: false, title: '',
    documentElement: makeEl('html'),
    getElementById: function (id) { return elements[id] || null; },
    createElement: function (tag) { return makeEl(tag); },
    addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; },
    body: makeEl('body')
  };
  documentShim.documentElement.setAttribute('lang', 'en-US');
  documentShim.documentElement.setAttribute('dir', 'ltr');
  var windowShim = {
    location: { hostname: 'localhost', href: 'http://localhost:8080/status/diagnostics.html', search: '', pathname: '/status/diagnostics.html', hash: opts.hash || '', port: '8080',
      replace: function () {}, assign: function (url) { assigned.push(String(url)); } },
    history: { replaceState: function (state, title, url) { replaced.push(String(url)); } },
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
    YurunaFirstUsable: { hold: function () {}, release: function () {}, measure: function (p, s, cb) { return cb(); }, mark: function () {} }
  };
  var sandbox = {
    window: windowShim, document: documentShim, console: { log: function () {}, warn: function () {}, error: function () {} },
    fetch: fetchShim, Date: FakeDate, Uint8Array: Uint8Array, JSON: JSON, Math: Math, Promise: Promise,
    setTimeout: function (fn, ms) { var id = nextTimer++; timers.push({ id: id, at: clock.now + (ms || 0), fn: fn }); return id; },
    clearTimeout: function (id) { timers = timers.filter(function (x) { return x.id !== id; }); },
    setInterval: function () { return 0; }, clearInterval: function () {}
  };
  windowShim.fetch = fetchShim;
  windowShim.setTimeout = sandbox.setTimeout;
  windowShim.clearTimeout = sandbox.clearTimeout;
  windowShim.setInterval = sandbox.setInterval;
  windowShim.document = documentShim;
  sandbox.window = sandbox;
  Object.keys(windowShim).forEach(function (k) { sandbox[k] = windowShim[k]; });
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'yuruna.common.js' });
  sandbox.YurunaI18n.t = function (key, args) { return key + (args ? ' ' + JSON.stringify(args) : ''); };
  if (opts.stored) { store[STORE_KEY] = JSON.stringify(opts.stored); }

  function settle() {
    var chain = Promise.resolve();
    for (var i = 0; i < 30; i++) { chain = chain.then(function () { return new Promise(function (r) { setImmediate(r); }); }); }
    return chain;
  }
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
    Y: sandbox.Yuruna, byId: elements, calls: calls, confirms: confirms, assigned: assigned, replaced: replaced, store: store, clock: clock, settle: settle, advance: advance,
    fetched: function (fragment) { return calls.filter(function (c) { return c.url.indexOf(fragment) !== -1; }); },
    text: function () { return elements['host-update-status'].textContent; }
  };
}

var HU_IDS = ['host-update', 'host-update-title', 'host-update-note', 'host-update-scope', 'host-update-start', 'host-update-status'];
var HR_IDS = ['host-repair', 'host-repair-title', 'host-repair-note', 'host-repair-start', 'host-repair-retry', 'host-repair-status'];
var STATE_URL = '/runtime/host-update.state.json';
var HOST_ID = '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
function capability(update, hostId) {
  var body = update === undefined ? { ok: true } : { ok: true, update: update };
  if (hostId) { body.hostId = hostId; }
  return { status: 200, body: body };
}
function available(extra) {
  var u = { protocol: 1, availability: 'available', scopes: 'restart', reason: '', remote: 'missing', state: 'idle', caller: 'loopback' };
  Object.keys(extra || {}).forEach(function (k) { u[k] = extra[k]; });
  return u;
}
var KVM = { status: 200, body: { host: 'host.ubuntu.kvm', history: [] } };
function isoAt(ms) { return new Date(ms).toISOString(); }
function phaseState(id, nowMs, index, name, bound, extra) {
  var s = { schemaVersion: 1, requestId: id, scope: 'restart', channel: 'listener', state: 'running', phase: { index: index, count: 6, name: name, bound: bound },
    startedUtc: isoAt(nowMs - 60000), heartbeatUtc: isoAt(nowMs), mutated: false, listenerExpectedBackUtc: null, remarks: [], debt: [],
    verdict: null, operatorAction: null, reason: null, commit: { before: null, after: null, resident: null }, runnerConsole: null, supersededBy: null, firstCycle: null, terminalUtc: null };
  Object.keys(extra || {}).forEach(function (k) { s[k] = extra[k]; });
  return s;
}
function terminal(id, nowMs, extra) {
  return phaseState(id, nowMs, 0, '', 0, Object.assign({ state: 'terminal', phase: null, terminalUtc: isoAt(nowMs) }, extra || {}));
}
// A page whose capability, host status and state file the check controls.
function page(opts) {
  var world = { update: opts.update, host: opts.host === undefined ? KVM : opts.host, file: opts.file || null, down: false, reply: opts.reply, posts: [],
    hostId: opts.hostId === undefined ? HOST_ID : opts.hostId };
  var env = createEnv({ ids: opts.ids || HU_IDS, stored: opts.stored, noStorage: opts.noStorage, confirm: opts.confirm, hash: opts.hash, route: function (url, init) {
    if (url.indexOf('control/control-status') === 0) { return world.down ? { reject: 'connection refused' } : capability(world.update, world.hostId); }
    if (url === 'runtime/status.json') { return world.host; }
    if (url.indexOf(STATE_URL) === 0) {
      if (world.down) { return { reject: 'connection refused' }; }
      return world.file ? { status: 200, body: world.file, headers: { Date: new Date(env.clock.now).toUTCString() } } : { status: 404, body: '' };
    }
    if (url === 'control/host-update') {
      var sent = JSON.parse(init.body);
      world.posts.push(sent);
      return typeof world.reply === 'function' ? world.reply(sent) : world.reply;
    }
    return opts.route ? opts.route(url, init) : null;
  } });
  env.world = world;
  return env;
}
function queuedReply(sent) { return { status: 202, body: { ok: true, requestId: sent.requestId, action: 'queued', scope: sent.scope, stateUrl: STATE_URL } }; }

var checks = [];
function check(name, fn) { checks.push({ name: name, fn: fn }); }

// --- REGION: Availability
check('shows the control on every host and disables it with the reason', function () {
  var cases = [
    { update: undefined, reason: 'unknown' },
    { update: { protocol: 1, availability: 'unavailable', scopes: '', reason: 'journal_unreadable', remote: 'missing', state: 'unknown', caller: 'loopback' }, reason: 'journal_unreadable' },
    { update: { protocol: 1, availability: 'unavailable', scopes: '', reason: 'listener_dependency_missing', remote: 'missing', state: 'unknown', caller: 'loopback' }, reason: 'listener_dependency_missing' },
    { update: { protocol: 1, availability: 'unavailable', scopes: '', reason: 'session_unusable', remote: 'missing', state: 'idle', caller: 'loopback' }, reason: 'session_unusable' }
  ];
  return cases.reduce(function (chain, item) {
    return chain.then(function () {
      var env = page({ update: item.update, reply: queuedReply });
      env.Y.bootHostUpdate();
      return env.settle().then(function () {
        assert.strictEqual(env.byId['host-update'].hidden, false, 'shown for ' + item.reason);
        assert.strictEqual(env.byId['host-update-title'].textContent, 'status.host_update_title');
        assert.strictEqual(env.byId['host-update-start'].textContent, 'status.host_update_start');
        assert.strictEqual(env.byId['host-update-start'].disabled, true, 'disabled for ' + item.reason);
        assert.match(env.text(), new RegExp('^status\\.host_update_unavailable .*"reason":"' + item.reason + '"'));
        assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error');
        env.byId['host-update-start'].click();
        return env.settle();
      }).then(function () {
        assert.strictEqual(env.world.posts.length, 0, 'no POST for ' + item.reason);
        assert.strictEqual(env.confirms.length, 0);
      });
    });
  }, Promise.resolve());
});

check('names Enable-TestAutomation for controller_absent on KVM and Windows', function () {
  var absent = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'controller_absent', remote: 'missing', state: 'idle', caller: 'loopback' };
  return [KVM, { status: 200, body: { host: 'host.windows.hyper-v', history: [] } }].reduce(function (chain, host) {
    return chain.then(function () {
      var env = page({ update: absent, host: host });
      env.Y.bootHostUpdate();
      return env.settle().then(function () {
        assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"controller_absent"/, JSON.stringify(host.body));
        assert.match(env.text(), /"command":"pwsh test\/lab\/Enable-TestAutomation\.ps1"/);
        assert.strictEqual(env.byId['host-update-start'].disabled, true);
      });
    });
  }, Promise.resolve());
});

check('says host updates are not yet available for controller_absent on an unknown host type', function () {
  var absent = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'controller_absent', remote: 'missing', state: 'idle', caller: 'loopback' };
  var hosts = [{ status: 200, body: { host: 'host.other' } }, { status: 404, body: '' }];
  return hosts.reduce(function (chain, host) {
    return chain.then(function () {
      var env = page({ update: absent, host: host });
      env.Y.bootHostUpdate();
      return env.settle().then(function () {
        assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"host_type"/, JSON.stringify(host.body));
        assert.strictEqual(env.byId['host-update-start'].disabled, true);
      });
    });
  }, Promise.resolve());
});

var MACOS = { status: 200, body: { host: 'host.macos.utm', history: [] } };

check('names the runner start and Enable-TestAutomation for controller_absent on macOS', function () {
  var absent = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'controller_absent', remote: 'missing', state: 'idle', caller: 'loopback' };
  var env = page({ update: absent, host: MACOS, reply: queuedReply });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"controller_absent_macos"/);
    assert.match(env.text(), /"command":"pwsh test\/lab\/Enable-TestAutomation\.ps1"/);
    assert.match(env.text(), /"runner":"pwsh test\/Start-TestRunner\.ps1"/);
    assert.strictEqual(env.byId['host-update-start'].disabled, true);
    env.byId['host-update-start'].click();
    return env.settle();
  }).then(function () {
    assert.strictEqual(env.world.posts.length, 0, 'no POST without a controller');
  });
});

check('names the runner start when a press on macOS meets no controller', function () {
  var env = page({ update: available(), host: MACOS, reply: { status: 503, body: { ok: false, reason: 'controller_absent' } } });
  env.Y.bootHostUpdate();
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(10); }).then(function () {
    assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"controller_absent_macos"/);
    assert.match(env.text(), /"runner":"pwsh test\/Start-TestRunner\.ps1"/);
    assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error');
    assert.strictEqual(env.store[STORE_KEY], undefined, 'a refused request is forgotten');
  });
});

check('on macOS says to start the runner once more while an update holds the gate with no controller', function () {
  var other = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var gone = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'controller_absent', remote: 'missing', state: 'active', caller: 'loopback' };
  var env = page({ update: gone, host: MACOS });
  // The controller ended in the drain: its heartbeat stopped long ago.
  env.world.file = phaseState(other, 1790000000000 - 600000, 2, 'drain', 7200);
  env.Y.bootHostUpdate();
  return env.advance(10).then(function () {
    assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"controller_absent_gate"/, 'the gate text, not the stale one');
    assert.match(env.text(), /"runner":"pwsh test\/Start-TestRunner\.ps1"/);
    assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error');
    assert.strictEqual(env.byId['host-update-start'].disabled, true);
    // The runner start brought the controller back, and it continues.
    env.world.update = available({ state: 'active' });
    env.world.file = phaseState(other, env.clock.now, 3, 'stop_runner', 120);
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), new RegExp('^status\\.host_update_progress .*"requestId":"' + other + '".*"phase":"stop_runner"'));
  });
});

check('on macOS names an ordinary runner start for an update that is queued, in phase 1 or not shown yet, with no controller', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var stored = { id: id, scope: 'restart', acceptedMs: 1790000000000, observe: false };
  var gone = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'controller_absent', remote: 'missing', state: 'active', caller: 'loopback' };
  var files = [
    { name: 'phase 1 with a stopped heartbeat', file: phaseState(id, 1790000000000 - 600000, 1, 'preflight', 60) },
    { name: 'phase 1 with a fresh heartbeat', file: phaseState(id, 1790000000000, 1, 'preflight', 60) },
    { name: 'a queued row', file: phaseState(id, 1790000000000, 0, '', 0, { state: 'queued', phase: null }) },
    { name: 'a request the state file does not show yet', file: null }
  ];
  return files.reduce(function (chain, item) {
    return chain.then(function () {
      var env = page({ update: gone, host: MACOS, stored: stored });
      env.world.file = item.file;
      env.Y.bootHostUpdate();
      return env.advance(10).then(function () {
        assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"controller_absent_macos"/, item.name);
        assert.match(env.text(), /"runner":"pwsh test\/Start-TestRunner\.ps1"/, item.name);
        assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error', item.name);
        assert.ok(env.store[STORE_KEY], 'the request is still followed: ' + item.name);
      });
    });
  }, Promise.resolve());
});

check('keeps the queued and stale texts with no controller on KVM', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var stored = { id: id, scope: 'restart', acceptedMs: 1790000000000, observe: false };
  var gone = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'controller_absent', remote: 'missing', state: 'active', caller: 'loopback' };
  var cases = [
    { file: phaseState(id, 1790000000000, 0, '', 0, { state: 'queued', phase: null }), text: /^status\.host_update_queued /, name: 'queued' },
    { file: null, text: /^status\.host_update_queued /, name: 'not shown yet' },
    { file: phaseState(id, 1790000000000 - 600000, 1, 'preflight', 60), text: /^status\.host_update_stale /, name: 'phase 1' },
    { file: phaseState(id, 1790000000000 - 600000, 3, 'stop_runner', 120), text: /^status\.host_update_stale /, name: 'phase 3' }
  ];
  return cases.reduce(function (chain, item) {
    return chain.then(function () {
      var env = page({ update: gone, stored: stored });
      env.world.file = item.file;
      env.Y.bootHostUpdate();
      return env.advance(10).then(function () { assert.match(env.text(), item.text, 'a KVM host keeps its text: ' + item.name); });
    });
  }, Promise.resolve());
});

check('on macOS names the runner start for a recovering update with no controller, not a host that keeps trying', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var stored = { id: id, scope: 'restart', acceptedMs: 1790000000000, observe: false };
  var gone = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'controller_absent', remote: 'missing', state: 'recovering', caller: 'loopback' };
  function recovering() {
    return phaseState(id, 1790000000000, 0, 'recover', 540, { state: 'recovering', verdict: 'recovering', reason: 'config_gate_refused', operatorAction: 'act_at_host', phase: { index: 0, count: 6, name: 'recover', bound: 540 } });
  }
  var env = page({ update: gone, host: MACOS, stored: stored });
  env.world.file = recovering();
  env.Y.bootHostUpdate();
  return env.advance(10).then(function () {
    assert.match(env.text(), /^status\.host_update_verdict .*"verdict":"recovering_without_controller".*"reason":"config_gate_refused"/);
    assert.match(env.text(), /status\.host_update_unavailable .*"reason":"controller_absent_gate"/);
    assert.match(env.text(), /"runner":"pwsh test\/Start-TestRunner\.ps1"/);
    assert.match(env.text(), /status\.host_update_action \{"action":"act_at_host","command":""\}/);
    assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error');
    assert.ok(env.store[STORE_KEY], 'a recovering update is still followed');
    // The runner start brought the controller back: it is the host that keeps trying again.
    env.world.update = available({ state: 'recovering' });
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_verdict .*"verdict":"recovering"/);
    assert.doesNotMatch(env.text(), /controller_absent_gate/);
    var kvm = page({ update: gone, stored: stored });
    kvm.world.file = recovering();
    kvm.Y.bootHostUpdate();
    return kvm.advance(10).then(function () {
      assert.match(kvm.text(), /^status\.host_update_verdict .*"verdict":"recovering".*"reason":"config_gate_refused"/, 'a KVM job restarts its controller');
      assert.doesNotMatch(kvm.text(), /controller_absent/);
    });
  });
});

check('names how to end the controller session for session_unusable, and the stop after the cycle', function () {
  var unusable = { protocol: 1, availability: 'unavailable', scopes: '', reason: 'session_unusable', remote: 'missing', state: 'idle', caller: 'loopback' };
  var env = page({ update: unusable, host: MACOS });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"session_unusable"/);
    assert.match(env.text(), /"tmux":"tmux -L yuruna-controller kill-session -t yuruna-controller"/);
    assert.match(env.text(), /"screen":"screen -ls"/);
    var variants = JSON.parse(fs.readFileSync(path.join(__dirname, '../../globalization/catalogs/en-US/status.json'), 'utf8')).messages['status.host_update_unavailable'].select.variants;
    assert.match(variants.session_unusable, /\{tmux\}/, 'the text names the tmux command');
    assert.match(variants.session_unusable, /\{screen\}/, 'the text names how to find a screen session');
    assert.match(variants.session_unusable, /after its cycle/, 'a running runner is stopped after its cycle, as for controller_absent_macos');
    assert.match(variants.controller_absent_macos, /after its cycle/);
  });
});

check('disables it for a remote viewer', function () {
  var env = page({ update: available({ caller: 'remote' }), reply: queuedReply });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    assert.strictEqual(env.byId['host-update'].hidden, false);
    assert.strictEqual(env.byId['host-update-start'].disabled, true);
    assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"remote"/);
    assert.match(env.text(), /"file":"pool-control\.record"/, 'the text names what opens it');
    env.byId['host-update-start'].click();
    return env.settle();
  }).then(function () {
    assert.strictEqual(env.world.posts.length, 0, 'no POST from a remote page');
  });
});

// --- REGION: From another machine
function remoteReady(extra) {
  return available(Object.assign({ caller: 'remote', remote: 'provisioned', poolControl: 'http://pool.example:8080/', scopes: 'restart,full' }, extra || {}));
}

check('sends a remote press to pool-control at the address the host record names', function () {
  var env = page({ update: remoteReady() });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    assert.strictEqual(env.byId['host-update-start'].disabled, false);
    assert.match(env.text(), /^status\.host_update_remote_hint .*"url":"http:\/\/pool\.example:8080"/);
    env.byId['host-update-scope'].value = 'full';
    env.byId['host-update-start'].click();
    return env.settle();
  }).then(function () {
    assert.deepStrictEqual(env.assigned, ['http://pool.example:8080/host/update?host=' + HOST_ID + '&scope=full']);
    assert.strictEqual(env.world.posts.length, 0, 'nothing is posted to the host');
    assert.strictEqual(env.confirms.length, 0, 'pool-control asks, not this page');
    assert.strictEqual(env.store[STORE_KEY], undefined, 'no id is stored before pool-control mints one');
  });
});

check('keeps the remote press disabled without a usable record', function () {
  var cases = [
    { update: remoteReady({ remote: 'missing', poolControl: undefined }) },
    { update: remoteReady({ remote: 'invalid', poolControl: undefined }) },
    { update: remoteReady({ poolControl: 'javascript:alert(1)' }) },
    { update: remoteReady({ poolControl: 'http://pool.example/?next=evil' }) },
    { update: remoteReady(), hostId: 'not-a-host-id' }
  ];
  return cases.reduce(function (chain, item) {
    return chain.then(function () {
      var env = page({ update: item.update, hostId: item.hostId });
      env.Y.bootHostUpdate();
      return env.settle().then(function () {
        assert.strictEqual(env.byId['host-update-start'].disabled, true, JSON.stringify(item));
        assert.match(env.text(), /^status\.host_update_unavailable .*"reason":"remote"/);
        env.byId['host-update-start'].click();
        return env.settle();
      }).then(function () {
        assert.strictEqual(env.assigned.length, 0, 'no navigation for ' + JSON.stringify(item));
      });
    });
  }, Promise.resolve());
});

check('follows the request pool-control queued from #yhu and drops the fragment', function () {
  var id = '0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90';
  var env = page({ update: remoteReady({ state: 'active' }), hash: '#yhu=' + id });
  env.world.file = phaseState(id, env.clock.now, 2, 'drain', 7200, { channel: 'remote' });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    assert.match(env.text(), new RegExp('^status\\.host_update_queued .*"requestId":"' + id + '"'));
    return env.advance(10);
  }).then(function () {
    assert.strictEqual(JSON.parse(env.store[STORE_KEY]).id, id);
    assert.deepStrictEqual(env.replaced, ['/status/diagnostics.html']);
    assert.match(env.text(), new RegExp('^status\\.host_update_progress .*"requestId":"' + id + '"'));
    assert.strictEqual(env.byId['host-update-start'].disabled, true, 'no second press while one is followed');
  });
});

check('ignores a #yhu fragment that is not a request id', function () {
  var env = page({ update: remoteReady(), hash: '#yhu=0B6F3C2E-8A51-4D0E-9F4C-2D7A1E6B5C90' });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    assert.strictEqual(env.store[STORE_KEY], undefined);
    assert.strictEqual(env.replaced.length, 0);
    assert.strictEqual(env.byId['host-update-start'].disabled, false);
  });
});

check('offers the full scope only when the capability lists it', function () {
  var env = page({ update: available() });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    var options = env.byId['host-update-scope'].children;
    assert.deepStrictEqual(options.map(function (o) { return o.value; }), ['restart']);
    assert.strictEqual(options[0].textContent, 'status.host_update_scope {"scope":"restart"}');
    assert.match(env.byId['host-update-note'].textContent, /^status\.host_update_note .*"minutes":120.*-Scope restart -Drain now/);
    var full = page({ update: available({ scopes: 'restart,full' }) });
    full.Y.bootHostUpdate();
    return full.settle().then(function () {
      assert.deepStrictEqual(full.byId['host-update-scope'].children.map(function (o) { return o.value; }), ['restart', 'full']);
      full.byId['host-update-scope'].value = 'full';
      (full.byId['host-update-scope'].listeners.change || []).forEach(function (fn) { fn({}); });
      assert.match(full.byId['host-update-note'].textContent, /-Scope full -Drain now/, 'the note names the chosen scope');
    });
  });
});

// --- REGION: The press
check('posts exactly requestId and scope', function () {
  var started = 1790000000000;
  var env = page({ update: available(), reply: queuedReply,
    host: { status: 200, body: { host: 'host.ubuntu.kvm', cycleStartUtc: isoAt(started - 1800000), finishedAt: null,
      history: [{ totalDurationSeconds: 3000 }, { totalDurationSeconds: 6000 }, { totalDurationSeconds: 5400 }] } } });
  env.Y.bootHostUpdate();
  return env.settle().then(function () {
    assert.strictEqual(env.byId['host-update-start'].disabled, false);
    env.byId['host-update-start'].click();
    return env.settle();
  }).then(function () {
    assert.strictEqual(env.confirms.length, 1);
    assert.match(env.confirms[0], /^status\.host_update_confirm .*"scope":"status\.host_update_scope \{\\"scope\\":\\"restart\\"\}"/);
    assert.match(env.confirms[0], /"minutes":120/);
    assert.match(env.confirms[0], /"command":"pwsh test\/lab\/Invoke-HostUpdate\.ps1 -Scope restart -Drain now"/);
    assert.match(env.confirms[0], /status\.host_update_cycle_time \{"elapsed":1800,"median":5400\}/, 'elapsed beside the median of recent cycles');
    var post = env.fetched('control/host-update')[0];
    assert.ok(post, 'the request was posted');
    assert.strictEqual(post.init.method, 'POST');
    var sent = JSON.parse(post.init.body);
    assert.deepStrictEqual(Object.keys(sent).sort(), ['requestId', 'scope']);
    assert.ok(ID_RE.test(sent.requestId));
    assert.strictEqual(sent.scope, 'restart');
    assert.strictEqual(post.init.headers['X-Yuruna'], '1');
    assert.strictEqual(post.init.headers['Content-Type'], 'application/json');
  });
});

check('stores the id before the POST', function () {
  var env = page({ update: available(), reply: queuedReply });
  env.Y.bootHostUpdate();
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(0); }).then(function () {
    var post = env.fetched('control/host-update')[0];
    var sent = JSON.parse(post.init.body);
    assert.ok(post.storedAtCall && JSON.parse(post.storedAtCall).id === sent.requestId, 'the id was stored before the POST');
    assert.strictEqual(JSON.parse(env.store[STORE_KEY]).id, sent.requestId);
    assert.ok(JSON.parse(env.store[STORE_KEY]).acceptedMs > 0, 'the acceptance is recorded');
    assert.match(env.text(), /^status\.host_update_queued /);
    assert.strictEqual(env.fetched(STATE_URL).length, 1, 'the accepted request is followed');
    assert.strictEqual(env.byId['host-update-start'].disabled, true, 'no second request while one is followed');
  });
});

check('asks nothing when the confirmation is declined', function () {
  var env = page({ update: available(), reply: queuedReply, confirm: false });
  env.Y.bootHostUpdate();
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.settle(); }).then(function () {
    assert.strictEqual(env.confirms.length, 1);
    assert.strictEqual(env.world.posts.length, 0);
    assert.strictEqual(env.store[STORE_KEY], undefined);
    assert.strictEqual(env.byId['host-update-start'].disabled, false);
  });
});

check('maps the refusals of the route to their texts', function () {
  var replies = [
    { reply: { status: 503, body: { ok: false, reason: 'controller_absent' } }, expect: /^status\.host_update_unavailable .*"reason":"controller_absent"/ },
    { reply: { status: 409, body: { ok: false, reason: 'scope_unavailable' } }, expect: /^status\.host_update_unavailable .*"reason":"scope_unavailable"/ },
    { reply: { status: 403, body: { ok: false, reason: 'update_proof_missing' } }, expect: /^status\.host_update_unavailable .*"reason":"remote"/ },
    { reply: { status: 409, body: { ok: false, reason: 'request_conflict' } }, expect: /^status\.host_request_conflict / },
    { reply: { status: 400, body: { ok: false, reason: 'forbidden_field', field: 'drain' } }, expect: /^status\.host_request_rejected .*forbidden_field/ },
    { reply: { reject: 'network down' }, expect: /^status\.host_request_rejected .*network down/ }
  ];
  return replies.reduce(function (chain, item) {
    return chain.then(function () {
      var env = page({ update: available(), reply: item.reply });
      env.Y.bootHostUpdate();
      return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(10); }).then(function () {
        assert.match(env.text(), item.expect, JSON.stringify(item.reply));
        assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error');
        assert.strictEqual(env.store[STORE_KEY], undefined, 'a refused request is forgotten');
        assert.strictEqual(env.fetched(STATE_URL).length, 0, 'nothing is followed');
        assert.strictEqual(env.byId['host-update-start'].disabled, false);
      });
    });
  }, Promise.resolve());
});

check('adopts a busy host_update and names any other holder', function () {
  var active = '7d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a';
  var env = page({ update: available(), reply: { status: 409, body: { ok: false, reason: 'busy', activeKind: 'host_update', activeRequestId: active, stateUrl: STATE_URL } } });
  env.Y.bootHostUpdate();
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(10); }).then(function () {
    var stored = JSON.parse(env.store[STORE_KEY]);
    assert.strictEqual(stored.id, active, 'the busy update is followed');
    assert.strictEqual(stored.observe, true);
    assert.strictEqual(env.fetched(STATE_URL).length, 1);
    env.world.file = phaseState(active, env.clock.now, 2, 'drain', 7200);
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), new RegExp('^status\\.host_update_progress .*"requestId":"' + active + '".*"phase":"drain"'));
    return ['host_repair', 'start_cycle'].reduce(function (chain, kind) {
      return chain.then(function () {
        var other = page({ update: available(), reply: { status: 409, body: { ok: false, reason: 'busy', activeKind: kind, activeRequestId: active } } });
        other.Y.bootHostUpdate();
        return other.settle().then(function () { other.byId['host-update-start'].click(); return other.advance(10); }).then(function () {
          assert.match(other.text(), new RegExp('^status\\.host_update_busy .*"kind":"' + kind + '"'));
          assert.strictEqual(other.store[STORE_KEY], undefined);
          assert.strictEqual(other.fetched(STATE_URL).length, 0, 'another kind of operation is not followed here');
        });
      });
    }, Promise.resolve());
  });
});

// --- REGION: Following an update
check('polls on state active with no stored id', function () {
  var other = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var env = page({ update: available({ state: 'active' }) });
  env.world.file = phaseState(other, 1790000000000, 3, 'stop_runner', 120);
  env.Y.bootHostUpdate();
  return env.advance(10).then(function () {
    assert.strictEqual(env.world.posts.length, 0, 'watching never posts');
    assert.strictEqual(env.fetched(STATE_URL).length, 1, 'an active update is followed without a stored id');
    assert.match(env.text(), new RegExp('^status\\.host_update_progress .*"requestId":"' + other + '".*"index":3.*"count":6.*"phase":"stop_runner".*"bound":120'));
    assert.strictEqual(env.byId['host-update-start'].disabled, true);
    assert.strictEqual(env.store[STORE_KEY], undefined, 'an update this page did not start is not stored');
    env.world.file = terminal(other, env.clock.now, { verdict: 'updated', operatorAction: 'none' });
    env.world.update = available({ state: 'idle' });
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_verdict .*"verdict":"updated"/);
    assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status ok');
    assert.strictEqual(env.byId['host-update-start'].disabled, false);
    var polls = env.fetched(STATE_URL).length;
    return env.advance(30000).then(function () {
      assert.strictEqual(env.fetched(STATE_URL).length, polls, 'polling stops once nothing is active');
    });
  });
});

check('never polls an idle host with nothing stored', function () {
  var env = page({ update: available() });
  env.Y.bootHostUpdate();
  return env.advance(30000).then(function () {
    assert.strictEqual(env.fetched(STATE_URL).length, 0);
    assert.strictEqual(env.text(), '');
  });
});

check('renders a recorded state sequence: queued, drain, stop, update, listener, runner, updated', function () {
  var id = null;
  var env = page({ update: available(), reply: function (sent) { id = sent.requestId; return queuedReply(sent); } });
  env.Y.bootHostUpdate();
  var seen = [];
  function next(file) {
    env.world.file = file(env.clock.now + 3000);
    return env.advance(3000).then(function () { seen.push(env.text()); });
  }
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(10); }).then(function () {
    env.world.update = available({ state: 'active' });
    return next(function (now) { return phaseState(id, now, 0, '', 0, { state: 'queued', phase: null }); });
  }).then(function () { return next(function (now) { return phaseState(id, now, 1, 'preflight', 60); }); })
    .then(function () { return next(function (now) { return phaseState(id, now, 2, 'drain', 7200); }); })
    .then(function () { return next(function (now) { return phaseState(id, now, 3, 'stop_runner', 120); }); })
    .then(function () { return next(function (now) { return phaseState(id, now, 4, 'update_source', 300, { mutated: true }); }); })
    .then(function () { return next(function (now) { return phaseState(id, now, 5, 'start_listener', 60, { mutated: true }); }); })
    .then(function () { return next(function (now) { return phaseState(id, now, 6, 'start_runner', 240, { mutated: true }); }); })
    .then(function () {
      return next(function (now) { return terminal(id, now, { verdict: 'updated', operatorAction: 'none', mutated: true, runnerConsole: 'tmux', firstCycle: 'pending' }); });
    }).then(function () {
      assert.match(seen[0], /^status\.host_update_queued /);
      [['preflight', 1, 60], ['drain', 2, 7200], ['stop_runner', 3, 120], ['update_source', 4, 300], ['start_listener', 5, 60], ['start_runner', 6, 240]].forEach(function (p, i) {
        assert.match(seen[i + 1], new RegExp('^status\\.host_update_progress .*"index":' + p[1] + ',"count":6,"phase":"' + p[0] + '","bound":' + p[2]), 'phase ' + p[0]);
      });
      var last = seen[7];
      assert.match(last, /^status\.host_update_verdict .*"verdict":"updated"/);
      assert.ok(last.indexOf('status.host_update_action') === -1, 'no action for none');
      assert.match(last, /status\.host_update_console .*"console":"tmux"/);
      assert.match(last, /status\.host_update_first_cycle \{"result":"pending"\}/);
      assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status ok');
      assert.strictEqual(env.store[STORE_KEY], undefined, 'a terminal update is forgotten');
      assert.strictEqual(env.byId['host-update-start'].disabled, false, 'a new press is possible once it ended');
      env.world.update = available();
      return next(function (now) { return terminal(id, now, { verdict: 'updated', operatorAction: 'none', runnerConsole: 'tmux', firstCycle: 'pass' }); });
    }).then(function () {
      assert.match(env.text(), /status\.host_update_first_cycle \{"result":"pass"\}/, 'the first cycle result arrives later');
      var polls = env.fetched(STATE_URL).length;
      return env.advance(30000).then(function () { assert.strictEqual(env.fetched(STATE_URL).length, polls, 'polling stops with the first cycle known'); });
    });
});

check('renders recovering, released, superseded, updated_not_started with their actions', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var newer = '7d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a';
  var stored = { id: id, scope: 'restart', acceptedMs: 1790000000000, observe: false };
  var env = page({ update: available({ state: 'recovering' }), stored: stored });
  env.world.file = phaseState(id, 1790000000000, 0, 'recover', 540, { state: 'recovering', verdict: 'recovering', reason: 'pull_failed', operatorAction: 'release', phase: { index: 0, count: 6, name: 'recover', bound: 540 } });
  env.Y.bootHostUpdate();
  return env.advance(10).then(function () {
    assert.strictEqual(env.world.posts.length, 0, 'a stored request is followed, never resent');
    assert.match(env.text(), /^status\.host_update_verdict .*"verdict":"recovering".*"reason":"pull_failed"/);
    assert.match(env.text(), new RegExp('status\\.host_update_action .*"action":"release","command":"pwsh test/lab/Invoke-HostUpdate\\.ps1 -Release ' + id + '"'));
    assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error');
    assert.ok(env.store[STORE_KEY], 'a recovering update is still followed');
    env.world.file = terminal(id, env.clock.now, { verdict: 'released', operatorAction: 'none', debt: [{ obligation: 'listener', action: 'start_listener' }] });
    env.world.update = available();
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_verdict .*"verdict":"released"/);
    assert.match(env.text(), /status\.host_update_debt \{"actions":"start_listener"\}/);
    assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status');
    assert.strictEqual(env.store[STORE_KEY], undefined);
    var sup = page({ update: available({ state: 'active' }), stored: stored });
    sup.world.file = terminal(id, 1790000000000, { verdict: 'superseded', operatorAction: 'none', supersededBy: newer });
    sup.Y.bootHostUpdate();
    return sup.advance(10).then(function () {
      assert.match(sup.text(), new RegExp('^status\\.host_update_verdict .*"verdict":"superseded".*"supersededBy":"' + newer + '"'));
      sup.world.file = phaseState(newer, sup.clock.now, 2, 'drain', 7200);
      return sup.advance(3000);
    }).then(function () {
      assert.match(sup.text(), new RegExp('^status\\.host_update_progress .*"requestId":"' + newer + '"'), 'the update that took over is followed next');
    });
  }).then(function () {
    var ns = page({ update: available(), stored: stored });
    ns.world.file = terminal(id, 1790000000000, { verdict: 'updated_not_started', operatorAction: 'start_runner' });
    ns.Y.bootHostUpdate();
    return ns.advance(10).then(function () {
      assert.match(ns.text(), /^status\.host_update_verdict .*"verdict":"updated_not_started"/);
      assert.match(ns.text(), /status\.host_update_action \{"action":"start_runner","command":""\}/);
      var dt = page({ update: available(), stored: stored });
      dt.world.file = terminal(id, 1790000000000, { verdict: 'drain_timeout', operatorAction: 'retry_or_drain_now', reason: 'drain_timeout' });
      dt.Y.bootHostUpdate();
      return dt.advance(10).then(function () {
        assert.match(dt.text(), /status\.host_update_action .*"action":"retry_or_drain_now","command":"pwsh test\/lab\/Invoke-HostUpdate\.ps1 -Scope restart -Drain now"/);
        assert.strictEqual(dt.byId['host-update-status'].className, 'host-operation-status error');
      });
    });
  });
});

check('names the attended Enable for provision_elevation on macOS and keeps the sudo rule text elsewhere', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var stored = { id: id, scope: 'full', acceptedMs: 1790000000000, observe: false };
  function refused() { return terminal(id, 1790000000000, { scope: 'full', verdict: 'refused', reason: 'scope_unavailable', operatorAction: 'provision_elevation' }); }
  var mac = page({ update: available(), host: MACOS, stored: stored });
  mac.world.file = refused();
  mac.Y.bootHostUpdate();
  return mac.advance(10).then(function () {
    assert.match(mac.text(), /^status\.host_update_verdict .*"verdict":"refused".*"reason":"scope_unavailable"/);
    assert.match(mac.text(), /status\.host_update_action \{"action":"provision_elevation_macos","command":"pwsh test\/lab\/Enable-TestAutomation\.ps1"\}/);
    var kvm = page({ update: available(), stored: stored });
    kvm.world.file = refused();
    kvm.Y.bootHostUpdate();
    return kvm.advance(10).then(function () {
      assert.match(kvm.text(), /status\.host_update_action \{"action":"provision_elevation","command":""\}/);
    });
  });
});

check('counts down to listenerExpectedBackUtc while the host does not answer', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var start = 1790000000000;
  var env = page({ update: available({ state: 'active' }), stored: { id: id, scope: 'restart', acceptedMs: start, observe: false } });
  env.world.file = phaseState(id, start, 5, 'start_listener', 60, { listenerExpectedBackUtc: isoAt(start + 40000) });
  env.Y.bootHostUpdate();
  return env.advance(10).then(function () {
    assert.match(env.text(), /^status\.host_update_progress .*"phase":"start_listener"/);
    env.world.down = true;
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_countdown \{"seconds":37\}/);
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_countdown \{"seconds":34\}/, 'the countdown advances');
    assert.ok(env.store[STORE_KEY], 'a host that does not answer has not ended the update');
    return env.advance(60000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_countdown \{"seconds":0\}/, 'never below zero');
    env.world.down = false;
    env.world.file = phaseState(id, env.clock.now + 3000, 6, 'start_runner', 240);
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_progress .*"phase":"start_runner"/, 'progress resumes when the host answers');
  });
});

check('shows the attach command for tmux, the window on Windows and the remark for none', function () {
  var id = '3f2b4c1d-0e9a-4b7c-8d6e-5f4a3b2c1d0e';
  var stored = { id: id, scope: 'restart', acceptedMs: 1790000000000, observe: false };
  var tmux = page({ update: available(), stored: stored });
  tmux.world.file = terminal(id, 1790000000000, { verdict: 'updated', operatorAction: 'none', runnerConsole: 'tmux' });
  tmux.Y.bootHostUpdate();
  return tmux.advance(10).then(function () {
    assert.match(tmux.text(), /status\.host_update_console \{"console":"tmux","command":"tmux -S ~\/\.yuruna\/host-repair\/host-controller\/runner-console\.sock attach"\}/);
    var none = page({ update: available(), stored: stored });
    none.world.file = terminal(id, 1790000000000, { verdict: 'updated_with_remarks', operatorAction: 'read_remarks', runnerConsole: 'none', remarks: ['runner_console_unavailable'] });
    none.Y.bootHostUpdate();
    return none.advance(10).then(function () {
      assert.match(none.text(), /^status\.host_update_verdict .*"verdict":"updated_with_remarks"/);
      assert.match(none.text(), /status\.host_update_action \{"action":"read_remarks","command":""\}/);
      assert.match(none.text(), /status\.host_update_remarks \{"remarks":"runner_console_unavailable"\}/);
      assert.match(none.text(), /status\.host_update_console \{"console":"none"/);
      assert.strictEqual(none.byId['host-update-status'].className, 'host-operation-status ok');
      var windowed = page({ update: available(), stored: stored, host: { status: 200, body: { host: 'host.windows.hyper-v', history: [] } } });
      windowed.world.file = terminal(id, 1790000000000, { verdict: 'updated', operatorAction: 'none', runnerConsole: 'window' });
      windowed.Y.bootHostUpdate();
      return windowed.advance(10).then(function () {
        assert.match(windowed.text(), /status\.host_update_console \{"console":"window"/);
        assert.doesNotMatch(windowed.text(), /runner_console_unavailable/);
      });
    });
  });
});

check('calls an update stale by the server clock and lost once the host reports nothing active', function () {
  var id = null;
  var env = page({ update: available(), reply: function (sent) { id = sent.requestId; return queuedReply(sent); } });
  env.Y.bootHostUpdate();
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(10); }).then(function () {
    env.world.update = available({ state: 'active' });
    env.world.file = phaseState(id, env.clock.now - 41000, 3, 'stop_runner', 120);
    return env.advance(3000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_stale .*"seconds":44/);
    assert.strictEqual(env.byId['host-update-status'].className, 'host-operation-status error');
    // A later update replaced the file and the journal shows nothing active.
    env.world.file = terminal('7d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a', env.clock.now, { verdict: 'updated' });
    env.world.update = available({ state: 'idle' });
    return env.advance(18000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_lost /);
    assert.strictEqual(env.store[STORE_KEY], undefined);
    assert.strictEqual(env.byId['host-update-start'].disabled, false);
    var polls = env.fetched(STATE_URL).length;
    return env.advance(30000).then(function () { assert.strictEqual(env.fetched(STATE_URL).length, polls, 'polling stopped'); });
  });
});

check('waits through the capability cache before calling a fresh request lost', function () {
  var id = null;
  var env = page({ update: available(), reply: function (sent) { id = sent.requestId; return queuedReply(sent); } });
  env.Y.bootHostUpdate();
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(10); }).then(function () {
    return env.advance(12000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_queued /, 'a capability that still reads idle is not the end inside the grace');
    env.world.file = phaseState(id, env.clock.now + 3000, 0, '', 0, { state: 'queued', phase: null });
    return env.advance(9000);
  }).then(function () {
    assert.match(env.text(), /^status\.host_update_queued /, 'the queued row is shown');
    assert.ok(env.store[STORE_KEY]);
  });
});

check('renders a completed replay by its verdict and keeps working without storage', function () {
  var env = page({ update: available(), reply: function (sent) { return { status: 200, body: { ok: true, requestId: sent.requestId, action: 'completed', state: 'refused', verdict: 'refused', stateUrl: STATE_URL } }; } });
  env.Y.bootHostUpdate();
  return env.settle().then(function () { env.byId['host-update-start'].click(); return env.advance(10); }).then(function () {
    assert.match(env.text(), /^status\.host_update_verdict .*"verdict":"refused"/);
    assert.strictEqual(env.fetched(STATE_URL).length, 0, 'a replay needs no polling');
    var bare = page({ update: available(), noStorage: true, reply: queuedReply });
    bare.Y.bootHostUpdate();
    return bare.settle().then(function () { bare.byId['host-update-start'].click(); return bare.advance(10); }).then(function () {
      assert.strictEqual(bare.world.posts.length, 1);
      assert.strictEqual(bare.fetched(STATE_URL).length, 1, 'identity lasts for the page even when storage throws');
    });
  });
});

// --- REGION: The repair and start-cycle beside it
check('the repair and start-cycle name a host update that holds the host', function () {
  var active = '7d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a';
  var env = createEnv({ ids: HR_IDS, route: function (url) {
    if (url.indexOf('control/control-status') === 0) { return { status: 200, body: { ok: true, repair: { protocol: 1, availability: 'available', ceiling: 'start-if-stopped', reason: '', remote: 'missing', state: 'idle' } } }; }
    if (url === 'control/host-repair') { return { status: 409, body: { ok: false, reason: 'busy', activeKind: 'host_update', activeRequestId: active, stateUrl: STATE_URL } }; }
    return null;
  } });
  env.Y.bootHostRepair();
  return env.settle().then(function () {
    assert.strictEqual(env.byId['host-repair-start'].textContent, 'status.host_repair_start', 'the repair button is its own Repair host control');
    env.byId['host-repair-start'].click();
    return env.advance(10);
  }).then(function () {
    assert.match(env.byId['host-repair-status'].textContent, new RegExp('^status\\.host_update_blocks \\{"requestId":"' + active + '"\\}'));
    assert.strictEqual(env.store.yurunaHostRepair, undefined, 'the repair does not follow an update');
    assert.strictEqual(env.fetched('/runtime/host-repair.state.json').length, 0);
    assert.match(src, /body\.activeKind === 'host_update'\) \{\s*throw new Error\(t\('status\.host_update_blocks'/, 'start-cycle names a host update too');
  });
});

check('boots the update beside the repair on the Diagnostics page', function () {
  assert.match(src, /bootDiagnostics\(\);\s*if \(document\.getElementById\('host-update'\)\) \{ bootHostUpdate\(\); \}\s*if \(document\.getElementById\('host-repair'\)\) \{ bootHostRepair\(\); \}/);
  var html = fs.readFileSync(path.join(__dirname, 'diagnostics.html'), 'utf8');
  HU_IDS.forEach(function (id) { assert.ok(html.indexOf('id="' + id + '"') !== -1, id + ' is in diagnostics.html'); });
  assert.ok(html.indexOf('id="diagnostics-output"') < html.indexOf('id="host-update"'), 'the host sections follow the report');
  assert.ok(html.indexOf('id="host-update"') < html.indexOf('id="host-repair"'), 'Update host comes before Repair host');
  assert.match(html, /<section id="host-update" class="host-operation" hidden aria-labelledby="host-update-title">/);
  assert.match(html, /id="host-update-status" class="host-operation-status" role="status" aria-live="polite" aria-atomic="true"/);
});

check('leaves Save and start cycle on the Config page without the host sections', function () {
  var html = fs.readFileSync(path.join(__dirname, 'config.html'), 'utf8');
  ['host-update', 'host-repair'].forEach(function (id) { assert.strictEqual(html.indexOf('id="' + id + '"'), -1, id + ' is not in config.html'); });
  assert.match(html, /<button type="button" class="config-btn destructive" id="config-save-start"/);
  assert.doesNotMatch(src, /bootTestConfig\(\);\s*if \(document\.getElementById\('host-/, 'the Config page boots no host section');
});

var failed = 0;
checks.reduce(function (chain, item) {
  return chain.then(function () { return item.fn(); }).then(function () { /* passed */ }, function (error) {
    failed++;
    console.error('FAIL: ' + item.name + '\n' + (error && error.stack ? error.stack : error));
  });
}, Promise.resolve()).then(function () {
  if (failed) { console.error(failed + ' host-update check(s) failed'); process.exit(1); }
  console.log('PASS: host-update flow and its neighbors on the Diagnostics page -- ' + checks.length + ' checks');
});
