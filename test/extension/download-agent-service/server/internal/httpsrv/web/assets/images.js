// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// The Download pool page: agent header, image table, per-row actions.
// No innerHTML on data.
(function () {
  var POLL_MS = 5000;
  var SORT_STORAGE_KEY = 'yuruna.download-agent.sort';
  var canMutate = false;
  var gateConfigured = false;
  var labTokenGate = false;
  var timer = null;
  // null means the order the API sent, which is what the table shows until the
  // operator clicks a header.
  var sort = null;
  // The last catalog, so a header click reorders what is already on screen
  // instead of waiting for the next poll.
  var lastImages = [];

  // --- agent header ---------------------------------------------------------

  function setCard(id, value, sub) {
    var v = document.getElementById(id);
    if (v) v.textContent = value;
    if (sub !== undefined) {
      var s = document.getElementById(id + '-sub');
      if (s) s.textContent = sub || '';
    }
  }

  function renderStatus(st) {
    var ag = st.agent || {};
    setCard('ag-pool', ag.poolAvailable ? 'available' : 'unavailable');
    var pd = document.getElementById('ag-pooldir');
    if (pd) pd.textContent = ag.imagesDir || ag.poolDir || '';

    // Read-only is the state that silently explains "why is nothing
    // downloading", so name the holder rather than just the mode.
    setCard('ag-lease', ag.readOnly ? 'read-only' : 'writer',
      ag.readOnly ? ('held by ' + (ag.leaseHolder || 'another agent')) : (ag.leaseError || (ag.leaseHolder || '')));

    var every = ag.scanIntervalSeconds ? ('every ' + Y.duration(ag.scanIntervalSeconds)) : '--';
    var scanSub = 'last ' + Y.stamp(ag.lastScanUtc);
    if (ag.nextScanUtc) scanSub += ' - next ' + Y.stamp(ag.nextScanUtc);
    if (ag.freshnessSeconds) {
      scanSub += ' - fresh ' + Y.duration(ag.freshnessSeconds) + ', lead ' + Y.duration(ag.prefetchLeadSeconds);
    }
    setCard('ag-scan', every, scanSub);

    var seed = ag.lastSeed || {};
    var seedSub = '';
    if (seed.error) seedSub = 'last pass failed: ' + seed.error;
    else if (seed.skipped) seedSub = 'skipped: ' + seed.skipped;
    else if (seed.atUtc) {
      seedSub = Y.stamp(seed.atUtc) + ' - started ' + (seed.started || 0);
      if (seed.deferred) seedSub += ' - deferred ' + seed.deferred;
      if (seed.hostTypes && seed.hostTypes.length) seedSub += ' - ' + seed.hostTypes.join(', ');
      if (seed.skippedHosts) seedSub += ' - ' + seed.skippedHosts + ' host(s) without status';
    }
    setCard('ag-seed', ag.autoSeed ? 'on' : 'off', seedSub);

    // Name the families that cannot run here, and why. A row that is simply
    // absent looks the same whether the image is pending or the agent has no way
    // to fetch it, and only one of those is something an operator can fix.
    var fams = ag.bestEffort || [];
    var down = fams.filter(function (f) { return !f.available; });
    setCard('ag-besteffort',
      fams.length ? ((fams.length - down.length) + ' of ' + fams.length + ' available') : '--',
      down.length
        ? down.map(function (f) { return f.imageKey + ': ' + (f.reason || 'unavailable'); }).join(' - ')
        : fams.map(function (f) { return f.imageKey; }).join(', '));

    var totals = ag.totals || {};
    setCard('ag-bytes', Y.bytes(totals.bytes || 0),
      (totals.images || 0) + ' entries - ' + Y.bytes(totals.currentBytes || 0) + ' current');
  }

  // --- table ----------------------------------------------------------------

  function badge(state) {
    return Y.el('span', { class: 'badge ' + state, text: state });
  }

  function progressBar(img) {
    if (!img.refreshInFlight) { return null; }
    var pct = img.bytesTotal > 0 ? Math.min(100, (img.bytesDone / img.bytesTotal) * 100) : 0;
    var fill = Y.el('span', {});
    // Assigned through the CSSOM, never as a style="" attribute: the page's CSP
    // is `style-src 'self'` with no 'unsafe-inline', which blocks an inline
    // style attribute but says nothing about a scripted property.
    fill.style.width = pct.toFixed(1) + '%';
    var bar = Y.el('span', { class: 'progress' }, [fill]);
    var label = img.bytesTotal > 0
      ? Y.bytes(img.bytesDone) + ' / ' + Y.bytes(img.bytesTotal)
      : (img.phase || 'working') + '...';
    return Y.el('div', {}, [Y.el('span', { class: 'muted', text: (img.phase ? img.phase + ' - ' : '') + label }), bar]);
  }

  function verifiedCell(img) {
    if (!img.lastVerifiedAt) { return Y.el('span', { class: 'muted', text: '--' }); }
    var kids = [Y.el('div', { text: Y.stamp(img.lastVerifiedAt) })];
    var s = Number(img.secondsToExpiry || 0);
    var word = s >= 0 ? ('expires in ' + Y.duration(s)) : ('expired ' + Y.duration(-s) + ' ago');
    kids.push(Y.el('div', { class: 'muted', text: word }));
    return Y.el('div', {}, kids);
  }

  function verdictCell(img) {
    if (!img.checksumVerdict) { return Y.el('span', { class: 'muted', text: '--' }); }
    return Y.el('span', { class: 'verdict-' + img.checksumVerdict, text: img.checksumVerdict });
  }

  function sourceCell(img) {
    if (!img.sourceUrl) { return Y.el('span', { class: 'muted', text: '--' }); }
    // Rendered as text, not an anchor: the CSP forbids off-origin navigation
    // targets and the value is only ever read, never followed from here.
    return Y.el('code', { title: img.sourceUrl, text: img.sourceUrl });
  }

  // manualHint is the way out for a row whose resolver cannot run: the page that
  // hands the artifact over, the choices to make on it, and the pool folder to
  // drop the file into. It REPLACES the raw resolver error, which named a
  // failure the operator has no way to act on; that text survives as the line's
  // tooltip, and the Diagnostics page still carries the whole capture.
  function manualHint(img) {
    var mf = img.manualFallback;
    if (!mf || !mf.pageUrl) { return null; }
    // Both targets open in a new tab: the publisher page so the pool view is
    // not lost, and the folder because a browser may well refuse to follow a
    // file:// link at all -- losing this page to a blocked navigation would
    // cost the operator the very instructions they were following.
    // file: is opted into here because the second link below is the pool folder
    // on this machine's share, which is the whole point of the instruction.
    var link = function (href, text) {
      return Y.linkTo(href, ['file:'], { target: '_blank', rel: 'noopener noreferrer', text: text });
    };
    var parts = ['Fido failed. Visit ', link(mf.pageUrl, 'this page'), '. Select '];
    var selections = mf.selections || [];
    for (var i = 0; i < selections.length; i++) {
      if (i > 0) { parts.push(', '); }
      parts.push(Y.el('em', { text: selections[i] }));
    }
    parts.push('. Copy the downloaded file into ');
    parts.push(mf.folderUrl ? link(mf.folderUrl, 'this folder') : Y.el('span', { text: 'this folder' }));
    parts.push('.');

    var why = img.lastError || img.unavailableReason || '';
    var kids = [Y.el('div', { class: 'hint', title: why }, parts)];
    if (mf.folder) { kids.push(Y.el('div', { class: 'muted mono', text: mf.folder })); }
    return Y.el('div', {}, kids);
  }

  function query(img) {
    return '?arch=' + encodeURIComponent(img.arch) + '&variant=' + encodeURIComponent(img.variant);
  }

  function actionPath(img, verb) {
    return '/api/v1/images/' + encodeURIComponent(img.hostType) + '/' + encodeURIComponent(img.imageKey) +
      '/' + verb + query(img);
  }

  function act(img, verb, confirmText, row) {
    if (confirmText && !window.confirm(confirmText)) { return Promise.resolve(); }
    Y.clearNotice();
    return Y.api(actionPath(img, verb), { method: 'POST' }).then(function () {
      // In the row as well as the banner: at high zoom the banner is off-screen
      // from the button that caused it.
      Y.rowFeedback(row, 'ok', verb + ' started.');
      return load();
    }, function (e) {
      Y.notice('error', verb + ' failed for ' + img.imageKey + ': ' + e.message);
      Y.rowFeedback(row, 'error', verb + ' failed: ' + e.message);
    });
  }

  function actionsCell(img) {
    var wrap = Y.el('div', { class: 'actions' });
    var mk = function (label, cls, handler, enabled) {
      var b = Y.el('button', { class: cls, type: 'button', text: label });
      b.disabled = !enabled;
      if (!canMutate) {
        // Say which key opens this door, not just that it is shut: with only a
        // bearer configured there is nothing for the operator to type.
        if (labTokenGate) { b.title = 'Enter the dashboard Lab token to enable actions'; }
        else if (gateConfigured) { b.title = 'Actions need the internal authentication key as a bearer'; }
        else { b.title = 'No aggregator URL or internal authentication key configured on the daemon'; }
      }
      b.addEventListener('click', handler);
      return b;
    };
    // Each handler takes the event so it can hand act() the row it fired from:
    // the outcome then lands beside the button instead of only in the banner at
    // the top of the page, which is off-screen at high zoom.
    var rowOf = function (ev) { return ev.currentTarget.closest('tr'); };
    wrap.appendChild(mk('Force refresh', '',
      function (ev) { return act(img, 'refresh', null, rowOf(ev)); },
      canMutate && img.supported));
    wrap.appendChild(mk('Delete', 'danger',
      function (ev) {
        return act(img, 'delete',
          'Delete every generation of ' + img.imageKey + ' (' + img.hostType + ', ' + img.arch + ', ' + img.variant +
          ')?\n\nThe next host request or seed pass re-downloads it from origin. Hosts keep their local copies.',
          rowOf(ev));
      },
      canMutate && !!img.generation));
    // Prune discards previous generations, which nothing re-creates, so it asks
    // the same way its sibling Delete does -- both destroy bytes.
    wrap.appendChild(mk('Prune previous', '',
      function (ev) {
        return act(img, 'prune',
          'Discard the previous generations of ' + img.imageKey + ' (' + img.hostType + ', ' + img.arch + ', ' + img.variant +
          ')?\n\nThe current generation is kept. The discarded ones are not recoverable.',
          rowOf(ev));
      },
      canMutate && img.previousBytes > 0));
    return wrap;
  }

  // n is where the row sits on screen, not anything about the image: the
  // counter is rebuilt from the painted order, so it still reads 1..N after a
  // header reorders the table.
  function rowEl(img, n) {
    var stateCell = Y.el('td', {}, [badge(img.state), progressBar(img)]);
    // The reason sits with the badge, not in a tooltip: "unavailable" on its own
    // is the same dead end as no row at all. A row with a hand-download path
    // carries that instead -- it says the same thing and adds what to do.
    var hint = manualHint(img);
    if (hint) {
      stateCell.appendChild(hint);
    } else {
      if (img.unavailableReason) {
        stateCell.appendChild(Y.el('div', { class: 'muted', text: img.unavailableReason }));
      }
      if (img.lastError) { stateCell.appendChild(Y.el('div', { class: 'err-line', text: img.lastError })); }
    }

    // variant is the requested preference; resolvedVariant is what the resolver
    // landed on. Naming both only when they differ is what tells an operator
    // that preference-with-fallback fired, rather than letting the row assert a
    // build the bytes did not come from.
    var ident = img.hostType + ' - ' + img.arch + ' - ' + img.variant;
    if (img.resolvedVariant && img.resolvedVariant !== img.variant) {
      ident += ' (resolved ' + img.resolvedVariant + ')';
    }
    // Best-effort families are never auto-seeded, so an operator who expects the
    // scanner to fill this row eventually needs to know it will not.
    if (img.bestEffort) { ident += ' - best effort'; }
    // scope="row" makes this the row header, so a screen reader announces the
    // image key with every other cell in the row -- including the three action
    // buttons, which are otherwise "Delete" repeated down the table.
    var idCell = Y.el('th', { scope: 'row' }, [
      Y.el('div', { text: img.imageKey }),
      Y.el('div', { class: 'muted', text: ident })
    ]);

    var artifact = img.upstreamFilename
      ? Y.el('div', {}, [
        Y.el('code', { text: img.upstreamFilename }),
        img.generation ? Y.el('div', { class: 'muted mono', text: img.generation }) : null
      ])
      : Y.el('span', { class: 'muted', text: img.supported ? '--' : 'no resolver' });

    var size = Y.el('div', {}, [
      Y.el('div', { text: Y.bytes(img.currentBytes) }),
      Y.el('div', { class: 'muted', text: img.previousBytes ? ('previous ' + Y.bytes(img.previousBytes)) : 'no previous' })
    ]);

    return Y.el('tr', {}, [
      Y.numCell(n),
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
    var foot = document.getElementById('image-totals');
    foot.textContent = '';
    var byHost = totals.byHostType || {};
    var parts = Object.keys(byHost).sort().map(function (k) { return k + ' ' + Y.bytes(byHost[k]); });
    foot.appendChild(Y.el('tr', {}, [
      // Blank, but present: the totals row has to carry a cell for the counter
      // column or every figure in it sits one column left of what it sums.
      Y.numCell(0),
      Y.el('td', { text: 'Totals' }),
      Y.el('td', { text: (totals.images || 0) + ' entries' }),
      Y.el('td', { class: 'muted', text: parts.join(' - ') || '--' }),
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
      var raw = window.localStorage.getItem(SORT_STORAGE_KEY);
      if (!raw) { return null; }
      var saved = JSON.parse(raw);
      if (saved && YSort.isColumn(saved.col)) { return { col: saved.col, dir: saved.dir < 0 ? -1 : 1 }; }
    } catch (e) {
      // Storage disabled, or holding something this version does not
      // understand: fall back to the API's order rather than failing to render.
    }
    return null;
  }

  function saveSort() {
    try {
      if (sort) { window.localStorage.setItem(SORT_STORAGE_KEY, JSON.stringify(sort)); }
      else { window.localStorage.removeItem(SORT_STORAGE_KEY); }
    } catch (e) { /* a session that cannot persist the choice still sorts */ }
  }

  function paintHeaders() {
    var ths = sortableHeaders();
    for (var i = 0; i < ths.length; i++) {
      var th = ths[i];
      var active = sort && sort.col === th.getAttribute('data-sort');
      th.setAttribute('aria-sort', active ? (sort.dir > 0 ? 'ascending' : 'descending') : 'none');
      var arrow = th.querySelector('.sort-arrow');
      if (arrow) { arrow.textContent = active ? (sort.dir > 0 ? '^' : 'v') : ''; }
    }
  }

  function wireHeaders() {
    var ths = sortableHeaders();
    for (var i = 0; i < ths.length; i++) {
      // Wired through a call rather than from the loop body, so each handler
      // closes over ITS column instead of the last one in the row.
      (function (th) {
        var col = th.getAttribute('data-sort');
        var btn = th.querySelector('button');
        if (!btn) { return; }
        btn.addEventListener('click', function () {
          sort = (sort && sort.col === col) ? { col: col, dir: -sort.dir } : { col: col, dir: 1 };
          saveSort();
          paintHeaders();
          renderRows();
        });
      }(ths[i]));
    }
  }

  // renderRows redraws the body from the last catalog. Every path that changes
  // what the table shows goes through here, which is why a poll landing between
  // two clicks cannot drop the chosen order.
  function renderRows() {
    var body = document.getElementById('image-rows');
    if (Y.holdRepaint(body, renderRows)) { return; }
    body.textContent = '';
    var rows = sort ? YSort.sort(lastImages, sort.col, sort.dir) : lastImages;
    for (var i = 0; i < rows.length; i++) { body.appendChild(rowEl(rows[i], i + 1)); }
    document.getElementById('empty').hidden = lastImages.length > 0;
  }

  // --- session --------------------------------------------------------------

  function loadSession() {
    // Awaited, not raced: a proof carried in from the dashboard has to be spent
    // before the gate is read, or this would render the lab-token prompt for a
    // device that was about to be unlocked anyway.
    return Y.proofUnlock.then(function () {
      return Y.api('/api/session');
    }).then(function (s) {
      gateConfigured = !!s.configured;
      labTokenGate = !!s.labToken;
      canMutate = !!s.authed;
      document.getElementById('login').hidden = !(labTokenGate && !s.authed);
      document.getElementById('gate-unconfigured').hidden = gateConfigured;
    }, function () {
      // A gate this page cannot vouch for offers no control it cannot back.
      gateConfigured = false;
      labTokenGate = false;
      canMutate = false;
    });
  }

  document.getElementById('login-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    var field = document.getElementById('lab-token');
    var err = document.getElementById('login-error');
    err.textContent = '';
    // Normalized here as well as at the daemon, so a code read off the tile in
    // capitals is not a round trip that comes back "incorrect".
    Y.api('/api/login', { method: 'POST', body: { labToken: field.value.trim().toLowerCase() } }).then(function () {
      field.value = '';
      return loadSession().then(load);
    }, function (e) {
      err.textContent = e.message;
    });
  });

  // --- polling --------------------------------------------------------------

  // Header version + host id and the footer bar. The countdown drives load()
  // rather than a reload: a reload would wipe a half-typed lab token out of the
  // unlock form. stamp() (not markLoaded) records each poll, because a 5 s poll
  // that reset the 60 s countdown would pin it at 60 and it would never fire.
  // refreshOnVisible is off -- the poll below already reloads on that event.
  var chrome = Y.initChrome({ intervalSeconds: 60, refresh: load, refreshOnVisible: false });

  function load() {
    return Promise.all([Y.api('/api/v1/status'), Y.api('/api/v1/images')]).then(function (both) {
      var cat = both[1];
      renderStatus(both[0]);
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
    }, function (e) {
      Y.notice('error', e.message);
    });
  }

  // Wrapped rather than passed straight to the listener: load takes no
  // arguments, and a DOM event is not one.
  document.getElementById('refresh-view').addEventListener('click', function () { load(); });

  // Poll so an in-flight download's progress moves without the operator
  // reloading; stop while the tab is hidden so a background tab does not keep
  // walking the share every few seconds.
  function startPolling() {
    if (timer) { window.clearInterval(timer); }
    timer = window.setInterval(function () { load(); }, POLL_MS);
  }
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) { window.clearInterval(timer); timer = null; }
    else { load(); startPolling(); }
  });

  (function init() {
    sort = loadSort();
    wireHeaders();
    paintHeaders();
    loadSession().then(load).then(startPolling, startPolling);
  }());
})();
