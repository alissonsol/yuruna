// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// gateHost registers a pool member with a fixed reachability + overall status so a
// pool-gate test can drive the healthy fraction deterministically.
func gateHost(s *poolState, hid, pool, status string, reachable bool) {
	hv := &hostView{HostId: hid, PoolId: pool, Reachable: reachable}
	if status != "" {
		hv.Status = &hostStatus{HostId: hid, OverallStatus: status}
	}
	s.hosts[hid] = hv
}

// fw builds a fail window with every fail sharing one class. Tests that need a
// class mix build []failRec literals directly.
func fw(class string, ts ...time.Time) []failRec {
	out := make([]failRec, 0, len(ts))
	for _, t := range ts {
		out = append(out, failRec{t: t, class: class})
	}
	return out
}

// TestEvaluateIncidents exercises the N-failures-in-M-minutes state machine:
// open at >=N in-window fails, no flapping while it stays failing, peak
// tracking, hysteresis (stays open until the window empties), and resolve +
// prune once all fails age out.
func TestEvaluateIncidents(t *testing.T) {
	s := newPoolState("test", 8080)
	s.incidentN = 3
	s.incidentWin = time.Hour
	hid := "4253419c1f0b45a08260f36a1521a857"
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)

	// 2 fails in window -> below threshold, no incident.
	s.failWindow[hid] = fw("script_error", now.Add(-50*time.Minute), now.Add(-40*time.Minute))
	if ev := s.evaluateIncidents(now); len(ev) != 0 || s.incident[hid] != nil {
		t.Fatalf("2 fails must not open an incident; events=%d incident=%v", len(ev), s.incident[hid])
	}

	// 3rd fail -> opens exactly one incident, carrying the failure class.
	s.failWindow[hid] = append(s.failWindow[hid], failRec{t: now.Add(-5 * time.Minute), class: "script_error"})
	ev := s.evaluateIncidents(now)
	if len(ev) != 1 || !ev[0].open || ev[0].count != 3 || s.incident[hid] == nil {
		t.Fatalf("3 fails must open one incident with count 3; got events=%+v incident=%v", ev, s.incident[hid])
	}
	if ev[0].dominantClass != "script_error" || ev[0].classHist["script_error"] != 3 {
		t.Fatalf("open event must carry the class histogram; got dominant=%q hist=%v", ev[0].dominantClass, ev[0].classHist)
	}
	openID := s.incident[hid].id

	// 4th fail -> still open, no new event, peak rises, id stable.
	s.failWindow[hid] = append(s.failWindow[hid], failRec{t: now.Add(-1 * time.Minute), class: "script_error"})
	if ev := s.evaluateIncidents(now); len(ev) != 0 {
		t.Fatalf("a further fail must not emit a new event; got %+v", ev)
	}
	if s.incident[hid].peak != 4 {
		t.Fatalf("peak want 4 got %d", s.incident[hid].peak)
	}
	if s.incident[hid].id != openID {
		t.Fatalf("incident id must not change mid-incident")
	}

	// Hysteresis: advance so all but one fail age out -> stays open, no event.
	mid := now.Add(58 * time.Minute) // cutoff = mid-60m = now-2m; only the now-1m fail survives
	if ev := s.evaluateIncidents(mid); len(ev) != 0 {
		t.Fatalf("dropping below N (but >0) must keep the incident open with no event; got %+v", ev)
	}
	if s.incident[hid] == nil {
		t.Fatalf("incident must remain open while any in-window fail remains")
	}
	if got := len(s.failWindow[hid]); got != 1 {
		t.Fatalf("prune want 1 surviving fail got %d", got)
	}

	// All fails age out -> resolve exactly once, prune empty, state cleared. The
	// resolve line carries the PEAK histogram (window has aged to 0 by now).
	later := now.Add(3 * time.Hour)
	ev = s.evaluateIncidents(later)
	if len(ev) != 1 || ev[0].open {
		t.Fatalf("aged-out fails must resolve the incident once; got %+v", ev)
	}
	if ev[0].peak != 4 {
		t.Fatalf("resolve event peak want 4 got %d", ev[0].peak)
	}
	if ev[0].dominantClass != "script_error" || ev[0].classHist["script_error"] != 4 {
		t.Fatalf("resolve event must carry the peak class histogram; got dominant=%q hist=%v", ev[0].dominantClass, ev[0].classHist)
	}
	if s.incident[hid] != nil {
		t.Fatalf("incident must be cleared after resolve")
	}
	if _, ok := s.failWindow[hid]; ok {
		t.Fatalf("empty fail window must be deleted")
	}

	// Quiet host (no fails) -> nothing happens.
	if ev := s.evaluateIncidents(later.Add(time.Hour)); len(ev) != 0 {
		t.Fatalf("a quiet pool must emit no incident events; got %+v", ev)
	}
}

// TestIncidentRestartResolve simulates the state restored from the incident feed
// on restart (rehydrateIncidentsFromLoki sets s.incident with the ORIGINAL
// id/startedAt) plus a seeded fail window, and verifies the incident stays open
// even when currently below the threshold and resolves exactly once -- carrying
// the original id + startedAt -- when the window empties. Guards the restart
// correlation that the fail-window-only reconstruction got wrong.
func TestIncidentRestartResolve(t *testing.T) {
	s := newPoolState("test", 8080)
	s.incidentN = 3
	s.incidentWin = time.Hour
	hid := "4253419c1f0b45a08260f36a1521a857"
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	origStart := now.Add(-90 * time.Minute) // original open predates the current window
	origID := incidentID(hid, origStart)

	// As restored from {src=incident}: original id/startedAt + one surviving
	// in-window fail (below N).
	s.incident[hid] = &incidentState{id: origID, startedAt: origStart, peak: 4, peakClassHist: map[string]int{"script_error": 4}, dominantClass: "script_error"}
	s.failWindow[hid] = fw("script_error", now.Add(-10*time.Minute))

	// Below threshold but already open -> stays open, emits nothing.
	if ev := s.evaluateIncidents(now); len(ev) != 0 {
		t.Fatalf("restored sub-threshold incident must stay open silently; got %+v", ev)
	}
	if s.incident[hid] == nil || s.incident[hid].id != origID {
		t.Fatalf("restored incident must persist with its original id")
	}

	// Window empties -> resolve once, carrying the ORIGINAL id + startedAt.
	ev := s.evaluateIncidents(now.Add(2 * time.Hour))
	if len(ev) != 1 || ev[0].open {
		t.Fatalf("emptied window must resolve the restored incident once; got %+v", ev)
	}
	if ev[0].id != origID {
		t.Fatalf("resolve must carry the original incidentId %q; got %q", origID, ev[0].id)
	}
	if !ev[0].startedAt.Equal(origStart) {
		t.Fatalf("resolve must carry the original startedAt %v; got %v", origStart, ev[0].startedAt)
	}
	if s.incident[hid] != nil {
		t.Fatalf("incident must be cleared after resolve")
	}
}

func poolEvents(evs []incidentEvent) []incidentEvent {
	var out []incidentEvent
	for _, e := range evs {
		if e.pool {
			out = append(out, e)
		}
	}
	return out
}

// TestPoolWideIncident exercises cross-host correlation: >= crossN distinct
// hosts failing within crossWin open ONE pool-wide incident (without opening
// per-host incidents at one fail each), it doesn't re-announce while open, and
// it resolves once with the original id when the window empties.
func TestPoolWideIncident(t *testing.T) {
	s := newPoolState("test", 8080)
	s.incidentN = 3 // high enough that one fail per host won't open a per-host incident
	s.incidentWin = time.Hour
	s.crossN = 3
	s.crossWin = 15 * time.Minute
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	for _, hid := range []string{"hostA", "hostB", "hostC"} {
		s.failWindow[hid] = fw("network_timeout", now.Add(-5*time.Minute))
	}

	// 3 hosts within crossWin, all the SAME class -> one pool-wide incident, no
	// per-host incidents, pinned to that class.
	ev := s.evaluateIncidents(now)
	pool := poolEvents(ev)
	if len(pool) != 1 || !pool[0].open || pool[0].count != 3 {
		t.Fatalf("3 hosts in crossWin must open one pool-wide incident (count 3); got %+v", ev)
	}
	if pool[0].class != "network_timeout" || s.poolIncident.class != "network_timeout" {
		t.Fatalf("pool incident must pin the same class; got event=%q state=%q", pool[0].class, s.poolIncident.class)
	}
	if s.poolIncident == nil {
		t.Fatalf("poolIncident must be set")
	}
	if len(s.incident) != 0 {
		t.Fatalf("per-host incidents must not open at one fail each; got %d", len(s.incident))
	}
	if len(pool[0].hosts) != 3 {
		t.Fatalf("pool open event must carry the 3 affected hosts; got %v", pool[0].hosts)
	}
	poolID := s.poolIncident.id

	// Re-eval while open -> no new pool event, same id.
	if p := poolEvents(s.evaluateIncidents(now.Add(time.Minute))); len(p) != 0 {
		t.Fatalf("re-eval must not emit a new pool event while open; got %+v", p)
	}
	if s.poolIncident == nil || s.poolIncident.id != poolID {
		t.Fatalf("pool incident must persist with the same id")
	}

	// Window empties -> resolve once, original id, state cleared.
	pool = poolEvents(s.evaluateIncidents(now.Add(2 * time.Hour)))
	if len(pool) != 1 || pool[0].open || pool[0].id != poolID {
		t.Fatalf("emptied window must resolve the pool incident once with its original id; got %+v", pool)
	}
	if s.poolIncident != nil {
		t.Fatalf("pool incident must be cleared after resolve")
	}
}

// TestPoolIncidentStickyResolve guards against the asymmetric-hysteresis bug:
// a pool-wide incident opened by a burst must RESOLVE under ordinary single-host
// churn (one host failing within crossWin every poll, so nh never reaches 0) --
// it resolves once nh drops below crossN-1, not only at zero, so the duration
// isn't inflated.
func TestPoolIncidentStickyResolve(t *testing.T) {
	s := newPoolState("test", 8080)
	s.incidentN = 100 // disable per-host incidents for isolation
	s.incidentWin = 4 * time.Hour
	s.crossN = 3
	s.crossWin = 15 * time.Minute
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	for _, h := range []string{"a", "b", "c"} {
		s.failWindow[h] = fw("network_timeout", now)
	}
	if p := poolEvents(s.evaluateIncidents(now)); len(p) != 1 || !p[0].open {
		t.Fatalf("3-host burst must open the pool incident; got %+v", p)
	}

	// Only host 'a' keeps failing the SAME class (every 10m). The pinned class's
	// distinct-host count stays 1 -- never 0 -- so the old `nh == 0` resolve would
	// stick forever; it must resolve once it drops below crossFloor.
	resolved := false
	tcur := now
	for i := 0; i < 12; i++ {
		tcur = tcur.Add(10 * time.Minute)
		s.failWindow["a"] = append(s.failWindow["a"], failRec{t: tcur, class: "network_timeout"})
		ev := poolEvents(s.evaluateIncidents(tcur))
		if len(ev) == 1 && !ev[0].open {
			resolved = true
			if d := tcur.Sub(now); d > 30*time.Minute {
				t.Fatalf("pool incident resolved too late (%v) -- still sticky", d)
			}
			break
		}
	}
	if !resolved {
		t.Fatalf("pool incident must resolve under single-host churn, but stayed open")
	}
	if s.poolIncident != nil {
		t.Fatalf("pool incident must be cleared after resolve")
	}
}

// TestApplyIncidentLines covers the restart restore parser: the latest line per
// host (and the latest pool-scoped line) decides current state, pool and
// per-host lines are not cross-misclassified, and a restored pool incident is
// not re-announced on the next poll.
func TestApplyIncidentLines(t *testing.T) {
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	mk := func(m map[string]any) string { b, _ := json.Marshal(m); return string(b) }
	poolStream := [][2]string{ // newest-first: latest is OPEN
		{"3", mk(map[string]any{"event": "pool_incident_open", "incidentId": "inc-pool-42", "startedAt": "2026-06-10T11:30:00Z", "affectedHostCount": 4, "scope": "pool", "class": "network_timeout"})},
		{"2", mk(map[string]any{"event": "pool_incident_resolved", "incidentId": "inc-pool-1", "startedAt": "2026-06-10T10:00:00Z"})},
	}
	hostA := [][2]string{ // latest is OPEN -> restore
		{"3", mk(map[string]any{"event": "incident_open", "incidentId": "inc-A-9", "hostId": "hostA", "startedAt": "2026-06-10T11:00:00Z", "failCount": 3})},
	}
	hostB := [][2]string{ // latest is RESOLVED -> do not restore
		{"3", mk(map[string]any{"event": "incident_resolved", "incidentId": "inc-B-1", "hostId": "hostB", "startedAt": "2026-06-10T09:00:00Z"})},
		{"2", mk(map[string]any{"event": "incident_open", "incidentId": "inc-B-1", "hostId": "hostB", "startedAt": "2026-06-10T09:00:00Z", "failCount": 3})},
	}
	s := newPoolState("test", 8080)
	if n := s.applyIncidentLines([][][2]string{poolStream, hostA, hostB}, now); n != 2 {
		t.Fatalf("expected 2 restored (pool + hostA); got %d", n)
	}
	if s.poolIncident == nil || s.poolIncident.id != "inc-pool-42" || s.poolIncident.peakHosts != 4 {
		t.Fatalf("pool incident must restore the latest open with id+peakHosts; got %+v", s.poolIncident)
	}
	if !s.poolIncident.startedAt.Equal(time.Date(2026, 6, 10, 11, 30, 0, 0, time.UTC)) {
		t.Fatalf("pool startedAt must come from the open line; got %v", s.poolIncident.startedAt)
	}
	if s.incident["hostA"] == nil || s.incident["hostA"].id != "inc-A-9" {
		t.Fatalf("hostA incident must restore with its original id; got %+v", s.incident["hostA"])
	}
	if s.incident["hostB"] != nil {
		t.Fatalf("hostB's latest line is a resolve -> must NOT restore")
	}

	// Idempotency: a fresh >=crossN burst must NOT re-announce the restored pool incident.
	s.crossN = 3
	s.crossWin = 15 * time.Minute
	s.incidentN = 100
	for _, h := range []string{"x", "y", "z"} {
		s.failWindow[h] = fw("network_timeout", now)
	}
	if p := poolEvents(s.evaluateIncidents(now)); len(p) != 0 {
		t.Fatalf("restored pool incident must not re-announce on the next poll; got %+v", p)
	}
	if s.poolIncident == nil || s.poolIncident.id != "inc-pool-42" {
		t.Fatalf("restored pool incident id must be preserved")
	}
}

// TestPoolWideSameClass is the core of the same-class requirement: distinct hosts
// failing within the cross-host window open a pool-wide incident ONLY when they share
// a failure class. Unrelated classes that merely coincide in time must not correlate.
func TestPoolWideSameClass(t *testing.T) {
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	newS := func() *poolState {
		s := newPoolState("test", 8080)
		s.incidentN = 100 // isolate cross-host from per-host
		s.incidentWin = time.Hour
		s.crossN = 3
		s.crossWin = 15 * time.Minute
		return s
	}

	// 3 hosts, 3 DIFFERENT classes -> NO pool incident (temporal-only would wrongly open).
	s := newS()
	s.failWindow["a"] = fw("script_error", now.Add(-2*time.Minute))
	s.failWindow["b"] = fw("network_timeout", now.Add(-2*time.Minute))
	s.failWindow["c"] = fw("wait_timeout", now.Add(-2*time.Minute))
	if p := poolEvents(s.evaluateIncidents(now)); len(p) != 0 || s.poolIncident != nil {
		t.Fatalf("3 hosts with DIFFERENT classes must NOT open a pool incident; got %+v", p)
	}

	// 2 hosts class A + 2 hosts class B, crossN=3 -> no single class reaches 3 -> none.
	s = newS()
	s.failWindow["a"] = fw("script_error", now.Add(-2*time.Minute))
	s.failWindow["b"] = fw("script_error", now.Add(-2*time.Minute))
	s.failWindow["c"] = fw("network_timeout", now.Add(-2*time.Minute))
	s.failWindow["d"] = fw("network_timeout", now.Add(-2*time.Minute))
	if p := poolEvents(s.evaluateIncidents(now)); len(p) != 0 {
		t.Fatalf("no single class reaching crossN must NOT open a pool incident; got %+v", p)
	}
	// A 3rd host fails script_error -> that class reaches 3 -> opens, pinned to it.
	s.failWindow["e"] = fw("script_error", now.Add(-1*time.Minute))
	p := poolEvents(s.evaluateIncidents(now))
	if len(p) != 1 || !p[0].open || p[0].class != "script_error" || p[0].count != 3 {
		t.Fatalf("3 hosts of one class must open a pool incident pinned to it; got %+v", p)
	}
}

// TestIncidentDominantClass: a per-host incident's dominant class is the argmax of
// its in-window class histogram (ties broken lexically).
func TestIncidentDominantClass(t *testing.T) {
	s := newPoolState("test", 8080)
	s.incidentN = 3
	s.incidentWin = time.Hour
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	s.failWindow["h"] = []failRec{
		{t: now.Add(-9 * time.Minute), class: "wait_timeout"},
		{t: now.Add(-8 * time.Minute), class: "script_error"},
		{t: now.Add(-7 * time.Minute), class: "wait_timeout"},
	}
	ev := s.evaluateIncidents(now)
	if len(ev) != 1 || ev[0].dominantClass != "wait_timeout" {
		t.Fatalf("dominant must be the most-frequent class; got %+v", ev)
	}
	if ev[0].classHist["wait_timeout"] != 2 || ev[0].classHist["script_error"] != 1 {
		t.Fatalf("histogram counts wrong; got %v", ev[0].classHist)
	}
}

// TestClassHistogramHelpers covers the pure histogram/argmax helpers: empty-class
// normalization, the lexical tiebreak, the argmax, and the empty case.
func TestClassHistogramHelpers(t *testing.T) {
	h := classHistogram([]failRec{{class: "b"}, {class: "a"}, {class: ""}})
	if h["b"] != 1 || h["a"] != 1 || h["unknown"] != 1 {
		t.Fatalf("classHistogram miscount (empty class -> unknown); got %v", h)
	}
	if d := dominantClass(map[string]int{"b": 1, "a": 1}); d != "a" {
		t.Fatalf("dominantClass tiebreak must be lexical; got %q", d)
	}
	if d := dominantClass(map[string]int{"x": 1, "y": 3}); d != "y" {
		t.Fatalf("dominantClass must be the argmax; got %q", d)
	}
	if d := dominantClass(map[string]int{}); d != "" {
		t.Fatalf("empty histogram dominant must be empty; got %q", d)
	}
}

// TestApplyIncidentLinesClass: restart restore reads the per-host dominantClass + the
// pool-wide pinned class from the incident feed, defaulting to "unknown" for legacy
// open lines that predate these fields.
func TestApplyIncidentLinesClass(t *testing.T) {
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	mk := func(m map[string]any) string { b, _ := json.Marshal(m); return string(b) }
	poolStream := [][2]string{
		{"1", mk(map[string]any{"event": "pool_incident_open", "incidentId": "inc-pool-7", "startedAt": "2026-06-10T11:30:00Z", "affectedHostCount": 3, "scope": "pool", "class": "network_timeout"})},
	}
	hostA := [][2]string{
		{"1", mk(map[string]any{"event": "incident_open", "incidentId": "inc-A-1", "hostId": "hostA", "startedAt": "2026-06-10T11:00:00Z", "failCount": 3, "dominantClass": "script_error", "classHistogram": map[string]int{"script_error": 3}})},
	}
	hostLegacy := [][2]string{ // legacy open line: no class fields
		{"1", mk(map[string]any{"event": "incident_open", "incidentId": "inc-L-1", "hostId": "hostL", "startedAt": "2026-06-10T11:00:00Z", "failCount": 3})},
	}
	s := newPoolState("test", 8080)
	if n := s.applyIncidentLines([][][2]string{poolStream, hostA, hostLegacy}, now); n != 3 {
		t.Fatalf("expected 3 restored; got %d", n)
	}
	if s.poolIncident == nil || s.poolIncident.class != "network_timeout" {
		t.Fatalf("pool incident must restore its pinned class; got %+v", s.poolIncident)
	}
	if s.incident["hostA"] == nil || s.incident["hostA"].dominantClass != "script_error" {
		t.Fatalf("hostA must restore dominantClass; got %+v", s.incident["hostA"])
	}
	if s.incident["hostL"] == nil || s.incident["hostL"].dominantClass != "unknown" {
		t.Fatalf("legacy line must default dominantClass to unknown; got %+v", s.incident["hostL"])
	}
}

// TestApplyIncidentLinesReconcile: when the live fail window (seeded by the
// cycle-feed rehydrate) is LARGER than the restored open line's snapshot, the
// restored incident's peakClassHist AND dominantClass are recomputed together from
// the live window so they never disagree (a stale dominantClass would misclassify
// the metric/Loki/dashboard on the next poll).
func TestApplyIncidentLinesReconcile(t *testing.T) {
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	mk := func(m map[string]any) string { b, _ := json.Marshal(m); return string(b) }
	s := newPoolState("test", 8080)
	s.incidentWin = time.Hour
	// Live window (as rehydrateFromLoki would have seeded it): 4 fails, zeta-dominated.
	s.failWindow["hostA"] = []failRec{
		{t: now.Add(-9 * time.Minute), class: "zeta"},
		{t: now.Add(-8 * time.Minute), class: "zeta"},
		{t: now.Add(-7 * time.Minute), class: "zeta"},
		{t: now.Add(-6 * time.Minute), class: "alpha"},
	}
	// Restored open line is an older, smaller snapshot dominated by alpha.
	hostA := [][2]string{
		{"1", mk(map[string]any{"event": "incident_open", "incidentId": "inc-A-1", "hostId": "hostA", "startedAt": "2026-06-10T11:00:00Z", "failCount": 2, "dominantClass": "alpha", "classHistogram": map[string]int{"alpha": 2}})},
	}
	if n := s.applyIncidentLines([][][2]string{hostA}, now); n != 1 {
		t.Fatalf("expected 1 restored; got %d", n)
	}
	inc := s.incident["hostA"]
	if inc == nil || inc.peak != 4 {
		t.Fatalf("peak must reconcile to the larger live window (4); got %+v", inc)
	}
	if inc.dominantClass != "zeta" {
		t.Fatalf("dominantClass must be recomputed from the live window (zeta), not the stale snapshot (alpha); got %q", inc.dominantClass)
	}
	if inc.peakClassHist["zeta"] != 3 || inc.peakClassHist["alpha"] != 1 {
		t.Fatalf("peakClassHist must reflect the live window; got %v", inc.peakClassHist)
	}
}

// TestEventNano confirms the Loki entry timestamp comes from the event's own
// RFC3339 timestamp, with a clean fallback to the ingest clock.
func TestEventNano(t *testing.T) {
	fb := time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
	got := eventNano(`{"timestamp":"2026-06-10T00:12:04Z","event":"step_end"}`, fb)
	if want := time.Date(2026, 6, 10, 0, 12, 4, 0, time.UTC).UnixNano(); got != want {
		t.Fatalf("eventNano: want %d got %d", want, got)
	}
	if got := eventNano(`{"event":"x"}`, fb); got != fb.UnixNano() {
		t.Fatalf("eventNano: missing timestamp must fall back to ingest clock")
	}
	if got := eventNano(`not json`, fb); got != fb.UnixNano() {
		t.Fatalf("eventNano: unparseable line must fall back to ingest clock")
	}
}

// TestRedactEventLine confirms forwarded NDJSON events are scrubbed of the
// hostname (literal field and the hostname-bearing cycleFolder) while every other
// field survives, that lines without those keys pass through byte-for-byte, and
// that the redaction is deterministic (so re-forwarding dedups idempotently).
func TestRedactEventLine(t *testing.T) {
	in := `{"cycleNumber":658,"hostname":"Alius202605a","event":"cycle_start","hostId":"4253419c","cycleId":"2026-06-10T15:44:32Z","cycleFolder":"000658.2026-06-10.15-44-31.Alius202605a","runId":"ce338d4c"}`
	out := redactEventLine(in)
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("redacted line must stay valid JSON: %v", err)
	}
	if _, ok := m["hostname"]; ok {
		t.Fatalf("hostname must be removed: %s", out)
	}
	if _, ok := m["cycleFolder"]; ok {
		t.Fatalf("cycleFolder (embeds hostname) must be removed: %s", out)
	}
	for _, k := range []string{"cycleNumber", "event", "hostId", "cycleId", "runId"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("non-hostname field %q must survive: %s", k, out)
		}
	}
	if out2 := redactEventLine(in); out2 != out {
		t.Fatalf("redaction must be deterministic (idempotent dedup): %q != %q", out, out2)
	}
	// A line carrying none of the keys is forwarded unchanged (byte-for-byte).
	clean := `{"event":"step_end","hostId":"4253419c","ok":true}`
	if got := redactEventLine(clean); got != clean {
		t.Fatalf("clean line must pass through unchanged: %q", got)
	}
	// A non-JSON tail fragment is forwarded unchanged.
	if got := redactEventLine(`{"event":"trunc`); got != `{"event":"trunc` {
		t.Fatalf("non-JSON line must pass through unchanged: %q", got)
	}
}

// TestHostViewJSONHostnameFree guards the unauthenticated /api/v1/pool-status
// surface (which serializes []*hostView): even when a host's parsed status
// carries a hostname, it must never be emitted -- hostStatus.Hostname is
// json:"-". A reviewer caught this endpoint leaking the raw hostname; this is the
// regression guard.
func TestHostViewJSONHostnameFree(t *testing.T) {
	hv := &hostView{
		HostId: "4253419c", BaseURL: "http://192.168.7.13:8080", Reachable: true,
		Status: &hostStatus{
			HostId: "4253419c", Host: "host.windows.hyper-v",
			Hostname: "SECRET-HOSTNAME-MUST-NOT-LEAK", CycleId: "2026-06-10T15:44:32Z",
			OverallStatus: "fail",
		},
	}
	// A failure class IS exposed on the public surface (not sensitive); the parsed
	// LastFailure struct is deliberately narrow (class + severity only) so the host's
	// richer lastFailure (errorMessage, vmName, reproCommand) can never ride along.
	hv.Status.LastFailure.FailureClass = "script_error"
	b, err := json.Marshal([]*hostView{hv})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "SECRET-HOSTNAME-MUST-NOT-LEAK") {
		t.Fatalf("pool-status JSON leaked the hostname value: %s", b)
	}
	if strings.Contains(strings.ToLower(string(b)), "hostname") {
		t.Fatalf("pool-status JSON must not carry a hostname key: %s", b)
	}
	if !strings.Contains(string(b), "script_error") {
		t.Fatalf("pool-status JSON should expose the failure class: %s", b)
	}
	for _, leak := range []string{"errorMessage", "vmName", "reproCommand", "relPath", "stepNumber"} {
		if strings.Contains(string(b), leak) {
			t.Fatalf("narrow LastFailure must not expose %q: %s", leak, b)
		}
	}
}

func TestPoolFor(t *testing.T) {
	s := newPoolState("default", 8080)
	s.hosts["42aaa"] = &hostView{HostId: "42aaa", PoolId: "lab"} // advertised pool
	s.hosts["42bbb"] = &hostView{HostId: "42bbb", PoolId: ""}    // unpooled host
	// 42ccc not present at all (never probed)
	cases := []struct {
		host, want string
	}{
		{"42aaa", "lab"},     // advertised poolId wins
		{"42bbb", "default"}, // empty poolId -> flag fallback
		{"42ccc", "default"}, // unknown host -> flag fallback
	}
	for _, c := range cases {
		if got := s.poolFor(c.host); got != c.want {
			t.Fatalf("poolFor(%q) = %q, want %q", c.host, got, c.want)
		}
	}
}

func TestFetchRegistration(t *testing.T) {
	// poolId present, absent (unpooled -> ""), and a non-200 (error) are the three
	// shapes the poll must tolerate without ever wiping a known pool on a miss; plus
	// the gating block (present/full, present/partial -> default-filled, absent -> nil).
	client := &http.Client{}
	serve := func(status int, body string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/runtime/host.registration.json" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			if status != http.StatusOK {
				w.WriteHeader(status)
				return
			}
			_, _ = w.Write([]byte(body))
		}))
	}

	pooled := serve(http.StatusOK, `{"schemaVersion":1,"hostId":"42aaa","poolId":"lab"}`)
	defer pooled.Close()
	if pid, g, err := fetchRegistration(client, pooled.URL); err != nil || pid != "lab" || g != nil {
		t.Fatalf("pooled: got (%q,%v,%v), want (lab,nil,nil)", pid, g, err)
	}

	unpooled := serve(http.StatusOK, `{"schemaVersion":1,"hostId":"42bbb","poolId":null}`)
	defer unpooled.Close()
	if pid, g, err := fetchRegistration(client, unpooled.URL); err != nil || pid != "" || g != nil {
		t.Fatalf("unpooled: got (%q,%v,%v), want ('',nil,nil)", pid, g, err)
	}

	missing := serve(http.StatusNotFound, "")
	defer missing.Close()
	if _, _, err := fetchRegistration(client, missing.URL); err == nil {
		t.Fatalf("missing: expected an error on HTTP 404")
	}

	// Full gating block parses verbatim.
	full := serve(http.StatusOK, `{"poolId":"lab","gating":{"failuresBeforeAlert":5,"successesBeforeRearm":4,"quorum":{"healthyThreshold":0.75,"degradedAfterMinutes":10}}}`)
	defer full.Close()
	if pid, g, err := fetchRegistration(client, full.URL); err != nil || pid != "lab" || g == nil ||
		g.FailuresBeforeAlert != 5 || g.SuccessesBeforeRearm != 4 || g.HealthyThreshold != 0.75 || g.DegradedAfter != 10*time.Minute {
		t.Fatalf("full gating: got (%q,%+v,%v)", pid, g, err)
	}

	// Partial gating block fills the missing knobs from the schema defaults.
	partial := serve(http.StatusOK, `{"poolId":"lab","gating":{"quorum":{"healthyThreshold":0.9}}}`)
	defer partial.Close()
	if _, g, err := fetchRegistration(client, partial.URL); err != nil || g == nil ||
		g.FailuresBeforeAlert != defaultFailuresBeforeAlert || g.SuccessesBeforeRearm != defaultSuccessesBeforeRearm ||
		g.HealthyThreshold != 0.9 || g.DegradedAfter != defaultDegradedAfter {
		t.Fatalf("partial gating: got (%+v,%v)", g, err)
	}
}

// TestEvaluatePoolGate exercises the advisory degraded/alert state machine: the
// at-threshold boundary, the sustained-window degraded latch, the poll-count alert
// hysteresis (fire + re-arm), immediate clear on recovery, and the authored-only
// alert gate (an un-configured pool computes degraded for the gauge but never alerts).
func TestEvaluatePoolGate(t *testing.T) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	pol := gatingPolicy{FailuresBeforeAlert: 2, SuccessesBeforeRearm: 2, HealthyThreshold: 0.5, DegradedAfter: 10 * time.Minute}

	// (a) fraction AT the threshold (0.5) is not "below" -> never degraded/alerts.
	s := newPoolState("default", 8080)
	s.gating["lab"] = pol
	gateHost(s, "42a", "lab", "pass", true) // healthy
	gateHost(s, "42b", "lab", "fail", true) // unhealthy -> frac 0.5
	for i := 0; i < 5; i++ {
		s.evaluatePoolGate(base.Add(time.Duration(i) * time.Hour))
	}
	if s.poolGate["lab"].degraded || s.poolGate["lab"].alertFired {
		t.Fatalf("(a) frac at threshold must not degrade/alert: %+v", s.poolGate["lab"])
	}

	// Below the threshold from here (both members failing -> frac 0).
	s = newPoolState("default", 8080)
	s.gating["lab"] = pol
	gateHost(s, "42a", "lab", "fail", true)
	gateHost(s, "42b", "lab", "fail", true)

	// (b) below but < degradedAfter -> not degraded yet.
	s.evaluatePoolGate(base)                      // belowSince = base
	s.evaluatePoolGate(base.Add(5 * time.Minute)) // 5m < 10m
	if s.poolGate["lab"].degraded {
		t.Fatalf("(b) below for 5m (<10m) must not be degraded")
	}
	// (c) sustained >= window -> degraded; (d) the alert needs 2 consecutive degraded polls.
	s.evaluatePoolGate(base.Add(11 * time.Minute)) // degraded poll #1
	if !s.poolGate["lab"].degraded {
		t.Fatalf("(c) sustained >=10m must be degraded")
	}
	if s.poolGate["lab"].alertFired {
		t.Fatalf("(d) one degraded poll must not fire (needs 2)")
	}
	s.evaluatePoolGate(base.Add(12 * time.Minute)) // degraded poll #2 -> fires
	if !s.poolGate["lab"].alertFired {
		t.Fatalf("(d) alert must fire after 2 consecutive degraded polls")
	}

	// (e)+(f) recovery: heal one host -> frac 0.5 (not below). belowSince resets and
	// degraded clears immediately; the alert re-arms only after 2 non-degraded polls.
	s.hosts["42a"].Status.OverallStatus = "pass"
	s.evaluatePoolGate(base.Add(13 * time.Minute)) // non-degraded poll #1
	if s.poolGate["lab"].degraded {
		t.Fatalf("(f) degraded must clear immediately on recovery")
	}
	if !s.poolGate["lab"].alertFired {
		t.Fatalf("(e) alert must stay fired until 2 non-degraded polls")
	}
	s.evaluatePoolGate(base.Add(14 * time.Minute)) // non-degraded poll #2 -> re-arm
	if s.poolGate["lab"].alertFired {
		t.Fatalf("(e) alert must re-arm after 2 non-degraded polls")
	}

	// (g) a pool with NO authored gating: degraded is computed (for the gauge) using
	// the defaults, but the alert latch never engages.
	s = newPoolState("default", 8080)
	gateHost(s, "42x", "wild", "fail", true)
	gateHost(s, "42y", "wild", "fail", true)
	for i := 0; i <= 6; i++ {
		s.evaluatePoolGate(base.Add(time.Duration(i*10) * time.Minute)) // 0..60m at 10m steps
	}
	g := s.poolGate["wild"]
	if !g.degraded {
		t.Fatalf("(g) unauthored pool should still compute degraded for the gauge")
	}
	if g.authored || g.alertFired {
		t.Fatalf("(g) unauthored pool must never alert: %+v", g)
	}

	// (h) a firing pool whose members all leave the view emits a rearm (so the
	// kind=alert Loki feed closes) and the gate is pruned.
	s = newPoolState("default", 8080)
	s.gating["lab"] = pol
	gateHost(s, "42a", "lab", "fail", true)
	gateHost(s, "42b", "lab", "fail", true)
	s.evaluatePoolGate(base)                       // belowSince = base
	s.evaluatePoolGate(base.Add(11 * time.Minute)) // degraded #1
	s.evaluatePoolGate(base.Add(12 * time.Minute)) // degraded #2 -> fired
	if !s.poolGate["lab"].alertFired {
		t.Fatalf("(h) precondition: alert should be firing")
	}
	delete(s.hosts, "42a")
	delete(s.hosts, "42b")
	ev := s.evaluatePoolGate(base.Add(13 * time.Minute))
	if _, ok := s.poolGate["lab"]; ok {
		t.Fatalf("(h) emptied pool's gate should be pruned")
	}
	gotRearm := false
	for _, e := range ev {
		if e.alert && e.rearm && e.poolLabel == "lab" {
			gotRearm = true
		}
	}
	if !gotRearm {
		t.Fatalf("(h) emptied firing pool must emit a rearm event, got %+v", ev)
	}
}

// captureLoki is a stub Loki push endpoint that records the raw bodies it receives,
// so an ingest test can assert the stream labels + redacted line that were forwarded.
func captureLoki() (*httptest.Server, *[]string, *sync.Mutex) {
	var mu sync.Mutex
	bodies := []string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, string(b))
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	return srv, &bodies, &mu
}

func TestFileReadable(t *testing.T) {
	dir := t.TempDir()
	if fileReadable(filepath.Join(dir, "nope")) {
		t.Fatal("missing file must not be readable")
	}
	empty := filepath.Join(dir, "empty")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if fileReadable(empty) {
		t.Fatal("empty file must not count (TLS/auth gate degrades to off)")
	}
	full := filepath.Join(dir, "full")
	if err := os.WriteFile(full, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !fileReadable(full) {
		t.Fatal("non-empty regular file must be readable")
	}
	if fileReadable(dir) {
		t.Fatal("a directory must not pass as a cert/token file")
	}
}

// TestHandleIngest exercises the push-ingest security gates: disabled-without-token,
// method, bearer, source-IP identity binding, body-hostId forgery rejection, redaction
// parity, the line cap, and a clean accepted push.
func TestHandleIngest(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	newState := func(token string) *poolState {
		s := newPoolState("default", 8080)
		s.authToken = token
		s.httpClient = &http.Client{}
		return s
	}
	addHost := func(s *poolState) { s.hosts[hid] = &hostView{HostId: hid, CurrentIP: "10.0.0.5", PoolId: "lab"} }
	post := func(s *poolState, remoteAddr, auth, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(body))
		req.RemoteAddr = remoteAddr
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		w := httptest.NewRecorder()
		s.handleIngest(w, req)
		return w
	}

	// (a) no token configured -> 503 (never an unauthenticated write route).
	if w := post(newState(""), "10.0.0.5:1", "Bearer x", "{}"); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("(a) no-token want 503, got %d", w.Code)
	}
	// (b) non-POST -> 405 + Allow: POST.
	{
		s := newState("secret")
		addHost(s)
		req := httptest.NewRequest(http.MethodGet, "/ingest", nil)
		req.RemoteAddr = "10.0.0.5:1"
		req.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		s.handleIngest(w, req)
		if w.Code != http.StatusMethodNotAllowed || w.Header().Get("Allow") != "POST" {
			t.Fatalf("(b) want 405+Allow:POST, got %d Allow=%q", w.Code, w.Header().Get("Allow"))
		}
	}
	// (c) missing / wrong bearer -> 401.
	if w := post(newState("secret"), "10.0.0.5:1", "", "{}"); w.Code != http.StatusUnauthorized {
		t.Fatalf("(c1) no-bearer want 401, got %d", w.Code)
	}
	if w := post(newState("secret"), "10.0.0.5:1", "Bearer nope", "{}"); w.Code != http.StatusUnauthorized {
		t.Fatalf("(c2) wrong-bearer want 401, got %d", w.Code)
	}
	// (d) authed but source IP is not a discovered member -> 403.
	{
		s := newState("secret")
		addHost(s)
		if w := post(s, "10.9.9.9:1", "Bearer secret", `{"hostId":"x"}`); w.Code != http.StatusForbidden {
			t.Fatalf("(d) undiscovered IP want 403, got %d", w.Code)
		}
	}
	// (e) body hostId disagrees with the IP-bound identity -> 403 (forgery).
	{
		s := newState("secret")
		addHost(s)
		if w := post(s, "10.0.0.5:1", "Bearer secret", `{"hostId":"42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}`); w.Code != http.StatusForbidden {
			t.Fatalf("(e) forged hostId want 403, got %d", w.Code)
		}
	}
	// (f) valid push -> 202; Loki gets {pool:lab,hostId,src:event} with hostname/cycleFolder redacted.
	{
		loki, bodies, mu := captureLoki()
		defer loki.Close()
		s := newState("secret")
		addHost(s)
		s.lokiURL = loki.URL
		body := `{"hostId":"` + hid + `","event":"step_end","hostname":"SECRET-PC","cycleFolder":"x","timestamp":"2026-01-01T00:00:00Z"}` + "\n"
		if w := post(s, "10.0.0.5:1", "Bearer secret", body); w.Code != http.StatusAccepted {
			t.Fatalf("(f) valid push want 202, got %d", w.Code)
		}
		mu.Lock()
		defer mu.Unlock()
		if len(*bodies) != 1 {
			t.Fatalf("(f) expected 1 loki push, got %d", len(*bodies))
		}
		got := (*bodies)[0]
		if !strings.Contains(got, `"hostId":"`+hid+`"`) || !strings.Contains(got, `"pool":"lab"`) || !strings.Contains(got, `"src":"event"`) {
			t.Fatalf("(f) loki stream labels wrong: %s", got)
		}
		if strings.Contains(got, "SECRET-PC") || strings.Contains(got, "hostname") || strings.Contains(got, "cycleFolder") {
			t.Fatalf("(f) redaction failed (hostname/cycleFolder leaked): %s", got)
		}
	}
	// (g) too many lines -> 413 (capped before any push).
	{
		s := newState("secret")
		addHost(s)
		var sb strings.Builder
		for i := 0; i < maxEventPush+2; i++ {
			sb.WriteString(`{"hostId":"` + hid + `"}` + "\n")
		}
		if w := post(s, "10.0.0.5:1", "Bearer secret", sb.String()); w.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("(g) too many lines want 413, got %d", w.Code)
		}
	}
	// (h) a batch mixing two hostIds -> 403.
	{
		s := newState("secret")
		addHost(s)
		body := `{"hostId":"` + hid + `"}` + "\n" + `{"hostId":"42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}` + "\n"
		if w := post(s, "10.0.0.5:1", "Bearer secret", body); w.Code != http.StatusForbidden {
			t.Fatalf("(h) mixed-hostId batch want 403, got %d", w.Code)
		}
	}
	// (i) no body hostId + a UNIQUE host at the source IP -> bound to it, 202.
	{
		loki, _, _ := captureLoki()
		defer loki.Close()
		s := newState("secret")
		addHost(s)
		s.lokiURL = loki.URL
		if w := post(s, "10.0.0.5:1", "Bearer secret", `{"event":"step_end"}`+"\n"); w.Code != http.StatusAccepted {
			t.Fatalf("(i) hostId-less line + unique IP want 202, got %d", w.Code)
		}
	}
	// (j) no body hostId + AMBIGUOUS source IP (two hosts share it) -> 403.
	{
		s := newState("secret")
		addHost(s)
		s.hosts["42cccccccccccccccccccccccccccccc"] = &hostView{HostId: "42cccccccccccccccccccccccccccccc", CurrentIP: "10.0.0.5", PoolId: "lab"}
		if w := post(s, "10.0.0.5:1", "Bearer secret", `{"event":"x"}`+"\n"); w.Code != http.StatusForbidden {
			t.Fatalf("(j) hostId-less line + ambiguous IP want 403, got %d", w.Code)
		}
	}
}
