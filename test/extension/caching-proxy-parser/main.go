// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// caching-proxy-parser: a tail-and-serve daemon for the caching-proxy VM.
//
// Replaces loki + promtail for the Grafana dashboard's "Recent 100
// requests" panel. Tails /var/log/squid/yuruna_access.log (the
// yuruna logformat written by /etc/squid/conf.d/yuruna.conf), parses
// each line, keeps the last 100 entries in an in-memory ring, and
// serves them as JSON + a self-contained HTML page.
//
// Optimized for one specific scenario (single host, one squid access
// log, one panel) — no tenancy, no persistence, no auth, no LogQL.
//
// Built and installed from the caching-proxy cloud-init user-data; see
// test/extension/caching-proxy-parser/README.md.
//
// Linux-only: inodeOf() uses syscall.Stat_t to detect logrotate. The
// build tag keeps `go vet` happy on the harness-host Windows toolchain
// while letting GOOS=linux builds compile cleanly.
//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultLogPath    = "/var/log/squid/yuruna_access.log"
	defaultListenAddr = ":9302"
	ringSize          = 100
	pollInterval      = 200 * time.Millisecond
	backfillBytes     = 64 * 1024 // bytes scanned from EOF on first open
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

func parseLine(line string) (Entry, bool) {
	m := lineRE.FindStringSubmatch(line)
	if m == nil {
		return Entry{}, false
	}
	ts, _ := strconv.ParseFloat(m[1], 64)
	bytes, _ := strconv.ParseInt(m[4], 10, 64)
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

func inodeOf(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return st.Ino
	}
	return 0
}

// follow tails the squid log forever. On first open it seeds the ring
// from the last ~64 KB of the file (so the panel is non-empty on cold
// start). It detects logrotate by stat'ing the path and comparing
// inodes; on rotation it closes the old fd and re-opens from byte 0.
func follow(path string, r *ring) {
	var (
		f         *os.File
		rd        *bufio.Reader
		seenInode uint64
		firstOpen = true
	)
	for {
		if f == nil {
			fh, err := os.Open(path)
			if err != nil {
				log.Printf("open %s: %v", path, err)
				time.Sleep(time.Second)
				continue
			}
			st, statErr := fh.Stat()
			if statErr != nil {
				_ = fh.Close()
				time.Sleep(time.Second)
				continue
			}
			seenInode = inodeOf(st)
			if firstOpen {
				size := st.Size()
				if size > backfillBytes {
					_, _ = fh.Seek(size-backfillBytes, io.SeekStart)
				}
				br := bufio.NewReader(fh)
				if size > backfillBytes {
					// Skip the partial first line introduced by mid-line seek.
					_, _ = br.ReadString('\n')
				}
				rd = br
				firstOpen = false
			} else {
				rd = bufio.NewReader(fh)
			}
			f = fh
		}
		line, err := rd.ReadString('\n')
		if err == nil {
			line = strings.TrimRight(line, "\n")
			if e, ok := parseLine(line); ok {
				r.push(e)
			}
			continue
		}
		// EOF or read error -- check for rotation, otherwise wait for new data.
		st, statErr := os.Stat(path)
		if statErr == nil && inodeOf(st) != seenInode {
			_ = f.Close()
			f, rd = nil, nil
			continue
		}
		time.Sleep(pollInterval)
	}
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
// textContent, never innerHTML — squid log fields are attacker-
// controlled (URL + User-Agent), so element creation is safer.
const indexHTML = `<!doctype html>
<html><head><meta charset="utf-8">
<title>Squid cache — recent 100 requests</title>
<style>
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
  tr:hover td { background: #1f2937; }
  .ok   { color: #10b981; } /* 2xx / 3xx */
  .red  { color: #f87171; } /* 4xx / 5xx */
  .gray { color: #6b7280; }
</style>
</head><body>
<h1>Squid cache — recent 100 requests <span id="meta"></span></h1>
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

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	_, _ = io.WriteString(w, "ok\n")
}

func main() {
	logPath := flag.String("log", defaultLogPath, "squid access log to tail")
	addr := flag.String("listen", defaultListenAddr, "address to listen on")
	flag.Parse()

	r := &ring{}
	go follow(*logPath, r)

	mux := http.NewServeMux()
	mux.HandleFunc("/recent-requests", handleJSON(r))
	mux.HandleFunc("/healthz", handleHealth)
	mux.HandleFunc("/", handleHTML)

	log.Printf("caching-proxy-parser listening on http://%s, tailing %s", *addr, *logPath)
	srv := &http.Server{
		Addr:         *addr,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}
