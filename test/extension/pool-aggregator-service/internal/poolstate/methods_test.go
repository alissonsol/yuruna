// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42a6f2d8-5b3e-4c91-8e7a-3d1c9f4b6e25

package poolstate

import (
	"errors"
	"testing"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
)

// A panic inside Do leaves the lock released: the next Do runs instead of
// waiting forever, which a handler panic that net/http recovers would otherwise
// cause.
func TestDoReleasesTheLockAfterAPanic(t *testing.T) {
	st := New()
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("the panic did not propagate")
			}
		}()
		st.Do(func(*View) { panic("handler fault") })
	}()
	done := make(chan struct{})
	go func() {
		st.Do(func(*View) {})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Do is still locked after a panic")
	}
}

// A retired identity never regains a row, a stub never replaces a record, and
// a host leaves the view with the state that belongs to it: the reaper's drop
// takes the footprint, a forget takes everything, a retire moves the fails.
func TestHostRecordsKeepTheirInvariants(t *testing.T) {
	v := New().view
	v.SetAliases(map[string]string{"42old": "42new"})
	if v.EnsureHost("42old") != nil || v.SeedHostStub("42old", "192.0.2.1", "http://192.0.2.1:8080", t0) || v.RelocateHost("42old", "192.0.2.1", "http://192.0.2.1:8080", t0) {
		t.Fatal("a retired identity regained a row")
	}
	if _, ok := v.Hosts["42old"]; ok {
		t.Fatal("a refused write still added a row")
	}
	hv := v.EnsureHost("42a")
	if hv == nil || hv.HostId != "42a" || v.EnsureHost("42a") != hv {
		t.Fatal("EnsureHost did not add one record and return it again")
	}
	hv.Reachable, hv.CurrentIP = true, "192.0.2.5"
	if v.SeedHostStub("42a", "192.0.2.9", "http://192.0.2.9:8080", t0) || !v.Hosts["42a"].Reachable || v.Hosts["42a"].CurrentIP != "192.0.2.5" {
		t.Fatal("a stub replaced a live record")
	}
	if !v.SeedHostStub("42b", "192.0.2.6", "http://192.0.2.6:8080", t0) || v.Hosts["42b"].Reachable || v.Hosts["42b"].LastSeenUnixMs != t0.UnixMilli() {
		t.Fatalf("stub = %+v", v.Hosts["42b"])
	}
	if v.SeedHostStub("42c", "", "http://", t0) {
		t.Fatal("a stub without an address was seeded")
	}
	v.Hosts["42b"].LastError = "refused"
	later := t0.Add(time.Minute)
	if !v.RelocateHost("42b", "192.0.2.7", "http://192.0.2.7:8080", later) || v.Hosts["42b"].CurrentIP != "192.0.2.7" || v.Hosts["42b"].LastError != "" || v.Hosts["42b"].LastSeenUnixMs != later.UnixMilli() {
		t.Fatalf("relocated = %+v", v.Hosts["42b"])
	}
	if !v.RelocateHost("42d", "192.0.2.8", "http://192.0.2.8:8080", t0) || v.Hosts["42d"] == nil || v.Hosts["42d"].Reachable {
		t.Fatal("relocating an unknown host did not seed a stub")
	}

	v.SetFootprint("42a", AddressFootprintView{Verdict: "stable"})
	v.DropHost("42a")
	if _, ok := v.Hosts["42a"]; ok {
		t.Fatal("DropHost kept the record")
	}
	if _, ok := v.Footprint("42a"); ok {
		t.Fatal("DropHost kept the footprint")
	}

	v.EnsureHost("42a")
	v.SetFootprint("42a", AddressFootprintView{Verdict: "stable"})
	v.RecordFail("42a", incident.FailRec{At: t0, Class: "script_error"})
	v.Incident["42a"] = &incident.HostIncident{ID: "inc"}
	v.ObserveCycle(CycleKey("42a", "c1"), "pass", t0)
	v.CountTerminal(CycleKey("42a", "c1"), "42a", true)
	v.RecordAnnounce("42a", "stash-service", "http://192.0.2.5", "192.0.2.5", t0, 10)
	v.RecordExtensionProbe(AnnounceKey("42a", "stash-service"), "http://192.0.2.5", nil, t0)
	if !v.ForgetHost("42a") || v.ForgetHost("42a") {
		t.Fatal("ForgetHost did not report the record's presence once")
	}
	pass, _ := v.CycleTotals()
	if _, ok := v.Hosts["42a"]; ok || len(v.FailWindow["42a"]) != 0 || v.Incident["42a"] != nil || pass["42a"] != 0 ||
		v.Announce[AnnounceKey("42a", "stash-service")] != nil || v.ExtHealth[AnnounceKey("42a", "stash-service")] != nil {
		t.Fatal("ForgetHost left a trace of the host")
	}
	if _, ok := v.Footprint("42a"); ok {
		t.Fatal("ForgetHost kept the footprint")
	}

	v.EnsureHost("42x")
	v.EnsureHost("42y")
	v.RecordFail("42x", incident.FailRec{At: t0, Class: "a"})
	v.RecordFail("42x", incident.FailRec{At: t0.Add(2 * time.Minute), Class: "a"})
	v.RecordFail("42y", incident.FailRec{At: t0.Add(time.Minute), Class: "b"})
	v.Incident["42x"] = &incident.HostIncident{ID: "inc"}
	v.RecordAnnounce("42x", "stash-service", "http://192.0.2.5", "192.0.2.5", t0, 10)
	v.RetireHost("42x", "42y")
	if _, ok := v.Hosts["42x"]; ok || v.Incident["42x"] != nil || len(v.FailWindow["42x"]) != 0 || v.Announce[AnnounceKey("42x", "stash-service")] != nil {
		t.Fatal("RetireHost left the old identity's records")
	}
	merged := v.FailWindow["42y"]
	if len(merged) != 3 || merged[0].Class != "a" || merged[1].Class != "b" || merged[2].Class != "a" {
		t.Fatalf("merged window = %+v", merged)
	}
	if v.PoolLabel("42y", "default") != "default" {
		t.Fatal("PoolLabel did not fall back")
	}
	v.Hosts["42y"].PoolId = "lab"
	if v.PoolLabel("42y", "default") != "lab" || v.PoolLabel("42zz", "default") != "default" {
		t.Fatal("PoolLabel did not read the advertised pool")
	}
}

// Fails recorded newest first (a Loki rehydrate) end up in the same order as
// fails recorded as they happen.
func TestRecordFailKeepsTheWindowAscending(t *testing.T) {
	v := New().view
	for _, m := range []int{30, 10, 20, 40} {
		v.RecordFail("42a", incident.FailRec{At: t0.Add(time.Duration(m) * time.Minute)})
	}
	fw := v.FailWindow["42a"]
	for i := 1; i < len(fw); i++ {
		if fw[i].At.Before(fw[i-1].At) {
			t.Fatalf("window out of order: %v", fw)
		}
	}
	if len(fw) != 4 || !fw[0].At.Equal(t0.Add(10*time.Minute)) || !fw[3].At.Equal(t0.Add(40*time.Minute)) {
		t.Fatalf("window = %v", fw)
	}
}

// A restored incident agrees with the live window when the window already
// holds more fails than the recorded peak; a restored alert latch is a firing,
// authored gate with its original id; the gate never counts a host in an
// incident healthy; an emptied window resolves its incident.
func TestIncidentRestoresAgreeWithTheLiveWindow(t *testing.T) {
	v := New().view
	v.RecordFail("42a", incident.FailRec{At: t0, Class: "script_error"})
	v.RecordFail("42a", incident.FailRec{At: t0.Add(time.Minute), Class: "network_timeout"})
	v.RecordFail("42a", incident.FailRec{At: t0.Add(2 * time.Minute), Class: "network_timeout"})
	v.RestoreIncident("42a", "inc-1", t0, 1, map[string]int{"script_error": 1}, "script_error")
	inc := v.Incident["42a"]
	if inc == nil || inc.ID != "inc-1" || inc.Peak != 3 || inc.DominantClass != "network_timeout" || inc.PeakClassHist["network_timeout"] != 2 {
		t.Fatalf("restored = %+v", inc)
	}
	v.RestoreIncident("42b", "inc-2", t0, 2, nil, "")
	if inc := v.Incident["42b"]; inc == nil || inc.Peak != 2 || inc.DominantClass != "unknown" || inc.PeakClassHist == nil {
		t.Fatalf("legacy restore = %+v", inc)
	}
	v.RestorePoolIncident("inc-pool", t0, 3, "")
	if v.PoolIncident == nil || v.PoolIncident.Class != "unknown" || v.PoolIncident.PeakHosts != 3 {
		t.Fatalf("pool restore = %+v", v.PoolIncident)
	}
	v.RestoreAlert("lab", "alert-1", t0)
	gate := v.PoolGate["lab"]
	if gate == nil || !gate.Authored || !gate.AlertFired || gate.AlertID != "alert-1" || !gate.AlertStartedAt.Equal(t0) {
		t.Fatalf("latch = %+v", gate)
	}
	v.SetGating("lab", incident.GatingPolicy{HealthyThreshold: 0.5, DegradedAfter: time.Hour, FailuresBeforeAlert: 3, SuccessesBeforeRearm: 2})
	v.EvaluateGate([]incident.Member{{HostID: "42a", Pool: "lab", Healthy: true}, {HostID: "42b", Pool: "lab", Healthy: true}}, t0)
	if gate := v.PoolGate["lab"]; gate.LastTotal != 2 || gate.LastHealthy != 0 {
		t.Fatalf("hosts in an incident were counted healthy: %+v", gate)
	}
	events := v.EvaluateIncidents(incident.Rules{HostN: 3, HostWindow: time.Hour, CrossN: 3, CrossWindow: time.Hour, PoolLabel: "lab"},
		func(string) string { return "lab" }, t0.Add(2*time.Hour))
	if len(events) == 0 || v.Incident["42a"] != nil || len(v.FailWindow["42a"]) != 0 {
		t.Fatalf("an emptied window did not resolve its incident: events=%d incident=%+v", len(events), v.Incident["42a"])
	}
}

// An announce belongs to its source: a full map refuses a new entry but
// refreshes a known one, a goodbye from elsewhere is ignored, an entry restored
// without a source accepts any goodbye, and the TTL reaps what stopped
// refreshing. A verdict belongs to an address: a new address starts over.
func TestAnnouncesBelongToTheirSource(t *testing.T) {
	v := New().view
	if !v.RecordAnnounce("42a", "stash-service", "http://192.0.2.5", "192.0.2.5", t0, 1) {
		t.Fatal("the first announce was refused")
	}
	if v.RecordAnnounce("42b", "stash-service", "http://192.0.2.6", "192.0.2.6", t0, 1) {
		t.Fatal("a full map took a new entry")
	}
	if !v.RecordAnnounce("42a", "stash-service", "http://192.0.2.7", "192.0.2.7", t0.Add(time.Minute), 1) {
		t.Fatal("a full map refused to refresh a known entry")
	}
	key := AnnounceKey("42a", "stash-service")
	if av := v.Announce[key]; av.Target != "http://192.0.2.7" || av.SourceIP != "192.0.2.7" || av.LastSeenUnixMs != t0.Add(time.Minute).UnixMilli() {
		t.Fatalf("refreshed = %+v", av)
	}
	if removed, ignored := v.Goodbye("42a", "stash-service", "192.0.2.9"); removed || !ignored || v.Announce[key] == nil {
		t.Fatal("a goodbye from another source removed the entry")
	}
	if removed, ignored := v.Goodbye("42a", "stash-service", "192.0.2.7"); !removed || ignored || v.Announce[key] != nil {
		t.Fatal("the owner's goodbye was refused")
	}
	if removed, ignored := v.Goodbye("42a", "stash-service", "192.0.2.7"); removed || ignored {
		t.Fatal("a goodbye for an absent entry reported something")
	}
	if !v.RestoreAnnounce("42a", "stash-service", "http://192.0.2.5", t0, 2) || v.RestoreAnnounce("42a", "stash-service", "http://192.0.2.5", t0, 2) {
		t.Fatal("a restore did not add exactly once")
	}
	if av := v.Announce[key]; av.SourceIP != "" || av.LastSeenUnixMs != t0.UnixMilli() {
		t.Fatalf("restored = %+v", av)
	}
	if removed, _ := v.Goodbye("42a", "stash-service", "198.51.100.1"); !removed {
		t.Fatal("an entry restored without a source refused a goodbye")
	}
	v.RestoreAnnounce("42b", "stash-service", "", t0, 2)
	v.RestoreAnnounce("42c", "stash-service", "", t0, 2)
	if len(v.Announce) != 2 {
		t.Fatalf("restores past the cap: %d", len(v.Announce))
	}
	v.RecordAnnounce("42b", "stash-service", "", "192.0.2.6", t0.Add(20*time.Minute), 2)
	v.ReapAnnounces(t0.Add(30*time.Minute), 15*time.Minute)
	if v.Announce[AnnounceKey("42b", "stash-service")] == nil || v.Announce[AnnounceKey("42c", "stash-service")] != nil {
		t.Fatal("the reap did not follow the last refresh")
	}

	v.RecordExtensionProbe(key, "http://192.0.2.5", nil, t0)
	v.RecordExtensionProbe(key, "http://192.0.2.5", errors.New("refused"), t0.Add(time.Minute))
	h := v.ExtHealth[key]
	if !h.Confirmed || h.FirstFailUnixMs != t0.Add(time.Minute).UnixMilli() || h.LastError != "refused" || h.LastOkUnixMs != t0.UnixMilli() {
		t.Fatalf("verdict = %+v", h)
	}
	v.RecordExtensionProbe(key, "http://192.0.2.5", errors.New("timeout"), t0.Add(2*time.Minute))
	if h.FirstFailUnixMs != t0.Add(time.Minute).UnixMilli() || h.LastError != "timeout" {
		t.Fatalf("a later failure restarted the streak: %+v", h)
	}
	h.RefusedLogged = true
	v.RecordExtensionProbe(key, "http://192.0.2.8", errors.New("refused"), t0.Add(3*time.Minute))
	if n := v.ExtHealth[key]; n == h || n.Confirmed || n.RefusedLogged || n.Target != "http://192.0.2.8" {
		t.Fatalf("a new address inherited the old verdict: %+v", n)
	}
	v.RecordExtensionProbe(key, "http://192.0.2.8", nil, t0.Add(4*time.Minute))
	if n := v.ExtHealth[key]; !n.Confirmed || n.FirstFailUnixMs != 0 || n.LastError != "" {
		t.Fatalf("a success did not end the streak: %+v", n)
	}
	v.RecordExtensionProbe(AnnounceKey("42z", "stash-service"), "http://192.0.2.9", nil, t0)
	v.PruneExtensionVerdicts(map[string]bool{key: true})
	if v.ExtHealth[key] == nil || v.ExtHealth[AnnounceKey("42z", "stash-service")] != nil {
		t.Fatal("the prune did not follow the live set")
	}
}

// Recording ring cycles is idempotent and bounded: a host keeps its newest
// cycles at a revision, the store keeps the revisions whose newest cycle is
// newest, and loaded facts are trimmed the same way.
func TestRingFactsAreBounded(t *testing.T) {
	v := New().view
	limits := RingLimits{CyclesPerHost: 2, Revisions: 2}
	rows := []RingRow{{"2026-10-01T08:00:00Z", "r1", true}, {"2026-10-01T09:00:00Z", "r1", false}}
	if !v.RecordRingCycles("42a", rows, limits) || v.RecordRingCycles("42a", rows, limits) {
		t.Fatal("recording was not idempotent")
	}
	if !v.RecordRingCycles("42a", []RingRow{{"2026-10-01T10:00:00Z", "r1", true}}, limits) {
		t.Fatal("a new cycle was not recorded")
	}
	if cycles := v.Ring["r1"]["42a"]; len(cycles) != 2 || cycles["2026-10-01T08:00:00Z"] || !cycles["2026-10-01T10:00:00Z"] {
		t.Fatalf("cycles = %v", cycles)
	}
	v.RecordRingCycles("42a", []RingRow{{"2026-10-02T08:00:00Z", "r2", true}}, limits)
	v.RecordRingCycles("42a", []RingRow{{"2026-10-03T08:00:00Z", "r3", true}}, limits)
	if _, kept := v.Ring["r1"]; kept || len(v.Ring) != 2 {
		t.Fatalf("revisions = %v", v.Ring)
	}
	if v.RecordRingCycles("42a", nil, limits) {
		t.Fatal("no rows recorded something")
	}
	loaded := RingFacts{
		"r1": {"42a": {"2026-10-01T08:00:00Z": true, "2026-10-01T09:00:00Z": true, "2026-10-01T10:00:00Z": true}},
		"r2": {"42a": {"2026-10-02T08:00:00Z": true}},
		"r3": {"42a": {"2026-10-03T08:00:00Z": true}},
	}
	v.SetRingFacts(loaded, limits)
	if _, kept := v.Ring["r1"]; kept || len(v.Ring) != 2 || len(v.Ring["r2"]["42a"]) != 1 {
		t.Fatalf("loaded facts were not trimmed: %v", v.Ring)
	}
	v.SetRingFacts(RingFacts{"r1": {"42a": {"2026-10-01T08:00:00Z": true, "2026-10-01T09:00:00Z": true, "2026-10-01T10:00:00Z": true}}}, limits)
	if cycles := v.Ring["r1"]["42a"]; len(cycles) != 2 || cycles["2026-10-01T08:00:00Z"] {
		t.Fatalf("loaded cycles were not trimmed to the newest: %v", cycles)
	}
}

// The two spellings of one hostId round-trip, and anything else passes
// through untouched.
func TestHostIDSpellings(t *testing.T) {
	plain := "42aabbccddeeff00112233445566778899"[:32]
	dashed := DashedHostID(plain)
	if dashed != plain[0:8]+"-"+plain[8:12]+"-"+plain[12:16]+"-"+plain[16:20]+"-"+plain[20:32] || NormalizeHostID(dashed) != plain {
		t.Fatalf("dashed = %q, normalized = %q", dashed, NormalizeHostID(dashed))
	}
	if DashedHostID("stash-vm-1") != "stash-vm-1" || NormalizeHostID("stash-vm-1") != "stash-vm-1" || NormalizeHostID(plain) != plain {
		t.Fatal("an opaque id was rewritten")
	}
}
