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
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
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
func follow(path string, r *ring, s *stats) {
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
				s.lastOpenErr.Store(fmt.Sprintf("open %s: %v", path, err))
				log.Printf("open %s: %v", path, err)
				time.Sleep(time.Second)
				continue
			}
			st, statErr := fh.Stat()
			if statErr != nil {
				// A stat failure must be surfaced, not silently retried: an
				// unrecorded stat error is invisible on /healthz and
				// indistinguishable there from a healthy tailer that is merely
				// caught up. Record + log it like the open failure above.
				s.lastOpenErr.Store(fmt.Sprintf("stat %s: %v", path, statErr))
				log.Printf("stat %s: %v", path, statErr)
				_ = fh.Close()
				time.Sleep(time.Second)
				continue
			}
			s.lastOpenErr.Store("") // open+stat succeeded; clear any prior failure
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
			s.lastReadUnixMs.Store(time.Now().UnixMilli())
			line = strings.TrimRight(line, "\n")
			if line == "" {
				continue // a blank line is not logformat drift; don't count it as skipped
			}
			if e, ok := parseLine(line, s); ok {
				s.parsed.Add(1)
				r.push(e)
			} else {
				s.skipped.Add(1)
				if s.logged.Load() < maxUnmatchedLogged {
					s.logged.Add(1)
					log.Printf("unmatched line (logformat drift?): %q", line)
				}
			}
			continue
		}
		if err != io.EOF {
			// A non-EOF read error (bad fd, underlying I/O error) will not clear by waiting, so
			// close and force a reopen instead of spinning on / stalling behind a broken
			// descriptor. Only io.EOF means "caught up -- wait for more data / check rotation".
			_ = f.Close()
			f, rd = nil, nil
			continue
		}
		// io.EOF: caught up. If the file rotated (new inode) reopen; otherwise wait for new data.
		// Keep rd so the next read resumes where bufio left off.
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
<meta name="viewport" content="width=device-width, initial-scale=1">
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

func main() {
	logPath := flag.String("log", defaultLogPath, "squid access log to tail")
	addr := flag.String("listen", defaultListenAddr, "address to listen on")
	flag.Parse()

	r := &ring{}
	s := &stats{}
	s.lastOpenErr.Store("") // seed the atomic.Value with its concrete string type
	go follow(*logPath, r, s)

	mux := http.NewServeMux()
	mux.HandleFunc("/recent-requests", handleJSON(r))
	mux.HandleFunc("/healthz", handleHealth(s))
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
