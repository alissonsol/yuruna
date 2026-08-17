// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Shared, XSS-safe helpers for the pool-control service UI. No innerHTML on data.
(function () {
  const Y = {};
  Y.el = function (tag, attrs, children) {
    const e = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === 'text') e.textContent = attrs[k];
      else if (k === 'class') e.className = attrs[k];
      else e.setAttribute(k, attrs[k]);
    }
    if (children) for (const c of [].concat(children)) {
      if (c === null || c === undefined) continue;
      e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return e;
  };
  Y.api = async function (path, opts) {
    opts = opts || {};
    const res = await fetch(path, {
      method: opts.method || 'GET',
      headers: opts.body ? { 'Content-Type': 'application/json' } : {},
      body: opts.body ? JSON.stringify(opts.body) : undefined
    });
    let data = {};
    try { data = await res.json(); } catch (e) { /* non-JSON */ }
    if (!res.ok || data.ok === false) {
      // Carry the status and the machine-readable reason onto the error: a
      // caller has to tell "you are not unlocked" (prompt for the lab token)
      // from "that failed" (say so), and a message string cannot be matched on
      // without breaking the moment the wording changes.
      const err = new Error(data.error || ('HTTP ' + res.status));
      err.status = res.status;
      err.reason = data.reason || '';
      throw err;
    }
    return data;
  };
  // needsUnlock reports whether an error means "not unlocked" rather than "that
  // operation failed". 401 is the gate refusing; auth-unconfigured is the gate
  // refusing because this service has no way to check a credential at all --
  // both leave the change unmade, and neither is worth an alert box that the
  // operator cannot act on.
  Y.needsUnlock = function (err) {
    return !!err && (err.status === 401 || err.reason === 'auth-unconfigured');
  };

  // Y.unlock prompts for the dashboard's Lab token and exchanges it for a
  // session. It builds its own markup so every page gets the prompt without
  // carrying a copy of it, and resolves true only when the unlock landed --
  // a caller retries its change on true and gives up on false.
  //
  // Reads are open, so this is never shown on arrival: it appears at the moment
  // a change is attempted, which is also the moment the operator has a reason to
  // go and read the rotating code off the dashboard.
  Y.unlock = function () {
    return new Promise((resolve) => {
      const existing = document.getElementById('yuruna-unlock');
      if (existing) existing.remove();

      const input = Y.el('input', {
        id: 'yuruna-unlock-code', type: 'text', maxlength: '6', spellcheck: 'false',
        autocapitalize: 'off', autocomplete: 'one-time-code',
        placeholder: 'Lab token', 'aria-label': 'Lab token'
      });
      const error = Y.el('p', { class: 'login-error' });
      error.hidden = true;
      const submit = Y.el('button', { type: 'submit', text: 'Unlock' });
      const cancel = Y.el('button', { type: 'button', class: 'secondary', text: 'Cancel' });
      const form = Y.el('form', null, [input, submit, cancel]);
      const panel = Y.el('section', { class: 'login' }, [
        Y.el('h1', { text: 'Enter the Lab token' }),
        Y.el('p', {
          class: 'login-hint',
          text: "The 6-character code on the Yuruna hosts dashboard's Lab token tile. It rotates every minute."
        }),
        form, error
      ]);
      const overlay = Y.el('div', { id: 'yuruna-unlock', class: 'unlock-overlay' }, panel);

      const close = (ok) => { overlay.remove(); resolve(ok); };
      cancel.addEventListener('click', () => close(false));
      form.addEventListener('submit', async (ev) => {
        ev.preventDefault();
        error.hidden = true;
        submit.disabled = true;
        try {
          await Y.api('/api/login', { method: 'POST', body: { labToken: input.value.trim().toLowerCase() } });
          close(true);
        } catch (e) {
          error.textContent = e.message;
          error.hidden = false;
          submit.disabled = false;
          input.select();
        }
      });
      document.body.appendChild(overlay);
      input.focus();
    });
  };

  // --- REGION: https://yuruna.link/control-proof
  // takeControlProof lifts the short-lived control proof the aggregator's
  // /go/stash redirect leaves in the URL fragment (#yctl=<expiry>.<proof>) and
  // strips it from the address bar, so it is not shoulder-surfed or pasted
  // onward with the URL. A fragment never reaches a server and never lands in an
  // access log, which is why the proof travels there and not in the query.
  //
  // Read once by construction: the second call finds no fragment. The value is
  // taken raw, not decodeURIComponent'd -- it is "<digits>.<standard base64>",
  // which has nothing to decode and a stray % would only make it throw.
  const takeControlProof = function () {
    try {
      const m = (window.location.hash || '').match(/(?:^#|[#&])yctl=([^&]+)/);
      if (!m || !m[1]) return '';
      if (window.history && window.history.replaceState) {
        window.history.replaceState(null, document.title, window.location.pathname + window.location.search);
      }
      return m[1];
    } catch (e) {
      // No history API: the proof still works, it just stays in the address bar.
      return '';
    }
  };

  // unlockFromProof exchanges that proof for this service's session, so arriving
  // through a link on the Yuruna hosts dashboard is enough to act — the operator
  // is not sent back to the dashboard to copy the rotating code off a tile.
  //
  // Resolves false on anything short of a granted session (no fragment, expired
  // proof, aggregator unreachable), which leaves the lab-token prompt as the way
  // in exactly as before. It is a shortcut, never the only door.
  const unlockFromProof = async function () {
    const proof = takeControlProof();
    if (!proof) return false;
    try {
      await Y.api('/api/unlock-proof', { method: 'POST', body: { proof: proof } });
      return true;
    } catch (e) {
      return false;
    }
  };

  // Started at load rather than on first use, so the session is in hand before
  // anything is clicked. Y.mutate awaits it, which is what stops a fast click
  // racing past the exchange into a lab-token prompt it did not need.
  const proofUnlock = unlockFromProof();

  // Y.ready resolves once that exchange has settled, for a page whose READ
  // depends on the session (a field served only to an unlocked request). Such a
  // page must not fetch before the proof has been spent, or its first paint
  // says "locked" to an operator who arrived holding the credential.
  Y.ready = function () { return proofUnlock; };

  // Y.mutate is Y.api for a request that CHANGES pool configuration: on a gate
  // refusal it prompts for the lab token and, if the unlock lands, sends the
  // same request again. Every mutating call site goes through it, so no page
  // has to decide for itself what a 401 means.
  Y.mutate = async function (path, opts) {
    await proofUnlock;
    try {
      return await Y.api(path, opts);
    } catch (e) {
      if (!Y.needsUnlock(e)) throw e;
      if (!(await Y.unlock())) throw e;
      return await Y.api(path, opts);
    }
  };

  // --- waiting -------------------------------------------------------------

  // How long a container that ALREADY holds rows keeps them before the wait
  // indicator replaces them. A read that answers in 50 ms would otherwise blink
  // the table out and back, which reads as a glitch rather than as progress;
  // a read that is actually slow is announced long before anyone concludes the
  // page is stuck.
  const BUSY_GRACE_MS = 250;

  // Y.busy paints "still working" into a container and returns the function
  // that takes it back down. Every slow read on every page goes through it, so
  // one wait looks like every other one.
  //
  //   const done = Y.busy(el, 'Loading pools…');
  //   try { ...render... } finally { done(); }
  //
  // done() must run on the FAILURE path too, or a read that never lands leaves
  // a spinner turning forever -- which claims progress that is not happening.
  //
  // A read that FAILED gets back what the indicator replaced: the rows are
  // stale, not wrong, and the page's notice already says the refresh did not
  // land. The originals go back, not copies of them, so the controls in those
  // rows keep the handlers they were built with. When the caller did repaint,
  // there is nothing to undo and done() leaves its work alone.
  //
  // An empty container shows the indicator at once -- there is nothing to lose,
  // and that first paint is the wait an operator is actually staring at.
  Y.busy = function (container, message) {
    if (!container) return function () { };
    const inner = Y.el('div', { class: 'loading', role: 'status' }, [
      Y.el('span', { class: 'spinner', 'aria-hidden': 'true' }),
      Y.el('span', { class: 'loading-text', text: message || 'Loading…' })
    ]);
    // A <tbody> may only hold rows, so there the indicator travels in one that
    // spans the table; every other container takes it directly.
    const node = container.tagName === 'TBODY' ? busyRow(container, inner) : inner;
    const previous = [];
    let timer = null;
    const paint = function () {
      timer = null;
      while (container.firstChild) previous.push(container.removeChild(container.firstChild));
      container.appendChild(node);
    };
    if (container.firstElementChild) timer = setTimeout(paint, BUSY_GRACE_MS);
    else paint();
    return function () {
      if (timer) { clearTimeout(timer); timer = null; }
      if (node.parentNode !== container) return;
      container.removeChild(node);
      for (const n of previous) container.appendChild(n);
      previous.length = 0;
    };
  };

  // The indicator row for a table, spanning every column so it sits under the
  // middle of the table rather than squeezed into the first one. The column
  // count comes from the header; a table without one gets a single wide cell,
  // which still renders.
  function busyRow(tbody, inner) {
    const table = tbody.closest ? tbody.closest('table') : null;
    const head = table ? table.querySelector('thead tr') : null;
    const cols = head ? head.children.length : 1;
    return Y.el('tr', { class: 'loading-row' }, [
      Y.el('td', { colspan: String(cols) }, [inner])
    ]);
  }

  Y.notice = function (kind, msg) {
    const n = document.getElementById('notice');
    if (!n) return;
    n.className = 'notice ' + kind;
    n.textContent = msg;
    n.style.display = 'block';
  };
  Y.clearNotice = function () {
    const n = document.getElementById('notice');
    if (n) { n.style.display = 'none'; n.textContent = ''; }
  };
  Y.shortHost = function (h) { return h ? String(h).slice(0, 8) : '?'; };

  // Y.guid is how a FULL opaque id is spelled wherever one is shown: 8-4-4-4-12,
  // the same form the Yuruna hosts dashboard reveals and every pool-admin command
  // accepts as pasted. 32 undifferentiated hex characters are not checkable
  // against another screen by eye, and a lab holds a dozen that share the '42'
  // prefix. The stores are keyed on the undashed form, so this is a rendering:
  // nothing that goes back to a server may be built from it.
  //
  // A value that is not 32 hex is passed through -- a pool GUID already carries
  // its dashes, and an id the daemon reported in some other shape is not this
  // function's to reinterpret.
  Y.guid = function (id) {
    const h = String(id || '');
    if (!/^[0-9a-fA-F]{32}$/.test(h)) return h;
    return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join('-');
  };

  // hostInfo memoizes the one /api/hostinfo read every page needs. The chrome
  // takes the version and host id from it; the tables take the aggregator URL
  // they build /go/host links from. Memoized because those facts do not change
  // for the life of the page, and deliberately non-rejecting: a caller gets {}
  // and renders what it can rather than losing its whole table to a failed
  // furniture fetch.
  let hostInfoPromise = null;
  Y.hostInfo = function () {
    if (!hostInfoPromise) {
      hostInfoPromise = Y.api('/api/hostinfo')
        .then(function (d) { return d || {}; })
        .catch(function () { return {}; });
    }
    return hostInfoPromise;
  };

  // Y.hostLink renders a host id as its first 8 characters, linked to that
  // host's own status page through the aggregator's /go/host redirect -- the
  // same hop the Yuruna hosts dashboard's Control column takes, which resolves
  // the host's CURRENT IP server-side (so the link survives a DHCP change) and
  // hands the browser a short-lived control proof.
  //
  // With no aggregator to redirect through, the id renders as unlinked text: a
  // link that cannot resolve reads as a broken page, while a bare id still
  // identifies the host. The full id is always on the title, because 8
  // characters identify but do not copy -- and it is spelled the way Y.guid
  // spells one, while the href carries the undashed key the pool is on.
  //
  // goBaseUrl comes from /api/hostinfo already reduced to the plain-http form a
  // browser must follow -- see goBaseURL in hostinfo.go for why an https hop
  // here would put a proxy-CA interstitial in front of every host link.
  Y.hostLink = function (hostId, poolId, goBaseUrl) {
    const full = String(hostId || '');
    if (!full) return Y.el('span', { class: 'muted', text: '—' });
    const base = httpBase(goBaseUrl);
    if (!base) return Y.el('span', { class: 'mono', text: Y.shortHost(full), title: Y.guid(full) });
    const url = base + '/go/host?host=' + encodeURIComponent(full) + '&pool=' + encodeURIComponent(poolId || '');
    return Y.el('a', { class: 'mono', href: url, target: '_blank', rel: 'noopener', title: Y.guid(full) }, Y.shortHost(full));
  };

  // httpBase gates what may become an href: an absolute http origin, trailing
  // slashes trimmed, or '' to render the id unlinked. The daemon already forces
  // the scheme, so this is the second of two checks rather than the only one --
  // it is here because the value reaches an href, and neither a javascript:/data:
  // URL from a mistyped flag nor an https one that would raise a certificate
  // warning should get there on the strength of a single guard.
  function httpBase(v) {
    const s = String(v || '').trim().replace(/\/+$/, '');
    if (!s) return '';
    try {
      return new URL(s).protocol === 'http:' ? s : '';
    } catch (e) {
      return '';
    }
  }

  // Y.idCell renders an opaque id (a pool GUID, a host id) as its first 8
  // characters -- the same prefix the header's "Host:" shows, and enough to tell
  // two apart at a glance -- expanding on click to the full id as Y.guid spells
  // it, because quoting one into a command needs all of it and a hyphenated id
  // is the form those commands take.
  //
  // A <button>, not a click handler on a <span>: it is an interactive control,
  // so keyboard activation and the screen-reader announcement have to come with
  // it rather than be reimplemented.
  Y.idCell = function (id) {
    const full = Y.guid(id);
    if (!full) return Y.el('span', { class: 'muted', text: '—' });
    const short = Y.shortHost(full);
    const btn = Y.el('button', { type: 'button', class: 'id-toggle mono', text: short, title: 'Show the full id' });
    btn.addEventListener('click', function () {
      const expanded = btn.textContent === full;
      btn.textContent = expanded ? short : full;
      btn.title = expanded ? 'Show the full id' : 'Show only the first 8 characters';
    });
    return btn;
  };

  // Y.numCell is the counter column every table opens with. It numbers the row
  // where it SITS, not the thing in it: the column reads 1..N down the page
  // whatever the table is sorted by, so "how many hosts are there" and "the
  // fourth one down" are answerable without counting.
  Y.numCell = function (n) {
    return Y.el('td', { class: 'rownum', text: n > 0 ? String(n) : '' });
  };

  // Y.sortTable orders a table by its column headers, over rows the page has
  // already built. A header opts in by carrying data-sort="<key>" around a
  // <button class="sort">; the page hands over { tr, values } per row, and
  // values[key] is what that column sorts on. A header without data-sort is a
  // column no order would mean anything for -- the counter, a cell that is only
  // an action button -- and stays inert.
  //
  // It reorders the EXISTING row nodes rather than asking the page to build
  // them again. A row on these pages can hold a hostId someone is halfway
  // through typing or a test set picked but not yet assigned, and rebuilding
  // would take that away as the price of reading the table another way.
  //
  // Returns { set, refresh }: set(rows) replaces what the table holds,
  // refresh() re-sorts the same rows after their values changed underneath
  // (a column fed by a slower endpoint than the one the rows came from).
  Y.sortTable = function (tbody, opts) {
    opts = opts || {};
    const table = tbody && tbody.closest ? tbody.closest('table') : null;
    let key = opts.key || '';
    let asc = opts.asc !== false;
    let rows = [];

    function headers() {
      return table ? table.querySelectorAll('th[data-sort]') : [];
    }

    // Strings compare lowercased -- a display name's capitalisation is not an
    // order anyone means to ask for -- and a missing value becomes '', which
    // the comparison ranks last. Numbers pass through: 0 members is a value.
    function cmpValue(v) {
      if (typeof v === 'string') return v.toLowerCase();
      return (v === null || v === undefined) ? '' : v;
    }

    function compare(a, b) {
      const av = cmpValue(a.values ? a.values[key] : '');
      const bv = cmpValue(b.values ? b.values[key] : '');
      let cmp = 0;
      if (av !== bv) {
        // A row with no value ranks last ascending: sorting on a column is a
        // way of reading the rows that HAVE one, and every one of these tables
        // has blanks -- a pool with no test set, a host that never answered.
        if (av === '') cmp = 1;
        else if (bv === '') cmp = -1;
        else cmp = av < bv ? -1 : 1;
      }
      return asc ? cmp : -cmp;
    }

    // Sorted from the order the page built the rows in, not from the order they
    // are in now, so ties land the same way every time: the sort is stable, and
    // that build order is the server's.
    //
    // Rows already standing in the right order are left where they are.
    // Re-appending a node moves it, and moving one that holds the focus takes
    // the caret out of whatever is being typed into it -- which is what a
    // repaint for a column fed by a slow endpoint would otherwise do, seconds
    // after the operator started typing.
    function paint() {
      const ordered = key ? rows.slice().sort(compare) : rows.slice();
      let placed = tbody.children.length === ordered.length;
      for (let i = 0; placed && i < ordered.length; i++) {
        placed = tbody.children[i] === ordered[i].tr;
      }
      if (!placed) tbody.textContent = '';
      let n = 0;
      for (const r of ordered) {
        n++;
        let cell = r.tr.firstElementChild;
        if (!cell || !cell.classList.contains('rownum')) {
          cell = Y.numCell(n);
          r.tr.insertBefore(cell, r.tr.firstChild);
        }
        cell.textContent = String(n);
        if (!placed) tbody.appendChild(r.tr);
      }
    }

    // aria-sort on the header cell is what a screen reader announces and what
    // draws the arrow, so the two cannot disagree.
    function mark() {
      for (const th of headers()) {
        if (th.getAttribute('data-sort') === key) th.setAttribute('aria-sort', asc ? 'ascending' : 'descending');
        else th.removeAttribute('aria-sort');
      }
    }

    for (const th of headers()) {
      const btn = th.querySelector('button.sort');
      if (!btn) continue;
      btn.addEventListener('click', function () {
        const k = th.getAttribute('data-sort');
        if (k === key) asc = !asc;
        else { key = k; asc = true; }
        mark();
        paint();
      });
    }
    mark();

    return {
      set: function (list) { rows = (list || []).slice(); paint(); },
      refresh: paint
    };
  };

  // initChrome wires the shared page chrome: the header's version + host id and
  // the bottom footer bar (server IPs, last-loaded time, refresh countdown).
  // Page-agnostic — every fact comes from /api/hostinfo, so a page adds the
  // chrome by carrying the markup and calling this once.
  //
  // Returns { markLoaded, stamp, busy }. markLoaded stamps the "Loaded" time AND
  // restarts the countdown, which suits a page whose data only moves when it
  // fetches. stamp only writes the time: a page polling faster than the
  // countdown would otherwise keep resetting it, pinning the number forever.
  // busy(true/false) is the quiet half of Y.busy -- see below.
  //
  // Mirrors the stash service's footer and the status pages' (yuruna.common.js).
  Y.initChrome = function (opts) {
    opts = opts || {};
    const interval = opts.intervalSeconds > 0 ? opts.intervalSeconds : 60;
    const refresh = typeof opts.refresh === 'function' ? opts.refresh : function () { location.reload(); };
    // Pages that already reload their own data on visibilitychange pass false,
    // so returning to the tab does not fire two fetches a second apart.
    const refreshOnVisible = opts.refreshOnVisible !== false;
    const $ = function (id) { return document.getElementById(id); };
    let countdown = interval;

    // Render IPs into the readonly textarea, sized to 1–2 rows (one per address
    // family). These are the daemon's own IPs, but use .value (never innerHTML)
    // anyway. Em dash (—) is the empty placeholder.
    const renderIps = function (text) {
      const el = $('footer-ip-list');
      if (!el) return;
      const v = (text || '').replace(/\s+$/, '');
      el.value = v || '—';
      el.rows = Math.min(2, Math.max(1, el.value.split('\n').length));
    };

    const stamp = function () {
      const el = $('last-loaded');
      if (el) el.textContent = new Date().toLocaleTimeString();
    };
    const markLoaded = function () { stamp(); countdown = interval; };

    // The footer's activity dot: what a refresh the operator did NOT ask for
    // signals with. A background poll keeps the numbers it is refreshing on
    // screen, so it has no room for Y.busy's indicator -- and a wall display
    // that blanked every half minute would read as failing, not as refreshing.
    //
    // Depth-counted: a page whose load runs two reads at once (the host list
    // and the hardware fan-out) must not have the first one to finish declare
    // the page idle.
    let busyDepth = 0;
    const busy = function (on) {
      busyDepth = Math.max(0, busyDepth + (on ? 1 : -1));
      const el = $('footer-busy');
      if (el) el.hidden = busyDepth === 0;
    };

    Y.hostInfo().then(function (d) {
      const ver = $('header-version');
      if (ver && d.version) ver.textContent = 'v' + d.version;
      const machine = $('machine');
      if (machine && d.localHostId) machine.textContent = 'Host: ' + Y.shortHost(d.localHostId);
      // A failed read resolves to {}, so this renders the em-dash placeholder
      // rather than needing a rejection path of its own.
      renderIps(d.serverIps);
      // Stamp here, not only from a page's data load: a page with no feed of its
      // own would otherwise show the em-dash forever. A page that does fetch
      // overwrites this a moment later with its own load time. stamp, not
      // markLoaded — arriving host facts must not restart the countdown a
      // caller may already be running.
      stamp();
    });

    const link = $('footer-refresh');
    if (link) link.addEventListener('click', function (e) { e.preventDefault(); location.reload(); });

    // One-second tick. A hidden tab parks the countdown ('...') and never
    // refreshes, so a backgrounded page does not poll; returning to the
    // foreground forces a refresh on the next tick (countdown driven to 0).
    if ($('countdown')) {
      setInterval(function () {
        const el = $('countdown');
        if (document.hidden) { el.textContent = '...'; return; }
        countdown = Math.max(0, countdown - 1);
        el.textContent = countdown;
        if (countdown === 0) { countdown = interval; refresh(); }
      }, 1000);
      if (refreshOnVisible) {
        document.addEventListener('visibilitychange', function () { if (!document.hidden) countdown = 0; });
      }
    }

    return { markLoaded: markLoaded, stamp: stamp, busy: busy };
  };

  // initMenu wires the header's page menu: the button toggles the panel, and a
  // click outside it or Escape closes it. The links are static markup, so every
  // page stays reachable even if this never runs.
  //
  // Wired here rather than from each page's script because not every page in
  // every Yuruna service calls initChrome, and the menu is how you leave a page.
  Y.initMenu = function () {
    const button = document.getElementById('menu-button');
    const panel = document.getElementById('menu-panel');
    if (!button || !panel) return;

    const setOpen = function (open) {
      panel.hidden = !open;
      button.setAttribute('aria-expanded', open ? 'true' : 'false');
    };
    setOpen(false);

    button.addEventListener('click', function () {
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
    document.addEventListener('click', function (e) {
      if (panel.hidden || panel.contains(e.target) || button.contains(e.target)) return;
      setOpen(false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !panel.hidden) { setOpen(false); button.focus(); }
    });
  };

  // Scripts load at the end of <body>, so the DOM is normally parsed already;
  // the guard covers a page that ever moves them into <head>.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', Y.initMenu);
  } else {
    Y.initMenu();
  }

  window.Y = Y;
})();
