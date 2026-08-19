// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Main page: list pools with their assigned test-set; assign a library test-set
// to each pool; show members + the copy-config-from-another-host command.
(function () {
  // Header version + host id and the footer bar; its countdown re-reads pool
  // intent rather than reloading, so an in-progress test-set choice survives.
  const chrome = Y.initChrome({ refresh: function () { load({ quiet: true }); } });

  // Built once, not per read: the sort an operator chose is theirs until they
  // change it, and re-reading pool intent every minute must not put the table
  // back in the server's order under them.
  const sorter = Y.sortTable(document.getElementById('pool-rows'), { key: 'pool' });

  // quiet marks the countdown's read, which keeps the table it is refreshing on
  // screen. Every other read replaces it and says so: pool intent is read by
  // running a CLI on the server, which is not instant.
  async function load(opts) {
    const quiet = !!(opts && opts.quiet);
    const tbody = document.getElementById('pool-rows');
    const done = quiet ? function () { } : Y.busy(tbody, 'Loading pools...');
    chrome.busy(true);
    try {
      await renderPools(tbody);
    } finally {
      // Also on the failure path: an indicator left turning over a read that
      // already failed claims progress that is not happening.
      done();
      chrome.busy(false);
    }
  }

  async function renderPools(tbody) {
    Y.clearNotice();
    let data;
    try { data = await Y.api('/api/state'); }
    catch (e) { Y.notice('error', 'Could not load pool intent: ' + e.message); return; }
    chrome.markLoaded();
    // Memoized and non-rejecting, so this is one read for the life of the page
    // and an aggregator this daemon does not know about just means unlinked ids.
    const goBaseUrl = (await Y.hostInfo()).goBaseUrl || '';
    const pools = data.pools || [];
    const testSets = data.testSets || [];
    tbody.textContent = '';

    if (pools.length === 0) {
      sorter.set([]);
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '7', class: 'muted', text: 'No pools defined. Create one on the Pools page.' })]));
      return;
    }

    const rows = [];
    for (const p of pools) {
      const ts = p.testSet || null;

      const sel = Y.el('select', {});
      sel.appendChild(Y.el('option', { value: '', text: '(choose a test set)' }));
      for (const t of testSets) {
        const o = Y.el('option', { value: t.name, text: t.name });
        if (ts && ts.name === t.name) o.selected = true;
        sel.appendChild(o);
      }
      const assignBtn = Y.el('button', { class: 'primary', text: 'Assign' });
      assignBtn.addEventListener('click', async function () {
        const name = sel.value;
        if (!name) { Y.notice('error', 'Pick a test set first (define one on the Test sets page).'); return; }
        const t = testSets.find(function (x) { return x.name === name; });
        if (!t) return;
        assignBtn.disabled = true;
        try {
          await Y.mutate('/api/pool/testset', { method: 'POST', body: { poolId: p.poolId, name: t.name, frameworkURL: t.frameworkUrl, projectURL: t.projectUrl } });
          Y.notice('ok', "Assigned '" + name + "' to pool '" + p.poolId + "'.");
          load();
        } catch (e) { Y.notice('error', 'Assign failed: ' + e.message); assignBtn.disabled = false; }
      });

      // Members: each id is the way into that host's own status page, so the
      // cell is the short id linked there. The copy-config command that used to
      // repeat under every multi-member pool is the table's footnote now -- it
      // is one instruction, not a per-row fact.
      const members = p.members || [];
      const memCell = Y.el('td', {}, [Y.el('div', { text: members.length + ' host(s)' })]);
      for (const m of members) memCell.appendChild(Y.el('div', {}, [Y.hostLink(m, p.poolId, goBaseUrl)]));

      // Framework and project on their own lines: the pair is two URLs, and one
      // run-on line of both is read by scanning for the separator between them.
      const fwProj = ts
        ? Y.el('td', { class: 'mono' }, [
          Y.el('div', { text: ts.frameworkUrl }),
          Y.el('div', { text: ts.projectUrl })
        ])
        : Y.el('td', { class: 'mono', text: '(none)' });
      // The picker column sorts on the set the pool holds NOW, not on the
      // choice sitting unsubmitted in the dropdown: the table orders what is
      // true of the lab, and a half-made choice is not that yet.
      rows.push({
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
      });
    }
    sorter.set(rows);
  }

  // Wrapped rather than passed straight to the listener: load() reads its first
  // argument as options, and a DOM event is not one.
  document.getElementById('refresh').addEventListener('click', function () { load(); });
  document.addEventListener('DOMContentLoaded', function () { load(); });
})();
