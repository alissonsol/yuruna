// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Main page: list pools with their assigned test-set; assign a library test-set
// to each pool; show members + the copy-config-from-another-host command.
(function () {
  // Header version + host id and the footer bar; its countdown re-reads pool
  // intent rather than reloading, so an in-progress test-set choice survives.
  var chrome = Y.initChrome({ refresh: function () { load({ quiet: true }); } });

  // Built once, not per read: the sort an operator chose is theirs until they
  // change it, and re-reading pool intent every minute must not put the table
  // back in the server's order under them.
  var sorter = Y.sortTable(document.getElementById('pool-rows'), { key: 'pool' });

  // quiet marks the countdown's read, which keeps the table it is refreshing on
  // screen. Every other read replaces it and says so: pool intent is read by
  // running a CLI on the server, which is not instant.
  function load(opts) {
    var quiet = !!(opts && opts.quiet);
    var tbody = document.getElementById('pool-rows');
    var done = quiet ? function () { } : Y.busy(tbody, 'Loading pools...');
    chrome.busy(true);
    // Runs on the failure path too: an indicator left turning over a read that
    // already failed claims progress that is not happening.
    var finish = function () { done(); chrome.busy(false); };
    return renderPools(tbody).then(finish, finish);
  }

  function renderPools(tbody) {
    Y.clearNotice();
    // Y.hostInfo is memoized and non-rejecting, so this is one read for the
    // life of the page and an aggregator this daemon does not know about just
    // means unlinked ids. Asked for alongside the state read rather than after
    // it, because neither depends on the other.
    return Promise.all([Y.api('/api/state'), Y.hostInfo()]).then(function (both) {
      chrome.markLoaded();
      paintPools(tbody, both[0], both[1].goBaseUrl || '');
    }, function (e) {
      Y.notice('error', 'Could not load pool intent: ' + e.message);
    });
  }

  function paintPools(tbody, data, goBaseUrl) {
    var pools = data.pools || [];
    var testSets = data.testSets || [];
    if (Y.holdRepaint(tbody, function () { renderPools(tbody); })) { return; }
    tbody.textContent = '';

    if (pools.length === 0) {
      sorter.set([]);
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '7', class: 'muted', text: 'No pools defined. Create one on the Pools page.' })]));
      return;
    }

    var rows = [];
    for (var i = 0; i < pools.length; i++) { rows.push(buildRow(pools[i], testSets, goBaseUrl)); }
    sorter.set(rows);
  }

  // One row, built in its own call so the picker and the Assign button below
  // close over THIS pool. Wiring them from inside a loop body would leave every
  // button assigning to the last pool in the table.
  function buildRow(p, testSets, goBaseUrl) {
    var ts = p.testSet || null;

    // Four of these render one under the other, one per pool. Without a name
    // they all announce as a bare "combo box" and there is nothing to tell
    // them apart -- which is how a test set gets assigned to the wrong pool.
    // The three sibling selects in this service already do this.
    var sel = Y.el('select', { 'aria-label': 'Test set for pool ' + p.poolId });
    sel.appendChild(Y.el('option', { value: '', text: '(choose a test set)' }));
    for (var i = 0; i < testSets.length; i++) {
      var t = testSets[i];
      var o = Y.el('option', { value: t.name, text: t.name });
      if (ts && ts.name === t.name) { o.selected = true; }
      sel.appendChild(o);
    }
    var assignBtn = Y.el('button', { class: 'primary', text: 'Assign' });
    assignBtn.addEventListener('click', function () {
      var name = sel.value;
      if (!name) { Y.notice('error', 'Pick a test set first (define one on the Test sets page).'); return; }
      var chosen = null;
      for (var j = 0; j < testSets.length; j++) {
        if (testSets[j].name === name) { chosen = testSets[j]; break; }
      }
      if (!chosen) { return; }
      assignBtn.disabled = true;
      Y.mutate('/api/pool/testset', {
        method: 'POST',
        body: { poolId: p.poolId, name: chosen.name, frameworkURL: chosen.frameworkUrl, projectURL: chosen.projectUrl }
      }).then(function () {
        Y.notice('ok', "Assigned '" + name + "' to pool '" + p.poolId + "'.");
        load();
      }, function (e) {
        Y.notice('error', 'Assign failed: ' + e.message);
        assignBtn.disabled = false;
      });
    });

    // Members: each id is the way into that host's own status page, so the cell
    // is the short id linked there. The copy-config command is the table's
    // footnote rather than a per-row repeat -- it is one instruction, not a
    // per-row fact.
    var members = p.members || [];
    var memCell = Y.el('td', {}, [Y.el('div', { text: members.length + ' host(s)' })]);
    for (var k = 0; k < members.length; k++) {
      memCell.appendChild(Y.el('div', {}, [Y.hostLink(members[k], p.poolId, goBaseUrl)]));
    }

    // Framework and project on their own lines: the pair is two URLs, and one
    // run-on line of both is read by scanning for the separator between them.
    var fwProj = ts
      ? Y.el('td', { class: 'mono' }, [
        Y.el('div', { text: ts.frameworkUrl }),
        Y.el('div', { text: ts.projectUrl })
      ])
      : Y.el('td', { class: 'mono', text: '(none)' });
    // The picker column sorts on the set the pool holds NOW, not on the choice
    // sitting unsubmitted in the dropdown: the table orders what is true of the
    // lab, and a half-made choice is not that yet.
    return {
      tr: Y.el('tr', {}, [
        Y.el('td', { text: p.poolId }),
        Y.el('td', {}, [Y.idCell(p.poolGuid)]),
        Y.el('td', {}, [sel, ' ', assignBtn]),
        fwProj,
        memCell,
        Y.el('td', { text: p.desiredState || 'run' })
      ]),
      values: {
        pool: p.poolId || '',
        poolGuid: p.poolGuid || '',
        testSet: ts ? ts.name : '',
        repos: ts ? ts.frameworkUrl + ' ' + ts.projectUrl : '',
        members: members.length,
        state: p.desiredState || 'run'
      }
    };
  }

  // Wrapped rather than passed straight to the listener: load() reads its first
  // argument as options, and a DOM event is not one.
  document.getElementById('refresh').addEventListener('click', function () { load(); });
  document.addEventListener('DOMContentLoaded', function () { load(); });
})();
