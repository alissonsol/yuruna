// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Pools CRUD: create (mints poolGuid server-side), set desired state, add/remove
// hosts, delete an empty pool.
(function () {
  async function load() {
    Y.clearNotice();
    let data;
    try { data = await Y.api('/api/state'); }
    catch (e) { Y.notice('error', 'Could not load pools: ' + e.message); return; }
    const pools = data.pools || [];
    const tbody = document.getElementById('pool-rows');
    tbody.textContent = '';
    if (pools.length === 0) {
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '6', class: 'muted', text: 'No pools yet.' })]));
      return;
    }
    for (const p of pools) {
      const members = p.members || [];

      // desiredState select
      const stateSel = Y.el('select', {});
      for (const st of ['run', 'paused', 'drain']) {
        const o = Y.el('option', { value: st, text: st });
        if ((p.desiredState || 'run') === st) o.selected = true;
        stateSel.appendChild(o);
      }
      stateSel.addEventListener('change', async function () {
        try { await Y.api('/api/pool/desired-state', { method: 'POST', body: { poolId: p.poolId, desiredState: stateSel.value } }); Y.notice('ok', "Pool '" + p.poolId + "' -> " + stateSel.value); load(); }
        catch (e) { Y.notice('error', 'State change failed: ' + e.message); }
      });

      // add-host input + button
      const hostInput = Y.el('input', { placeholder: 'hostId (42+30hex)', size: '20' });
      const addBtn = Y.el('button', { text: '+ host' });
      addBtn.addEventListener('click', async function () {
        const hid = hostInput.value.trim(); if (!hid) return;
        addBtn.disabled = true;
        try { await Y.api('/api/pool/host', { method: 'POST', body: { poolId: p.poolId, hostId: hid } }); Y.notice('ok', 'Added ' + hid + ' to ' + p.poolId); load(); }
        catch (e) { Y.notice('error', 'Add host failed: ' + e.message); addBtn.disabled = false; }
      });

      const delBtn = Y.el('button', { text: 'Delete pool' });
      delBtn.addEventListener('click', async function () {
        if (members.length > 0) { Y.notice('error', "Pool '" + p.poolId + "' has members; remove them first."); return; }
        delBtn.disabled = true;
        try { await Y.api('/api/pool?poolId=' + encodeURIComponent(p.poolId), { method: 'DELETE' }); Y.notice('ok', "Deleted pool '" + p.poolId + "'."); load(); }
        catch (e) { Y.notice('error', 'Delete failed: ' + e.message); delBtn.disabled = false; }
      });

      // members cell with per-host remove
      const memCell = Y.el('td', {});
      for (const m of members) {
        const rm = Y.el('button', { text: 'x' });
        rm.addEventListener('click', async function () {
          try { await Y.api('/api/pool/host?poolId=' + encodeURIComponent(p.poolId) + '&hostId=' + encodeURIComponent(m), { method: 'DELETE' }); load(); }
          catch (e) { Y.notice('error', 'Remove host failed: ' + e.message); }
        });
        memCell.appendChild(Y.el('div', { class: 'mono' }, [m + ' ', rm]));
      }
      memCell.appendChild(Y.el('div', {}, [hostInput, ' ', addBtn]));

      tbody.appendChild(Y.el('tr', {}, [
        Y.el('td', { text: p.poolId }),
        Y.el('td', { class: 'mono', text: p.poolGuid || '' }),
        Y.el('td', { text: p.displayName || '' }),
        memCell,
        Y.el('td', {}, [stateSel]),
        Y.el('td', {}, [delBtn])
      ]));
    }
  }

  document.getElementById('create').addEventListener('click', async function () {
    const poolId = document.getElementById('new-poolid').value.trim();
    const display = document.getElementById('new-display').value.trim();
    const state = document.getElementById('new-state').value;
    if (!poolId) { Y.notice('error', 'Enter a pool id.'); return; }
    try {
      await Y.api('/api/pool', { method: 'POST', body: { poolId: poolId, displayName: display, desiredState: state } });
      Y.notice('ok', "Created pool '" + poolId + "'.");
      document.getElementById('new-poolid').value = '';
      document.getElementById('new-display').value = '';
      load();
    } catch (e) { Y.notice('error', 'Create failed: ' + e.message); }
  });

  document.addEventListener('DOMContentLoaded', load);
})();
