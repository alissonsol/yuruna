// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Shared helpers for the stash UI. Vanilla JS, no framework. Untrusted stash
// content is ALWAYS placed via textContent / safe DOM APIs, never innerHTML (§7.4).

// Backs Y.hostInfo below: one in-flight/settled promise for the life of the
// page, so the header and the footer cost one request between them.
let hostInfoPromise = null;

// Guards the one-time submit wiring in Y.initUnlock below.
let unlockWired = false;

// How long a blocked page waits before it LOOKS blocked (Y.block). Matches the
// grace the other Yuruna service UIs give their wait indicator, so a fast
// operation reads as instant on every page rather than as a flicker on one.
const BLOCK_GRACE_MS = 250;

const Y = {
  // el builds an element with attributes + text/children, escaping by
  // construction (text goes through textContent).
  el(tag, attrs, ...kids) {
    const e = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v == null) continue;
        if (k === 'class') e.className = v;
        else if (k === 'text') e.textContent = v;
        else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2), v);
        else if (k === 'href' || k === 'src') { const safe = safeUrl(v); if (safe != null) e.setAttribute(k, safe); }
        else e.setAttribute(k, v);
      }
    }
    for (const kid of kids) {
      if (kid == null) continue;
      e.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
    }
    return e;
  },

  // replace swaps all of el's children for the given nodes via removeChild +
  // append (Safari/iOS 10+), NOT Element.replaceChildren (Safari/iOS 14+ only),
  // to hold the same older-iOS baseline the rest of this UI targets. Null kids
  // are skipped and strings become text nodes, matching el()'s child handling.
  replace(el, ...kids) {
    while (el.firstChild) el.removeChild(el.firstChild);
    for (const kid of kids) {
      if (kid == null) continue;
      el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
    }
    return el;
  },

  async api(path, opts) {
    // Bound the request so a stalled daemon cannot hang the page load (and its
    // footer) forever; the abort surfaces as a thrown error the caller's catch
    // already handles. opts.timeoutMs overrides the 10s default.
    const controller = (typeof AbortController !== 'undefined') ? new AbortController() : null;
    const timer = setTimeout(() => { if (controller) controller.abort(); }, (opts && opts.timeoutMs) || 10000);
    try {
      const res = await fetch(path, Object.assign({}, opts, { signal: controller ? controller.signal : undefined }));
      let body = null;
      try { body = await res.json(); } catch (_) { /* non-JSON */ }
      if (!res.ok || (body && body.ok === false)) {
        const msg = (body && body.error) || ('HTTP ' + res.status);
        const err = new Error(msg);
        err.status = res.status;
        err.body = body;
        throw err;
      }
      return body;
    } finally {
      clearTimeout(timer);
    }
  },

  humanSize(n) {
    if (n == null) return '';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0, v = Number(n);
    // A non-numeric / non-finite size falls back to the same empty placeholder
    // as null instead of rendering 'NaN B'.
    if (!Number.isFinite(v)) return '';
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? v : v.toFixed(1)) + ' ' + u[i];
  },

  fmtDate(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d)) return iso;
    return d.toLocaleString();
  },

  classIcon(cls) {
    switch (cls) {
      case 'text': return '\u{1F4C4}';      // page
      case 'image': return '\u{1F5BC}';     // framed picture
      case 'pdf': return '\u{1F4D5}';       // closed book
      case 'audio': return '\u{1F50A}';     // speaker
      case 'video': return '\u{1F3AC}';     // clapper
      case 'archive': return '\u{1F4E6}';   // package
      default: return '\u{1F4BE}';          // floppy
    }
  },

  // Propagate pathTail's null so a bad permalink yields no link: Y.el skips a
  // null href/src attribute, rather than building a broken URL from it.
  rawURL(view) { const tail = pathTail(view); return tail === null ? null : '/raw/' + view.hostId + tail; },
  downloadURL(view) { const tail = pathTail(view); return tail === null ? null : '/download/' + view.hostId + tail; },

  // The REST endpoint for one listed stash (GET / DELETE). Same null propagation:
  // a malformed permalink yields no URL at all rather than a DELETE aimed at a
  // guessed path -- the caller must not destroy a stash it could not address.
  stashApiURL(view) { const tail = pathTail(view); return tail === null ? null : '/api/stashes/' + view.hostId + tail; },

  // The same stash as the bulk-delete API's field form. Null for a malformed
  // permalink, for the same reason stashApiURL is: a stash that cannot be
  // addressed exactly must not be named in a request that destroys things.
  stashKey(view) {
    const tail = pathTail(view);
    if (tail === null) return null;
    const parts = tail.split('/').filter(Boolean); // [y, m, d, id]
    if (parts.length !== 4) return null;
    return { hostId: view.hostId, year: parts[0], month: parts[1], day: parts[2], id: parts[3] };
  },

  shortHost(h) { return h ? h.slice(0, 8) : '?'; },

  // hostInfo reads /api/hostinfo once and hands every later caller the same
  // answer: these are facts about the daemon, and they do not change under a
  // loaded page. Never rejects -- a failed read resolves to {} so a caller reads
  // a missing field rather than wrapping the call in a catch of its own.
  hostInfo() {
    if (!hostInfoPromise) {
      hostInfoPromise = Y.api('/api/hostinfo')
        .then((d) => d || {})
        // Only success is memoized. A failure that stuck would hold the delete
        // controls off for the life of the page over one unlucky moment at
        // load; releasing it lets the next read (a refresh, a re-render) pick
        // the answer up as soon as the daemon is back.
        .catch(() => { hostInfoPromise = null; return {}; });
    }
    return hostInfoPromise;
  },

  notice(parent, kind, text) {
    const n = Y.el('div', { class: 'notice ' + kind, text });
    parent.prepend(n);
    return n;
  },

  // Y.block raises a barrier over the whole page and returns the function that
  // takes it down.
  //
  //   const done = Y.block('Deleting…');
  //   try { ...work... } finally { done(); }
  //
  // It exists for destructive work, where the page on screen is about to stop
  // being true: a row whose bytes are already gone still offers Download, and
  // the operator has no way to know the difference. Refusing every input for
  // the duration is the only honest state -- the alternative is a page that
  // takes an action and then explains it could not have worked.
  //
  // done() MUST run on the failure path too. A request that never lands would
  // otherwise leave the page permanently unusable, which is a worse fault than
  // the confusion the barrier prevents.
  //
  // The barrier swallows input from the moment it is raised; only its
  // APPEARANCE waits out a grace period, so a delete that answers in 80 ms does
  // not flash a scrim over the table. The two halves are deliberately not
  // synchronized: looking live while refusing clicks merely feels unresponsive,
  // whereas looking blocked while still accepting them is the exact bug this is
  // here to fix.
  block(message) {
    if (typeof document === 'undefined' || !document.body) return function () { };
    const box = Y.el('div', { class: 'blocking-box' },
      Y.el('span', { class: 'spinner', 'aria-hidden': 'true' }),
      // aria-live, so a screen reader announces the wait it cannot see. The
      // text is the element's whole content, so polite is enough -- there is
      // nothing here to interrupt.
      Y.el('span', { class: 'blocking-text', role: 'status', 'aria-live': 'polite', text: message || 'Working…' }));
    const overlay = Y.el('div', { class: 'blocking', 'aria-busy': 'true' }, box);
    document.body.append(overlay);

    // A scrim stops the pointer, not the keyboard: a Tab from wherever focus
    // sat lands on a link underneath it, and the barrier would be a picture of
    // a blocked page rather than a blocked one. Focus is parked and Tab
    // swallowed for the duration, then given back to whatever held it.
    const previousFocus = document.activeElement;
    if (previousFocus && previousFocus.blur) previousFocus.blur();
    const trap = (e) => { if (e.key === 'Tab') e.preventDefault(); };
    document.addEventListener('keydown', trap, true);

    let timer = setTimeout(() => { timer = null; overlay.className = 'blocking shown'; }, BLOCK_GRACE_MS);
    return function () {
      if (timer) { clearTimeout(timer); timer = null; }
      document.removeEventListener('keydown', trap, true);
      if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
      // Only if it is still there to focus: the work that just finished may
      // well have removed the row this button belonged to.
      if (previousFocus && previousFocus.focus && previousFocus.parentNode) previousFocus.focus();
    };
  },

  // initFooter wires the shared bottom footer bar (server IPs, last-loaded
  // time, refresh countdown). Page-agnostic: host facts come from
  // /api/hostinfo, the countdown is visibility-aware (default 60 s, matched to
  // the status pages), and { markLoaded } lets a page stamp the "Loaded" time +
  // reset the countdown when ITS data refreshes. At zero it invokes
  // opts.refresh (default: a full reload). A no-op on a page without
  // #footer-bar markup. Mirrors the status pages' footer (yuruna.common.js).
  //
  // The countdown is opt-in through the markup: a page that carries no
  // #countdown starts no tick and is never reloaded from under the operator,
  // which is what a page holding an unsaved form needs.
  //
  // opts.paused is the finer-grained form of the same protection: a page that
  // normally auto-refreshes can park the countdown for as long as a refresh
  // would destroy transient state the operator built by hand (an in-progress
  // selection, a half-finished action). The displayed number freezes where it
  // stands and resumes ticking once the predicate goes false.
  initFooter(opts) {
    opts = opts || {};
    const interval = opts.intervalSeconds > 0 ? opts.intervalSeconds : 60;
    const refresh = typeof opts.refresh === 'function' ? opts.refresh : () => location.reload();
    const paused = typeof opts.paused === 'function' ? opts.paused : null;
    const $ = (id) => document.getElementById(id);
    let countdown = interval;

    // Render IPs into the readonly textarea, sized to 1–2 rows (one per
    // address family). These are the daemon's own IPs, but use .value (never
    // innerHTML) anyway per §7.4. Em dash (—) is the empty placeholder.
    const renderIps = (text) => {
      const el = $('footer-ip-list');
      if (!el) return;
      const v = (text || '').replace(/\s+$/, '');
      el.value = v || '—';
      el.rows = Math.min(2, Math.max(1, el.value.split('\n').length));
    };
    const stamp = () => {
      const el = $('last-loaded');
      if (el) el.textContent = new Date().toLocaleTimeString();
    };
    // Stamp here, not only from a page's data load: a page with no feed of its
    // own would otherwise show the em-dash forever. stamp, not markLoaded --
    // arriving host facts must not restart a countdown a caller is running.
    // A failed read leaves the time at its placeholder: an unreachable daemon
    // must not be stamped as a successful load.
    Y.hostInfo().then((d) => { renderIps(d.serverIps); if (d.ok) stamp(); });

    const markLoaded = () => {
      stamp();
      countdown = interval;
    };

    const link = $('footer-refresh');
    if (link) link.addEventListener('click', (e) => { e.preventDefault(); location.reload(); });

    // One-second tick. A hidden tab parks the countdown ('...') and never
    // refreshes (a backgrounded page must not poll, §4.1); returning to the
    // foreground forces a refresh on the next tick (countdown driven to 0).
    if ($('countdown')) {
      setInterval(() => {
        const el = $('countdown');
        if (document.hidden) { el.textContent = '...'; return; }
        if (paused && paused()) { el.title = 'Auto-refresh paused'; return; }
        el.title = '';
        countdown = Math.max(0, countdown - 1);
        el.textContent = countdown;
        if (countdown === 0) { countdown = interval; refresh(); }
      }, 1000);
      document.addEventListener('visibilitychange', () => { if (!document.hidden) countdown = 0; });
    }

    return { markLoaded };
  },

  // initHeader fills the shared header's two variable slots: the daemon version
  // under the service name, and this host's id. Page-agnostic -- both facts come
  // from /api/hostinfo, so a page gets them by carrying the markup. A failure
  // leaves the slots empty rather than blocking the page: they are decoration,
  // and every page here works without them.
  initHeader() {
    Y.hostInfo().then((d) => {
      const ver = document.getElementById('header-version');
      if (ver && d.version) ver.textContent = 'v' + d.version;
      const machine = document.getElementById('machine');
      if (machine && d.localHostId) machine.textContent = 'Host: ' + Y.shortHost(d.localHostId);
    });
  },

  // initMenu wires the header's page menu: the button toggles the panel, and a
  // click outside it or Escape closes it. The links are static markup, so every
  // page stays reachable even if this never runs.
  initMenu() {
    const button = document.getElementById('menu-button');
    const panel = document.getElementById('menu-panel');
    if (!button || !panel) return;

    const setOpen = (open) => {
      panel.hidden = !open;
      button.setAttribute('aria-expanded', open ? 'true' : 'false');
    };
    setOpen(false);

    button.addEventListener('click', () => {
      const open = button.getAttribute('aria-expanded') === 'true';
      setOpen(!open);
      if (!open) {
        const first = panel.querySelector('a');
        if (first) first.focus();
      }
    });
    // The button's own handler runs first (target phase), so by the time this
    // bubble-phase listener sees the same click the panel is already open --
    // hence the button check, which stops it closing again immediately.
    document.addEventListener('click', (e) => {
      if (panel.hidden || panel.contains(e.target) || button.contains(e.target)) return;
      setOpen(false);
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !panel.hidden) { setOpen(false); button.focus(); }
    });
  },
};

// Y.proofUnlock is the one attempt to spend a control proof carried in from the
// Yuruna hosts dashboard, started at load so the gate is already open by the
// time a page reads it. Arriving through the dashboard's Extension hosts link is
// then enough to delete -- the operator is not sent back to copy the rotating
// code off a tile.
//
// Resolves false on anything short of a granted session (no fragment, expired
// proof, aggregator unreachable), which leaves the lab-token prompt as the way
// in. It is a shortcut, never the only door.
Y.proofUnlock = (async function () {
  const proof = takeControlProof();
  if (!proof) return false;
  try {
    await Y.api('/api/unlock-proof', { method: 'POST', body: JSON.stringify({ proof }), headers: { 'Content-Type': 'application/json' } });
    return true;
  } catch (e) {
    return false;
  }
})();

// Y.session reports what this browser may do. The proof is awaited rather than
// raced: reading the gate first would render the lab-token prompt for a device
// that was about to be unlocked anyway, and the prompt would then be answered by
// an operator who never needed to see it. A failed read reports a locked,
// unconfigured gate -- a page must offer no control it cannot vouch for.
Y.session = async function () {
  await Y.proofUnlock;
  try {
    const s = await Y.api('/api/session');
    return { authed: !!s.authed, labToken: !!s.labToken, configured: !!s.configured };
  } catch (e) {
    return { authed: false, labToken: false, configured: false };
  }
};

// Y.initUnlock wires the shared lab-token prompt: it shows the form only when
// the gate is on and this device is not through it, names the case where no gate
// is configured at all, and re-runs the page's own render after a successful
// unlock so the controls appear without a reload. Returns the session it read,
// so a caller gets the answer and the wiring from one call.
Y.initUnlock = async function (onUnlocked) {
  const sess = await Y.session();
  const login = document.getElementById('login');
  const unconfigured = document.getElementById('gate-unconfigured');
  if (login) login.hidden = !(sess.labToken && !sess.authed);
  if (unconfigured) unconfigured.hidden = sess.configured;
  // The form is wired once for the page's life: initUnlock is called again after
  // every unlock and every reload, and a second listener on the same form would
  // submit the code twice.
  const form = document.getElementById('login-form');
  if (form && !unlockWired) {
    unlockWired = true;
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const field = document.getElementById('lab-token');
      const err = document.getElementById('login-error');
      if (err) err.textContent = '';
      try {
        // Normalised here as well as at the daemon, so a code read off the tile
        // in capitals is not a round trip that comes back "incorrect".
        await Y.api('/api/login', {
          method: 'POST',
          body: JSON.stringify({ labToken: field.value.trim().toLowerCase() }),
          headers: { 'Content-Type': 'application/json' },
        });
        field.value = '';
        if (typeof onUnlocked === 'function') await onUnlocked();
      } catch (e) {
        if (err) err.textContent = e.message;
      }
    });
  }
  return sess;
};

// takeControlProof reads the #yctl=<proof> fragment the aggregator's /go/stash
// redirect leaves behind and strips it from the address bar, so a proof is spent
// once and does not survive in history or in a copied URL. A fragment never
// reaches a server, which is why the handoff uses one.
function takeControlProof() {
  const m = /(?:^|[#&])yctl=([^&]+)/.exec((typeof location !== 'undefined' && location.hash) || '');
  if (!m) return '';
  try {
    if (typeof history !== 'undefined' && history.replaceState) {
      history.replaceState(null, document.title, location.pathname + location.search);
    }
  } catch (e) {
    // No history API: the proof still works, it just stays in the address bar.
  }
  return decodeURIComponent(m[1]);
}

// The header and its menu are on every page of this service, and not every page
// has a script that would wire them, so they are wired here instead of being
// left to each one. Scripts load at the end of <body>, so the DOM is normally
// parsed already; the guard covers a page that ever moves them into <head>.
function initPageChrome() { Y.initHeader(); Y.initMenu(); }
if (typeof document !== 'undefined' && typeof document.addEventListener === 'function') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initPageChrome);
  } else {
    initPageChrome();
  }
}

// safeUrl gates href/src attribute values: only same-origin relative paths and
// absolute http(s) URLs are allowed, so a javascript:/data:/vbscript: value
// (e.g. a spoofed remoteStashUrl) can never become an executable link.
// Returns null to drop the attribute.
function safeUrl(v) {
  const s = String(v).trim();
  if (s === '') return null;
  if (s.startsWith('/') && !s.startsWith('//')) return s; // same-origin relative
  try {
    const u = new URL(s, location.origin);
    return (u.protocol === 'http:' || u.protocol === 'https:') ? s : null;
  } catch (_) {
    return null;
  }
}

// pathTail derives /<yyyy>/<mm>/<dd>/<id> from a view's permalink, which is
// the authoritative /s/<host>/<yyyy>/<mm>/<dd>/<id> the server built.
function pathTail(view) {
  // A malformed view (missing or non-string permalink) returns null instead of
  // throwing, so one bad row cannot crash the render of every other row.
  if (!view || typeof view.permalink !== 'string') return null;
  const parts = view.permalink.split('/').filter(Boolean); // [s, host, y, m, d, id]
  return '/' + parts.slice(2).join('/');
}
