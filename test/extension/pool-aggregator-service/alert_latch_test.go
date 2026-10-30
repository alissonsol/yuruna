// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42f0c6d8-3b51-4a7e-9d24-8e6b1f0a5c93

package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// A collector restart must not forget a pool alert that is firing. The latch
// lived only in memory: a pool still degraded after the restart fired a second
// alert under a new id -- paging again -- and the first alert's lifecycle never
// closed. Restored from the incident feed, the latch keeps its id, and the
// eventual rearm pairs with the alert that fired.
func TestARestartKeepsAFiringPoolAlert(t *testing.T) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	firedAt := base.Add(-time.Hour)
	line := fmt.Sprintf(`{"event":"pool_alert_fired","incidentId":"alert-pool-%d","startedAt":%q,"timestamp":%q,"scope":"pool"}`,
		firedAt.Unix(), firedAt.Format(time.RFC3339), firedAt.Format(time.RFC3339))
	loki := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"data":{"result":[{"stream":{"pool":"lab","src":"incident","scope":"pool","kind":"alert"},"values":[[%q,%q]]}]}}`,
			fmt.Sprint(firedAt.UnixNano()), line)
	}))
	defer loki.Close()

	s := newPoolState("default", 8080)
	s.gating["lab"] = gatingPolicy{FailuresBeforeAlert: 2, SuccessesBeforeRearm: 2, HealthyThreshold: 0.5, DegradedAfter: 10 * time.Minute}
	gateHost(s, "42a", "lab", "fail", true)
	gateHost(s, "42b", "lab", "fail", true)
	s.rehydrateIncidentsFromLoki(loki.URL+"/loki/api/v1/push", "default", 24*time.Hour, base)

	var events []incidentEvent
	for _, at := range []time.Duration{0, 11 * time.Minute, 12 * time.Minute, 13 * time.Minute} {
		events = append(events, s.evaluatePoolGate(base.Add(at))...)
	}
	for _, ev := range events {
		if ev.Alert && !ev.Rearm {
			t.Fatalf("the still-degraded pool fired a second alert %q after the restart", ev.ID)
		}
	}
	s.hosts["42a"].Status.OverallStatus = "pass"
	for _, at := range []time.Duration{14 * time.Minute, 15 * time.Minute} {
		events = append(events, s.evaluatePoolGate(base.Add(at))...)
	}
	want := fmt.Sprintf("alert-pool-%d", firedAt.Unix())
	rearmed := false
	for _, ev := range events {
		if ev.Alert && ev.Rearm {
			if ev.ID != want || !ev.StartedAt.Equal(firedAt) {
				t.Fatalf("rearm = id %q started %v; want the restored alert %q started %v", ev.ID, ev.StartedAt, want, firedAt)
			}
			rearmed = true
		}
	}
	if !rearmed {
		t.Fatal("the recovered pool never re-armed the alert that fired before the restart")
	}
}

// A pool whose latest alert line is a rearm is not firing, and stays unlatched.
func TestARestartLeavesARearmedPoolAlertClosed(t *testing.T) {
	s := newPoolState("default", 8080)
	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	stream := lokiStream{Stream: map[string]string{"pool": "lab", "scope": "pool", "kind": "alert"}, Values: [][2]string{
		{fmt.Sprint(t0.Add(time.Minute).UnixNano()), `{"event":"pool_alert_rearmed","incidentId":"alert-pool-1","startedAt":"2026-01-01T00:00:00Z"}`},
		{fmt.Sprint(t0.UnixNano()), `{"event":"pool_alert_fired","incidentId":"alert-pool-1","startedAt":"2026-01-01T00:00:00Z"}`},
	}}
	if n := s.applyPoolAlertLines([]lokiStream{stream}); n != 0 || s.poolGate["lab"] != nil {
		t.Fatalf("restored %d latch(es) (%+v) for a pool whose last line is a rearm", n, s.poolGate["lab"])
	}
}
