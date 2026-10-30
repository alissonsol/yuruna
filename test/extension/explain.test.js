// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42ab3c16-e5fc-4f3b-a8fa-531ef012ce44
/*
  The explanation primitive in both browser runtimes: Y.explain in the
  extension SDK's yuruna.core.js and Yuruna.explain in the host status pages'
  yuruna.common.js, which do not share a file. Each is run against the same DOM
  stub and held to the same contract, and the pool hosts page is checked to
  route its remediation text through it. Run: node explain.test.js.

  A title attribute reaches only a hovering mouse. The contract is that the
  same text also reaches a keyboard (focus, Enter, Space) and a touch screen
  (a tap), without taking away a link's own action.
*/
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const assert = require('assert');
const {runPage, makeEl, fire} = require('./ui-pages.test.js');

const settle = async () => { for (let i = 0; i < 15; i++) await new Promise(resolve => setTimeout(resolve, 0)); };
function nodes(root, predicate) {
  const found = [];
  (function visit(node) { if (predicate(node)) found.push(node); (node.children || []).forEach(visit); })(root);
  return found;
}
function key(el, name) {
  let prevented = false;
  for (const fn of (el.listeners.keydown || [])) { fn({ type: 'keydown', key: name, target: el, preventDefault() { prevented = true; } }); }
  return prevented;
}

// The status runtime is one large closure; the primitive is lifted out of it
// with the DOM stub the extension tests use.
function statusExplain() {
  const source = fs.readFileSync(path.join(__dirname, '..', 'status', 'yuruna.common.js'), 'utf8');
  const start = source.indexOf('  // --- REGION: Explanations');
  const end = source.indexOf('  function onReady(fn) {', start);
  assert.ok(start > 0 && end > start, 'Yuruna.explain must be present in yuruna.common.js');
  const box = {
    document: { createElement: makeEl },
    YurunaI18n: { t: key => (key === 'status.explain_details' ? 'Details' : key) }
  };
  box.window = box;
  vm.createContext(box);
  vm.runInContext(source.slice(start, end) + '\nthis.explain = explain;', box);
  return box.explain;
}

function checkContract(name, explain) {
  // A plain-text target becomes the disclosure itself.
  const span = makeEl('span');
  span.textContent = 'none';
  const wrap = explain(span, 'Enroll a lab token on the host.');
  assert.strictEqual(wrap.className, 'explain', `${name}: a wrapper is returned to place`);
  assert.deepStrictEqual(wrap.children.length, 2, `${name}: target and details`);
  const details = wrap.children[1];
  assert.strictEqual(wrap.children[0], span);
  assert.strictEqual(span.getAttribute('title'), 'Enroll a lab token on the host.', `${name}: the mouse keeps its tooltip`);
  assert.strictEqual(span.getAttribute('role'), 'button');
  assert.strictEqual(span.getAttribute('tabindex'), '0', `${name}: a keyboard can reach it`);
  assert.strictEqual(span.getAttribute('aria-expanded'), 'false');
  assert.strictEqual(span.getAttribute('aria-controls'), details.id);
  assert.ok(/^yuruna-explain-\d+$/.test(details.id), `${name}: the details carry an id`);
  assert.strictEqual(details.hidden, true);
  assert.strictEqual(details.textContent, 'Enroll a lab token on the host.');
  assert.ok(/\bexplain-target\b/.test(span.className));
  fire(span, 'click');
  assert.strictEqual(details.hidden, false, `${name}: a tap shows the text`);
  assert.strictEqual(span.getAttribute('aria-expanded'), 'true');
  assert.strictEqual(key(span, 'Enter'), true, `${name}: Enter is taken`);
  assert.strictEqual(details.hidden, true, `${name}: Enter hides it again`);
  assert.strictEqual(key(span, ' '), true);
  assert.strictEqual(details.hidden, false, `${name}: Space toggles`);
  assert.strictEqual(key(span, 'a'), false, `${name}: other keys are left alone`);
  assert.strictEqual(details.hidden, false);

  // A link keeps its own action and gets a companion toggle.
  const link = makeEl('a');
  link.setAttribute('href', 'https://repo.test/');
  const linked = explain(link, 'Grant this host read access.');
  assert.strictEqual(linked.children.length, 3, `${name}: link, toggle and details`);
  const toggle = linked.children[1];
  assert.strictEqual(toggle.tagName, 'BUTTON');
  assert.strictEqual(toggle.getAttribute('type'), 'button');
  assert.strictEqual(toggle.textContent, '?');
  assert.strictEqual(toggle.getAttribute('aria-label'), 'Details', `${name}: the toggle has a localized name`);
  assert.strictEqual(toggle.getAttribute('aria-controls'), linked.children[2].id);
  assert.strictEqual(link.getAttribute('role'), null, `${name}: the link stays a link`);
  assert.strictEqual(link.getAttribute('tabindex'), null);
  assert.strictEqual((link.listeners.click || []).length, 0, `${name}: the link's click is not taken`);
  fire(toggle, 'click');
  assert.strictEqual(linked.children[2].hidden, false);
  assert.strictEqual(toggle.getAttribute('aria-expanded'), 'true');

  // With a region, focus or a tap writes the text there; a caller's tabindex is kept.
  const region = makeEl('p');
  region.hidden = true;
  const bar = makeEl('rect');
  bar.setAttribute('tabindex', '-1');
  assert.strictEqual(explain(bar, 'Duration: 2s', region), bar, `${name}: the target itself is returned`);
  assert.strictEqual(bar.getAttribute('tabindex'), '-1', `${name}: a roving tabindex is kept`);
  fire(bar, 'focus');
  assert.strictEqual(region.textContent, 'Duration: 2s');
  assert.strictEqual(region.hidden, false);
  const label = makeEl('span');
  explain(label, 'Summed work: 3s', region);
  assert.strictEqual(label.getAttribute('tabindex'), '0', `${name}: a plain target becomes focusable`);
  fire(label, 'click');
  assert.strictEqual(region.textContent, 'Summed work: 3s');
  const button = makeEl('button');
  explain(button, 'Re-scan', region);
  assert.strictEqual(button.getAttribute('tabindex'), null, `${name}: a control keeps its native focus`);

  // No text, nothing to explain.
  const quiet = makeEl('span');
  assert.strictEqual(explain(quiet, ''), quiet);
  assert.strictEqual(explain(quiet, null), quiet);
  assert.strictEqual(quiet.getAttribute('title'), null);
}

async function hostsPage() {
  const hosts = {
    ok: true, pools: ['default'], targetPoolId: '', hostnamesVisible: true,
    hosts: [{ hostId: '426d17ef0b88426b922180dad1a9e921', hostname: 'box', type: 'kvm', pool: 'default', control: 'none', access: 'denied' }]
  };
  const facts = { ok: true, hosts: { '426d17ef0b88426b922180dad1a9e921': { ok: true,
    frameworkAccess: 'yuruna', frameworkAccessState: 'readable', frameworkUrl: 'https://f.test',
    projectAccess: '', projectAccessState: 'denied', projectUrl: 'https://p.test/private' } } };
  const env = runPage({service: 'pool-control-service', file: 'hosts.html'}, 'en-US', false, 'data', {beforePage: box => {
    const api = box.Y.api;
    box.Y.api = (url, opts) => url === '/api/hosts' ? Promise.resolve(hosts) : (url === '/api/hosts/facts' ? Promise.resolve(facts) : api(url, opts));
  }});
  assert.deepStrictEqual(env.failures, []);
  await settle();
  const rows = env.byId['host-rows'].children;
  assert.strictEqual(rows.length, 1, 'the host row rendered');
  const explained = nodes(rows[0], n => n.className === 'explain');
  const texts = explained.map(w => w.children[w.children.length - 1].textContent);
  assert.ok(texts.some(text => /Set-LabToken\.ps1/.test(text)), 'the control state names its fix inline: ' + JSON.stringify(texts));
  const control = explained.find(w => /Set-LabToken\.ps1/.test(w.children[w.children.length - 1].textContent));
  assert.strictEqual(control.children[0].getAttribute('role'), 'button');
  const denied = explained.find(w => w.children[0].tagName === 'A');
  assert.ok(denied, 'the denied repository keeps its link and gets a toggle');
  assert.strictEqual(denied.children[1].className, 'explain-toggle');
  assert.ok(denied.children[2].textContent.length > 0, 'the denied repository explains what to fix');
}

checkContract('Y.explain (yuruna.core.js)', runPage({service: 'pool-control-service', file: 'hosts.html'}).box.Y.explain);
checkContract('Yuruna.explain (yuruna.common.js)', statusExplain());
hostsPage().then(() => {
  console.log('PASS: Y.explain and Yuruna.explain share one contract (disclosure, companion toggle, details region), and pool hosts route remediation through it');
}).catch(error => { console.error(error.stack); process.exitCode = 1; });
