// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// The Download pool page: agent header, image table, per-row actions.
// No innerHTML on data.
(function () {
  const POLL_MS = 5000;
  const SORT_STORAGE_KEY = 'yuruna.download-agent.sort';
  let canMutate = false;
  let gateConfigured = false;
  let labTokenGate = false;
  let timer = null;
  // null means the order the API sent, which is what the table shows until the
  // operator clicks a header.
  let sort = null;
  // The last catalog, so a header click reorders what is already on screen
  // instead of waiting for the next poll.
  let lastImages = [];

  // --- agent header ---------------------------------------------------------

  function setCard(id, value, sub) {
    const v = document.getElementById(id);
    if (v) v.textContent = value;
    if (sub !== undefined) {
      const s = document.getElementById(id + '-sub');
      if (s) s.textContent = sub || '';
    }
  }

  function renderStatus(st) {
    const ag = st.agent || {};
    setCard('ag-pool', ag.poolAvailable ? 'available' : 'unavailable');
    const pd = document.getElementById('ag-pooldir');
    if (pd) pd.textContent = ag.imagesDir || ag.poolDir || '';

    // Read-only is the state that silently explains "why is nothing
    // downloading", so name the holder rather than just the mode.
    setCard('ag-lease', ag.readOnly ? 'read-only' : 'writer',
      ag.readOnly ? ('held by ' + (ag.leaseHolder || 'another agent')) : (ag.leaseError || (ag.leaseHolder || '')));

    const every = ag.scanIntervalSeconds ? ('every ' + Y.duration(ag.scanIntervalSeconds)) : '—';
    let scanSub = 'last ' + Y.stamp(ag.lastScanUtc);
    if (ag.nextScanUtc) scanSub += ' · next ' + Y.stamp(ag.nextScanUtc);
    if (ag.freshnessSeconds) {
      scanSub += ' · fresh ' + Y.duration(ag.freshnessSeconds) + ', lead ' + Y.duration(ag.prefetchLeadSeconds);
    }
    setCard('ag-scan', every, scanSub);

    const seed = ag.lastSeed || {};
    let seedSub = '';
    if (seed.error) seedSub = 'last pass failed: ' + seed.error;
    else if (seed.skipped) seedSub = 'skipped: ' + seed.skipped;
    else if (seed.atUtc) {
      seedSub = Y.stamp(seed.atUtc) + ' · started ' + (seed.started || 0);
      if (seed.deferred) seedSub += ' · deferred ' + seed.deferred;
      if (seed.hostTypes && seed.hostTypes.length) seedSub += ' · ' + seed.hostTypes.join(', ');
      if (seed.skippedHosts) seedSub += ' · ' + seed.skippedHosts + ' host(s) without status';
    }
    setCard('ag-seed', ag.autoSeed ? 'on' : 'off', seedSub);

    // Name the families that cannot run here, and why. A row that is simply
    // absent looks the same whether the image is pending or the agent has no way
    // to fetch it, and only one of those is something an operator can fix.
    const fams = ag.bestEffort || [];
    const down = fams.filter(f => !f.available);
    setCard('ag-besteffort',
      fams.length ? ((fams.length - down.length) + ' of ' + fams.length + ' available') : '—',
      down.length
        ? down.map(f => f.imageKey + ': ' + (f.reason || 'unavailable')).join(' · ')
        : fams.map(f => f.imageKey).join(', '));

    const totals = ag.totals || {};
    setCard('ag-bytes', Y.bytes(totals.bytes || 0),
      (totals.images || 0) + ' entries · ' + Y.bytes(totals.currentBytes || 0) + ' current');
  }

  // --- table ----------------------------------------------------------------

  function badge(state) {
    return Y.el('span', { class: 'badge ' + state, text: state });
  }

  function progressBar(img) {
    if (!img.refreshInFlight) return null;
    const pct = img.bytesTotal > 0 ? Math.min(100, (img.bytesDone / img.bytesTotal) * 100) : 0;
    const fill = Y.el('span', {});
    // Assigned through the CSSOM, never as a style="" attribute: the page's CSP
    // is `style-src 'self'` with no 'unsafe-inline', which blocks an inline
    // style attribute but says nothing about a scripted property.
    fill.style.width = pct.toFixed(1) + '%';
    const bar = Y.el('span', { class: 'progress' }, [fill]);
    const label = img.bytesTotal > 0
      ? Y.bytes(img.bytesDone) + ' / ' + Y.bytes(img.bytesTotal)
      : (img.phase || 'working') + '…';
    return Y.el('div', {}, [Y.el('span', { class: 'muted', text: (img.phase ? img.phase + ' · ' : '') + label }), bar]);
  }

  function verifiedCell(img) {
    if (!img.lastVerifiedAt) return Y.el('span', { class: 'muted', text: '—' });
    const kids = [Y.el('div', { text: Y.stamp(img.lastVerifiedAt) })];
    const s = Number(img.secondsToExpiry || 0);
    const word = s >= 0 ? ('expires in ' + Y.duration(s)) : ('expired ' + Y.duration(-s) + ' ago');
    kids.push(Y.el('div', { class: 'muted', text: word }));
    return Y.el('div', {}, kids);
  }

  function verdictCell(img) {
    if (!img.checksumVerdict) return Y.el('span', { class: 'muted', text: '—' });
    return Y.el('span', { class: 'verdict-' + img.checksumVerdict, text: img.checksumVerdict });
  }

  function sourceCell(img) {
    if (!img.sourceUrl) return Y.el('span', { class: 'muted', text: '—' });
    // Rendered as text, not an anchor: the CSP forbids off-origin navigation
    // targets and the value is only ever read, never followed from here.
    return Y.el('code', { title: img.sourceUrl, text: img.sourceUrl });
  }

  function query(img) {
    return '?arch=' + encodeURIComponent(img.arch) + '&variant=' + encodeURIComponent(img.variant);
  }

  function actionPath(img, verb) {
    return '/api/v1/images/' + encodeURIComponent(img.hostType) + '/' + encodeURIComponent(img.imageKey) +
      '/' + verb + query(img);
  }

  async function act(img, verb, confirmText) {
    if (confirmText && !confirm(confirmText)) return;
    try {
      Y.clearNotice();
      await Y.api(actionPath(img, verb), { method: 'POST' });
      await load();
    } catch (e) {
      Y.notice('error', verb + ' failed for ' + img.imageKey + ': ' + e.message);
    }
  }

  function actionsCell(img) {
    const wrap = Y.el('div', { class: 'actions' });
    const mk = (label, cls, handler, enabled) => {
      const b = Y.el('button', { class: cls, type: 'button', text: label });
      b.disabled = !enabled;
      if (!canMutate) {
        // Say which key opens this door, not just that it is shut: with only a
        // bearer configured there is nothing for the operator to type.
        if (labTokenGate) b.title = 'Enter the dashboard Lab token to enable actions';
        else if (gateConfigured) b.title = 'Actions need the lab auth token as a bearer';
        else b.title = 'No aggregator URL or lab auth token configured on the daemon';
      }
      b.addEventListener('click', handler);
      return b;
    };
    wrap.appendChild(mk('Force refresh', '', () => act(img, 'refresh'), canMutate && img.supported));
    wrap.appendChild(mk('Delete', 'danger', () => act(img, 'delete',
      'Delete every generation of ' + img.imageKey + ' (' + img.hostType + ', ' + img.arch + ', ' + img.variant +
      ')?\n\nThe next host request or seed pass re-downloads it from origin. Hosts keep their local copies.'),
      canMutate && !!img.generation));
    wrap.appendChild(mk('Prune previous', '', () => act(img, 'prune'),
      canMutate && img.previousBytes > 0));
    return wrap;
  }

  function rowEl(img) {
    const stateCell = Y.el('td', {}, [badge(img.state), progressBar(img)]);
    // The reason sits with the badge, not in a tooltip: "unavailable" on its own
    // is the same dead end as no row at all.
    if (img.unavailableReason) {
      stateCell.appendChild(Y.el('div', { class: 'muted', text: img.unavailableReason }));
    }
    if (img.lastError) stateCell.appendChild(Y.el('div', { class: 'err-line', text: img.lastError }));

    // variant is the requested preference; resolvedVariant is what the resolver
    // landed on. Naming both only when they differ is what tells an operator
    // that preference-with-fallback fired, rather than letting the row assert a
    // build the bytes did not come from.
    let ident = img.hostType + ' · ' + img.arch + ' · ' + img.variant;
    if (img.resolvedVariant && img.resolvedVariant !== img.variant) {
      ident += ' (resolved ' + img.resolvedVariant + ')';
    }
    // Best-effort families are never auto-seeded, so an operator who expects the
    // scanner to fill this row eventually needs to know it will not.
    if (img.bestEffort) ident += ' · best effort';
    const idCell = Y.el('td', {}, [
      Y.el('div', { text: img.imageKey }),
      Y.el('div', { class: 'muted', text: ident })
    ]);

    const artifact = img.upstreamFilename
      ? Y.el('div', {}, [
        Y.el('code', { text: img.upstreamFilename }),
        img.generation ? Y.el('div', { class: 'muted mono', text: img.generation }) : null
      ])
      : Y.el('span', { class: 'muted', text: img.supported ? '—' : 'no resolver' });

    const size = Y.el('div', {}, [
      Y.el('div', { text: Y.bytes(img.currentBytes) }),
      Y.el('div', { class: 'muted', text: img.previousBytes ? ('previous ' + Y.bytes(img.previousBytes)) : 'no previous' })
    ]);

    return Y.el('tr', {}, [
      stateCell,
      idCell,
      Y.el('td', {}, [artifact]),
      Y.el('td', {}, [size]),
      Y.el('td', {}, [verifiedCell(img)]),
      Y.el('td', {}, [verdictCell(img)]),
      Y.el('td', {}, [sourceCell(img)]),
      Y.el('td', {}, [actionsCell(img)])
    ]);
  }

  function renderTotals(totals) {
    const foot = document.getElementById('image-totals');
    foot.textContent = '';
    const byHost = totals.byHostType || {};
    const parts = Object.keys(byHost).sort().map(k => k + ' ' + Y.bytes(byHost[k]));
    foot.appendChild(Y.el('tr', {}, [
      Y.el('td', { text: 'Totals' }),
      Y.el('td', { text: (totals.images || 0) + ' entries' }),
      Y.el('td', { class: 'muted', text: parts.join(' · ') || '—' }),
      Y.el('td', {}, [
        Y.el('div', { text: Y.bytes(totals.currentBytes || 0) }),
        Y.el('div', { class: 'muted', text: 'previous ' + Y.bytes(totals.previousBytes || 0) })
      ]),
      Y.el('td', { colspan: '4', text: Y.bytes(totals.bytes || 0) + ' on the share' })
    ]));
  }

  // --- sorting --------------------------------------------------------------

  function sortableHeaders() {
    return Array.prototype.slice.call(document.querySelectorAll('th[data-sort]'));
  }

  // The choice outlives the tab: an operator who sorted by state once expects
  // the same view after a reload, not the API's order back again.
  function loadSort() {
    try {
      const raw = window.localStorage.getItem(SORT_STORAGE_KEY);
      if (!raw) return null;
      const saved = JSON.parse(raw);
      if (saved && YSort.isColumn(saved.col)) return { col: saved.col, dir: saved.dir < 0 ? -1 : 1 };
    } catch (e) {
      // Storage disabled, or holding something this version does not
      // understand: fall back to the API's order rather than failing to render.
    }
    return null;
  }

  function saveSort() {
    try {
      if (sort) window.localStorage.setItem(SORT_STORAGE_KEY, JSON.stringify(sort));
      else window.localStorage.removeItem(SORT_STORAGE_KEY);
    } catch (e) { /* a session that cannot persist the choice still sorts */ }
  }

  function paintHeaders() {
    for (const th of sortableHeaders()) {
      const active = sort && sort.col === th.getAttribute('data-sort');
      th.setAttribute('aria-sort', active ? (sort.dir > 0 ? 'ascending' : 'descending') : 'none');
      const arrow = th.querySelector('.sort-arrow');
      if (arrow) arrow.textContent = active ? (sort.dir > 0 ? '↑' : '↓') : '';
    }
  }

  function wireHeaders() {
    for (const th of sortableHeaders()) {
      const col = th.getAttribute('data-sort');
      const btn = th.querySelector('button');
      if (!btn) continue;
      btn.addEventListener('click', () => {
        sort = (sort && sort.col === col) ? { col: col, dir: -sort.dir } : { col: col, dir: 1 };
        saveSort();
        paintHeaders();
        renderRows();
      });
    }
  }

  // renderRows redraws the body from the last catalog. Every path that changes
  // what the table shows goes through here, which is why a poll landing between
  // two clicks cannot drop the chosen order.
  function renderRows() {
    const body = document.getElementById('image-rows');
    body.textContent = '';
    const rows = sort ? YSort.sort(lastImages, sort.col, sort.dir) : lastImages;
    for (const img of rows) body.appendChild(rowEl(img));
    document.getElementById('empty').hidden = lastImages.length > 0;
  }

  // --- session --------------------------------------------------------------

  async function loadSession() {
    try {
      // Awaited, not raced: a proof carried in from the dashboard has to be
      // spent before the gate is read, or this would render the lab-token
      // prompt for a device that was about to be unlocked anyway.
      await Y.proofUnlock;
      const s = await Y.api('/api/session');
      gateConfigured = !!s.configured;
      labTokenGate = !!s.labToken;
      canMutate = !!s.authed;
      document.getElementById('login').hidden = !(labTokenGate && !s.authed);
      document.getElementById('gate-unconfigured').hidden = gateConfigured;
    } catch (e) {
      gateConfigured = false;
      labTokenGate = false;
      canMutate = false;
    }
  }

  document.getElementById('login-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const field = document.getElementById('lab-token');
    const err = document.getElementById('login-error');
    err.textContent = '';
    try {
      // Normalised here as well as at the daemon, so a code read off the tile in
      // capitals is not a round trip that comes back "incorrect".
      await Y.api('/api/login', { method: 'POST', body: { labToken: field.value.trim().toLowerCase() } });
      field.value = '';
      await loadSession();
      await load();
    } catch (e) {
      err.textContent = e.message;
    }
  });

  // --- polling --------------------------------------------------------------

  // Header version + host id and the footer bar. The countdown drives load()
  // rather than a reload: a reload would wipe a half-typed lab token out of the
  // unlock form. stamp() (not markLoaded) records each poll, because a 5 s poll
  // that reset the 60 s countdown would pin it at 60 and it would never fire.
  // refreshOnVisible is off — the poll below already reloads on that event.
  const chrome = Y.initChrome({ intervalSeconds: 60, refresh: load, refreshOnVisible: false });

  async function load() {
    try {
      const [st, cat] = await Promise.all([Y.api('/api/v1/status'), Y.api('/api/v1/images')]);
      renderStatus(st);
      lastImages = cat.images || [];
      renderRows();
      renderTotals(cat.totals || {});
      document.getElementById('as-of').textContent = 'as of ' + Y.stamp(cat.asOfUtc);
      chrome.stamp();
      if (!cat.poolAvailable) {
        Y.notice('warn', 'The pool share is not available. The agent still answers metadata, but nothing can be downloaded or served until it is mounted.');
      } else {
        Y.clearNotice();
      }
    } catch (e) {
      Y.notice('error', e.message);
    }
  }

  document.getElementById('refresh-view').addEventListener('click', load);

  // Poll so an in-flight download's progress moves without the operator
  // reloading; stop while the tab is hidden so a background tab does not keep
  // walking the share every few seconds.
  function startPolling() {
    if (timer) clearInterval(timer);
    timer = setInterval(load, POLL_MS);
  }
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { clearInterval(timer); timer = null; }
    else { load(); startPolling(); }
  });

  (async function init() {
    sort = loadSort();
    wireHeaders();
    paintHeaders();
    await loadSession();
    await load();
    startPolling();
  })();
})();
