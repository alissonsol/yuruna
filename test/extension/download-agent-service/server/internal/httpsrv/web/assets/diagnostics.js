// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Diagnostics page: renders /api/v1/diagnostics and drives the gated resolver
// test. All data lands via textContent (Y.el) -- captured child-process output
// is untrusted display text, never markup.
(function () {
  const $ = function (id) { return document.getElementById(id); };
  let labTokenGate = false;
  let gateConfigured = false;

  const chrome = Y.initChrome({ intervalSeconds: 60, refresh: load, refreshOnVisible: true });

  const setCard = function (id, value, sub) {
    $(id).textContent = value || '—';
    $(id + '-sub').textContent = sub || '';
  };

  const badge = function (state, text) {
    return Y.el('span', { class: 'badge ' + state, text: text });
  };

  // renderAttempt shows one captured Fido run: verdict line, error, argv and
  // both streams. Shared by "last resolver run" (from the report) and the test
  // button (from its response), so the two always read the same way.
  const renderAttempt = function (container, at) {
    container.textContent = '';
    if (!at) {
      container.appendChild(Y.el('p', { class: 'muted', text: 'No resolver run recorded since the daemon started. A scan, a host request, or the test button above will record one.' }));
      return;
    }
    const ok = !at.error;
    const facts = [];
    if (at.atUtc) facts.push(Y.stamp(at.atUtc));
    facts.push('arch ' + (at.arch || '?'));
    facts.push('exit ' + at.exitCode);
    facts.push(Math.round((at.durationMs || 0) / 1000) + 's');
    if (at.timedOut) facts.push('timed out');
    container.appendChild(Y.el('p', null, [
      badge(ok ? 'fresh' : 'failed', ok ? 'succeeded' : 'failed'),
      ' ',
      Y.el('span', { class: 'muted', text: facts.join(' — ') })
    ]));
    if (at.error) container.appendChild(Y.el('p', { class: 'err-line', text: at.error }));
    if (at.url) container.appendChild(Y.el('p', null, ['Minted: ', Y.el('code', { text: at.url })]));
    if (at.argv && at.argv.length) container.appendChild(Y.el('pre', { class: 'console', text: 'argv: ' + at.argv.join(' ') }));
    if (at.stdout) {
      container.appendChild(Y.el('h3', { text: 'stdout' }));
      container.appendChild(Y.el('pre', { class: 'console', text: at.stdout }));
    }
    if (at.stderr) {
      container.appendChild(Y.el('h3', { text: 'stderr' }));
      container.appendChild(Y.el('pre', { class: 'console', text: at.stderr }));
    }
  };

  const renderErrors = function (list) {
    const body = $('error-rows');
    body.textContent = '';
    const rows = list || [];
    $('no-errors').hidden = rows.length > 0;
    for (const e of rows) {
      body.appendChild(Y.el('tr', null, [
        Y.el('td', { class: 'mono', text: e.key }),
        Y.el('td', null, [Y.el('span', { class: 'err-line', text: e.error })]),
        Y.el('td', { text: Y.stamp(e.atUtc) })
      ]));
    }
  };

  async function load() {
    let d;
    try {
      d = await Y.api('/api/v1/diagnostics');
    } catch (e) {
      Y.notice('error', 'Diagnostics load failed: ' + e.message);
      return;
    }
    const g = d.diagnostics || {};

    const fam = (g.bestEffort || []).find(function (f) { return f.imageKey === 'guest.windows.11'; });
    if (fam && fam.available) {
      let sub = 'Interpreter and script present; resolves are attempted.';
      setCard('dg-family', 'available', sub);
    } else {
      // The remembered failure carries the retry horizon the reason alone
      // does not: the family re-arms itself when the TTL runs out.
      let sub = fam ? (fam.reason || '') : '';
      if (g.rememberedFailure && g.rememberedFailure.expiresUtc) {
        sub += ' — retries after ' + Y.stamp(g.rememberedFailure.expiresUtc);
      }
      setCard('dg-family', 'unavailable', sub);
    }

    const it = g.interpreter || {};
    if (it.error) setCard('dg-pwsh', 'missing', it.error);
    else setCard('dg-pwsh', it.version || 'found', it.resolvedPath || '');

    const sc = g.script || {};
    if (sc.error) setCard('dg-script', 'missing', sc.error);
    else setCard('dg-script', (sc.sha256 || '').slice(0, 12) || 'found', sc.path + (sc.sizeBytes ? ' — ' + Y.bytes(sc.sizeBytes) : ''));

    setCard('dg-os', g.os || (g.goos || '?'), (g.kernel ? 'kernel ' + g.kernel + ' — ' : '') + (g.goos || '') + '/' + (g.goarch || ''));

    if (g.proxyHttp || g.proxyHttps) {
      setCard('dg-proxy', 'configured', [g.proxyHttp, g.proxyHttps].filter(Boolean).join(' · ') + (g.proxyCaSet ? '' : ' — no CA'));
    } else {
      setCard('dg-proxy', 'none', 'Byte downloads go direct.');
    }

    setCard('dg-pool', g.poolAvailable ? 'available' : 'unavailable', g.poolDir || '');

    renderAttempt($('attempt'), g.lastFidoAttempt);
    renderErrors(g.recentErrors);
    $('as-of').textContent = g.asOfUtc ? 'As of ' + Y.stamp(g.asOfUtc) : '';
    chrome.markLoaded();
  }

  // --- resolver test --------------------------------------------------------

  const setTesting = function (busy) {
    $('test-amd64').disabled = busy;
    $('test-arm64').disabled = busy;
    $('test-running').hidden = !busy;
  };

  // Raw fetch, not Y.api: a failed ATTEMPT answers ok:false with the capture
  // attached, and that capture is exactly what this page exists to show.
  async function runTest(arch) {
    Y.clearNotice();
    setTesting(true);
    try {
      const res = await fetch('/api/v1/diagnostics/fido-test?arch=' + encodeURIComponent(arch), { method: 'POST' });
      if (res.status === 401) {
        Y.notice('error', 'Unlock actions first — enter the Lab token above.');
        return;
      }
      let data = {};
      try { data = await res.json(); } catch (e) { /* non-JSON */ }
      if (!res.ok && !data.attempt) {
        Y.notice('error', 'Resolver test refused: ' + (data.error || data.reason || ('HTTP ' + res.status)));
        return;
      }
      renderAttempt($('test-result'), data.attempt);
      if (data.ok) Y.notice('ok', 'Resolve succeeded — the family is usable on this agent.');
      else Y.notice('error', 'Resolve failed — the capture below says why.');
      // The family card may have flipped either way; re-read the report.
      await load();
    } catch (e) {
      Y.notice('error', 'Resolver test failed to run: ' + e.message);
    } finally {
      setTesting(false);
    }
  }
  $('test-amd64').addEventListener('click', function () { runTest('amd64'); });
  $('test-arm64').addEventListener('click', function () { runTest('arm64'); });

  // --- session --------------------------------------------------------------

  async function loadSession() {
    try {
      await Y.proofUnlock;
      const s = await Y.api('/api/session');
      gateConfigured = !!s.configured;
      labTokenGate = !!s.labToken;
      $('login').hidden = !(labTokenGate && !s.authed);
      $('gate-unconfigured').hidden = gateConfigured;
    } catch (e) {
      gateConfigured = false;
      labTokenGate = false;
    }
  }

  $('login-form').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    const field = $('lab-token');
    const err = $('login-error');
    err.textContent = '';
    try {
      await Y.api('/api/login', { method: 'POST', body: { labToken: field.value.trim().toLowerCase() } });
      field.value = '';
      await loadSession();
    } catch (e) {
      err.textContent = e.message;
    }
  });

  loadSession();
  load();
})();
