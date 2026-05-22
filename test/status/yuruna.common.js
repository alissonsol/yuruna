/*
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.05.22

  Shared helpers for the Yuruna status pages. Mounted on window.Yuruna.
  --- See https://yuruna.link/definition#defining-the-status-page-browser-baseline
  --- See https://yuruna.link/definition#defining-the-status-page-hostinfo-aggregator
*/
(function() {
  'use strict';

  var VERSION = '2026.05.22';

  // fetch shim for Safari iOS 9.x.
  if (!window.fetch) {
    window.fetch = function(url, options) {
      options = options || {};
      return new Promise(function(resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open(options.method || 'GET', url, true);
        var headers = options.headers;
        if (headers) {
          for (var k in headers) {
            if (Object.prototype.hasOwnProperty.call(headers, k)) {
              xhr.setRequestHeader(k, headers[k]);
            }
          }
        }
        xhr.onload = function() {
          var responseText = xhr.responseText;
          resolve({
            ok: xhr.status >= 200 && xhr.status < 300,
            status: xhr.status,
            statusText: xhr.statusText,
            text: function() { return Promise.resolve(responseText); },
            json: function() {
              return new Promise(function(res, rej) {
                try { res(JSON.parse(responseText)); }
                catch (e) { rej(e); }
              });
            }
          });
        };
        xhr.onerror = function() { reject(new Error('Network error')); };
        xhr.send(options.body || null);
      });
    };
  }

  // ── Generic utilities ──

  function safeWarn(msg, err) {
    if (window.console && console.warn) {
      console.warn(msg, err && err.message ? err.message : err);
    }
  }

  function escHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  var STATUS_CLASSES = ['idle','running','pass','fail','skipped','pending','paused','stopped'];
  function cls(status) {
    return STATUS_CLASSES.indexOf(status) !== -1 ? status : 'idle';
  }

  function badge(status, label) {
    return '<span class="badge ' + cls(status) + '">' + (label || status) + '</span>';
  }

  // ISO -> short localized date+time. Returns "—" for falsy/unparseable
  // input. dateStyle/timeStyle are ES2020 (Safari 14.1+); iOS 9 ignores
  // them per ECMA-402 and falls back to the longer default.
  function fmtDate(iso) {
    if (!iso) return '—';
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '—';
    try { return d.toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' }); }
    catch (e) { return d.toLocaleString(); }
  }

  function fmtDuration(a, b) {
    if (!a || !b) return '—';
    var s = Math.round((new Date(b) - new Date(a)) / 1000);
    if (s < 0) return '—';
    var m = Math.floor(s / 60);
    var r = s % 60;
    if (m) return r ? (m + 'm ' + r + 's') : (m + 'm');
    return s + 's';
  }

  // ── HostInfo: single aggregated fetch of every host-level datum every
  // page needs. Cached for the page's lifetime; multiple consumers share
  // the same Promise (one round-trip per source, regardless of how many
  // helpers ask).
  // --- See https://yuruna.link/definition#defining-the-status-page-hostinfo-aggregator

  function fetchText(url) {
    return fetch(url + '?_=' + Date.now(), { cache: 'no-store' })
      .then(function(res) { return res.ok ? res.text() : ''; })
      ['catch'](function() { return ''; });
  }
  function fetchJson(url) {
    return fetch(url + '?_=' + Date.now(), { cache: 'no-store' })
      .then(function(res) { return res.ok ? res.json() : null; })
      ['catch'](function() { return null; });
  }

  function buildHostInfo(statusDoc, versionRaw, ipRaw) {
    var info = {
      repoName:    null,
      version:     null,
      hostname:    window.location.hostname || '',
      host:        null,
      ipAddresses: null
    };
    if (statusDoc) {
      if (statusDoc.hostname) info.hostname = statusDoc.hostname;
      if (statusDoc.host)     info.host     = statusDoc.host.replace(/^host\./, '');
      if (statusDoc.repoUrl) {
        var url = String(statusDoc.repoUrl).split(/[?#]/)[0]
                    .replace(/\.git$/i, '').replace(/\/+$/, '');
        var last = url.split('/').pop();
        if (last) info.repoName = last.charAt(0).toUpperCase() + last.slice(1);
      }
    }
    if (versionRaw) {
      var v = versionRaw.split(/\r?\n/)[0].replace(/^\s+|\s+$/g, '');
      if (v) info.version = v;
    }
    if (ipRaw) info.ipAddresses = ipRaw.replace(/\s+$/, '') || null;
    return info;
  }

  var _hostInfoPromise = null;
  function getHostInfo() {
    if (_hostInfoPromise) return _hostInfoPromise;
    _hostInfoPromise = Promise.all([
      fetchJson('runtime/status.json'),
      fetchText('yuruna-repo/VERSION'),
      fetchText('runtime/ipaddresses.txt')
    ]).then(function(r) { return buildHostInfo(r[0], r[1], r[2]); });
    return _hostInfoPromise;
  }

  // ── Header helpers ──
  // --- See https://yuruna.link/definition#defining-the-status-page-header-anatomy

  function appendHmStack(parentEl, name, host) {
    var stack = document.createElement('span');
    stack.className = 'hm-stack';
    var nameLink = document.createElement('a');
    nameLink.className = 'hm-name';
    nameLink.href = 'hostinfo.html';
    nameLink.title = 'Host diagnostic';
    nameLink.textContent = name;
    stack.appendChild(nameLink);
    if (host) {
      var hostSpan = document.createElement('span');
      hostSpan.className = 'hm-host';
      hostSpan.textContent = '(' + host + ')';
      stack.appendChild(hostSpan);
    }
    parentEl.appendChild(stack);
    return stack;
  }

  // Rebuild #header-machine: hm-stack + a sibling CTA. textContent is
  // wiped first so callers can invoke this on every poll without leaking
  // duplicate children.
  function renderHeaderMachine(el, name, host, cta) {
    el.textContent = '';
    appendHmStack(el, name, host);
    if (cta && cta.href && cta.label) {
      var a = document.createElement('a');
      a.className = 'header-cta';
      a.href = cta.href;
      a.textContent = cta.label;
      if (cta.title) a.title = cta.title;
      el.appendChild(a);
    }
  }

  // One-shot: read HostInfo and populate every header field.
  function populateHeader(cta) {
    return getHostInfo().then(function(info) {
      var titleEl = document.getElementById('header-title');
      if (titleEl && info.repoName) titleEl.textContent = info.repoName;
      var versionEl = document.getElementById('header-version');
      if (versionEl && info.version) versionEl.textContent = 'v' + info.version;
      var machineEl = document.getElementById('header-machine');
      if (machineEl) renderHeaderMachine(machineEl, info.hostname, info.host || '', cta);
      return info;
    });
  }

  window.Yuruna = {
    version:             VERSION,
    safeWarn:            safeWarn,
    escHtml:             escHtml,
    cls:                 cls,
    badge:               badge,
    fmtDate:             fmtDate,
    fmtDuration:         fmtDuration,
    getHostInfo:         getHostInfo,
    appendHmStack:       appendHmStack,
    renderHeaderMachine: renderHeaderMachine,
    populateHeader:      populateHeader
  };
})();
