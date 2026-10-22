// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
'use strict';
const assert = require('assert');
const {runPage, makeEl, fire} = require('./ui-pages.test.js');
const settle = async () => { for (let i = 0; i < 15; i++) await new Promise(resolve => setTimeout(resolve, 0)); };
function nodes(root, predicate) {
  const found = [];
  (function visit(node) { if (predicate(node)) found.push(node); (node.children || []).forEach(visit); })(root);
  return found;
}
function load(file, setup) {
  const env = runPage({service: 'pool-control-service', file}, 'en-US', false, 'data', {beforePage: setup});
  assert.deepStrictEqual(env.failures, []);
  return env;
}
async function boardGenerations() {
  const pending = [];
  const period = makeEl('button');
  period.setAttribute('data-range', '7d');
  const env = load('board.html', box => {
    const api = box.Y.api;
    box.document.querySelectorAll = selector => selector === '.periods button' ? [period] : [];
    box.Y.api = (url, opts) => url.startsWith('/api/board?') ? new Promise((resolve, reject) => pending.push({url, opts, resolve, reject})) : api(url, opts);
  });
  await settle();
  fire(period, 'click');
  assert.strictEqual(pending.length, 2);
  assert.ok(pending.every(p => p.opts.timeoutMs >= 60000), 'board timeout permits bounded backend queries');
  pending[1].resolve({cards: [], statsError: 'newest period'});
  await settle();
  const message = env.byId['stats-banner'].textContent;
  assert.ok(message.includes('newest period'));
  pending[0].resolve({cards: []});
  await settle();
  assert.strictEqual(env.byId['stats-banner'].hidden, false);
  assert.strictEqual(env.byId['stats-banner'].textContent, message, 'older range cannot erase newer results');
}
function instrument(box, byId) {
  const reads = [];
  const writes = [];
  const feedback = [];
  let notice = null;
  const api = box.Y.api;
  box.Y.api = (url, opts) => { reads.push({url, opts}); return api(url, opts); };
  box.Y.mutate = (url, opts) => { writes.push({url, opts}); return Promise.resolve({ok: true, applied: 1, hosts: []}); };
  box.Y.notice = (kind, message) => { notice = {kind, message}; };
  box.Y.clearNotice = () => { notice = null; };
  box.Y.rowFeedback = (row, kind, message) => { feedback.push({row, kind, message}); };
  // Real textContent replacement detaches old table rows. The lightweight page
  // fixture normally needs only append semantics; mutation checks need both.
  ['pool-rows', 'host-rows'].forEach(id => {
    const el = byId[id];
    if (!el) return;
    let text = '';
    Object.defineProperty(el, 'textContent', {get() { return text; }, set(value) {
      text = value; el.children.forEach(child => {child.parentNode = null;}); el.children = [];
    }});
  });
  return {reads, writes, feedback, notice: () => notice};
}
// First strong isolate, pop directional isolate and right-to-left override:
// what Y.bidiIsolate wraps a value in, and one of the controls it strips.
const FSI = String.fromCharCode(0x2068);
const PDI = String.fromCharCode(0x2069);
const RLO = String.fromCharCode(0x202e);
function repositoryBoxes(env) {
  return nodes(env.byId['pool-rows'], n => n.tagName === 'INPUT' && n.className === 'repo-url');
}
function rowAction(env, action) {
  return nodes(env.byId['pool-rows'], n => n.tagName === 'BUTTON' && n.getAttribute('data-action') === action)[0];
}
function press(el, key, extra) {
  const ev = Object.assign({type: 'keydown', currentTarget: el, target: el, key, keyCode: 0, prevented: false,
    preventDefault() { this.prevented = true; }, stopPropagation() {}}, extra || {});
  for (const fn of (el.listeners.keydown || [])) fn(ev);
  return ev;
}
// A /api/state reply of its own, with the member count and auto-enrollment
// target a case needs; every other route keeps the shared fixture.
function poolState(box, state) {
  const api = box.Y.api;
  box.Y.api = (url, opts) => url === '/api/state' ? Promise.resolve(JSON.parse(JSON.stringify(state))) : api(url, opts);
}
async function repositoryColumn() {
  const pool = {poolId: 'default', poolGuid: '426d17ef0b88426b922180dad1a9e921', displayName: 'Default', members: ['426d17ef0b88426b922180dad1a9e921'],
    repositories: {frameworkUrl: 'https://f.test', projectUrl: 'https://p.test'}};

  // The boxes show the saved pair, framework over project, and Save waits for a change.
  let observed;
  const asked = [];
  let env = load('pools.html', (box, byId) => {
    observed = instrument(box, byId);
    box.confirm = question => { asked.push(question); return true; };
  });
  await settle();
  let boxes = repositoryBoxes(env);
  assert.strictEqual(boxes.length, 2, 'one framework box and one project box per pool');
  assert.deepStrictEqual(boxes.map(b => b.getAttribute('data-repo')), ['framework', 'project']);
  assert.deepStrictEqual(boxes.map(b => b.value), ['https://f.test', 'https://p.test'], 'the boxes open on the saved pair');
  assert.deepStrictEqual(boxes.map(b => b.getAttribute('dir')), ['ltr', 'ltr'], 'a URL reads left to right in every locale');
  assert.deepStrictEqual(boxes.map(b => b.getAttribute('placeholder')), ['Framework URL', 'Project URL']);
  assert.ok(boxes.every(b => /default/.test(b.getAttribute('aria-label'))), 'each box names its pool for assistive tech');
  assert.ok(boxes.every(b => b.getAttribute('type') === 'text'), 'single-line text boxes, never a textarea');
  let save = rowAction(env, 'set-repositories');
  assert.ok(save, 'a Save control sits in the Actions column');
  assert.strictEqual(save.disabled, true, 'Save is off while the boxes hold the saved pair');
  assert.strictEqual(press(boxes[1], 'Enter').prevented, true);
  await settle();
  assert.strictEqual(observed.writes.length, 0, 'Enter with nothing changed sends nothing');

  // Enter in either box saves, after naming the blast radius.
  boxes[1].value = 'https://p2.test';
  fire(boxes[1], 'input');
  assert.strictEqual(save.disabled, false, 'an edit turns Save on');
  press(boxes[1], 'Enter', {isComposing: true});
  await settle();
  assert.strictEqual(observed.writes.length, 0, 'Enter that ends an IME composition does not save');
  press(boxes[1], 'Enter');
  await settle();
  assert.strictEqual(observed.writes.length, 1, 'Enter in a box saves');
  assert.strictEqual(asked.length, 1, 'a pool with members is asked first');
  assert.ok(asked[0].includes(FSI + 'https://p2.test' + PDI), 'the project in the question is bidi-isolated: ' + asked[0]);
  assert.strictEqual(observed.notice().kind, 'ok', 'the outcome survives the reload');

  // Half a pair is refused in the page, with no request.
  boxes = repositoryBoxes(env);
  boxes[0].value = '';
  fire(boxes[0], 'input');
  fire(rowAction(env, 'set-repositories'), 'click');
  await settle();
  assert.strictEqual(observed.writes.length, 1, 'one empty box sends nothing');
  assert.strictEqual(observed.notice().kind, 'error');
  assert.strictEqual(observed.notice().message, 'Enter both a framework URL and a project URL, or leave both empty to clear them.');

  // Both empty clears, after its own question.
  boxes[1].value = '  ';
  fire(boxes[1], 'input');
  fire(rowAction(env, 'set-repositories'), 'click');
  await settle();
  assert.strictEqual(observed.writes.length, 2, 'both empty is a clear');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(observed.writes[1].opts.body)), {poolId: 'default', frameworkUrl: '', projectUrl: ''});
  assert.ok(/own project/.test(asked[1]), 'a clear says the members go back to their own projects: ' + asked[1]);

  // A declined question sends nothing and keeps the text.
  env = load('pools.html', (box, byId) => {
    observed = instrument(box, byId);
    box.confirm = () => false;
  });
  await settle();
  boxes = repositoryBoxes(env);
  boxes[0].value = 'https://f2.test';
  fire(boxes[0], 'input');
  fire(rowAction(env, 'set-repositories'), 'click');
  await settle();
  assert.strictEqual(observed.writes.length, 0, 'a declined confirmation writes nothing');
  assert.strictEqual(repositoryBoxes(env)[0].value, 'https://f2.test');

  // Typed text survives a repaint of the whole table.
  env = load('pools.html', (box, byId) => { observed = instrument(box, byId); });
  await settle();
  boxes = repositoryBoxes(env);
  boxes[1].value = 'https://draft.test/project';
  fire(boxes[1], 'input');
  const hostBox = nodes(env.byId['pool-rows'], n => n.tagName === 'INPUT' && n.className !== 'repo-url')[0];
  hostBox.value = 'host-to-add';
  fire(nodes(hostBox.parentNode, n => n.tagName === 'BUTTON')[0], 'click');
  await settle();
  const rebuilt = repositoryBoxes(env);
  assert.notStrictEqual(rebuilt[1], boxes[1], 'the row was rebuilt');
  assert.strictEqual(rebuilt[1].value, 'https://draft.test/project', 'the unsaved text came back');
  assert.strictEqual(rebuilt[0].value, 'https://f.test');
  assert.strictEqual(rowAction(env, 'set-repositories').disabled, false, 'and it can still be saved');

  // A failed save keeps the text and says why, with the remote detail isolated.
  env = load('pools.html', (box, byId) => {
    observed = instrument(box, byId);
    box.Y.mutate = () => Promise.reject(new Error('refused ' + RLO + ' here'));
  });
  await settle();
  boxes = repositoryBoxes(env);
  boxes[0].value = 'https://f3.test';
  fire(boxes[0], 'input');
  save = rowAction(env, 'set-repositories');
  fire(save, 'click');
  await settle();
  assert.strictEqual(observed.notice().kind, 'error');
  assert.strictEqual(observed.notice().message, 'Save failed: ' + FSI + 'refused  here' + PDI);
  assert.strictEqual(save.disabled, false, 'a failed save can be retried');
  assert.strictEqual(repositoryBoxes(env)[0].value, 'https://f3.test');

  // The auto-enrollment target pool takes no pair: boxes off, the note, no Save.
  env = load('pools.html', (box, byId) => {
    observed = instrument(box, byId);
    poolState(box, {ok: true, pools: [Object.assign({}, pool, {repositories: undefined})], autoEnrollment: {enabled: true, targetPoolId: 'default', excluded: []}});
  });
  await settle();
  boxes = repositoryBoxes(env);
  assert.deepStrictEqual(boxes.map(b => b.disabled), [true, true], 'the target pool cannot be given a pair');
  assert.deepStrictEqual(boxes.map(b => b.value), ['', '']);
  assert.ok(nodes(env.byId['pool-rows'], n => n.textContent === 'Hosts land here automatically and keep running their own project.').length === 1, 'the row says why');
  assert.strictEqual(rowAction(env, 'set-repositories'), undefined);
  assert.strictEqual(rowAction(env, 'clear-repositories'), undefined);

  // ...and a pair it carries anyway is shown, and can only be cleared.
  const clearAsked = [];
  env = load('pools.html', (box, byId) => {
    observed = instrument(box, byId);
    box.confirm = question => { clearAsked.push(question); return true; };
    poolState(box, {ok: true, pools: [pool], autoEnrollment: {enabled: true, targetPoolId: 'default', excluded: []}});
  });
  await settle();
  boxes = repositoryBoxes(env);
  assert.deepStrictEqual(boxes.map(b => b.value), ['https://f.test', 'https://p.test']);
  assert.deepStrictEqual(boxes.map(b => b.disabled), [true, true]);
  assert.strictEqual(rowAction(env, 'set-repositories'), undefined);
  fire(rowAction(env, 'clear-repositories'), 'click');
  await settle();
  assert.strictEqual(observed.writes.length, 1);
  assert.strictEqual(observed.writes[0].url, '/api/pool/repositories');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(observed.writes[0].opts.body)), {poolId: 'default', frameworkUrl: '', projectUrl: ''});
  assert.strictEqual(clearAsked.length, 0, 'clearing the target pool changes nothing its members run');
}
async function mutationConfirmation(file, action, rowFeedback) {
  let observed;
  const env = load(file, (box, byId) => {observed = instrument(box, byId);});
  await settle();
  action(env);
  await settle();
  assert.strictEqual(observed.writes.length, 1, file + ' executed mutation');
  assert.strictEqual(observed.notice().kind, 'ok', file + ' confirmation survives reload');
  if (rowFeedback) {
    assert.strictEqual(observed.feedback.length, 1);
    assert.ok(env.byId[rowFeedback].contains(observed.feedback[0].row), file + ' feedback belongs to newly rendered row');
  }
  return observed;
}
async function confirmationsAndBudgets() {
  await mutationConfirmation('pools.html', env => {
    env.byId['new-poolid'].value = 'created';
    env.byId['new-display'].value = 'Created';
    fire(env.byId.create, 'click');
  });
  const repositories = await mutationConfirmation('pools.html', env => {
    const boxes = repositoryBoxes(env);
    boxes[0].value = ' https://fixture.test/framework ';
    fire(boxes[0], 'input');
    boxes[1].value = 'https://fixture.test/project';
    fire(boxes[1], 'input');
    fire(rowAction(env, 'set-repositories'), 'click');
  }, 'pool-rows');
  assert.strictEqual(repositories.writes[0].url, '/api/pool/repositories');
  assert.deepStrictEqual(JSON.parse(JSON.stringify(repositories.writes[0].opts.body)),
    {poolId: 'default', frameworkUrl: 'https://fixture.test/framework', projectUrl: 'https://fixture.test/project'},
    'the pair is sent trimmed, under the pool it was typed for');
  const hosts = await mutationConfirmation('hosts.html', env => {
    const select = nodes(env.byId['host-rows'], n => n.tagName === 'SELECT')[0];
    select.value = '';
    fire(select, 'change');
  }, 'host-rows');
  for (const route of ['/api/hosts', '/api/hosts/facts']) {
    const read = hosts.reads.find(r => r.url === route);
    assert.ok(read && read.opts.timeoutMs >= 60000, route + ' permits bounded aggregator and fanout reads');
  }
  const controls = await mutationConfirmation('pools.html', env => {
    const select = nodes(env.byId['pool-rows'], n => n.tagName === 'SELECT')[0];
    select.value = 'pause-after-step';
    fire(select, 'change');
  });
  assert.strictEqual(controls.writes[0].url, '/api/pool/host-control');
  assert.ok(controls.writes[0].opts.timeoutMs >= 90000, 'host action permits discovery, host fanout and intent work');
}
function watchDocumentKeys(box) {
  const keys = new Set();
  const add = box.document.addEventListener;
  const remove = box.document.removeEventListener;
  box.document.addEventListener = function (type, fn, capture) {
    if (type === 'keydown' && capture) keys.add(fn);
    return add.call(this, type, fn, capture);
  };
  box.document.removeEventListener = function (type, fn, capture) {
    if (type === 'keydown' && capture) keys.delete(fn);
    return remove.call(this, type, fn, capture);
  };
  return keys;
}
// These cases exercise a modal lifetime, so the page fixture needs connected
// controls, real focus ownership, and the document's capture listeners. CSS hit
// testing is left to the browser gate; a DOM shim cannot prove viewport cover.
function interactivePage(box, byId) {
  const doc = box.document;
  const capture = {};
  const add = doc.addEventListener;
  const remove = doc.removeEventListener;
  doc.addEventListener = function (type, fn, useCapture) {
    if (useCapture) (capture[type] = capture[type] || []).push(fn);
    return add.call(this, type, fn, useCapture);
  };
  doc.removeEventListener = function (type, fn, useCapture) {
    if (useCapture) {
      const list = capture[type] || [];
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    }
    return remove.call(this, type, fn, useCapture);
  };
  function dispatch(target, type, extra) {
    const event = Object.assign({type, target, currentTarget: target, key: '', keyCode: 0, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.stopped = true; },
      stopImmediatePropagation() { this.stopped = true; this.immediate = true; }
    }, extra || {});
    for (const fn of (capture[type] || []).slice()) {
      fn(event);
      if (event.immediate) break;
    }
    if (!event.stopped) for (const fn of (target.listeners[type] || []).slice()) {
      fn(event);
      if (event.immediate) break;
    }
    return event;
  }
  function decorate(el) {
    let text = el.textContent;
    Object.defineProperty(el, 'textContent', {configurable: true, get() { return text; }, set(value) {
      text = value;
      el.children.forEach(child => { child.parentNode = null; });
      el.children = [];
    }});
    el.focus = function () {
      if (!doc.body.contains(this)) return;
      doc.activeElement = this;
      dispatch(this, 'focusin');
    };
    el.querySelectorAll = function (selector) {
      return nodes(this, node => node !== this && selector.split(',').some(part => {
        const s = part.trim();
        if (s === '[href]') return node.hasAttribute && node.hasAttribute('href');
        if (s.indexOf('[tabindex]') === 0) return node.tabIndex >= 0;
        if (s[0] === '#') return node.getAttribute && node.getAttribute('id') === s.slice(1);
        return node.tagName === s.toUpperCase();
      }));
    };
    el.querySelector = function (selector) { return this.querySelectorAll(selector)[0] || null; };
    return el;
  }
  const create = doc.createElement;
  doc.createElement = tag => decorate(create(tag));
  decorate(doc.body);
  for (const id of Object.keys(byId)) {
    decorate(byId[id]);
    byId[id].setAttribute('id', id);
    doc.body.appendChild(byId[id]);
  }
  const originalGet = doc.getElementById;
  doc.getElementById = id => originalGet(id) || nodes(doc.body, n => n.getAttribute && n.getAttribute('id') === id)[0] || null;
  doc.querySelectorAll = selector => doc.body.querySelectorAll(selector);
  doc.querySelector = selector => doc.body.querySelector(selector);
  return {dispatch, listeners: type => (capture[type] || []).length};
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}
function barriers(env) {
  return nodes(env.body, node => String(node.className || '').split(' ').includes('blocking'));
}
function statusSelect(env) {
  return nodes(env.byId['pool-rows'], n => n.tagName === 'SELECT')[0];
}
async function statusBarrier() {
  // The mutation and each subsequent read are independently held. A barrier
  // that ends at the POST response would expose controls built from old state.
  for (const outcome of ['success', 'partial', 'rejected', 'read-rejected', 'read-throws']) {
    const post = deferred(), stateRead = deferred(), hostsRead = deferred();
    const requests = [];
    let afterPost = false, observed, input;
    const ticks = [];
    const env = load('pools.html', (box, byId) => {
      input = interactivePage(box, byId);
      observed = instrument(box, byId);
      box.setInterval = fn => { ticks.push(fn); return ticks.length; };
      const api = box.Y.api;
      box.Y.mutate = (url, opts) => { requests.push({url, opts}); return post.promise; };
      box.Y.api = (url, opts) => {
        if (afterPost && url === '/api/state') {
          if (outcome === 'read-throws') throw new Error('configuration read threw');
          return stateRead.promise;
        }
        if (afterPost && url === '/api/pool/host-control') return hostsRead.promise;
        return api(url, opts);
      };
    });
    await settle();
    assert.strictEqual(barriers(env).length, 0, outcome + ': ordinary reads do not block the page');
    const select = statusSelect(env);
    select.focus();
    const keyListeners = input.listeners('keydown');
    select.value = 'pause-after-step';
    fire(select, 'change');
    assert.strictEqual(barriers(env).length, 1, outcome + ': choosing Pool Status blocks immediately');
    await settle();
    assert.strictEqual(requests.length, 1);
    assert.strictEqual(requests[0].url, '/api/pool/host-control');
    assert.deepStrictEqual(JSON.parse(JSON.stringify(requests[0].opts.body)), {poolId: 'default', action: 'pause-after-step'});
    const barrier = barriers(env)[0];
    assert.strictEqual(barrier.getAttribute('aria-busy'), 'true');
    assert.ok(barrier.contains(env.box.document.activeElement), outcome + ': keyboard focus moves inside the barrier');
    env.byId.create.focus();
    assert.ok(barrier.contains(env.box.document.activeElement), outcome + ': background controls cannot take focus while commands are pending');
    for (const shiftKey of [false, true]) {
      const event = input.dispatch(env.box.document.activeElement, 'keydown', {key: 'Tab', shiftKey});
      assert.strictEqual(event.defaultPrevented, true, outcome + ': Tab stays within the wait surface');
      assert.ok(barrier.contains(env.box.document.activeElement));
    }
    // An already queued selection event must not start a second fanout.
    fire(select, 'change');
    assert.strictEqual(requests.length, 1, outcome + ': duplicate commits send no second mutation');
    const readsBeforeTick = observed.reads.length;
    for (let i = 0; i < 65; i++) for (const tick of ticks) tick();
    await settle();
    assert.strictEqual(observed.reads.length, readsBeforeTick, outcome + ': auto-refresh waits for the mutation');

    afterPost = true;
    if (outcome === 'rejected') post.reject(new Error('host command refused'));
    else post.resolve({ok: outcome !== 'partial', requested: 2, applied: outcome === 'partial' ? 1 : 2,
      failed: outcome === 'partial' ? 1 : 0, hosts: outcome === 'partial' ? [{hostId: 'host-two', ok: false, error: 'host is offline'}] : []});
    await settle();
    if (outcome !== 'read-throws') {
      assert.strictEqual(barriers(env).length, 1, outcome + ': POST completion keeps the page blocked through configuration read');
      if (outcome === 'read-rejected') stateRead.reject(new Error('configuration read refused'));
      else stateRead.resolve({ok: true, pools: [{poolId: 'default', poolGuid: '426d17ef0b88426b922180dad1a9e921', members: ['host-one', 'host-two']}]});
      await settle();
      if (outcome !== 'read-rejected') {
        assert.strictEqual(barriers(env).length, 1, outcome + ': fresh rows stay blocked while host states are outstanding');
        hostsRead.resolve({ok: true, pools: {default: {state: 'pause-after-step', hosts: []}}});
      }
    }
    await settle();
    assert.strictEqual(barriers(env).length, 0, outcome + ': terminal completion releases the page');
    assert.strictEqual(env.byId['footer-busy'].hidden, true, outcome + ': completion also releases read progress');
    assert.strictEqual(input.listeners('keydown'), keyListeners, outcome + ': modal key handlers do not leak');
    assert.ok(statusSelect(env) && !statusSelect(env).disabled, outcome + ': Pool Status can be used again');
    assert.ok(env.body.contains(env.box.document.activeElement), outcome + ': focus returns to a connected control');
    assert.strictEqual(observed.notice().kind, ['success', 'read-rejected'].includes(outcome) ? 'ok' : 'error', outcome + ': outcome survives repaint');
    if (outcome === 'partial') assert.ok(observed.notice().message.includes('host is offline'), 'partial failure names the refused host');
  }
  let writes = 0;
  const env = load('pools.html', (box, byId) => {
    interactivePage(box, byId);
    box.confirm = () => false;
    box.Y.mutate = () => { writes++; return Promise.resolve({ok: true}); };
  });
  await settle();
  statusSelect(env).value = 'continue';
  fire(statusSelect(env), 'change');
  await settle();
  assert.strictEqual(writes, 0, 'a declined status confirmation sends nothing');
  assert.strictEqual(barriers(env).length, 0, 'a declined status confirmation leaves the page usable');
}
async function statusUnlockAndTimeout() {
  for (const answer of ['unlock', 'cancel']) {
    const retry = deferred();
    let attempts = 0, observed, input;
    const env = load('pools.html', (box, byId) => {
      input = interactivePage(box, byId);
      // Keep the real Y.mutate: the authentication retry is part of the action.
      const mutate = box.Y.mutate;
      observed = instrument(box, byId);
      box.Y.mutate = mutate;
      const api = box.Y.api;
      box.Y.api = (url, opts) => {
        if (url !== '/api/pool/host-control' || !opts || opts.method !== 'POST') return api(url, opts);
        attempts++;
        return attempts === 1 ? Promise.reject(Object.assign(new Error('session expired'), {status: 401})) : retry.promise;
      };
    });
    await settle();
    const select = statusSelect(env);
    select.focus(); select.value = 'continue'; fire(select, 'change');
    await settle();
    const dialog = env.box.document.getElementById('yuruna-unlock');
    assert.ok(dialog, answer + ': expired session opens the token prompt');
    assert.strictEqual(barriers(env).length, 1, answer + ': page stays blocked while authentication is requested');
    assert.ok(dialog.contains(env.box.document.activeElement), answer + ': the prompt can take keyboard focus');
    const code = nodes(dialog, n => n.tagName === 'INPUT')[0];
    code.value = 'abc123'; code.focus();
    const typing = input.dispatch(code, 'keydown', {key: 'a'});
    assert.strictEqual(typing.defaultPrevented, false, answer + ': barrier permits token entry');
    if (answer === 'cancel') {
      fire(nodes(dialog, n => n.tagName === 'BUTTON' && n.textContent === 'Cancel')[0], 'click');
      await settle();
      assert.strictEqual(attempts, 1, 'canceling token entry never retries host commands');
      assert.strictEqual(barriers(env).length, 0, 'canceling unlock releases the page');
      assert.strictEqual(observed.notice().kind, 'error');
    } else {
      fire(nodes(dialog, n => n.tagName === 'FORM')[0], 'submit');
      await settle();
      assert.strictEqual(attempts, 2, 'unlock retries the original host command once');
      assert.strictEqual(env.box.document.getElementById('yuruna-unlock'), null);
      assert.strictEqual(barriers(env).length, 1, 'host-command retry remains blocked');
      assert.ok(barriers(env)[0].contains(env.box.document.activeElement), 'closing unlock restores focus into the wait surface');
      retry.resolve({ok: true, applied: 1, hosts: []});
      await settle();
      assert.strictEqual(barriers(env).length, 0, 'successful authenticated action releases the page');
      assert.strictEqual(observed.notice().kind, 'ok');
    }
  }
  let request, observed;
  const env = load('pools.html', (box, byId) => {
    interactivePage(box, byId);
    const mutate = box.Y.mutate;
    observed = instrument(box, byId); box.Y.mutate = mutate;
    const fetch = box.fetch;
    box.fetch = (url, opts) => {
      if (url === '/api/pool/host-control' && opts && opts.method === 'POST') { request = opts; return new Promise(() => {}); }
      return fetch(url, opts);
    };
  });
  await settle();
  const select = statusSelect(env); select.value = 'continue'; fire(select, 'change');
  assert.strictEqual(barriers(env).length, 1, 'a stalled request initially blocks the page');
  await settle();
  assert.ok(request.signal.aborted, 'the real API timeout aborts the stalled host command');
  assert.strictEqual(barriers(env).length, 0, 'timeout releases the barrier');
  assert.strictEqual(observed.notice().kind, 'error', 'timeout is reported to the operator');
}
async function statusOlderRead() {
  for (const rejectOld of [false, true]) {
    const oldRead = deferred(), nextRead = deferred();
    const ticks = [];
    let hostReads = 0, observed;
    const env = load('pools.html', (box, byId) => {
      interactivePage(box, byId);
      observed = instrument(box, byId);
      box.setInterval = fn => { ticks.push(fn); return ticks.length; };
      const api = box.Y.api;
      box.Y.api = (url, opts) => {
        if (url !== '/api/pool/host-control') return api(url, opts);
        hostReads++;
        if (hostReads === 1) return oldRead.promise;
        if (hostReads > 2) return nextRead.promise;
        return Promise.resolve({ok: true, pools: {default: {state: 'pause-after-step', hosts: []}}});
      };
    });
    await settle();
    assert.strictEqual(hostReads, 1, 'an earlier background member read is still outstanding');
    const select = statusSelect(env); select.focus(); select.value = 'pause-after-step'; fire(select, 'change');
    await settle();
    assert.strictEqual(hostReads, 2, 'the action independently reads back its new host state');
    assert.strictEqual(barriers(env).length, 0, 'the action does not wait for an obsolete read');
    const message = observed.notice().message;
    const selectedAction = () => nodes(statusSelect(env), n => n.tagName === 'OPTION' && n.selected)[0].getAttribute('value');
    assert.strictEqual(selectedAction(), 'pause-after-step');
    env.byId['new-poolid'].focus();
    if (rejectOld) oldRead.reject(new Error('old host-state read failed'));
    else oldRead.resolve({ok: true, pools: {default: {state: 'continue', hosts: []}}});
    await settle();
    assert.strictEqual(selectedAction(), 'pause-after-step', 'late pre-action host state cannot replace the completed action');
    assert.strictEqual(observed.notice().message, message, 'late read does not erase the operation result');
    // A stale reply must not poison the cached state used for the next paint,
    // either. Hold that refresh's member read so the cached value is visible.
    for (let i = 0; i < 65; i++) for (const tick of ticks) tick();
    await settle();
    assert.ok(hostReads >= 3, 'the next ordinary refresh still runs');
    assert.strictEqual(selectedAction(), 'pause-after-step', 'the next paint starts from the confirmed state');
    nextRead.resolve({ok: true, pools: {default: {state: 'pause-after-step', hosts: []}}});
    await settle();
    assert.strictEqual(env.byId['footer-busy'].hidden, true, 'all read progress is released');
  }
}
async function blockingFocusLifetimes() {
  for (const newestFirst of [false, true]) {
    let input;
    const env = load('pools.html', (box, byId) => { input = interactivePage(box, byId); });
    await settle();
    env.byId.create.focus();
    const beforeKeys = input.listeners('keydown'), beforeFocus = input.listeners('focusin');
    const first = env.box.Y.block('first');
    const second = env.box.Y.block('second');
    assert.strictEqual(barriers(env).length, 2, 'overlapping shared blockers can coexist');
    assert.ok(barriers(env)[1].contains(env.box.document.activeElement), 'the newest blocker owns focus');
    input.dispatch(env.box.document.activeElement, 'keydown', {key: 'Tab'});
    assert.ok(barriers(env)[1].contains(env.box.document.activeElement), 'Tab never activates an older blocker');
    (newestFirst ? second : first)();
    assert.strictEqual(barriers(env).length, 1);
    input.dispatch(env.box.document.activeElement, 'keydown', {key: 'Tab'});
    assert.ok(barriers(env)[0].contains(env.box.document.activeElement), 'the remaining blocker still contains keyboard navigation');
    (newestFirst ? first : second)();
    assert.strictEqual(barriers(env).length, 0);
    assert.strictEqual(input.listeners('keydown'), beforeKeys);
    assert.strictEqual(input.listeners('focusin'), beforeFocus, 'all modal focus handlers are removed');
    env.byId.create.focus();
    assert.strictEqual(env.box.document.activeElement, env.byId.create, 'normal focus is available after both completions');

    // A deletion caller selects its surviving row before releasing the shared
    // barrier. The disconnected opener must not override that deliberate move.
    const opener = env.box.document.createElement('button');
    env.body.appendChild(opener); opener.focus();
    const done = env.box.Y.block('deleting');
    env.body.removeChild(opener);
    env.byId.create.focus();
    assert.strictEqual(env.box.document.activeElement, env.byId.create, 'default shared blockers permit a caller to select replacement focus');
    done();
    assert.strictEqual(env.box.document.activeElement, env.byId.create, 'release preserves the caller\'s replacement focus');
  }
}
async function dialogCleanup() {
  let unlockKeys;
  const env = load('pools.html', box => { unlockKeys = watchDocumentKeys(box); });
  await settle();
  const previous = unlockKeys.size;
  const first = env.box.Y.unlock();
  const second = env.box.Y.unlock();
  assert.strictEqual(first, second, 'concurrent mutations share one unlock result');
  assert.strictEqual(nodes(env.body, n => n.getAttribute('id') === 'yuruna-unlock').length, 1);
  const cancel = nodes(env.body, n => n.tagName === 'BUTTON' && n.textContent === 'Cancel')[0];
  fire(cancel, 'click');
  assert.deepStrictEqual(await Promise.all([first, second]), [false, false]);
  assert.strictEqual(unlockKeys.size, previous, 'closing unlock removes its listener');
}
async function focusAndBusyLifetimes() {
  let answer;
  const env = load('pools.html', box => {
    const api = box.Y.api;
    box.Y.api = (url, opts) => url === '/api/pool/host-control' ? new Promise(resolve => { answer = resolve; }) : api(url, opts);
  });
  await settle();
  const select = nodes(env.byId['pool-rows'], n => n.tagName === 'SELECT')[0];
  assert.ok(select, 'pool controls render before delayed host replies');
  select.value = 'pause-after-step';
  env.box.document.activeElement = select;
  answer({pools: {default: {state: 'run'}}});
  await settle();
  assert.strictEqual(nodes(env.byId['pool-rows'], n => n.tagName === 'SELECT')[0], select, 'delayed reply preserves the focused control');
  assert.strictEqual(select.value, 'pause-after-step', 'pending selection survives fanout');
  assert.strictEqual(select.parentNode.getAttribute('data-repaint-held'), '1');

  for (const reverse of [false, true]) {
    const container = makeEl('div');
    const original = makeEl('button');
    container.appendChild(original);
    const first = env.box.Y.busy(container, 'first');
    const second = env.box.Y.busy(container, 'second');
    await settle();
    const one = reverse ? second : first;
    const two = reverse ? first : second;
    one(); one();
    assert.notStrictEqual(container.firstChild, original, 'one completed request keeps the other busy');
    two();
    assert.strictEqual(container.children.length, 1);
    assert.strictEqual(container.firstChild, original, 'last completion restores original controls once');
  }
}
async function diagnosticRefreshAndTimeout() {
  let reads = 0;
  const download = runPage({service: 'download-agent-service', file: 'diagnostics.html'}, 'en-US', false, 'data', {beforePage(box) {
    const api = box.Y.api;
    box.Y.api = (url, opts) => { if (url === '/api/v1/diagnostics') reads++; return api(url, opts); };
  }});
  await settle();
  const before = reads;
  fire(download.byId['refresh-view'], 'click');
  await settle();
  assert.strictEqual(reads, before+1, 'Refresh view requests fresh diagnostics');

  let request;
  const pool = load('diagnostics.html', box => {
    const fetch = box.fetch;
    box.fetch = (url, opts) => {
      if (url !== '/api/diagnostics') return fetch(url, opts);
      request = opts;
      return new Promise(() => {});
    };
  });
  await settle();
  assert.ok(request.signal.aborted, 'stalled diagnostic requests abort');
  assert.strictEqual(nodes(pool.byId['check-rows'], n => n.className === 'loading').length, 0, 'timeout removes progress indicator');
  assert.ok(pool.byId.notice.textContent, 'timeout is reported');
  let failing;
  const report = load('diagnostics.html', box => {
    const fetch = box.fetch;
    box.fetch = (url, opts) => url === '/api/diagnostics' ? Promise.resolve({ok: true, status: 200, json: () => Promise.resolve({ok: false, checks: [{name: 'down', ok: false, detail: 'offline'}]})}) : fetch(url, opts);
    const notice = box.Y.notice;
    box.Y.notice = (kind, text) => { if (kind === 'error') failing = text; return notice(kind, text); };
  });
  await settle();
  assert.strictEqual(failing, undefined, 'failed checks render as report data');
  assert.ok(report.byId['check-rows'].children.length, 'failed checks remain visible');
}
Promise.resolve().then(boardGenerations).then(confirmationsAndBudgets).then(repositoryColumn).then(statusBarrier).then(statusUnlockAndTimeout).then(statusOlderRead).then(blockingFocusLifetimes).then(dialogCleanup).then(focusAndBusyLifetimes).then(diagnosticRefreshAndTimeout).then(() => {
  console.log('PASS: pool request budgets, latest board generation, mutation confirmation, current-row feedback, Pool Status blocking and the Framework / Project column');
}).catch(error => { console.error(error.stack); process.exitCode = 1; });
