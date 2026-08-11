// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
/*
  Framework-free checks for this directory's index.js (the stashes list page).
  Run: node index.test.js (exit 0 = pass). There is no JS test runner in the repo,
  so this drives the page through a minimal DOM/fetch shim, the same way
  common.test.js does for common.js. index.js is an IIFE with no exports, so it is
  concatenated after common.js and exercised through the elements it wires.

  Covers the selection + delete surface:
    - a remote-host row (which the daemon refuses to DELETE) gets no checkbox and
      no Delete button, so the page offers no control the server would reject;
    - a browser the daemon will not accept a delete FROM gets the same treatment
      on every row, plus one line naming the address it was seen as;
    - "All" checks/unchecks exactly the selectable rows and drives the enabled
      state of "Delete selected";
    - the auto-refresh countdown parks while rows are selected, so a poll cannot
      re-render the table out from under a half-built selection;
    - a per-row Delete removes that row without re-fetching the list, and moves
      the count and the paging offset with it;
    - a bulk delete confirms first, sends one DELETE per selected row, then
      reloads the list.
*/
'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');

const commonSrc = fs.readFileSync(path.join(__dirname, 'common.js'), 'utf8');
const indexSrc = fs.readFileSync(path.join(__dirname, 'index.js'), 'utf8');

// --- minimal DOM ------------------------------------------------------------

function makeText(s) { return { nodeType: 3, textContent: s, parentNode: null }; }

function makeEl(tag) {
  return {
    nodeType: 1,
    tagName: tag,
    className: '',
    textContent: '',
    title: '',
    value: '',
    checked: false,
    disabled: false,
    indeterminate: false,
    hidden: false,
    rows: 1,
    style: {},
    attrs: {},
    children: [],
    parentNode: null,
    listeners: {},
    get firstChild() { return this.children.length ? this.children[0] : null; },
    setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'disabled') this.disabled = true; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    append(...kids) {
      for (const kid of kids) {
        const node = (kid && kid.nodeType) ? kid : makeText(String(kid));
        node.parentNode = this;
        this.children.push(node);
      }
    },
    prepend(kid) { kid.parentNode = this; this.children.unshift(kid); },
    removeChild(kid) {
      const i = this.children.indexOf(kid);
      if (i >= 0) this.children.splice(i, 1);
      kid.parentNode = null;
      return kid;
    },
    querySelector() { return null; },
  };
}

// The ids index.html carries. getElementById returns null for anything else, which
// is how the page's optional chrome (header/menu) stays inert under the shim.
const PAGE_IDS = ['q', 'class', 'host', 'refresh', 'rows', 'status', 'msg', 'more',
  'delete-note', 'pick-all', 'delete-selected', 'footer-ip-list', 'last-loaded',
  'countdown', 'footer-refresh'];

// Page-scoped state. bootPage rebuilds all of it and runs the scripts in a fresh
// context, so a second page can be raised under different host facts -- the
// delete gate is answered per browser, and its "no" is only observable on a page
// that loaded under it.
let byId, ticks, calls, corpus, confirmAnswer, confirmed, hostinfo;

function respond(body) { return Promise.resolve({ ok: true, json: () => Promise.resolve(body) }); }

function fakeFetch(p, o) {
  const method = (o && o.method) || 'GET';
  calls.push({ path: p, method });
  if (p === '/api/hostinfo') return respond(Object.assign({ ok: true, serverIps: '10.0.0.2', version: '1', localHostId: 'h1' }, hostinfo));
  if (p.startsWith('/api/stashes?')) return respond({ ok: true, total: corpus.length, stashes: corpus.slice() });
  if (method === 'DELETE' && p.startsWith('/api/stashes/')) {
    const id = p.split('/').pop();
    corpus = corpus.filter((s) => s.id !== id);
    return respond({ ok: true });
  }
  return respond({ ok: true });
}

function bootPage(info) {
  hostinfo = info;
  byId = {};
  for (const id of PAGE_IDS) byId[id] = makeEl('div');
  byId.countdown.textContent = '60';
  ticks = [];   // captured setInterval callbacks (the footer's 1 s tick)
  calls = [];   // every fetch: { path, method }
  confirmAnswer = true;
  confirmed = 0;
  // Server-side corpus the stub serves and deletes from, so a reload after a bulk
  // delete returns what actually survived rather than a canned response.
  corpus = [
    { id: 'aaa', local: true, hostId: 'h1', permalink: '/s/h1/2026/07/06/aaa', originalFilename: 'a.txt', username: 'u', sizeBytes: 10, createdAt: '2026-07-06T00:00:00Z', status: 'complete', contentClass: 'text' },
    { id: 'bbb', local: true, hostId: 'h1', permalink: '/s/h1/2026/07/06/bbb', originalFilename: 'b.txt', username: 'u', sizeBytes: 20, createdAt: '2026-07-06T00:00:00Z', status: 'complete', contentClass: 'text' },
    { id: 'ccc', local: false, hostId: 'h2', permalink: '/s/h2/2026/07/06/ccc', originalFilename: 'c.txt', username: 'u', sizeBytes: 30, createdAt: '2026-07-06T00:00:00Z', status: 'complete', contentClass: 'text' },
  ];

  const sandbox = {
    console,
    URL,
    URLSearchParams,
    AbortController,
    Date,
    Math,
    Number,
    setTimeout,
    clearTimeout,
    setInterval: (fn) => { ticks.push(fn); return ticks.length; },
    fetch: (p, o) => fakeFetch(p, o),
    confirm: (msg) => { confirmed++; assert.match(msg, /cannot be undone/, 'bulk delete warns the action is final'); return confirmAnswer; },
    location: { origin: 'https://stash.test', href: '', reload() {} },
    document: {
      readyState: 'complete',
      hidden: false,
      createElement: makeEl,
      createTextNode: makeText,
      getElementById: (id) => byId[id] || null,
      addEventListener() {},
    },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(commonSrc + '\n;globalThis.__Y = Y;\n' + indexSrc, sandbox, { filename: 'index-page.js' });
}

// The page under test throughout: a browser the daemon accepts deletes from.
bootPage({ clientIp: '10.0.0.9', canDelete: true });

// --- helpers ----------------------------------------------------------------

const settle = () => new Promise((r) => setTimeout(r, 0));
function fire(el, type) {
  let stopped = false;
  const ev = { stopPropagation() { stopped = true; } };
  for (const fn of (el.listeners[type] || [])) fn(ev);
  return stopped;
}
const rowsOf = () => byId.rows.children;
const cellOf = (tr, i) => tr.children[i];
const pickOf = (tr) => cellOf(tr, 0).children[0] || null;           // leading select column
const delOf = (tr) => cellOf(tr, tr.children.length - 1).children[0] || null; // trailing action column
const listLoads = () => calls.filter((c) => c.path.startsWith('/api/stashes?')).length;

(async function () {
  await settle();

  // (1) Initial render: one row per stash, and the remote row carries neither
  // control -- delete is local-host-only, so the page shows no button the daemon
  // would answer with a 403.
  assert.strictEqual(rowsOf().length, 3, 'three rows render');
  assert.ok(pickOf(rowsOf()[0]) && delOf(rowsOf()[0]), 'a local row has a checkbox and a Delete button');
  assert.strictEqual(pickOf(rowsOf()[2]), null, 'the remote row has no checkbox');
  assert.strictEqual(delOf(rowsOf()[2]), null, 'the remote row has no Delete button');
  assert.strictEqual(byId.status.textContent, '3 stashes (showing 3)', 'status counts every stash');

  // (2) Both controls stop the click, so acting on a row never also opens it.
  assert.ok(fire(cellOf(rowsOf()[0], 0), 'click'), 'the select cell stops the row click');
  assert.ok(fire(cellOf(rowsOf()[0], rowsOf()[0].children.length - 1), 'click'), 'the action cell stops the row click');

  // (3) Nothing selected: the bulk button is off, "All" is available.
  assert.strictEqual(byId['delete-selected'].disabled, true, 'Delete selected is disabled with no selection');
  assert.strictEqual(byId['pick-all'].disabled, false, 'All is enabled while selectable rows exist');

  // (4) "All" checks exactly the selectable rows and enables the bulk button.
  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  assert.strictEqual(pickOf(rowsOf()[0]).checked, true, 'All checks the first local row');
  assert.strictEqual(pickOf(rowsOf()[1]).checked, true, 'All checks the second local row');
  assert.strictEqual(byId['delete-selected'].disabled, false, 'Delete selected enables once rows are selected');

  // (5) The countdown parks while a selection is pending: 60 ticks (a full
  // interval) neither decrement it nor trigger the auto-refresh that would
  // re-render the table and drop the selection.
  const before = listLoads();
  for (let i = 0; i < 60; i++) for (const t of ticks) t();
  assert.strictEqual(String(byId.countdown.textContent), '60', 'the countdown freezes while rows are selected');
  assert.strictEqual(listLoads(), before, 'no auto-refresh fires while rows are selected');

  // (6) Unchecking one row leaves a partial selection; unchecking all releases
  // both the bulk button and the countdown.
  pickOf(rowsOf()[1]).checked = false;
  fire(pickOf(rowsOf()[1]), 'change');
  assert.strictEqual(byId['pick-all'].indeterminate, true, 'All goes indeterminate on a partial selection');
  byId['pick-all'].checked = false;
  fire(byId['pick-all'], 'change');
  assert.strictEqual(pickOf(rowsOf()[0]).checked, false, 'unchecking All clears every row');
  assert.strictEqual(byId['delete-selected'].disabled, true, 'Delete selected disables again when nothing is selected');
  for (const t of ticks) t();
  assert.strictEqual(String(byId.countdown.textContent), '59', 'the countdown resumes once the selection is cleared');

  // (7) A declined bulk confirmation deletes nothing.
  confirmAnswer = false;
  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  fire(byId['delete-selected'], 'click');
  await settle();
  assert.strictEqual(confirmed, 1, 'the bulk delete asks for confirmation');
  assert.strictEqual(calls.filter((c) => c.method === 'DELETE').length, 0, 'a declined confirmation sends no DELETE');
  assert.strictEqual(rowsOf().length, 3, 'a declined confirmation leaves every row in place');
  byId['pick-all'].checked = false;
  fire(byId['pick-all'], 'change');

  // (8) Per-row Delete: the row goes, the counts follow it, and the list is NOT
  // re-fetched -- the operator keeps their position on the page.
  const loadsBefore = listLoads();
  fire(delOf(rowsOf()[0]), 'click');
  await settle();
  assert.deepStrictEqual(calls[calls.length - 1], { path: '/api/stashes/h1/2026/07/06/aaa', method: 'DELETE' }, 'the row DELETEs its own permalink');
  assert.strictEqual(rowsOf().length, 2, 'the deleted row leaves the table');
  assert.strictEqual(byId.status.textContent, '2 stashes (showing 2)', 'the count drops with the row');
  assert.strictEqual(listLoads(), loadsBefore, 'a per-row delete does not reload the list');

  // (9) Bulk delete: one DELETE per selected row, then a reload showing what
  // survived (here the remote row, which was never selectable).
  confirmAnswer = true;
  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  fire(byId['delete-selected'], 'click');
  await settle();
  await settle();
  assert.deepStrictEqual(calls.filter((c) => c.method === 'DELETE').map((c) => c.path),
    ['/api/stashes/h1/2026/07/06/aaa', '/api/stashes/h1/2026/07/06/bbb'],
    'every delete so far targeted its own row and no other');
  assert.strictEqual(listLoads(), loadsBefore + 1, 'a bulk delete reloads the list afterward');
  assert.strictEqual(rowsOf().length, 1, 'only the undeletable remote row remains');
  assert.strictEqual(byId.status.textContent, '1 stash (showing 1)', 'the reloaded count is the server\'s, singular');
  assert.strictEqual(byId['delete-selected'].disabled, true, 'the reloaded page starts with nothing selected');
  assert.strictEqual(byId['pick-all'].disabled, true, 'All is disabled when no row is selectable');

  // (10) The same corpus, seen by a browser the daemon will not accept a delete
  // FROM: every row loses its controls -- including the two owned by this very
  // host -- and the page states the reason once, naming the address the daemon
  // saw. That address is the operator's only way to tell "wrong machine" from
  // "this VM was built with the wrong host IP".
  bootPage({ clientIp: '192.0.2.55', canDelete: false });
  await settle();
  assert.strictEqual(rowsOf().length, 3, 'every row still renders when delete is off');
  assert.strictEqual(pickOf(rowsOf()[0]), null, 'a local row has no checkbox when this browser may not delete');
  assert.strictEqual(delOf(rowsOf()[0]), null, 'a local row has no Delete button when this browser may not delete');
  assert.strictEqual(byId['pick-all'].disabled, true, 'All is disabled when no row is selectable');
  assert.strictEqual(byId['delete-selected'].disabled, true, 'Delete selected is disabled when no row is selectable');
  const note = byId['delete-note'].children[0];
  assert.ok(note, 'the page explains why delete is not on offer');
  assert.match(note.textContent, /192\.0\.2\.55/, 'the note names the address the daemon saw');

  // (11) The same page for a browser that MAY delete carries no such note --
  // the explanation appears only where it changes what is on screen.
  bootPage({ clientIp: '10.0.0.9', canDelete: true });
  await settle();
  assert.strictEqual(byId['delete-note'].children.length, 0, 'no note when the controls are on offer');
  assert.strictEqual(calls.filter((c) => c.path === '/api/hostinfo').length, 1,
    'the three consumers of host facts share one request');

  console.log('PASS: index.js');
})().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
