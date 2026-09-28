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
  pending[1].resolve({cards: [], offers: [], statsError: 'newest period'});
  await settle();
  const message = env.byId['stats-banner'].textContent;
  assert.ok(message.includes('newest period'));
  pending[0].resolve({cards: [], offers: []});
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
  ['pool-rows', 'host-rows', 'ts-rows'].forEach(id => {
    const el = byId[id];
    if (!el) return;
    let text = '';
    Object.defineProperty(el, 'textContent', {get() { return text; }, set(value) {
      text = value; el.children.forEach(child => {child.parentNode = null;}); el.children = [];
    }});
  });
  return {reads, writes, feedback, notice: () => notice};
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
  await mutationConfirmation('test-sets.html', env => {
    env.byId['ts-name'].value = 'created';
    env.byId['ts-framework'].value = 'https://fixture.test/framework';
    env.byId['ts-project'].value = 'https://fixture.test/project';
    fire(env.byId.save, 'click');
  });
  await mutationConfirmation('index.html', env => {
    const select = nodes(env.byId['pool-rows'], n => n.tagName === 'SELECT')[0];
    select.value = 'smoke';
    fire(nodes(env.byId['pool-rows'], n => n.tagName === 'BUTTON' && n.textContent === 'Assign')[0], 'click');
  });
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
Promise.resolve().then(boardGenerations).then(confirmationsAndBudgets).then(() => {
  console.log('PASS: pool request budgets, latest board generation, mutation confirmation and current-row feedback');
}).catch(error => { console.error(error.stack); process.exitCode = 1; });
