// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// caching-proxy-parser-service: a tail-and-serve daemon for the caching-proxy-service VM.
//
// Replaces loki + promtail for the Grafana dashboard's "Recent 100 requests"
// panel: tails the squid yuruna access log into a 100-entry in-memory ring,
// served as JSON + a self-contained HTML page. Single host, one log, one
// panel -- no tenancy, no persistence, no auth, no LogQL.
//
// Full design and operator guide: https://yuruna.link/caching-proxy-parser-service (README.md).
//
// This file holds the parts that depend on nothing but the standard library:
// the logformat regex, the ring, the counters and the three handlers. They
// carry no build constraint so they compile -- and are tested -- on every
// harness host. Tailing the log needs syscall.Stat_t to see a logrotate, and
// lives in main_linux.go beside the platform's main.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const (
	defaultLogPath    = "/var/log/squid/yuruna_access.log"
	defaultListenAddr = ":9302"
	ringSize          = 100
	pollInterval      = 200 * time.Millisecond
	backfillBytes     = 64 * 1024 // bytes scanned from EOF on first open

	// Cap on unmatched sample lines written to the log, so a total
	// logformat drift (every line failing lineRE) cannot flood the
	// journal. The running skipped counter on /healthz stays exact.
	maxUnmatchedLogged = 5
)

// yuruna logformat (see /etc/squid/conf.d/yuruna.conf):
//
//	%ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %[un %Sh/%<a %mt "%{User-Agent}>h"
//
// Capture groups: 1=ts 2=client_ip 3=squid/http_status 4=bytes
// 5=method 6=url 7=user_agent (in quotes).
var lineRE = regexp.MustCompile(
	`^(\d+\.\d+)\s+\S+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\S+\s+\S+\s+\S+\s+"([^"]*)"`,
)

type Entry struct {
	TsUnix   float64 `json:"ts"`
	TsISO    string  `json:"ts_iso"`
	ClientIP string  `json:"client_ip"`
	Status   string  `json:"status"`
	Bytes    int64   `json:"bytes"`
	Method   string  `json:"method"`
	URL      string  `json:"url"`
	UA       string  `json:"ua"`
}

type ring struct {
	mu  sync.RWMutex
	buf [ringSize]Entry
	n   int // filled slots, caps at ringSize
	idx int // next write position
}

func (r *ring) push(e Entry) {
	r.mu.Lock()
	r.buf[r.idx] = e
	r.idx = (r.idx + 1) % ringSize
	if r.n < ringSize {
		r.n++
	}
	r.mu.Unlock()
}

// snapshot returns entries newest-first so the dashboard's top row is
// the most recent request.
func (r *ring) snapshot() []Entry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Entry, r.n)
	start := (r.idx - r.n + ringSize) % ringSize
	for i := 0; i < r.n; i++ {
		out[i] = r.buf[(start+i)%ringSize]
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// stats holds the follower's observability counters and last-activity
// markers. Every field is written only from the single follow goroutine
// and read concurrently by /healthz, so all access goes through
// sync/atomic. Surfacing these lets an operator (or a watchdog) see
// whether the tailer can read the log (last_open_err, last_read) and
// spot logformat drift (skipped/fielderr).
type stats struct {
	parsed   atomic.Int64 // lines that matched lineRE and were pushed to the ring
	skipped  atomic.Int64 // lines that did not match lineRE (logformat drift)
	fieldErr atomic.Int64 // matched lines with an unparseable ts/bytes field (pushed with a zero fallback)
	logged   atomic.Int64 // unmatched sample lines already logged (bounded by maxUnmatchedLogged)

	lastReadUnixMs atomic.Int64 // wall-clock ms of the last line read from the log
	lastOpenErr    atomic.Value // string: most recent open/stat failure, "" while the log is open
}

func parseLine(line string, s *stats) (Entry, bool) {
	m := lineRE.FindStringSubmatch(line)
	if m == nil {
		return Entry{}, false
	}
	ts, tsErr := strconv.ParseFloat(m[1], 64)
	bytes, bytesErr := strconv.ParseInt(m[4], 10, 64)
	if tsErr != nil || bytesErr != nil {
		// The line matched the logformat shape but a numeric field would
		// not parse (most plausibly a "-" bytes value). Keep the row with
		// a zero fallback rather than dropping it, but count the miss so a
		// field-level drift shows up on /healthz.
		s.fieldErr.Add(1)
	}
	whole := int64(ts)
	frac := int64((ts - float64(whole)) * 1e9)
	return Entry{
		TsUnix:   ts,
		TsISO:    time.Unix(whole, frac).UTC().Format("2006-01-02T15:04:05.000Z"),
		ClientIP: m[2],
		Status:   m[3],
		Bytes:    bytes,
		Method:   m[5],
		URL:      m[6],
		UA:       m[7],
	}, true
}

// recordLine folds one raw log line into the ring and the counters and reports
// whether the caller should log it as a drift sample. The cap lives here, not
// at the call site: a total logformat drift means EVERY line misses, and an
// uncapped sample log would fill the journal with the same failure.
func recordLine(line string, r *ring, s *stats) bool {
	if e, ok := parseLine(line, s); ok {
		s.parsed.Add(1)
		r.push(e)
		return false
	}
	s.skipped.Add(1)
	if s.logged.Load() < maxUnmatchedLogged {
		s.logged.Add(1)
		return true
	}
	return false
}

// handleJSON returns the ring as a JSON array, newest first.
func handleJSON(r *ring) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_ = json.NewEncoder(w).Encode(r.snapshot())
	}
}

// handleHTML renders a self-contained page (no external assets) that
// fetches /recent-requests every 5 s and rebuilds the table with
// textContent, never innerHTML -- squid log fields are attacker-
// controlled (URL + User-Agent), so element creation is safer.
const indexHTML = `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Squid cache -- recent 100 requests</title>
<style>
  /* Banded rows, the same two values every Yuruna UI bands its tables with.
     Only the dark pair is defined: this page paints a dark surface outright
     rather than following prefers-color-scheme, so the light pair would band
     a dark table in white. */
  :root { --band-odd: #111827; --band-even: #0b1220; }
  body { font: 12px Menlo, Consolas, monospace; background: #111827; color: #e5e7eb;
         margin: 0; padding: 12px; }
  h1 { font-size: 14px; margin: 0 0 8px; color: #9ca3af; font-weight: 600; }
  #meta { color: #6b7280; font-weight: 400; }
  table { width: 100%; border-collapse: collapse; table-layout: auto; }
  th, td { text-align: left; padding: 3px 8px; border-bottom: 1px solid #1f2937;
           white-space: nowrap; vertical-align: top; }
  th { color: #6b7280; font-weight: 600; position: sticky; top: 0; background: #111827; }
  td.url { white-space: normal; word-break: break-all; max-width: 50ch; }
  td.ua  { color: #6b7280; max-width: 30ch; overflow: hidden; text-overflow: ellipsis; }
  /* Scoped to tbody so the sticky header keeps its own opaque background. The
     hover rule below still shows through: it paints the td, and a td's
     background paints over its tr's. */
  tbody tr:nth-child(odd) { background: var(--band-odd); }
  tbody tr:nth-child(even) { background: var(--band-even); }
  tr:hover td { background: #1f2937; }
  .ok   { color: #10b981; } /* 2xx / 3xx */
  .red  { color: #f87171; } /* 4xx / 5xx */
  .gray { color: #6b7280; }
</style>
</head><body>
<h1>Squid cache -- recent 100 requests <span id="meta"></span></h1>
<table id="t"><thead>
<tr><th>time</th><th>client</th><th>status</th><th>bytes</th>
<th>method</th><th>url</th><th>user-agent</th></tr>
</thead><tbody></tbody></table>
<script>
function statusClass(s) {
  if (!s) return 'gray';
  var p = s.split('/'); var code = p[p.length - 1];
  if (/^[23]\d\d$/.test(code)) return 'ok';
  if (/^[45]\d\d$/.test(code)) return 'red';
  return 'gray';
}
function refresh() {
  fetch('/recent-requests').then(function(r){ return r.json(); }).then(function(rows){
    var t = document.querySelector('#t tbody');
    while (t.firstChild) t.removeChild(t.firstChild);
    rows.forEach(function(r){
      function cell(text, klass) {
        var d = document.createElement('td');
        d.textContent = (text == null) ? '' : String(text);
        if (klass) d.className = klass;
        return d;
      }
      var tr = document.createElement('tr');
      tr.appendChild(cell((r.ts_iso || '').slice(11, 23), 'gray'));
      tr.appendChild(cell(r.client_ip));
      tr.appendChild(cell(r.status, statusClass(r.status)));
      tr.appendChild(cell(r.bytes));
      tr.appendChild(cell(r.method));
      tr.appendChild(cell(r.url, 'url'));
      tr.appendChild(cell(r.ua, 'ua'));
      t.appendChild(tr);
    });
    document.getElementById('meta').textContent =
      '(' + rows.length + ' rows, refreshed ' + new Date().toLocaleTimeString() + ')';
  }).catch(function(){
    document.getElementById('meta').textContent = '(refresh failed)';
  });
}
refresh();
setInterval(refresh, 5000);
</script>
</body></html>`

func handleHTML(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path != "/" && req.URL.Path != "/index.html" {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.WriteString(w, indexHTML)
}

// handleHealth reports liveness plus the follower's counters and last-
// activity markers. It keeps the leading "ok" token (probes and the
// README example match on it) and appends the diagnostics: last_open_err
// distinguishes a tailer that cannot open/stat the log (set) from one
// reading fine (empty), while last_read shows when a line last arrived
// (old for any idle log, so it is a value to read, not a health verdict).
func handleHealth(s *stats) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		lastRead := "never"
		if ms := s.lastReadUnixMs.Load(); ms > 0 {
			lastRead = time.UnixMilli(ms).UTC().Format("2006-01-02T15:04:05.000Z")
		}
		openErr, _ := s.lastOpenErr.Load().(string)
		_, _ = fmt.Fprintf(w, "ok parsed=%d skipped=%d fielderr=%d last_read=%s last_open_err=%s\n",
			s.parsed.Load(), s.skipped.Load(), s.fieldErr.Load(), lastRead, openErr)
	}
}

// newStats returns counters ready to read: lastOpenErr is an atomic.Value, so
// it must be seeded with its concrete string type before any load, or the
// first /healthz before the first open panics on the type assertion.
func newStats() *stats {
	s := &stats{}
	s.lastOpenErr.Store("")
	return s
}

// newMux wires the three served routes. Kept beside the handlers rather than
// in main so a test can exercise the routing, not just the handler functions.
func newMux(r *ring, s *stats) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/recent-requests", handleJSON(r))
	mux.HandleFunc("/healthz", handleHealth(s))
	mux.HandleFunc("/", handleHTML)
	return mux
}
