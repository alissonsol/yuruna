// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Tests for the parts of the parser that do not touch the filesystem. No build
// constraint, so they run on every harness host rather than only on the VM's
// operating system.
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// goldenLine is a real line in the documented yuruna logformat:
//
//	%ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %[un %Sh/%<a %mt "%{User-Agent}>h"
//
// Every field the panel renders is read out of this one line, so it doubles as
// the record of what the format is: change squid's logformat and this fails
// before the dashboard silently empties.
const goldenLine = `1787227200.123    142 192.0.2.31 TCP_MISS/200 34567 GET http://archive.ubuntu.com/ubuntu/dists/noble/InRelease - HIER_DIRECT/185.125.190.39 text/plain "Debian APT-HTTP/1.3 (2.7.14)"`

// goldenISO is what the panel actually shows for goldenLine's timestamp, and
// the last digit is deliberate: the seconds field is carried as a float64, and
// .123 has no exact binary form, so the nanosecond conversion lands on
// 122999906 and the .000 layout truncates rather than rounds. One millisecond
// early on a display timestamp changes nothing an operator reads, but pinning
// the value keeps the whole format honest -- if this string moves, the panel's
// clock moved with it.
const goldenISO = "2026-08-20T12:00:00.122Z"

func TestParseLineReadsEveryPanelField(t *testing.T) {
	s := newStats()
	e, ok := parseLine(goldenLine, s)
	if !ok {
		t.Fatalf("the documented logformat line did not match lineRE")
	}
	for _, tc := range []struct {
		field string
		got   any
		want  any
	}{
		{"ts", e.TsUnix, 1787227200.123},
		{"ts_iso", e.TsISO, goldenISO},
		{"client_ip", e.ClientIP, "192.0.2.31"},
		{"status", e.Status, "TCP_MISS/200"},
		{"bytes", e.Bytes, int64(34567)},
		{"method", e.Method, "GET"},
		{"url", e.URL, "http://archive.ubuntu.com/ubuntu/dists/noble/InRelease"},
		{"ua", e.UA, "Debian APT-HTTP/1.3 (2.7.14)"},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %v, want %v", tc.field, tc.got, tc.want)
		}
	}
	if n := s.fieldErr.Load(); n != 0 {
		t.Errorf("a fully parseable line counted %d field errors", n)
	}
}

// A "-" in the bytes column is squid's own output for a request it served no
// body for. The row still belongs on the panel, so it is kept with a zero and
// counted -- dropping it would hide the request entirely.
func TestParseLineKeepsRowWithUnparseableBytes(t *testing.T) {
	line := strings.Replace(goldenLine, " 34567 ", " - ", 1)
	s := newStats()
	e, ok := parseLine(line, s)
	if !ok {
		t.Fatalf("a dash in the bytes column must still match the logformat")
	}
	if e.Bytes != 0 {
		t.Errorf("bytes = %d, want the 0 fallback", e.Bytes)
	}
	if e.URL == "" || e.Method != "GET" {
		t.Errorf("the rest of the row must survive: %+v", e)
	}
	if n := s.fieldErr.Load(); n != 1 {
		t.Errorf("fielderr = %d, want 1 so the drift is visible on /healthz", n)
	}
}

func TestParseLineRejectsForeignFormat(t *testing.T) {
	s := newStats()
	for _, line := range []string{
		"",
		"not a squid line at all",
		`1755691200.123 142 192.0.2.31 TCP_MISS/200 34567 GET http://example.invalid/`, // truncated: no UA
	} {
		if _, ok := parseLine(line, s); ok {
			t.Errorf("parsed a line that is not in the logformat: %q", line)
		}
	}
}

func TestRecordLineCapsTheDriftSampleLog(t *testing.T) {
	// The counter must stay exact while the LOGGING stops, so a wholesale
	// logformat change is still measurable on /healthz after the journal has
	// been spared.
	r := &ring{}
	s := newStats()
	sampled := 0
	for i := 0; i < maxUnmatchedLogged+7; i++ {
		if recordLine("this line is not in the logformat", r, s) {
			sampled++
		}
	}
	if sampled != maxUnmatchedLogged {
		t.Errorf("logged %d drift samples, want the %d cap", sampled, maxUnmatchedLogged)
	}
	if got := s.skipped.Load(); got != int64(maxUnmatchedLogged+7) {
		t.Errorf("skipped = %d, want every unmatched line counted", got)
	}
	if got := s.parsed.Load(); got != 0 {
		t.Errorf("parsed = %d, want 0", got)
	}
}

func TestRecordLinePushesAParsedLineToTheRing(t *testing.T) {
	r := &ring{}
	s := newStats()
	if recordLine(goldenLine, r, s) {
		t.Fatalf("a well-formed line must not be reported as a drift sample")
	}
	snap := r.snapshot()
	if len(snap) != 1 || snap[0].ClientIP != "192.0.2.31" {
		t.Fatalf("ring holds %+v", snap)
	}
	if s.parsed.Load() != 1 || s.skipped.Load() != 0 {
		t.Errorf("parsed=%d skipped=%d", s.parsed.Load(), s.skipped.Load())
	}
}

func TestRingReturnsNewestFirst(t *testing.T) {
	r := &ring{}
	for i := 0; i < 5; i++ {
		r.push(Entry{URL: string(rune('a' + i))})
	}
	got := r.snapshot()
	if len(got) != 5 {
		t.Fatalf("snapshot has %d entries, want 5", len(got))
	}
	// The dashboard's top row is the most recent request.
	if got[0].URL != "e" || got[4].URL != "a" {
		t.Errorf("snapshot order is %v, want newest first", urls(got))
	}
}

// The ring is the panel's whole retention policy: past ringSize the oldest
// entry has to go, and the wrap must not reorder or duplicate what remains.
func TestRingWrapsAtCapacityKeepingTheNewest(t *testing.T) {
	r := &ring{}
	for i := 0; i < ringSize+13; i++ {
		r.push(Entry{Bytes: int64(i)})
	}
	got := r.snapshot()
	if len(got) != ringSize {
		t.Fatalf("snapshot has %d entries, want the %d cap", len(got), ringSize)
	}
	if got[0].Bytes != int64(ringSize+12) {
		t.Errorf("newest is %d, want %d", got[0].Bytes, ringSize+12)
	}
	if got[ringSize-1].Bytes != 13 {
		t.Errorf("oldest kept is %d, want 13", got[ringSize-1].Bytes)
	}
	for i := 1; i < len(got); i++ {
		if got[i].Bytes != got[i-1].Bytes-1 {
			t.Fatalf("wrap reordered the ring at index %d: %d after %d", i, got[i].Bytes, got[i-1].Bytes)
		}
	}
}

// The follower writes while /recent-requests reads. Run with -race.
func TestRingIsSafeForConcurrentPushAndSnapshot(t *testing.T) {
	r := &ring{}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			r.push(Entry{Bytes: int64(i)})
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			_ = r.snapshot()
		}
	}()
	wg.Wait()
}

func TestRecentRequestsServesTheRingAsJSON(t *testing.T) {
	r := &ring{}
	s := newStats()
	recordLine(goldenLine, r, s)
	rec := httptest.NewRecorder()
	newMux(r, s).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/recent-requests", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type %q", ct)
	}
	// The Grafana panel reads this cross-origin and must never be served a
	// stale ring from an intermediary.
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("Cache-Control %q", rec.Header().Get("Cache-Control"))
	}
	if rec.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Errorf("the panel needs the CORS header, got %q", rec.Header().Get("Access-Control-Allow-Origin"))
	}
	var got []Entry
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("body is not a JSON array: %v (%s)", err, rec.Body.String())
	}
	if len(got) != 1 || got[0].URL != "http://archive.ubuntu.com/ubuntu/dists/noble/InRelease" {
		t.Fatalf("body %s", rec.Body.String())
	}
}

func TestRecentRequestsServesAnEmptyArrayNotNull(t *testing.T) {
	// A cold start has an empty ring. `null` would make the panel's row loop
	// throw instead of rendering nothing.
	rec := httptest.NewRecorder()
	newMux(&ring{}, newStats()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/recent-requests", nil))
	if body := strings.TrimSpace(rec.Body.String()); body != "[]" {
		t.Errorf("empty ring served %q, want []", body)
	}
}

func TestHealthzLeadsWithOkAndCarriesTheCounters(t *testing.T) {
	r := &ring{}
	s := newStats()
	recordLine(goldenLine, r, s)
	recordLine("drift", r, s)

	rec := httptest.NewRecorder()
	newMux(r, s).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	body := rec.Body.String()
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	// Probes and the README example match on the leading token.
	if !strings.HasPrefix(body, "ok ") {
		t.Fatalf("healthz must lead with ok: %q", body)
	}
	for _, want := range []string{"parsed=1", "skipped=1", "fielderr=0", "last_open_err="} {
		if !strings.Contains(body, want) {
			t.Errorf("healthz missing %q: %q", want, body)
		}
	}
}

// A /healthz served before the tailer has ever opened the log must not panic
// on the atomic.Value holding lastOpenErr, and must say so rather than
// inventing a timestamp.
func TestHealthzBeforeTheFirstReadSaysNever(t *testing.T) {
	rec := httptest.NewRecorder()
	newMux(&ring{}, newStats()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if !strings.Contains(rec.Body.String(), "last_read=never") {
		t.Errorf("healthz %q", rec.Body.String())
	}
}

func TestIndexIsSelfContainedAndOtherPathsAre404(t *testing.T) {
	mux := newMux(&ring{}, newStats())

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("index status %d", rec.Code)
	}
	body := rec.Body.String()
	// The VM serves this page to a browser that may have no route off the lab
	// network, so an external asset would render a broken page.
	for _, external := range []string{"src=\"http", "href=\"http", "@import"} {
		if strings.Contains(body, external) {
			t.Errorf("index references an external asset (%s)", external)
		}
	}
	// Squid log fields are attacker-controlled; the table must be built with
	// textContent, never innerHTML.
	if strings.Contains(body, "innerHTML") {
		t.Error("index builds rows with innerHTML; log fields are attacker-controlled")
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/not-a-page", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("unknown path served %d, want 404", rec.Code)
	}
}

func urls(entries []Entry) []string {
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = e.URL
	}
	return out
}
