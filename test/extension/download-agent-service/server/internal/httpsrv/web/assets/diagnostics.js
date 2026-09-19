// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// Diagnostics page: renders /api/v1/diagnostics and drives the gated resolver
// test. All data lands via textContent (Y.el) -- captured child-process output
// is untrusted display text, never markup.
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var labTokenGate = false;
  var gateConfigured = false;

  var chrome = Y.initChrome({ intervalSeconds: 60, refresh: load, refreshOnVisible: true });

  var setCard = function (id, value, sub) {
    $(id).textContent = value || '--';
    $(id + '-sub').textContent = sub || '';
  };

  var badge = function (state, text) {
    return Y.el('span', { class: 'badge ' + state, text: text });
  };

  // renderAttempt shows one captured Fido run: verdict line, error, argv and
  // both streams. Shared by "last resolver run" (from the report) and the test
  // button (from its response), so the two always read the same way.
  var renderAttempt = function (container, at) {
    container.textContent = '';
    if (!at) {
      container.appendChild(Y.el('p', { class: 'muted', text: window.YurunaI18n.t("download.no_resolver_run_recorded_since_the_daemon_started_a_scan_a_host_r") }));
      return;
    }
    var ok = !at.error;
    var facts = [];
    if (at.atUtc) facts.push(Y.stamp(at.atUtc));
    facts.push(window.YurunaI18n.t('download.attempt_arch', {value: at.arch || '?'}));
    facts.push(window.YurunaI18n.t('download.attempt_exit', {value: at.exitCode}));
    facts.push(Math.round((at.durationMs || 0) / 1000) + 's');
    if (at.timedOut) facts.push('timed out');
    container.appendChild(Y.el('p', null, [
      badge(ok ? 'fresh' : 'failed', ok ? 'succeeded' : 'failed'),
      ' ',
      Y.el('span', { class: 'muted', text: facts.join(' -- ') })
    ]));
    if (at.error) container.appendChild(Y.el('p', { class: 'err-line', text: at.error }));
    if (at.url) container.appendChild(Y.el('p', {text: window.YurunaI18n.t('download.minted_url', {url: at.url})}));
    if (at.argv && at.argv.length) container.appendChild(Y.el('pre', { class: 'console', tabindex: '0', role: 'region', 'aria-label': window.YurunaI18n.t("download.command_line"), text: window.YurunaI18n.t("download.argv_value1", {value1: (at.argv.join(' '))}) }));
    if (at.stdout) {
      container.appendChild(Y.el('h3', { text: window.YurunaI18n.t("download.stdout") }));
      container.appendChild(Y.el('pre', { class: 'console', tabindex: '0', role: 'region', 'aria-label': window.YurunaI18n.t("download.standard_output"), text: at.stdout }));
    }
    if (at.stderr) {
      container.appendChild(Y.el('h3', { text: window.YurunaI18n.t("download.stderr") }));
      container.appendChild(Y.el('pre', { class: 'console', tabindex: '0', role: 'region', 'aria-label': window.YurunaI18n.t("download.standard_error"), text: at.stderr }));
    }
  };

  var renderErrors = function (list) {
    var body = $('error-rows');
    body.textContent = '';
    var rows = list || [];
    $('no-errors').hidden = rows.length > 0;
    for (var i = 0; i < rows.length; i++) {
      var e = rows[i];
      body.appendChild(Y.el('tr', null, [
        Y.el('td', { class: 'mono', text: e.key }),
        Y.el('td', null, [Y.el('span', { class: 'err-line', text: e.error })]),
        Y.el('td', { text: Y.stamp(e.atUtc) })
      ]));
    }
  };

  function load() {
    return Y.api('/api/v1/diagnostics').then(function (d) {
      paint(d.diagnostics || {});
    }, function (e) {
      Y.notice('error', window.YurunaI18n.t("download.diagnostics_load_failed_value1", {value1: (e.message)}));
      window.YurunaFirstUsable.mark('test/extension/download-agent-service/server/internal/httpsrv/web/diagnostics.html', 'error');
    });
  }

  function paint(g) {
    return window.YurunaFirstUsable.measure("test/extension/download-agent-service/server/internal/httpsrv/web/diagnostics.html", "data", function () { return paintMeasured(g); });
  }


  function paintMeasured(g) {
    var best = g.bestEffort || [];
    var fam = null;
    for (var i = 0; i < best.length; i++) {
      if (best[i].imageKey === 'guest.windows.11') { fam = best[i]; break; }
    }
    var sub;
    if (fam && fam.available) {
      sub = window.YurunaI18n.t("download.interpreter_and_script_present_resolves_are_attempted");
      setCard('dg-family', window.YurunaI18n.t("download.available"), sub);
    } else {
      // The remembered failure carries the retry horizon the reason alone does
      // not: the family re-arms itself when the TTL runs out.
      sub = fam ? (fam.reason || '') : '';
      if (g.rememberedFailure && g.rememberedFailure.expiresUtc) {
        sub += ' — ' + window.YurunaI18n.t('download.retries_after', {time: Y.stamp(g.rememberedFailure.expiresUtc)});
      }
      setCard('dg-family', window.YurunaI18n.t("download.unavailable"), sub);
    }

    var it = g.interpreter || {};
    if (it.error) { setCard('dg-pwsh', window.YurunaI18n.t("download.missing"), it.error); }
    else { setCard('dg-pwsh', it.version || window.YurunaI18n.t("download.found"), it.resolvedPath || ''); }

    var sc = g.script || {};
    if (sc.error) { setCard('dg-script', window.YurunaI18n.t("download.missing"), sc.error); }
    else { setCard('dg-script', (sc.sha256 || '').slice(0, 12) || window.YurunaI18n.t("download.found"), sc.path + (sc.sizeBytes ? ' -- ' + Y.bytes(sc.sizeBytes) : '')); }

    setCard('dg-os', g.os || (g.goos || '?'), ("" + ((g.kernel ? 'kernel ' + g.kernel + ' -- ' : '') + (g.goos || '')) + "/" + (g.goarch || '') + ""));

    if (g.proxyHttp || g.proxyHttps) {
      setCard('dg-proxy', window.YurunaI18n.t("download.configured"), [g.proxyHttp, g.proxyHttps].filter(Boolean).join(' - ') + (g.proxyCaSet ? '' : ' -- no CA'));
    } else {
      setCard('dg-proxy', window.YurunaI18n.t("download.none"), window.YurunaI18n.t("download.byte_downloads_go_direct"));
    }

    setCard('dg-pool', g.poolAvailable ? window.YurunaI18n.t("download.available") : window.YurunaI18n.t("download.unavailable"), g.poolDir || '');

    renderAttempt($('attempt'), g.lastFidoAttempt);
    renderErrors(g.recentErrors);
    $('as-of').textContent = g.asOfUtc ? window.YurunaI18n.t("download.as_of_value1", {value1: (Y.stamp(g.asOfUtc))}) : '';
    chrome.markLoaded();
    window.YurunaFirstUsable.mark('test/extension/download-agent-service/server/internal/httpsrv/web/diagnostics.html', 'data');
  }

  // --- REGION: Resolver test
  var setTesting = function (busy) {
    $('test-amd64').disabled = busy;
    $('test-arm64').disabled = busy;
    $('test-running').hidden = !busy;
  };

  // Raw fetch, not Y.api: a failed ATTEMPT answers ok:false with the capture
  // attached, and that capture is exactly what this page exists to show.
  function runTest(arch) {
    Y.clearNotice();
    setTesting(true);
    var finish = function () { setTesting(false); };
    return window.fetch('/api/v1/diagnostics/fido-test?arch=' + encodeURIComponent(arch), { method: 'POST' })
      .then(function (res) {
        if (res.status === 401) {
          Y.notice('error', window.YurunaI18n.t("download.unlock_actions_first_enter_the_lab_token_above"));
          return null;
        }
        return res.json().then(function (d) { return d; }, function () { return {}; })
          .then(function (data) {
            data = data || {};
            if (!res.ok && !data.attempt) {
              Y.notice('error', window.YurunaI18n.t("download.resolver_test_refused_value1", {value1: (data.error || data.reason || ('HTTP ' + res.status))}));
              return null;
            }
            renderAttempt($('test-result'), data.attempt);
            if (data.ok) { Y.notice('ok', window.YurunaI18n.t("download.resolve_succeeded_the_family_is_usable_on_this_agent")); }
            else { Y.notice('error', window.YurunaI18n.t("download.resolve_failed_the_capture_below_says_why")); }
            // The family card may have flipped either way; re-read the report.
            return load();
          });
      }, function (e) {
        Y.notice('error', window.YurunaI18n.t("download.resolver_test_failed_to_run_value1", {value1: (e.message)}));
      }).then(finish, finish);
  }
  $('test-amd64').addEventListener('click', function () { runTest('amd64'); });
  $('test-arm64').addEventListener('click', function () { runTest('arm64'); });

  // --- REGION: Session
  function loadSession() {
    return Y.proofUnlock.then(function () {
      return Y.api('/api/session');
    }).then(function (s) {
      gateConfigured = !!s.configured;
      labTokenGate = !!s.labToken;
      $('login').hidden = !(labTokenGate && !s.authed);
      $('gate-unconfigured').hidden = gateConfigured;
    }, function () {
      // A gate this page cannot vouch for offers no control it cannot back.
      gateConfigured = false;
      labTokenGate = false;
    });
  }

  $('login-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    var field = $('lab-token');
    var err = $('login-error');
    err.textContent = '';
    Y.api('/api/login', { method: 'POST', body: { labToken: field.value.trim().toLowerCase() } }).then(function () {
      field.value = '';
      return loadSession();
    }, function (e) {
      err.textContent = e.message;
    });
  });

  window.YurunaFirstUsable.hold('session');
  loadSession().then(function () { window.YurunaFirstUsable.release('session'); });
  load();
})();
