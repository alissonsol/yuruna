// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"net/http"
	"strings"
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
<title data-i18n="cache.caching_proxy_service">Caching proxy service</title>
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
<h1 data-i18n="cache.caching_proxy_service">Caching proxy service</h1>
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
<p id="controls"><button type="button" id="pause" aria-pressed="false" data-i18n="cache.pause_auto_refresh">Pause auto-refresh</button></p>

<h2>Squid</h2>
<table><tbody id="squid"></tbody></table>

<h2 data-i18n="cache.switches">Switches</h2>
<table><tbody id="switches"></tbody></table>

<h2 data-i18n="cache.registry">Registry</h2>
<table><tbody id="registry"></tbody></table>

<footer>
  <span data-i18n="cache.read_only_json">Read-only. JSON:</span> <a href="/api/status">/api/status</a>,
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
  // Bounded: this page refreshes on a timer, and a request that never
  // settles would leave the table showing a state the proxy left minutes ago
  // with nothing to say it is stale.
  yurunaRequest('/api/status', 8000).then(function (s) {
return window.YurunaFirstUsable.measure("cache/index", 'data', function () {
    var sq = clear('squid');
    if (s.squid && s.squid.reachable) {
      row(sq, window.YurunaI18n.t("cache.reachable"), window.YurunaI18n.t("cache.yes"), 'ok');
      row(sq, window.YurunaI18n.t("cache.version"), s.squid.version);
      row(sq, window.YurunaI18n.t("cache.uptime_s"), s.squid.uptimeSeconds);
      row(sq, window.YurunaI18n.t("cache.requests"), s.squid.requestsTotal);
      row(sq, window.YurunaI18n.t("cache.hit_ratio_5min"), s.squid.hitRatioPct);
      row(sq, window.YurunaI18n.t("cache.cache_size_kb"), s.squid.cacheSizeKB);
      row(sq, window.YurunaI18n.t("cache.file_descriptors"), s.squid.fileDescriptorsInUse);
    } else {
      row(sq, window.YurunaI18n.t("cache.reachable"), window.YurunaI18n.t("cache.no"), 'red');
      row(sq, window.YurunaI18n.t("cache.error"), s.squid ? s.squid.error : '', 'red');
    }

    var sw = clear('switches');
    if (s.switches) {
      // offline_mode suppresses revalidation, not fetching -- amber, because it
      // is a deliberate state worth noticing rather than a fault.
      row(sw, window.YurunaI18n.t("cache.offline_mode"), s.switches.offline ? window.YurunaI18n.t("cache.on") : window.YurunaI18n.t("cache.off"),
          s.switches.offline ? 'warn' : 'gray');
      row(sw, window.YurunaI18n.t("cache.no_upstream"), s.switches.noUpstream ? window.YurunaI18n.t("cache.on") : window.YurunaI18n.t("cache.off"),
          s.switches.noUpstream ? 'warn' : 'gray');
      row(sw, window.YurunaI18n.t("cache.read_from"), s.switches.source, 'gray');
      if (s.switches.detail) { row(sw, window.YurunaI18n.t("cache.note"), s.switches.detail, 'gray'); }
    }

    var rg = clear('registry');
    if (s.registry && s.registry.reachable) {
      row(rg, window.YurunaI18n.t("cache.reachable"), window.YurunaI18n.t("cache.yes"), 'ok');
      row(rg, window.YurunaI18n.t("cache.repositories"), s.registry.repositories);
      row(rg, window.YurunaI18n.t("cache.canary"), s.registry.canaryOk ? window.YurunaI18n.t("cache.ok") : window.YurunaI18n.t("cache.not_ok"),
          s.registry.canaryOk ? 'ok' : 'red');
      row(rg, window.YurunaI18n.t("cache.canary_latency_s"), s.registry.canaryLatencySeconds);
      row(rg, window.YurunaI18n.t("cache.prewarm_last_run"), s.registry.prewarmLastRun);
      if (s.registry.prewarmTotal) {
        row(rg, window.YurunaI18n.t("cache.prewarm_held"), ("" + (s.registry.prewarmHeld) + " / " + (s.registry.prewarmTotal) + ""));
      }
    } else {
      row(rg, window.YurunaI18n.t("cache.reachable"), window.YurunaI18n.t("cache.no"), 'red');
      row(rg, window.YurunaI18n.t("cache.error"), s.registry ? s.registry.error : '', 'red');
    }

    document.getElementById('meta').textContent =
      window.YurunaI18n.t("cache.value1_mode_v_value2_refreshed_value3", {value1: (s.mode), value2: (s.version), value3: (yurunaLocalTime(new Date()))});

    // Remote mode cannot apply a switch at all; say so rather than offering a
    // command that would answer 501.
    var help = clear('switchhelp');
    var line = document.createElement('div');
    if (s.mode === 'remote') {
      line.textContent = window.YurunaI18n.t("cache.remote_mode_the_switches_are_readable_here_but_can_only_be_applie");
    } else {
      line.textContent = window.YurunaI18n.t("cache.flip_a_switch_post_api_switches_offline_on_true_with_the_internal");
    }
    help.appendChild(line);
    document.getElementById('err').textContent = '';
    window.YurunaFirstUsable.mark('cache/index', 'data');

});
}).catch(function () {
    document.getElementById('meta').textContent = window.YurunaI18n.t("cache.refresh_failed");
    // A sighted reader sees the header change; without this the values below
    // simply stop moving, which looks identical to a quiet lab.
    document.getElementById('err').textContent =
      window.YurunaI18n.t("cache.refresh_failed_the_values_below_are_from_the_last_successful_read");
    window.YurunaFirstUsable.mark('cache/index', 'error');
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
    pause.textContent = window.YurunaI18n.t("cache.pause_auto_refresh");
    startPolling();
    refresh();
  } else {
    pause.setAttribute('aria-pressed', 'true');
    pause.textContent = window.YurunaI18n.t("cache.resume_auto_refresh");
    stopPolling();
  }
});
refresh();
startPolling();
</script>
</body></html>`

// indexPage is the served document: the request adapter is spliced into the
// head so it is installed before the page's own script runs. Composed once at
// startup rather than per request -- the result never varies, and a handler
// that rebuilt it would pay for the concatenation on every hit.
//
// A page on a browser without fetch would otherwise render its shell and then
// fill in nothing, which reads as a lab with no data rather than as a page
// that failed.
var indexPage = strings.Replace(
	indexHTML,
	"</head>",
	"<script>"+requestAdapterScript+"</script>\n</head>",
	1,
)

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
	if !localizedPages().Serve(w, r, "index.html") {
		http.NotFound(w, r)
	}
}
