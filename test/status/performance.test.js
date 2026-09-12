/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.09.12
  Exercise the performance page's actual rendering functions with a minimal DOM.
  Optional argument: aggregate JSON produced by the generated status handler.
*/
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const assert = require('assert');
const source = fs.readFileSync(path.join(__dirname, 'yuruna.common.js'), 'utf8');
const start = source.indexOf('  function bootPerf() {') + '  function bootPerf() {'.length;
const end = source.indexOf('    function renderAggregates(', start);
assert.ok(start > 30 && end > start, 'performance rendering functions must be available');
function element(name) {
  return {
    name, attributes: {}, children: [], textContent: '', className: '',
    appendChild(child) { this.children.push(child); return child; },
    setAttribute(key, value) { this.attributes[key] = value; }
  };
}
const scope = {
  document: { createElement: element, createElementNS: (_, name) => element(name) },
  Yuruna: { populateHeader() {} }, startBannerPolling() {},
  safeUrl(value) { return value; }, t(value) { return value; }
};
vm.createContext(scope);
vm.runInContext(source.slice(start, end) + '\nthis.render = buildSeqCard; this.flame = buildFlame;', scope);
const payload = process.argv[2] ? JSON.parse(fs.readFileSync(process.argv[2], 'utf8')) : {
  sequences: { startup: Array.from({ length: 4 }, (_, i) => ({
    sequenceInvocationId: 'legacy-' + (i + 1), invocationIdentitySource: 'legacy-inferred',
    cycleStartUtc: '2026-09-11T00:00:00Z', cycleStartedAtUtc: '2026-09-11T00:00:00Z',
    invocationStartedAtUtc: '2026-09-11T00:0' + i + ':00Z', vmName: 'temporary-vm',
    durationMs: 2000, stepCount: 1, failCount: 0, retryFailureCount: 1,
    steps: [
      { name: 'retry', kind: 'retry', startedMs: i * 10000, endedMs: i * 10000 + 2000, durationMs: 2000, outcome: 'pass' },
      { name: 'failed attempt', startedMs: i * 10000, endedMs: i * 10000 + 1000, durationMs: 1000, outcome: 'fail', parentOrdinal: 1 }
    ]
  })) }
};
const runs = payload.sequences.startup;
const card = scope.render('startup', runs, {});
const rows = card.children.find(child => child.className === 'cycle-rows').children;
assert.equal(rows.length, 4, 'all four invocations must have separate rows');
assert.equal(new Set(rows.map(row => row.attributes['data-sequence-invocation-id'])).size, 4);
assert.match(card.children[1].textContent, /4 of 4 runs/);
assert.doesNotMatch(card.children[1].textContent, /failures/, 'superseded attempts must not badge passing runs as failed');
for (const row of rows) {
  const header = row.children[0];
  assert.match(header.children[0].textContent, /run legacy-[1-4]/);
  assert.match(header.children[0].attributes.title, /inferred/);
  assert.equal(header.children[1].className, 'cycle-dur');
  assert.match(header.children[1].attributes.title, /Summed top-level work:/);
}
const diagnostic = JSON.parse(JSON.stringify(runs[0]));
diagnostic.steps[0].diagnosticOutcome = 'timeout';
diagnostic.steps[0].evidenceCaptureDurationMs = 1500;
diagnostic.diagnosticIncompleteCount = 1;
const diagCard = scope.render('diagnostic', [diagnostic], {});
const diagRow = diagCard.children.find(child => child.className === 'cycle-rows').children[0];
assert.match(diagRow.children[0].children[1].textContent, /1 incomplete capture/);
const plot = diagRow.children[1];
const partial = plot.children.find(child => /partial/.test(child.attributes.class || ''));
assert.ok(partial, 'incomplete diagnostic must be visually distinguished');
assert.match(partial.children[0].textContent, /Diagnostic: timeout/);
assert.match(partial.children[0].textContent, /Evidence capture within step: 1.5s/);
const ssh = scope.flame({ steps: [{ name: 'ssh', kind: 'sshFetchAndExecute', startedMs: 0, endedMs: 1000,
  durationMs: 1000, checkpoints: [{ name: 'packages', offsetMs: 50 }], outcome: 'pass' }] });
assert.ok(ssh.nodes.some(node => node.isCkpt && node.name === 'packages'), 'SSH checkpoints must render alongside console checkpoints');
const legacyMissing = scope.render('legacy', [{ durationMs: 2500, failCount: 0, steps: [{ durationMs: 2500 }] }], {});
const missingRow = legacyMissing.children.find(child => child.className === 'cycle-rows').children[0];
assert.match(missingRow.children[0].children[1].textContent, /^work 2.5s/);
assert.match(missingRow.children[0].children[1].attributes.title, /Elapsed interval: unavailable/);
console.log('PASS: performance rendering, repeated invocations, retries and diagnostic outcomes');
