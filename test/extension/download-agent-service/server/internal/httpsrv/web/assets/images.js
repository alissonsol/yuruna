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

  // --- REGION: Agent header
  function lastErrorText(image) {
    return image.lastErrorCode ? window.YurunaI18n.t(image.lastErrorCode, image.lastErrorArguments || {}) : (image.lastError || '');
  }

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
    setCard('ag-pool', ag.poolAvailable ? window.YurunaI18n.t("download.available") : window.YurunaI18n.t("download.unavailable"));
    var pd = document.getElementById('ag-pooldir');
    if (pd) pd.textContent = ag.imagesDir || ag.poolDir || '';

    // Read-only is the state that silently explains "why is nothing
    // downloading", so name the holder rather than just the mode.
    setCard('ag-lease', ag.readOnly ? window.YurunaI18n.t("download.read_only") : window.YurunaI18n.t("download.writer"),
      ag.readOnly ? window.YurunaI18n.t("download.held_by_value1", {value1: (ag.leaseHolder || 'another agent')}) : ag.leaseError || (ag.leaseHolder || ''));

    var every = ag.scanIntervalSeconds ? window.YurunaI18n.t("download.every_value1", {value1: (Y.duration(ag.scanIntervalSeconds))}) : '--';
    var scanSub = window.YurunaI18n.t("download.last_value1", {value1: (Y.stamp(ag.lastScanUtc))});
    if (ag.nextScanUtc) scanSub += ' — ' + window.YurunaI18n.t('download.next_scan', {time: Y.stamp(ag.nextScanUtc)});
    if (ag.freshnessSeconds) {
      scanSub += ' — ' + window.YurunaI18n.t('download.freshness_window', {freshness: Y.duration(ag.freshnessSeconds), lead: Y.duration(ag.prefetchLeadSeconds)});
    }
    setCard('ag-scan', every, scanSub);

    var seed = ag.lastSeed || {};
    var seedSub = '';
    if (seed.error) seedSub = window.YurunaI18n.t("download.last_pass_failed_value1", {value1: (seed.error)});
    else if (seed.skipped) seedSub = window.YurunaI18n.t("download.skipped_value1", {value1: (seed.skipped)});
    else if (seed.atUtc) {
      seedSub = window.YurunaI18n.t("download.value1_started_value2", {value1: (Y.stamp(seed.atUtc)), value2: (seed.started || 0)});
      if (seed.deferred) seedSub += ' — ' + window.YurunaI18n.t('download.deferred_count', {count: seed.deferred});
      if (seed.hostTypes && seed.hostTypes.length) seedSub += ' - ' + seed.hostTypes.join(', ');
      if (seed.skippedHosts) seedSub += ' — ' + window.YurunaI18n.t('download.hosts_without_status', {count: seed.skippedHosts});
    }
    setCard('ag-seed', ag.autoSeed ? window.YurunaI18n.t("download.on") : window.YurunaI18n.t("download.off"), seedSub);

    // Name the families that cannot run here, and why. A row that is simply
    // absent looks the same whether the image is pending or the agent has no way
    // to fetch it, and only one of those is something an operator can fix.
    var fams = ag.bestEffort || [];
    var down = fams.filter(function (f) { return !f.available; });
    setCard('ag-besteffort',
      fams.length ? window.YurunaI18n.t("download.value1_of_value2_available", {value1: (fams.length - down.length), value2: (fams.length)}) : '--',
      down.length
        ? down.map(function (f) { return f.imageKey + ': ' + (f.reason || 'unavailable'); }).join(' - ')
        : fams.map(function (f) { return f.imageKey; }).join(', '));

    var totals = ag.totals || {};
    setCard('ag-bytes', Y.bytes(totals.bytes || 0),
      (window.YurunaI18n.t('download.entry_bytes', {count: totals.images || 0, bytes: Y.bytes(totals.currentBytes || 0)})));
  }

  // --- REGION: Table
  function badge(state) {
    return Y.el('span', { class: 'badge ' + state, text: Y.displayState(state) });
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
    var label = img.bytesTotal > 0 ? ("" + (Y.bytes(img.bytesDone)) + " / " + (Y.bytes(img.bytesTotal)) + "") : ("" + Y.displayState(img.phase || 'working') + "...");
    return Y.el('div', {}, [Y.el('span', { class: 'muted', text: (img.phase ? Y.displayState(img.phase) + ' - ' : '') + label }), bar]);
  }

  function verifiedCell(img) {
    if (!img.lastVerifiedAt) { return Y.el('span', { class: 'muted', text: '--' }); }
    var kids = [Y.el('div', { text: Y.stamp(img.lastVerifiedAt) })];
    var s = Number(img.secondsToExpiry || 0);
    var word = s >= 0 ? window.YurunaI18n.t("download.expires_in_value1", {value1: (Y.duration(s))}) : window.YurunaI18n.t("download.expired_value1_ago", {value1: (Y.duration(-s))});
    kids.push(Y.el('div', { class: 'muted', text: word }));
    return Y.el('div', {}, kids);
  }

  function verdictCell(img) {
    if (!img.checksumVerdict) { return Y.el('span', { class: 'muted', text: '--' }); }
    return Y.el('span', { class: 'verdict-' + img.checksumVerdict, text: Y.displayState(img.checksumVerdict) });
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
    var selections = mf.selections || [];
    var parts = [window.YurunaI18n.t('download.manual_resolve', {selections: selections.join(', ')}), ' ',
      link(mf.pageUrl, window.YurunaI18n.t('download.this_page')), ' ',
      window.YurunaI18n.t('download.manual_copy'), ' ',
      mf.folderUrl ? link(mf.folderUrl, window.YurunaI18n.t('download.this_folder')) : Y.el('span', {text: window.YurunaI18n.t('download.this_folder')})];

    var why = lastErrorText(img) || img.unavailableReason || '';
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
      Y.rowFeedback(row, 'ok', window.YurunaI18n.t("download.value1_started", {value1: (verb)}));
      return load();
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("download.value1_failed_for_value2_value3", {value1: (verb), value2: (img.imageKey), value3: (e.message)}));
      Y.rowFeedback(row, 'error', window.YurunaI18n.t("download.value1_failed_value2", {value1: (verb), value2: (e.message)}));
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
        if (labTokenGate) { b.title = window.YurunaI18n.t("download.enter_the_dashboard_lab_token_to_enable_actions"); }
        else if (gateConfigured) { b.title = window.YurunaI18n.t("download.actions_need_the_internal_authentication_key_as_a_bearer"); }
        else { b.title = window.YurunaI18n.t("download.no_aggregator_url_or_internal_authentication_key_configured_on_th"); }
      }
      b.addEventListener('click', handler);
      return b;
    };
    // Each handler takes the event so it can hand act() the row it fired from:
    // the outcome then lands beside the button instead of only in the banner at
    // the top of the page, which is off-screen at high zoom.
    var rowOf = function (ev) { return ev.currentTarget.closest('tr'); };
    wrap.appendChild(mk(window.YurunaI18n.t("download.force_refresh"), '',
      function (ev) { return act(img, 'refresh', null, rowOf(ev)); },
      canMutate && img.supported));
    wrap.appendChild(mk(window.YurunaI18n.t("download.delete"), 'danger',
      function (ev) {
        return act(img, 'delete',
          window.YurunaI18n.t("download.delete_every_generation_of_value1_value2_value3_value4_the_next_h", {value1: (img.imageKey), value2: (img.hostType), value3: (img.arch), value4: (img.variant)}),
          rowOf(ev));
      },
      canMutate && !!img.generation));
    // Prune discards previous generations, which nothing re-creates, so it asks
    // the same way its sibling Delete does -- both destroy bytes.
    wrap.appendChild(mk(window.YurunaI18n.t("download.prune_previous"), '',
      function (ev) {
        return act(img, 'prune',
          window.YurunaI18n.t("download.discard_the_previous_generations_of_value1_value2_value3_value4_t", {value1: (img.imageKey), value2: (img.hostType), value3: (img.arch), value4: (img.variant)}),
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
      if (img.lastError) { stateCell.appendChild(Y.el('div', { class: 'err-line', text: lastErrorText(img) })); }
    }

    // variant is the requested preference; resolvedVariant is what the resolver
    // landed on. Naming both only when they differ is what tells an operator
    // that preference-with-fallback fired, rather than letting the row assert a
    // build the bytes did not come from.
    var ident = img.hostType + ' - ' + img.arch + ' - ' + img.variant;
    if (img.resolvedVariant && img.resolvedVariant !== img.variant) {
      ident = window.YurunaI18n.t('download.resolved_variant', {identity: ident, variant: img.resolvedVariant});
    }
    // Best-effort families are never auto-seeded, so an operator who expects the
    // scanner to fill this row eventually needs to know it will not.
    if (img.bestEffort) { ident = window.YurunaI18n.t('download.best_effort_identity', {identity: ident}); }
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
      : Y.el('span', { class: 'muted', text: img.supported ? '--' : window.YurunaI18n.t("download.no_resolver") });

    var size = Y.el('div', {}, [
      Y.el('div', { text: Y.bytes(img.currentBytes) }),
      Y.el('div', { class: 'muted', text: img.previousBytes ? window.YurunaI18n.t("download.previous_value1", {value1: (Y.bytes(img.previousBytes))}) : window.YurunaI18n.t("download.no_previous") })
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
      Y.el('td', { text: window.YurunaI18n.t("download.totals") }),
      Y.el('td', { text: (window.YurunaI18n.t('download.entry_count', {count: totals.images || 0})) }),
      Y.el('td', { class: 'muted', text: parts.join(' - ') || '--' }),
      Y.el('td', {}, [
        Y.el('div', { text: Y.bytes(totals.currentBytes || 0) }),
        Y.el('div', { class: 'muted', text: window.YurunaI18n.t("download.previous_value1", {value1: (Y.bytes(totals.previousBytes || 0))}) })
      ]),
      Y.el('td', { colspan: '4', text: window.YurunaI18n.t("download.value1_on_the_share", {value1: (Y.bytes(totals.bytes || 0))}) })
    ]));
  }

  // --- REGION: Sorting
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
      if (arrow) { arrow.textContent = active ? sort.dir > 0 ? '^' : window.YurunaI18n.t("download.v") : ''; }
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
  var primaryLoaded = false;
  function renderRows() {
    return window.YurunaFirstUsable.measure("test/extension/download-agent-service/server/internal/httpsrv/web/index.html", "data", function () {
      return renderRowsMeasured();
    });
  }


  function renderRowsMeasured() {
    var body = document.getElementById('image-rows');
    if (Y.holdRepaint(body, renderRows)) { return; }
    body.textContent = '';
    var rows = sort ? YSort.sort(lastImages, sort.col, sort.dir) : lastImages;
    for (var i = 0; i < rows.length; i++) { body.appendChild(rowEl(rows[i], i + 1)); }
    document.getElementById('empty').hidden = lastImages.length > 0;
    if (primaryLoaded) {
      window.YurunaFirstUsable.mark('test/extension/download-agent-service/server/internal/httpsrv/web/index.html', lastImages.length ? 'data' : 'empty');
    }
  }

  // --- REGION: Session
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

  // --- REGION: Polling
  // Header version + host id and the footer bar. The countdown drives load()
  // rather than a reload: a reload would wipe a half-typed lab token out of the
  // unlock form. stamp() (not markLoaded) records each poll, because a 5 s poll
  // that reset the 60 s countdown would pin it at 60 and it would never fire.
  // refreshOnVisible is off -- the poll below already reloads on that event.
  var chrome = Y.initChrome({ intervalSeconds: 60, refresh: load, refreshOnVisible: false });

  function load() {
    window.YurunaFirstUsable.hold('primary');
    return Promise.all([Y.api('/api/v1/status'), Y.api('/api/v1/images')]).then(function (both) {
      var cat = both[1];
      renderStatus(both[0]);
      lastImages = cat.images || [];
      primaryLoaded = true;
      renderRows();
      renderTotals(cat.totals || {});
      document.getElementById('as-of').textContent = window.YurunaI18n.t("download.as_of_value1_273588ee", {value1: (Y.stamp(cat.asOfUtc))});
      chrome.stamp();
      if (!cat.poolAvailable) {
        Y.notice('warn', window.YurunaI18n.t("download.the_pool_share_is_not_available_the_agent_still_answers_metadata_"));
      } else {
        Y.clearNotice();
      }
    }, function (e) {
      Y.notice('error', e.message);
      window.YurunaFirstUsable.mark('test/extension/download-agent-service/server/internal/httpsrv/web/index.html', 'error');
    }).then(function () {
      window.YurunaFirstUsable.release('primary');
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
