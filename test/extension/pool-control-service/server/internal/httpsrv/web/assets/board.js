// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// Operator board. Every value here comes from an operator or a project repo, so
// nothing is ever written with innerHTML -- Y.el sets textContent.
(function () {
  const RANGE_KEY = 'yuruna.board.range';
  let state = { range: localStorage.getItem(RANGE_KEY) || '24h', cards: [], offers: [] };
  let pending = null;   // the assignment awaiting confirmation
  let timer = null;

  const $ = (id) => document.getElementById(id);

  // --- rendering -----------------------------------------------------------

  // Thresholds mirror the Grafana tile exactly: red below 95, amber below 100,
  // green only at a clean 100.
  function heroClass(pct) {
    if (pct === null || pct === undefined) return 'none';
    if (pct >= 100) return 'good';
    if (pct >= 95) return 'warn';
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
    const kids = [
      Y.el('h2', { text: c.displayName }),
      Y.el('p', { class: 'hosts', text: c.hostsTotal + (c.hostsTotal === 1 ? ' host' : ' hosts') + ' · ' + c.hostsReporting + ' reporting' }),
      Y.el('div', { class: 'hero ' + heroClass(c.successPct) }, [
        Y.el('span', { class: 'pct', text: fmtPct(c.successPct) }),
        Y.el('span', { class: 'lbl', text: 'success' })
      ]),
      Y.el('div', { class: 'counts' }, [
        Y.el('div', {}, [Y.el('span', { class: 'n', text: String(c.total) }), Y.el('span', { class: 'k', text: 'cycles' })]),
        Y.el('div', {}, [Y.el('span', { class: 'n', text: String(c.failed) }), Y.el('span', { class: 'k', text: 'failed' })])
      ])
    ];

    const assigned = Y.el('p', { class: 'assigned' });
    assigned.appendChild(document.createTextNode('Running: '));
    if (c.testSet) {
      assigned.appendChild(Y.el('strong', { text: c.testSetLabel || c.testSet }));
    } else {
      assigned.appendChild(Y.el('span', { class: 'none', text: 'the hosts’ own projects' }));
    }
    kids.push(assigned);

    if (c.assignAllowed) {
      const sel = Y.el('select', { 'aria-label': 'Test set for ' + c.displayName });
      sel.appendChild(Y.el('option', { value: '', text: 'Change test set…' }));
      for (const o of state.offers) {
        const opt = Y.el('option', { value: o.name, text: offerLabel(o) });
        if (o.name === c.testSet) opt.selected = true;
        sel.appendChild(opt);
      }
      sel.addEventListener('change', () => {
        const chosen = state.offers.find((o) => o.name === sel.value);
        if (!chosen) return;
        askConfirm(c, chosen, sel);
      });
      kids.push(sel);
    } else {
      kids.push(Y.el('p', { class: 'locked', text: c.reason }));
    }

    if (c.blocked && c.blocked.length) {
      kids.push(Y.el('p', {
        class: 'blocked',
        text: c.blocked.length + (c.blocked.length === 1 ? ' host cannot' : ' hosts cannot')
              + ' read the assigned project. Grant its token access, or assign a different test set.'
      }));
    }
    return Y.el('section', { class: 'card' }, kids);
  }

  function render() {
    const host = $('cards');
    host.textContent = '';
    for (const c of state.cards) host.appendChild(cardEl(c));
    $('empty').hidden = state.cards.length > 0;
  }

  // --- confirmation --------------------------------------------------------

  // The failure mode is a mis-tap, so name the blast radius before writing.
  function askConfirm(card, offer, selectEl) {
    pending = { card: card, offer: offer, selectEl: selectEl };
    $('confirm-title').textContent = 'Assign “' + offerLabel(offer) + '” to ' + card.displayName + '?';
    const n = card.hostsTotal;
    $('confirm-body').textContent =
      n + (n === 1 ? ' host will switch to ' : ' hosts will switch to ') +
      (offer.projectUrl || 'the assigned project') + ' on their next cycle.';
    $('confirm').hidden = false;
  }

  function closeConfirm(restore) {
    if (restore && pending && pending.selectEl) {
      pending.selectEl.value = pending.card.testSet || '';
    }
    pending = null;
    $('confirm').hidden = true;
  }

  $('confirm-cancel').addEventListener('click', () => closeConfirm(true));
  $('confirm-ok').addEventListener('click', async () => {
    if (!pending) return;
    $('confirm').hidden = true;
    await assignPending();
  });

  // assignPending sends the confirmed assignment through Y.mutate, so a gate
  // refusal prompts for the Lab token and re-sends this same assignment rather
  // than losing the selection. A real failure puts the picker back where it was,
  // so the UI never claims an assignment that did not happen.
  async function assignPending() {
    const { card, offer } = pending;
    try {
      await Y.mutate('/api/pool/testset', {
        method: 'POST',
        body: {
          poolId: card.poolId, name: offer.name,
          frameworkUrl: offer.frameworkUrl, projectUrl: offer.projectUrl
        }
      });
      pending = null;
      await load();
    } catch (e) {
      closeConfirm(true);
      alert('Could not assign: ' + e.message);
    }
  }

  // --- data ----------------------------------------------------------------

  // Header version + host id and the footer bar. stamp() (not markLoaded) records
  // each pass, because the 30 s poll below would otherwise keep resetting the
  // 60 s countdown and it would never reach zero. refreshOnVisible is off -- the
  // board already reloads on that event.
  const chrome = Y.initChrome({ intervalSeconds: 60, refresh: load, refreshOnVisible: false });

  async function load() {
    try {
      const d = await Y.api('/api/board?range=' + encodeURIComponent(state.range));
      chrome.stamp();
      state.cards = d.cards || [];
      state.offers = d.offers || [];
      const b = $('stats-banner');
      if (d.statsError) {
        // Numbers grey out; assignment still works, because it goes through the
        // intent CLIs and never touches the aggregator.
        b.textContent = 'Live numbers unavailable (' + d.statsError + '). Assigning still works.';
        b.hidden = false;
      } else {
        b.hidden = true;
      }
      render();
    } catch (e) {
      Y.notice && Y.notice('error', e.message);
    }
  }

  for (const btn of document.querySelectorAll('.periods button')) {
    btn.addEventListener('click', () => {
      state.range = btn.getAttribute('data-range');
      localStorage.setItem(RANGE_KEY, state.range);
      for (const b of document.querySelectorAll('.periods button')) b.classList.toggle('on', b === btn);
      load();
    });
  }

  // Auto-refresh, paused while the tab is hidden so a phone in a pocket is not
  // polling. The endpoint behind this is memoized server-side.
  function startTimer() {
    if (timer) clearInterval(timer);
    timer = setInterval(() => { if (!document.hidden) load(); }, 30000);
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) load(); });

  (async function init() {
    for (const b of document.querySelectorAll('.periods button')) {
      b.classList.toggle('on', b.getAttribute('data-range') === state.range);
    }
    // The board never blocks on the gate: it renders for anyone on the LAN and
    // asks for the Lab token at the moment a change is attempted.
    $('board').hidden = false;
    await load();
    startTimer();
  })();
})();
