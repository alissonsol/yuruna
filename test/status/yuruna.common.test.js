/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.09.24

  Framework-free checks for test/status/yuruna.common.js. Run: node yuruna.common.test.js
  (exit 0 = pass). No package.json / test runner in the repo, so this uses the Node
  built-in assert + vm modules and a minimal document/window shim -- enough to load the
  browser IIFE and exercise its exported surface plus source-structure guards.

  Covers two yuruna.common.js invariants:
    - renderStatus guards banner/noData (matching applyBanner) so an id drift degrades
      gracefully instead of throwing out of the poll loop;
    - bootIndex reuses the shared BANNER_TEXT via Object.assign instead of a duplicate
      literal, so the two banner tables cannot silently diverge.
*/
'use strict';
var fs = require('fs');
var vm = require('vm');
var assert = require('assert');
var path = require('path');

var file = path.join(__dirname, 'yuruna.common.js');
var src = fs.readFileSync(file, 'utf8');

// U+2014 em-dash via char code so this test file stays plain ASCII.
var EMDASH = String.fromCharCode(0x2014);

function makeEl() {
  return {
    textContent: '', innerHTML: '', className: '', value: '', style: {},
    addEventListener: function () {}, appendChild: function () {},
    setAttribute: function () {}, getAttribute: function () { return null; },
    querySelector: function () { return null; }, querySelectorAll: function () { return []; },
    classList: { add: function () {}, remove: function () {}, toggle: function () {} }
  };
}

// getElementById returns null for every id -> simulates the DOM-id drift the guard defends.
var documentShim = {
  getElementById: function () { return null; },
  createElement: function () { return makeEl(); },
  addEventListener: function () {},
  querySelector: function () { return null; },
  querySelectorAll: function () { return []; },
  title: '', body: makeEl()
};
var windowShim = {
  location: { hostname: 'test', href: '', search: '', pathname: '/' },
  addEventListener: function () {}, removeEventListener: function () {},
  navigator: { userAgent: 'node' },
  localStorage: { getItem: function () { return null; }, setItem: function () {}, removeItem: function () {} },
  setTimeout: function () { return 0; }, clearTimeout: function () {},
  setInterval: function () { return 0; }, clearInterval: function () {}
};
windowShim.window = windowShim;
var sandbox = {
  window: windowShim, document: documentShim, console: console,
  navigator: windowShim.navigator, localStorage: windowShim.localStorage,
  location: windowShim.location,
  fetch: function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve({}); }, text: function () { return Promise.resolve('{}'); } }); },
  setTimeout: function () { return 0; }, clearTimeout: function () {},
  setInterval: function () { return 0; }, clearInterval: function () {}
};
sandbox.globalThis = sandbox;
Object.keys(windowShim).forEach(function (key) {
  if (!Object.prototype.hasOwnProperty.call(sandbox, key)) sandbox[key] = windowShim[key];
});
// Classic browser scripts register catalogs on the global object (`this`),
// which is the same object as window in a real page.
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: 'yuruna.common.js' });

var Y = sandbox.window.Yuruna;
assert.ok(Y, 'window.Yuruna should be mounted after load');

// (1) Defensive contract: applyBanner tolerates a missing #banner (getElementById -> null).
//     renderStatus mirrors this contract for banner + noData.
assert.doesNotThrow(function () {
  Y.applyBanner({ overallStatus: 'pass', guests: [{}] }, null, null);
}, 'applyBanner must not throw when #banner is absent');

// (2) The shared BANNER_TEXT is exported with the five expected keys.
assert.deepStrictEqual(
  Object.keys(Y.BANNER_TEXT).sort(),
  ['fail', 'idle', 'pass', 'running', 'stopped'],
  'BANNER_TEXT must expose idle/running/pass/fail/stopped'
);

// (3) Behavioral equivalence: reusing BANNER_TEXT with only fail overridden must
//     reproduce the index dashboard BANNER table exactly (all five keys identical).
var rebuilt = Object.assign({}, Y.BANNER_TEXT, { fail: 'Incident detected ' + EMDASH + ' see details below' });
var expected = {
  idle: 'No test data available',
  running: 'Test in progress',
  pass: 'All guests operational',
  fail: 'Incident detected ' + EMDASH + ' see details below',
  stopped: 'Test runner stopped'
};
assert.deepStrictEqual(rebuilt, expected, 'Object.assign over BANNER_TEXT must reproduce the index BANNER table');

// (4) Source-structure guards (non-tautological -- they fail if the guards are removed from the source).
//     renderStatus is loop-internal (not exported), so its guard is verified here
//     structurally and behaviorally via the applyBanner contract it mirrors (see 1).
assert.match(src, /function renderStatus[\s\S]*?if \(!banner \|\| !noData \|\| !headerMachine\)/,
  'renderStatus must guard banner/noData/headerMachine before dereferencing them');
assert.match(src, /var BANNER = Object\.assign\(\{\}, BANNER_TEXT,/,
  'bootIndex must build BANNER by reusing BANNER_TEXT, not a duplicate literal');

// The cycle-folder lifecycle-suffix strip is a single shared helper, so a
// history-row URL and a perf-icicle deep-link URL cannot drift apart. The
// trailing-slash-capturing .incomplete strip must appear exactly once (in the
// helper); logFileUrl's bare-anchor variant is a distinct regex and not counted.
assert.match(src, /function stripCycleFolderSuffix\(u\)/,
  'stripCycleFolderSuffix must be defined once as the shared cycle-folder strip');
assert.strictEqual(src.split(".replace(/\\.incomplete(\\/?)$/, '$1')").length - 1, 1,
  'the trailing-slash .incomplete strip must appear once (in stripCycleFolderSuffix), not re-inlined at the two call sites');

// The optional-endpoint "fetch -> JSON or null" shape is the single
// module-level fetchJson; the per-handler jsonOrNull closures are gone, and no
// caller passes a manual ?_= cache-buster into fetchJson (which appends its own),
// so the poll URLs cannot carry a double ?_=X?_=Y.
assert.doesNotMatch(src, /function jsonOrNull/,
  'the per-handler jsonOrNull closures must be consolidated onto module-level fetchJson');
assert.doesNotMatch(src, /fetchJson\([^)]*\?_=/,
  'no fetchJson caller may append its own ?_= buster (fetchJson adds one) -- avoids a double cache-buster');

// (5) Nested-run subtree rendering. The nested helpers are loop-internal (not
//     exported), so verify their presence + wiring structurally. `nestedChildrenIndex`
//     is a pure map->index builder; exercise it directly by evaluating just that
//     function in the sandbox so a real behavioral check backs the source guards.
assert.match(src, /function nestedChildrenIndex\(nested\)/,
  'nestedChildrenIndex must build the parentId -> children index for nested tiles');
assert.match(src, /function renderNestedNode\(node, byParent, data, depth\)/,
  'renderNestedNode must render a nested sub-tile recursively');
assert.match(src, /function renderOrphanNested\(byParent, sequences, guests, data\)/,
  'renderOrphanNested must be the safety net for parentless nested nodes');
assert.match(src, /renderNestedChildren\(seq\.name, byParent, data, 1\)/,
  'each sequence card must graft nested children matched by parentId === seq.name');
assert.match(src, /data\.cycleFolderUrl \+ node\.logRel/,
  'a nested tile must deep-link via the LIVE cycleFolderUrl + node.logRel (survives the .incomplete rename)');

// Behavioral: pull nestedChildrenIndex out of the source and confirm it groups
// by parentId and stable-sorts by startedAt. Non-tautological -- fails if the
// grouping/sort logic regresses.
var nciSrc = src.match(/function nestedChildrenIndex\(nested\)[\s\S]*?\n    \}/);
assert.ok(nciSrc, 'nestedChildrenIndex source must be extractable for the behavioral check');
var nci = new Function(nciSrc[0] + '\nreturn nestedChildrenIndex;')();
var idx = nci({
  'p/b': { id: 'p/b', parentId: 'p', name: 'b', startedAt: '2026-01-01T00:00:02Z' },
  'p/a': { id: 'p/a', parentId: 'p', name: 'a', startedAt: '2026-01-01T00:00:01Z' },
  'p/a/deep': { parentId: 'p/a', name: 'deep' }
});
assert.strictEqual(idx['p'].length, 2, 'two children group under parent p');
assert.strictEqual(idx['p'][0].name, 'a', 'children sort by startedAt (a before b)');
assert.strictEqual(idx['p/a'][0].id, 'p/a/deep', 'a deeper node groups under its own parent id');
assert.strictEqual(idx['p/a'][0].id && idx['p/a'][0].name, 'deep', 'missing id is backfilled from the map key');

// (7) Lab-health hold banner. The gate raises control.lab-hold from the cycle
//     process while a service the host had been reaching is away; status.json
//     mirrors it as labHold/labHoldAreas. Two properties matter and both are
//     silent when they break: the hold must NAME the service (a generic
//     "paused" sends an operator hunting for whoever pressed pause, when the
//     fix is a VM somewhere else), and an operator pause must still win over it.
var pbt = Y.pauseBannerText;
assert.strictEqual(pbt(false, false, 'running', null, false, []), null,
  'no pause and no hold leaves the banner to the run status');
assert.strictEqual(pbt(false, false, 'running', null, true, ['stash-service']),
  'Lab hold -- waiting for stash-service',
  'a hold names the area it is waiting for');
assert.strictEqual(pbt(false, false, 'running', null, true, ['stash-service', 'download-agent-service']),
  'Lab hold -- waiting for stash-service, download-agent-service',
  'multiple held areas are listed');
assert.strictEqual(pbt(false, false, 'running', null, true, []),
  'Lab hold -- waiting for a lab service',
  'a hold with no area list still reads as a hold, not as nothing');
assert.strictEqual(pbt(true, false, 'running', null, true, ['stash-service']),
  'Test pausing (after step)',
  'the operator pause outranks the hold: they are present and did not cause it');
assert.strictEqual(pbt(false, true, 'pass', null, true, ['stash-service']),
  'Test paused',
  'an effective cycle-pause also outranks the hold');

// (8) A step-pause holds the runner while the guest keeps running, so the
//     banner has to say more than that someone pressed pause: how long the hold
//     has run, and that a guest is live under it. Both are what turn a hold that
//     is quietly costing a boot-time prompt into something an operator can see.
//     The age is bucketed on purpose -- the banner is an aria-live region, and a
//     per-minute counter would re-announce itself for as long as the hold lasts.
var pausedAction = { line: '[sequence start] Paused (waiting for resume)', vmName: 'test-guest.ubuntu.server.24-01' };
var ageMinutes = function(m) { return new Date(Date.now() - m * 60000).toISOString(); };
assert.strictEqual(pbt(true, false, 'running', { line: '[1/5] Paused (waiting for resume)' }, false, [], ageMinutes(0)),
  'Test paused',
  'a hold younger than the first bucket reads as a plain pause');
assert.strictEqual(pbt(true, false, 'running', { line: '[1/5] Paused (waiting for resume)' }, false, [], ageMinutes(7)),
  'Test paused -- 5m+',
  'the age is reported at the bucket it has crossed, not to the minute');
assert.strictEqual(pbt(true, false, 'running', pausedAction, false, [], ageMinutes(35)),
  'Test paused -- 30m+, guest test-guest.ubuntu.server.24-01 running',
  'a live guest under the hold is named alongside its age');

// The runner states the pause in a code. That is what makes the sentence
// beside it ordinary prose again: reword it, or translate it, and the badge
// still flips, because nothing reads the words to decide.
assert.strictEqual(pbt(true, false, 'running',
    { code: 'sequence_paused_waiting_resume', line: 'Pausado, aguardando retomada.' }, false, [], ageMinutes(0)),
  'Test paused',
  'the code decides, so a translated sentence is still a recognised pause');
assert.strictEqual(pbt(true, false, 'running',
    { code: 'step_running', line: '[3/9] Paused (waiting for resume)' }, false, [], ageMinutes(0)),
  'Test pausing (after step)',
  'a different code keeps the armed pause from being upgraded by the stale sentence');
assert.strictEqual(pbt(true, false, 'running',
    { line: '[1/5] Paused (waiting for resume)' }, false, [], ageMinutes(0)),
  'Test paused',
  'a sidecar from a runner older than the code field is still read correctly');
assert.strictEqual(pbt(true, false, 'running', pausedAction, false, [], ageMinutes(150)),
  'Test paused -- 2h+, guest test-guest.ubuntu.server.24-01 running',
  'holds past an hour read in hours');
assert.strictEqual(pbt(true, false, 'running', pausedAction, false, []),
  'Test paused -- guest test-guest.ubuntu.server.24-01 running',
  'a missing stamp still names the guest: the flag is the truth about the hold');
assert.strictEqual(pbt(false, false, 'running', pausedAction, false, [], ageMinutes(35)),
  null,
  'no hold means no banner, whatever the stamps say');

// (9) The config editor saves test.config.yml back, and guestSequence in that
//     file is the fallback a cycle reads only when no plan resolves from
//     test/test.runner.yml in the project repository. An edit to that field
//     that silently changes nothing is the worst thing this editor can do, so
//     the field carries a note, the note is actually rendered, and it is fed
//     by the plan the cycle already recorded rather than by a second resolver.
assert.ok(/function guestSequenceNote\(/.test(src),
  'the guestSequence field must carry a note saying what really chooses the guests');
assert.ok(/if \(isguestSequenceArray\(value\)\) \{ children\.appendChild\(guestSequenceNote\(\)\); \}/.test(src),
  'the note must be rendered by the array renderer, not merely defined');
assert.ok(/function loadResolvedPlan\(\)\s*\{[\s\S]{0,200}runtime\/status\.json/.test(src),
  'the note must read the plan the cycle recorded, not resolve one of its own');
assert.ok(/loadGuestFolders\(\),\s*\r?\n\s*loadResolvedPlan\(\)/.test(src),
  'the plan must load with the config, or the note renders before it arrives');

// Config numbers remain typed data while the keyboard owns an unfinished edit.
var numericSource = src.match(/function buildNumberInput\(value, parent, key\)[\s\S]*?\n    \}/);
assert.ok(numericSource, 'numeric editor is present');
var buildNumber = new Function('document', numericSource[0] + '\nreturn buildNumberInput;')({
  createElement: function () {
    return { value: '', attributes: {}, setAttribute: function (name, value) { this.attributes[name] = value; } };
  }
});
var config = { count: 12 };
var numeric = buildNumber(12, config, 'count');
['', '-', '+', '1.', '1e', '1,5', '1,234', 'NaN', 'Infinity', '0x10', '1 000'].forEach(function (raw) {
  numeric.value = raw;
  numeric.onchange();
  assert.strictEqual(config.count, 12, 'incomplete/ambiguous number must not replace config: ' + raw);
  assert.strictEqual(numeric.attributes['aria-invalid'], 'true');
});
numeric.value = '23';
numeric.oncompositionstart();
numeric.onchange();
numeric.onkeydown({ key: 'Enter', preventDefault: function () {} });
assert.strictEqual(config.count, 12, 'composition cannot commit its intermediate value');
numeric.oncompositionend();
assert.strictEqual(config.count, 12, 'composition ending alone is not an explicit commit');
numeric.onchange();
assert.strictEqual(config.count, 23);
numeric.value = '-0.25';
numeric.onblur();
assert.strictEqual(config.count, -0.25, 'valid blur commits a typed decimal');
numeric.value = '99';
numeric.onkeydown({ key: 'Escape', preventDefault: function () {} });
assert.strictEqual(config.count, -0.25, 'cancel preserves last committed number');
assert.strictEqual(numeric.value, '-0.25');
numeric.value = '6.02e2';
numeric.onkeydown({ key: 'Enter', preventDefault: function () {} });
assert.strictEqual(config.count, 602);
assert.strictEqual(numeric.attributes['aria-invalid'], 'false');


// Exercise the actual combobox with legacy key codes and no Pointer Events.
var selectSource = src.match(/function buildCustomSelect\(opts\)[\s\S]*?\n    \}/);
assert.ok(selectSource, 'custom select implementation is present');
function selectElement() {
  var el = {children: [], attributes: {}, className: '', hidden: false, offsetTop: 0, offsetHeight: 20, scrollTop: 0, clientHeight: 100,
    appendChild: function (child) { this.children.push(child); },
    setAttribute: function (name, value) { this.attributes[name] = value; },
    removeAttribute: function (name) { delete this.attributes[name]; },
    addEventListener: function () {}, contains: function (node) { return this === node || this.children.indexOf(node) >= 0; }};
  el.classList = {add: function (name) { if (el.className.split(' ').indexOf(name) < 0) el.className += ' ' + name; },
    remove: function (name) { el.className = el.className.split(' ').filter(function (part) { return part !== name; }).join(' '); },
    toggle: function (name, selected) { if (selected) this.add(name); else this.remove(name); }};
  return el;
}
var selectDocument = {createElement: selectElement, addEventListener: function () {}, removeEventListener: function () {}, activeElement: null};
var buildSelect = new Function('window', 'document', 'var configKeyUid = 0;\n' + selectSource[0] + '\nreturn buildCustomSelect;')({}, selectDocument);
var choices = [];
var combo = buildSelect({value:'a', options:[{value:'a',label:'Alpha'},{value:'disabled',label:'Unavailable',disabled:true},{value:'b',label:'Beta'}], onChange:function (value) { choices.push(value); }});
var stopped = 0;
function selectKey(code) { combo.onkeydown({keyCode:code,preventDefault:function(){},stopPropagation:function(){stopped++;}}); }
selectKey(40);
assert.strictEqual(combo.attributes['aria-expanded'], 'true');
selectKey(40);
assert.strictEqual(combo.attributes['aria-activedescendant'], combo.children[2].children[2].id, 'arrows skip disabled values');
selectKey(27);
assert.strictEqual(stopped, 1, 'Escape cannot discard the surrounding config edit');
assert.deepStrictEqual(choices, [], 'navigation and cancellation do not commit values');
selectKey(40); selectKey(40); selectKey(13);
assert.deepStrictEqual(choices, ['b']);
assert.strictEqual(combo.children[2].children[2].attributes['aria-selected'], 'true');
assert.strictEqual(combo.attributes['aria-expanded'], 'false');

// Functional query/path bytes cannot become translator-owned messages.
var querySource = fs.readFileSync(path.join(__dirname, '../extension/download-agent-service/server/internal/httpsrv/web/assets/images.js'),'utf8').match(/function query\(img\)[\s\S]*?\n  \}/)[0];
var query = new Function(querySource + '\nreturn query;')();
assert.strictEqual(query({arch:'a&b',variant:'x y'}), '?arch=a%26b&variant=x%20y');
var logSource = src.match(/function logFileUrl\(cycleStartUtc, hostKey, gitCommit, cycleFolderUrl\)[\s\S]*?\n    \}/)[0];
var logFile = new Function(logSource + '\nreturn logFileUrl;')();
assert.strictEqual(logFile('', '', '', 'log/000001.date.host.incomplete/'), 'log/000001.date.host.incomplete/000001.date.host.html');
assert.strictEqual(logFile('2026-09-18T12:00:00Z', 'host', 'abc', ''), 'log/2026-09-18T12-00-00Z.host.abc.html');

console.log('PASS: yuruna.common.js');
