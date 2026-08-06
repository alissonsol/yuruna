// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Host-centric pool assignment. No innerHTML on data.
(function () {
  let pools = [];
  let targetPoolId = '';
  let goBaseUrl = '';

  // The dashboard collapses control state into remote/onsite. This page shows
  // the wire value instead, because mismatch (wrong token) and skew (clock) need
  // completely different fixes.
  const CONTROL_HINT = {
    ready: 'Holds this lab’s token; clock agrees.',
    none: 'Never enrolled a lab token — run Set-LabToken.ps1 on the host.',
    mismatch: 'Holds a DIFFERENT token — re-enrol against this proxy.',
    skew: 'Token is right but the clock is off — fix the host clock.',
    unknown: 'Not answered yet, or the proxy holds no token of its own.'
  };

  // The GUID-dashed presentation the dashboard uses for the opaque id. The
  // table shows the short id, but a confirm prompt is where an operator commits
  // to moving a machine: it names the host in full, and dashes are what makes
  // 32 hex characters checkable against another screen.
  function guid(hostId) {
    const h = String(hostId);
    if (h.length !== 32) return h;
    return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join('-');
  }

  function accessCell(access) {
    if (!access) return Y.el('span', { class: 'muted', text: '—' });
    if (access === 'denied') return Y.el('strong', { text: 'DENIED' });
    return Y.el('span', { text: access });
  }

  function rowEl(h) {
    const sel = Y.el('select', { 'aria-label': 'Pool for host ' + h.hostId });
    sel.appendChild(Y.el('option', { value: '', text: '(none)' }));
    for (const p of pools) {
      const o = Y.el('option', { value: p, text: p + (p === targetPoolId ? ' — auto-enrolment target' : '') });
      if (p === h.pool) o.selected = true;
      sel.appendChild(o);
    }
    sel.addEventListener('change', async () => {
      const to = sel.value;
      const label = to || '(none)';
      // (none) also records an exclusion, or the sweep would undo this within a
      // minute and the UI would look broken. Say so, rather than surprise them.
      const extra = to ? '' : '\n\nIt will also be excluded from auto-enrolment, so the sweep will not add it back.';
      if (!confirm('Move host ' + guid(h.hostId) + ' to ' + label + '?' + extra)) {
        sel.value = h.pool || '';
        return;
      }
      try {
        Y.clearNotice();
        await Y.mutate('/api/pool/move-host', { method: 'POST', body: { hostId: h.hostId, poolId: to } });
        await load();
      } catch (e) {
        sel.value = h.pool || '';
        Y.notice('error', e.message);
      }
    });

    const control = Y.el('span', { text: h.control, title: CONTROL_HINT[h.control] || '' });
    return Y.el('tr', {}, [
      Y.el('td', {}, [Y.hostLink(h.hostId, h.pool, goBaseUrl)]),
      Y.el('td', {}, [control]),
      Y.el('td', {}, [accessCell(h.access)]),
      Y.el('td', {}, [sel])
    ]);
  }

  async function load() {
    try {
      const d = await Y.api('/api/hosts');
      chrome.markLoaded();
      // Memoized and non-rejecting, so this is one read for the life of the page
      // and an aggregator this daemon does not know about just means unlinked ids.
      goBaseUrl = (await Y.hostInfo()).goBaseUrl || '';
      pools = d.pools || [];
      targetPoolId = d.targetPoolId || '';
      const body = document.getElementById('host-rows');
      body.textContent = '';
      for (const h of (d.hosts || [])) body.appendChild(rowEl(h));
      if (d.statusError) {
        Y.notice('warn', 'Aggregator unavailable (' + d.statusError + '); control state and project access are unknown. Moving hosts still works.');
      } else {
        Y.clearNotice();
      }
    } catch (e) {
      Y.notice('error', e.message);
    }
  }

  document.getElementById('refresh').addEventListener('click', load);
  // Header version + host id and the footer bar; its countdown re-reads the host
  // list rather than reloading, so a pending pool choice in a row survives.
  const chrome = Y.initChrome({ refresh: load });
  load();
})();
