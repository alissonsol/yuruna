// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

// /api/v1/pool-stats feeds the pool-control board's cards. The properties that
// matter are: the window is a CLOSED set (it is interpolated into LogQL), the
// rows are per-HOST (pool attribution belongs to the intent store, which this
// service never reads), a host that only failed still appears, and the answer is
// memoized so a phone refreshing does not become a Loki query storm.

// newLokiStub serves the instant-query endpoint, answering pass/fail counts from
// the supplied maps and recording every query it saw.
func newLokiStub(t *testing.T, pass, fail map[string]int64, seen *[]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/query") {
			http.NotFound(w, r)
			return
		}
		q := r.URL.Query().Get("query")
		*seen = append(*seen, q)
		src := pass
		if strings.Contains(q, `overallStatus="fail"`) {
			src = fail
		}
		type sample struct {
			Metric map[string]string `json:"metric"`
			Value  [2]any            `json:"value"`
		}
		var out struct {
			Data struct {
				Result []sample `json:"result"`
			} `json:"data"`
		}
		for hid, n := range src {
			out.Data.Result = append(out.Data.Result, sample{
				Metric: map[string]string{"hostId": hid},
				// Loki renders the sample value as a STRING in [ts, "value"],
				// which is exactly what the reader must cope with.
				Value: [2]any{1.0, strconv.FormatInt(n, 10)},
			})
		}
		_ = json.NewEncoder(w).Encode(out)
	}))
}

func newStatsState(lokiBase string) *poolState {
	return &poolState{
		// The readers derive /query from the PUSH url, as every other reader does.
		lokiURL:    lokiBase + "/loki/api/v1/push",
		httpClient: &http.Client{Timeout: 5 * time.Second},
		statsCache: map[string]*poolStatsCacheEntry{},
	}
}

func TestPoolStatsRejectsUnknownRange(t *testing.T) {
	var seen []string
	stub := newLokiStub(t, nil, nil, &seen)
	defer stub.Close()
	s := newStatsState(stub.URL)

	// The window is interpolated straight into LogQL, so anything outside the
	// preset set must be refused rather than passed through.
	for _, bad := range []string{"5m", "365d", "24h) or vector(1", "", "1h;drop"} {
		if bad == "" {
			continue // empty means "use the default", covered separately
		}
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range="+url.QueryEscape(bad), nil)
		s.handlePoolStats(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("range %q: status = %d, want 400", bad, rec.Code)
		}
	}
	if len(seen) != 0 {
		t.Errorf("a rejected range still queried Loki: %v", seen)
	}
}

func TestPoolStatsPerHostRowsIncludeFailOnlyHosts(t *testing.T) {
	var seen []string
	stub := newLokiStub(t,
		map[string]int64{"42aa": 10, "42bb": 3},
		map[string]int64{"42bb": 1, "42cc": 5}, // 42cc has ONLY failures
		&seen)
	defer stub.Close()
	s := newStatsState(stub.URL)

	rec := httptest.NewRecorder()
	s.handlePoolStats(rec, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=24h", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Range string `json:"range"`
		Hosts []struct {
			HostID string `json:"hostId"`
			Passed int64  `json:"passed"`
			Failed int64  `json:"failed"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Range != "24h" {
		t.Errorf("range = %q, want 24h", got.Range)
	}
	if len(got.Hosts) != 3 {
		t.Fatalf("hosts = %d, want 3 (a fail-only host must still appear): %+v", len(got.Hosts), got.Hosts)
	}
	want := map[string][2]int64{"42aa": {10, 0}, "42bb": {3, 1}, "42cc": {0, 5}}
	for _, h := range got.Hosts {
		w, ok := want[h.HostID]
		if !ok {
			t.Errorf("unexpected host %q", h.HostID)
			continue
		}
		if h.Passed != w[0] || h.Failed != w[1] {
			t.Errorf("%s = %d/%d, want %d/%d", h.HostID, h.Passed, h.Failed, w[0], w[1])
		}
	}
	// Rows are keyed by host and grouped by hostId, never by the `pool` stream
	// label -- that label falls back to the literal "default" for an
	// unidentified host, so summing on it would fold non-members into a pool.
	for _, q := range seen {
		if !strings.Contains(q, "sum by (hostId)") {
			t.Errorf("query does not group by hostId: %s", q)
		}
		if strings.Contains(q, "sum by (pool)") {
			t.Errorf("query groups by the push-time pool label: %s", q)
		}
	}
}

func TestPoolStatsCachesPerRange(t *testing.T) {
	var seen []string
	stub := newLokiStub(t, map[string]int64{"42aa": 1}, nil, &seen)
	defer stub.Close()
	s := newStatsState(stub.URL)

	for i := 0; i < 3; i++ {
		rec := httptest.NewRecorder()
		s.handlePoolStats(rec, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=24h", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d", rec.Code)
		}
	}
	// Two queries (pass + fail) for the first call; the rest are served warm.
	if len(seen) != 2 {
		t.Errorf("loki queries = %d, want 2 (three requests, one range, memoized)", len(seen))
	}

	// A DIFFERENT range must not be served from the 24h entry.
	rec := httptest.NewRecorder()
	s.handlePoolStats(rec, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=7d", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("7d status = %d", rec.Code)
	}
	if len(seen) != 4 {
		t.Errorf("loki queries = %d, want 4 (a second range is a separate entry)", len(seen))
	}
	for _, q := range seen[2:] {
		if !strings.Contains(q, "[7d]") {
			t.Errorf("7d request used the wrong window: %s", q)
		}
	}
}

func TestPoolStatsLokiDownIsNotZero(t *testing.T) {
	// A dead Loki must NOT render as "0 cycles" -- an operator would read that
	// as "nothing ran" rather than "we could not tell".
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer stub.Close()
	s := newStatsState(stub.URL)

	rec := httptest.NewRecorder()
	s.handlePoolStats(rec, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=1h", nil))
	if rec.Code != http.StatusBadGateway {
		t.Errorf("status = %d, want 502 when Loki is unavailable", rec.Code)
	}
}

func TestPoolStatsDefaultRange(t *testing.T) {
	var seen []string
	stub := newLokiStub(t, map[string]int64{"42aa": 1}, nil, &seen)
	defer stub.Close()
	s := newStatsState(stub.URL)

	rec := httptest.NewRecorder()
	s.handlePoolStats(rec, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	for _, q := range seen {
		if !strings.Contains(q, "[24h]") {
			t.Errorf("default window is not 24h: %s", q)
		}
	}
}
