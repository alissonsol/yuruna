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

  var state = { range: remembered(RANGE_KEY, '24h'), cards: [], offers: [] };
  var pending = null;   // the assignment awaiting confirmation
  var timer = null;

  function $(id) { return document.getElementById(id); }
  function t(key, args) { return window.YurunaI18n.t(key, args || null); }

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

  function offerLabel(o) {
    return o.displayName || o.name;
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

    var assigned = Y.el('p', { class: 'assigned' });
    assigned.appendChild(document.createTextNode(window.YurunaI18n.t("pool.running")));
    if (c.testSet) {
      assigned.appendChild(Y.el('strong', { text: Y.bidiIsolate(c.testSetLabel || c.testSet) }));
    } else {
      assigned.appendChild(Y.el('span', { class: 'none', text: window.YurunaI18n.t("pool.the_hosts_own_projects") }));
    }
    kids.push(assigned);

    if (c.assignAllowed) {
      var sel = Y.el('select', {
        'aria-label': t('pool.test_set_label', { name: Y.bidiIsolate(c.displayName) })
      });
      sel.appendChild(Y.el('option', { value: '', text: window.YurunaI18n.t("pool.change_test_set") }));
      for (var i = 0; i < state.offers.length; i++) {
        var o = state.offers[i];
        var opt = Y.el('option', { value: o.name, text: offerLabel(o) });
        if (o.name === c.testSet) { opt.selected = true; }
        sel.appendChild(opt);
      }
      Y.onSelectCommit(sel, function () {
        var chosen = null;
        for (var j = 0; j < state.offers.length; j++) {
          if (state.offers[j].name === sel.value) { chosen = state.offers[j]; break; }
        }
        if (!chosen) { return; }
        askConfirm(c, chosen, sel);
      });
      kids.push(sel);
    } else {
      kids.push(Y.el('p', { class: 'locked', text: c.assignDisabledDetail }));
    }

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

  // --- REGION: Confirmation
  // The failure mode is a mis-tap, so name the blast radius before writing.
  // Where focus was when the sheet opened, so it can go back there. The sheet
  // markup is already correct (role=dialog, aria-modal, aria-labelledby); what
  // was missing was every behavior behind it. aria-modal="true" in particular
  // asks assistive tech to ignore everything OUTSIDE the dialog -- so leaving
  // focus on the <select> that opened it put the user's focus point inside the
  // part of the tree the screen reader had just been told to suppress, and
  // nothing was announced at all.
  var confirmOpener = null;

  function trapConfirmKeys(ev) {
    var k = Y.key(ev);
    if (k === 'Escape') { ev.preventDefault(); closeConfirm(true); return; }
    if (k !== 'Tab') { return; }
    var box = $('confirm').querySelector('.sheet-box');
    var stops = box.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])');
    if (!stops.length) { return; }
    var first = stops[0], last = stops[stops.length - 1];
    if (ev.shiftKey && document.activeElement === first) { ev.preventDefault(); last.focus(); }
    else if (!ev.shiftKey && document.activeElement === last) { ev.preventDefault(); first.focus(); }
  }

  function askConfirm(card, offer, selectEl) {
    pending = { card: card, offer: offer, selectEl: selectEl };
    $('confirm-title').textContent = window.YurunaI18n.t("pool.assign_value1_to_value2", {value1: (Y.bidiIsolate(offerLabel(offer))), value2: (Y.bidiIsolate(card.displayName))});
    var n = card.hostsTotal;
    $('confirm-body').textContent =
      (offer.projectUrl ? window.YurunaI18n.t('pool.hosts_switch_project', {count: n, project: Y.bidiIsolate(offer.projectUrl)}) : window.YurunaI18n.t('pool.hosts_switch_assigned', {count: n}));
    confirmOpener = document.activeElement;
    $('confirm').hidden = false;
    // Cancel, not Assign: the sheet guards a change the user has not committed
    // to, so the safe option is the one under the finger.
    $('confirm-cancel').focus();
    document.addEventListener('keydown', trapConfirmKeys, true);
  }

  function closeConfirm(restore) {
    if (restore && pending && pending.selectEl) {
      pending.selectEl.value = pending.card.testSet || '';
    }
    pending = null;
    $('confirm').hidden = true;
    document.removeEventListener('keydown', trapConfirmKeys, true);
    // Back to the control that opened it. Without this the focused button is
    // hidden underneath the user and focus falls to <body>. parentNode rather
    // than Node.isConnected, which the browser baseline does not carry.
    if (confirmOpener && confirmOpener.parentNode && confirmOpener.focus) { confirmOpener.focus(); }
    confirmOpener = null;
  }

  $('confirm-cancel').addEventListener('click', function () { closeConfirm(true); });
  $('confirm-ok').addEventListener('click', function () {
    if (!pending) { return; }
    $('confirm').hidden = true;
    assignPending();
  });

  // assignPending sends the confirmed assignment through Y.mutate, so a gate
  // refusal prompts for the Lab token and re-sends this same assignment rather
  // than losing the selection. A real failure puts the picker back where it was,
  // so the UI never claims an assignment that did not happen.
  function assignPending() {
    var card = pending.card;
    var offer = pending.offer;
    return Y.mutate('/api/pool/testset', {
      method: 'POST',
      body: {
        poolId: card.poolId, name: offer.name,
        frameworkUrl: offer.frameworkUrl, projectUrl: offer.projectUrl
      }
    }).then(function () {
      pending = null;
      return load();
    }, function (e) {
      closeConfirm(true);
      window.alert(window.YurunaI18n.t("pool.could_not_assign_value1", {value1: (Y.bidiIsolate(e.message))}));
    });
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
  function load(opts) {
    window.YurunaFirstUsable.hold('primary');
    var quiet = !!(opts && opts.quiet);
    var done = function () { };
    if (!quiet) {
      // The empty-state line is an ANSWER ("no pools yet"), so it must not sit
      // under the indicator claiming one before the read has landed.
      $('empty').hidden = true;
      done = Y.busy($('cards'), window.YurunaI18n.t("pool.loading_pools"));
    }
    chrome.busy(true);
    var finish = function () { done(); chrome.busy(false); window.YurunaFirstUsable.release('primary'); };
    return Y.api('/api/board?range=' + encodeURIComponent(state.range)).then(function (d) {
      chrome.stamp();
      state.cards = d.cards || [];
      state.offers = d.offers || [];
      var b = $('stats-banner');
      if (d.statsError) {
        // Numbers gray out; assignment still works, because it goes through the
        // intent CLIs and never touches the aggregator.
        b.textContent = window.YurunaI18n.t("pool.live_numbers_unavailable_value1_assigning_still_works", {value1: (Y.bidiIsolate(d.statsError))});
        b.hidden = false;
      } else {
        b.hidden = true;
      }
      render();
    }, function (e) {
      if (Y.notice) { Y.notice('error', e.message); }
      // A failed poll leaves the cards it could not refresh alone -- they are
      // stale, not wrong, and the footer time says how stale.
      if (!quiet) { showLoadError(e.message); }
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
    // The board never blocks on the gate: it renders for anyone on the LAN and
    // asks for the Lab token at the moment a change is attempted.
    $('board').hidden = false;
    load().then(startTimer, startTimer);
  }());
})();
