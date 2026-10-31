// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428138f1-a631-4ea0-bd4f-d1dffb75c150

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

const (
	ringCanaryA   = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	ringCanaryB   = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	ringFollower  = "42cccccccccccccccccccccccccccccc"
	ringRevOld    = "1111111111111111111111111111111111111111"
	ringRevMiddle = "2222222222222222222222222222222222222222"
	ringRevNew    = "3333333333333333333333333333333333333333"
)

func ringHistoryRow(cycle, status, revision string, guests map[string]string) map[string]any {
	summary := map[string]any{}
	for guest, guestStatus := range guests {
		summary[guest] = map[string]any{"status": guestStatus, "stepDurationsSeconds": map[string]any{}}
	}
	return map[string]any{
		"cycleStartUtc": cycle, "overallStatus": status, "finishedAt": cycle,
		"gitCommits":   []map[string]any{{"sha": revision[:9], "repoUrl": "https://github.com/alissonsol/yuruna", "selectedSha": revision}},
		"guestSummary": summary,
	}
}

func ringStatusBody(t *testing.T, hostID string, rows ...map[string]any) []byte {
	t.Helper()
	body, err := json.Marshal(map[string]any{"hostId": hostID, "host": "host.ubuntu.kvm", "overallStatus": "pass", "history": rows})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestRingRowsCountOnlyCompletedCyclesThatNameTheirFullRevision(t *testing.T) {
	body := ringStatusBody(t, ringCanaryA,
		ringHistoryRow("2026-10-01T10:00:00Z", "pass", ringRevNew, map[string]string{"guest.a": "pass"}),
		ringHistoryRow("2026-10-01T09:00:00Z", "pass", ringRevMiddle, map[string]string{"guest.a": "pass", "guest.b": "skipped"}),
		ringHistoryRow("2026-10-01T08:00:00Z", "fail", ringRevOld, nil),
		ringHistoryRow("2026-10-01T07:00:00Z", "running", ringRevOld, nil),
		map[string]any{"cycleStartUtc": "2026-10-01T06:00:00Z", "overallStatus": "pass", "gitCommits": []map[string]any{{"sha": "abc1234"}}},
		map[string]any{"cycleStartUtc": "2026-10-01T05:00:00Z", "overallStatus": "pass", "gitCommits": []map[string]any{{"sha": ringRevOld}}, "guestSummary": map[string]any{"guest.a": "skipped"}},
	)
	rows := parseRingRows(body)
	want := []ringRow{
		{cycle: "2026-10-01T10:00:00Z", revision: ringRevNew, passed: true},
		{cycle: "2026-10-01T09:00:00Z", revision: ringRevMiddle, passed: false},
		{cycle: "2026-10-01T08:00:00Z", revision: ringRevOld, passed: false},
		{cycle: "2026-10-01T05:00:00Z", revision: ringRevOld, passed: false},
	}
	if len(rows) != len(want) {
		t.Fatalf("rows = %+v, want %+v", rows, want)
	}
	for i := range want {
		if rows[i] != want[i] {
			t.Errorf("row %d = %+v, want %+v", i, rows[i], want[i])
		}
	}
}

func TestRingRequiresTheConfiguredNumberOfCanaryPasses(t *testing.T) {
	s := newPoolState("default", 8080)
	s.recordRingRows(s.view(), ringCanaryA, []ringRow{{"2026-10-01T08:00:00Z", ringRevOld, true}})
	if got := s.qualifyRing(s.view(), []string{ringCanaryA, ringCanaryB}, 2); got.QualifyingRevision != "" {
		t.Fatalf("one pass qualified %s with two required", got.QualifyingRevision)
	}
	s.recordRingRows(s.view(), ringCanaryB, []ringRow{{"2026-10-01T09:00:00Z", ringRevOld, true}})
	got := s.qualifyRing(s.view(), []string{ringCanaryA, ringCanaryB}, 2)
	if got.QualifyingRevision != ringRevOld || got.QualifyingPasses != 2 {
		t.Fatalf("answer = %+v, want %s with 2 passes", got, ringRevOld)
	}
}

func TestRingCountsOnlyTheNamedCanaries(t *testing.T) {
	s := newPoolState("default", 8080)
	s.recordRingRows(s.view(), ringFollower, []ringRow{
		{"2026-10-01T08:00:00Z", ringRevNew, true},
		{"2026-10-01T09:00:00Z", ringRevNew, true},
	})
	s.recordRingRows(s.view(), ringCanaryA, []ringRow{{"2026-10-01T07:00:00Z", ringRevOld, true}})
	got := s.qualifyRing(s.view(), []string{ringCanaryA}, 1)
	if got.QualifyingRevision != ringRevOld {
		t.Fatalf("qualifying = %s, want %s: a non-canary's passes must not count", got.QualifyingRevision, ringRevOld)
	}
}

func TestANewerRevisionThatOnlyFailedLeavesTheQualifiedOneInPlace(t *testing.T) {
	s := newPoolState("default", 8080)
	s.recordRingRows(s.view(), ringCanaryA, []ringRow{
		{"2026-10-01T08:00:00Z", ringRevOld, true},
		{"2026-10-01T09:00:00Z", ringRevNew, false},
		{"2026-10-01T10:00:00Z", ringRevNew, false},
	})
	got := s.qualifyRing(s.view(), []string{ringCanaryA}, 1)
	if got.QualifyingRevision != ringRevOld {
		t.Fatalf("qualifying = %s, want %s", got.QualifyingRevision, ringRevOld)
	}
	if len(got.Revisions) != 2 || got.Revisions[0].Revision != ringRevNew || got.Revisions[0].Failures != 2 {
		t.Fatalf("revisions = %+v, want the failing newer revision listed first", got.Revisions)
	}
}

// Results reach the collector in whatever order hosts answer; the newest
// revision is the one canaries started running last, not the one read last.
func TestRingOrdersRevisionsByCanaryCycleStartNotByArrival(t *testing.T) {
	s := newPoolState("default", 8080)
	s.recordRingRows(s.view(), ringCanaryB, []ringRow{{"2026-10-01T12:00:00Z", ringRevNew, true}})
	s.recordRingRows(s.view(), ringCanaryA, []ringRow{
		{"2026-10-01T08:00:00Z", ringRevMiddle, true},
		{"2026-10-01T13:00:00Z", ringRevMiddle, true},
	})
	got := s.qualifyRing(s.view(), []string{ringCanaryA, ringCanaryB}, 1)
	if got.QualifyingRevision != ringRevNew {
		t.Fatalf("qualifying = %s, want %s (its first canary cycle is the latest)", got.QualifyingRevision, ringRevNew)
	}
}

func TestRingCountsARetiredCanaryIDForItsSuccessor(t *testing.T) {
	s := newPoolState("default", 8080)
	s.view().SetAliases(map[string]string{ringCanaryA: ringCanaryB})
	s.recordRingRows(s.view(), ringCanaryA, []ringRow{{"2026-10-01T08:00:00Z", ringRevOld, true}})
	if got := s.qualifyRing(s.view(), []string{ringCanaryB}, 1); got.QualifyingRevision != ringRevOld {
		t.Fatalf("qualifying = %q, want the retired id's pass counted for its successor", got.QualifyingRevision)
	}
}

func TestRingRouteValidatesItsQuery(t *testing.T) {
	s := newPoolState("default", 8080)
	for _, query := range []string{
		"canary=" + ringCanaryA,
		"canary=not-a-host&passes=1",
		"canary=" + ringCanaryA + "&passes=0",
		"canary=" + ringCanaryA + "&passes=1001",
		"canary=" + ringCanaryA + "&passes=two",
	} {
		rec := httptest.NewRecorder()
		s.handleFrameworkRing(rec, httptest.NewRequest(http.MethodGet, routeFrameworkRing+"?"+query, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s answered %d, want 400", query, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	s.handleFrameworkRing(rec, httptest.NewRequest(http.MethodGet, routeFrameworkRing+"?passes=1", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"qualifyingRevision":""`) {
		t.Fatalf("no canaries answered %d %s, want 200 with no qualifying revision", rec.Code, rec.Body.String())
	}
}

// The facts come from each host's status.json during the ordinary poll, are
// kept in the state file, and a restarted collector that loads the file answers
// the same while the canary is offline.
func TestRingFactsComeFromThePollAndSurviveARestart(t *testing.T) {
	now := time.Now().UTC()
	body := ringStatusBody(t, ringCanaryA,
		ringHistoryRow("2026-10-01T09:00:00Z", "pass", ringRevNew, map[string]string{"guest.a": "pass"}),
		ringHistoryRow("2026-10-01T08:00:00Z", "pass", ringRevOld, map[string]string{"guest.a": "pass"}),
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/runtime/status.json" {
			_, _ = w.Write(body)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	u, _ := url.Parse(srv.URL)
	port, _ := strconv.Atoi(u.Port())
	statePath := filepath.Join(t.TempDir(), "framework-ring.json")
	s := newPoolState("default", port)
	s.ringStateFile = statePath
	s.view().Hosts[ringCanaryA] = &hostView{HostId: ringCanaryA, CurrentIP: u.Hostname(), LastSeenUnixMs: now.UnixMilli()}
	s.pollWithFreshConnections("no-such-squid.log", "", now)
	srv.Close()

	var first ringAnswer
	s.st.Do(func(view *poolstate.View) {
		first = s.qualifyRing(view, []string{ringCanaryA}, 1)
	})
	if first.QualifyingRevision != ringRevNew {
		t.Fatalf("after the poll the qualifying revision is %q, want %s", first.QualifyingRevision, ringRevNew)
	}
	if _, err := os.Stat(statePath); err != nil {
		t.Fatalf("the poll did not write the state file: %v", err)
	}

	restarted := newPoolState("default", port)
	restarted.ringStateFile = statePath
	restarted.loadRingState()
	if got := restarted.qualifyRing(restarted.view(), []string{ringCanaryA}, 1); got.QualifyingRevision != ringRevNew || got.QualifyingPasses != 1 {
		t.Fatalf("after a restart the answer is %+v, want %s with 1 pass", got, ringRevNew)
	}
}

func TestAnUnreadableRingStateStartsEmpty(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "framework-ring.json")
	if err := os.WriteFile(statePath, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := newPoolState("default", 8080)
	s.ringStateFile = statePath
	s.loadRingState()
	if got := s.qualifyRing(s.view(), []string{ringCanaryA}, 1); got.QualifyingRevision != "" || len(got.Revisions) != 0 {
		t.Fatalf("an unreadable state produced %+v", got)
	}
}

// The pool-status snapshot is unauthenticated: reading the guest summaries for
// the ring must not put them, or the parsed rows, into it.
func TestRingRowsStayOutOfThePublicSnapshot(t *testing.T) {
	body := ringStatusBody(t, ringCanaryA,
		ringHistoryRow("2026-10-01T09:00:00Z", "pass", ringRevNew, map[string]string{"guest.secret-name": "pass"}))
	var st hostStatus
	if err := json.Unmarshal(body, &st); err != nil {
		t.Fatal(err)
	}
	if rows := parseRingRows(body); len(rows) != 1 {
		t.Fatalf("the fixture body should carry one ring row, parsed %d", len(rows))
	}
	out, err := json.Marshal(&st)
	if err != nil {
		t.Fatal(err)
	}
	for _, leak := range []string{"guest.secret-name", "guestSummary", ringRevNew} {
		if strings.Contains(string(out), leak) {
			t.Errorf("snapshot carries %q: %s", leak, out)
		}
	}
}

func TestRingStoreStaysBounded(t *testing.T) {
	s := newPoolState("default", 8080)
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < ringMaxRevisions+10; i++ {
		revision := fmt.Sprintf("%040x", i+1)
		s.recordRingRows(s.view(), ringCanaryA, []ringRow{{start.Add(time.Duration(i) * time.Hour).Format(time.RFC3339), revision, true}})
	}
	if len(s.view().Ring) != ringMaxRevisions {
		t.Fatalf("store holds %d revisions, want %d", len(s.view().Ring), ringMaxRevisions)
	}
	if _, kept := s.view().Ring[fmt.Sprintf("%040x", 1)]; kept {
		t.Fatal("the oldest revision survived the bound")
	}
	for i := 0; i < ringMaxCyclesPerHost+5; i++ {
		later := start.Add(time.Duration(ringMaxRevisions+100) * time.Hour)
		s.recordRingRows(s.view(), ringCanaryB, []ringRow{{later.Add(time.Duration(i) * time.Minute).Format(time.RFC3339), ringRevOld, true}})
	}
	if n := len(s.view().Ring[ringRevOld][ringCanaryB]); n != ringMaxCyclesPerHost {
		t.Fatalf("one host keeps %d cycles at a revision, want %d", n, ringMaxCyclesPerHost)
	}
}
