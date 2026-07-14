// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Recent-stashes list + search (stash-service-ui.md §4). Visibility-aware
// auto-refresh so a backgrounded tab does not poll.

(function () {
  const PAGE = 50;
  let offset = 0;
  let lastTotal = 0;
  const seenHosts = new Set();

  const $ = (id) => document.getElementById(id);

  function filterQuery() {
    const p = new URLSearchParams();
    const q = $('q').value.trim();
    const cls = $('class').value;
    const host = $('host').value;
    if (q) p.set('q', q);
    if (cls) p.set('class', cls);
    if (host) p.set('host', host);
    p.set('limit', String(PAGE));
    p.set('offset', String(offset));
    return p.toString();
  }

  function statusBadge(s) {
    return Y.el('span', { class: 'badge ' + s, text: s });
  }

  function row(v) {
    const tr = Y.el('tr', { onclick: () => { location.href = v.permalink; } });
    tr.append(
      Y.el('td', { text: Y.classIcon(v.contentClass), title: v.mimeType || v.contentClass }),
      Y.el('td', { class: 'mono', text: v.id }),
      Y.el('td', { text: v.originalFilename || '(unnamed)' }),
      Y.el('td', {}, Y.el('span', { class: 'badge ' + (v.local ? 'local' : 'host'), title: v.hostId, text: v.local ? 'this host' : Y.shortHost(v.hostId) })),
      Y.el('td', { text: v.username }),
      Y.el('td', { class: 'num', text: Y.humanSize(v.sizeBytes) }),
      Y.el('td', { text: Y.fmtDate(v.createdAt) }),
      Y.el('td', {}, statusBadge(v.status)),
    );
    return tr;
  }

  async function load(reset) {
    if (reset) { offset = 0; Y.replace($('rows')); }
    $('status').textContent = 'Loading…';
    try {
      const data = await Y.api('/api/stashes?' + filterQuery());
      if (data.localHostId) $('machine').textContent = 'this host: ' + Y.shortHost(data.localHostId);
      if (data.version) $('header-version').textContent = 'v' + data.version;
      lastTotal = data.total;
      for (const v of data.stashes) {
        $('rows').append(row(v));
        if (v.hostId && !seenHosts.has(v.hostId)) {
          seenHosts.add(v.hostId);
          if (!v.local) $('host').append(Y.el('option', { value: v.hostId, text: Y.shortHost(v.hostId) }));
        }
      }
      offset += data.stashes.length;
      $('status').textContent = data.total + ' stash' + (data.total === 1 ? '' : 'es') + ' (showing ' + Math.min(offset, data.total) + ')';
      $('more').style.display = offset < data.total ? '' : 'none';
      footer.markLoaded();
    } catch (e) {
      $('status').textContent = 'Error: ' + e.message;
    }
  }

  let timer = null;
  function debounced() { clearTimeout(timer); timer = setTimeout(() => load(true), 250); }

  $('q').addEventListener('input', debounced);
  $('class').addEventListener('change', () => load(true));
  $('host').addEventListener('change', () => load(true));
  $('more').addEventListener('click', () => load(false));
  $('refresh').addEventListener('click', async () => {
    $('refresh').disabled = true;
    try { await Y.api('/api/refresh', { method: 'POST' }); await load(true); }
    finally { $('refresh').disabled = false; }
  });

  // Shared footer: server IPs, last-loaded time, and the refresh countdown
  // (default 60 s). The countdown drives the visibility-aware auto-refresh of
  // the first page — but only when not searching or paginated (§4.1), so it
  // never yanks the user off a "Load more" page or an active query. Each
  // successful load() stamps the footer's "Loaded" time + resets the countdown.
  const footer = Y.initFooter({
    intervalSeconds: 60,
    refresh: () => { if (offset <= PAGE && !$('q').value) load(true); },
  });

  load(true);
})();
