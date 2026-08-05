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

  // Y.mutate is Y.api for a request that CHANGES pool configuration: on a gate
  // refusal it prompts for the lab token and, if the unlock lands, sends the
  // same request again. Every mutating call site goes through it, so no page
  // has to decide for itself what a 401 means.
  Y.mutate = async function (path, opts) {
    try {
      return await Y.api(path, opts);
    } catch (e) {
      if (!Y.needsUnlock(e)) throw e;
      if (!(await Y.unlock())) throw e;
      return await Y.api(path, opts);
    }
  };

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

  // initChrome wires the shared page chrome: the header's version + host id and
  // the bottom footer bar (server IPs, last-loaded time, refresh countdown).
  // Page-agnostic — every fact comes from /api/hostinfo, so a page adds the
  // chrome by carrying the markup and calling this once.
  //
  // Returns { markLoaded, stamp }. markLoaded stamps the "Loaded" time AND
  // restarts the countdown, which suits a page whose data only moves when it
  // fetches. stamp only writes the time: a page polling faster than the
  // countdown would otherwise keep resetting it, pinning the number forever.
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

    Y.api('/api/hostinfo').then(function (d) {
      d = d || {};
      const ver = $('header-version');
      if (ver && d.version) ver.textContent = 'v' + d.version;
      const machine = $('machine');
      if (machine && d.localHostId) machine.textContent = 'Host: ' + Y.shortHost(d.localHostId);
      renderIps(d.serverIps);
      // Stamp here, not only from a page's data load: a page with no feed of its
      // own (a static link list) would otherwise show the em-dash forever. A page
      // that does fetch overwrites this a moment later with its own load time.
      // stamp, not markLoaded — arriving host facts must not restart the
      // countdown a caller may already be running.
      stamp();
    }).catch(function () { renderIps(''); });

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

    return { markLoaded: markLoaded, stamp: stamp };
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
