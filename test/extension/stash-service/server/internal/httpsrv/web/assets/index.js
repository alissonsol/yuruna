// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Recent-stashes list + search. Visibility-aware auto-refresh, so a
// backgrounded tab does not poll. Also the delete surface for a whole page of
// stashes: one button per row, plus a checkbox selection driving a bulk delete.

(function () {
  const PAGE = 50;
  let offset = 0;
  let total = 0;
  // Sortable columns in table order. `desc` is the direction a FIRST click
  // applies: a quantity is most useful biggest-or-newest first, a name or an id
  // is most useful from the top of the alphabet. A second click on the same
  // column reverses whatever it is showing.
  //
  // Sorting reloads rather than reordering the rows on screen, because the list
  // is paged: the daemon holds the whole matching set and this browser holds one
  // page of it, so only the daemon can answer "the largest" without qualifying
  // it as "the largest of the fifty you happen to have".
  const SORTS = [
    { key: 'type', desc: false },
    { key: 'id', desc: false },
    { key: 'name', desc: false },
    { key: 'host', desc: false },
    { key: 'user', desc: false },
    { key: 'size', desc: true },
    { key: 'created', desc: true },
    { key: 'status', desc: false },
  ];
  // The default the daemon also falls back to, so the first render agrees with
  // the markup's initial aria-sort without a round trip to find out.
  let sortCol = 'created';
  let sortAsc = false;
  const seenHosts = new Set();
  // Every rendered row in display order: { view, tr, pick }, where pick is the
  // row's checkbox, or null while the page is locked. The array is the
  // selection model -- the checkboxes themselves hold the state, so a row that
  // leaves the table takes its selection with it.
  let rendered = [];
  let deleting = false;
  // Whether this browser is through the delete gate. Nothing about a row can
  // reveal it -- it is a fact about a credential this device holds -- so the
  // page asks, and withholds the controls the daemon would refuse rather than
  // letting the operator find out by pressing one. Rows from OTHER hosts are
  // deletable too: the daemon reaches every host's folder on the stash share.
  const gate = { canDelete: false, labToken: false };

  const $ = (id) => document.getElementById(id);

  function filterQuery() {
    const p = new URLSearchParams();
    const q = $('q').value.trim();
    const cls = $('class').value;
    const host = $('host').value;
    if (q) p.set('q', q);
    if (cls) p.set('class', cls);
    if (host) p.set('host', host);
    p.set('sort', sortCol);
    p.set('dir', sortAsc ? 'asc' : 'desc');
    p.set('limit', String(PAGE));
    p.set('offset', String(offset));
    return p.toString();
  }

  // renderSortHeaders marks the active column on the header cells. aria-sort is
  // the whole of it: the caret is a CSS rule keyed on that attribute, so the
  // indicator a sighted operator sees and the one a screen reader announces can
  // never disagree.
  function renderSortHeaders() {
    for (const c of SORTS) {
      const th = $('th-' + c.key);
      if (!th) continue;
      th.setAttribute('aria-sort', c.key !== sortCol ? 'none' : (sortAsc ? 'ascending' : 'descending'));
    }
  }

  // A click on the active column reverses it; a click on any other adopts that
  // column's natural first direction. Sorting starts the list again from the
  // top -- an offset counts into an order, so it means nothing once the order
  // changes underneath it.
  function sortBy(c) {
    if (deleting) return;
    if (sortCol === c.key) sortAsc = !sortAsc;
    else { sortCol = c.key; sortAsc = !c.desc; }
    renderSortHeaders();
    load(true);
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

  // Why the delete controls are absent: one line above the table, not a marker
  // per row, because the reason is a fact about this browser and is therefore
  // the same for every row. Rendered only when it changes what the operator
  // sees -- there are rows on screen, and their controls are being withheld.
  function renderDeleteNote() {
    const el = $('delete-note');
    if (!el) return;
    if (gate.canDelete || !rendered.length) { Y.replace(el); return; }
    Y.replace(el, Y.el('div', {
      class: 'notice warn',
      text: gate.labToken
        ? 'Delete is locked. Unlock actions with the Lab token above, or open this page from the Yuruna hosts dashboard, which unlocks it for you.'
        : 'Delete is unavailable: this service has no pool aggregator configured, so no Lab token or dashboard link can be checked.',
    }));
  }

  function row(v) {
    const tr = Y.el('tr', { onclick: () => { location.href = v.permalink; } });
    const entry = { view: v, tr, pick: null };
    // Every row is deletable once this browser is through the gate, whichever
    // host owns it: the daemon writes to the whole stash share, so a peer's
    // stash goes the same way as one of this host's. A locked browser gets no
    // control at all, with the reason stated once above the table.
    let del = null;
    if (gate.canDelete) {
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
      Y.el('td', {}, Y.el('span', { class: 'badge ' + (v.local ? 'local' : 'host'), title: Y.guid(v.hostId), text: v.local ? 'this host' : Y.shortHost(v.hostId) })),
      Y.el('td', { text: v.username }),
      Y.el('td', { class: 'num', text: Y.humanSize(v.sizeBytes) }),
      Y.el('td', { text: Y.fmtDate(v.createdAt) }),
      Y.el('td', {}, statusBadge(v.status)),
      Y.el('td', { class: 'row-actions', onclick: stop }, del),
    );
    return entry;
  }

  // dropRow removes a deleted row in place -- the per-row Delete deliberately does
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
    // Blocked like the bulk run, and for the same reason: from the moment the
    // request leaves, this row's Download and its permalink are promises the
    // page can no longer keep. One unlink usually beats the grace period, so
    // the barrier is invisible in the common case and only shows itself when
    // the share is slow enough for the question to arise.
    const done = Y.block('Deleting...');
    try {
      const url = Y.stashApiURL(entry.view);
      if (!url) throw new Error('malformed permalink');
      await Y.api(url, { method: 'DELETE' });
      dropRow(entry);
    } catch (e) {
      btn.disabled = false;
      showError('Delete failed for ' + entry.view.id + ': ' + e.message);
    } finally {
      done();
    }
  }

  async function deleteSelected() {
    const picked = selected();
    if (!picked.length || deleting) return;
    const label = picked.length + ' stash' + (picked.length === 1 ? '' : 'es');
    if (!confirm('Delete ' + label + '? This cannot be undone.')) return;
    // A row whose permalink could not be parsed is dropped here rather than
    // guessed at: the request must name exactly the stashes the operator picked.
    const keys = [];
    const unaddressable = [];
    for (const entry of picked) {
      const key = Y.stashKey(entry.view);
      if (key) keys.push(key); else unaddressable.push(entry.view.id);
    }
    deleting = true;
    syncControls();
    // The page is refused for the whole operation, not just the request: from
    // the confirmation until the fresh list is on screen, every row shown is one
    // the daemon may already have unlinked. Downloading one, or opening its
    // permalink, would fail in a way that looks like the page's fault -- so
    // there is nothing to press until the page can be trusted again.
    const done = Y.block('Deleting...');
    // One request for the whole selection, not one per row: the operator made a
    // single decision, and the daemon records and answers it as one. The
    // per-stash verdicts come back together, so a refusal in the middle cannot
    // hide the deletes that worked.
    let failed = unaddressable.map((id) => id + ' (malformed permalink)');
    try {
      if (keys.length) {
        const res = await Y.api('/api/stashes/delete', {
          method: 'POST',
          body: JSON.stringify({ stashes: keys }),
          headers: { 'Content-Type': 'application/json' },
        });
        for (const r of (res.results || [])) {
          if (!r.ok) failed.push(r.id + ' (' + (r.error || 'refused') + ')');
        }
      }
    } catch (e) {
      failed = failed.concat(keys.map((k) => k.id + ' (' + e.message + ')'));
    }
    // The reload is unconditional. A request that failed mid-flight may still
    // have deleted part of the selection, so the rows on screen are no more
    // trustworthy after a failure than after a success -- and the server's view
    // is the only one worth showing either way. `deleting` is cleared first so
    // the reloaded page renders its controls in their normal state; load()
    // clears #msg, so the failure report goes up after it, not before.
    deleting = false;
    try {
      await load(true);
    } finally {
      done();
    }
    if (failed.length) showError(failed.length + ' of ' + picked.length + ' could not be deleted -- ' + failed.join('; '));
  }

  async function load(reset) {
    if (reset) { offset = 0; rendered = []; Y.replace($('rows')); clearError(); }
    $('status').textContent = 'Loading...';
    // Before the rows, never after: row() reads the gate as it builds each one.
    // This also spends a control proof carried in from the dashboard, so a
    // browser that arrived by that link renders its first page already unlocked.
    const sess = await Y.initUnlock(() => load(true));
    gate.canDelete = sess.authed;
    gate.labToken = sess.labToken;
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
  for (const c of SORTS) {
    const btn = $('sort-' + c.key);
    if (btn) btn.addEventListener('click', () => sortBy(c));
  }
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
  // the first page -- but only when not searching or paginated (section 4.1), so it
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

  renderSortHeaders();
  load(true);
})();
