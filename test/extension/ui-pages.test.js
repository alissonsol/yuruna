// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
/*
  Every page of every extension service UI, loaded the way a browser loads it:
  the SDK's shared runtime, then the service's common.js, then the page's own
  script -- against a DOM stub built from that page's OWN ids. Run:
  node ui-pages.test.js (exit 0 = pass).

  This exists because the two failures it checks are invisible from the server
  side. A daemon serves the same bytes whether or not the browser can run them,
  so every Go test passes while the page renders as a shell: the header bar
  paints from static markup, the menu never opens because the script that wires
  it never ran, and every table stays empty because the rows are built in
  script. Nothing short of executing the scripts against real page ids
  distinguishes that from a working page.

  What this does NOT check is the browser baseline. node runs modern syntax
  happily, so these pages would pass here whether or not Safari 9 could parse
  them -- that half is tools/Invoke-Es5Check.ps1, which reads the files without
  running them. The two are complements: the checker proves the scripts PARSE
  on the floor, this proves they WORK. Neither alone says the page renders.

  So each page is asserted to:
    - load all three scripts without throwing, and without leaving a rejected
      promise behind;
    - open its menu when the menu button is clicked (the panel ships hidden and
      is revealed only by script);
    - fill its main region -- the rows of its table, the cards of the board --
      from the data its endpoints returned.

  The fetch stub answers every route these pages read with one plausible record,
  so "the table filled" means the render path ran end to end rather than that it
  short-circuited on an empty list.
*/
'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');

const EXT = __dirname;
const CORE = path.join(EXT, 'extension-sdk', 'webui', 'assets', 'yuruna.core.js');

function webDir(service) {
  return path.join(EXT, service, 'server', 'internal', 'httpsrv', 'web');
}

// --- REGION: Pages and required content
const PAGES = [
  { service: 'pool-control-service', file: 'board.html', fills: 'cards', reveals: 'board' },
  { service: 'pool-control-service', file: 'index.html', fills: 'pool-rows' },
  { service: 'pool-control-service', file: 'hosts.html', fills: 'host-rows' },
  { service: 'pool-control-service', file: 'pools.html', fills: 'pool-rows' },
  { service: 'pool-control-service', file: 'test-sets.html', fills: 'ts-rows' },
  { service: 'pool-control-service', file: 'scan.html', fills: 'host-rows' },
  { service: 'pool-control-service', file: 'diagnostics.html', fills: 'check-rows' },
  { service: 'stash-service', file: 'index.html', fills: 'rows' },
  { service: 'stash-service', file: 'stash.html', fills: 'detail' },
  { service: 'stash-service', file: 'new.html' },
  { service: 'download-agent-service', file: 'index.html', fills: 'image-rows' },
  { service: 'download-agent-service', file: 'diagnostics.html', fills: 'error-rows' },
];

// --- REGION: Fetch fixtures
const HOST = '426d17ef0b88426b922180dad1a9e921';

// One record per collection, so a filled region proves the row-building path
// ran rather than that an empty list was rendered as an empty list.
const ROUTES = [
  ['/api/hostinfo', { ok: true, version: '1.2.3', localHostId: HOST, serverIps: '10.0.0.2', goBaseUrl: 'http://agg.test' }],
  ['/api/session', { ok: true, authed: true, labToken: true, configured: true }],
  ['/api/unlock-proof', { ok: true }],
  ['/api/login', { ok: true }],
  ['/api/state', {
    ok: true,
    pools: [{ poolId: 'default', poolGuid: HOST, displayName: 'Default', members: [HOST], desiredState: 'run', testSet: { name: 'smoke', frameworkUrl: 'https://f.test', projectUrl: 'https://p.test' } }],
    testSets: [{ name: 'smoke', frameworkUrl: 'https://f.test', projectUrl: 'https://p.test' }]
  }],
  ['/api/board', {
    ok: true,
    cards: [{ poolId: 'default', displayName: 'Default', hostsTotal: 2, hostsReporting: 2, successPct: 100, total: 9, failed: 0, testSet: 'smoke', assignAllowed: true, blocked: [] }],
    offers: [{ name: 'smoke', displayName: 'Smoke', frameworkUrl: 'https://f.test', projectUrl: 'https://p.test' }]
  }],
  ['/api/pool/host-control', { ok: true, pools: { default: { state: 'ready', hosts: [{ hostId: HOST, ok: true, state: 'ready' }] } } }],
  ['/api/hosts/facts', { ok: true, hosts: {} }],
  ['/api/hosts', {
    ok: true, pools: ['default'], targetPoolId: 'default', hostnamesVisible: true,
    hosts: [{ hostId: HOST, hostname: 'box', type: 'kvm', pool: 'default', control: 'ready', access: 'ok' }]
  }],
  ['/api/scan', {
    ok: true, defaultCidr: '192.168.7.0/24', maxAddresses: 1024, port: 8080, sweepSeconds: 300,
    scan: { running: false, cidr: '192.168.7.0/24', done: 254, total: 254, found: [], alreadyMonitored: 1, startedUtc: '2026-08-22T00:00:00Z', finishedUtc: '2026-08-22T00:01:00Z' },
    hosts: [{ address: '192.168.7.5', hostId: HOST, hostname: 'box', hostType: 'kvm', baseUrl: 'http://192.168.7.5:8080', firstSeenUtc: '2026-08-22T00:00:00Z', lastSeenUtc: '2026-08-22T00:01:00Z' }]
  }],
  ['/api/diagnostics', {
    ok: true, version: '1.2.3', go: 'go1.25', collectedAt: '2026-08-22T00:00:00Z',
    checks: [{ name: 'intent', ok: true, detail: 'fine', hint: '' }],
    intentProbe: { argv: ['pwsh'], exitCode: 0, duration: '1s', stdout: '', stderr: '' },
    environment: {}, runtime: { os: 'linux', arch: 'amd64', pid: 1 }
  }],
  ['/api/v1/status', { ok: true, autoSeed: true, bestEffort: [{ imageKey: 'guest.windows.11', available: true }], totals: { bytes: 1024, images: 1, currentBytes: 1024 } }],
  ['/api/v1/images', {
    ok: true, asOfUtc: '2026-08-22T00:00:00Z', poolAvailable: true,
    totals: { images: 1, bytes: 1024, currentBytes: 1024, previousBytes: 0, byHostType: { kvm: 1024 } },
    images: [{ imageKey: 'guest.ubuntu.server.26', hostType: 'kvm', arch: 'amd64', variant: 'server', state: 'fresh', supported: true, generation: 'g1', upstreamFilename: 'x.img', currentBytes: 1024, previousBytes: 0, checksumVerdict: 'match', sourceUrl: 'https://s.test/x.img', lastVerifiedAt: '2026-08-22T00:00:00Z', secondsToExpiry: 3600 }]
  }],
  ['/api/v1/diagnostics', {
    ok: true,
    diagnostics: {
      asOfUtc: '2026-08-22T00:00:00Z', os: 'linux', goos: 'linux', goarch: 'amd64', poolAvailable: true,
      bestEffort: [{ imageKey: 'guest.windows.11', available: true }],
      interpreter: { version: '7.4', resolvedPath: '/usr/bin/pwsh' },
      script: { sha256: 'abc123def456', path: '/opt/fido.ps1', sizeBytes: 10 },
      recentErrors: [{ key: 'k', error: 'e', atUtc: '2026-08-22T00:00:00Z' }],
      lastFidoAttempt: null
    }
  }],
  ['/api/stashes', {
    ok: true, total: 1,
    stashes: [{ id: 'aaa', local: true, hostId: HOST, permalink: '/s/' + HOST + '/2026/08/22/aaa', originalFilename: 'a.txt', username: 'u', sizeBytes: 10, createdAt: '2026-08-22T00:00:00Z', status: 'complete', contentClass: 'text' }]
  }],
];

// The stash detail page reads /api/stashes/<host>/<y>/<m>/<d>/<id>, which is a
// prefix of the list route above, so it is matched after the exact ones.
const STASH_DETAIL = {
  ok: true, inlineTextCap: 1024,
  stash: {
    id: 'aaa', local: true, hostId: HOST, permalink: '/s/' + HOST + '/2026/08/22/aaa',
    originalFilename: 'a.txt', username: 'u', sizeBytes: 10, createdAt: '2026-08-22T00:00:00Z',
    status: 'complete', contentClass: 'other', mimeType: 'application/octet-stream', source: 'web'
  }
};

function bodyFor(url) {
  const p = String(url).split('?')[0];
  for (const [route, body] of ROUTES) {
    if (p === route) { return body; }
  }
  if (p.indexOf('/api/stashes/') === 0) { return STASH_DETAIL; }
  return { ok: true };
}

// --- REGION: DOM stub
function makeText(s) { return { nodeType: 3, textContent: String(s), parentNode: null, children: [] }; }

function makeEl(tag) {
  const el = {
    nodeType: 1,
    tagName: String(tag || 'div').toUpperCase(),
    className: '', textContent: '', title: '', value: '', href: '', protocol: 'https:',
    checked: false, disabled: false, indeterminate: false, hidden: false, selected: false,
    rows: 1, tabIndex: -1, style: {}, attrs: {}, children: [], parentNode: null, listeners: {},
    files: { length: 0 },
    get firstChild() { return this.children[0] || null; },
    get firstElementChild() { return this.children.filter((c) => c.nodeType === 1)[0] || null; },
    get lastElementChild() { const e = this.children.filter((c) => c.nodeType === 1); return e[e.length - 1] || null; },
    setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'disabled') { this.disabled = true; } },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); },
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    removeEventListener() {},
    focus() {}, select() {}, scrollIntoView() {},
    appendChild(kid) {
      const node = (kid && kid.nodeType) ? kid : makeText(kid);
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
      if (i >= 0) { this.children.splice(i, 1); }
      kid.parentNode = null;
      return kid;
    },
    contains(node) {
      if (!node) { return false; }
      if (node === this) { return true; }
      return this.children.some((c) => c.nodeType === 1 && c.contains(node));
    },
    closest() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
  };
  return el;
}

// Every id the page's own markup declares. Anything else resolves to null,
// which is how a page's optional furniture stays inert under the stub -- and
// how a script that reaches for an element the page does not have is caught.
function idsIn(html) {
  const out = [];
  const re = /\bid="([^"]+)"/g;
  let m;
  while ((m = re.exec(html)) !== null) { out.push(m[1]); }
  return out;
}

function scriptsIn(html) {
  const out = [];
  const re = /<script src="\/assets\/([^"]+)"><\/script>/g;
  let m;
  while ((m = re.exec(html)) !== null) { out.push(m[1]); }
  return out;
}

// --- REGION: Page checks
function runPage(page) {
  const dir = webDir(page.service);
  const html = fs.readFileSync(path.join(dir, page.file), 'utf8');
  const scripts = scriptsIn(html);
  assert.ok(scripts.length >= 2, `${page.service}/${page.file}: expected the runtime and at least one page script`);
  assert.strictEqual(scripts[0], 'yuruna.core.js',
    `${page.service}/${page.file}: the shared runtime must load first; it defines Y and installs the baseline shims`);

  const byId = {};
  for (const id of idsIn(html)) { byId[id] = makeEl('div'); }
  const body = makeEl('body');
  const failures = [];
  // Document-level listeners are captured rather than dropped: these scripts sit
  // at the end of <body>, so the document is still parsing when they run and
  // several of them do their first read from DOMContentLoaded. A stub that
  // swallowed that listener would report an empty table as the page's fault.
  const docListeners = {};
  const box = {
    console: { log() {}, warn() {}, error() {} },
    JSON, Math, Date, Number, String, Object, Array, RegExp, Promise, isNaN, parseInt, parseFloat,
    encodeURIComponent, decodeURIComponent,
    setTimeout: (fn) => setTimeout(fn, 0),
    clearTimeout: (t) => clearTimeout(t),
    setInterval: () => 0,
    clearInterval() {},
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    location: { origin: 'https://svc.test', href: '', hash: '', pathname: '/s/' + HOST + '/2026/08/22/aaa', search: '', reload() {} },
    history: { replaceState() {} },
    confirm: () => true,
    alert() {},
    FormData: function () {},
    XMLHttpRequest: function () {},
    fetch(url) {
      const payload = bodyFor(url);
      return Promise.resolve({
        ok: true, status: 200, statusText: 'OK',
        json: () => Promise.resolve(payload),
        text: () => Promise.resolve(''),
      });
    },
    document: {
      // 'loading', because that is what it is while a script at the end of
      // <body> runs -- and it is the branch the runtime takes to defer its
      // chrome wiring.
      readyState: 'loading', hidden: false, title: 't', body,
      activeElement: null,
      createElement: makeEl,
      createTextNode: makeText,
      getElementById: (id) => byId[id] || null,
      querySelector: () => null,
      querySelectorAll: () => [],
      addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
      removeEventListener(type, fn) {
        const list = docListeners[type] || [];
        const i = list.indexOf(fn);
        if (i >= 0) { list.splice(i, 1); }
      },
    },
  };
  box.window = box;
  box.globalThis = box;
  vm.createContext(box);

  for (const name of scripts) {
    const file = name === 'yuruna.core.js' ? CORE : path.join(dir, 'assets', name);
    try {
      vm.runInContext(fs.readFileSync(file, 'utf8'), box, { filename: name });
    } catch (e) {
      failures.push(`${page.service}/${page.file}: ${name} threw at load -- ${e && e.message}`);
    }
  }
  // The parser finishing, which is what releases every deferred first read.
  box.document.readyState = 'complete';
  for (const fn of (docListeners.DOMContentLoaded || []).slice()) {
    try { fn({ type: 'DOMContentLoaded' }); } catch (e) {
      failures.push(`${page.service}/${page.file}: DOMContentLoaded threw -- ${e && e.message}`);
    }
  }

  return { box, byId, body, failures };
}

function fire(el, type) {
  const ev = {
    type, currentTarget: el, target: el, key: '', keyCode: 0,
    preventDefault() {}, stopPropagation() {},
  };
  for (const fn of (el.listeners[type] || [])) { fn(ev); }
}

const settle = () => new Promise((r) => setTimeout(r, 0));

// --- REGION: Test run
(async function () {
  const problems = [];
  let menusOpened = 0;
  let regionsFilled = 0;

  for (const page of PAGES) {
    const where = `${page.service}/${page.file}`;
    const { box, byId, failures } = runPage(page);
    problems.push(...failures);
    if (failures.length) { continue; }

    assert.ok(box.Y && typeof box.Y.el === 'function', `${where}: the runtime did not attach Y`);

    // (1) The menu. It ships hidden in the markup and is revealed only by
    // script, so a page whose scripts did not run shows a header bar with a
    // button that does nothing -- which is exactly how the failure presents.
    const button = byId['menu-button'];
    const panel = byId['menu-panel'];
    if (!button || !panel) {
      problems.push(`${where}: has no menu button/panel`);
    } else if (panel.hidden !== true) {
      problems.push(`${where}: the menu panel is not hidden before the button is pressed`);
    } else {
      fire(button, 'click');
      if (panel.hidden !== false) { problems.push(`${where}: pressing the menu button did not open the panel`); }
      else if (button.getAttribute('aria-expanded') !== 'true') { problems.push(`${where}: the menu opened without announcing it`); }
      else { menusOpened++; }
    }

    // Let every load-time read and its render settle.
    for (let i = 0; i < 25; i++) { await settle(); }

    // (2) The main region. Rows are built in script from what the endpoints
    // returned, so an empty one is the second half of the same failure.
    if (page.fills) {
      const host = byId[page.fills];
      if (!host) { problems.push(`${where}: has no #${page.fills}`); }
      else if (host.children.length === 0) { problems.push(`${where}: #${page.fills} is still empty after its data arrived`); }
      else { regionsFilled++; }
    }
    if (page.reveals) {
      const main = byId[page.reveals];
      if (!main) { problems.push(`${where}: has no #${page.reveals}`); }
      else if (main.hidden !== false) { problems.push(`${where}: #${page.reveals} is still hidden, so the page renders as a shell`); }
    }
  }

  assert.deepStrictEqual(problems, [], 'every page must run, open its menu and fill its region');
  // Guards against a harness that quietly stops exercising anything.
  assert.ok(menusOpened >= 10, `only ${menusOpened} menus were opened; the harness is not reaching the pages`);
  assert.ok(regionsFilled >= 9, `only ${regionsFilled} regions were filled; the harness is not reaching the pages`);

  console.log(`PASS: ${PAGES.length} pages, ${menusOpened} menus opened, ${regionsFilled} regions filled`);
})().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
