// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Shared helpers for the stash UI. Vanilla JS, no framework
// (stash-service-ui.md §2.3). Untrusted stash content is ALWAYS placed via
// textContent / safe DOM APIs, never innerHTML (§7.4).

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

  async api(path, opts) {
    // Bound the request so a stalled daemon cannot hang the page load (and its
    // footer) forever; the abort surfaces as a thrown error the caller's catch
    // already handles. opts.timeoutMs overrides the 10s default.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), (opts && opts.timeoutMs) || 10000);
    try {
      const res = await fetch(path, Object.assign({}, opts, { signal: controller.signal }));
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

  shortHost(h) { return h ? h.slice(0, 8) : '?'; },

  notice(parent, kind, text) {
    const n = Y.el('div', { class: 'notice ' + kind, text });
    parent.prepend(n);
    return n;
  },

  // initFooter wires the shared bottom footer bar (server IPs, last-loaded
  // time, refresh countdown) used across the stash UI pages. Self-contained
  // and page-agnostic: it pulls host facts from /api/hostinfo (so it needs no
  // page-specific data), runs a visibility-aware countdown (default 60 s,
  // matched to the status pages), and returns { markLoaded } so a page can
  // stamp the "Loaded" time + reset the countdown whenever ITS own data
  // refreshes. When the countdown reaches zero it invokes opts.refresh
  // (default: a full reload). A no-op on a page without #footer-bar markup.
  // Mirrors the status pages' footer (yuruna.common.js) for consistency.
  initFooter(opts) {
    opts = opts || {};
    const interval = opts.intervalSeconds > 0 ? opts.intervalSeconds : 60;
    const refresh = typeof opts.refresh === 'function' ? opts.refresh : () => location.reload();
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
    Y.api('/api/hostinfo').then((d) => renderIps(d && d.serverIps)).catch(() => renderIps(''));

    const markLoaded = () => {
      const el = $('last-loaded');
      if (el) el.textContent = new Date().toLocaleTimeString();
      countdown = interval;
    };

    const link = $('footer-refresh');
    if (link) link.addEventListener('click', (e) => { e.preventDefault(); location.reload(); });

    // One-second tick. A hidden tab parks the countdown ('...') and never
    // refreshes (a backgrounded page must not poll, §4.1); returning to the
    // foreground forces a refresh on the next tick (countdown driven to 0).
    setInterval(() => {
      const el = $('countdown');
      if (document.hidden) { if (el) el.textContent = '...'; return; }
      countdown = Math.max(0, countdown - 1);
      if (el) el.textContent = countdown;
      if (countdown === 0) { countdown = interval; refresh(); }
    }, 1000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) countdown = 0; });

    return { markLoaded };
  },
};

// safeUrl gates href/src attribute values: only same-origin relative paths
// and absolute http(s) URLs are allowed, so a javascript:/data:/vbscript:
// value (e.g. a spoofed remoteStashUrl, stash-service-ui.md §7.4) can never
// become an executable link. Returns null to drop the attribute.
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
  // permalink = /s/<host>/<y>/<m>/<d>/<id>
  const parts = view.permalink.split('/').filter(Boolean); // [s, host, y, m, d, id]
  return '/' + parts.slice(2).join('/');
}
