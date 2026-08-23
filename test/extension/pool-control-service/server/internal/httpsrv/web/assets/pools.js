// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Pools CRUD: create (mints poolGuid server-side), drive every member's pause
// state, add/remove hosts, delete an empty pool.
(function () {
  // Header version + host id and the footer bar; its countdown re-reads pool
  // intent rather than reloading, so a half-typed new-pool id is not wiped.
  var chrome = Y.initChrome({ refresh: function () { load({ quiet: true }); } });

  // Built once, not per read: the sort an operator chose is theirs until they
  // change it, and re-reading pool intent every minute must not put the table
  // back in the server's order under them.
  var sorter = Y.sortTable(document.getElementById('pool-rows'), { key: 'pool' });

  // The three states an operator picks between, in the order the host's own
  // status page presents them: continue first, then the two pause depths.
  var ACTIONS = [
    { value: 'continue', label: 'Continue' },
    { value: 'pause-after-cycle', label: 'Pause after cycle' },
    { value: 'pause-after-step', label: 'Pause after step' }
  ];
  // States a pool can be IN that no operator can select. They are shown as the
  // current value and removed from the list the moment a real one is chosen.
  var OBSERVED = {
    mixed: 'Mixed',
    both: 'Paused after cycle and step',
    unknown: '--'
  };
  var LABEL = {};
  for (var li = 0; li < ACTIONS.length; li++) { LABEL[ACTIONS[li].value] = ACTIONS[li].label; }
  for (var lk in OBSERVED) {
    if (Object.prototype.hasOwnProperty.call(OBSERVED, lk)) { LABEL[lk] = OBSERVED[lk]; }
  }

  // Member states arrive from a separate endpoint because they come from the
  // hosts, not from the intent store: a pool renders (and stays editable) while
  // its members are being read, and an unreachable host grays one cell rather
  // than emptying the page.
  var control = {};
  var goBaseUrl = '';

  // renderStatus fills one pool's status cell from whatever member states are
  // in hand. It is called twice per load -- once with the states from the
  // previous read, once when the fresh ones arrive -- so the table (and the
  // hostId box someone may be typing into) is never held up by a lab where half
  // the hosts are powered off.
  function renderStatus(cell, p) {
    cell.textContent = '';
    var view = control[p.poolId] || {};
    var current = view.state || 'unknown';
    var sel = Y.el('select', { 'aria-label': 'Pool status for ' + p.poolId });
    if (OBSERVED[current]) {
      // A placeholder, not a choice: re-selecting it would mean nothing, so it
      // is disabled and drops out as soon as the operator picks a real state.
      var o = Y.el('option', { value: '', text: OBSERVED[current], disabled: 'disabled' });
      o.selected = true;
      sel.appendChild(o);
    }
    for (var ai = 0; ai < ACTIONS.length; ai++) {
      var opt = Y.el('option', { value: ACTIONS[ai].value, text: ACTIONS[ai].label });
      if (ACTIONS[ai].value === current) { opt.selected = true; }
      sel.appendChild(opt);
    }
    if ((p.members || []).length === 0) { sel.disabled = true; }

    Y.onSelectCommit(sel, function () {
      var action = sel.value;
      var count = (p.members || []).length;
      if (!window.confirm('Apply "' + LABEL[action] + '" to all ' + count + ' host(s) in pool ' + p.poolId + '?')) {
        load();
        return;
      }
      sel.disabled = true;
      // Re-read BEFORE reporting: the reload clears the notice area, so a
      // message written first would be wiped before it could be read -- and
      // which members refused is the whole answer here.
      Y.mutate('/api/pool/host-control', { method: 'POST', body: { poolId: p.poolId, action: action } }).then(function (res) {
        return load().then(function () { reportApply(p.poolId, action, res); });
      }, function (failure) {
        return load().then(function () {
          Y.notice('error', 'Pool status change failed: ' + failure.message);
        });
      });
    });

    cell.appendChild(sel);
    // Which members disagree is the question "Mixed" raises, so answer it in
    // the same cell instead of making the operator open each host.
    var hosts = view.hosts || [];
    if (hosts.length && (current === 'mixed' || current === 'unknown')) {
      for (var hi = 0; hi < hosts.length; hi++) {
        var h = hosts[hi];
        var text = Y.shortHost(h.hostId) + ': ' + (h.ok ? (LABEL[h.state] || h.state) : (h.error || 'no answer'));
        cell.appendChild(Y.el('div', { class: 'muted', text: text }));
      }
    }
  }

  // What the status column sorts on: the label the cell shows, so rows group
  // the way they read. A pool whose state is unknown has nothing to order by --
  // its cell is an em dash -- so it sorts as a blank, which ranks last.
  function statusValue(p) {
    var current = (control[p.poolId] || {}).state || 'unknown';
    return current === 'unknown' ? '' : (LABEL[current] || current);
  }

  // reportApply says what actually happened per host. A fan-out is partial by
  // nature -- one member never enrolled a lab token while the rest paused -- and
  // a bare "done" would hide exactly the host that needs attention.
  function reportApply(poolId, action, res) {
    var failed = (res.hosts || []).filter(function (h) { return !h.ok; });
    if (!res.applied && !failed.length) {
      Y.notice('ok', "Pool '" + poolId + "' has no members; nothing to drive.");
      return;
    }
    if (!failed.length) {
      Y.notice('ok', LABEL[action] + ': applied to ' + res.applied + " host(s) in pool '" + poolId + "'.");
      return;
    }
    var detail = failed.map(function (h) { return Y.shortHost(h.hostId) + ' (' + (h.error || 'failed') + ')'; }).join('; ');
    Y.notice('error', LABEL[action] + ': ' + res.applied + ' applied, ' + failed.length + ' failed -- ' + detail);
  }

  // quiet marks the countdown's read, which keeps the table it is refreshing on
  // screen. Every other read replaces it and says so: this page waits on a CLI
  // for pool intent and then on every member for its state.
  function load(opts) {
    var quiet = !!(opts && opts.quiet);
    var done = quiet ? function () { } : Y.busy(document.getElementById('pool-rows'), 'Loading pools...');
    chrome.busy(true);
    // Runs on the failure path too: an indicator left turning over a read that
    // already failed claims progress that is not happening.
    var finish = function () { done(); chrome.busy(false); };
    return renderPools().then(finish, finish);
  }

  function renderPools() {
    Y.clearNotice();
    // Y.hostInfo is memoized and non-rejecting, so this is one read for the
    // life of the page and an aggregator this daemon does not know about just
    // means unlinked ids. Asked for alongside the state read rather than after
    // it, because neither depends on the other.
    return Promise.all([Y.api('/api/state'), Y.hostInfo()]).then(function (both) {
      chrome.markLoaded();
      goBaseUrl = both[1].goBaseUrl || '';
      return paintPools(both[0].pools || []);
    }, function (e) {
      Y.notice('error', 'Could not load pools: ' + e.message);
    });
  }

  function paintPools(pools) {
    var tbody = document.getElementById('pool-rows');
    if (Y.holdRepaint(tbody, renderPools)) { return Promise.resolve(); }
    tbody.textContent = '';
    if (pools.length === 0) {
      sorter.set([]);
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '7', class: 'muted', text: 'No pools yet.' })]));
      return Promise.resolve();
    }
    var statusCells = {};
    var rowsByPool = {};
    var rows = [];
    for (var i = 0; i < pools.length; i++) {
      var built = buildRow(pools[i]);
      statusCells[pools[i].poolId] = built.statusTd;
      rowsByPool[pools[i].poolId] = built.row;
      rows.push(built.row);
    }
    sorter.set(rows);

    // Best-effort, and last: the member read reaches every host in the lab, so
    // a pool whose hosts are all down still renders and stays editable. A
    // failure keeps the previous states rather than blanking the column.
    return Y.api('/api/pool/host-control').then(function (d) {
      control = d.pools || {};
    }, function () { }).then(function () {
      for (var j = 0; j < pools.length; j++) {
        var p = pools[j];
        if (statusCells[p.poolId]) { renderStatus(statusCells[p.poolId], p); }
        if (rowsByPool[p.poolId]) { rowsByPool[p.poolId].values.status = statusValue(p); }
      }
      // The column these states feed is sortable, so the table has to answer
      // for the values it just took on. Rows already in order are left alone.
      sorter.refresh();
    });
  }

  // One row, built in its own call so every control below closes over THIS
  // pool and THIS member. Wiring them from inside a loop body would leave each
  // button acting on the last pool in the table.
  function buildRow(p) {
    var members = p.members || [];

    // placeholder IS a valid last-resort name source, so this control is not
    // nameless -- but the name disappears the moment a character is typed,
    // which is exactly when someone interrupted mid-entry needs it. The
    // aria-label persists and names the pool the id will join.
    var hostInput = Y.el('input', { placeholder: 'hostId (42+30hex)', size: '20', 'aria-label': 'Host id to add to pool ' + p.poolId });
    var addBtn = Y.el('button', { text: '+ host' });
    addBtn.addEventListener('click', function () {
      var hid = hostInput.value.trim();
      if (!hid) { return; }
      addBtn.disabled = true;
      Y.mutate('/api/pool/host', { method: 'POST', body: { poolId: p.poolId, hostId: hid } }).then(function () {
        Y.notice('ok', 'Added ' + hid + ' to ' + p.poolId);
        // In the row too: the banner is at the top of <main>, which at high
        // zoom is nowhere near the field the operator just typed into.
        Y.rowFeedback(addBtn.closest('tr'), 'ok', 'Added ' + Y.shortHost(hid) + '.');
        load();
      }, function (e) {
        Y.notice('error', 'Add host failed: ' + e.message);
        addBtn.disabled = false;
      });
    });

    var delBtn = Y.el('button', { text: 'Delete pool', 'aria-label': 'Delete pool ' + p.poolId });
    delBtn.addEventListener('click', function () {
      if (members.length > 0) { Y.notice('error', "Pool '" + p.poolId + "' has members; remove them first."); return; }
      // The empty-members check bounds the blast radius but is not a
      // confirmation: the pool, its display name and its test-set assignment
      // still go. Every other destructive control on this service asks, in
      // these words, and one that does not is the inconsistency users learn
      // to distrust.
      if (!window.confirm("Delete pool '" + p.poolId + "'? This cannot be undone.")) { return; }
      delBtn.disabled = true;
      Y.mutate('/api/pool?poolId=' + encodeURIComponent(p.poolId), { method: 'DELETE' }).then(function () {
        Y.notice('ok', "Deleted pool '" + p.poolId + "'.");
        load();
      }, function (e) {
        Y.notice('error', 'Delete failed: ' + e.message);
        delBtn.disabled = false;
      });
    });

    // members cell: the short id links to that host's own status page, with its
    // per-host remove alongside.
    var memCell = Y.el('td', {});
    for (var i = 0; i < members.length; i++) { memCell.appendChild(memberRow(p, members[i])); }
    memCell.appendChild(Y.el('div', {}, [hostInput, ' ', addBtn]));

    // Painted from the previous read now, repainted when this load's arrives:
    // a refresh must not blank a state that is still true.
    var statusTd = Y.el('td', {});
    renderStatus(statusTd, p);

    return {
      statusTd: statusTd,
      row: {
        tr: Y.el('tr', {}, [
          Y.el('td', { text: p.poolId }),
          Y.el('td', {}, [Y.idCell(p.poolGuid)]),
          Y.el('td', { text: p.displayName || '' }),
          memCell,
          statusTd,
          Y.el('td', {}, [delBtn])
        ]),
        values: {
          pool: p.poolId || '',
          poolGuid: p.poolGuid || '',
          name: p.displayName || '',
          members: members.length,
          status: statusValue(p)
        }
      }
    };
  }

  function memberRow(p, m) {
    // The label is the single character "x", which says neither what the
    // control does nor which of the rows above it acts on -- and every member
    // row carries one. The visible text stays, so the button keeps its size and
    // shape; the accessible name names the target.
    var rm = Y.el('button', { text: 'x', 'aria-label': 'Remove host ' + Y.shortHost(m) + ' from pool ' + p.poolId });
    rm.addEventListener('click', function () {
      // Every sibling destructive path on this service confirms, in these words.
      if (!window.confirm('Remove host ' + m + ' from pool ' + p.poolId + '? This cannot be undone.')) { return; }
      Y.mutate('/api/pool/host?poolId=' + encodeURIComponent(p.poolId) + '&hostId=' + encodeURIComponent(m), { method: 'DELETE' })
        .then(function () {
          load();
        }, function (e) {
          Y.notice('error', 'Remove host failed: ' + e.message);
          Y.rowFeedback(rm.closest('tr'), 'error', 'Remove failed: ' + e.message);
        });
    });
    return Y.el('div', {}, [Y.hostLink(m, p.poolId, goBaseUrl), ' ', rm]);
  }

  document.getElementById('create').addEventListener('click', function () {
    var poolId = document.getElementById('new-poolid').value.trim();
    var display = document.getElementById('new-display').value.trim();
    if (!poolId) { Y.notice('error', 'Enter a pool id.'); return; }
    Y.mutate('/api/pool', { method: 'POST', body: { poolId: poolId, displayName: display } }).then(function () {
      Y.notice('ok', "Created pool '" + poolId + "'.");
      document.getElementById('new-poolid').value = '';
      document.getElementById('new-display').value = '';
      load();
    }, function (e) {
      Y.notice('error', 'Create failed: ' + e.message);
    });
  });

  // Wrapped rather than passed straight to the listener: load() reads its first
  // argument as options, and a DOM event is not one.
  document.addEventListener('DOMContentLoaded', function () { load(); });
})();
