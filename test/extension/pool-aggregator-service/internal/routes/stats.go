// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 424760e9-fcbc-4840-bec8-2d2fdb5bc52b

package routes

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The Loki instant query and its answer, which the counts are read from.
type lokiVectorResult = loki.Vector

var instantQueryURL = loki.InstantQueryURL

// PoolStatsRanges is the CLOSED set of windows /api/v1/pool-stats accepts.
// The value is interpolated into LogQL, so it is never free-form input; and every
// window must stay inside Loki's retention_period (2160h on the proxy) -- a longer
// one would silently return a partial answer that reads as a real number.
var PoolStatsRanges = map[string]bool{"1h": true, "24h": true, "7d": true, "30d": true}

// countCyclesByHost runs one instant LogQL count for a terminal overallStatus
// over the window, lab-wide and grouped by hostId, and returns hostId -> count.
// It deliberately does not group by the pool label: the caller joins the rows
// onto pool membership.
// See https://yuruna.link/42c29d04-001b.
func (s *Server) countCyclesByHost(status, window string) (map[string]int64, error) {
	out := map[string]int64{}
	if s.lokiURL == "" || s.httpClient == nil {
		return out, errors.New("loki-unconfigured")
	}
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`sum by (hostId) (count_over_time({pool=~".+"} | json | overallStatus=%q [%s]))`, status, window))
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, instantQueryURL(s.lokiURL)+"?"+params.Encode(), nil)
	if err != nil {
		return out, err
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return out, fmt.Errorf("loki status %d", resp.StatusCode)
	}
	var vr lokiVectorResult
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&vr); err != nil {
		return out, err
	}
	for _, r := range vr.Data.Result {
		hid := r.Metric["hostId"]
		if hid == "" {
			continue
		}
		// Loki renders the sample value as a string in the [ts, "value"] pair.
		if sv, ok := r.Value[1].(string); ok {
			if n, err := strconv.ParseInt(sv, 10, 64); err == nil {
				out[hid] = n
			}
		}
	}
	return out, nil
}

// HandlePoolStats serves per-host terminal-cycle counts over a preset window,
// only what Loki can answer: the pool-control service joins them onto pool
// membership. Read-only and open, the same posture as /api/v1/pool-status.
// See https://yuruna.link/42c29d04-001b.
func (s *Server) HandlePoolStats(w http.ResponseWriter, r *http.Request) {
	window := r.URL.Query().Get("range")
	if window == "" {
		window = "24h"
	}
	if !PoolStatsRanges[window] {
		localizedJSONError(w, r, "aggregator.unsupported_range_use_1h_24h_7d_or_30d", http.StatusBadRequest)
		return
	}

	epoch, cached, hit := s.cachedPoolStats(window)
	if hit {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(cached)
		return
	}

	passed, errPass := s.countCyclesByHost("pass", window)
	failed, errFail := s.countCyclesByHost("fail", window)
	if errPass != nil || errFail != nil {
		// An unavailable leg is not a real zero: say so rather than serve zeros, which the board
		// would render as a real "0 cycles" and an operator would read as
		// "nothing ran" instead of "we could not tell".
		localizedJSONError(w, r, "aggregator.loki_query_failed", http.StatusBadGateway)
		return
	}
	// Loki retains the original hostId label. Project its counts through the
	// durable alias ledger so pool membership on the live ID sees all cycles.
	canonicalPassed, canonicalFailed := map[string]int64{}, map[string]int64{}
	s.st.Do(func(view *poolstate.View) {
		for id, n := range passed {
			canonicalPassed[view.CanonicalHostID(id)] += n
		}
		for id, n := range failed {
			canonicalFailed[view.CanonicalHostID(id)] += n
		}
	})
	passed, failed = canonicalPassed, canonicalFailed

	type hostRow struct {
		HostID string `json:"hostId"`
		Passed int64  `json:"passed"`
		Failed int64  `json:"failed"`
	}
	ids := map[string]bool{}
	for id := range passed {
		ids[id] = true
	}
	for id := range failed {
		ids[id] = true
	}
	sorted := make([]string, 0, len(ids))
	for id := range ids {
		sorted = append(sorted, id)
	}
	sort.Strings(sorted)
	rows := make([]hostRow, 0, len(sorted))
	for _, id := range sorted {
		rows = append(rows, hostRow{HostID: id, Passed: passed[id], Failed: failed[id]})
	}

	out := struct {
		Range      string    `json:"range"`
		ComputedAt string    `json:"computedAt"`
		Hosts      []hostRow `json:"hosts"`
	}{Range: window, ComputedAt: time.Now().UTC().Format(time.RFC3339), Hosts: rows}

	payload, err := json.Marshal(out)
	if err != nil {
		localizedJSONError(w, r, "aggregator.encode_failed", http.StatusInternalServerError)
		return
	}
	s.cachePoolStats(window, epoch, payload)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(payload)
}
