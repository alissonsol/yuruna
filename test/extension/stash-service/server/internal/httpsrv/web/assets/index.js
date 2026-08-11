// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Recent-stashes list + search. Visibility-aware auto-refresh, so a
// backgrounded tab does not poll. Also the delete surface for a whole page of
// stashes: one button per row, plus a checkbox selection driving a bulk delete.

(function () {
  const PAGE = 50;
  let offset = 0;
  let total = 0;
  const seenHosts = new Set();
  // Every rendered row in display order: { view, tr, pick }, where pick is the
  // row's checkbox or null for a row this host may not delete. The array is the
  // selection model — the checkboxes themselves hold the state, so a row that
  // leaves the table takes its selection with it.
  let rendered = [];
  let deleting = false;
  // The daemon gates delete twice: by which host OWNS the stash (only a local
  // row can go, and the list already says which those are) and by which machine
  // the request comes FROM -- the VM itself or the host IP it was launched with.
  // gate carries the second answer for this browser, which no amount of looking
  // at the rows can reveal, so the page can withhold a control the daemon would
  // refuse instead of letting the operator find out by pressing it.
  const gate = { canDelete: false, clientIp: '' };

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

  function showError(text) { Y.replace($('msg'), Y.el('div', { class: 'notice error', text })); }
  function clearError() { Y.replace($('msg')); }

  function selected() { return rendered.filter((r) => r.pick && r.pick.checked); }

  // syncControls re-derives everything that depends on the selection: the bulk
  // button's enabled state and the header checkbox's three states (none / some /
  // all of the selectable rows). Called after every change to rendered rows or
  // their checkboxes, so no caller has to remember which of them to update.
  function syncControls() {
    const pickable = rendered.filter((r) => r.pick);
    const n = selected().length;
    $('delete-selected').disabled = deleting || n === 0;
    const all = $('pick-all');
    all.disabled = deleting || pickable.length === 0;
    all.checked = pickable.length > 0 && n === pickable.length;
    all.indeterminate = n > 0 && n < pickable.length;
  }

  function renderStatus() {
    $('status').textContent = total + ' stash' + (total === 1 ? '' : 'es') + ' (showing ' + Math.min(offset, total) + ')';
    $('more').style.display = offset < total ? '' : 'none';
  }

  // The delete-source explanation: one line above the table, not a marker per
  // row, because the reason is a fact about this browser and is therefore the
  // same for every row. Rendered only when it changes what the operator sees --
  // there are local rows, and their controls are being withheld.
  function renderDeleteNote() {
    const el = $('delete-note');
    if (!el) return;
    if (gate.canDelete || !rendered.some((r) => r.view.local)) { Y.replace(el); return; }
    Y.replace(el, Y.el('div', {
      class: 'notice warn',
      text: 'Delete is not offered here: this browser reaches the stash service from '
        + (gate.clientIp || 'an address the daemon could not read')
        + ', and only the stash VM itself or the host IP it was launched with may delete. '
        + 'Open this page from that host, or relaunch the daemon with that address as its host IP.',
    }));
  }

  function row(v) {
    const tr = Y.el('tr', { onclick: () => { location.href = v.permalink; } });
    const entry = { view: v, tr, pick: null };
    // Delete is local-host-only (§8.1) and the server refuses a foreign hostId
    // with a 403, so a remote row carries neither control: the only delete
    // affordances on the page are ones the daemon will accept. The same holds
    // for a browser the daemon will not accept a delete FROM -- every local row
    // then renders as a remote one does, with the reason stated once above.
    let del = null;
    if (v.local && gate.canDelete) {
      entry.pick = Y.el('input', { type: 'checkbox', 'aria-label': 'Select stash ' + v.id, onchange: syncControls });
      del = Y.el('button', { class: 'btn destructive compact', onclick: (e) => { e.stopPropagation(); deleteOne(entry, del); } }, 'Delete');
    }
    // The row itself navigates to the permalink, so both controls swallow the
    // click before it bubbles: selecting or deleting must not also open the stash.
    const stop = (e) => e.stopPropagation();
    tr.append(
      Y.el('td', { class: 'pick', onclick: stop }, entry.pick),
      Y.el('td', { text: Y.classIcon(v.contentClass), title: v.mimeType || v.contentClass }),
      Y.el('td', { class: 'mono', text: v.id }),
      Y.el('td', { text: v.originalFilename || '(unnamed)' }),
      Y.el('td', {}, Y.el('span', { class: 'badge ' + (v.local ? 'local' : 'host'), title: v.hostId, text: v.local ? 'this host' : Y.shortHost(v.hostId) })),
      Y.el('td', { text: v.username }),
      Y.el('td', { class: 'num', text: Y.humanSize(v.sizeBytes) }),
      Y.el('td', { text: Y.fmtDate(v.createdAt) }),
      Y.el('td', {}, statusBadge(v.status)),
      Y.el('td', { class: 'row-actions', onclick: stop }, del),
    );
    return entry;
  }

  // dropRow removes a deleted row in place — the per-row Delete deliberately does
  // NOT reload the list, so an operator working down a page keeps their position
  // and the rest of their selection. The counters follow the row out, `offset`
  // included: the server's result window just shrank by one, and leaving offset
  // where it was would make the next "Load more" skip a stash.
  function dropRow(entry) {
    const i = rendered.indexOf(entry);
    if (i >= 0) rendered.splice(i, 1);
    if (entry.tr.parentNode) entry.tr.parentNode.removeChild(entry.tr);
    if (offset > 0) offset--;
    if (total > 0) total--;
    renderStatus();
    syncControls();
  }

  // The button's own disabled flag is the re-entrancy guard for a double-click;
  // `deleting` keeps a row button from racing a bulk run that already owns this
  // row, where the loser would report a puzzling "stash not found".
  async function deleteOne(entry, btn) {
    if (deleting || btn.disabled) return;
    btn.disabled = true;
    try {
      const url = Y.stashApiURL(entry.view);
      if (!url) throw new Error('malformed permalink');
      await Y.api(url, { method: 'DELETE' });
    } catch (e) {
      btn.disabled = false;
      showError('Delete failed for ' + entry.view.id + ': ' + e.message);
      return;
    }
    dropRow(entry);
  }

  async function deleteSelected() {
    const picked = selected();
    if (!picked.length || deleting) return;
    const label = picked.length + ' stash' + (picked.length === 1 ? '' : 'es');
    if (!confirm('Delete ' + label + ' on this host? This cannot be undone.')) return;
    deleting = true;
    syncControls();
    // Sequential, not concurrent: each delete unlinks an artifact + sidecar and
    // writes the local index, and a burst of parallel DELETEs buys nothing
    // against a LAN-local daemon while making a partial failure harder to
    // attribute. Every failure is collected so one refusal cannot hide the rest.
    const failed = [];
    for (const entry of picked) {
      try {
        const url = Y.stashApiURL(entry.view);
        if (!url) throw new Error('malformed permalink');
        await Y.api(url, { method: 'DELETE' });
      } catch (e) {
        failed.push(entry.view.id + ' (' + e.message + ')');
      }
    }
    deleting = false;
    // Unlike the per-row button, a bulk delete reloads the list: enough of the
    // page changed that the server's view is the one worth showing. load() clears
    // #msg, so the failure report goes up after it, not before.
    await load(true);
    if (failed.length) showError(failed.length + ' of ' + picked.length + ' could not be deleted — ' + failed.join('; '));
  }

  async function load(reset) {
    if (reset) { offset = 0; rendered = []; Y.replace($('rows')); clearError(); }
    $('status').textContent = 'Loading…';
    // Before the rows, never after: row() reads the gate as it builds each one,
    // and the read is memoized, so this costs one request for the page's life.
    const info = await Y.hostInfo();
    gate.canDelete = !!info.canDelete;
    gate.clientIp = info.clientIp || '';
    try {
      const data = await Y.api('/api/stashes?' + filterQuery());
      total = data.total;
      for (const v of data.stashes) {
        const entry = row(v);
        rendered.push(entry);
        $('rows').append(entry.tr);
        if (v.hostId && !seenHosts.has(v.hostId)) {
          seenHosts.add(v.hostId);
          if (!v.local) $('host').append(Y.el('option', { value: v.hostId, text: Y.shortHost(v.hostId) }));
        }
      }
      offset += data.stashes.length;
      renderStatus();
      footer.markLoaded();
    } catch (e) {
      $('status').textContent = 'Error: ' + e.message;
    }
    renderDeleteNote();
    syncControls();
  }

  let timer = null;
  function debounced() { clearTimeout(timer); timer = setTimeout(() => load(true), 250); }

  $('q').addEventListener('input', debounced);
  $('class').addEventListener('change', () => load(true));
  $('host').addEventListener('change', () => load(true));
  $('more').addEventListener('click', () => load(false));
  // "All" spans every row on screen, the ones a "Load more" appended included --
  // it is a select-all-visible, not a select-all-matching-the-query.
  $('pick-all').addEventListener('change', () => {
    const on = $('pick-all').checked;
    for (const r of rendered) { if (r.pick) r.pick.checked = on; }
    syncControls();
  });
  $('delete-selected').addEventListener('click', deleteSelected);
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
    // A refresh re-renders every row, which would silently discard a selection
    // the operator is still assembling; park the countdown until it is acted on
    // or cleared.
    paused: () => deleting || selected().length > 0,
    refresh: () => { if (offset <= PAGE && !$('q').value) load(true); },
  });

  load(true);
})();
