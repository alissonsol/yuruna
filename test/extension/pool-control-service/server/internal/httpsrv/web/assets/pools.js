// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Pools CRUD: create (mints poolGuid server-side), drive every member's pause
// state, set each pool's framework and project URLs, add/remove hosts, delete
// an empty pool.
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
    { value: 'continue', label: window.YurunaI18n.t("pool.continue") },
    { value: 'pause-after-cycle', label: window.YurunaI18n.t("pool.pause_after_cycle") },
    { value: 'pause-after-step', label: window.YurunaI18n.t("pool.pause_after_step") }
  ];
  // States a pool can be IN that no operator can select. They are shown as the
  // current value and removed from the list the moment a real one is chosen.
  var OBSERVED = {
    mixed: window.YurunaI18n.t("pool.mixed"),
    both: window.YurunaI18n.t("pool.paused_after_cycle_and_step"),
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

  // The auto-enrollment target pool, from the same /api/state reply as the
  // pools. Hosts land there on their own and keep running their own projects,
  // so that row takes no framework or project URL.
  var targetPoolId = '';

  // Framework / Project text typed but not yet saved, by poolId, as
  // { framework, project }. Every read rebuilds the rows -- the countdown's,
  // the one after an action in another row, the one Y.holdRepaint runs once
  // focus leaves the table -- and a rebuilt row fills its boxes from here
  // before the saved values, so typing survives until it is saved.
  var drafts = {};
  // Pools whose save is on its way, by poolId. A row rebuilt while the request
  // is out must not offer the same save a second time.
  var saving = {};

  // renderStatus fills one pool's status cell from whatever member states are
  // in hand. It is called twice per load -- once with the states from the
  // previous read, once when the fresh ones arrive -- so the table (and the
  // hostId box someone may be typing into) is never held up by a lab where half
  // the hosts are powered off.
  function renderStatus(cell, p) {
    cell.textContent = '';
    var view = control[p.poolId] || {};
    var current = view.state || 'unknown';
    var sel = Y.el('select', { 'aria-label': window.YurunaI18n.t("pool.pool_status_for_value1", {value1: (p.poolId)}) });
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
      if (!window.confirm(window.YurunaI18n.t("pool.apply_value1_to_all_value2_host_s_in_pool_value3", {value1: (LABEL[action]), value2: (count), value3: (p.poolId)}))) {
        load();
        return;
      }
      sel.disabled = true;
      // Re-read BEFORE reporting: the reload clears the notice area, so a
      // message written first would be wiped before it could be read -- and
      // which members refused is the whole answer here.
      Y.mutate('/api/pool/host-control', { method: 'POST', timeoutMs: 90000, body: { poolId: p.poolId, action: action } }).then(function (res) {
        return load().then(function () { reportApply(p.poolId, action, res); });
      }, function (failure) {
        return load().then(function () {
          Y.notice('error', window.YurunaI18n.t("pool.pool_status_change_failed_value1", {value1: (failure.message)}));
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

  // The pool's framework and project URLs as the intent store holds them, ''
  // for a pool that carries none, so every comparison below is string to
  // string.
  function savedRepositories(p) {
    var r = p.repositories || {};
    return { framework: String(r.frameworkUrl || ''), project: String(r.projectUrl || '') };
  }

  // What the Framework / Project column sorts on: the pair the pool holds NOW,
  // never text sitting unsaved in its boxes -- the table orders what is true of
  // the lab, and a half-typed URL is not that yet.
  function repositoriesValue(p) {
    var saved = savedRepositories(p);
    return saved.framework || saved.project ? saved.framework + ' ' + saved.project : '';
  }

  // reportApply says what actually happened per host. A fan-out is partial by
  // nature -- one member never enrolled a lab token while the rest paused -- and
  // a bare "done" would hide exactly the host that needs attention.
  function reportApply(poolId, action, res) {
    var failed = (res.hosts || []).filter(function (h) { return !h.ok; });
    if (!res.applied && !failed.length) {
      Y.notice('ok', window.YurunaI18n.t("pool.pool_value1_has_no_members_nothing_to_drive", {value1: (poolId)}));
      return;
    }
    if (!failed.length) {
      Y.notice('ok', window.YurunaI18n.t("pool.value1_applied_to_value2_host_s_in_pool_value3", {value1: (LABEL[action]), value2: (res.applied), value3: (poolId)}));
      return;
    }
    var detail = failed.map(function (h) { return Y.shortHost(h.hostId) + ' (' + (h.error || 'failed') + ')'; }).join('; ');
    Y.notice('error', window.YurunaI18n.t("pool.value1_value2_applied_value3_failed_value4", {value1: (LABEL[action]), value2: (res.applied), value3: (failed.length), value4: (detail)}));
  }

  // quiet marks the countdown's read, which keeps the table it is refreshing on
  // screen. Every other read replaces it and says so: this page waits on a CLI
  // for pool intent and then on every member for its state.
  function load(opts) {
    var finish = Y.beginPageLoad(chrome, { quiet: !!(opts && opts.quiet), target: document.getElementById('pool-rows'), label: window.YurunaI18n.t("pool.loading_pools") });
    return renderPools().then(finish, finish);
  }

  function renderPools() {
    return window.YurunaFirstUsable.measure("test/extension/pool-control-service/server/internal/httpsrv/web/pools.html", "data", function () {
      return renderPoolsMeasured();
    });
  }


  function renderPoolsMeasured() {
    Y.clearNotice();
    // Y.hostInfo is memoized and non-rejecting, so this is one read for the
    // life of the page and an aggregator this daemon does not know about just
    // means unlinked ids. Asked for alongside the state read rather than after
    // it, because neither depends on the other.
    return Promise.all([Y.api('/api/state'), Y.hostInfo()]).then(function (both) {
      chrome.markLoaded();
      goBaseUrl = both[1].goBaseUrl || '';
      targetPoolId = (both[0].autoEnrollment && both[0].autoEnrollment.targetPoolId) || '';
      return paintPools(both[0].pools || []);
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("pool.could_not_load_pools_value1", {value1: (e.message)}));
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/pools.html', 'error');
    });
  }

  function paintPools(pools) {
    var tbody = document.getElementById('pool-rows');
    if (Y.holdRepaint(tbody, renderPools)) { return Promise.resolve(); }
    tbody.textContent = '';
    // A draft outlives its row but not its pool: text typed for a pool that is
    // gone must not reappear in a new pool created under the same id.
    var present = {};
    for (var pi = 0; pi < pools.length; pi++) { present[pools[pi].poolId] = true; }
    for (var stale in drafts) {
      if (Object.prototype.hasOwnProperty.call(drafts, stale) && !present[stale]) { delete drafts[stale]; }
    }
    if (pools.length === 0) {
      sorter.set([]);
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '8', class: 'muted', text: window.YurunaI18n.t("pool.no_pools_yet") })]));
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/pools.html', 'empty');
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
        if (statusCells[p.poolId] && !Y.holdRepaint(statusCells[p.poolId], renderPools)) { renderStatus(statusCells[p.poolId], p); }
        if (rowsByPool[p.poolId]) { rowsByPool[p.poolId].values.status = statusValue(p); }
      }
      // The column these states feed is sortable, so the table has to answer
      // for the values it just took on. Rows already in order are left alone.
      sorter.refresh();
      window.YurunaFirstUsable.mark('test/extension/pool-control-service/server/internal/httpsrv/web/pools.html', 'data');
    });
  }

  // The outcome of a row's action, in the row that produced it. Looked up by
  // pool after the reload, because the reload may have replaced the row the
  // action started from.
  function feedbackOnRow(poolId, kind, text) {
    var rows = document.getElementById('pool-rows').children;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].getAttribute('data-pool-id') === poolId) { Y.rowFeedback(rows[i], kind, text); }
    }
  }

  // sendRepositories writes one pool's pair; both empty clears it, and each
  // member goes back to its own configured repositories. landed runs the
  // moment the write succeeds, BEFORE the reload, so the rebuilt row does not
  // find the draft that was just saved. The reload also comes before the
  // notice, because the reload clears the notice area.
  function sendRepositories(p, framework, project, landed) {
    return Y.mutate('/api/pool/repositories', {
      method: 'POST',
      body: { poolId: p.poolId, frameworkUrl: framework, projectUrl: project }
    }).then(function () {
      landed();
      return load({ quiet: true }).then(function () {
        var text = framework
          ? window.YurunaI18n.t("pool.repositories_saved", {pool: (p.poolId)})
          : window.YurunaI18n.t("pool.repositories_cleared", {pool: (p.poolId)});
        Y.notice('ok', text);
        feedbackOnRow(p.poolId, 'ok', text);
      });
    });
  }

  function saveFailed(e) {
    Y.notice('error', window.YurunaI18n.t("pool.save_failed_value1", {value1: (Y.bidiIsolate(e && e.message))}));
  }

  // The Framework / Project cell: two single-line boxes, the framework URL over
  // the project URL, plus the control that commits them, which the caller puts
  // in the Actions column. Returns { cell, action }; action is null when the
  // row has nothing to commit.
  function buildRepositoryCell(p) {
    var saved = savedRepositories(p);
    var draft = drafts[p.poolId] || null;
    if (draft && draft.framework.trim() === saved.framework && draft.project.trim() === saved.project) {
      delete drafts[p.poolId];
      draft = null;
    }
    var shown = draft || saved;

    // No visible label: one would repeat the column header on every row. The
    // aria-label names the box and its pool for assistive tech, the
    // placeholder says which box is which while it is empty, and dir="ltr"
    // keeps a URL reading left to right on a right-to-left page.
    var frameworkBox = Y.el('input', {
      type: 'text', class: 'repo-url', dir: 'ltr', 'data-repo': 'framework',
      spellcheck: 'false', autocomplete: 'off', autocapitalize: 'off', autocorrect: 'off', inputmode: 'url',
      placeholder: window.YurunaI18n.t("pool.framework_url"),
      'aria-label': window.YurunaI18n.t("pool.repositories_framework_label", {pool: (p.poolId)})
    });
    var projectBox = Y.el('input', {
      type: 'text', class: 'repo-url', dir: 'ltr', 'data-repo': 'project',
      spellcheck: 'false', autocomplete: 'off', autocapitalize: 'off', autocorrect: 'off', inputmode: 'url',
      placeholder: window.YurunaI18n.t("pool.project_url"),
      'aria-label': window.YurunaI18n.t("pool.repositories_project_label", {pool: (p.poolId)})
    });
    // Properties, never Y.el attributes: Y.el writes every key with
    // setAttribute, and a value attribute is only the default a box resets to
    // while a disabled attribute disables whatever its value says.
    frameworkBox.value = shown.framework;
    projectBox.value = shown.project;
    var cell = Y.el('td', { class: 'repo-cell' }, [frameworkBox, projectBox]);

    if (targetPoolId && p.poolId === targetPoolId) {
      frameworkBox.disabled = true;
      projectBox.disabled = true;
      cell.appendChild(Y.el('div', { class: 'muted', text: window.YurunaI18n.t("pool.diagnostic_auto_enrollment_assignment") }));
      if (!saved.framework && !saved.project) { return { cell: cell, action: null }; }
      // A pair on this pool is one the runner already ignores and
      // Test-PoolIntent reports, so the only change offered is taking it off.
      // Its members run their own projects either way, so nothing changes for
      // them and there is nothing to confirm.
      var clearBtn = Y.el('button', {
        type: 'button', 'data-action': 'clear-repositories',
        text: window.YurunaI18n.t("pool.repositories_clear"),
        'aria-label': window.YurunaI18n.t("pool.repositories_clear_label", {pool: (p.poolId)})
      });
      clearBtn.disabled = !!saving[p.poolId];
      clearBtn.addEventListener('click', function () {
        saving[p.poolId] = true;
        clearBtn.disabled = true;
        sendRepositories(p, '', '', function () {
          delete saving[p.poolId];
          frameworkBox.value = '';
          projectBox.value = '';
        }).then(null, function (e) {
          delete saving[p.poolId];
          clearBtn.disabled = false;
          saveFailed(e);
        });
      });
      return { cell: cell, action: clearBtn };
    }

    var saveBtn = Y.el('button', {
      type: 'button', 'data-action': 'set-repositories',
      text: window.YurunaI18n.t("pool.repositories_save"),
      'aria-label': window.YurunaI18n.t("pool.repositories_save_label", {pool: (p.poolId)})
    });
    function refreshSave() {
      saveBtn.disabled = !!saving[p.poolId] || !drafts[p.poolId];
    }
    refreshSave();

    // A draft exists exactly while a box differs from what the pool holds;
    // surrounding spaces are not a difference, because the save trims them.
    function track() {
      if (frameworkBox.value.trim() === saved.framework && projectBox.value.trim() === saved.project) {
        delete drafts[p.poolId];
      } else {
        drafts[p.poolId] = { framework: frameworkBox.value, project: projectBox.value };
      }
      refreshSave();
    }

    function commit() {
      if (saveBtn.disabled) { return; }
      var framework = frameworkBox.value.trim();
      var project = projectBox.value.trim();
      // Half a pair is never sent: the server refuses it, and saying why here
      // costs the operator no Lab-token prompt and no round trip.
      if ((framework === '') !== (project === '')) {
        Y.notice('error', window.YurunaI18n.t("pool.repositories_both_or_neither"));
        return;
      }
      // Every member picks the change up on its next cycle, the same blast
      // radius as a Pool Status change, so it is named before it is written.
      var count = (p.members || []).length;
      if (count > 0) {
        var question = project
          ? window.YurunaI18n.t('pool.hosts_switch_project', {count: count, project: Y.bidiIsolate(project)})
          : window.YurunaI18n.t('pool.hosts_switch_own_projects', {count: count});
        if (!window.confirm(question)) { return; }
      }
      saving[p.poolId] = true;
      refreshSave();
      sendRepositories(p, framework, project, function () {
        delete saving[p.poolId];
        // Compared with the draft rather than the boxes: text typed while the
        // request was out is newer than what it carried, and it stays.
        saved = { framework: framework, project: project };
        var pending = drafts[p.poolId];
        if (pending && pending.framework.trim() === framework && pending.project.trim() === project) {
          delete drafts[p.poolId];
        }
        refreshSave();
      }).then(null, function (e) {
        delete saving[p.poolId];
        refreshSave();
        saveFailed(e);
      });
    }

    // Enter in either box saves. No form element carries this: the page's CSP
    // sets form-action 'none', which blocks every form submission. An Enter
    // that ends an IME composition belongs to the composition.
    function onKey(ev) {
      if (Y.key(ev) !== 'Enter' || ev.isComposing || ev.keyCode === 229) { return; }
      ev.preventDefault();
      commit();
    }
    frameworkBox.addEventListener('input', track);
    projectBox.addEventListener('input', track);
    frameworkBox.addEventListener('keydown', onKey);
    projectBox.addEventListener('keydown', onKey);
    saveBtn.addEventListener('click', commit);
    return { cell: cell, action: saveBtn };
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
    var hostInput = Y.el('input', { placeholder: window.YurunaI18n.t("pool.hostid_42_30hex"), size: '20', 'aria-label': window.YurunaI18n.t("pool.host_id_to_add_to_pool_value1", {value1: (p.poolId)}) });
    var addBtn = Y.el('button', { text: window.YurunaI18n.t("pool.host") });
    addBtn.addEventListener('click', function () {
      var hid = hostInput.value.trim();
      if (!hid) { return; }
      addBtn.disabled = true;
      Y.mutate('/api/pool/host', { method: 'POST', body: { poolId: p.poolId, hostId: hid } }).then(function () {
        return load({ quiet: true }).then(function () {
          Y.notice('ok', window.YurunaI18n.t("pool.added_value1_to_value2", {value1: (hid), value2: (p.poolId)}));
          var rows = document.getElementById('pool-rows').children;
          for (var i = 0; i < rows.length; i++) {
            if (rows[i].getAttribute('data-pool-id') === p.poolId) {
              Y.rowFeedback(rows[i], 'ok', window.YurunaI18n.t("pool.added_value1", {value1: (Y.shortHost(hid))}));
            }
          }
        });
      }, function (e) {
        Y.notice('error', window.YurunaI18n.t("pool.add_host_failed_value1", {value1: (e.message)}));
        addBtn.disabled = false;
      });
    });

    var delBtn = Y.el('button', { text: window.YurunaI18n.t("pool.delete_pool"), 'aria-label': window.YurunaI18n.t("pool.delete_pool_value1", {value1: (p.poolId)}) });
    delBtn.addEventListener('click', function () {
      if (members.length > 0) { Y.notice('error', window.YurunaI18n.t("pool.pool_value1_has_members_remove_them_first", {value1: (p.poolId)})); return; }
      // The empty-members check bounds the blast radius but is not a
      // confirmation: the pool, its display name and its framework and project
      // URLs still go. Every other destructive control on this service asks, in
      // these words, and one that does not is the inconsistency users learn
      // to distrust.
      if (!window.confirm(window.YurunaI18n.t("pool.delete_pool_value1_this_cannot_be_undone", {value1: (p.poolId)}))) { return; }
      delBtn.disabled = true;
      Y.mutate('/api/pool?poolId=' + encodeURIComponent(p.poolId), { method: 'DELETE' }).then(function () {
        return load().then(function () {
          Y.notice('ok', window.YurunaI18n.t("pool.deleted_pool_value1", {value1: (p.poolId)}));
        });
      }, function (e) {
        Y.notice('error', window.YurunaI18n.t("pool.delete_failed_value1", {value1: (e.message)}));
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

    var repositories = buildRepositoryCell(p);

    return {
      statusTd: statusTd,
      row: {
        tr: Y.el('tr', { 'data-pool-id': p.poolId }, [
          Y.el('td', { text: p.poolId }),
          Y.el('td', {}, [Y.idCell(p.poolGuid)]),
          Y.el('td', { text: p.displayName || '' }),
          memCell,
          statusTd,
          repositories.cell,
          Y.el('td', {}, repositories.action ? [repositories.action, ' ', delBtn] : [delBtn])
        ]),
        values: {
          pool: p.poolId || '',
          poolGuid: p.poolGuid || '',
          name: p.displayName || '',
          members: members.length,
          status: statusValue(p),
          repositories: repositoriesValue(p)
        }
      }
    };
  }

  function memberRow(p, m) {
    // The label is the single character "x", which says neither what the
    // control does nor which of the rows above it acts on -- and every member
    // row carries one. The visible text stays, so the button keeps its size and
    // shape; the accessible name names the target.
    var rm = Y.el('button', { text: 'x', 'aria-label': window.YurunaI18n.t("pool.remove_host_value1_from_pool_value2", {value1: (Y.shortHost(m)), value2: (p.poolId)}) });
    rm.addEventListener('click', function () {
      // Every sibling destructive path on this service confirms, in these words.
      if (!window.confirm(window.YurunaI18n.t("pool.remove_host_value1_from_pool_value2_this_cannot_be_undone", {value1: (m), value2: (p.poolId)}))) { return; }
      Y.mutate('/api/pool/host?poolId=' + encodeURIComponent(p.poolId) + '&hostId=' + encodeURIComponent(m), { method: 'DELETE' })
        .then(function () {
          load();
        }, function (e) {
          Y.notice('error', window.YurunaI18n.t("pool.remove_host_failed_value1", {value1: (e.message)}));
          Y.rowFeedback(rm.closest('tr'), 'error', window.YurunaI18n.t("pool.remove_failed_value1", {value1: (e.message)}));
        });
    });
    return Y.el('div', {}, [Y.hostLink(m, p.poolId, goBaseUrl), ' ', rm]);
  }

  document.getElementById('create').addEventListener('click', function () {
    var poolId = document.getElementById('new-poolid').value.trim();
    var display = document.getElementById('new-display').value.trim();
    if (!poolId) { Y.notice('error', window.YurunaI18n.t("pool.enter_a_pool_id")); return; }
    Y.mutate('/api/pool', { method: 'POST', body: { poolId: poolId, displayName: display } }).then(function () {
      document.getElementById('new-poolid').value = '';
      document.getElementById('new-display').value = '';
      return load().then(function () {
        Y.notice('ok', window.YurunaI18n.t("pool.created_pool_value1", {value1: (poolId)}));
      });
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("pool.create_failed_value1", {value1: (e.message)}));
    });
  });

  // Wrapped rather than passed straight to the listener: load() reads its first
  // argument as options, and a DOM event is not one.
  document.addEventListener('DOMContentLoaded', function () { load(); });
})();
