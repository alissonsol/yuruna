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
Promise.resolve().then(boardGenerations).then(confirmationsAndBudgets).then(repositoryColumn).then(dialogCleanup).then(focusAndBusyLifetimes).then(diagnosticRefreshAndTimeout).then(() => {
  console.log('PASS: pool request budgets, latest board generation, mutation confirmation, current-row feedback and the Framework / Project column');
}).catch(error => { console.error(error.stack); process.exitCode = 1; });
