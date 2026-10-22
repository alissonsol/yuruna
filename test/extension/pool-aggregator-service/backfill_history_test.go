// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestBackfillRestoresStatusHistoryWhenCycleFilesAreUnavailable(t *testing.T) {
	for _, mode := range []string{"listing-failed", "deferred", "event-file-failed"} {
		t.Run(mode, func(t *testing.T) {
			now := bfAt("2026-10-02T12:00:00Z")
			clock := func() time.Time { return now }
			loki := newFakeLoki(clock)
			lokiSrv := httptest.NewServer(loki)
			t.Cleanup(lokiSrv.Close)
			prom := newFakeProm(t, clock)
			promSrv := httptest.NewServer(prom)
			t.Cleanup(promSrv.Close)
			var hostRequests atomic.Int32
			host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hostRequests.Add(1)
				if mode == "event-file-failed" && r.URL.Path == "/log/" {
					fmt.Fprintf(w, `<a href="000001.2026-10-02.09-00-00.%s/">cycle</a>`, bfHostA)
					return
				}
				http.Error(w, "unavailable", http.StatusServiceUnavailable)
			}))
			t.Cleanup(host.Close)
			var historyMu sync.Mutex
			history := []map[string]string{
				{"cycleStartUtc": "2026-10-02T09:00:00Z", "finishedAt": "2026-10-02T09:30:17Z", "overallStatus": "pass"},
				{"cycleStartUtc": "2026-10-02T10:00:00Z", "finishedAt": "2026-10-02T10:30:00Z", "overallStatus": "fail"},
				{"cycleStartUtc": "2026-10-02T07:00:00Z", "finishedAt": "2026-10-02T07:30:00Z", "overallStatus": "running"},
				{"cycleStartUtc": "2026-10-02T06:00:00Z", "finishedAt": "bad-time", "overallStatus": "pass"},
				{"cycleStartUtc": "2026-10-02T05:00:00Z", "finishedAt": "2026-10-02T04:30:00Z", "overallStatus": "fail"},
				{"cycleStartUtc": "2026-10-02T03:00:00Z", "finishedAt": "2026-10-03T03:30:00Z", "overallStatus": "pass"},
				{"cycleStartUtc": "2026-10-02T02:00:00", "finishedAt": "2026-10-02T02:30:00Z", "overallStatus": "skipped"},
			}
			agg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				historyMu.Lock()
				defer historyMu.Unlock()
				_ = json.NewEncoder(w).Encode(map[string]any{"pool": "red", "hosts": []any{map[string]any{
					"hostId": bfHostA, "baseUrl": host.URL, "reachable": true,
					"status": map[string]any{"host": "host.macos.utm", "overallStatus": "pass", "history": history},
				}}})
			}))
			t.Cleanup(agg.Close)
			cfg, err := parseBackfillFlags([]string{"-aggregator", agg.URL, "-loki", lokiSrv.URL + "/loki/api/v1/push", "-prometheus", promSrv.URL,
				"-state-dir", t.TempDir(), "-horizon", "24h", "-once"})
			if err != nil {
				t.Fatal(err)
			}
			if mode == "deferred" {
				hs := loadHostState(cfg.stateDir, bfHostA)
				hs.SeenAt = now
				hs.ListingDeferredUntil = now.Add(time.Hour)
				if err := hs.save(cfg.stateDir); err != nil {
					t.Fatal(err)
				}
			}
			labels := map[string]string{}
			for _, label := range hostStatusLabels("red", bfHostA) {
				labels[label[0]] = label[1]
			}
			liveAt := bfAt("2026-10-02T10:12:00Z").UnixMilli()
			if err := prom.add(labels, liveAt, 8, false); err != nil {
				t.Fatal(err)
			}
			b := newBackfiller(cfg, &http.Client{Timeout: time.Second}, clock, func(context.Context, time.Duration) bool { return true })
			if res := b.sweep(context.Background()); res.Samples == 0 || res.Cycles != 0 || res.Events != 0 || res.Incidents != 0 {
				t.Errorf("want only known timeline intervals restored, got %+v", res)
			}
			key := labelKey(labels)
			prom.mu.Lock()
			for timestamp, want := range map[string]float64{
				"2026-10-02T09:10:00Z": 1, "2026-10-02T09:30:00Z": 1, "2026-10-02T09:30:17Z": 2,
				"2026-10-02T10:20:00Z": 1, "2026-10-02T10:30:00Z": 3,
			} {
				if got, ok := prom.samples[key][bfAt(timestamp).UnixMilli()]; !ok || got != want {
					t.Errorf("%s: got %v (present %v), want %v", timestamp, got, ok, want)
				}
			}
			for at := range prom.backfilled[key] {
				known := (at >= bfAt("2026-10-02T09:00:00Z").UnixMilli() && at <= bfAt("2026-10-02T09:30:17Z").UnixMilli()) ||
					(at >= bfAt("2026-10-02T10:00:00Z").UnixMilli() && at <= bfAt("2026-10-02T10:30:00Z").UnixMilli())
				if !known {
					t.Errorf("sample outside a known completed interval: %s", time.UnixMilli(at))
				}
			}
			if prom.samples[key][liveAt] != 8 || prom.backfilled[key][liveAt] {
				t.Error("the collector's paused sample was replaced")
			}
			prom.mu.Unlock()
			if loki.pushCount() != 0 {
				t.Error("status history must not fabricate cycle, event, or incident log lines")
			}
			if mode == "deferred" && hostRequests.Load() != 0 {
				t.Error("a deferred host was asked for history")
			}
			writes := prom.writeCount()
			b.sweep(context.Background())
			if prom.writeCount() != writes {
				t.Error("an unchanged status history rewrote existing timeline samples")
			}
			historyMu.Lock()
			history = append(history, map[string]string{"cycleStartUtc": "2026-10-02T08:00:00Z", "finishedAt": "2026-10-02T08:20:00Z", "overallStatus": "skipped"})
			historyMu.Unlock()
			if res := b.sweep(context.Background()); res.Samples == 0 {
				t.Error("the derived-state refresh interval suppressed newly available history")
			}
			prom.mu.Lock()
			if got, ok := prom.samples[key][bfAt("2026-10-02T08:20:00Z").UnixMilli()]; !ok || got != 4 {
				t.Errorf("new skipped cycle end: got %v (present %v), want 4", got, ok)
			}
			prom.mu.Unlock()
		})
	}
}

func TestBackfillUsesLocalListingOnlyWithReadableProxyArchive(t *testing.T) {
	for _, available := range []bool{false, true} {
		t.Run(fmt.Sprintf("archive-readable-%t", available), func(t *testing.T) {
			host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if got := r.URL.Query().Get("localOnly") == "true"; got != available {
					t.Errorf("localOnly=%t, want %t: %s", got, available, r.URL)
				}
				fmt.Fprint(w, "<html></html>")
			}))
			t.Cleanup(host.Close)
			cfg, err := parseBackfillFlags([]string{"-state-dir", t.TempDir(), "-archive-root", t.TempDir(), "-once"})
			if err != nil {
				t.Fatal(err)
			}
			if available {
				if err := os.MkdirAll(filepath.Join(cfg.archiveRoot, bfHostA, "test-cycles"), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			now := bfAt("2026-10-02T12:00:00Z")
			b := newBackfiller(cfg, host.Client(), func() time.Time { return now }, func(context.Context, time.Duration) bool { return true })
			hs := loadHostState(cfg.stateDir, bfHostA)
			_, _, err = b.discover(context.Background(), activeHost{HostID: bfHostA, BaseURL: host.URL}, hs,
				&pacer{now: b.now, sleep: b.sleep}, now.Add(-cfg.horizon))
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestArchiveFoldersKeepsReadableCopiesWhenMarkerStatFails(t *testing.T) {
	root := t.TempDir()
	committed := "000001.2026-10-02.09-00-00." + bfHostA
	incomplete := "000002.2026-10-02.10-00-00." + bfHostA
	for _, name := range []string{committed, incomplete} {
		if err := os.MkdirAll(filepath.Join(root, bfHostA, "test-cycles", name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	committedDir := filepath.Join(root, bfHostA, "test-cycles", committed)
	if err := os.WriteFile(filepath.Join(committedDir, ".yuruna-complete"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	folders, readable := archiveFolders(root, bfHostA)
	if !readable || len(folders) != 1 || folders[committed] != committedDir {
		t.Fatalf("an ordinary incomplete copy must not disable archive reads: folders=%v readable=%t", folders, readable)
	}
	// A self-referencing marker produces a stat error even when tests run as an
	// administrator, unlike permission-bit fixtures that administrators bypass.
	marker := filepath.Join(root, bfHostA, "test-cycles", incomplete, ".yuruna-complete")
	if err := os.Symlink(".yuruna-complete", marker); err != nil {
		t.Skipf("symlinks unavailable here: %v", err)
	}
	folders, readable = archiveFolders(root, bfHostA)
	if readable || len(folders) != 1 || folders[committed] != committedDir {
		t.Errorf("an unreadable marker must retain readable copies and require the host's merged listing: folders=%v readable=%t", folders, readable)
	}
}

func TestBackfillStatusHistoryDefersToCycleEvidence(t *testing.T) {
	now := bfAt("2026-10-02T12:00:00Z")
	clock := func() time.Time { return now }
	loki := newFakeLoki(clock)
	loki.seed(cycleTransitionPayload("red", &hostStatus{
		HostId: bfHostA, CycleStartUtc: "2026-10-02T10:00:00Z", StartedAt: "2026-10-02T10:00:00Z",
		FinishedAt: "2026-10-02T10:20:00Z", OverallStatus: "pass",
	}, "http://host", bfAt("2026-10-02T10:21:00Z")))
	lokiSrv := httptest.NewServer(loki)
	t.Cleanup(lokiSrv.Close)
	prom := newFakeProm(t, clock)
	promSrv := httptest.NewServer(prom)
	t.Cleanup(promSrv.Close)
	cfg, err := parseBackfillFlags([]string{"-loki", lokiSrv.URL + "/loki/api/v1/push", "-prometheus", promSrv.URL, "-once"})
	if err != nil {
		t.Fatal(err)
	}
	b := newBackfiller(cfg, &http.Client{Timeout: time.Second}, clock, func(context.Context, time.Duration) bool { return true })
	h := activeHost{HostID: bfHostA, Pool: "red", History: []cycleVerdict{
		{CycleStartUtc: "2026-10-02T09:00:00Z", FinishedAt: "2026-10-02T09:30:00Z", OverallStatus: "pass"},
		{CycleStartUtc: "2026-10-02T10:00:00Z", FinishedAt: "2026-10-02T10:30:00Z", OverallStatus: "fail"},
		{CycleStartUtc: "2026-10-02T11:00:00Z", FinishedAt: "2026-10-02T11:20:00Z", OverallStatus: "skipped"},
	}}
	outcomes := map[string]cycleOutcome{
		"first":  {CycleStartUtc: "2026-10-02T09:00:00Z", Start: bfAt("2026-10-02T09:00:00Z"), End: bfAt("2026-10-02T09:20:00Z"), Status: "fail"},
		"second": {CycleStartUtc: "2026-10-02T10:00:00Z", Start: bfAt("2026-10-02T10:00:00Z"), End: bfAt("2026-10-02T10:28:00Z"), Status: "fail"},
	}
	if _, err := b.fillTimeline(context.Background(), h, bfAt("2026-10-02T08:00:00Z"), now, outcomes); err != nil {
		t.Fatal(err)
	}
	labels := map[string]string{}
	for _, label := range hostStatusLabels("red", bfHostA) {
		labels[label[0]] = label[1]
	}
	prom.mu.Lock()
	defer prom.mu.Unlock()
	samples := prom.samples[labelKey(labels)]
	for timestamp, want := range map[string]float64{
		"2026-10-02T09:24:00Z": 3, // The index's completed failure beats the summary's running interval.
		"2026-10-02T10:24:00Z": 2, // Loki wins over both the index and the summary.
		"2026-10-02T11:20:00Z": 4, // A cycle absent from both sources comes from the summary.
	} {
		if got, ok := samples[bfAt(timestamp).UnixMilli()]; !ok || got != want {
			t.Errorf("%s: got %v (present %v), want %v", timestamp, got, ok, want)
		}
	}
	if _, ok := samples[bfAt("2026-10-02T11:22:00Z").UnixMilli()]; ok {
		t.Error("the summary verdict was held beyond its known completion")
	}
}

func TestStatusHistoryCompletionSamplesRespectCoverageAndOrdering(t *testing.T) {
	cycles := timelineFromHistory([]cycleVerdict{
		{CycleStartUtc: "2026-10-02T09:00:00Z", FinishedAt: "2026-10-02T09:10:17Z", OverallStatus: "pass"},
		{CycleStartUtc: "2026-10-02T09:20:00Z", FinishedAt: "2026-10-02T09:30:17Z", OverallStatus: "fail"},
		{CycleStartUtc: "2026-10-02T09:40:00Z", FinishedAt: "2026-10-02T09:50:00Z", OverallStatus: "skipped"},
	}, bfAt("2026-10-02T12:00:00Z"))
	covered := map[int64]bool{bfAt("2026-10-02T09:35:00Z").Unix(): true}
	samples := timelineSamples(cycles, uncoveredSteps(bfAt("2026-10-02T08:55:00Z"), bfAt("2026-10-02T10:00:00Z"), covered), defaultSampleStep, maxFinalHold)
	finals := map[int64]float64{}
	for i, sample := range samples {
		if i > 0 && samples[i-1].T >= sample.T {
			t.Errorf("sample timestamps are not strictly increasing: %+v", samples)
		}
		if sample.V != 1 {
			finals[sample.T] = sample.V
		}
	}
	if len(finals) != 2 || finals[bfAt("2026-10-02T09:10:17Z").UnixMilli()] != 2 || finals[bfAt("2026-10-02T09:50:00Z").UnixMilli()] != 4 {
		t.Errorf("want only the two uncovered completion observations: %+v", finals)
	}
}
