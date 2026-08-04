// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Diagnostics view. Renders the report even when checks fail -- this is the one
// page that has to work while the service is broken.
(function () {
  // Deliberately NOT Y.api: that helper treats {ok:false} as a thrown error,
  // which is the normal payload here (a report of failing checks). Fetch the
  // JSON directly and let the table show the failures.
  async function load() {
    Y.clearNotice();
    const res = await fetch('/api/diagnostics', { headers: { 'Accept': 'application/json' } });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return res.json();
  }

  function summary(d) {
    const box = Y.el('div', { class: 'notice ' + (d.ok ? 'ok' : 'error') });
    box.textContent = d.ok
      ? 'All checks passed. pool-control-service ' + d.version + ' (' + d.go + '), collected ' + d.collectedAt
      : (d.checks.filter(c => !c.ok).length + ' of ' + d.checks.length + ' checks failing. pool-control-service '
         + d.version + ' (' + d.go + '), collected ' + d.collectedAt);
    box.style.display = 'block';
    return box;
  }

  function checkRow(c) {
    return Y.el('tr', null, [
      Y.el('td', null, Y.el('code', { text: c.name })),
      Y.el('td', { class: c.ok ? 'ok' : 'error', text: c.ok ? 'PASS' : 'FAIL' }),
      Y.el('td', null, Y.el('pre', { class: 'detail', text: c.detail || '' })),
      Y.el('td', { class: 'muted', text: c.hint || '' })
    ]);
  }

  function envRow(label, value) {
    return Y.el('tr', null, [
      Y.el('th', { text: label }),
      Y.el('td', null, Y.el('code', { text: (value === '' || value === undefined || value === null) ? '(empty)' : String(value) }))
    ]);
  }

  // Stream bodies keep their newlines, so render them in a <pre> rather than
  // the single-line <code> the scalar rows use.
  function streamRow(label, value) {
    return Y.el('tr', null, [
      Y.el('th', { text: label }),
      Y.el('td', null, Y.el('pre', { class: 'detail', text: (value === '' || value === undefined || value === null) ? '(empty)' : String(value) }))
    ]);
  }

  function render(d) {
    const sum = document.getElementById('summary');
    sum.textContent = '';
    sum.appendChild(summary(d));

    const rows = document.getElementById('check-rows');
    rows.textContent = '';
    for (const c of d.checks || []) rows.appendChild(checkRow(c));

    const p = d.intentProbe || {};
    const probe = document.getElementById('probe-rows');
    probe.textContent = '';
    probe.appendChild(streamRow('argv', (p.argv || []).join('  ')));
    probe.appendChild(envRow('exit code', p.exitCode));
    probe.appendChild(envRow('duration', p.duration));
    probe.appendChild(streamRow('stdout', p.stdout));
    probe.appendChild(streamRow('stderr', p.stderr));

    const e = d.environment || {};
    const env = document.getElementById('env-rows');
    env.textContent = '';
    env.appendChild(envRow('pwsh (--pwsh flag)', e.pwshFlag));
    env.appendChild(envRow('pwsh (resolved)', e.pwshResolved));
    env.appendChild(envRow('repo dir', e.repoDir));
    env.appendChild(envRow('framework version', e.frameworkVersion));
    env.appendChild(envRow('framework revision', e.frameworkRevision));
    env.appendChild(envRow('state dir', e.stateDir));
    env.appendChild(envRow('intent git URL', e.intentGitUrl));
    env.appendChild(envRow('aggregator URL', e.aggregatorUrl));
    env.appendChild(envRow('host id', e.hostId));
    env.appendChild(envRow('service user', e.user));
    env.appendChild(envRow('PATH', e.path));
    env.appendChild(envRow('HOME', e.home));

    const rt = d.runtime || {};
    const rtRows = document.getElementById('runtime-rows');
    rtRows.textContent = '';
    rtRows.appendChild(envRow('version', d.version));
    rtRows.appendChild(envRow('go', d.go));
    rtRows.appendChild(envRow('platform', (rt.os || '') + '/' + (rt.arch || '')));
    rtRows.appendChild(envRow('pid', rt.pid));
    rtRows.appendChild(envRow('listen addr', rt.listenAddr));
    rtRows.appendChild(envRow('started at', rt.startedAt));
    rtRows.appendChild(envRow('uptime', rt.uptime));

    const health = document.getElementById('health');
    health.textContent = d.health ? JSON.stringify(d.health, null, 2) : '(persistence disabled)';
  }

  async function refresh() {
    try {
      render(await load());
      chrome.markLoaded();
    } catch (err) {
      Y.notice('error', 'Could not collect diagnostics: ' + err.message);
    }
  }

  document.getElementById('refresh').addEventListener('click', refresh);
  // Header version + host id and the footer bar. Re-running the checks is this
  // page's refresh -- it is the page an operator leaves open during an outage,
  // so the countdown re-probes rather than reloading.
  const chrome = Y.initChrome({ refresh: refresh });
  refresh();
})();
