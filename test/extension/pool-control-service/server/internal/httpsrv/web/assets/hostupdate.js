// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 425e9804-4c09-4b5a-90ba-5e49cd286e74
//
// Host update confirmation. Only host and scope are read from the URL; the
// request id, the address and the page to return to all come from this
// service, so a link cannot choose what is signed or where the operator lands.
// Nothing is written with innerHTML.
(function () {
  var PAGE = 'test/extension/pool-control-service/server/internal/httpsrv/web/hostupdate.html';
  var CREDENTIAL_HEADER = 'X-Yuruna-Operator-Credential';
  var DRAIN_NOW_COMMAND = 'pwsh test/lab/Invoke-HostUpdate.ps1';
  function $(id) { return document.getElementById(id); }
  function t(key, args) { return window.YurunaI18n.t(key, args || null); }

  // The two query values, parsed by hand: the browser baseline does not carry
  // URLSearchParams everywhere.
  function query() {
    var out = {};
    var raw = String(window.location.search || '').replace(/^\?/, '');
    raw.split('&').forEach(function (pair) {
      var eq = pair.indexOf('=');
      if (eq < 1) { return; }
      var name = pair.slice(0, eq);
      if (name !== 'host' && name !== 'scope') { return; }
      try { out[name] = decodeURIComponent(pair.slice(eq + 1).replace(/\+/g, ' ')); } catch (e) { /* ignored */ }
    });
    return out;
  }

  var prepared = null;
  var sent = false;

  function setStatus(text) { $('status').textContent = text || ''; }

  // The page to return to is built by this service from the address the
  // aggregator reports; it is still checked here, because it reaches an href.
  function safeDiagnosticsUrl(u) {
    var a = document.createElement('a');
    a.href = String(u || '');
    return (a.protocol === 'http:' || a.protocol === 'https:') ? a.href : '';
  }

  function render(d) {
    prepared = d;
    $('field-host').textContent = Y.guid(d.hostId);
    $('field-address').textContent = Y.bidiIsolate(String(d.address || ''));
    $('field-type').textContent = String(d.hostType || '-');
    $('field-scope').textContent = t('pool.host_update_scope', { scope: String(d.scope) });
    $('field-drain').textContent = t('pool.host_update_drain_value', { seconds: d.drainSeconds, minutes: Math.round(d.drainSeconds / 60) });
    $('field-commit').textContent = d.expectCommit ? String(d.expectCommit) : t('pool.none');
    $('field-request').textContent = String(d.requestId);
    $('field-drain-now').textContent = DRAIN_NOW_COMMAND + ' -Scope ' + d.scope + ' -Drain now';
    $('update-form').hidden = false;
    if (!d.offer) {
      $('submit').disabled = true;
      Y.notice('error', t('pool.host_update_not_offered', { hostId: Y.guid(d.hostId), reason: String(d.reason || '') }));
    }
    window.YurunaFirstUsable.mark(PAGE, 'data');
  }

  function load() {
    var q = query();
    setStatus(t('pool.host_update_loading'));
    var path = '/api/host/update?host=' + encodeURIComponent(q.host || '') + '&scope=' + encodeURIComponent(q.scope || '');
    return Y.api(path, { timeoutMs: 30000 }).then(function (d) {
      setStatus('');
      render(d);
    }, function (e) {
      setStatus('');
      Y.notice('error', e.message);
      window.YurunaFirstUsable.mark(PAGE, 'error');
    });
  }

  // One POST under one request id. A lab gate refusal prompts for the Lab
  // token and sends the same request again; an operator credential refusal
  // does not, because the Lab token cannot fix it.
  function post(credential) {
    var headers = {};
    headers[CREDENTIAL_HEADER] = credential;
    var send = function () {
      return Y.api('/api/host/update', {
        method: 'POST', timeoutMs: 30000, headers: headers,
        body: { hostId: prepared.hostId, requestId: prepared.requestId, scope: prepared.scope, drainSeconds: prepared.drainSeconds }
      });
    };
    return send().then(null, function (e) {
      if (e.status !== 401 || e.reason === 'operator_credential_required') { throw e; }
      return Y.unlock().then(function (ok) {
        if (!ok) { throw e; }
        return send();
      });
    });
  }

  function accepted(d) {
    sent = true;
    $('submit').disabled = true;
    var target = safeDiagnosticsUrl(d.diagnosticsUrl);
    var text = d.replay ?
      t('pool.host_update_completed', { hostId: Y.guid(d.hostId), requestId: d.requestId, verdict: String(d.verdict || '') }) :
      t('pool.host_update_sent', { hostId: Y.guid(d.hostId), requestId: d.requestId });
    Y.notice('ok', text);
    if (!target) { return; }
    $('diagnostics-link').href = target;
    $('diagnostics-link-row').hidden = false;
    if (!d.replay) { window.location.assign(target); }
  }

  $('update-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    if (!prepared || sent || !prepared.offer) { return; }
    var credential = String($('credential').value || '').replace(/^\s+|\s+$/g, '');
    if (!credential) {
      Y.notice('error', t('pool.host_update_credential_missing'));
      return;
    }
    Y.clearNotice();
    $('submit').disabled = true;
    setStatus(t('pool.host_update_sending'));
    post(credential).then(function (d) {
      setStatus('');
      accepted(d);
    }, function (e) {
      setStatus('');
      $('submit').disabled = false;
      var body = e.body || {};
      var reason = body.hostReason ? ' (' + Y.bidiIsolate(String(body.hostReason)) + ')' : '';
      Y.notice('error', e.message + reason);
    });
  });

  // The countdown never runs out here: a refresh mints a new request id, so
  // it happens only when the operator asks for one.
  Y.initChrome({ refreshOnVisible: false, paused: function () { return true; } });
  Y.ready().then(load, load);
})();
