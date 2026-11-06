/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  GUID: 423b04da-3c01-4ade-bcdb-003a0a239f01
  Version: 2026.11.05
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
const end = source.indexOf('    function buildCycleLinks(', start);
assert.ok(start > 30 && end > start, 'performance rendering functions must be available');
function element(name) {
  const el = {
    name, attributes: {}, children: [], textContent: '', className: '', style: {}, clientWidth: 760, scrollLeft: 0,
    appendChild(child) { this.children.push(child); return child; },
    insertBefore(child) { this.children.unshift(child); return child; },
    setAttribute(key, value) { this.attributes[key] = value; },
    hasAttribute(key) { return Object.prototype.hasOwnProperty.call(this.attributes, key); },
    focus() { focused = this; },
    addEventListener(type, callback) { this.listeners[type] = callback; },
    listeners: {}
  };
  Object.defineProperty(el, 'innerHTML', { set() { this.children = []; } });
  Object.defineProperty(el, 'scrollWidth', { get() {
    return this.children[0] && parseInt(this.children[0].style.width, 10) || this.clientWidth;
  } });
  return el;
}
let focused = null;
const perfMessage = element('div');
const perfBody = element('div');
const zoomInput = element('input');
zoomInput.value = '0';
const zoomValue = element('output');
const fitButton = element('button');
const scope = {
  document: { createElement: element, createElementNS: (_, name) => element(name),
    getElementById(id) { return ({ 'perf-message': perfMessage, 'perf-body': perfBody,
      'perf-zoom': zoomInput, 'perf-zoom-value': zoomValue, 'perf-fit': fitButton })[id] || null; } },
  Yuruna: { populateHeader() {} }, startBannerPolling() {},
  safeUrl(value) { return value; }, t(value) { return value; },
  addEventListener() {}, setTimeout, clearTimeout
};
scope.window = scope;
vm.createContext(scope);
const catalogStart = source.indexOf('// >>> yuruna-i18n embedded block');
const catalogEnd = source.indexOf('// <<< yuruna-i18n embedded block');
vm.runInContext(source.slice(catalogStart, catalogEnd), scope);
scope.t = function (key, args) { return scope.YurunaI18n.t(key, args); };
// The page reaches the shared primitive through window.Yuruna; the real one is
// lifted from the runtime so the chart is checked against what ships.
const explainStart = source.indexOf('  // --- REGION: Explanations');
const explainEnd = source.indexOf('  function onReady(fn) {', explainStart);
assert.ok(explainStart > 0 && explainEnd > explainStart, 'the explain primitive must be available');
vm.runInContext(source.slice(explainStart, explainEnd) + '\nthis.Yuruna.explain = explain;', scope);
vm.runInContext(source.slice(start, end) + '\nthis.render = buildSeqCard; this.flame = buildFlame;' +
  'this.renderChart = renderSeqChart; this.renderMeasured = renderAggregatesMeasured;' +
  'this.redraw = redrawCharts; this.setZoom = function(z) { zoomFactor = z; redrawCharts(); };', scope);
function renderedCard(name, cycles) {
  const card = scope.render(name, cycles, {});
  scope.renderChart(card, Math.max(1, card._perfData.maxSpan), 1, 760);
  return card;
}
function chartRows(card) { return card._perfData.plot.children.find(child => child.className === 'cycle-rows').children; }
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
const card = renderedCard('startup', runs);
const rows = chartRows(card);
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
const diagCard = renderedCard('diagnostic', [diagnostic]);
const diagRow = chartRows(diagCard)[0];
assert.match(diagRow.children[0].children[1].textContent, /1 incomplete capture/);
const plot = diagRow.children[1];
const partial = plot.children.find(child => /partial/.test(child.attributes.class || ''));
assert.ok(partial, 'incomplete diagnostic must be visually distinguished');
assert.match(partial.children[0].textContent, /Diagnostic: timeout/);
assert.match(partial.children[0].textContent, /Evidence capture within step: 1.5s/);
const ssh = scope.flame({ steps: [{ name: 'ssh', kind: 'sshFetchAndExecute', startedMs: 0, endedMs: 1000,
  durationMs: 1000, checkpoints: [{ name: 'packages', offsetMs: 50 }], outcome: 'pass' }] });
assert.ok(ssh.nodes.some(node => node.isCkpt && node.name === 'packages'), 'SSH checkpoints must render alongside console checkpoints');
const legacyMissing = renderedCard('legacy', [{ durationMs: 2500, failCount: 0, steps: [{ durationMs: 2500 }] }]);
const missingRow = chartRows(legacyMissing)[0];
assert.match(missingRow.children[0].children[1].textContent, /^work 2.5s/);
assert.match(missingRow.children[0].children[1].attributes.title, /Elapsed interval: unavailable/);
const longRun = { durationMs: 350000, steps: [{ name: 'long', startedMs: 0, endedMs: 350000, durationMs: 350000 }] };
const shortRun = { durationMs: 8000, steps: [{ name: 'short', startedMs: 0, endedMs: 8000, durationMs: 8000 }] };
scope.renderMeasured({ sequences: { slow: [longRun], fast: [shortRun] } }, {});
const fast = perfBody.children.find(child => child.children[0].textContent === 'fast');
const slow = perfBody.children.find(child => child.children[0].textContent === 'slow');
const fastPlot = chartRows(fast)[0].children[1];
const slowPlot = chartRows(slow)[0].children[1];
assert.equal(fastPlot.attributes.viewBox, slowPlot.attributes.viewBox, 'all sections share one time scale');
assert.ok(Math.abs(fastPlot.children[0].attributes.width - 8000 * 760 / 350000) < 1e-9);
assert.equal(slowPlot.children[0].attributes.width, 760);
assert.equal(fast._perfData.plot.children[1].children[0].attributes.viewBox, '0 0 760 18', 'axis shares row width');
const axisLabels = fast._perfData.plot.children[1].children[0].children.filter(child => child.name === 'text');
assert.equal(axisLabels[axisLabels.length - 1].attributes['text-anchor'], 'end', 'final tick stays inside the plot');
scope.setZoom(4);
assert.equal(fast._perfData.plot.style.width, '3040px');
assert.equal(chartRows(fast)[0].children[1].attributes.height, '21', 'zoom changes width without enlarging rows');
fast._perfData.scroll.scrollLeft = 500;
fast._perfData.scroll.listeners.scroll();
assert.equal(slow._perfData.scroll.scrollLeft, 500, 'panning one section pans the others to the same time');
fast._perfData.scroll.clientWidth = 320;
scope.redraw();
assert.equal(fast._perfData.plot.style.width, '1280px', 'narrow layouts keep the same pixel label height');
assert.equal(chartRows(fast)[0].children[1].attributes.height, '21');
fast._perfData.scroll.clientWidth = 760;
const controlsStart = source.indexOf('    var recalcBtn = document.getElementById(\'perf-recalc\');', end);
const controlsEnd = source.indexOf('    loadAggregates(false);', controlsStart);
assert.ok(controlsStart > end && controlsEnd > controlsStart);
vm.runInContext(source.slice(controlsStart, controlsEnd), scope);
zoomInput.value = '4';
zoomInput.listeners.input();
assert.equal(zoomValue.textContent, '16×');
assert.equal(zoomInput.attributes['aria-valuetext'], '16×');
assert.equal(fast._perfData.plot.style.width, '12160px', 'range input updates every timeline');
fast._perfData.scroll.scrollLeft = 300;
fast._perfData.scroll.listeners.scroll();
fitButton.listeners.click();
assert.equal(zoomInput.value, '0');
assert.equal(zoomValue.textContent, '1×');
assert.equal(fast._perfData.plot.style.width, '760px');
assert.equal(fast._perfData.scroll.scrollLeft, 0);
assert.equal(slow._perfData.scroll.scrollLeft, 0);
vm.runInContext(fs.readFileSync(path.join(__dirname, 'pt-BR.status.js'), 'utf8'), scope);
assert.equal(scope.YurunaI18n.t('status.performance_zoom', {}, 'pt-BR'), 'Zoom do tempo');
assert.equal(scope.YurunaI18n.t('status.performance_fit', {}, 'pt-BR'), 'Mostrar tudo');
scope.YurunaI18n.setLocale('pt-BR');
scope.redraw();
const localizedAxis = fast._perfData.plot.children[1].children[0].children.filter(child => child.name === 'text');
assert.equal(localizedAxis[1].textContent, '50,0s', 'axis decimals follow the selected locale');
// Bar and duration details reach a keyboard and a touch screen, not only a
// hovering mouse: one region per card, one roving tab stop across the cells.
scope.YurunaI18n.setLocale('en-US');
const detailCard = renderedCard('details', [diagnostic]);
const region = detailCard.children.find(child => child.className === 'perf-details');
assert.ok(region, 'each chart card carries a details region');
assert.equal(region.attributes.role, 'status');
assert.match(region.textContent, /Select a duration or a bar/);
const cells = detailCard._perfData.cells;
const detailRow = chartRows(detailCard)[0];
const duration = detailRow.children[0].children[1];
const bars = detailRow.children[1].children.filter(child => /flame-cell/.test(child.attributes.class || ''));
assert.equal(cells[0], duration, 'the duration label leads the card\'s cells');
assert.deepEqual(cells.slice(1), bars, 'every bar joins the card\'s cells in time order');
assert.deepEqual(cells.map(cell => cell.attributes.tabindex), ['0'].concat(bars.map(() => '-1')), 'one tab stop per card');
bars[0].listeners.focus();
assert.match(region.textContent, /Diagnostic: timeout/, 'focusing a bar shows its details');
assert.match(region.textContent, /Evidence capture within step: 1.5s/);
duration.listeners.click();
assert.match(region.textContent, /Summed top-level work:/, 'tapping a duration shows its details');
let prevented = false;
detailCard._perfData.scroll.listeners.keydown({ target: duration, key: 'ArrowRight', preventDefault() { prevented = true; } });
assert.ok(prevented, 'the arrow is taken by the chart');
assert.equal(focused, bars[0], 'the arrow moves focus to the next cell');
assert.deepEqual(cells.map(cell => cell.attributes.tabindex), ['-1', '0'].concat(bars.slice(1).map(() => '-1')));
detailCard._perfData.scroll.listeners.keydown({ target: bars[0], key: 'End', preventDefault() {} });
assert.equal(focused, cells[cells.length - 1]);
detailCard._perfData.scroll.listeners.keydown({ target: cells[cells.length - 1], key: 'Home', preventDefault() {} });
assert.equal(focused, duration);
let ignored = true;
detailCard._perfData.scroll.listeners.keydown({ target: duration, key: 'a', preventDefault() { ignored = false; } });
assert.ok(ignored, 'other keys are left to the page');
const fallbackCard = renderedCard('fallback', [{ durationMs: 2500, failCount: 0, steps: [{ durationMs: 2500 }] }]);
const fallbackRegion = fallbackCard.children.find(child => child.className === 'perf-details');
fallbackCard._perfData.cells[1].listeners.focus();
assert.match(fallbackRegion.textContent, /No per-step timing was recorded/, 'a bar without step timing still explains itself');
console.log('PASS: performance rendering, shared scale, zoom, synchronized pan, narrow layout, diagnostics and reachable details');
