// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Recent-stashes list + search. Visibility-aware auto-refresh, so a
// backgrounded tab does not poll. Also the delete surface for a whole page of
// stashes: one button per row, plus a checkbox selection driving a bulk delete.

(function () {
  var PAGE = 50;
  var offset = 0;
  var total = 0;
  // Sortable columns in table order. `desc` is the direction a FIRST click
  // applies: a quantity is most useful biggest-or-newest first, a name or an id
  // is most useful from the top of the alphabet. A second click on the same
  // column reverses whatever it is showing.
  //
  // Sorting reloads rather than reordering the rows on screen, because the list
  // is paged: the daemon holds the whole matching set and this browser holds one
  // page of it, so only the daemon can answer "the largest" without qualifying
  // it as "the largest of the fifty you happen to have".
  var SORTS = [
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
  var sortCol = 'created';
  var sortAsc = false;
  // A plain object, not a Set: this is a membership check on host id strings,
  // and an object literal is the form the browser baseline carries everywhere.
  var seenHosts = {};
  // Every rendered row in display order: { view, tr, pick }, where pick is the
  // row's checkbox, or null while the page is locked. The array is the
  // selection model -- the checkboxes themselves hold the state, so a row that
  // leaves the table takes its selection with it.
  var rendered = [];
  var deleting = false;
  // Whether this browser is through the delete gate. Nothing about a row can
  // reveal it -- it is a fact about a credential this device holds -- so the
  // page asks, and withholds the controls the daemon would refuse rather than
  // letting the operator find out by pressing one. Rows from OTHER hosts are
  // deletable too: the daemon reaches every host's folder on the stash share.
  var gate = { canDelete: false, labToken: false };

  function $(id) { return document.getElementById(id); }

  // Built by hand rather than with URLSearchParams, which the browser baseline
  // does not carry. encodeURIComponent is the same escaping the class applies,
  // and every value here reaches the daemon as a query field.
  function filterQuery() {
    var parts = [];
    var add = function (k, v) { parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v)); };
    var q = $('q').value.trim();
    var cls = $('class').value;
    var host = $('host').value;
    if (q) { add(window.YurunaI18n.t("stash.q"), q); }
    if (cls) { add(window.YurunaI18n.t("stash.class"), cls); }
    if (host) { add(window.YurunaI18n.t("stash.host_4740ae63"), host); }
    add(window.YurunaI18n.t("stash.sort"), sortCol);
    add(window.YurunaI18n.t("stash.dir"), sortAsc ? 'asc' : 'desc');
    add(window.YurunaI18n.t("stash.limit"), String(PAGE));
    add(window.YurunaI18n.t("stash.offset"), String(offset));
    return parts.join('&');
  }

  // renderSortHeaders marks the active column on the header cells. aria-sort is
  // the whole of it: the caret is a CSS rule keyed on that attribute, so the
  // indicator a sighted operator sees and the one a screen reader announces can
  // never disagree.
  function renderSortHeaders() {
    for (var i = 0; i < SORTS.length; i++) {
      var c = SORTS[i];
      var th = $('th-' + c.key);
      if (!th) { continue; }
      th.setAttribute('aria-sort', c.key !== sortCol ? 'none' : (sortAsc ? 'ascending' : 'descending'));
    }
  }

  // A click on the active column reverses it; a click on any other adopts that
  // column's natural first direction. Sorting starts the list again from the
  // top -- an offset counts into an order, so it means nothing once the order
  // changes underneath it.
  function sortBy(c) {
    if (deleting) { return; }
    if (sortCol === c.key) { sortAsc = !sortAsc; }
    else { sortCol = c.key; sortAsc = !c.desc; }
    renderSortHeaders();
    load(true);
  }

  function statusBadge(s) {
    return Y.el('span', { class: 'badge ' + s, text: Y.displayState(s) });
  }

  function showError(text) { Y.replace($('msg'), Y.el('div', { class: 'notice error', text: text })); }
  function clearError() { Y.replace($('msg')); }

  function selected() { return rendered.filter(function (r) { return r.pick && r.pick.checked; }); }

  // syncControls re-derives everything that depends on the selection: the bulk
  // button's enabled state and the header checkbox's three states (none / some /
  // all of the selectable rows). Called after every change to rendered rows or
  // their checkboxes, so no caller has to remember which of them to update.
  function syncControls() {
    var pickable = rendered.filter(function (r) { return r.pick; });
    var n = selected().length;
    $('delete-selected').disabled = deleting || n === 0;
    var all = $('pick-all');
    all.disabled = deleting || pickable.length === 0;
    all.checked = pickable.length > 0 && n === pickable.length;
    all.indeterminate = n > 0 && n < pickable.length;
  }

  function renderStatus() {
    $('status').textContent = (window.YurunaI18n.t('stash.listed_count', {count: total, shown: Math.min(offset, total)}));
    $('more').style.display = offset < total ? '' : 'none';
  }

  // Why the delete controls are absent: one line above the table, not a marker
  // per row, because the reason is a fact about this browser and is therefore
  // the same for every row. Rendered only when it changes what the operator
  // sees -- there are rows on screen, and their controls are being withheld.
  function renderDeleteNote() {
    var el = $('delete-note');
    if (!el) { return; }
    if (gate.canDelete || !rendered.length) { Y.replace(el); return; }
    Y.replace(el, Y.el('div', {
      class: 'notice warn',
      text: gate.labToken ? window.YurunaI18n.t("stash.delete_is_locked_unlock_actions_with_the_lab_token_above_or_open_") : window.YurunaI18n.t("stash.delete_is_unavailable_this_service_has_no_pool_aggregator_configu"),
    }));
  }

  function row(v) {
    var tr = Y.el('tr', { onclick: function () { window.location.href = v.permalink; } });
    var entry = { view: v, tr: tr, pick: null };
    // Every row is deletable once this browser is through the gate, whichever
    // host owns it: the daemon writes to the whole stash share, so a peer's
    // stash goes the same way as one of this host's. A locked browser gets no
    // control at all, with the reason stated once above the table.
    var del = null;
    if (gate.canDelete) {
      entry.pick = Y.el('input', { type: 'checkbox', 'aria-label': window.YurunaI18n.t("stash.select_stash_value1", {value1: (v.id)}), onchange: syncControls });
      del = Y.el('button', {
        class: 'btn destructive compact',
        'aria-label': window.YurunaI18n.t("stash.delete_stash_value1", {value1: (v.id)}),
        onclick: function (e) { e.stopPropagation(); deleteOne(entry, del); }
      }, window.YurunaI18n.t("stash.delete"));
    }
    // The row itself navigates to the permalink, so the controls inside it
    // swallow the click before it bubbles: selecting, deleting, or following
    // the id link must not also re-trigger the row's own navigation.
    var stop = function (e) { e.stopPropagation(); };
    Y.append(tr,
      Y.el('td', { class: 'pick', onclick: stop }, entry.pick),
      Y.el('td', { text: Y.classIcon(v.contentClass), title: v.mimeType || v.contentClass }),
      // The row-level click below is a pointer convenience. This anchor is the
      // route everything else uses: Tab reaches it, Enter follows it, and a
      // screen reader announces the row as actionable at all. Without it the
      // list is readable and no stash can be opened.
      Y.el('td', { class: 'mono' }, Y.el('a', { href: v.permalink, text: v.id, onclick: stop })),
      Y.el('td', { text: v.originalFilename || window.YurunaI18n.t("stash.unnamed") }),
      Y.el('td', {}, Y.el('span', { class: 'badge ' + (v.local ? 'local' : 'host'), title: Y.guid(v.hostId), text: v.local ? window.YurunaI18n.t("stash.this_host") : Y.shortHost(v.hostId) })),
      Y.el('td', { text: v.username }),
      Y.el('td', { class: 'num', text: Y.humanSize(v.sizeBytes) }),
      Y.el('td', { text: Y.fmtDate(v.createdAt) }),
      Y.el('td', {}, statusBadge(v.status)),
      Y.el('td', { class: 'row-actions', onclick: stop }, del));
    return entry;
  }

  // dropRow removes a deleted row in place -- the per-row Delete deliberately does
  // NOT reload the list, so an operator working down a page keeps their position
  // and the rest of their selection. The counters follow the row out, `offset`
  // included: the server's result window just shrank by one, and leaving offset
  // where it was would make the next "Load more" skip a stash.
  function dropRow(entry) {
    var i = rendered.indexOf(entry);
    if (i >= 0) { rendered.splice(i, 1); }
    // Removing the row that holds focus drops focus to <body>, and an operator
    // working down a list with the keyboard loses their place entirely. Pick
    // the next place to stand BEFORE the row goes: the following row's Delete,
    // or the row above it when this was the last one. Y.block's own restore
    // cannot help here -- the element it saved is the button inside this row,
    // which is about to leave the document.
    var focusWasInRow = entry.tr.contains(document.activeElement);
    var next = null;
    if (focusWasInRow) {
      var after = rendered[i] || rendered[i - 1] || null;
      next = after ? (after.tr.querySelector('button, a[href], input') || after.tr) : null;
    }
    Y.detach(entry.tr);
    if (offset > 0) { offset--; }
    if (total > 0) { total--; }
    renderStatus();
    syncControls();
    if (focusWasInRow) {
      // Fall back to the list heading rather than <body> when the list is now
      // empty; it is given tabindex="-1" so it can take programmatic focus
      // without becoming a tab stop of its own.
      var target = next || document.getElementById('status');
      if (target) {
        if (target.tabIndex < 0 && !target.hasAttribute('tabindex')) { target.setAttribute('tabindex', '-1'); }
        target.focus();
      }
    }
  }

  // The button's own disabled flag is the re-entrancy guard for a double-click;
  // `deleting` keeps a row button from racing a bulk run that already owns this
  // row, where the loser would report a puzzling "stash not found".
  function deleteOne(entry, btn) {
    if (deleting || btn.disabled) { return Promise.resolve(); }
    // The bulk path below and the detail page both confirm, in these words --
    // the per-row Delete is the easiest of the three to hit by accident.
    var what = entry.view.originalFilename ? (entry.view.id + ' (' + entry.view.originalFilename + ')') : entry.view.id;
    if (!window.confirm(window.YurunaI18n.t("stash.delete_stash_value1_this_cannot_be_undone", {value1: (what)}))) { return Promise.resolve(); }
    btn.disabled = true;
    // Blocked like the bulk run, and for the same reason: from the moment the
    // request leaves, this row's Download and its permalink are promises the
    // page can no longer keep. One unlink usually beats the grace period, so
    // the barrier is invisible in the common case and only shows itself when
    // the share is slow enough for the question to arise.
    var done = Y.block(window.YurunaI18n.t("stash.deleting"));
    return Promise.resolve().then(function () {
      var url = Y.stashApiURL(entry.view);
      if (!url) { throw new Error('malformed permalink'); }
      return Y.api(url, { method: 'DELETE' });
    }).then(function () {
      dropRow(entry);
    }, function (e) {
      btn.disabled = false;
      showError(window.YurunaI18n.t("stash.delete_failed_for_value1_value2", {value1: (entry.view.id), value2: (e.message)}));
    }).then(done, done);
  }

  function deleteSelected() {
    var picked = selected();
    if (!picked.length || deleting) { return Promise.resolve(); }
    var label = (window.YurunaI18n.t('stash.selection_count', {count: picked.length}));
    if (!window.confirm(window.YurunaI18n.t("stash.delete_value1_this_cannot_be_undone", {value1: (label)}))) { return Promise.resolve(); }
    // A row whose permalink could not be parsed is dropped here rather than
    // guessed at: the request must name exactly the stashes the operator picked.
    var keys = [];
    var unaddressable = [];
    for (var i = 0; i < picked.length; i++) {
      var key = Y.stashKey(picked[i].view);
      if (key) { keys.push(key); } else { unaddressable.push(picked[i].view.id); }
    }
    deleting = true;
    syncControls();
    // The page is refused for the whole operation, not just the request: from
    // the confirmation until the fresh list is on screen, every row shown is one
    // the daemon may already have unlinked. Downloading one, or opening its
    // permalink, would fail in a way that looks like the page's fault -- so
    // there is nothing to press until the page can be trusted again.
    var done = Y.block(window.YurunaI18n.t("stash.deleting"));
    // One request for the whole selection, not one per row: the operator made a
    // single decision, and the daemon records and answers it as one. The
    // per-stash verdicts come back together, so a refusal in the middle cannot
    // hide the deletes that worked.
    var failed = unaddressable.map(function (id) { return window.YurunaI18n.t("stash.value1_malformed_permalink", {value1: (id)}); });
    var send = keys.length
      ? Y.api('/api/stashes/delete', { method: 'POST', body: { stashes: keys } }).then(function (res) {
        var results = res.results || [];
        for (var j = 0; j < results.length; j++) {
          if (!results[j].ok) { failed.push(results[j].id + ' (' + (results[j].error || 'refused') + ')'); }
        }
      }, function (e) {
        failed = failed.concat(keys.map(function (k) { return k.id + ' (' + e.message + ')'; }));
      })
      : Promise.resolve();

    return send.then(function () {
      // The reload is unconditional. A request that failed mid-flight may still
      // have deleted part of the selection, so the rows on screen are no more
      // trustworthy after a failure than after a success -- and the server's
      // view is the only one worth showing either way. `deleting` is cleared
      // first so the reloaded page renders its controls in their normal state;
      // load() clears #msg, so the failure report goes up after it, not before.
      deleting = false;
      return load(true).then(done, done);
    }).then(function () {
      if (failed.length) { showError(window.YurunaI18n.t("stash.value1_of_value2_could_not_be_deleted_value3", {value1: (failed.length), value2: (picked.length), value3: (failed.join('; '))})); }
    });
  }

  function load(reset) {
    var readyState = 'error';
    if (reset) { offset = 0; rendered = []; Y.replace($('rows')); clearError(); }
    $('status').textContent = window.YurunaI18n.t("stash.loading");
    // Before the rows, never after: row() reads the gate as it builds each one.
    // This also spends a control proof carried in from the dashboard, so a
    // browser that arrived by that link renders its first page already unlocked.
    return Y.initUnlock(function () { return load(true); }).then(function (sess) {
      gate.canDelete = sess.authed;
      gate.labToken = sess.labToken;
      return Y.api('/api/stashes?' + filterQuery()).then(function (data) {
return window.YurunaFirstUsable.measure("test/extension/stash-service/server/internal/httpsrv/web/index.html", "data", function () {
        total = data.total;
        var list = data.stashes || [];
        for (var i = 0; i < list.length; i++) {
          var v = list[i];
          var entry = row(v);
          rendered.push(entry);
          $('rows').appendChild(entry.tr);
          if (v.hostId && !seenHosts[v.hostId]) {
            seenHosts[v.hostId] = true;
            if (!v.local) { $('host').appendChild(Y.el('option', { value: v.hostId, text: Y.shortHost(v.hostId) })); }
          }
        }
        offset += list.length;
        readyState = list.length ? 'data' : 'empty';
        renderStatus();
        footer.markLoaded();

});
}, function (e) {
        $('status').textContent = window.YurunaI18n.t("stash.error_value1", {value1: (e.message)});
      });
    }).then(function () {
      renderDeleteNote();
      syncControls();
      window.YurunaFirstUsable.mark('test/extension/stash-service/server/internal/httpsrv/web/index.html', readyState);
    });
  }

  var timer = null;
  function debounced() {
    window.clearTimeout(timer);
    timer = window.setTimeout(function () { load(true); }, 250);
  }

  $('q').addEventListener('input', debounced);
  $('class').addEventListener('change', function () { load(true); });
  $('host').addEventListener('change', function () { load(true); });
  $('more').addEventListener('click', function () { load(false); });
  for (var si = 0; si < SORTS.length; si++) {
    // Wired through a call rather than from the loop body, so each handler
    // closes over ITS column instead of the last one in the list.
    (function (c) {
      var btn = $('sort-' + c.key);
      if (btn) { btn.addEventListener('click', function () { sortBy(c); }); }
    }(SORTS[si]));
  }
  // "All" spans every row on screen, the ones a "Load more" appended included --
  // it is a select-all-visible, not a select-all-matching-the-query.
  $('pick-all').addEventListener('change', function () {
    var on = $('pick-all').checked;
    for (var i = 0; i < rendered.length; i++) {
      if (rendered[i].pick) { rendered[i].pick.checked = on; }
    }
    syncControls();
  });
  $('delete-selected').addEventListener('click', function () { deleteSelected(); });
  $('refresh').addEventListener('click', function () {
    $('refresh').disabled = true;
    var release = function () { $('refresh').disabled = false; };
    Y.api('/api/refresh', { method: 'POST' })
      .then(function () { return load(true); })
      .then(release, release);
  });

  // Shared footer: server IPs, last-loaded time, and the refresh countdown
  // (default 60 s). The countdown drives the visibility-aware auto-refresh of
  // the first page -- but only when not searching or paginated (section 4.1), so it
  // never yanks the user off a "Load more" page or an active query. Each
  // successful load() stamps the footer's "Loaded" time + resets the countdown.
  var footer = Y.initFooter({
    intervalSeconds: 60,
    // A refresh re-renders every row, which would silently discard a selection
    // the operator is still assembling; park the countdown until it is acted on
    // or cleared.
    paused: function () { return deleting || selected().length > 0; },
    refresh: function () { if (offset <= PAGE && !$('q').value) { load(true); } }
  });

  renderSortHeaders();
  load(true);
})();
