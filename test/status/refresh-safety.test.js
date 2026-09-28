// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const {runtime, statusResponse, statusDoc} = require('./globalization-pages.test.js');
const {makeEl} = require('../extension/ui-pages.test.js');
const source = fs.readFileSync(path.join(__dirname, 'yuruna.common.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const settle = async () => { for (let i = 0; i < 12; i++) await new Promise(resolve => setTimeout(resolve, 0)); };
function fixture() {
  let current = JSON.parse(JSON.stringify(statusDoc));
  const env = runtime(html, 'en-US', url => {
    if (url === 'runtime/status.json') return {body: current};
    if (url === 'runtime/current-action.json') return {body: {line: 'At breakpoint', guestKey: current.guests[0].guestKey}};
    if (url === 'runtime/break-active.json') return {body: {guestKey: current.guests[0].guestKey}};
    return statusResponse('index', 'data', url);
  });
  const intervals = [];
  env.box.setInterval = (fn, ms) => { intervals.push({fn, ms}); return intervals.length; };
  let poll;
  vm.runInContext(source, env.box);
  env.box.Yuruna.startVisibilityAwarePolling = opts => { poll = opts.run; return {tick: opts.run}; };
  return Object.assign(env, {intervals, poll: () => poll(), update: value => {current = value;}});
}
async function delayedRefresh() {
  const env = fixture();
  const original = env.box.fetch;
  let release;
  let reads = 0;
  env.box.fetch = url => {
    if (String(url).startsWith('runtime/status.json')) {
      reads++;
      if (reads === 2) return new Promise(resolve => {release = () => original(url).then(resolve);});
    }
    return original(url);
  };
  env.boot();
  const initialReads = reads;
  const timer = env.intervals.find(i => i.ms === 1000);
  assert.ok(timer, 'dashboard countdown started');
  for (let i = 0; i < 180; i++) timer.fn();
  env.poll();
  assert.strictEqual(reads, initialReads, 'countdown and manual refresh must share the in-flight request');
  release();
  await settle();
  // A rendering exception must also release the in-flight guard.
  const measure = env.box.YurunaFirstUsable.measure;
  env.box.YurunaFirstUsable.measure = () => { throw new Error('render failed'); };
  env.poll();
  await settle();
  env.box.YurunaFirstUsable.measure = measure;
  env.poll();
  await settle();
  assert.strictEqual(reads, initialReads + 2, 'completed and failed renders both permit the next refresh');
}
async function latestHeldSnapshot() {
  const env = fixture();
  const list = env.byId['sequence-list'];
  let rendered = '';
  // Model the browser replacing the button when its enclosing HTML is rebuilt.
  Object.defineProperty(list, 'innerHTML', {
    get() { return rendered; },
    set(value) {
      rendered = value;
      if (value.includes('id="break-continue-btn"')) env.byId['break-continue-btn'] = makeEl('button');
    }
  });
  env.boot();
  await settle();
  const firstButton = env.byId['break-continue-btn'];
  assert.strictEqual(typeof firstButton.onclick, 'function');
  const link = makeEl('a');
  list.appendChild(link);
  env.box.document.activeElement = link;
  const old = JSON.parse(JSON.stringify(statusDoc));
  old.sequences[0].name = 'held-old';
  old.overallStatus = 'fail';
  env.update(old);
  env.poll();
  await settle();
  const latest = JSON.parse(JSON.stringify(statusDoc));
  latest.sequences[0].name = 'held-latest';
  latest.overallStatus = 'pass';
  env.update(latest);
  env.poll();
  await settle();
  const latestBanner = env.byId.banner.textContent;
  assert.ok(!rendered.includes('held-latest'), 'focused sequence region defers repaint');
  env.box.document.activeElement = env.box.document.body;
  list.listeners.focusout[0]({relatedTarget: env.box.document.body});
  assert.ok(rendered.includes('held-latest'), 'focus release paints the newest accepted snapshot');
  assert.ok(!rendered.includes('held-old'));
  assert.strictEqual(env.byId.banner.textContent, latestBanner, 'releasing focus cannot roll back the banner');
  assert.notStrictEqual(env.byId['break-continue-btn'], firstButton);
  assert.strictEqual(typeof env.byId['break-continue-btn'].onclick, 'function', 'rebuilt Continue remains wired');
}
function configurationInputSafety() {
  const enumSource = source.match(/function buildEnumInput\(value, parent, key, options\)[\s\S]*?\n    \}/)[0];
  const buildEnum = new Function('t', 'buildCustomSelect', enumSource + '; return buildEnumInput;')((key) => key, opts => opts);
  for (const value of ['information', 'Unexpected']) {
    const parent = {logLevel: value};
    const select = buildEnum(value, parent, 'logLevel', ['Error', 'Information', 'Debug']);
    assert.strictEqual(parent.logLevel, value, 'rendering never edits stored configuration');
    assert.strictEqual(select.value, value === 'information' ? 'Information' : value);
    if (value === 'Unexpected') assert.strictEqual(select.options[0].disabled, true);
    select.onChange('Debug');
    assert.strictEqual(parent.logLevel, 'Debug');
  }
  const start = source.indexOf("document.getElementById('config-discard').addEventListener('click', discardAndExit);");
  const handler = source.slice(start).match(/document.addEventListener\('keydown', function\(e\) \{[\s\S]*?\n    \}\);/)[0];
  let keydown;
  let discarded = 0;
  new Function('document', 'discardAndExit', handler)({addEventListener: (_, fn) => {keydown = fn;}}, () => {discarded++;});
  for (const override of [{defaultPrevented: true}, {isComposing: true}, {keyCode: 229}]) {
    keydown(Object.assign({key: 'Escape', stopPropagation() {}}, override));
  }
  assert.strictEqual(discarded, 0, 'handled or composing Escape cannot discard the editor');
  keydown({key: 'Escape', stopPropagation() {}});
  assert.strictEqual(discarded, 1);
}
Promise.resolve().then(delayedRefresh).then(latestHeldSnapshot).then(configurationInputSafety).then(() => {
  console.log('PASS: status refresh exclusion, latest held repaint, Continue wiring, Escape and enum safety');
}).catch(error => { console.error(error.stack); process.exitCode = 1; });
