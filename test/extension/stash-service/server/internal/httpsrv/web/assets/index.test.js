// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
/*
  Framework-free checks for this directory's index.js (the stashes list page).
  Run: node index.test.js (exit 0 = pass). There is no JS test runner in the repo,
  so this drives the page through a minimal DOM/fetch shim, the same way
  common.test.js does. index.js is an IIFE with no exports, so the three scripts
  a page loads -- the SDK's shared runtime, this service's common.js, then
  index.js -- are run in that order and the page is exercised through the
  elements it wires.

  Covers the selection + delete surface:
    - an unlocked browser gets a checkbox and a Delete on EVERY row, another
      host's included -- the daemon writes to the whole stash share;
    - a locked browser gets neither, on any row, plus one line saying so and the
      lab-token prompt revealed;
    - "All" checks/unchecks exactly the selectable rows and drives the enabled
      state of "Delete selected";
    - the auto-refresh countdown parks while rows are selected, so a poll cannot
      re-render the table out from under a half-built selection;
    - a per-row Delete removes that row without re-fetching the list, and moves
      the count and the paging offset with it;
    - a bulk delete confirms first, sends ONE request naming every selected
      stash, then reloads the list;
    - a per-stash refusal inside that one response is reported and does not hide
      the deletes that worked.
*/
'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');

const coreSrc = fs.readFileSync(path.join(__dirname, '..', '..', '..', '..', '..', '..',
  'extension-sdk', 'webui', 'assets', 'yuruna.core.js'), 'utf8');
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
    tabIndex: -1,
    get firstChild() { return this.children.length ? this.children[0] : null; },
    get firstElementChild() { return this.children.filter((c) => c.nodeType === 1)[0] || null; },
    get lastElementChild() { const e = this.children.filter((c) => c.nodeType === 1); return e[e.length - 1] || null; },
    setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'disabled') this.disabled = true; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); },
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    removeEventListener() {},
    focus() {},
    // The runtime builds every tree with appendChild, never ChildNode.append:
    // the browser baseline it targets does not carry the latter.
    appendChild(kid) {
      const node = (kid && kid.nodeType) ? kid : makeText(String(kid));
      node.parentNode = this;
      this.children.push(node);
      return node;
    },
    insertBefore(kid, ref) {
      const i = this.children.indexOf(ref);
      kid.parentNode = this;
      this.children.splice(i < 0 ? 0 : i, 0, kid);
      return kid;
    },
    removeChild(kid) {
      const i = this.children.indexOf(kid);
      if (i >= 0) this.children.splice(i, 1);
      kid.parentNode = null;
      return kid;
    },
    contains(node) {
      if (!node) { return false; }
      if (node === this) { return true; }
      return this.children.some((c) => c.nodeType === 1 && c.contains && c.contains(node));
    },
    closest() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    scrollIntoView() {},
  };
}

// The ids index.html carries. getElementById returns null for anything else, which
// is how the page's optional chrome (header/menu) stays inert under the shim.
const SORT_KEYS = ['type', 'id', 'name', 'host', 'user', 'size', 'created', 'status'];
const PAGE_IDS = ['q', 'class', 'host', 'refresh', 'rows', 'status', 'msg', 'more',
  'delete-note', 'pick-all', 'delete-selected', 'footer-ip-list', 'last-loaded',
  'countdown', 'footer-refresh', 'login', 'login-form', 'lab-token', 'login-error',
  'gate-unconfigured']
  // Each sortable column carries a header cell (which holds aria-sort) and the
  // button inside it (which takes the click).
  .concat(SORT_KEYS.map((k) => 'th-' + k))
  .concat(SORT_KEYS.map((k) => 'sort-' + k));

// Page-scoped state. bootPage rebuilds all of it and runs the scripts in a fresh
// context, so a second page can be raised under different host facts -- the
// delete gate is answered per browser, and its "no" is only observable on a page
// that loaded under it.
let byId, ticks, calls, corpus, confirmAnswer, confirmed, session, refuse, pageBody, failDelete;

function respond(body) { return Promise.resolve({ ok: true, json: () => Promise.resolve(body) }); }

// Whether the page barrier (Y.block) is up right now. Read at the moment a
// request is made, which is the only way to observe a state that exists solely
// between two awaits.
function blocked() {
  return pageBody.children.some((c) => String(c.className).split(' ')[0] === 'blocking');
}

function fakeFetch(p, o) {
  const method = (o && o.method) || 'GET';
  let body = null;
  if (o && typeof o.body === 'string') {
    try { body = JSON.parse(o.body); } catch (e) { body = null; }
  }
  calls.push({ path: p, method, body, blocked: blocked() });
  if (p === '/api/hostinfo') return respond({ ok: true, serverIps: '10.0.0.2', version: '1', localHostId: 'h1' });
  if (p === '/api/session') return respond(Object.assign({ ok: true }, session));
  if (p === '/api/login') { session = { authed: true, labToken: true, configured: true }; return respond({ ok: true }); }
  if (p.startsWith('/api/stashes?')) return respond({ ok: true, total: corpus.length, stashes: corpus.slice() });
  // The bulk route: one request naming every selected stash, answered with one
  // verdict each. `refuse` names an id the daemon rejects, so the page's
  // handling of a partial failure is exercised against a real response shape.
  if (p === '/api/stashes/delete' && failDelete) {
    // A refusal of the whole request, not a per-stash verdict: what it proves is
    // that the barrier comes down on the failure path too, which is the one way
    // this feature could leave the page permanently unusable.
    return Promise.resolve({ ok: false, status: 503, json: () => Promise.resolve({ ok: false, error: 'share is offline' }) });
  }
  if (p === '/api/stashes/delete') {
    const results = body.stashes.map((s) => (s.id === refuse
      ? { id: s.id, hostId: s.hostId, ok: false, error: 'stash not found' }
      : { id: s.id, hostId: s.hostId, ok: true }));
    corpus = corpus.filter((s) => !results.some((r) => r.ok && r.id === s.id));
    return respond({ ok: true, requested: results.length, deleted: results.filter((r) => r.ok).length, failed: results.filter((r) => !r.ok).length, results });
  }
  if (method === 'DELETE' && p.startsWith('/api/stashes/')) {
    const id = p.split('/').pop();
    corpus = corpus.filter((s) => s.id !== id);
    return respond({ ok: true });
  }
  return respond({ ok: true });
}

function bootPage(sess) {
  session = sess;
  refuse = null;
  byId = {};
  for (const id of PAGE_IDS) byId[id] = makeEl('div');
  byId.countdown.textContent = '60';
  // The barrier is appended to <body>, so the shim needs one to append to.
  pageBody = makeEl('body');
  failDelete = false;
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
    clearInterval() {},
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    FormData,
    Blob,
    fetch: (p, o) => fakeFetch(p, o),
    confirm: (msg) => { confirmed++; assert.match(msg, /cannot be undone/, 'bulk delete warns the action is final'); return confirmAnswer; },
    location: { origin: 'https://stash.test', href: '', hash: '', pathname: '/', search: '', reload() {} },
    document: {
      readyState: 'complete',
      hidden: false,
      body: pageBody,
      createElement: makeEl,
      createTextNode: makeText,
      getElementById: (id) => byId[id] || null,
      addEventListener() {},
      removeEventListener() {},
      activeElement: null,
    },
  };
  // The scripts address the browser through `window`, so it has to be the
  // context itself -- a separate object would hand the runtime a different
  // setInterval from the one these ticks are captured through.
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  // Loaded in page order: shared runtime, service layer, page.
  vm.runInContext(coreSrc, sandbox, { filename: 'yuruna.core.js' });
  vm.runInContext(commonSrc, sandbox, { filename: 'common.js' });
  vm.runInContext(indexSrc, sandbox, { filename: 'index.js' });
}

// The page under test throughout: a browser that has been through the gate.
const UNLOCKED = { authed: true, labToken: true, configured: true };
const LOCKED = { authed: false, labToken: true, configured: true };
bootPage(UNLOCKED);

// --- helpers ----------------------------------------------------------------

const settle = () => new Promise((r) => setTimeout(r, 0));
function fire(el, type) {
  let stopped = false;
  const ev = { stopPropagation() { stopped = true; }, preventDefault() {} };
  for (const fn of (el.listeners[type] || [])) fn(ev);
  return stopped;
}
const rowsOf = () => byId.rows.children;
const cellOf = (tr, i) => tr.children[i];
const pickOf = (tr) => cellOf(tr, 0).children[0] || null;           // leading select column
const delOf = (tr) => cellOf(tr, tr.children.length - 1).children[0] || null; // trailing action column
const listLoads = () => calls.filter((c) => c.path.startsWith('/api/stashes?')).length;
const bulkCalls = () => calls.filter((c) => c.path === '/api/stashes/delete');

(async function () {
  await settle();

  // (1) Initial render: one row per stash, every one of them deletable. The
  // third is owned by another host and carries the same controls as the rest --
  // the daemon writes to every host's folder on the share, so withholding them
  // would hide a delete the server would have accepted.
  assert.strictEqual(rowsOf().length, 3, 'three rows render');
  assert.ok(pickOf(rowsOf()[0]) && delOf(rowsOf()[0]), 'a local row has a checkbox and a Delete button');
  assert.ok(pickOf(rowsOf()[2]), 'the remote row has a checkbox too');
  assert.ok(delOf(rowsOf()[2]), 'the remote row has a Delete button too');
  assert.strictEqual(byId.status.textContent, '3 stashes (showing 3)', 'status counts every stash');
  assert.strictEqual(byId.login.hidden, true, 'an unlocked browser is not asked for the lab token');

  // (2) Both controls stop the click, so acting on a row never also opens it.
  assert.ok(fire(cellOf(rowsOf()[0], 0), 'click'), 'the select cell stops the row click');
  assert.ok(fire(cellOf(rowsOf()[0], rowsOf()[0].children.length - 1), 'click'), 'the action cell stops the row click');

  // (3) Nothing selected: the bulk button is off, "All" is available.
  assert.strictEqual(byId['delete-selected'].disabled, true, 'Delete selected is disabled with no selection');
  assert.strictEqual(byId['pick-all'].disabled, false, 'All is enabled while selectable rows exist');

  // (4) "All" checks every row and enables the bulk button.
  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  assert.strictEqual(pickOf(rowsOf()[0]).checked, true, 'All checks the first row');
  assert.strictEqual(pickOf(rowsOf()[2]).checked, true, 'All checks the remote row as well');
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
  assert.strictEqual(bulkCalls().length, 0, 'a declined confirmation sends no request');
  assert.strictEqual(rowsOf().length, 3, 'a declined confirmation leaves every row in place');
  byId['pick-all'].checked = false;
  fire(byId['pick-all'], 'change');

  // (8) Per-row Delete: the row goes, the counts follow it, and the list is NOT
  // re-fetched -- the operator keeps their position on the page.
  // The answer is set back to yes first: case (7) above left it at no, and a
  // declined row delete would look exactly like a row delete that never fired.
  confirmAnswer = true;
  const loadsBefore = listLoads();
  fire(delOf(rowsOf()[0]), 'click');
  await settle();
  assert.deepStrictEqual(calls[calls.length - 1].path, '/api/stashes/h1/2026/07/06/aaa', 'the row DELETEs its own permalink');
  assert.strictEqual(calls[calls.length - 1].method, 'DELETE', 'a single row still uses the REST verb');
  assert.strictEqual(rowsOf().length, 2, 'the deleted row leaves the table');
  assert.strictEqual(byId.status.textContent, '2 stashes (showing 2)', 'the count drops with the row');
  assert.strictEqual(listLoads(), loadsBefore, 'a per-row delete does not reload the list');

  // (9) Bulk delete: ONE request naming every selected stash -- including the
  // remote one -- then a reload showing what survived.
  confirmAnswer = true;
  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  fire(byId['delete-selected'], 'click');
  await settle();
  await settle();
  assert.strictEqual(bulkCalls().length, 1, 'the whole selection goes in one request');
  assert.deepStrictEqual(bulkCalls()[0].body.stashes, [
    { hostId: 'h1', year: '2026', month: '07', day: '06', id: 'bbb' },
    { hostId: 'h2', year: '2026', month: '07', day: '06', id: 'ccc' },
  ], 'every selected stash is named by host and date, the remote one included');
  assert.strictEqual(listLoads(), loadsBefore + 1, 'a bulk delete reloads the list afterward');
  assert.strictEqual(rowsOf().length, 0, 'nothing remains');
  assert.strictEqual(byId['delete-selected'].disabled, true, 'the reloaded page starts with nothing selected');

  // (10) A per-stash refusal inside that one response is reported, and does not
  // hide the deletes that worked alongside it.
  bootPage(UNLOCKED);
  await settle();
  refuse = 'bbb';
  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  fire(byId['delete-selected'], 'click');
  await settle();
  await settle();
  assert.strictEqual(rowsOf().length, 1, 'the refused stash is the only row left');
  const err = byId.msg.children[0];
  assert.ok(err, 'the page reports the refusal');
  assert.match(err.textContent, /1 of 3 could not be deleted/, 'the report counts the refusal against the selection');
  assert.match(err.textContent, /bbb .*not found/, 'the report names the stash and the reason the daemon gave');

  // (11) The same corpus seen by a LOCKED browser: no row offers a control --
  // there is nothing to press that the daemon would refuse -- the reason is
  // stated once, and the lab-token prompt is revealed.
  bootPage(LOCKED);
  await settle();
  assert.strictEqual(rowsOf().length, 3, 'every row still renders when delete is locked');
  assert.strictEqual(pickOf(rowsOf()[0]), null, 'a row has no checkbox while the page is locked');
  assert.strictEqual(delOf(rowsOf()[0]), null, 'a row has no Delete button while the page is locked');
  assert.strictEqual(byId['pick-all'].disabled, true, 'All is disabled when no row is selectable');
  assert.strictEqual(byId['delete-selected'].disabled, true, 'Delete selected is disabled when no row is selectable');
  assert.strictEqual(byId.login.hidden, false, 'the lab-token prompt is shown to a locked browser');
  const note = byId['delete-note'].children[0];
  assert.ok(note, 'the page explains why delete is not on offer');
  assert.match(note.textContent, /Unlock actions/, 'the note says how to get the controls back');

  // (12) Unlocking in place: the code goes to /api/login and the page re-renders
  // with its controls, without a reload that would lose the operator's place.
  byId['lab-token'].value = 'ABC123';
  fire(byId['login-form'], 'submit');
  await settle();
  await settle();
  const login = calls.filter((c) => c.path === '/api/login');
  assert.strictEqual(login.length, 1, 'the lab token is submitted once');
  assert.strictEqual(login[0].body.labToken, 'abc123', 'the code is lower-cased before it is sent, so a code read off the tile in capitals works');
  assert.ok(delOf(rowsOf()[0]), 'the controls appear once the session is unlocked');
  assert.strictEqual(byId.login.hidden, true, 'the prompt goes away once this browser is through');
  assert.strictEqual(byId['delete-note'].children.length, 0, 'and so does the note explaining its absence');

  // (13) Sorting. The page does not reorder the rows it holds -- it asks the
  // daemon for a differently ordered page -- so what each click has to produce
  // is the right query, and a header state that says which one is active.
  bootPage(UNLOCKED);
  await settle();
  const lastList = () => calls.filter((c) => c.path.startsWith('/api/stashes?')).pop().path;
  const ariaOf = (key) => byId['th-' + key].getAttribute('aria-sort');

  assert.match(lastList(), /sort=created&dir=desc/, 'the first load asks for the default order, newest first');
  assert.strictEqual(ariaOf('created'), 'descending', 'the default column is marked before anything is clicked');
  assert.strictEqual(ariaOf('size'), 'none', 'the columns not being sorted on are marked as such');

  // A first click on a quantity opens at the useful end: biggest first.
  fire(byId['sort-size'], 'click');
  await settle();
  assert.match(lastList(), /sort=size&dir=desc/, 'a first click on Size asks for the largest first');
  assert.strictEqual(ariaOf('size'), 'descending', 'Size is marked as the active column');
  assert.strictEqual(ariaOf('created'), 'none', 'the previously active column is released');

  // A second click on the same column reverses it.
  fire(byId['sort-size'], 'click');
  await settle();
  assert.match(lastList(), /sort=size&dir=asc/, 'clicking the active column again reverses it');
  assert.strictEqual(ariaOf('size'), 'ascending', 'and the header follows');

  // A first click on a name opens at the top of the alphabet instead -- the
  // direction is per column, and moving to a new one does not carry the old
  // one's direction across.
  fire(byId['sort-name'], 'click');
  await settle();
  assert.match(lastList(), /sort=name&dir=asc/, 'a first click on Name asks for A first, not the direction Size was left in');
  assert.strictEqual(ariaOf('name'), 'ascending');
  assert.strictEqual(ariaOf('size'), 'none');

  // Sorting starts from the top: an offset counts into an order, and the order
  // just changed.
  assert.match(lastList(), /offset=0/, 'a sort reloads from the first page');

  // The sort survives a filter change, so narrowing a list does not silently
  // reorder it back to the default.
  byId.class.value = 'text';
  fire(byId.class, 'change');
  await settle();
  assert.match(lastList(), /sort=name&dir=asc/, 'a filter change keeps the chosen order');
  assert.match(lastList(), /class=text/, 'and applies the filter');

  // (14) The page barrier. A delete makes the rows on screen untrue -- their
  // bytes are going -- so the page refuses input until it can be trusted again.
  // The state only exists between two awaits, so it is observed the way anything
  // transient is: by recording it at the moment each request goes out.
  bootPage(UNLOCKED);
  await settle();
  assert.strictEqual(blocked(), false, 'an idle page is not blocked');

  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  fire(byId['delete-selected'], 'click');
  await settle();
  await settle();

  const bulk = calls.find((c) => c.path === '/api/stashes/delete');
  assert.ok(bulk, 'the bulk delete was sent');
  assert.strictEqual(bulk.blocked, true, 'the page is blocked while the delete is in flight');
  // The half that matters most: the reload AFTER the delete runs behind the
  // barrier too. That is the window where the daemon has already unlinked the
  // bytes and the old rows are still on screen offering Download.
  const reload = calls.filter((c) => c.path.startsWith('/api/stashes?')).pop();
  assert.strictEqual(reload.blocked, true, 'the page stays blocked through the reload that follows');
  assert.strictEqual(blocked(), false, 'and is released once the fresh list is rendered');

  // (15) The failure path releases it too. A barrier that outlived a failed
  // request would leave the page permanently unusable -- worse than the
  // confusion it exists to prevent.
  bootPage(UNLOCKED);
  await settle();
  failDelete = true;
  byId['pick-all'].checked = true;
  fire(byId['pick-all'], 'change');
  fire(byId['delete-selected'], 'click');
  await settle();
  await settle();
  assert.strictEqual(blocked(), false, 'a refused delete still releases the page');
  assert.match(byId.msg.children[0].textContent, /could not be deleted/, 'and the refusal is reported');
  assert.ok(calls.filter((c) => c.path.startsWith('/api/stashes?')).length > 1,
    'a refused delete still reloads: it may have deleted part of the selection');

  // (16) A per-row delete raises the same barrier.
  bootPage(UNLOCKED);
  await settle();
  fire(delOf(rowsOf()[0]), 'click');
  await settle();
  const single = calls.filter((c) => c.method === 'DELETE').pop();
  assert.strictEqual(single.blocked, true, 'a per-row delete blocks the page while it runs');
  assert.strictEqual(blocked(), false, 'and releases it when the row is gone');

  console.log('PASS: index.js');
})().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
