// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"io"
	"net/http"
)

// indexHTML is the page the dashboard's Extension hosts cell links to.
//
// It exists because that link had nowhere to land: the cell deep-links to the
// address this daemon announces, and a daemon serving only JSON answered 404 to
// an operator who clicked the one row that finally represented the caching
// proxy. A 404 there reads as "the service is broken", which is the opposite of
// what it meant.
//
// Self-contained, like its neighbor in this VM: no external stylesheet, no
// script host, no font. The proxy VM serves this to a browser that may have no
// route off the lab network, so an external asset would render a broken page on
// exactly the machine whose job is to make the network unnecessary. Rows are
// built with textContent, never innerHTML -- everything shown here comes from
// squid and zot, and the switch source string is operator-influenced.
//
// READ-ONLY on purpose. The two switches are a lab-token write, and putting
// them here would mean an unlock flow, a session, and a second place where "may
// this caller change the proxy" is decided. The page names the API call
// instead; the gate stays in one place.
const indexHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Caching proxy service</title>
<style>
  /* The same dark surface and banding the parser page on this VM uses, so the
     two services on one machine read as one product. */
  :root { --band-odd: #111827; --band-even: #0b1220; }
  body { font: 12px Menlo, Consolas, monospace; background: #111827; color: #e5e7eb;
         margin: 0; padding: 12px; }
  h1 { font-size: 14px; margin: 0 0 8px; color: #9ca3af; font-weight: 600; }
  /* #6b7280 computes 3.67:1 on this page's #111827 and 3.04:1 on the hover
     band -- below the 4.5:1 body-text floor at the 12px this page sets. #9ca3af
     is the same neutral one step up and is already the h1 color here, so the
     hierarchy survives while every tier clears AA. */
  #meta { color: #9ca3af; font-weight: 400; margin: 0 0 8px; }
  /* 26px tall at this font size, which clears the 24x24 minimum for a pointer
     target, and the focus ring is drawn outside the border so it stays visible
     against the button's own fill. */
  #controls { margin: 0 0 8px; }
  button { font: inherit; color: #e5e7eb; background: #1f2937;
           border: 1px solid #4b5563; border-radius: 3px; padding: 6px 10px; }
  button:hover { background: #374151; }
  button:focus-visible { outline: 2px solid #93c5fd; outline-offset: 2px; }
  h2 { font-size: 12px; margin: 14px 0 4px; color: #9ca3af; font-weight: 600;
       text-transform: uppercase; letter-spacing: .04em; }
  table { width: 100%; max-width: 90ch; border-collapse: collapse; }
  th, td { text-align: left; padding: 3px 8px; border-bottom: 1px solid #1f2937;
           vertical-align: top; }
  th { color: #9ca3af; font-weight: 600; width: 26ch; }
  tbody tr:nth-child(odd) { background: var(--band-odd); }
  tbody tr:nth-child(even) { background: var(--band-even); }
  tr:hover td { background: #1f2937; }
  .ok    { color: #10b981; }
  .warn  { color: #fbbf24; }
  .red   { color: #f87171; }
  .gray  { color: #9ca3af; }
  code { color: #93c5fd; }
  footer { margin-top: 16px; color: #9ca3af; }
  a { color: #93c5fd; }
</style>
</head><body>
<h1>Caching proxy service</h1>
<!-- The refresh timestamp is rewritten on every tick, so it sits beside the
     heading rather than inside it: a document whose h1 changes six times a
     minute has no stable name to navigate to. -->
<p id="meta"></p>
<!-- role="alert" and empty at load: a live region has to exist before its text
     is written to be announced reliably. Deliberately NOT on #meta, which is a
     timestamp -- announcing that every 10 seconds would be a spoken clock. The
     thing worth interrupting for is the data going stale, which is what fills
     this. -->
<p id="err" role="alert"></p>
<p id="controls"><button type="button" id="pause" aria-pressed="false">Pause auto-refresh</button></p>

<h2>Squid</h2>
<table><tbody id="squid"></tbody></table>

<h2>Switches</h2>
<table><tbody id="switches"></tbody></table>

<h2>Registry</h2>
<table><tbody id="registry"></tbody></table>

<footer>
  Read-only. JSON: <a href="/api/status">/api/status</a>,
  <a href="/api/switches">/api/switches</a>,
  <a href="/api/hostinfo">/api/hostinfo</a>,
  <a href="/healthz">/healthz</a>.
  <div id="switchhelp" style="margin-top:6px"></div>
</footer>

<script>
function row(tbody, label, value, klass) {
  var tr = document.createElement('tr');
  var th = document.createElement('th');
  th.textContent = label;
  var td = document.createElement('td');
  td.textContent = (value === null || value === undefined || value === '') ? '--' : String(value);
  if (klass) { td.className = klass; }
  tr.appendChild(th); tr.appendChild(td); tbody.appendChild(tr);
}
function clear(id) {
  var t = document.getElementById(id);
  while (t.firstChild) { t.removeChild(t.firstChild); }
  return t;
}
function refresh() {
  fetch('/api/status').then(function (r) { return r.json(); }).then(function (s) {
    var sq = clear('squid');
    if (s.squid && s.squid.reachable) {
      row(sq, 'reachable', 'yes', 'ok');
      row(sq, 'version', s.squid.version);
      row(sq, 'uptime (s)', s.squid.uptimeSeconds);
      row(sq, 'requests', s.squid.requestsTotal);
      row(sq, 'hit ratio (5min %)', s.squid.hitRatioPct);
      row(sq, 'cache size (KB)', s.squid.cacheSizeKB);
      row(sq, 'file descriptors', s.squid.fileDescriptorsInUse);
    } else {
      row(sq, 'reachable', 'no', 'red');
      row(sq, 'error', s.squid ? s.squid.error : '', 'red');
    }

    var sw = clear('switches');
    if (s.switches) {
      // offline_mode suppresses revalidation, not fetching -- amber, because it
      // is a deliberate state worth noticing rather than a fault.
      row(sw, 'offline mode', s.switches.offline ? 'on' : 'off',
          s.switches.offline ? 'warn' : 'gray');
      row(sw, 'no upstream', s.switches.noUpstream ? 'on' : 'off',
          s.switches.noUpstream ? 'warn' : 'gray');
      row(sw, 'read from', s.switches.source, 'gray');
      if (s.switches.detail) { row(sw, 'note', s.switches.detail, 'gray'); }
    }

    var rg = clear('registry');
    if (s.registry && s.registry.reachable) {
      row(rg, 'reachable', 'yes', 'ok');
      row(rg, 'repositories', s.registry.repositories);
      row(rg, 'canary', s.registry.canaryOk ? 'ok' : 'not ok',
          s.registry.canaryOk ? 'ok' : 'red');
      row(rg, 'canary latency (s)', s.registry.canaryLatencySeconds);
      row(rg, 'prewarm last run', s.registry.prewarmLastRun);
      if (s.registry.prewarmTotal) {
        row(rg, 'prewarm held', s.registry.prewarmHeld + ' / ' + s.registry.prewarmTotal);
      }
    } else {
      row(rg, 'reachable', 'no', 'red');
      row(rg, 'error', s.registry ? s.registry.error : '', 'red');
    }

    document.getElementById('meta').textContent =
      '(' + s.mode + ' mode, v' + s.version + ', refreshed ' + new Date().toLocaleTimeString() + ')';

    // Remote mode cannot apply a switch at all; say so rather than offering a
    // command that would answer 501.
    var help = clear('switchhelp');
    var line = document.createElement('div');
    if (s.mode === 'remote') {
      line.textContent = 'Remote mode: the switches are readable here but can only be applied by the daemon on the proxy VM itself.';
    } else {
      line.textContent = 'Flip a switch: POST /api/switches/offline {"on":true} with the internal authentication key as a bearer.';
    }
    help.appendChild(line);
    document.getElementById('err').textContent = '';
  }).catch(function () {
    document.getElementById('meta').textContent = '(refresh failed)';
    // A sighted reader sees the header change; without this the values below
    // simply stop moving, which looks identical to a quiet lab.
    document.getElementById('err').textContent =
      'Refresh failed. The values below are from the last successful read.';
  });
}
// The handle is kept so the control above has something to clear. Discarding
// it leaves the poll unstoppable even in principle, which is what turns a
// refresh into moving content with no mechanism to pause it.
var timer = null;
var pause = document.getElementById('pause');
function startPolling() { if (timer === null) { timer = setInterval(refresh, 10000); } }
function stopPolling() { if (timer !== null) { clearInterval(timer); timer = null; } }
pause.addEventListener('click', function () {
  if (pause.getAttribute('aria-pressed') === 'true') {
    pause.setAttribute('aria-pressed', 'false');
    pause.textContent = 'Pause auto-refresh';
    startPolling();
    refresh();
  } else {
    pause.setAttribute('aria-pressed', 'true');
    pause.textContent = 'Resume auto-refresh';
    stopPolling();
  }
});
refresh();
startPolling();
</script>
</body></html>`

// handleIndex serves the page, and only at the root. The mux pattern already
// anchors it, so anything else reaching here is a bug worth a 404 rather than a
// page that pretends the path meant something.
func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" && r.URL.Path != "/index.html" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// Everything the page needs is inline, so nothing but 'self' is allowed to
	// load and nothing at all may frame it. 'unsafe-inline' covers the one
	// inline style block and the one inline script this page ships as; there is
	// no external origin in either direction.
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "+
			"connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	_, _ = io.WriteString(w, indexHTML)
}
