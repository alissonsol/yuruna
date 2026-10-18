// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"strconv"
	"testing"
	"time"
)

// liveIncidents runs the collector's own rule over fails the way the poll loop
// feeds it: each fail counted at its poll, the window evaluated at every poll.
func liveIncidents(hostID string, fails []failRec, step time.Duration, until time.Time) []incidentEvent {
	s := newPoolState("lab", 8080)
	var events []incidentEvent
	next := 0
	for now := fails[0].t; !now.After(until); now = now.Add(step) {
		for next < len(fails) && !fails[next].t.After(now) {
			s.failWindow[hostID] = append(s.failWindow[hostID], fails[next])
			next++
		}
		for _, ev := range s.evaluateIncidents(now) {
			if !ev.pool {
				events = append(events, ev)
			}
		}
	}
	return events
}

type incidentSummary struct {
	ID, Kind, Dominant string
	StartedAt, At      time.Time
	Count, Peak        int
	Hist               map[string]int
}

func summarize(events []incidentEvent) []incidentSummary {
	var out []incidentSummary
	for _, ev := range events {
		kind := "resolved"
		if ev.open {
			kind = "open"
		}
		out = append(out, incidentSummary{ID: ev.id, Kind: kind, Dominant: ev.dominantClass, StartedAt: ev.startedAt, At: ev.now, Count: ev.count, Peak: ev.peak, Hist: ev.classHist})
	}
	return out
}

// The replay must raise exactly the incidents the collector would have raised had
// it been watching: same ids, same open and resolve moments, same peaks and class
// breakdowns. Fails sit on the poll grid, as live fails do.
func TestReplayHostIncidentsMatchesTheLiveRule(t *testing.T) {
	const poll = 15 * time.Second
	classes := []string{"network_timeout", "guest_boot", "unknown"}
	for seed := int64(1); seed <= 40; seed++ {
		rng := rand.New(rand.NewSource(seed))
		start := bfAt("2026-09-01T00:00:00Z")
		var fails []failRec
		at := start
		for i := 0; i < 60; i++ {
			// Bursts of close fails separated by quiet stretches of varied length.
			gap := time.Duration(rng.Intn(40)+1) * poll * time.Duration(1+rng.Intn(30))
			if rng.Intn(5) == 0 {
				gap = time.Duration(rng.Intn(6)+1) * time.Hour
			}
			at = at.Add(gap)
			fails = append(fails, failRec{t: at, class: classes[rng.Intn(len(classes))]})
		}
		until := fails[len(fails)-1].t.Add(defaultIncidentWin + poll)
		live := summarize(liveIncidents(bfHostA, append([]failRec(nil), fails...), poll, until))
		replayed := summarize(replayHostIncidents(bfHostA, "lab", append([]failRec(nil), fails...), defaultIncidentN, defaultIncidentWin))
		if !reflect.DeepEqual(live, replayed) {
			t.Fatalf("seed %d: replay diverged from the live rule\nlive:   %+v\nreplay: %+v", seed, live, replayed)
		}
	}
}

func TestReplayHostIncidentsEdgeCases(t *testing.T) {
	base := bfAt("2026-09-01T00:00:00Z")
	f := func(min int, class string) failRec {
		return failRec{t: base.Add(time.Duration(min) * time.Minute), class: class}
	}
	if got := replayHostIncidents(bfHostA, "lab", []failRec{f(0, "a"), f(10, "a")}, 3, 2*time.Hour); len(got) != 0 {
		t.Errorf("two fails open nothing: %+v", got)
	}
	// A fail landing exactly as the window empties keeps the incident open.
	got := replayHostIncidents(bfHostA, "lab", []failRec{f(0, "a"), f(10, "a"), f(20, "b"), f(140, "b")}, 3, 2*time.Hour)
	if len(got) != 2 || !got[0].open || got[1].open || !got[1].now.Equal(base.Add(260*time.Minute)) {
		t.Fatalf("one incident resolving two hours after its last fail: %+v", summarize(got))
	}
	if got[0].id != incidentID(bfHostA, base) || got[1].peak != 3 || got[1].dominantClass != "a" {
		t.Errorf("incident identity or peak wrong: %+v", summarize(got))
	}
	// Out-of-order input is sorted first.
	shuffled := replayHostIncidents(bfHostA, "lab", []failRec{f(20, "b"), f(0, "a"), f(10, "a")}, 3, 2*time.Hour)
	if len(shuffled) != 2 || shuffled[0].id != incidentID(bfHostA, base) {
		t.Errorf("unsorted fails mishandled: %+v", summarize(shuffled))
	}
}

func TestFailsFromTransitionsTakesOneFailPerCycle(t *testing.T) {
	at := bfAt("2026-09-01T00:00:00Z")
	entries := []lokiEntry{
		{At: at, Line: `{"cycleStartUtc":"c1","overallStatus":"fail","failureClass":"guest_boot"}`},
		{At: at.Add(time.Minute), Line: `{"cycleStartUtc":"c1","overallStatus":"fail","failureClass":"guest_boot"}`},
		{At: at.Add(2 * time.Minute), Line: `{"cycleStartUtc":"c2","overallStatus":"pass"}`},
		{At: at.Add(3 * time.Minute), Line: `{"cycleStartUtc":"c3","overallStatus":"fail"}`},
		{At: at.Add(4 * time.Minute), Line: `not json`},
	}
	got := failsFromTransitions(entries)
	want := map[string]failRec{"c1": {t: at, class: "guest_boot"}, "c3": {t: at.Add(3 * time.Minute), class: "unknown"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v want %+v", got, want)
	}
}

// A cycle this job wrote counts as a fail before Loki answers for its line, and
// a cycle Loki answers for counts once, at the time the collector counted it.
func TestMergeFailsAddsWhatLokiCannotAnswerForYet(t *testing.T) {
	at := bfAt("2026-09-01T00:00:00Z")
	fromLoki := map[string]failRec{cycleKey("2026-09-01T00:00:00Z"): {t: at.Add(40 * time.Minute), class: "guest_boot"}}
	outcomes := map[string]cycleOutcome{
		"a": {CycleStartUtc: "2026-09-01T00:00:00Z", End: at.Add(39 * time.Minute), Status: "fail", FailureClass: "other"},
		"b": {CycleStartUtc: "2026-09-01T01:00:00Z", End: at.Add(100 * time.Minute), Status: "fail"},
		"c": {CycleStartUtc: "2026-09-01T02:00:00Z", End: at.Add(160 * time.Minute), Status: "pass"},
		"d": {CycleStartUtc: "2026-09-01T03:00:00Z", End: at.Add(220 * time.Minute), Status: "fail", FailureClass: "late"},
	}
	got := mergeFails(fromLoki, outcomes, at.Add(200*time.Minute))
	want := []failRec{{t: at.Add(40 * time.Minute), class: "guest_boot"}, {t: at.Add(100 * time.Minute), class: "unknown"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v want %+v", got, want)
	}
}

// A replayed incident line is the live line, in a stream of its own.
func TestIncidentPayloadIsTheLiveLineInItsOwnStream(t *testing.T) {
	ev := incidentEvent{open: true, hostId: bfHostA, id: "inc-42a1a1a1-1", count: 3, startedAt: bfAt("2026-09-01T00:00:00Z"), now: bfAt("2026-09-01T00:20:00Z"),
		classHist: map[string]int{"guest_boot": 3}, dominantClass: "guest_boot", poolLabel: "red"}
	liveStream, liveLine := incidentStreamLine("red", ev)
	p := incidentPayload(ev)
	st := p["streams"].([]map[string]any)[0]
	labels := st["stream"].(map[string]string)
	v := st["values"].([][]string)[0]
	if labels["incidentId"] != ev.id || labels["hostId"] != bfHostA || labels["src"] != "incident" || labels["pool"] != "red" || len(labels) != len(liveStream)+1 {
		t.Errorf("labels: %v (live %v)", labels, liveStream)
	}
	if v[1] != string(liveLine) || v[0] != strconv.FormatInt(ev.now.UnixNano(), 10) {
		t.Errorf("line differs from the live one: %s vs %s", v[1], liveLine)
	}
	var body map[string]any
	if err := json.Unmarshal(liveLine, &body); err != nil || body["event"] != "incident_open" || body["incidentId"] != ev.id {
		t.Errorf("live line shape: %s", liveLine)
	}
}

// A host can now own several incident streams. The newest line across all of
// them decides whether the host is in an incident after a restart, whatever order
// Loki lists the streams in.
func TestApplyIncidentLinesDecidesAcrossStreamsByTime(t *testing.T) {
	now := bfAt("2026-10-02T12:00:00Z")
	mk := func(m map[string]any) string { b, _ := json.Marshal(m); return string(b) }
	ns := func(t time.Time) string { return fmt.Sprint(t.UnixNano()) }
	replayed := [][2]string{
		{ns(now.Add(-30 * 24 * time.Hour)), mk(map[string]any{"event": "incident_resolved", "incidentId": "inc-old", "hostId": bfHostA, "startedAt": "2026-09-01T00:00:00Z"})},
		{ns(now.Add(-31 * 24 * time.Hour)), mk(map[string]any{"event": "incident_open", "incidentId": "inc-old", "hostId": bfHostA, "startedAt": "2026-09-01T00:00:00Z", "failCount": 3})},
	}
	live := [][2]string{
		{ns(now.Add(-10 * time.Minute)), mk(map[string]any{"event": "incident_open", "incidentId": "inc-live", "hostId": bfHostA, "startedAt": "2026-10-02T11:40:00Z", "failCount": 3})},
	}
	for _, order := range [][][][2]string{{replayed, live}, {live, replayed}} {
		s := newPoolState("lab", 8080)
		if n := s.applyIncidentLines(order, now); n != 1 || s.incident[bfHostA] == nil || s.incident[bfHostA].id != "inc-live" {
			t.Fatalf("the open live incident must be restored whatever the stream order: n=%d %+v", n, s.incident[bfHostA])
		}
	}
	s := newPoolState("lab", 8080)
	if n := s.applyIncidentLines([][][2]string{replayed}, now); n != 0 || s.incident[bfHostA] != nil {
		t.Errorf("a host whose newest line is a resolve is not in an incident: %d", n)
	}
}

// classHistogram and dominantClass are shared with the live rule; the replay
// must not depend on map order for its headline class.
func TestReplayDominantClassIsDeterministic(t *testing.T) {
	base := bfAt("2026-09-01T00:00:00Z")
	var fails []failRec
	for i, c := range []string{"b", "a", "b", "a"} {
		fails = append(fails, failRec{t: base.Add(time.Duration(i) * time.Minute), class: c})
	}
	first := replayHostIncidents(bfHostA, "lab", fails, 3, time.Hour)
	for i := 0; i < 20; i++ {
		again := replayHostIncidents(bfHostA, "lab", append([]failRec(nil), fails...), 3, time.Hour)
		if !reflect.DeepEqual(summarize(first), summarize(again)) {
			t.Fatal("replay is not deterministic")
		}
	}
	keys := make([]string, 0)
	for k := range first[1].classHist {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if first[1].dominantClass != "a" || !reflect.DeepEqual(keys, []string{"a", "b"}) {
		t.Errorf("tie must break lexically: %+v", summarize(first))
	}
}
