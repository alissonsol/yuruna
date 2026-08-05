// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Pools CRUD: create (mints poolGuid server-side), drive every member's pause
// state, add/remove hosts, delete an empty pool.
(function () {
  // Header version + host id and the footer bar; its countdown re-reads pool
  // intent rather than reloading, so a half-typed new-pool id is not wiped.
  const chrome = Y.initChrome({ refresh: load });

  // The three states an operator picks between, in the order the host's own
  // status page presents them: continue first, then the two pause depths.
  const ACTIONS = [
    { value: 'continue', label: 'Continue' },
    { value: 'pause-after-cycle', label: 'Pause after cycle' },
    { value: 'pause-after-step', label: 'Pause after step' }
  ];
  // States a pool can be IN that no operator can select. They are shown as the
  // current value and removed from the list the moment a real one is chosen.
  const OBSERVED = {
    mixed: 'Mixed',
    both: 'Paused after cycle and step',
    unknown: '—'
  };
  const LABEL = {};
  for (const a of ACTIONS) LABEL[a.value] = a.label;
  for (const k in OBSERVED) LABEL[k] = OBSERVED[k];

  // Member states arrive from a separate endpoint because they come from the
  // hosts, not from the intent store: a pool renders (and stays editable) while
  // its members are being read, and an unreachable host greys one cell rather
  // than emptying the page.
  let control = {};

  // renderStatus fills one pool's status cell from whatever member states are
  // in hand. It is called twice per load -- once with the states from the
  // previous read, once when the fresh ones arrive -- so the table (and the
  // hostId box someone may be typing into) is never held up by a lab where half
  // the hosts are powered off.
  function renderStatus(cell, p) {
    cell.textContent = '';
    const view = control[p.poolId] || {};
    const current = view.state || 'unknown';
    const sel = Y.el('select', { 'aria-label': 'Pool status for ' + p.poolId });
    if (OBSERVED[current]) {
      // A placeholder, not a choice: re-selecting it would mean nothing, so it
      // is disabled and drops out as soon as the operator picks a real state.
      const o = Y.el('option', { value: '', text: OBSERVED[current], disabled: 'disabled' });
      o.selected = true;
      sel.appendChild(o);
    }
    for (const a of ACTIONS) {
      const o = Y.el('option', { value: a.value, text: a.label });
      if (a.value === current) o.selected = true;
      sel.appendChild(o);
    }
    if ((p.members || []).length === 0) sel.disabled = true;

    sel.addEventListener('change', async function () {
      const action = sel.value;
      const count = (p.members || []).length;
      if (!confirm('Apply "' + LABEL[action] + '" to all ' + count + ' host(s) in pool ' + p.poolId + '?')) {
        load();
        return;
      }
      sel.disabled = true;
      let res, failure;
      try {
        res = await Y.mutate('/api/pool/host-control', { method: 'POST', body: { poolId: p.poolId, action: action } });
      } catch (e) {
        failure = e;
      }
      // Re-read BEFORE reporting: the reload clears the notice area, so a
      // message written first would be wiped before it could be read -- and
      // which members refused is the whole answer here.
      await load();
      if (failure) Y.notice('error', 'Pool status change failed: ' + failure.message);
      else reportApply(p.poolId, action, res);
    });

    cell.appendChild(sel);
    // Which members disagree is the question "Mixed" raises, so answer it in
    // the same cell instead of making the operator open each host.
    const hosts = view.hosts || [];
    if (hosts.length && (current === 'mixed' || current === 'unknown')) {
      for (const h of hosts) {
        const text = Y.shortHost(h.hostId) + ': ' + (h.ok ? (LABEL[h.state] || h.state) : (h.error || 'no answer'));
        cell.appendChild(Y.el('div', { class: 'muted', text: text }));
      }
    }
  }

  // reportApply says what actually happened per host. A fan-out is partial by
  // nature -- one member never enrolled a lab token while the rest paused -- and
  // a bare "done" would hide exactly the host that needs attention.
  function reportApply(poolId, action, res) {
    const failed = (res.hosts || []).filter(function (h) { return !h.ok; });
    if (!res.applied && !failed.length) {
      Y.notice('ok', "Pool '" + poolId + "' has no members; nothing to drive.");
      return;
    }
    if (!failed.length) {
      Y.notice('ok', LABEL[action] + ': applied to ' + res.applied + " host(s) in pool '" + poolId + "'.");
      return;
    }
    const detail = failed.map(function (h) { return Y.shortHost(h.hostId) + ' (' + (h.error || 'failed') + ')'; }).join('; ');
    Y.notice('error', LABEL[action] + ': ' + res.applied + ' applied, ' + failed.length + ' failed — ' + detail);
  }

  async function load() {
    Y.clearNotice();
    let data;
    try { data = await Y.api('/api/state'); }
    catch (e) { Y.notice('error', 'Could not load pools: ' + e.message); return; }
    chrome.markLoaded();
    const pools = data.pools || [];
    const tbody = document.getElementById('pool-rows');
    tbody.textContent = '';
    if (pools.length === 0) {
      tbody.appendChild(Y.el('tr', {}, [Y.el('td', { colspan: '6', class: 'muted', text: 'No pools yet.' })]));
      return;
    }
    const statusCells = {};
    for (const p of pools) {
      const members = p.members || [];

      const hostInput = Y.el('input', { placeholder: 'hostId (42+30hex)', size: '20' });
      const addBtn = Y.el('button', { text: '+ host' });
      addBtn.addEventListener('click', async function () {
        const hid = hostInput.value.trim(); if (!hid) return;
        addBtn.disabled = true;
        try { await Y.mutate('/api/pool/host', { method: 'POST', body: { poolId: p.poolId, hostId: hid } }); Y.notice('ok', 'Added ' + hid + ' to ' + p.poolId); load(); }
        catch (e) { Y.notice('error', 'Add host failed: ' + e.message); addBtn.disabled = false; }
      });

      const delBtn = Y.el('button', { text: 'Delete pool' });
      delBtn.addEventListener('click', async function () {
        if (members.length > 0) { Y.notice('error', "Pool '" + p.poolId + "' has members; remove them first."); return; }
        delBtn.disabled = true;
        try { await Y.mutate('/api/pool?poolId=' + encodeURIComponent(p.poolId), { method: 'DELETE' }); Y.notice('ok', "Deleted pool '" + p.poolId + "'."); load(); }
        catch (e) { Y.notice('error', 'Delete failed: ' + e.message); delBtn.disabled = false; }
      });

      // members cell with per-host remove
      const memCell = Y.el('td', {});
      for (const m of members) {
        const rm = Y.el('button', { text: 'x' });
        rm.addEventListener('click', async function () {
          try { await Y.mutate('/api/pool/host?poolId=' + encodeURIComponent(p.poolId) + '&hostId=' + encodeURIComponent(m), { method: 'DELETE' }); load(); }
          catch (e) { Y.notice('error', 'Remove host failed: ' + e.message); }
        });
        memCell.appendChild(Y.el('div', { class: 'mono' }, [m + ' ', rm]));
      }
      memCell.appendChild(Y.el('div', {}, [hostInput, ' ', addBtn]));

      // Painted from the previous read now, repainted below when this load's
      // arrives: a refresh must not blank a state that is still true.
      const statusTd = Y.el('td', {});
      statusCells[p.poolId] = statusTd;
      renderStatus(statusTd, p);

      tbody.appendChild(Y.el('tr', {}, [
        Y.el('td', { text: p.poolId }),
        Y.el('td', { class: 'mono', text: p.poolGuid || '' }),
        Y.el('td', { text: p.displayName || '' }),
        memCell,
        statusTd,
        Y.el('td', {}, [delBtn])
      ]));
    }

    // Best-effort, and last: the member read reaches every host in the lab, so
    // a pool whose hosts are all down still renders and stays editable.
    try { control = (await Y.api('/api/pool/host-control')).pools || {}; }
    catch (e) { /* keep the previous states rather than blanking the column */ }
    for (const p of pools) {
      if (statusCells[p.poolId]) renderStatus(statusCells[p.poolId], p);
    }
  }

  document.getElementById('create').addEventListener('click', async function () {
    const poolId = document.getElementById('new-poolid').value.trim();
    const display = document.getElementById('new-display').value.trim();
    if (!poolId) { Y.notice('error', 'Enter a pool id.'); return; }
    try {
      await Y.mutate('/api/pool', { method: 'POST', body: { poolId: poolId, displayName: display } });
      Y.notice('ok', "Created pool '" + poolId + "'.");
      document.getElementById('new-poolid').value = '';
      document.getElementById('new-display').value = '';
      load();
    } catch (e) { Y.notice('error', 'Create failed: ' + e.message); }
  });

  document.addEventListener('DOMContentLoaded', load);
})();
