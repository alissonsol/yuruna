/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.07.17

  Shared helpers for the Yuruna status pages. Mounted on window.Yuruna.
  --- REGION: https://yuruna.link/definition#defining-the-status-page-browser-baseline
  --- REGION: https://yuruna.link/definition#defining-the-status-page-hostinfo-aggregator
*/
(function() {
  'use strict';

  var VERSION = '2026.07.17';

  // --- REGION: control-route auth (proof from the Caching Proxy /go/host redirect)
  // A Grafana deep-link routes through the Caching Proxy's /go/host, which appends a
  // short-lived HMAC control proof in the URL FRAGMENT (#yctl=<expiry>.<proof>). Capture
  // it once, stash it in sessionStorage, and strip it from the address bar so the proof is
  // not shoulder-surfed or copy-pasted out of the URL. The mutating /control/* POSTs then
  // present it in the X-Yuruna-Control header; the host verifies it (or accepts loopback).
  // Read routes are unaffected. ES5 only (iOS 9.x baseline). No proof -> loopback only.
  (function() {
    try {
      var m = (window.location.hash || '').match(/(?:^#|[#&])yctl=([^&]+)/);
      if (m && m[1]) {
        window.sessionStorage.setItem('yurunaCtl', m[1]);
        if (window.history && window.history.replaceState) {
          window.history.replaceState(null, document.title, window.location.pathname + window.location.search);
        }
      }
    } catch (e) { /* sessionStorage / history unavailable -> no proof; loopback still works */ }
  })();

  // Request headers for a control-plane call: the same-origin X-Yuruna marker plus the
  // captured control proof (when present) in X-Yuruna-Control. Pass a base object for the
  // routes that also set Content-Type.
  function yurunaControlHeaders(base) {
    var h = base || {};
    h['X-Yuruna'] = '1';
    var t = '';
    try { t = window.sessionStorage.getItem('yurunaCtl') || ''; } catch (e) { t = ''; }
    if (t) { h['X-Yuruna-Control'] = t; }
    return h;
  }

  // fetch shim for Safari iOS 9.x. (Target support for Yuruna UI).
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

  // Escapes the five HTML-significant characters. Quotes are included so the
  // same helper is safe in attribute context (title="...", href="..."); a value
  // carrying a quote would otherwise break out of the attribute and corrupt the
  // row. &#39; (not &apos;) for the apostrophe so it resolves on legacy parsers.
  function escHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  // Scheme-validate a URL before it is placed in an href/src. escHtml alone
  // stops attribute break-out but not a javascript:/data:/vbscript: payload
  // in status.json / caching-proxy.txt (both host-generated but influenced
  // by guest-supplied names), so a click on a poisoned link would execute.
  // The status pages deep-link almost entirely with DOCUMENT-RELATIVE paths
  // (log/..., index.html, hostinfo.html), so a strict ^https?:// gate would
  // break every results/log link -- instead allow same-origin relative paths
  // and absolute http(s), reject everything else. ES5 only (iOS 9.3 baseline,
  // no URL constructor): returns '' for anything not provably safe so callers
  // fall back to rendering plain text.
  function safeUrl(v) {
    if (v === null || typeof v === 'undefined') { return ''; }
    var s = String(v);
    if (s === '') { return ''; }
    // Detect the scheme on a probe with every char <= space removed:
    // browsers strip TAB/CR/LF (and NUL) from a URL before parsing its
    // scheme, so a raw check would let 'java\tscript:...' through. Stripping
    // is for detection only; the original value is what gets returned.
    var probe = s.replace(/[\s\S]/g, function(c){ return c.charCodeAt(0) > 32 ? c : ''; });
    if (probe === '') { return ''; }
    // Reject protocol-relative (//host) -- inherits the page scheme but points
    // off-origin, which none of our links need.
    if (probe.charAt(0) === '/' && probe.charAt(1) === '/') { return ''; }
    // A leading scheme must be http/https; a colon after only scheme-valid
    // chars signals one. Relative paths (log/..., index.html) have none.
    var schemeMatch = probe.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):/);
    if (schemeMatch) {
      var scheme = schemeMatch[1].toLowerCase();
      if (scheme !== 'http' && scheme !== 'https') { return ''; }
    }
    return s.replace(/^\s+/, '');
  }

  var STATUS_CLASSES = ['idle','running','pass','fail','skipped','pending','paused','stopped'];
  function cls(status) {
    return STATUS_CLASSES.indexOf(status) !== -1 ? status : 'idle';
  }

  function badge(status, label) {
    // cls() already constrains the class attribute to the STATUS_CLASSES
    // whitelist; the visible text is caller-supplied (a status or a label that
    // can originate from guest output on error paths), so escape it for
    // defense-in-depth against HTML injection.
    return '<span class="badge ' + cls(status) + '">' + escHtml(label || status) + '</span>';
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
  // --- REGION: https://yuruna.link/definition#defining-the-status-page-hostinfo-aggregator

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

  // stripCycleFolderSuffix removes the .incomplete / .aborted.<UTC> lifecycle
  // suffix from a cycle-folder URL (preserving a trailing slash) so an in-progress
  // folder URL resolves to its post-rename on-disk path. Shared by the history
  // rows (renderStatus) and the perf deep-links (buildCycleLinks); logFileUrl's
  // bare-anchor variant is intentionally different and is NOT merged here.
  function stripCycleFolderSuffix(u) {
    return u ? u.replace(/\.incomplete(\/?)$/, '$1').replace(/\.aborted\.[^/]+(\/?)$/, '$1') : u;
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
  // --- REGION: https://yuruna.link/definition#defining-the-status-page-header-anatomy

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

  // --- REGION: https://yuruna.link/definition#defining-the-status-page-visibility-aware-polling
  function startVisibilityAwarePolling(opts) {
    opts = opts || {};
    var run = opts.run || function() {};
    var resumed = opts.onResume || function() {};
    var state = { paused: document.hidden, lastSkipped: 0 };
    function handler() {
      if (document.hidden) {
        state.paused = true;
      } else if (state.paused) {
        state.paused = false;
        try { resumed(state); } catch (e) { safeWarn('onResume threw:', e); }
      }
    }
    if (typeof document.addEventListener === 'function') {
      document.addEventListener('visibilitychange', handler, false);
    }
    return {
      // Call from the page's tick. Returns true iff the request was
      // actually issued; false when document.hidden suppressed it.
      tick: function() {
        if (document.hidden) { state.lastSkipped++; return false; }
        try { run(); } catch (e) { safeWarn('poll run threw:', e); }
        return true;
      },
      state: state
    };
  }

  // ── Shared banner helpers (perf.html, hostinfo.html, test.config.html
  // and index.html all share the same banner DOM contract: #banner +
  // #banner-text). The polling-driven banner refresh used by the
  // light-weight pages is consolidated here.

  var BANNER_TEXT = {
    idle:    'No test data available',
    running: 'Test in progress',
    pass:    'All guests operational',
    fail:    'Incident detected — see status',
    stopped: 'Test runner stopped'
  };

  function setBannerText(text) {
    var el = document.getElementById('banner-text');
    if (el) el.textContent = text || '';
  }

  function pauseBannerText(stepPaused, cyclePaused, status, actionData) {
    var stepEffective  = stepPaused &&
      !!(actionData && actionData.line && /Paused \(waiting for resume\)/.test(actionData.line));
    var cycleEffective = cyclePaused && status !== 'running';
    if (stepEffective)  return 'Test paused';
    if (stepPaused)     return 'Test will pause (after current step)';
    if (cycleEffective) return 'Test paused';
    if (cyclePaused)    return 'Test will pause (after current cycle)';
    return null;
  }

  function applyBanner(data, actionData, runnerStatus) {
    var banner = document.getElementById('banner');
    if (!banner) return;
    var runnerStopped = !!(runnerStatus && runnerStatus.running === false);
    var liveCycleId = data && (data.cycleId || data.runId);
    var hasGuests   = !!(data && data.guests && data.guests.length);
    var hasHistory  = !!(data && data.history && data.history.length);
    if (!data || (!liveCycleId && !hasGuests && !hasHistory)) {
      banner.className = runnerStopped ? 'stopped' : 'idle';
      setBannerText(runnerStopped ? BANNER_TEXT.stopped : BANNER_TEXT.idle);
      return;
    }
    var status      = data.overallStatus || 'idle';
    var stepPaused  = !!data.stepPaused;
    var cyclePaused = !!data.cyclePaused;
    var pauseText   = pauseBannerText(stepPaused, cyclePaused, status, actionData);
    var anyPaused   = pauseText !== null;
    if (runnerStopped) {
      banner.className = 'stopped';
      setBannerText(BANNER_TEXT.stopped);
      return;
    }
    banner.className = anyPaused ? 'paused' : cls(status);
    setBannerText(pauseText !== null ? pauseText : (BANNER_TEXT[status] || status));
  }

  function pollBanner() {
    // Three endpoints are independent; Promise.all parallelizes the
    // round-trips so a 60 s banner poll pays one RTT, not three.
    Promise.all([
      fetchJson('runtime/status.json'),
      fetchJson('runtime/current-action.json'),
      fetchJson('control/runner-status')
    ]).then(function(results) {
      applyBanner(results[0], results[1], results[2]);
    });
  }

  function startBannerPolling() {
    pollBanner();
    setInterval(pollBanner, 60000);
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
    populateHeader:      populateHeader,
    startVisibilityAwarePolling: startVisibilityAwarePolling,
    BANNER_TEXT:         BANNER_TEXT,
    setBannerText:       setBannerText,
    pauseBannerText:     pauseBannerText,
    applyBanner:         applyBanner,
    pollBanner:          pollBanner,
    startBannerPolling:  startBannerPolling
  };

  // ── Per-page bootstrap dispatch ────────────────────────────────────
  // Each page gates its handler block on a stable DOM id so the script
  // can be loaded uniformly via <script src="yuruna.common.js"></script>
  // without inline <script> blocks (CSP script-src 'self' compatible).
  // --- REGION: https://yuruna.link/definition#defining-the-status-page-browser-baseline

  function onReady(fn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', fn);
    } else {
      fn();
    }
  }

  // === index.html handlers ===
  function bootIndex() {
    var PAGE_CTA = {
      href:  'test.config.html',
      label: 'Edit config',
      title: 'Edit test/test.config.yml'
    };

    // Reuse the shared BANNER_TEXT so the two tables cannot silently diverge;
    // only the fail copy differs on the index dashboard (it points to the
    // details below rather than the status banner).
    var BANNER = Object.assign({}, BANNER_TEXT, {
      fail: 'Incident detected — see details below'
    });

    var cachingProxyHtml = '';

    function renderIpAddresses(value) {
      var el = document.getElementById('footer-ip-list');
      if (!el) return;
      el.value = value || '—';
      el.rows = Math.min(2, Math.max(1, el.value.split('\n').length));
    }

    function applyCachingProxyBanner() {
      var linkEl = document.getElementById('banner-dash');
      var noEl   = document.getElementById('banner-dash-noproxy');
      if (!linkEl || !noEl) return;
      var m = cachingProxyHtml.match(/href="([^"]+)"/i);
      var url = (m && m[1]) ? safeUrl(m[1].replace(/&amp;/g, '&')) : '';
      if (url) {
        linkEl.setAttribute('href', url);
        linkEl.classList.remove('hidden');
        noEl.classList.add('hidden');
      } else {
        linkEl.classList.add('hidden');
        noEl.classList.remove('hidden');
      }
    }

    function loadCachingProxyText() {
      fetch('runtime/caching-proxy.txt?_=' + Date.now(), { cache: 'no-store' })
        .then(function(res) {
          if (!res.ok) throw new Error('HTTP ' + res.status);
          return res.text();
        })
        .then(function(text) {
          cachingProxyHtml = (text || '').replace(/^\s+|\s+$/g, '');
        })
        ['catch'](function(e) {
          cachingProxyHtml = '';
          safeWarn('Could not load runtime/caching-proxy.txt:', e);
        })
        .then(function() {
          applyCachingProxyBanner();
        });
    }

    function updatePauseButton(kind, armed, cycleActive) {
      var btn = document.getElementById(kind + '-pause-btn');
      if (!btn) return;
      var pauseLabel = (kind === 'step') ? 'Pause after step' : 'Pause after cycle';
      if (armed) {
        btn.textContent = 'Continue';
        btn.classList.add('paused-active');
        btn.disabled = false;
        btn.onclick = function() { controlAction(kind, 'resume'); };
      } else if (cycleActive) {
        btn.textContent = pauseLabel;
        btn.classList.remove('paused-active');
        btn.disabled = false;
        btn.onclick = function() { controlAction(kind, 'pause'); };
      } else {
        btn.textContent = pauseLabel;
        btn.classList.remove('paused-active');
        btn.disabled = true;
        btn.onclick = null;
      }
    }

    // Refusal notice for a control POST the host would not accept. A 403 is a
    // RESOLVED fetch (not a network error), so it never reaches .catch -- the
    // old code fell straight through to loadStatus() and the click looked like a
    // silent no-op. The mutating /control/* routes are loopback-or-proof: an
    // on-host browser (http://localhost:<port>) is trusted; a browser on another
    // machine needs the short-lived token the pool dashboard grants. Tell the
    // operator that instead of doing nothing. Static markup (no data interpolated).
    function hideControlNotice() {
      var n = document.getElementById('control-notice');
      if (n) { n.hidden = true; }
    }
    function showControlNotice() {
      var n = document.getElementById('control-notice');
      if (!n) { return; }
      n.innerHTML =
        'Control refused. This host accepts control only from a browser <b>on the host itself</b> ' +
        '(<code>http://localhost:&lt;port&gt;</code>), or one opened through the <b>Yuruna hosts ' +
        'dashboard</b> link (which grants a short-lived token). To drive it from another machine, ' +
        'open it via the dashboard, or set the shared pool token — see ' +
        '<a href="https://yuruna.link/control-routes" target="_blank" rel="noopener">control-route setup</a>.';
      n.hidden = false;
    }

    function controlAction(kind, action) {
      var btn = document.getElementById(kind + '-pause-btn');
      if (btn) btn.disabled = true;
      var endpoint = 'control/' + kind + '-' + action;
      // X-Yuruna marks this as a same-origin UI call: any cross-origin copy
      // becomes a preflighted request the server refuses, blocking drive-by CSRF.
      fetch(endpoint, { method: 'POST', cache: 'no-store', headers: yurunaControlHeaders() })
        .then(function(res) {
          if (res && res.status === 403) { showControlNotice(); } else { hideControlNotice(); }
        })
        ['catch'](function(e) {
          safeWarn(endpoint + ' failed:', e);
        })
        .then(function() {
          loadStatus();
        });
    }

    var PILL_LABELS = {
      'New-VM.Resource':     'New VM',
      'Start-GuestOS':       'Start OS',
      'Start-GuestWorkload': 'Workload'
    };
    function pill(step) {
      var c = cls(step.status);
      var skip = step.skipped ? ' (skip)' : '';
      // errorMessage flows into a title="" attribute and step.name into element
      // text; both are runner/guest-supplied. escHtml() covers the attribute
      // delimiters and the HTML-significant characters, so a value carrying a
      // quote or angle bracket cannot break out of either context.
      var err  = step.errorMessage ? ' title="' + escHtml(step.errorMessage) + '"' : '';
      var label = PILL_LABELS[step.name] || step.name;
      return '<span class="step-pill ' + c + '"' + err + '>' + escHtml(label) + skip + '</span>';
    }

    var VM_PREP_STEPS = ['New-VM', 'Start-VM', 'New-VM.Resource'];
    function collapseVmPrep(steps) {
      var prep = [];
      var rest = [];
      for (var i = 0; i < steps.length; i++) {
        if (VM_PREP_STEPS.indexOf(steps[i].name) >= 0) prep.push(steps[i]);
        else rest.push(steps[i]);
      }
      if (prep.length === 0) return steps;
      var rank = { fail: 5, running: 4, pass: 3, skipped: 2, pending: 1 };
      var bestStatus = 'pending';
      var bestRank   = 0;
      var allSkipped = true;
      var firstErr   = null;
      var earliestStart = null;
      var latestFinish  = null;
      for (var j = 0; j < prep.length; j++) {
        var s = prep[j];
        var r = rank[s.status] || 0;
        if (r > bestRank) { bestRank = r; bestStatus = s.status; }
        if (!s.skipped) allSkipped = false;
        if (!firstErr && s.errorMessage) firstErr = s.errorMessage;
        if (s.startedAt && (!earliestStart || s.startedAt < earliestStart)) earliestStart = s.startedAt;
        if (s.finishedAt && (!latestFinish || s.finishedAt > latestFinish)) latestFinish = s.finishedAt;
      }
      var merged = {
        name:         'New-VM.Resource',
        status:       bestStatus,
        skipped:      allSkipped,
        errorMessage: firstErr,
        startedAt:    earliestStart,
        finishedAt:   latestFinish
      };
      var out = [];
      var inserted = false;
      for (var k = 0; k < steps.length; k++) {
        if (VM_PREP_STEPS.indexOf(steps[k].name) >= 0) {
          if (!inserted) { out.push(merged); inserted = true; }
          continue;
        }
        out.push(steps[k]);
      }
      return out;
    }

    function logFileUrl(cycleId, hostKey, gitCommit, cycleFolderUrl) {
      if (cycleFolderUrl) {
        var trimmed = cycleFolderUrl.replace(/\/+$/, '');
        var parts = trimmed.split('/');
        // The folder URL can carry a lifecycle suffix (`.incomplete`
        // mid-cycle, `.aborted.<UTC>` post-crash) but the HTML log
        // file inside is always named with the stable base identity.
        // Mirror Get-CycleFolderIdentity in Test.Log.psm1.
        var base = parts[parts.length - 1]
          .replace(/\.incomplete$/, '')
          .replace(/\.aborted\.[^/\\]+$/, '');
        return trimmed + '/' + base + '.html';
      }
      // Fallback hierarchy when status.json lacks cycleFolderUrl (e.g.
      // crashed before Start-LogFile populated it). Keeps the link
      // clickable so the operator can pivot into the log dir instead of
      // being silently stuck with a non-actionable cycle id. hostKey is
      // the hostId (callers pass hostId, falling back to hostname for a
      // legacy status.json) -- the cycleFolder's hostname-free 4th segment.
      if (cycleId && hostKey && gitCommit) {
        return 'log/' + cycleId.replace(/:/g, '-') + '.' + hostKey + '.' + gitCommit + '.html';
      }
      if (cycleId && hostKey) {
        // Mirror Format-CycleFolderBaseName: <padded>.<cycleDate>.<cycleTime>.<hostId>
        // We lack the padded counter, so degrade to a directory link the
        // server's index/listing can resolve to the actual cycle folder.
        var iso = String(cycleId);
        var d = (iso.length >= 10) ? iso.substring(0, 10) : '';
        var t = (iso.length >= 19) ? iso.substring(11, 19).replace(/:/g, '-') : '';
        if (d && t) {
          return 'log/?prefix=' + d + '.' + t + '.' + hostKey;
        }
      }
      return 'log/';
    }

    function gitCommitsForRender(rec, legacyRepoUrl) {
      if (rec.gitCommits && rec.gitCommits.length > 0) return rec.gitCommits;
      if (rec.gitCommit) return [{ sha: rec.gitCommit, repoUrl: rec.repoUrl || legacyRepoUrl || null }];
      return [];
    }
    function renderCommitLinks(commits) {
      if (!commits || commits.length === 0) return '—';
      return commits.map(function(c) {
        var sha   = (c && c.sha) ? c.sha.slice(0, 8) : '';
        var rawSha = (c && c.sha) ? c.sha : '';
        if (!sha) return '—';
        if (c.repoUrl && /^https?:\/\//i.test(c.repoUrl) && /^[A-Za-z0-9]+$/.test(rawSha)) {
          var href = escHtml(c.repoUrl + '/commit/' + rawSha);
          return '<a href="' + href + '" target="_blank" style="color:inherit;text-decoration:underline dotted">' + escHtml(sha) + '</a>';
        }
        return escHtml(sha);
      }).join(', ');
    }
    function primaryShaForLog(rec) {
      var commits = gitCommitsForRender(rec, null);
      if (commits.length > 0 && commits[0].sha) return commits[0].sha;
      return rec.gitCommit || null;
    }

    function guestActionHtml(g, actionData, paused, breakData) {
      if (!actionData || !actionData.line) return '';
      if (g.status !== 'running') return '';
      if (actionData.guestKey && actionData.guestKey !== g.guestKey) return '';
      var waitingForResume = paused && /Paused \(waiting for resume\)/.test(actionData.line);
      var atBreak = !!(breakData && breakData.guestKey === g.guestKey);
      var actionCls = (waitingForResume || atBreak) ? 'guest-action paused' : 'guest-action';
      var html = '<div class="' + actionCls + '">' + escHtml(actionData.line);
      if (atBreak) {
        // restoreOnContinue (opt-in) decides what Continue does. A plain
        // breakpoint resumes in place; the id alone is just a label, so the
        // tooltip must not promise a restore the handler will not perform.
        var willRestore = !!(breakData.restoreOnContinue && breakData.snapshotId);
        var btnTitle = willRestore
          ? ('Restore snapshot id ' + escHtml(breakData.snapshotId) + ', restart the VM, then resume the sequence')
          : 'Resume the sequence in place (no snapshot restore)';
        html += ' <button id="break-continue-btn" class="meta-btn paused-active" type="button"' +
                ' title="' + btnTitle + '">Continue</button>';
      }
      html += '</div>';
      return html;
    }

    function continueFromBreak() {
      var btn = document.getElementById('break-continue-btn');
      if (btn) { btn.disabled = true; btn.textContent = 'Continuing...'; }
      fetch('control/break-continue', { method: 'POST', cache: 'no-store', headers: yurunaControlHeaders() })
        ['catch'](function(e) { safeWarn('control/break-continue failed:', e); })
        .then(function() { loadStatus(); });
    }

    // Rank for rolling a sequence's guests up to one aggregate badge. Mirrors
    // the collapseVmPrep step-rank above so the dashboard ranks statuses the
    // same way everywhere: fail > running > pass > skipped > pending.
    var GUEST_STATUS_RANK = { fail: 5, running: 4, pass: 3, skipped: 2, pending: 1 };
    function aggregateStatus(statuses) {
      var best = 'pending', bestRank = 0;
      for (var i = 0; i < statuses.length; i++) {
        var s = statuses[i] || 'pending';
        var r = GUEST_STATUS_RANK[s] || 0;
        if (r > bestRank) { bestRank = r; best = s; }
      }
      return best;
    }

    // Render one guest's block (header + step pills + action + error). Shared
    // by the per-sequence cards (nested, ctx.hideTopLevel === true) and the
    // flat fallback list (standalone card, top-level sub-line shown). ctx
    // carries the live { data, actionData, stepPaused, breakData } scope.
    function renderGuestBlock(g, ctx) {
      var data = ctx.data;
      var stepsArr = collapseVmPrep(g.steps || []);
      var steps    = stepsArr.map(pill).join('');
      var firstStartedAt = stepsArr[0] ? stepsArr[0].startedAt : null;
      var lastFinishedAt = stepsArr.length ? stepsArr[stepsArr.length - 1].finishedAt : null;
      var dur            = fmtDuration(firstStartedAt, lastFinishedAt);
      var errStep = null;
      for (var i = 0; i < stepsArr.length; i++) {
        if (stepsArr[i].errorMessage) { errStep = stepsArr[i]; break; }
      }
      var errHtml = errStep ? ('<div class="guest-error">' + escHtml(errStep.errorMessage) + '</div>') : '';
      var actHtml = guestActionHtml(g, ctx.actionData, ctx.stepPaused, ctx.breakData);
      var metaParts = ' · ';
      if (g.status === 'running' && g.vmName) {
        metaParts = 'VM: ' + escHtml(g.vmName);
      } else if (g.status && g.status !== 'running' && g.status !== 'pending' && dur !== '—') {
        metaParts = 'Duration: ' + dur;
      }
      // The sequence card already names the top-level sequence, so the
      // per-guest top-level sub-line is suppressed when nested.
      var topLevelStr = (g.topLevel || '').replace(/^\s+|\s+$/g, '');
      var topHtml = (!ctx.hideTopLevel && topLevelStr)
        ? ('<div class="guest-toplevel">' + escHtml(topLevelStr) + '</div>')
        : '';
      // Live cycle: derive the per-guest folder URL from the current
      // cycleFolderUrl (Set-CycleFolderUrl flips its suffix at the
      // Stop-LogFile rename, so this always matches the on-disk path).
      // g.failureArtifacts records the post-rename URL; using it mid-cycle
      // 404s while the folder is still `<base>.incomplete/<VMName>/`.
      var folderUrl = safeUrl((data.cycleFolderUrl && g.vmName)
        ? (data.cycleFolderUrl + g.vmName + '/')
        : (g.failureArtifacts || ''));
      var titleHtml = folderUrl
        ? ('<a href="' + escHtml(folderUrl) + '" target="_blank" title="Open results folder for ' + escHtml(g.guestKey) + '" style="color:inherit;text-decoration:underline dotted">' + escHtml(g.guestKey) + '</a>')
        : escHtml(g.guestKey);
      // The sequence card already carries one aggregate status badge in its
      // header; a guest nested under it (ctx.hideStatusBadge) would just
      // repeat that status, so the per-guest badge is suppressed there. The
      // flat fallback list (no sequence card) still shows it — there it is
      // the only status indicator. The guest-name link preserves the
      // results-folder pivot in both layouts.
      var badgeColHtml = '';
      if (!ctx.hideStatusBadge) {
        var badgeHtml = folderUrl
          ? ('<a href="' + escHtml(folderUrl) + '" target="_blank" title="Open results folder for ' + escHtml(g.guestKey) + '" style="text-decoration:none">' + badge(g.status) + '</a>')
          : badge(g.status);
        badgeColHtml = '<div>' + badgeHtml + '</div>';
      }
      return '<div class="guest-card">' +
        '<div class="guest-card-header">' +
          '<div class="left">' +
            '<div class="guest-name">' + titleHtml + '</div>' +
            '<div class="guest-meta">' + metaParts + '</div>' +
          '</div>' +
          badgeColHtml +
        '</div>' +
        topHtml +
        '<div class="steps">' + steps + '</div>' +
        actHtml +
        errHtml +
      '</div>';
    }

    // Recent-Cycles "Sequences" cell: one badge per sequence the cycle ran,
    // each linking to that sequence's results folder. History rows recorded
    // before sequenceSummary existed carry only guestSummary, so fall back to
    // one badge per guest there — old rows still render with their original
    // per-guest pills.
    function historySummaryCell(h, guestToSeq) {
      var seqs = h.sequenceSummary;
      if (seqs && seqs.length) {
        return seqs.map(function(s) {
          var status = (s && s.status) || '';
          var name   = (s && s.name) || '';
          var folder = safeUrl((s && s.folderUrl) || '');
          var pill   = '<span class="badge ' + cls(status) + '">' + escHtml(name) + '</span>';
          if (folder) {
            return '<a href="' + escHtml(folder) + '" target="_blank" title="Open results folder for ' + escHtml(name) + '" style="text-decoration:none">' + pill + '</a>';
          }
          return pill;
        }).join(' ');
      }
      // Legacy fallback: rows recorded before sequenceSummary existed carry
      // only guestSummary (keyed by guest). Relabel each pill with the
      // sequence name(s) that drive that guest in the CURRENT cycle plan
      // (guestToSeq) so the column reads as sequences even for old rows — the
      // link still targets the per-guest folder. A guest the current plan no
      // longer references degrades to its bare guest key.
      var gs = h.guestSummary || {};
      return Object.keys(gs).map(function(k) {
        var v        = gs[k];
        var status   = (typeof v === 'string') ? v : (v && v.status) || '';
        var debugUrl = safeUrl((typeof v === 'object' && v) ? v.failureArtifacts : '');
        var seqNames = guestToSeq && guestToSeq[k];
        var label    = (seqNames && seqNames.length) ? seqNames.join(' + ') : k.replace('guest.','');
        var pillHtml = '<span class="badge ' + cls(status) + '">' + escHtml(label) + '</span>';
        if (debugUrl) {
          return '<a href="' + escHtml(debugUrl) + '" target="_blank" title="Open results folder for ' + escHtml(label) + '" style="text-decoration:none">' + pillHtml + '</a>';
        }
        return pillHtml;
      }).join(' ');
    }

    function renderStatus(data, actionData, breakData, runnerStatus) {
      var noData = document.getElementById('no-data');
      var banner = document.getElementById('banner');
      var headerMachine = document.getElementById('header-machine');
      // Match applyBanner's defensive contract: if the core status DOM ids
      // have drifted, degrade gracefully rather than throwing out of the
      // 60s poll loop (an uncaught throw there freezes the dashboard).
      // headerMachine is guarded too because renderHeaderMachine dereferences
      // it below with no null check of its own.
      if (!banner || !noData || !headerMachine) { return; }

      var nameText = '';
      var hostText = '';
      if (data && data.hostname) {
        nameText = data.hostname;
        hostText = data.host ? data.host.replace('host.','') : '';
        document.title = data.hostname + ' — Yuruna status';
      } else {
        nameText = window.location.hostname || '';
      }
      Yuruna.renderHeaderMachine(headerMachine, nameText, hostText, PAGE_CTA);

      var liveCycleId = data && (data.cycleId || data.runId);
      var hasGuests   = !!(data && data.guests && data.guests.length);
      var hasHistory  = !!(data && data.history && data.history.length);

      var runnerStopped = !!(runnerStatus && runnerStatus.running === false);

      if (!data || (!liveCycleId && !hasGuests && !hasHistory)) {
        banner.className = runnerStopped ? 'stopped' : 'idle';
        setBannerText(runnerStopped ? BANNER.stopped : BANNER.idle);
        updatePauseButton('step',  false, false);
        updatePauseButton('cycle', false, false);
        var ids = ['sec-cycle','sec-sequences','sec-history'];
        for (var i = 0; i < ids.length; i++) {
          var s = document.getElementById(ids[i]);
          if (s) s.style.display = 'none';
        }
        noData.style.display = '';
        return;
      }
      noData.style.display = 'none';

      var status = data.overallStatus || 'idle';
      var stepPaused  = !!data.stepPaused;
      var cyclePaused = !!data.cyclePaused;
      var pauseText = pauseBannerText(stepPaused, cyclePaused, status, actionData);
      var anyPaused = pauseText !== null;
      var effective = anyPaused ? 'paused' : cls(status);
      if (runnerStopped) {
        banner.className = 'stopped';
        setBannerText(BANNER.stopped);
      } else {
        banner.className = effective;
        setBannerText(pauseText !== null ? pauseText : (BANNER[status] || status));
      }
      var cycleActive = (status === 'running') || anyPaused;
      // The cycle-pause button stays live BETWEEN cycles too: while the runner
      // is alive but the current cycle has already finished (the
      // cycleDelaySeconds inter-cycle wait), arming it pauses the runner right
      // after that wait, before the next cycle starts. runnerStatus.running is
      // the same liveness signal the "stopped" banner uses above. Step-pause
      // has no step to attach to between cycles, so it keeps the cycle-scoped
      // rule.
      var runnerAlive = !!(runnerStatus && runnerStatus.running);
      updatePauseButton('step',  stepPaused,  cycleActive);
      updatePauseButton('cycle', cyclePaused, cycleActive || runnerAlive);

      if (liveCycleId) {
        document.getElementById('sec-cycle').style.display = '';
        var liveCommits = gitCommitsForRender(data, data.repoUrl);
        document.getElementById('cycle-commit').innerHTML = renderCommitLinks(liveCommits);
        var cycleIdLabel = escHtml((liveCycleId || '—').slice(0, 19).replace('T', ' T'));
        var cycleLogUrl  = safeUrl(logFileUrl(liveCycleId, (data.hostId || data.hostname), primaryShaForLog(data), data.cycleFolderUrl));
        var cycleCell = cycleLogUrl
          ? ('<a href="' + escHtml(cycleLogUrl) + '" target="_blank" style="color:inherit;text-decoration:underline dotted">' + cycleIdLabel + '</a>')
          : cycleIdLabel;
        document.getElementById('cycle-timestamp').innerHTML = '<span class="badge ' + cls(status) + '">' + cycleCell + '</span>';
        document.getElementById('cycle-started').textContent  = fmtDate(data.startedAt);
        document.getElementById('cycle-images-refresh').textContent = data.lastGetImageAt ? fmtDate(data.lastGetImageAt) : 'never';
        // Classified failure cause for the live cycle (data.lastFailure), set by
        // Set-LastFailureSummary at failure time. Every interpolated value is
        // escHtml'd (attribute- and text-safe). Hidden when the cycle has no
        // failure (passing cycle / pre-failure window).
        var fcEl = document.getElementById('cycle-failure');
        if (fcEl) {
          var lf = data.lastFailure;
          if (lf && lf.failureClass) {
            var parts = ['<span class="badge fail">' + escHtml(lf.failureClass) + '</span>'];
            if (lf.severity) { parts.push('severity: ' + escHtml(lf.severity)); }
            if (lf.sequenceName) { parts.push('sequence: ' + escHtml(lf.sequenceName) + (lf.stepNumber ? ' (step ' + escHtml(String(lf.stepNumber)) + ')' : '')); }
            if (lf.errorMessage) { parts.push(escHtml(lf.errorMessage)); }
            var fcHtml = parts.join(' &middot; ');
            if (lf.reproCommand) { fcHtml += '<div class="repro"><code>' + escHtml(lf.reproCommand) + '</code></div>'; }
            if (lf.relPath && data.cycleFolderUrl && lf.vmName) {
              var lfUrl = safeUrl(data.cycleFolderUrl + lf.vmName + '/' + lf.relPath);
              if (lfUrl) { fcHtml += '<div><a href="' + escHtml(lfUrl) + '">last_failure.json</a></div>'; }
            }
            fcEl.innerHTML = fcHtml;
            fcEl.style.display = '';
          } else {
            fcEl.style.display = 'none';
            fcEl.innerHTML = '';
          }
        }
      }

      // Primary view: one card per test.runner.yml sequence (in list order),
      // nesting the guest(s) that sequence drives. Falls back to a flat
      // per-guest list when status.json carries no `sequences` (legacy
      // guestSequence path, or the brief pre-Initialize "running" window).
      var sequences = data.sequences || [];
      var guests    = data.guests || [];
      var ctx = { data: data, actionData: actionData, stepPaused: stepPaused, breakData: breakData };
      var secSeq  = document.getElementById('sec-sequences');
      var listSeq = document.getElementById('sequence-list');
      if (sequences.length) {
        secSeq.style.display = '';
        var guestsByKey = {};
        for (var gi = 0; gi < guests.length; gi++) { guestsByKey[guests[gi].guestKey] = guests[gi]; }
        listSeq.innerHTML = sequences.map(function(seq) {
          var gkeys    = seq.guests || [];
          var statuses = [];
          var blocks   = gkeys.map(function(gk) {
            // A sequence can reference a guest that isn't in guests[] yet
            // (pending before its lifecycle starts); synthesize a placeholder.
            var g = guestsByKey[gk] || { guestKey: gk, status: 'pending', steps: [] };
            statuses.push(g.status);
            return renderGuestBlock(g, {
              data: data, actionData: actionData, stepPaused: stepPaused,
              breakData: breakData, hideTopLevel: true, hideStatusBadge: true
            });
          }).join('');
          return '<div class="sequence-card">' +
            '<div class="sequence-card-header">' +
              '<div class="sequence-name">' + escHtml(seq.name) + '</div>' +
              '<div>' + badge(aggregateStatus(statuses)) + '</div>' +
            '</div>' +
            blocks +
          '</div>';
        }).join('');
      } else if (guests.length) {
        secSeq.style.display = '';
        listSeq.innerHTML = guests.map(function(g) { return renderGuestBlock(g, ctx); }).join('');
      } else {
        secSeq.style.display = 'none';
      }

      var history = data.history || [];
      if (history.length) {
        document.getElementById('sec-history').style.display = '';
        // Map guestKey -> [sequence names] from the CURRENT cycle plan so
        // legacy history rows (guestSummary only, no sequenceSummary) can
        // still label their pills with sequence names. Empty when the live
        // doc carries no sequences[] (legacy guestSequence path), in which
        // case those rows degrade to bare guest keys.
        var guestToSeq = {};
        (data.sequences || []).forEach(function(seq) {
          (seq.guests || []).forEach(function(gk) {
            if (!guestToSeq[gk]) { guestToSeq[gk] = []; }
            if (guestToSeq[gk].indexOf(seq.name) === -1) { guestToSeq[gk].push(seq.name); }
          });
        });
        document.getElementById('history-body').innerHTML = history.map(function(h) {
          var summaryCell = historySummaryCell(h, guestToSeq);
          var hCycleId    = h.cycleId || h.runId;
          // Legacy entries (recorded before Complete-Run started
          // stripping the suffix) saved the in-progress `.incomplete/`
          // URL into history. Strip on read so those rows resolve to
          // the post-rename folder on disk.
          var hCycleFolderUrl = stripCycleFolderSuffix(h.cycleFolderUrl);
          var hLogUrl     = safeUrl(logFileUrl(hCycleId, (h.hostId || h.hostname), primaryShaForLog(h), hCycleFolderUrl));
          // Escape the id BEFORE inserting the literal <wbr> so an id carrying
          // markup can't inject, while the intended line-break hint survives.
          var hCycleLabel = escHtml((hCycleId || '—').slice(0, 19)).replace('T', ' <wbr>T');
          var hCycleCell  = hLogUrl
            ? ('<a href="' + escHtml(hLogUrl) + '" target="_blank" style="color:inherit;text-decoration:underline dotted">' + hCycleLabel + '</a>')
            : hCycleLabel;
          var statusCls  = cls(h.overallStatus);
          var commitCell = renderCommitLinks(gitCommitsForRender(h, data.repoUrl));
          return '<tr>' +
            '<td class="mono"><span class="badge ' + statusCls + '">' + hCycleCell + '</span></td>' +
            '<td>' + fmtDuration(h.startedAt, h.finishedAt) + '</td>' +
            '<td>' + summaryCell + '</td>' +
            '<td class="mono">' + commitCell + '</td>' +
          '</tr>';
        }).join('');
      }
    }

    var countdown = 60;

    function loadStatus() {
      // Four endpoints are independent; Promise.all parallelizes the
      // round-trips so one refresh pays one RTT, not four. status.json
      // failures still surface in the console so the operator can see
      // when the server is down.
      var statusPromise = fetch('runtime/status.json?_=' + Date.now())
        .then(function(res) {
          if (!res.ok) throw new Error('HTTP ' + res.status);
          return res.json();
        })
        ['catch'](function(e) {
          safeWarn('Could not load runtime/status.json:', e);
          return null;
        });
      Promise.all([
        statusPromise,
        fetchJson('runtime/current-action.json'),
        fetchJson('runtime/break-active.json'),
        fetchJson('control/runner-status')
      ]).then(function(results) {
        var data = results[0], actionData = results[1], breakData = results[2], runnerStatus = results[3];
        renderStatus(data, actionData, breakData, runnerStatus);
        var contBtn = document.getElementById('break-continue-btn');
        if (contBtn) { contBtn.onclick = continueFromBreak; }
        document.getElementById('last-loaded').textContent = new Date().toLocaleTimeString();
        countdown = 60;
        loadCachingProxyText();
      });
    }
    // --- REGION: https://yuruna.link/definition#defining-the-status-page-visibility-aware-polling
    var poller = Yuruna.startVisibilityAwarePolling({
      run: function() { loadStatus(); },
      onResume: function() { countdown = 0; }
    });
    setInterval(function() {
      if (document.hidden) {
        var elH = document.getElementById('countdown');
        if (elH) elH.textContent = '...';
        return;
      }
      countdown = Math.max(0, countdown - 1);
      var el = document.getElementById('countdown');
      if (el) el.textContent = countdown;
      if (countdown === 0) poller.tick();
    }, 1000);

    Yuruna.populateHeader(PAGE_CTA);
    Yuruna.getHostInfo().then(function(info) { renderIpAddresses(info.ipAddresses); });
    loadCachingProxyText();
    loadStatus();

    // Footer refresh link. Wired via addEventListener rather than an inline
    // onclick attribute so the page stays CSP script-src 'self' compatible.
    var refreshLink = document.getElementById('footer-refresh');
    if (refreshLink) {
      refreshLink.addEventListener('click', function(e) {
        e.preventDefault();
        location.reload();
      });
    }
  }

  // === perf.html handlers ===
  function bootPerf() {
    Yuruna.populateHeader({ href: 'index.html', label: '← Status' });
    startBannerPolling();

    // Icicle geometry. Each cycle is one horizontal icicle: time runs along
    // x (CHART_W viewBox units, shared scale across the shown cycles so a
    // slower cycle's bar is visibly longer), hierarchy depth runs down y
    // (BAND_H per level). MAX_CYCLES caps how many recent cycles a sequence
    // shows.
    var CHART_W    = 760;
    var BAND_H     = 15;
    var ROW_PAD    = 3;
    var AXIS_H     = 18;
    var MAX_CYCLES = 10;
    var STEP_PALETTE = [
      '#3b82f6', '#10b981', '#f59e0b', '#8b5cf6',
      '#ec4899', '#14b8a6', '#f97316', '#6366f1',
      '#84cc16', '#06b6d4', '#a855f7', '#0ea5e9',
      '#22c55e', '#eab308', '#d946ef', '#64748b'
    ];

    function svgEl(name, attrs) {
      var el = document.createElementNS('http://www.w3.org/2000/svg', name);
      if (attrs) {
        for (var k in attrs) { if (attrs.hasOwnProperty(k)) el.setAttribute(k, attrs[k]); }
      }
      return el;
    }

    function fmtSec(ms) {
      if (!isFinite(ms) || ms < 0) return '—';
      return (ms / 1000).toFixed(1) + 's';
    }

    function fmtDateLocal(iso) {
      if (!iso) return '';
      return iso.replace('T', ' ').replace(/\.\d+Z$/, 'Z').slice(0, 19);
    }

    function stepColor(name) {
      var s = name || '';
      var h = 5381;
      for (var i = 0; i < s.length; i++) {
        h = ((h << 5) + h + s.charCodeAt(i)) | 0;
      }
      if (h < 0) h = -h;
      return STEP_PALETTE[h % STEP_PALETTE.length];
    }

    // Turn a fetchAndExecute step's checkpoints (each an {name, offsetMs} point
    // measured from the step's start) into contiguous phase sub-segments that
    // fill the step's duration. The slice before the first checkpoint is the
    // fetch/preamble '(setup)'; the slice after the last checkpoint runs to the
    // step's end (it absorbs the completion-marker + POST tail). Returns null
    // when there is nothing renderable.
    function normalizeCheckpoints(checkpoints, sms) {
      var pts = [];
      for (var i = 0; i < checkpoints.length; i++) {
        var c = checkpoints[i];
        if (!c) continue;
        var off = +c.offsetMs;
        if (!isFinite(off)) continue;
        if (off < 0) off = 0;
        if (off > sms) off = sms;
        pts.push({ off: off, name: (c.name == null ? '' : ('' + c.name)) });
      }
      if (!pts.length) return null;
      pts.sort(function(a, b) { return a.off - b.off; });
      var segs = [];
      if (pts[0].off > 0) segs.push({ lo: 0, hi: pts[0].off, label: '(setup)' });
      for (var k = 0; k < pts.length; k++) {
        var lo = pts[k].off;
        var hi = (k + 1 < pts.length) ? pts[k + 1].off : sms;
        if (hi <= lo) continue;   // zero-width phase (two markers at the same ms)
        segs.push({ lo: lo, hi: hi, label: pts[k].name || '(unnamed)' });
      }
      return segs.length ? segs : null;
    }

    var staleCycleCount = 0;

    // Reconstruct one cycle's step hierarchy as a flat list of placed nodes
    // (each { name, kind, outcome, lo, hi (ms from the cycle's first step),
    // depth, ... }). Nesting is derived by TIME CONTAINMENT: a step whose
    // [start,end] window sits inside another's becomes its child, one level
    // deeper — so a retry parent that wraps two passwdPrompt children shows
    // the children nested INSIDE it rather than stacked on top (the stacking
    // is what double-counted the nested time). fetchAndExecute checkpoints
    // (phase markers) become a further child level so the per-phase split is
    // preserved. Returns { fallback:true } when the cycle's steps lack usable
    // epoch-ms windows (degraded/old data) so the caller draws one gray bar.
    function buildFlame(cyc) {
      var raw = (cyc && cyc.steps) ? cyc.steps : [];
      var timed = [];
      for (var i = 0; i < raw.length; i++) {
        var st = raw[i];
        var s = st.startedMs, e = st.endedMs;
        if (typeof s !== 'number' || typeof e !== 'number' || e < s) continue;
        timed.push({ st: st, start: s, end: e });
      }
      if (raw.length === 0 || timed.length !== raw.length) {
        return { fallback: true, spanMs: Math.max(1, +((cyc && cyc.durationMs)) || 0) };
      }
      // Container before contained: earliest start first, then longer span
      // first so a parent is on the stack before its children are visited.
      timed.sort(function(a, b) { return (a.start - b.start) || (b.end - a.end); });
      var t0 = timed[0].start;
      var t1 = t0;
      for (var m = 0; m < timed.length; m++) { if (timed[m].end > t1) t1 = timed[m].end; }
      var spanMs = Math.max(1, t1 - t0);

      var stack = [];   // open ancestors: { end }
      var nodes = [];
      var maxDepth = 0;
      for (var k = 0; k < timed.length; k++) {
        var x = timed[k];
        // Drop ancestors that closed before x starts, then any that end before
        // x ends (siblings / partial overlap — x is not inside them).
        while (stack.length && stack[stack.length - 1].end <= x.start) { stack.pop(); }
        while (stack.length && stack[stack.length - 1].end <  x.end)   { stack.pop(); }
        var depth = stack.length;
        if (depth > maxDepth) maxDepth = depth;
        nodes.push({
          name: x.st.name || '', kind: x.st.kind || '', outcome: x.st.outcome || '',
          lo: x.start - t0, hi: x.end - t0, depth: depth,
          durationMs: +x.st.durationMs || 0, parentAction: x.st.parentAction || ''
        });
        stack.push({ end: x.end });
        // fetchAndExecute checkpoints -> one nested level of phase segments.
        var sms = x.end - x.start;
        var cks = (x.st.kind === 'fetchAndExecute' && x.st.checkpoints && x.st.checkpoints.length && sms > 0)
          ? normalizeCheckpoints(x.st.checkpoints, sms) : null;
        if (cks) {
          var cdepth = depth + 1;
          if (cdepth > maxDepth) maxDepth = cdepth;
          for (var ci = 0; ci < cks.length; ci++) {
            var sub = cks[ci];
            nodes.push({
              name: sub.label, kind: 'checkpoint', outcome: x.st.outcome || '',
              lo: (x.start - t0) + sub.lo, hi: (x.start - t0) + sub.hi, depth: cdepth,
              durationMs: sub.hi - sub.lo, isCkpt: true
            });
          }
        }
      }
      return { fallback: false, nodes: nodes, spanMs: spanMs, maxDepth: maxDepth };
    }

    function flameLabel(name, widthUnits) {
      if (widthUnits <= 34) return '';
      var maxChars = Math.floor((widthUnits - 6) / 5.0);
      if (maxChars < 3) return '';
      var nm = name || '';
      return (nm.length > maxChars) ? (nm.slice(0, Math.max(1, maxChars - 1)) + '…') : nm;
    }

    // One cycle row: a clickable timestamp + wall-clock duration above the
    // cycle's horizontal icicle. pxPerMs / plotDepth are shared across the
    // sequence's shown cycles so bars are comparable and rows are uniform.
    function renderCycleRow(cyc, flame, pxPerMs, plotDepth, cycleLinks) {
      var row = document.createElement('div');
      row.className = 'cycle-row';

      var head = document.createElement('div');
      head.className = 'cycle-row-head';
      var when  = fmtDateLocal(cyc.cycleStartedAtUtc) || (cyc.cycleId || '');
      var label = when.replace(/^\d{4}-/, '').replace(/:\d{2}Z?$/, '');   // MM-DD HH:MM
      var url   = safeUrl((cycleLinks && cyc.cycleId) ? cycleLinks[cyc.cycleId] : '');
      var failCount = +cyc.failCount || 0;
      var whenEl;
      if (url) {
        whenEl = document.createElement('a');
        whenEl.setAttribute('href', url);
        whenEl.setAttribute('target', '_blank');
        whenEl.setAttribute('title', 'Open cycle data folder');
        whenEl.className = 'cycle-link';
      } else {
        whenEl = document.createElement('span');
        whenEl.className = 'cycle-link nolink';
        whenEl.setAttribute('title', 'No cycle folder recorded for this cycle');
      }
      whenEl.textContent = label;
      head.appendChild(whenEl);

      var durEl = document.createElement('span');
      durEl.className = 'cycle-dur' + (failCount > 0 ? ' fail' : '');
      durEl.textContent = fmtSec(flame.spanMs) + (failCount > 0 ? ' ✕' : '');
      head.appendChild(durEl);
      row.appendChild(head);

      var plotH = (plotDepth + 1) * BAND_H + ROW_PAD * 2;
      var svg = svgEl('svg', {
        'class': 'cycle-flame',
        'viewBox': '0 0 ' + CHART_W + ' ' + plotH,
        'preserveAspectRatio': 'xMinYMid meet'
      });

      if (flame.fallback) {
        staleCycleCount++;
        var fr = svgEl('rect', {
          'class': 'flame-cell fallback',
          x: 0, y: ROW_PAD, width: Math.max(2, flame.spanMs * pxPerMs), height: BAND_H
        });
        var ft = svgEl('title', {});
        ft.textContent = '(no per-step timing)\nDuration: ' + fmtSec(flame.spanMs);
        fr.appendChild(ft);
        svg.appendChild(fr);
        row.appendChild(svg);
        return row;
      }

      for (var i = 0; i < flame.nodes.length; i++) {
        var nd = flame.nodes[i];
        var x = nd.lo * pxPerMs;
        var w = Math.max(1, (nd.hi - nd.lo) * pxPerMs);
        var y = ROW_PAD + nd.depth * BAND_H;
        var isFail = (nd.outcome === 'fail');
        var rect = svgEl('rect', {
          'class': 'flame-cell' + (nd.isCkpt ? ' ckpt' : '') + (isFail ? ' fail' : ''),
          x: x, y: y, width: w, height: BAND_H - 1,
          fill: stepColor(nd.name)
        });
        var title = svgEl('title', {});
        title.textContent =
          (nd.isCkpt ? '▸ ' : '') + (nd.name || '(unnamed)') + '\n' +
          (nd.isCkpt ? '' : ('Kind: ' + (nd.kind || '?') + '\n')) +
          'Duration: ' + fmtSec(nd.durationMs) + '\n' +
          (nd.outcome ? ('Outcome: ' + nd.outcome + '\n') : '') +
          (nd.parentAction ? ('Within: ' + nd.parentAction + '\n') : '') +
          'Cycle: ' + fmtDateLocal(cyc.cycleStartedAtUtc);
        rect.appendChild(title);
        svg.appendChild(rect);
        var lbl = flameLabel(nd.name, w);
        if (lbl) {
          var txt = svgEl('text', { 'class': 'flame-label', x: x + 3, y: y + BAND_H - 4 });
          txt.textContent = lbl;
          svg.appendChild(txt);
        }
      }
      row.appendChild(svg);
      return row;
    }

    // Shared seconds axis, drawn once under a sequence's cycle rows (every
    // row uses the same pxPerMs, so one axis describes them all).
    function buildAxisRow(maxSpan, pxPerMs) {
      var row = document.createElement('div');
      row.className = 'axis-row';
      var svg = svgEl('svg', {
        'class': 'cycle-flame',
        'viewBox': '0 0 ' + CHART_W + ' ' + AXIS_H,
        'preserveAspectRatio': 'xMinYMid meet'
      });
      svg.appendChild(svgEl('line', { 'class': 'flame-axis-line', x1: 0, y1: 1, x2: maxSpan * pxPerMs, y2: 1 }));
      var ticks = [0, 0.25, 0.5, 0.75, 1];
      for (var i = 0; i < ticks.length; i++) {
        var ms = maxSpan * ticks[i];
        var anchor = (i === 0) ? 'start' : (i === ticks.length - 1 ? 'end' : 'middle');
        var t = svgEl('text', { 'class': 'flame-axis-text', x: ms * pxPerMs, y: AXIS_H - 5, 'text-anchor': anchor });
        t.textContent = fmtSec(ms);
        svg.appendChild(t);
      }
      row.appendChild(svg);
      return row;
    }

    function buildSeqCard(seqName, cycles, cycleLinks) {
      var card = document.createElement('div');
      card.className = 'seq-card';

      var nameEl = document.createElement('div');
      nameEl.className = 'seq-name';
      nameEl.textContent = seqName;
      card.appendChild(nameEl);

      // Payload arrives oldest-first; show the most-recent MAX_CYCLES newest
      // at the top.
      var shown = cycles.slice().reverse().slice(0, MAX_CYCLES);

      var totalFails = 0;
      for (var i = 0; i < shown.length; i++) { if ((shown[i].failCount || 0) > 0) totalFails++; }

      var metaEl = document.createElement('div');
      metaEl.className = 'seq-meta';
      metaEl.textContent =
        'latest ' + shown.length + ' of ' + cycles.length + ' cycle' + (cycles.length === 1 ? '' : 's')
        + (totalFails > 0 ? ' · ' + totalFails + ' with failures' : '');
      card.appendChild(metaEl);

      if (shown.length === 0) {
        var none = document.createElement('div');
        none.className = 'seq-meta';
        none.textContent = '(no data)';
        card.appendChild(none);
        return card;
      }

      // Shared scale: widest span + deepest hierarchy across the shown cycles.
      var flames = [];
      var maxSpan = 1, maxDepth = 0;
      for (var c = 0; c < shown.length; c++) {
        var fl = buildFlame(shown[c]);
        flames.push(fl);
        if (fl.spanMs > maxSpan) maxSpan = fl.spanMs;
        if (!fl.fallback && fl.maxDepth > maxDepth) maxDepth = fl.maxDepth;
      }
      var pxPerMs = CHART_W / maxSpan;

      var rowsWrap = document.createElement('div');
      rowsWrap.className = 'cycle-rows';
      for (var r = 0; r < shown.length; r++) {
        rowsWrap.appendChild(renderCycleRow(shown[r], flames[r], pxPerMs, maxDepth, cycleLinks));
      }
      card.appendChild(rowsWrap);
      card.appendChild(buildAxisRow(maxSpan, pxPerMs));
      return card;
    }

    function renderAggregates(payload, cycleLinks) {
      var meta = document.getElementById('perf-message');
      var body = document.getElementById('perf-body');
      body.innerHTML = '';
      staleCycleCount = 0;
      if (!payload || !payload.sequences) {
        meta.textContent = 'No aggregates available.';
        meta.className = 'perf-message error';
        return;
      }
      var sequences = payload.sequences;
      var names = [];
      for (var n in sequences) { if (sequences.hasOwnProperty(n)) names.push(n); }
      names.sort();
      if (names.length === 0) {
        meta.textContent = 'No perf data yet — run at least one test cycle.';
        meta.className = 'perf-message';
        return;
      }
      meta.textContent = names.length + ' sequence' + (names.length === 1 ? '' : 's')
        + ' · latest ' + MAX_CYCLES + ' cycles each'
        + ' · generated ' + (payload.generatedAtUtc || 'unknown');
      meta.className = 'perf-message';
      for (var i = 0; i < names.length; i++) {
        body.appendChild(buildSeqCard(names[i], sequences[names[i]] || [], cycleLinks));
      }
      if (staleCycleCount > 0) {
        var warn = document.createElement('div');
        warn.className = 'stale-banner';
        warn.innerHTML =
          '<strong>' + staleCycleCount + ' cycle' + (staleCycleCount === 1 ? '' : 's') + ' lack per-step timing</strong> ' +
          '— drawn as a single gray bar. ' +
          'This usually means the detached status-service process predates the ' +
          '<code>/control/perf-aggregates</code> icicle change. Restart it with: ' +
          '<code>pwsh test/Stop-StatusService.ps1 ; pwsh test/Start-StatusService.ps1</code>' +
          ', then reload this page.';
        body.insertBefore(warn, body.firstChild);
      }
    }

    // cycleId -> cycle-folder URL, joined from status.json so each icicle row
    // can deep-link to that cycle's data folder. The .incomplete / .aborted
    // lifecycle suffix is stripped the same way index.html's history rows do.
    function buildCycleLinks(statusDoc) {
      var map = {};
      if (!statusDoc) return map;
      var strip = stripCycleFolderSuffix;
      var hist = statusDoc.history || [];
      for (var i = 0; i < hist.length; i++) {
        var h = hist[i];
        var id = h.cycleId || h.runId;
        if (id && h.cycleFolderUrl) { map[id] = strip(h.cycleFolderUrl); }
      }
      var liveId = statusDoc.cycleId || statusDoc.runId;
      if (liveId && statusDoc.cycleFolderUrl && !map[liveId]) { map[liveId] = strip(statusDoc.cycleFolderUrl); }
      return map;
    }

    function loadAggregates(recalculate) {
      var meta = document.getElementById('perf-message');
      var body = document.getElementById('perf-body');
      var btn  = document.getElementById('perf-recalc');
      btn.disabled = true;
      var originalLabel = btn.textContent;
      btn.textContent = recalculate ? 'Recalculating…' : 'Loading…';
      if (recalculate) {
        meta.textContent = 'Recalculating perf aggregates…';
        body.innerHTML = '';
      }
      var opts = { cache: 'no-store' };
      if (recalculate) { opts.method = 'POST'; opts.headers = yurunaControlHeaders(); }
      // Two independent fetches: the aggregates drive the icicles; status.json
      // supplies the cycleId -> folder map that makes each row's timestamp a
      // deep link. A status.json miss only costs the links, not the charts.
      var aggP = fetch('control/perf-aggregates', opts).then(function(r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      });
      var statusP = fetch('runtime/status.json?_=' + Date.now(), { cache: 'no-store' })
        .then(function(r) { return r.ok ? r.json() : null; })
        ['catch'](function() { return null; });
      Promise.all([aggP, statusP])
        .then(function(results) {
          renderAggregates(results[0], buildCycleLinks(results[1]));
        })
        ['catch'](function(e) {
          meta.textContent = 'Could not load aggregates: ' + (e.message || e);
          meta.className = 'perf-message error';
          body.innerHTML = '';
        })
        .then(function() {
          btn.disabled = false;
          btn.textContent = originalLabel;
        });
    }

    var recalcBtn = document.getElementById('perf-recalc');
    if (recalcBtn) {
      recalcBtn.addEventListener('click', function() { loadAggregates(true); });
    }

    loadAggregates(false);
  }

  // === hostinfo.html handlers ===
  function bootHostInfo() {
    Yuruna.populateHeader({ href: 'index.html', label: '← Status' });

    function loadServerUserAccount() {
      var bu = document.getElementById('banner-user');
      if (!bu) return;
      fetch('control/runtime-env', { cache: 'no-store' })
        .then(function(r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
        .then(function(j) {
          var v = (j && typeof j.serverUserAccount === 'string') ? j.serverUserAccount : '';
          bu.textContent = v === '' ? '(unknown)' : v;
        })
        ['catch'](function() { bu.textContent = '(unavailable)'; });
    }
    loadServerUserAccount();
    startBannerPolling();

    var el = document.getElementById('hostinfo-output');
    fetch('control/host-diagnostic?_=' + Date.now(), { cache: 'no-store', headers: yurunaControlHeaders() })
      .then(function(res) { if (!res.ok) throw new Error('HTTP ' + res.status); return res.text(); })
      .then(function(text) { el.className = ''; el.textContent = text || '(no output)'; })
      ['catch'](function(e) { el.className = 'error'; el.textContent = 'Could not load: ' + (e.message || e); });
  }

  // === test.config.html handlers ===
  function bootTestConfig() {
    var PAGE_CTA = { href: 'index.html', label: '← Status' };

    var configState = null;
    var availableGuestFolders = null;
    // Serialized snapshot of configState taken the moment the tree loads.
    // The editor mutates configState in place, so comparing a fresh
    // serialization against this baseline tells us whether the operator has
    // unsaved edits — used to gate the Escape/discard exit behind a confirm.
    var pristineConfigJson = null;

    function serializeConfig() {
      try { return JSON.stringify(configState); }
      catch (e) { return null; }
    }
    function isConfigDirty() {
      if (pristineConfigJson === null) return false;
      var current = serializeConfig();
      // A serialization failure is ambiguous; treat it as dirty so the
      // operator is asked rather than losing edits silently.
      return current === null || current !== pristineConfigJson;
    }

    function loadGuestFolders() {
      return fetch('control/guest-folders?_=' + Date.now(), { cache: 'no-store' })
        .then(function(res) {
          if (!res.ok) { availableGuestFolders = null; return null; }
          return res.json().then(function(data) {
            availableGuestFolders = (Array.isArray(data) && data.length) ? data : null;
          });
        })
        ['catch'](function() { availableGuestFolders = null; });
    }

    function loadConfig() {
      var body     = document.getElementById('config-body');
      var status   = document.getElementById('config-status');
      var saveBtn  = document.getElementById('config-save');
      var startBtn = document.getElementById('config-save-start');
      body.innerHTML = '<div class="tree-empty">Loading…</div>';
      status.textContent = '';
      status.className = '';
      saveBtn.disabled  = true;
      startBtn.disabled = true;
      return Promise.all([
        fetch('control/test-config?_=' + Date.now(), { cache: 'no-store' }),
        loadGuestFolders()
      ]).then(function(results) {
        var configRes = results[0];
        if (!configRes.ok) throw new Error('HTTP ' + configRes.status);
        return configRes.text();
      }).then(function(text) {
        configState = JSON.parse(text);
        pristineConfigJson = serializeConfig();
        body.innerHTML = '';
        body.appendChild(renderConfigNode(configState, null, null));
        saveBtn.disabled  = false;
        startBtn.disabled = false;
      })['catch'](function(e) {
        body.innerHTML = '';
        status.textContent = 'Could not load config: ' + e.message;
        status.className = 'error';
      });
    }

    function discardAndExit() {
      if (isConfigDirty() &&
          !window.confirm('Discard unsaved config changes and return to status?')) {
        return;
      }
      window.location.replace('index.html');
    }

    function renderConfigNode(value, parent, keyOrIndex, arrayRerender) {
      var node = document.createElement('div');
      node.className = 'tree-node';
      var row = document.createElement('div');
      row.className = 'tree-row';
      node.appendChild(row);

      var toggle = document.createElement('span');
      toggle.className = 'tree-toggle leaf';
      toggle.textContent = '';
      row.appendChild(toggle);

      var isRoot = (parent === null);
      var keyEl = document.createElement('span');
      keyEl.className = 'tree-key';
      if (isRoot) {
        keyEl.textContent = 'test.config.yml';
      } else if (Array.isArray(parent)) {
        keyEl.classList.add('array-index');
        if (isguestSequenceArray(parent)) keyEl.classList.add('narrow');
        keyEl.textContent = '[' + keyOrIndex + ']';
      } else {
        keyEl.textContent = keyOrIndex;
      }
      row.appendChild(keyEl);

      var type = jsonType(value);

      if (type === 'object' || type === 'array') {
        toggle.classList.remove('leaf');
        var expanded = true;
        toggle.textContent = '▼';
        var typeEl = null;
        if (!isRoot) {
          typeEl = document.createElement('span');
          typeEl.className = 'tree-type';
          var c0 = (type === 'array') ? value.length : Object.keys(value).length;
          typeEl.textContent = type + ' (' + c0 + ')';
          row.appendChild(typeEl);
        }

        var children = document.createElement('div');
        children.className = 'tree-children';
        node.appendChild(children);

        if (type === 'array') {
          var renderArrayChildren = function() {
            children.innerHTML = '';
            var isguestSequence = isguestSequenceArray(value) && availableGuestFolders;
            value.forEach(function(item, idx) {
              var childNode = renderConfigNode(item, value, idx, renderArrayChildren);
              // Find the direct-child .tree-row WITHOUT the :scope selector, which throws a
              // SyntaxError on Safari < 10 and would abort the whole config-tree render. The
              // row is the node's own first element child; scan direct children defensively.
              var childRow = null;
              var rowKids = childNode.children;
              for (var rk = 0; rk < rowKids.length; rk++) {
                if ((' ' + rowKids[rk].className + ' ').indexOf(' tree-row ') !== -1) { childRow = rowKids[rk]; break; }
              }
              if (childRow) {
                var del = document.createElement('button');
                del.type = 'button';
                del.className = 'tree-array-delete';
                del.title = 'Delete item ' + idx;
                del.setAttribute('aria-label', 'Delete item ' + idx);
                del.textContent = '✕';
                (function(capturedIdx) {
                  del.onclick = function(e) {
                    e.stopPropagation();
                    value.splice(capturedIdx, 1);
                    renderArrayChildren();
                  };
                })(idx);
                childRow.appendChild(del);
              }
              children.appendChild(childNode);
            });
            if (value.length === 0) {
              var empty = document.createElement('div');
              empty.className = 'tree-empty';
              empty.textContent = '(empty array)';
              children.appendChild(empty);
            }
            var addBtn = document.createElement('button');
            addBtn.type = 'button';
            addBtn.className = 'tree-array-add';
            if (isguestSequence) {
              var used = {};
              for (var i = 0; i < value.length; i++) used[value[i]] = true;
              var remaining = availableGuestFolders.filter(function(g) {
                return !used[g];
              });
              if (remaining.length === 0) {
                addBtn.textContent = '+ add item (all guests added)';
                addBtn.disabled = true;
                addBtn.title = 'Every guest folder under this host is already in the list';
              } else {
                addBtn.textContent = '+ add item';
                addBtn.onclick = function() {
                  var usedNow = {};
                  for (var j = 0; j < value.length; j++) usedNow[value[j]] = true;
                  var candidate = null;
                  for (var k = 0; k < availableGuestFolders.length; k++) {
                    if (!usedNow[availableGuestFolders[k]]) {
                      candidate = availableGuestFolders[k];
                      break;
                    }
                  }
                  if (!candidate) return;
                  value.push(candidate);
                  renderArrayChildren();
                };
              }
            } else {
              addBtn.textContent = '+ add item';
              addBtn.onclick = function() {
                value.push(defaultForArray(value));
                renderArrayChildren();
              };
            }
            children.appendChild(addBtn);
            if (typeEl) typeEl.textContent = type + ' (' + value.length + ')';
          };
          renderArrayChildren();
        } else {
          var keys = Object.keys(value);
          if (isRoot && keys.indexOf('logLevel') > 0) {
            keys.splice(keys.indexOf('logLevel'), 1);
            keys.unshift('logLevel');
          }
          for (var i = 0; i < keys.length; i++) {
            children.appendChild(renderConfigNode(value[keys[i]], value, keys[i]));
          }
          if (keys.length === 0) {
            var emptyObj = document.createElement('div');
            emptyObj.className = 'tree-empty';
            emptyObj.textContent = '(empty object)';
            children.appendChild(emptyObj);
          }
        }

        var flip = function() {
          expanded = !expanded;
          toggle.textContent = expanded ? '▼' : '▶';
          children.classList.toggle('collapsed', !expanded);
        };
        toggle.onclick = flip;
        keyEl.onclick = flip;
        keyEl.style.cursor = 'pointer';
        return node;
      }

      if (type === 'boolean') {
        row.appendChild(buildBoolInput(value, parent, keyOrIndex));
      } else if (type === 'number') {
        row.appendChild(buildNumberInput(value, parent, keyOrIndex));
      } else if (type === 'string') {
        if (isguestSequenceArray(parent) && availableGuestFolders) {
          row.appendChild(buildGuestSelect(value, parent, keyOrIndex, arrayRerender));
        } else {
          var enums = enumOptions(parent, keyOrIndex);
          if (enums) {
            row.appendChild(buildEnumInput(value, parent, keyOrIndex, enums));
          } else {
            row.appendChild(buildStringInput(value, parent, keyOrIndex));
          }
        }
      } else if (type === 'null') {
        var span = document.createElement('span');
        span.className = 'tree-null';
        span.textContent = 'null';
        row.appendChild(span);
      } else {
        var spanOther = document.createElement('span');
        spanOther.className = 'tree-null';
        spanOther.textContent = '(' + type + ')';
        row.appendChild(spanOther);
      }
      return node;
    }

    function jsonType(v) {
      if (v === null) return 'null';
      if (Array.isArray(v)) return 'array';
      return typeof v;
    }

    function defaultForArray(arr) {
      if (arr.length === 0) return '';
      var last = arr[arr.length - 1];
      switch (jsonType(last)) {
        case 'string':  return '';
        case 'number':  return 0;
        case 'boolean': return false;
        case 'array':   return [];
        case 'object':  return {};
        default:        return '';
      }
    }

    function buildBoolInput(value, parent, key) {
      var wrap = document.createElement('span');
      wrap.className = 'tree-bool';

      var label = document.createElement('span');
      label.className = 'tree-bool-label ' + (value ? 'true' : 'false');
      label.textContent = value ? 'True' : 'False';

      var sw = document.createElement('label');
      sw.className = 'tree-bool-switch';
      var cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = !!value;
      cb.setAttribute('role', 'switch');
      cb.setAttribute('aria-checked', String(!!value));
      var track = document.createElement('span');
      track.className = 'tree-bool-track';
      sw.appendChild(cb);
      sw.appendChild(track);
      cb.onchange = function() {
        parent[key] = cb.checked;
        label.textContent = cb.checked ? 'True' : 'False';
        label.className = 'tree-bool-label ' + (cb.checked ? 'true' : 'false');
        cb.setAttribute('aria-checked', String(cb.checked));
      };

      wrap.appendChild(sw);
      wrap.appendChild(label);
      return wrap;
    }

    function buildNumberInput(value, parent, key) {
      var input = document.createElement('input');
      input.type = 'number';
      input.step = 'any';
      input.className = 'tree-input number';
      input.value = String(value);
      input.oninput = function() {
        var n = input.value === '' ? 0 : Number(input.value);
        parent[key] = isFinite(n) ? n : 0;
      };
      return input;
    }

    function buildStringInput(value, parent, key) {
      var input = document.createElement('input');
      input.type = 'text';
      input.className = 'tree-input string';
      input.value = value;
      input.spellcheck = false;
      // Mobile-keyboard hints: tree-input strings are hostnames / IPs /
      // identifiers, not prose. Suppress autocorrect's "did you mean"
      // word-swap (iOS Safari corrupts hostnames otherwise) and the
      // sentence-case bump.
      input.setAttribute('autocorrect', 'off');
      input.setAttribute('autocapitalize', 'off');

      var refreshHint = null;
      if (key === 'cachingProxyIP') {
        input.placeholder = 'e.g. 192.168.1.42 (probed first; empty = env-var fallback, else local discovery)';
        // url inputmode gives mobile keyboards the dot + digits row first,
        // matching the IPv4 / IPv6 / FQDN values this field accepts.
        input.inputMode = 'url';
        refreshHint = function() {
          var v = input.value.trim();
          if (v === '' || isIpAddressLike(v)) {
            input.classList.remove('invalid-ip');
            input.removeAttribute('title');
          } else {
            input.classList.add('invalid-ip');
            input.title = 'Not a valid IPv4 or IPv6 address. Save will be rejected.';
          }
        };
        refreshHint();
      }

      input.oninput = function() {
        parent[key] = input.value;
        if (refreshHint) refreshHint();
      };

      if (key === 'cachingProxyIP') {
        var wrap = document.createElement('div');
        wrap.className = 'cache-ip-wrap';

        var editRow = document.createElement('div');
        editRow.className = 'cache-ip-input-row';
        editRow.appendChild(input);
        var editMark = buildCacheIpMark();
        editRow.appendChild(editMark);
        wrap.appendChild(editRow);

        var editProbe = makeCacheIpProbeDriver(editMark);
        var originalOnInput = input.oninput;
        input.oninput = function() {
          if (originalOnInput) originalOnInput();
          editProbe(input.value, false);
        };
        input.addEventListener('blur', function() {
          editProbe(input.value, true);
        });
        editProbe(input.value, true);

        var envRow = document.createElement('div');
        envRow.className = 'cache-ip-envrow';
        var envLabel = document.createElement('span');
        envLabel.className = 'cache-ip-envlabel';
        envLabel.textContent = '$env:YURUNA_CACHING_PROXY_IP =';
        var envInput = document.createElement('input');
        envInput.type = 'text';
        envInput.className = 'tree-input string cache-ip-envinput';
        envInput.readOnly = true;
        envInput.spellcheck = false;
        // Read-only display field — suppress the mobile OSK on tap-to-
        // focus and the autocorrect / autocapitalize hints that would
        // never apply.
        envInput.inputMode = 'none';
        envInput.setAttribute('autocorrect', 'off');
        envInput.setAttribute('autocapitalize', 'off');
        envInput.tabIndex = -1;
        envInput.value = '(loading…)';
        envInput.title = 'Process-environment value the status server inherited at startup. Read-only here; fallback source only: at cycle start the vmStart.cachingProxyIP field above is probed first and wins when its :3128 answers. Export this in the shell that launches Invoke-TestRunner.ps1 for hosts whose config field is empty.';
        var envMark = buildCacheIpMark();
        envRow.appendChild(envLabel);
        envRow.appendChild(envInput);
        envRow.appendChild(envMark);
        wrap.appendChild(envRow);

        var envProbe = makeCacheIpProbeDriver(envMark);
        fetchRuntimeEnv().then(function(envObj) {
          var v = (envObj && typeof envObj.YURUNA_CACHING_PROXY_IP === 'string') ? envObj.YURUNA_CACHING_PROXY_IP : '';
          envInput.value = v === '' ? '(unset)' : v;
          envProbe(v, true);
        })['catch'](function() {
          envInput.value = '(unavailable)';
          envProbe('', true);
        });

        return wrap;
      }

      return input;
    }

    function buildCacheIpMark() {
      var mark = document.createElement('span');
      mark.className = 'cache-ip-mark disabled';
      mark.textContent = '✗';
      mark.title = 'Enter a valid IP address to test caching-proxy connectivity from host.';
      mark.setCacheIpState = function(state, tooltip) {
        mark.className = 'cache-ip-mark ' + state;
        if (state === 'ok')           mark.textContent = '✓';
        else if (state === 'pending') mark.textContent = '⏳';
        else                          mark.textContent = '✗';
        mark.title = tooltip;
      };
      return mark;
    }

    function makeCacheIpProbeDriver(markEl) {
      var debounceTimer    = null;
      var latestId         = 0;
      var lastProbedValue  = null;

      return function(ip, trigger) {
        if (debounceTimer) { clearTimeout(debounceTimer); debounceTimer = null; }
        var myId = ++latestId;
        var v = (ip || '').trim();

        if (v === '' || !isIpAddressLike(v)) {
          lastProbedValue = null;
          markEl.setCacheIpState('disabled',
            v === '' ? 'No IP set — nothing to test.'
                     : 'Not a valid IPv4 or IPv6 address — test skipped.');
          return;
        }

        if (!trigger) {
          if (v === lastProbedValue) return;
          markEl.setCacheIpState('disabled', 'Leave the field to test caching proxy from host.');
          return;
        }

        if (v === lastProbedValue) return;

        markEl.setCacheIpState('pending', 'Testing caching proxy from host…');
        debounceTimer = setTimeout(function() {
          if (myId !== latestId) return;
          // Deliberately do NOT disable the field while probing. The current
          // value can be a dead cache whose host-side test runs ~40 s (4 ports
          // x 3 attempts x 3 s timeouts); disabling the input then makes it
          // impossible to edit the field to move OFF that dead value. The
          // myId/latestId guard already discards a stale probe once the value
          // changes, so the mark just updates in the background while the
          // operator keeps typing. Bound the fetch (AbortController where
          // available) so a black-holed cache resolves to a failed mark instead
          // of an indefinite pending one.
          var ctrl     = (typeof AbortController !== 'undefined') ? new AbortController() : null;
          var timedOut = false;
          var timer    = setTimeout(function() { timedOut = true; if (ctrl) { ctrl.abort(); } }, 15000);
          fetch('control/test-caching-proxy?ip=' + encodeURIComponent(v) + '&_=' + Date.now(),
                { method: 'POST', cache: 'no-store', headers: yurunaControlHeaders(),
                  signal: ctrl ? ctrl.signal : undefined })
            .then(function(r) {
              clearTimeout(timer);
              if (!r.ok) throw new Error('HTTP ' + r.status);
              return r.json();
            })
            .then(function(j) {
              if (myId !== latestId) return;
              if (!j || j.valid !== true) {
                lastProbedValue = null;
                markEl.setCacheIpState('disabled', 'Server reports IP not valid — test skipped.');
                return;
              }
              lastProbedValue = v;
              if (j.success === true) {
                markEl.setCacheIpState('ok',
                  'Test caching proxy from host succeeded (' + j.passCount + ' pass'
                  + (j.warnCount ? ', ' + j.warnCount + ' warn' : '') + ').');
              } else {
                markEl.setCacheIpState('fail',
                  'Test caching proxy from host failed (' + j.failCount + ' fail'
                  + (j.warnCount ? ', ' + j.warnCount + ' warn' : '')
                  + (j.passCount ? ', ' + j.passCount + ' pass' : '') + ').');
              }
            })
            ['catch'](function(e) {
              clearTimeout(timer);
              if (myId !== latestId) return;
              lastProbedValue = null;
              markEl.setCacheIpState('disabled',
                timedOut ? 'Caching-proxy test timed out (15 s) — not reachable from this host?'
                         : 'Caching-proxy test endpoint unavailable: ' + e.message);
            });
        }, 350);
      };
    }

    var _runtimeEnvPromise = null;
    function fetchRuntimeEnv() {
      if (_runtimeEnvPromise) return _runtimeEnvPromise;
      _runtimeEnvPromise = fetch('control/runtime-env', { cache: 'no-store' })
        .then(function(r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
      return _runtimeEnvPromise;
    }

    function isIpAddressLike(s) {
      if (!s) return false;
      var v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
      if (v4) {
        for (var i = 1; i <= 4; i++) {
          var n = parseInt(v4[i], 10);
          if (!(n >= 0 && n <= 255)) return false;
          if (v4[i].length > 1 && v4[i].charAt(0) === '0') return false;
        }
        return true;
      }
      if (/^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}$/.test(s)) return true;
      if (/^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$/.test(s) && s.indexOf('::') >= 0) return true;
      return false;
    }

    function enumOptions(parent, keyOrIndex) {
      if (!parent || Array.isArray(parent)) return null;
      if (keyOrIndex === 'keystrokeMechanism') return ['GUI', 'SSH'];
      if (keyOrIndex === 'logLevel') return ['Error', 'Warning', 'Information', 'Verbose', 'Debug'];
      return null;
    }

    function isguestSequenceArray(arr) {
      return !!(configState && Array.isArray(arr) && arr === configState.guestSequence);
    }

    function buildCustomSelect(opts) {
      var wrap = document.createElement('div');
      wrap.className = 'ydd';
      wrap.tabIndex = 0;
      wrap.setAttribute('role', 'combobox');
      wrap.setAttribute('aria-haspopup', 'listbox');
      wrap.setAttribute('aria-expanded', 'false');

      var current = document.createElement('span');
      current.className = 'ydd-current';
      wrap.appendChild(current);

      var arrow = document.createElement('span');
      arrow.className = 'ydd-arrow';
      arrow.textContent = '▾';
      wrap.appendChild(arrow);

      var menu = document.createElement('div');
      menu.className = 'ydd-menu';
      menu.setAttribute('role', 'listbox');
      menu.hidden = true;
      wrap.appendChild(menu);

      var optionEls = [];
      var selectedValue = opts.value;
      var activeIndex = -1;

      function findOptionForValue(v) {
        for (var i = 0; i < opts.options.length; i++) {
          if (opts.options[i].value === v && !opts.options[i].disabled) return i;
        }
        return -1;
      }

      function render() {
        var idx = findOptionForValue(selectedValue);
        if (idx >= 0) {
          current.textContent = opts.options[idx].label;
          current.classList.remove('ydd-stale');
        } else if (opts.placeholderLabel) {
          current.textContent = opts.placeholderLabel;
          current.classList.add('ydd-stale');
        } else {
          current.textContent = selectedValue || '';
          current.classList.remove('ydd-stale');
        }
        for (var i = 0; i < optionEls.length; i++) {
          var item = opts.options[i];
          var sel = item.value === selectedValue && !item.disabled;
          optionEls[i].classList.toggle('is-selected', sel);
          optionEls[i].setAttribute('aria-selected', sel ? 'true' : 'false');
        }
      }

      for (var i = 0; i < opts.options.length; i++) {
        (function (item, idx) {
          var el = document.createElement('div');
          el.className = 'ydd-item';
          if (item.disabled) el.classList.add('is-disabled');
          el.setAttribute('role', 'option');
          el.textContent = item.label;
          // pointerdown unifies mouse + touch + pen where Pointer Events exist. Older iOS
          // Safari (< 13) has no Pointer Events, so without a fallback an option could not be
          // selected at all; there, use mousedown (desktop) + touchstart (touch), whose
          // preventDefault suppresses the emulated mouse events so the handler fires once.
          var selectItem = function (e) {
            if (e && e.preventDefault) e.preventDefault();
            if (item.disabled) return;
            selectedValue = item.value;
            close();
            render();
            if (typeof opts.onChange === 'function') {
              opts.onChange(selectedValue);
            }
          };
          if (window.PointerEvent) {
            el.onpointerdown = selectItem;
          } else {
            el.onmousedown = selectItem;
            el.addEventListener('touchstart', selectItem, false);
          }
          // Desktop-only highlight-on-hover; touch devices have no hover
          // and rely on tap-to-select (above) without a preview state.
          el.onmouseenter = function () {
            if (!item.disabled) { activeIndex = idx; updateActive(); }
          };
          optionEls.push(el);
          menu.appendChild(el);
        })(opts.options[i], i);
      }

      function updateActive() {
        for (var i = 0; i < optionEls.length; i++) {
          optionEls[i].classList.toggle('is-active', i === activeIndex);
        }
        if (activeIndex >= 0 && optionEls[activeIndex]) {
          var el = optionEls[activeIndex];
          var elTop = el.offsetTop;
          var elBot = elTop + el.offsetHeight;
          if (elTop < menu.scrollTop) menu.scrollTop = elTop;
          else if (elBot > menu.scrollTop + menu.clientHeight) {
            menu.scrollTop = elBot - menu.clientHeight;
          }
        }
      }

      // Pointer Events where available; otherwise the mouse+touch pair (older iOS Safari)
      // so an outside tap still closes the menu.
      var docCloseEvents = window.PointerEvent ? ['pointerdown'] : ['mousedown', 'touchstart'];
      function open() {
        if (!menu.hidden) return;
        menu.hidden = false;
        wrap.setAttribute('aria-expanded', 'true');
        wrap.classList.add('is-open');
        activeIndex = findOptionForValue(selectedValue);
        if (activeIndex < 0) {
          for (var i = 0; i < opts.options.length; i++) {
            if (!opts.options[i].disabled) { activeIndex = i; break; }
          }
        }
        updateActive();
        for (var dci = 0; dci < docCloseEvents.length; dci++) {
          document.addEventListener(docCloseEvents[dci], onDocPointerDown, true);
        }
      }

      function close() {
        if (menu.hidden) return;
        menu.hidden = true;
        wrap.setAttribute('aria-expanded', 'false');
        wrap.classList.remove('is-open');
        activeIndex = -1;
        for (var i = 0; i < optionEls.length; i++) {
          optionEls[i].classList.remove('is-active');
        }
        for (var dcj = 0; dcj < docCloseEvents.length; dcj++) {
          document.removeEventListener(docCloseEvents[dcj], onDocPointerDown, true);
        }
      }

      function onDocPointerDown(e) {
        if (!wrap.contains(e.target)) close();
      }

      function moveActive(delta) {
        var n = opts.options.length;
        if (n === 0) return;
        var i = activeIndex;
        for (var step = 0; step < n; step++) {
          i = (i + delta + n) % n;
          if (!opts.options[i].disabled) { activeIndex = i; break; }
        }
        updateActive();
      }

      function keyOf(e) {
        if (e.key) return e.key;
        switch (e.keyCode) {
          case 13: return 'Enter';
          case 27: return 'Escape';
          case 32: return ' ';
          case 38: return 'ArrowUp';
          case 40: return 'ArrowDown';
          default: return '';
        }
      }

      wrap.onclick = function (e) {
        if (menu.contains(e.target)) return;
        if (menu.hidden) open(); else close();
      };

      wrap.onkeydown = function (e) {
        var k = keyOf(e);
        if (menu.hidden) {
          if (k === 'ArrowDown' || k === 'ArrowUp' || k === 'Enter' || k === ' ') {
            e.preventDefault(); open();
          }
          return;
        }
        if (k === 'Escape') {
          // Escape here only dismisses the open menu. Without stopPropagation
          // it would also reach the page-level keydown handler, which reads a
          // bare Escape as "discard the whole edit session" — closing a dropdown
          // would silently throw away every unsaved config change.
          e.preventDefault(); e.stopPropagation(); close();
        } else if (k === 'ArrowDown') {
          e.preventDefault(); moveActive(1);
        } else if (k === 'ArrowUp') {
          e.preventDefault(); moveActive(-1);
        } else if (k === 'Enter' || k === ' ') {
          e.preventDefault();
          if (activeIndex >= 0 && !opts.options[activeIndex].disabled) {
            selectedValue = opts.options[activeIndex].value;
            close();
            render();
            if (typeof opts.onChange === 'function') {
              opts.onChange(selectedValue);
            }
          }
        }
      };

      wrap.onblur = function () {
        setTimeout(function () {
          if (!wrap.contains(document.activeElement)) close();
        }, 0);
      };

      render();
      return wrap;
    }

    function buildGuestSelect(value, parent, idx, onChange) {
      var used = {};
      for (var i = 0; i < parent.length; i++) {
        if (i !== idx && typeof parent[i] === 'string') used[parent[i]] = true;
      }
      var allowed = availableGuestFolders.filter(function(g) {
        return g === value || !used[g];
      });
      var matched = false;
      var options = [];
      for (var j = 0; j < allowed.length; j++) {
        var g = allowed[j];
        if (g === value) matched = true;
        options.push({ value: g, label: g.replace(/^guest\./, '') });
      }
      var placeholderLabel = null;
      if (!matched) {
        placeholderLabel = (value || '(empty)') + ' (not under host folder)';
        options.unshift({ value: value, label: placeholderLabel, disabled: true });
      }
      return buildCustomSelect({
        value: value,
        options: options,
        placeholderLabel: placeholderLabel,
        onChange: function (newValue) {
          parent[idx] = newValue;
          if (typeof onChange === 'function') setTimeout(onChange, 0);
        }
      });
    }

    function buildEnumInput(value, parent, key, options) {
      var current = String(value);
      var matched = false;
      var optList = [];
      for (var i = 0; i < options.length; i++) {
        if (options[i] === current) matched = true;
        optList.push({ value: options[i], label: options[i] });
      }
      var placeholderLabel = null;
      if (!matched) {
        placeholderLabel = current + ' (invalid — pick one)';
        optList.unshift({ value: current, label: placeholderLabel, disabled: true });
        parent[key] = options[0];
      }
      return buildCustomSelect({
        value: current,
        options: optList,
        placeholderLabel: placeholderLabel,
        onChange: function (newValue) { parent[key] = newValue; }
      });
    }

    function saveConfig() {
      var status     = document.getElementById('config-status');
      var saveBtn    = document.getElementById('config-save');
      var discardBtn = document.getElementById('config-discard');
      var startBtn   = document.getElementById('config-save-start');
      if (!configState) return;
      var payload;
      try {
        payload = JSON.stringify(configState, null, 2) + '\n';
      } catch (e) {
        status.textContent = 'Could not serialize: ' + e.message;
        status.className = 'error';
        return;
      }
      saveBtn.disabled    = true;
      discardBtn.disabled = true;
      startBtn.disabled   = true;
      status.textContent = 'Saving…';
      status.className = '';
      fetch('control/test-config', {
        method: 'POST',
        cache: 'no-store',
        headers: yurunaControlHeaders({ 'Content-Type': 'application/json' }),
        body: payload
      }).then(function(res) {
        return res.text().then(function(text) {
          var body = null;
          try { body = JSON.parse(text); } catch (_e) { /* non-JSON error */ }
          if (!res.ok || !body || !body.ok) {
            var msg = (body && body.error) ? body.error : ('HTTP ' + res.status);
            status.textContent = 'Save failed: ' + msg;
            status.className = 'error';
            saveBtn.disabled    = false;
            discardBtn.disabled = false;
            startBtn.disabled   = false;
            return;
          }
          status.textContent = 'Saved. Returning to status…';
          status.className = 'ok';
          setTimeout(function() { window.location.replace('index.html'); }, 600);
        });
      })['catch'](function(e) {
        status.textContent = 'Save failed: ' + e.message;
        status.className = 'error';
        saveBtn.disabled    = false;
        discardBtn.disabled = false;
        startBtn.disabled   = false;
      });
    }

    function saveAndStartCycle() {
      fetch('control/runner-status?_=' + Date.now(), { cache: 'no-store' })
        .then(function(res) {
          if (!res.ok) throw new Error('HTTP ' + res.status);
          return res.json();
        })
        .then(function(status) {
          var isRunning = !!(status && status.running);
          if (isRunning) {
            var ok = window.confirm(
              'A cycle is currently running. Save the config, abort the ' +
              'running cycle, and start a new one? In-progress VMs are removed ' +
              'first -- this is not instant: each running VM is given up to ' +
              '~30 seconds to shut down (macOS/UTM is the slowest), so with ' +
              'several VMs up the new cycle can take a minute or two to begin.'
            );
            if (!ok) return;
          }
          doSaveAndStartCycle();
        })
        ['catch'](function(e) {
          var ok = window.confirm(
            'Could not determine runner status (' + e.message + '). ' +
            'Save and start cycle anyway? In-progress VMs (if any) are removed ' +
            'first -- up to ~30 seconds per running VM (macOS/UTM is the ' +
            'slowest), so the new cycle may take a minute or two to begin.'
          );
          if (ok) doSaveAndStartCycle();
        });
    }

    function doSaveAndStartCycle() {
      var status     = document.getElementById('config-status');
      var saveBtn    = document.getElementById('config-save');
      var discardBtn = document.getElementById('config-discard');
      var startBtn   = document.getElementById('config-save-start');
      if (!configState) return;
      var payload;
      try {
        payload = JSON.stringify(configState, null, 2) + '\n';
      } catch (e) {
        status.textContent = 'Could not serialize: ' + e.message;
        status.className = 'error';
        return;
      }
      saveBtn.disabled    = true;
      discardBtn.disabled = true;
      startBtn.disabled   = true;
      status.textContent = 'Saving config…';
      status.className = '';
      fetch('control/test-config', {
        method: 'POST',
        cache: 'no-store',
        headers: yurunaControlHeaders({ 'Content-Type': 'application/json' }),
        body: payload
      }).then(function(res) {
        return res.text().then(function(text) {
          var body = null;
          try { body = JSON.parse(text); } catch (_e) { /* non-JSON error */ }
          if (!res.ok || !body || !body.ok) {
            var msg = (body && body.error) ? body.error : ('HTTP ' + res.status);
            throw new Error(msg);
          }
          status.textContent = 'Saved. Stopping in-progress VMs (up to ~30s each) and starting a new cycle -- this can take a minute or two…';
          return fetch('control/start-cycle', {
            method: 'POST',
            cache: 'no-store',
            headers: yurunaControlHeaders()
          });
        });
      }).then(function(res) {
        return res.text().then(function(text) {
          var body = null;
          try { body = JSON.parse(text); } catch (_e) { /* non-JSON error */ }
          if (!res.ok || !body || !body.ok) {
            var msg = (body && body.error) ? body.error : ('HTTP ' + res.status);
            throw new Error(msg);
          }
          var verb = body.action === 'spawned' ? 'Runner started' : 'Cycle restarted';
          status.textContent = verb + '. Returning to status in 6 seconds…';
          status.className = 'ok';
          setTimeout(function() { window.location.replace('index.html'); }, 6000);
        });
      })['catch'](function(e) {
        status.textContent = 'Save and start cycle failed: ' + e.message;
        status.className = 'error';
        saveBtn.disabled    = false;
        discardBtn.disabled = false;
        startBtn.disabled   = false;
      });
    }

    document.getElementById('config-discard').addEventListener('click', discardAndExit);
    document.getElementById('config-save').addEventListener('click', saveConfig);
    document.getElementById('config-save-start').addEventListener('click', saveAndStartCycle);
    document.addEventListener('keydown', function(e) {
      var isEsc = (e.key === 'Escape') ||
                  (e.key === 'Esc') ||
                  (e.keyCode === 27) ||
                  (e.which === 27);
      if (isEsc) {
        // Stop the Escape here once we own it as "exit the editor" so no other
        // listener re-handles the same keystroke. An open dropdown's own Escape
        // handler stops propagation first, so it never reaches this point.
        e.stopPropagation();
        discardAndExit();
      }
    });

    startBannerPolling();
    Yuruna.populateHeader(PAGE_CTA);
    loadConfig();
  }

  // Page dispatch keyed on a stable per-page id. Each page boots exactly
  // one of these (id presence is mutually exclusive across the four
  // status pages).
  onReady(function() {
    if (document.getElementById('cycle-pause-btn')) {
      bootIndex();
    } else if (document.getElementById('perf-recalc')) {
      bootPerf();
    } else if (document.getElementById('hostinfo-output')) {
      bootHostInfo();
    } else if (document.getElementById('config-body')) {
      bootTestConfig();
    }
  });
})();
