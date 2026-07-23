// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Main page: list pools with their assigned test-set; assign a library test-set
// to each pool; show members + the copy-config-from-another-host command.
(function () {
  async function load() {
    Y.clearNotice();
    let data;
    try { data = await Y.api('/api/state'); }
    catch (e) { Y.notice('error', 'Could not load pool intent: ' + e.message); return; }
    const pools = data.pools || [];
    const testSets = data.testSets || [];
    const tbody = document.getElementById('pool-rows');
    tbody.textContent = '';

    if (pools.length === 0) {
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '6', class: 'muted', text: 'No pools defined. Create one on the Pools page.' })]));
      return;
    }

    for (const p of pools) {
      const ts = p.testSet || null;

      // Assign dropdown (library test-sets) + button.
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
          await Y.api('/api/pool/testset', { method: 'POST', body: { poolId: p.poolId, name: t.name, frameworkURL: t.frameworkUrl, projectURL: t.projectUrl } });
          Y.notice('ok', "Assigned '" + name + "' to pool '" + p.poolId + "'.");
          load();
        } catch (e) { Y.notice('error', 'Assign failed: ' + e.message); assignBtn.disabled = false; }
      });

      // Members + copy-config affordance.
      const members = p.members || [];
      const memCell = Y.el('td', {}, [Y.el('div', { text: members.length + ' host(s)' })]);
      for (const m of members) memCell.appendChild(Y.el('div', { class: 'mono', text: m }));
      if (members.length > 1) {
        memCell.appendChild(Y.el('div', { class: 'hint', text: 'Copy config from a pool peer: pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <peer-ip>' }));
      }

      const fwProj = ts ? (ts.frameworkUrl + '  /  ' + ts.projectUrl) : '(none)';
      tbody.appendChild(Y.el('tr', {}, [
        Y.el('td', { text: p.poolId }),
        Y.el('td', { class: 'mono', text: p.poolGuid || '' }),
        Y.el('td', {}, [sel, ' ', assignBtn]),
        Y.el('td', { class: 'mono', text: fwProj }),
        memCell,
        Y.el('td', { text: p.desiredState || 'run' })
      ]));
    }
  }

  document.getElementById('refresh').addEventListener('click', load);
  document.addEventListener('DOMContentLoaded', load);
})();
