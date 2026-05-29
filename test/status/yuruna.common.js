/*
  LICENSEURI https://yuruna.link/license
  Copyright (c) 2019-2026 by Alisson Sol et al.
  Version: 2026.05.29

  Shared helpers for the Yuruna status pages. Mounted on window.Yuruna.
  --- See https://yuruna.link/definition#defining-the-status-page-browser-baseline
  --- See https://yuruna.link/definition#defining-the-status-page-hostinfo-aggregator
*/
(function() {
  'use strict';

  var VERSION = '2026.05.29';

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

  // --- See https://yuruna.link/definition#defining-the-status-page-visibility-aware-polling
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
    function jsonOrNull(url) {
      return fetch(url, { cache: 'no-store' })
        .then(function(r) { return r.ok ? r.json() : null; })
        ['catch'](function() { return null; });
    }
    Promise.all([
      jsonOrNull('runtime/status.json?_=' + Date.now()),
      jsonOrNull('runtime/current-action.json?_=' + Date.now()),
      jsonOrNull('control/runner-status')
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
  // --- See https://yuruna.link/definition#defining-the-status-page-browser-baseline

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

    var BANNER = {
      idle:    'No test data available',
      running: 'Test in progress',
      pass:    'All guests operational',
      fail:    'Incident detected — see details below',
      stopped: 'Test runner stopped'
    };

    var cachingProxyHtml = '';

    function renderIpAddresses(value) {
      var el = document.getElementById('footer-ip-list');
      if (!el) return;
      el.value = value || '—';
      el.rows = Math.min(2, Math.max(1, el.value.split('\n').length));
    }

    function setBannerTextLocal(statusText) {
      var el = document.getElementById('banner-text');
      if (!el) return;
      el.textContent = statusText || '';
    }

    function applyCachingProxyBanner() {
      var linkEl = document.getElementById('banner-cp');
      var noEl   = document.getElementById('banner-cp-noproxy');
      if (!linkEl || !noEl) return;
      var m = cachingProxyHtml.match(/href="([^"]+)"/i);
      if (m && m[1]) {
        var url = m[1].replace(/&amp;/g, '&');
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

    function controlAction(kind, action) {
      var btn = document.getElementById(kind + '-pause-btn');
      if (btn) btn.disabled = true;
      var endpoint = 'control/' + kind + '-' + action;
      fetch(endpoint, { method: 'POST', cache: 'no-store' })
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
      var err  = step.errorMessage ? ' title="' + step.errorMessage.replace(/"/g,'&quot;') + '"' : '';
      var label = PILL_LABELS[step.name] || step.name;
      return '<span class="step-pill ' + c + '"' + err + '>' + label + skip + '</span>';
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

    function logFileUrl(cycleId, hostname, gitCommit, cycleFolderUrl) {
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
      // being silently stuck with a non-actionable cycle id.
      if (cycleId && hostname && gitCommit) {
        return 'log/' + cycleId.replace(/:/g, '-') + '.' + hostname + '.' + gitCommit + '.html';
      }
      if (cycleId && hostname) {
        // Mirror Format-CycleFolderBaseName: <padded>.<cycleDate>.<cycleTime>.<hostname>
        // We lack the padded counter, so degrade to a directory link the
        // server's index/listing can resolve to the actual cycle folder.
        var iso = String(cycleId);
        var d = (iso.length >= 10) ? iso.substring(0, 10) : '';
        var t = (iso.length >= 19) ? iso.substring(11, 19).replace(/:/g, '-') : '';
        if (d && t) {
          return 'log/?prefix=' + d + '.' + t + '.' + hostname;
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

    function pauseBannerTextLocal(stepPaused, cyclePaused, status, actionData) {
      var stepEffective  = stepPaused &&
        !!(actionData && actionData.line && /Paused \(waiting for resume\)/.test(actionData.line));
      var cycleEffective = cyclePaused && status !== 'running';
      if (stepEffective)  return 'Test paused';
      if (stepPaused)     return 'Test will pause (after current step)';
      if (cycleEffective) return 'Test paused';
      if (cyclePaused)    return 'Test will pause (after current cycle)';
      return null;
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
        var snapHint = breakData.snapshotId
          ? (' (loadDiskSnapshot id="' + escHtml(breakData.snapshotId) + '")')
          : ' (no snapshot to restore)';
        html += ' <button id="break-continue-btn" class="meta-btn paused-active" type="button"' +
                ' title="Restore snapshot' + snapHint.replace(/"/g,'&quot;') + ', start the VM, then resume the sequence">Continue</button>';
      }
      html += '</div>';
      return html;
    }

    function continueFromBreak() {
      var btn = document.getElementById('break-continue-btn');
      if (btn) { btn.disabled = true; btn.textContent = 'Continuing...'; }
      fetch('control/break-continue', { method: 'POST', cache: 'no-store' })
        ['catch'](function(e) { safeWarn('control/break-continue failed:', e); })
        .then(function() { loadStatus(); });
    }

    function renderStatus(data, actionData, breakData, runnerStatus) {
      var noData = document.getElementById('no-data');
      var banner = document.getElementById('banner');
      var headerMachine = document.getElementById('header-machine');

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
        setBannerTextLocal(runnerStopped ? BANNER.stopped : BANNER.idle);
        updatePauseButton('step',  false, false);
        updatePauseButton('cycle', false, false);
        var ids = ['sec-cycle','sec-guests','sec-history'];
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
      var pauseText = pauseBannerTextLocal(stepPaused, cyclePaused, status, actionData);
      var anyPaused = pauseText !== null;
      var effective = anyPaused ? 'paused' : cls(status);
      if (runnerStopped) {
        banner.className = 'stopped';
        setBannerTextLocal(BANNER.stopped);
      } else {
        banner.className = effective;
        setBannerTextLocal(pauseText !== null ? pauseText : (BANNER[status] || status));
      }
      var cycleActive = (status === 'running') || anyPaused;
      updatePauseButton('step',  stepPaused,  cycleActive);
      updatePauseButton('cycle', cyclePaused, cycleActive);

      if (liveCycleId) {
        document.getElementById('sec-cycle').style.display = '';
        var liveCommits = gitCommitsForRender(data, data.repoUrl);
        document.getElementById('cycle-commit').innerHTML = renderCommitLinks(liveCommits);
        var cycleIdLabel = (liveCycleId || '—').slice(0, 19).replace('T', ' T');
        var cycleLogUrl  = logFileUrl(liveCycleId, data.hostname, primaryShaForLog(data), data.cycleFolderUrl);
        var cycleCell = cycleLogUrl
          ? ('<a href="' + cycleLogUrl + '" target="_blank" style="color:inherit;text-decoration:underline dotted">' + cycleIdLabel + '</a>')
          : cycleIdLabel;
        document.getElementById('cycle-timestamp').innerHTML = '<span class="badge ' + cls(status) + '">' + cycleCell + '</span>';
        document.getElementById('cycle-started').textContent  = fmtDate(data.startedAt);
        document.getElementById('cycle-images-refresh').textContent = data.lastGetImageAt ? fmtDate(data.lastGetImageAt) : 'never';
      }

      var guests = data.guests || [];
      if (guests.length) {
        document.getElementById('sec-guests').style.display = '';
        document.getElementById('guest-list').innerHTML = guests.map(function(g) {
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
          var actHtml = guestActionHtml(g, actionData, stepPaused, breakData);
          var metaParts = ' · ';
          if (g.status === 'running' && g.vmName) {
            metaParts = 'VM: ' + escHtml(g.vmName);
          } else if (g.status && g.status !== 'running' && g.status !== 'pending' && dur !== '—') {
            metaParts = 'Duration: ' + dur;
          }
          var topLevelStr = (g.topLevel || '').replace(/^\s+|\s+$/g, '');
          var topHtml = topLevelStr
            ? ('<div class="guest-toplevel">' + escHtml(topLevelStr) + '</div>')
            : '';
          // Live cycle: derive the per-guest folder URL from the
          // current cycleFolderUrl (Set-CycleFolderUrl flips its
          // suffix at the Stop-LogFile rename, so this always
          // matches the on-disk path). g.failureArtifacts records the
          // post-rename URL; using it mid-cycle 404s while the folder
          // is still `<base>.incomplete/<VMName>/`.
          var folderUrl = (data.cycleFolderUrl && g.vmName)
            ? (data.cycleFolderUrl + g.vmName + '/')
            : (g.failureArtifacts || '');
          var titleHtml = folderUrl
            ? ('<a href="' + folderUrl + '" target="_blank" title="Open results folder for ' + escHtml(g.guestKey) + '" style="color:inherit;text-decoration:underline dotted">' + escHtml(g.guestKey) + '</a>')
            : escHtml(g.guestKey);
          var badgeHtml = folderUrl
            ? ('<a href="' + folderUrl + '" target="_blank" title="Open results folder for ' + escHtml(g.guestKey) + '" style="text-decoration:none">' + badge(g.status) + '</a>')
            : badge(g.status);
          return '<div class="guest-card">' +
            '<div class="guest-card-header">' +
              '<div class="left">' +
                '<div class="guest-name">' + titleHtml + '</div>' +
                '<div class="guest-meta">' + metaParts + '</div>' +
              '</div>' +
              '<div>' + badgeHtml + '</div>' +
            '</div>' +
            topHtml +
            '<div class="steps">' + steps + '</div>' +
            actHtml +
            errHtml +
          '</div>';
        }).join('');
      }

      var history = data.history || [];
      if (history.length) {
        document.getElementById('sec-history').style.display = '';
        document.getElementById('history-body').innerHTML = history.map(function(h) {
          var gs = h.guestSummary || {};
          var guestPills = Object.keys(gs).map(function(k) {
            var v        = gs[k];
            var status   = (typeof v === 'string') ? v : (v && v.status) || '';
            var debugUrl = (typeof v === 'object' && v) ? v.failureArtifacts : '';
            var label    = k.replace('guest.','');
            var pillHtml = '<span class="badge ' + cls(status) + '">' + label + '</span>';
            if (debugUrl) {
              return '<a href="' + debugUrl + '" target="_blank" title="Open debug folder for ' + label + '" style="text-decoration:none">' + pillHtml + '</a>';
            }
            return pillHtml;
          }).join(' ');
          var hCycleId    = h.cycleId || h.runId;
          // Legacy entries (recorded before Complete-Run started
          // stripping the suffix) saved the in-progress `.incomplete/`
          // URL into history. Strip on read so those rows resolve to
          // the post-rename folder on disk.
          var hCycleFolderUrl = h.cycleFolderUrl
            ? h.cycleFolderUrl
                .replace(/\.incomplete(\/?)$/, '$1')
                .replace(/\.aborted\.[^/]+(\/?)$/, '$1')
            : h.cycleFolderUrl;
          var hLogUrl     = logFileUrl(hCycleId, h.hostname, primaryShaForLog(h), hCycleFolderUrl);
          var hCycleLabel = (hCycleId || '—').slice(0, 19).replace('T', ' <wbr>T');
          var hCycleCell  = hLogUrl
            ? ('<a href="' + hLogUrl + '" target="_blank" style="color:inherit;text-decoration:underline dotted">' + hCycleLabel + '</a>')
            : hCycleLabel;
          var statusCls  = cls(h.overallStatus);
          var commitCell = renderCommitLinks(gitCommitsForRender(h, data.repoUrl));
          return '<tr>' +
            '<td class="mono"><span class="badge ' + statusCls + '">' + hCycleCell + '</span></td>' +
            '<td>' + fmtDuration(h.startedAt, h.finishedAt) + '</td>' +
            '<td>' + guestPills + '</td>' +
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
      function jsonOrNull(url, opts) {
        return fetch(url, opts || {})
          .then(function(res) { return res.ok ? res.json() : null; })
          ['catch'](function() { return null; });
      }
      Promise.all([
        statusPromise,
        jsonOrNull('runtime/current-action.json?_=' + Date.now()),
        jsonOrNull('runtime/break-active.json?_=' + Date.now()),
        jsonOrNull('control/runner-status', { cache: 'no-store' })
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
    // --- See https://yuruna.link/definition#defining-the-status-page-visibility-aware-polling
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

    // Footer refresh link (was inline onclick="location.reload();return false").
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

    var CHART_W = 720, CHART_H = 260;
    var MARGIN  = { top: 12, right: 16, bottom: 28, left: 56 };
    var PLOT_W  = CHART_W - MARGIN.left - MARGIN.right;
    var PLOT_H  = CHART_H - MARGIN.top  - MARGIN.bottom;
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

    var staleCycleCount = 0;

    function buildStackedChart(seqName, cycles) {
      var card = document.createElement('div');
      card.className = 'seq-card';

      var nameEl = document.createElement('div');
      nameEl.className = 'seq-name';
      nameEl.textContent = seqName;
      card.appendChild(nameEl);

      var metaEl = document.createElement('div');
      metaEl.className = 'seq-meta';
      var totalCycles = cycles.length;
      var totalFails  = 0;
      for (var i = 0; i < cycles.length; i++) {
        if ((cycles[i].failCount || 0) > 0) totalFails++;
      }
      metaEl.textContent = totalCycles + ' cycle' + (totalCycles === 1 ? '' : 's')
        + (totalFails > 0 ? ' (' + totalFails + ' with failures)' : '');
      card.appendChild(metaEl);

      var svg = svgEl('svg', {
        'class': 'seq-chart',
        'viewBox': '0 0 ' + CHART_W + ' ' + CHART_H,
        'preserveAspectRatio': 'xMidYMid meet'
      });
      card.appendChild(svg);

      if (cycles.length === 0) {
        var empty = svgEl('text', {
          x: CHART_W / 2, y: CHART_H / 2,
          'text-anchor': 'middle', 'class': 'axis-text'
        });
        empty.textContent = '(no data)';
        svg.appendChild(empty);
        return card;
      }

      var maxMs = 0;
      for (var j = 0; j < cycles.length; j++) {
        var dm = +cycles[j].durationMs || 0;
        if (dm > maxMs) maxMs = dm;
      }
      var spanY = Math.max(1, maxMs);

      function yOf(ms) { return MARGIN.top + PLOT_H - (PLOT_H * (ms / spanY)); }

      var yTicks = [0, spanY * 0.25, spanY * 0.5, spanY * 0.75, spanY];
      for (var yi = 0; yi < yTicks.length; yi++) {
        var yMs = yTicks[yi];
        var yPx = yOf(yMs);
        svg.appendChild(svgEl('line', {
          'class': 'grid',
          x1: MARGIN.left, x2: MARGIN.left + PLOT_W,
          y1: yPx, y2: yPx
        }));
        var ylabel = svgEl('text', {
          'class': 'axis-text',
          x: MARGIN.left - 6, y: yPx + 3,
          'text-anchor': 'end'
        });
        ylabel.textContent = fmtSec(yMs);
        svg.appendChild(ylabel);
      }

      svg.appendChild(svgEl('line', {
        'class': 'axis',
        x1: MARGIN.left, x2: MARGIN.left + PLOT_W,
        y1: MARGIN.top + PLOT_H, y2: MARGIN.top + PLOT_H
      }));
      svg.appendChild(svgEl('line', {
        'class': 'axis',
        x1: MARGIN.left, x2: MARGIN.left,
        y1: MARGIN.top, y2: MARGIN.top + PLOT_H
      }));

      var n         = cycles.length;
      var slotWidth = PLOT_W / n;
      var barWidth  = Math.max(2, slotWidth * 0.75);

      for (var c = 0; c < n; c++) {
        var cyc = cycles[c];
        var slotCenter = MARGIN.left + (c + 0.5) * slotWidth;
        var barX = slotCenter - barWidth / 2;
        var hasStepDetail = !!(cyc.steps && cyc.steps.length > 0);
        if (!hasStepDetail) { staleCycleCount++; }
        var steps = hasStepDetail ? cyc.steps : [{
          ordinal: 0, occurrence: 1, name: '(no step detail)', kind: '',
          durationMs: +cyc.durationMs || 0, outcome: cyc.failCount ? 'fail' : 'pass'
        }];

        var accumulatedMs = 0;
        for (var s = 0; s < steps.length; s++) {
          var st = steps[s];
          var sms = +st.durationMs || 0;
          var yTop    = yOf(accumulatedMs + sms);
          var yBottom = yOf(accumulatedMs);
          var segHeight = Math.max(0, yBottom - yTop);
          var isFail = (st.outcome === 'fail');
          var segClass = 'seg' + (isFail ? ' fail' : '') + (hasStepDetail ? '' : ' fallback');
          var fill = hasStepDetail ? stepColor(st.name) : undefined;
          var attrs = {
            'class': segClass,
            x: barX, y: yTop,
            width: barWidth, height: segHeight
          };
          if (fill) { attrs.fill = fill; }
          var rect = svgEl('rect', attrs);
          var title = svgEl('title', {});
          title.textContent =
            '[' + (st.ordinal || '?') + (st.occurrence > 1 ? '.' + st.occurrence : '') + '] ' + (st.name || '') + '\n' +
            'Kind: ' + (st.kind || '?') + '\n' +
            'Duration: ' + fmtSec(sms) + '\n' +
            'Outcome: ' + (st.outcome || '?') + '\n' +
            'Cycle: ' + fmtDateLocal(cyc.cycleStartedAtUtc);
          rect.appendChild(title);
          svg.appendChild(rect);
          accumulatedMs += sms;
        }
        svg.appendChild(svgEl('rect', {
          'class': 'bar-outline',
          x: barX, y: yOf(accumulatedMs),
          width: barWidth, height: yOf(0) - yOf(accumulatedMs)
        }));
      }

      var firstC = cycles[0];
      var lastC  = cycles[n - 1];
      var midC   = cycles[Math.floor(n / 2)];
      var labels = (n === 1)
        ? [{ c: firstC, anchor: 'middle', cx: MARGIN.left + slotWidth * 0.5 }]
        : [
            { c: firstC, anchor: 'start', cx: MARGIN.left + slotWidth * 0.5 },
            { c: midC,   anchor: 'middle', cx: MARGIN.left + (Math.floor(n / 2) + 0.5) * slotWidth },
            { c: lastC,  anchor: 'end',    cx: MARGIN.left + (n - 0.5) * slotWidth }
          ];
      for (var li = 0; li < labels.length; li++) {
        var ll = labels[li];
        var xlabel = svgEl('text', {
          'class': 'axis-text',
          x: ll.cx, y: MARGIN.top + PLOT_H + 16,
          'text-anchor': ll.anchor
        });
        xlabel.textContent = fmtDateLocal(ll.c.cycleStartedAtUtc);
        svg.appendChild(xlabel);
      }

      return card;
    }

    function renderAggregates(payload) {
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
      var limitNote = payload.recentLimit
        ? ' · latest ' + payload.recentLimit + ' cycle' + (payload.recentLimit === 1 ? '' : 's')
        : '';
      meta.textContent = names.length + ' sequence' + (names.length === 1 ? '' : 's')
        + limitNote
        + ' · generated ' + (payload.generatedAtUtc || 'unknown');
      meta.className = 'perf-message';
      for (var i = 0; i < names.length; i++) {
        body.appendChild(buildStackedChart(names[i], sequences[names[i]] || []));
      }
      if (staleCycleCount > 0) {
        var warn = document.createElement('div');
        warn.className = 'stale-banner';
        warn.innerHTML =
          '<strong>' + staleCycleCount + ' cycle' + (staleCycleCount === 1 ? '' : 's') + ' lack step detail</strong> ' +
          '— their bars are drawn as a single gray segment. ' +
          'This almost always means the detached status-service process predates the ' +
          '<code>/control/perf-aggregates</code> step-detail change. Restart it with: ' +
          '<code>pwsh test/Stop-StatusService.ps1 ; pwsh test/Start-StatusService.ps1</code>' +
          ', then reload this page.';
        body.insertBefore(warn, body.firstChild);
      }
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
      if (recalculate) { opts.method = 'POST'; }
      fetch('control/perf-aggregates', opts)
        .then(function(r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.json();
        })
        .then(function(payload) {
          renderAggregates(payload);
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
    fetch('control/host-diagnostic?_=' + Date.now(), { cache: 'no-store' })
      .then(function(res) { if (!res.ok) throw new Error('HTTP ' + res.status); return res.text(); })
      .then(function(text) { el.className = ''; el.textContent = text || '(no output)'; })
      ['catch'](function(e) { el.className = 'error'; el.textContent = 'Could not load: ' + (e.message || e); });
  }

  // === test.config.html handlers ===
  function bootTestConfig() {
    var PAGE_CTA = { href: 'index.html', label: '← Status' };

    var configState = null;
    var availableGuestFolders = null;

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
              var childRow = childNode.querySelector(':scope > .tree-row');
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

      var refreshHint = null;
      if (key === 'cachingProxyIP') {
        input.placeholder = 'e.g. 192.168.1.42 (empty = no external cache)';
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

        var editProbe = makeCacheIpProbeDriver(editMark, input);
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
        envInput.tabIndex = -1;
        envInput.value = '(loading…)';
        envInput.title = 'Process-environment value the status server inherited at startup. Read-only here; export it in the shell that launches Invoke-TestRunner.ps1 (or set vmStart.cachingProxyIP above) to take effect.';
        var envMark = buildCacheIpMark();
        envRow.appendChild(envLabel);
        envRow.appendChild(envInput);
        envRow.appendChild(envMark);
        wrap.appendChild(envRow);

        var envProbe = makeCacheIpProbeDriver(envMark, null);
        fetchRuntimeEnv().then(function(envObj) {
          var v = (envObj && typeof envObj.YURUNA_CACHING_PROXY_IP === 'string') ? envObj.YURUNA_CACHING_PROXY_IP : '';
          envInput.value = v === '' ? '(unset)' : v;
          envProbe(v, true);
        }).catch(function() {
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

    function makeCacheIpProbeDriver(markEl, inputEl) {
      var debounceTimer    = null;
      var latestId         = 0;
      var lockedByMe       = false;
      var lastProbedValue  = null;

      function unlockInput() {
        if (inputEl && lockedByMe) {
          var hadFocus = (document.activeElement === inputEl);
          inputEl.disabled = false;
          lockedByMe = false;
          if (hadFocus) { try { inputEl.focus(); } catch (e) { /* ignore */ } }
        }
      }

      return function(ip, trigger) {
        if (debounceTimer) { clearTimeout(debounceTimer); debounceTimer = null; }
        var myId = ++latestId;
        var v = (ip || '').trim();

        if (v === '' || !isIpAddressLike(v)) {
          unlockInput();
          lastProbedValue = null;
          markEl.setCacheIpState('disabled',
            v === '' ? 'No IP set — nothing to test.'
                     : 'Not a valid IPv4 or IPv6 address — test skipped.');
          return;
        }

        if (!trigger) {
          if (v === lastProbedValue) return;
          unlockInput();
          markEl.setCacheIpState('disabled', 'Leave the field to test caching proxy from host.');
          return;
        }

        if (v === lastProbedValue) return;

        markEl.setCacheIpState('pending', 'Testing caching proxy from host…');
        debounceTimer = setTimeout(function() {
          if (myId !== latestId) return;
          if (inputEl) { inputEl.disabled = true; lockedByMe = true; }
          fetch('control/test-caching-proxy?ip=' + encodeURIComponent(v) + '&_=' + Date.now(),
                { cache: 'no-store' })
            .then(function(r) {
              if (!r.ok) throw new Error('HTTP ' + r.status);
              return r.json();
            })
            .then(function(j) {
              if (myId !== latestId) return;
              unlockInput();
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
              if (myId !== latestId) return;
              unlockInput();
              lastProbedValue = null;
              markEl.setCacheIpState('disabled', 'Caching-proxy test endpoint unavailable: ' + e.message);
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
          // pointerdown unifies mouse + touch + pen so iPhone / Android
          // taps fire the same handler the desktop mouse hits. Falling
          // back to mousedown for any browser without Pointer Events
          // would be redundant on the supported target set (iOS 13+,
          // Chrome 55+, Firefox 59+); skip the duplicate listener.
          el.onpointerdown = function (e) {
            e.preventDefault();
            if (item.disabled) return;
            selectedValue = item.value;
            close();
            render();
            if (typeof opts.onChange === 'function') {
              opts.onChange(selectedValue);
            }
          };
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
        document.addEventListener('pointerdown', onDocPointerDown, true);
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
        document.removeEventListener('pointerdown', onDocPointerDown, true);
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
          e.preventDefault(); close();
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
        headers: { 'Content-Type': 'application/json' },
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
              'running cycle, and start a new one? In-progress VMs will be ' +
              'removed.'
            );
            if (!ok) return;
          }
          doSaveAndStartCycle();
        })
        ['catch'](function(e) {
          var ok = window.confirm(
            'Could not determine runner status (' + e.message + '). ' +
            'Save and start cycle anyway? In-progress VMs (if any) will ' +
            'be removed.'
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
        headers: { 'Content-Type': 'application/json' },
        body: payload
      }).then(function(res) {
        return res.text().then(function(text) {
          var body = null;
          try { body = JSON.parse(text); } catch (_e) { /* non-JSON error */ }
          if (!res.ok || !body || !body.ok) {
            var msg = (body && body.error) ? body.error : ('HTTP ' + res.status);
            throw new Error(msg);
          }
          status.textContent = 'Saved. Stopping VMs and starting new cycle…';
          return fetch('control/start-cycle', {
            method: 'POST',
            cache: 'no-store'
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
      if (isEsc) discardAndExit();
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
