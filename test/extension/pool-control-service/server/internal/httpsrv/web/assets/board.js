// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// Operator board. Every value here comes from an operator or a project repo, so
// nothing is ever written with innerHTML -- Y.el sets textContent.
(function () {
  var RANGE_KEY = 'yuruna.board.range';

  // Guarded both ways: private browsing makes localStorage throw on write, and
  // on some builds on read too. A board that cannot remember the chosen period
  // is a smaller loss than a board that does not render.
  function remembered(key, fallback) {
    try { return window.localStorage.getItem(key) || fallback; } catch (e) { return fallback; }
  }
  function remember(key, value) {
    try { window.localStorage.setItem(key, value); } catch (e) { /* private mode */ }
  }

  var state = { range: remembered(RANGE_KEY, '24h'), cards: [] };
  var timer = null;

  function $(id) { return document.getElementById(id); }

  // The class carries the look; aria-pressed carries the state. Setting only
  // the class leaves the selected range visible and unannounced. Written with
  // add/remove rather than classList.toggle's force argument, which the browser
  // baseline does not carry everywhere.
  function markPeriod(selected) {
    var all = document.querySelectorAll('.periods button');
    for (var i = 0; i < all.length; i++) {
      var b = all[i];
      var on = (b === selected);
      if (on) { b.className = b.className.indexOf('on') >= 0 ? b.className : (b.className + ' on').replace(/^\s+/, ''); }
      else { b.className = b.className.replace(/\bon\b/g, '').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, ''); }
      b.setAttribute('aria-pressed', String(on));
    }
  }

  // --- REGION: Rendering
  // Thresholds mirror the Grafana tile exactly: red below 95, amber below 100,
  // green only at a clean 100.
  function heroClass(pct) {
    if (pct === null || pct === undefined) { return 'none'; }
    if (pct >= 100) { return 'good'; }
    if (pct >= 95) { return 'warn'; }
    return 'bad';
  }

  function fmtPct(pct) {
    // null means the window held no terminal cycle. Deliberately NOT 100%: an
    // idle or freshly built pool must not read as healthy.
    return (pct === null || pct === undefined) ? 'n/a' : pct.toFixed(2) + '%';
  }

  function cardEl(c) {
    var kids = [
      Y.el('h2', { text: c.displayName }),
      Y.el('p', { class: 'hosts', text: (window.YurunaI18n.t('pool.hosts_reporting', {count: c.hostsTotal, reporting: c.hostsReporting})) }),
      Y.el('div', { class: 'hero ' + heroClass(c.successPct) }, [
        Y.el('span', { class: 'pct', text: fmtPct(c.successPct) }),
        Y.el('span', { class: 'lbl', text: window.YurunaI18n.t("pool.success") })
      ]),
      Y.el('div', { class: 'counts' }, [
        Y.el('div', {}, [Y.el('span', { class: 'n', text: String(c.total) }), Y.el('span', { class: 'k', text: window.YurunaI18n.t("pool.cycles") })]),
        Y.el('div', {}, [Y.el('span', { class: 'n', text: String(c.failed) }), Y.el('span', { class: 'k', text: window.YurunaI18n.t("pool.failed") })])
      ])
    ];

    // What the pool's hosts run: the project URL the pool sets, or their own
    // projects when it sets none. Shown read-only; a pool's URLs are set on the
    // Pools page. The URL is operator-typed, so it is bidi-isolated, and a raw
    // URL has no break points, so board.css lets it wrap anywhere.
    var assigned = Y.el('p', { class: 'assigned' });
    assigned.appendChild(document.createTextNode(window.YurunaI18n.t("pool.running")));
    if (c.projectUrl) {
      assigned.appendChild(Y.el('strong', { text: Y.bidiIsolate(c.projectUrl) }));
    } else {
      assigned.appendChild(Y.el('span', { class: 'none', text: window.YurunaI18n.t("pool.the_hosts_own_projects") }));
    }
    kids.push(assigned);

    if (c.blocked && c.blocked.length) {
      kids.push(Y.el('p', {
        class: 'blocked',
        text: (window.YurunaI18n.t('pool.hosts_project_denied', {count: c.blocked.length}))
      }));
    }
    return Y.el('section', { class: 'card' }, kids);
  }

  function render() {
    return window.YurunaFirstUsable.measure("test/extension/pool-control-service/server/internal/httpsrv/web/board.html", "data", function () {
      return renderMeasured();
    });
  }


  function renderMeasured() {
    var host = $('cards');
    if (Y.holdRepaint(host, render)) { return; }
    host.textContent = '';
    for (var i = 0; i < state.cards.length; i++) { host.appendChild(cardEl(state.cards[i])); }
    $('empty').hidden = state.cards.length > 0;
    window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/board.html', state.cards.length ? 'data' : 'empty');
  }

  // --- REGION: Data
  // Header version + host id and the footer bar. stamp() (not markLoaded) records
  // each pass, because the 30 s poll below would otherwise keep resetting the
  // 60 s countdown and it would never reach zero. refreshOnVisible is off -- the
  // board already reloads on that event.
  var chrome = Y.initChrome({
    intervalSeconds: 60, refreshOnVisible: false,
    refresh: function () { load({ quiet: true }); }
  });

  // load({quiet}) distinguishes a read the operator is waiting on -- the first
  // paint, a period switch -- from one they did not ask for. The board's read
  // fans out to every host in the lab and the first one of the day is slow
  // enough to look like a stuck page, so the wait an operator is watching gets
  // the indicator. A poll keeps its numbers on screen and signals in the footer
  // instead: a wall display that blanked every half minute would read as
  // failing rather than as refreshing.
  var loadGeneration = 0;
  function load(opts) {
    var generation = ++loadGeneration;
    var finish = Y.beginPageLoad(chrome, { quiet: !!(opts && opts.quiet), target: document.getElementById('cards'), label: window.YurunaI18n.t("pool.loading_pools"), beforeBusy: function () { $('empty').hidden = true; } });
    return Y.api('/api/board?range=' + encodeURIComponent(state.range), { timeoutMs: 60000 }).then(function (d) {
      if (generation !== loadGeneration) { return; }
      chrome.stamp();
      state.cards = d.cards || [];
      var b = $('stats-banner');
      if (d.statsError) {
        // Only the numbers come from the aggregator. The pools and what each
        // one runs come from the intent store, so the cards still render and
        // the banner says which part is missing.
        b.textContent = window.YurunaI18n.t("pool.board_live_numbers_unavailable", {detail: (Y.bidiIsolate(d.statsError))});
        b.hidden = false;
      } else {
        b.hidden = true;
      }
      render();
    }, function (e) {
      if (generation !== loadGeneration) { return; }
      if (Y.notice) { Y.notice('error', e.message); }
      // A failed poll leaves the cards it could not refresh alone -- they are
      // stale, not wrong, and the footer time says how stale.
      if (!(opts && opts.quiet)) { showLoadError(e.message); }
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/board.html', 'error');
    }).then(finish, finish);
  }

  // This page carries no notice area, so a read that failed says so where the
  // cards would have been. Without it the wait ends in a blank board that looks
  // exactly like the wait did.
  function showLoadError(msg) {
    var host = $('cards');
    host.textContent = '';
    host.appendChild(Y.el('p', {
      class: 'muted load-error',
      text: window.YurunaI18n.t("pool.could_not_load_the_board_value1_retrying_on_the_next_refresh", {value1: (Y.bidiIsolate(msg))})
    }));
  }

  var periodButtons = document.querySelectorAll('.periods button');
  for (var pi = 0; pi < periodButtons.length; pi++) {
    // Wired through a call rather than from the loop body, so each handler
    // closes over ITS button instead of the last one in the list.
    (function (btn) {
      btn.addEventListener('click', function () {
        state.range = btn.getAttribute('data-range');
        remember(RANGE_KEY, state.range);
        markPeriod(btn);
        load();
      });
    }(periodButtons[pi]));
  }

  // Auto-refresh, paused while the tab is hidden so a phone in a pocket is not
  // polling. The endpoint behind this is memoized server-side.
  function startTimer() {
    if (timer) { window.clearInterval(timer); }
    timer = window.setInterval(function () { if (!document.hidden) { load({ quiet: true }); } }, 30000);
  }
  document.addEventListener('visibilitychange', function () { if (!document.hidden) { load({ quiet: true }); } });

  (function init() {
    var all = document.querySelectorAll('.periods button');
    var selected = null;
    for (var i = 0; i < all.length; i++) {
      if (all[i].getAttribute('data-range') === state.range) { selected = all[i]; }
    }
    markPeriod(selected);
    // The board never blocks on the gate: every read it makes is open, and it
    // changes nothing itself.
    $('board').hidden = false;
    load().then(startTimer, startTimer);
  }());
})();
