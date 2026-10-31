// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42e5db01-f8eb-4942-b52c-9be31c7e392f

package poolstate

import (
	"strconv"
	"sync"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)

// Do serializes its callers: concurrent increments through it lose none, which
// is what the race detector and the count both check.
func TestDoSerializesCallers(t *testing.T) {
	st := New()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			st.Do(func(v *View) { v.CountTerminal(CycleKey("42a", strconv.Itoa(i)), "42a", true) })
		}()
	}
	wg.Wait()
	var pass int64
	st.Do(func(v *View) { p, _ := v.CycleTotals(); pass = p["42a"] })
	if pass != 50 {
		t.Fatalf("pass = %d, want 50", pass)
	}
}

// A changed status is reported as a change with what it replaced, an unchanged
// one is not, and a revert restores the previous status only while the
// reverted one is still current.
func TestObserveAndRevertCycle(t *testing.T) {
	v := New().view
	key := CycleKey("42a", "c1")
	if prev, known, changed := v.ObserveCycle(key, "running", t0); prev != "" || known || !changed {
		t.Fatalf("first observation = %q %v %v", prev, known, changed)
	}
	if _, _, changed := v.ObserveCycle(key, "running", t0.Add(time.Minute)); changed {
		t.Fatal("an unchanged status reported a change")
	}
	prev, known, changed := v.ObserveCycle(key, "pass", t0.Add(2*time.Minute))
	if prev != "running" || !known || !changed {
		t.Fatalf("transition = %q %v %v", prev, known, changed)
	}
	v.RevertCycle(key, "pass", prev, known)
	if rec, _ := v.Cycle(key); rec.Status != "running" || !rec.ObservedAt.Equal(t0.Add(2*time.Minute)) {
		t.Fatalf("after revert: %+v", rec)
	}
	v.ObserveCycle(key, "fail", t0.Add(3*time.Minute))
	v.RevertCycle(key, "pass", "running", true)
	if rec, _ := v.Cycle(key); rec.Status != "fail" {
		t.Fatalf("a stale revert replaced the current status: %+v", rec)
	}
	other := CycleKey("42a", "c2")
	v.ObserveCycle(other, "running", t0)
	v.RevertCycle(other, "running", "", false)
	if _, ok := v.Cycle(other); !ok {
		t.Fatal("a revert to unseen dropped the observation time")
	}
	if rec, _ := v.Cycle(other); rec.Status != "" {
		t.Fatalf("a revert to unseen kept the status: %+v", rec)
	}
}

// A terminal cycle counts once; the dedup records expire while the counters
// stay; forgetting a host drops both, and only that host's.
func TestCycleCountersAndExpiry(t *testing.T) {
	v := New().view
	k1, k2, k3 := CycleKey("42a", "c1"), CycleKey("42a", "c2"), CycleKey("42b", "c1")
	v.ObserveCycle(k1, "pass", t0)
	if !v.CountTerminal(k1, "42a", true) || v.CountTerminal(k1, "42a", true) {
		t.Fatal("a terminal cycle was not counted exactly once")
	}
	v.ObserveCycle(k2, "fail", t0.Add(time.Hour))
	v.CountTerminal(k2, "42a", false)
	v.ObserveCycle(k3, "pass", t0.Add(time.Hour))
	v.CountTerminal(k3, "42b", true)

	v.ReapCycles(t0.Add(90*time.Minute), time.Hour)
	if _, ok := v.Cycle(k1); ok {
		t.Fatal("an expired dedup record survived the reap")
	}
	if rec, ok := v.Cycle(k2); !ok || !rec.Counted || rec.Status != "fail" {
		t.Fatalf("a current dedup record was reaped: %+v %v", rec, ok)
	}
	if pass, fail := v.CycleTotals(); pass["42a"] != 1 || fail["42a"] != 1 || pass["42b"] != 1 {
		t.Fatalf("the reap changed the counters: %v %v", pass, fail)
	}

	v.ForgetCycles("42a")
	pass, fail := v.CycleTotals()
	if _, ok := pass["42a"]; ok {
		t.Fatal("forgotten host kept its pass counter")
	}
	if _, ok := fail["42a"]; ok {
		t.Fatal("forgotten host kept its fail counter")
	}
	if _, ok := v.Cycle(k2); ok {
		t.Fatal("forgotten host kept a dedup record")
	}
	if pass["42b"] != 1 || v.CycleCount() != 1 {
		t.Fatalf("forgetting one host touched another: %v count=%d", pass, v.CycleCount())
	}
	pass["42b"] = 99
	if p, _ := v.CycleTotals(); p["42b"] != 1 {
		t.Fatal("CycleTotals handed out the live counters")
	}
}

// The scan counts the union of proxy clients and host addresses, so an address
// in both is counted once, and the hosts half is reported on its own.
func TestRecordAddressScanCountsTheUnion(t *testing.T) {
	v := New().view
	if !v.AddressScanDue(t0, time.Hour) {
		t.Fatal("a scan that never ran is not due")
	}
	v.Hosts["42a"] = &HostView{HostId: "42a", CurrentIP: "192.0.2.1"}
	v.Hosts["42b"] = &HostView{HostId: "42b", CurrentIP: "192.0.2.9"}
	v.Hosts["42c"] = &HostView{HostId: "42c"}
	v.RecordAddressScan(map[string]bool{"192.0.2.1": true, "192.0.2.2": true}, true, t0)
	got := v.AddressCounts()
	want := AddressCounts{Distinct: 2, Complete: true, InUse: 3, InUseHosts: 2, ScannedAt: t0}
	if got != want {
		t.Fatalf("counts = %+v, want %+v", got, want)
	}
	if v.AddressScanDue(t0.Add(59*time.Minute), time.Hour) || !v.AddressScanDue(t0.Add(time.Hour), time.Hour) {
		t.Fatal("the scan interval is not honored")
	}
}

// Rotation keeps the newest codes; a redemption matches any kept code,
// records a miss against its bucket, throttles at the limit without comparing,
// and counts every outcome.
func TestLabCodeRotationAndRedemption(t *testing.T) {
	v := New().view
	for _, c := range []string{"aaaaaa", "bbbbbb", "cccccc", "dddddd"} {
		v.RotateLabCode(c, 3, time.Time{})
	}
	if codes := v.LabCodes(); len(codes) != 3 || codes[0] != "dddddd" || codes[2] != "bbbbbb" {
		t.Fatalf("codes = %v", codes)
	}
	cut := t0.Add(-10 * time.Minute)
	if a := v.RedeemLabCode("10.0.0.7", "bbbbbb", t0, cut, 2, 10); !a.Matched || a.Outcome != "ok" {
		t.Fatalf("a kept code did not redeem: %+v", a)
	}
	for i := 0; i < 2; i++ {
		if a := v.RedeemLabCode("10.0.0.7", "zzzzzz", t0, cut, 2, 10); a.Matched || a.Throttled || a.Outcome != "refused" || a.Recent != i {
			t.Fatalf("miss %d = %+v", i, a)
		}
	}
	if a := v.RedeemLabCode("10.0.0.7", "dddddd", t0, cut, 2, 10); !a.Throttled || a.Matched || a.Outcome != "throttled" {
		t.Fatalf("a throttled bucket compared its code: %+v", a)
	}
	if n := len(v.LabFailures("10.0.0.7")); n != 2 {
		t.Fatalf("a throttled attempt was recorded as a failure: %d", n)
	}
	if v.LabExchangeCount("ok") != 1 || v.LabExchangeCount("refused") != 2 || v.LabExchangeCount("throttled") != 1 {
		t.Fatal("the outcomes were not counted")
	}
	v.RotateLabCode("eeeeee", 3, t0)
	if v.LabFailures("10.0.0.7") != nil || v.LabFailureBuckets() != 0 {
		t.Fatal("rotation kept failures at or before its cut")
	}
}

// A full throttle map refuses new buckets rather than growing, after pruning
// the expired ones.
func TestLabFailureBucketsAreBounded(t *testing.T) {
	v := New().view
	v.RotateLabCode("aaaaaa", 3, time.Time{})
	old := t0.Add(-time.Hour)
	v.RedeemLabCode("10.0.0.1", "zzzzzz", old, old.Add(-time.Minute), 10, 2)
	v.RedeemLabCode("10.0.0.2", "zzzzzz", t0, t0.Add(-time.Minute), 10, 2)
	v.RedeemLabCode("10.0.0.3", "zzzzzz", t0, t0.Add(-time.Minute), 10, 2)
	if v.LabFailures("10.0.0.1") != nil || v.LabFailures("10.0.0.3") == nil {
		t.Fatal("a full map did not prune its expired bucket for the new one")
	}
	v.RedeemLabCode("10.0.0.4", "zzzzzz", t0, t0.Add(-time.Minute), 10, 2)
	if v.LabFailures("10.0.0.4") != nil || v.LabFailureBuckets() != 2 {
		t.Fatalf("a full map grew: %d buckets", v.LabFailureBuckets())
	}
	if a := v.RedeemLabCode("10.0.0.5", "aaaaaa", t0, t0.Add(-time.Minute), 10, 2); !a.Matched {
		t.Fatal("a correct code did not redeem at capacity")
	}
}

// An alias chain resolves to its last identity, an unknown id is its own, the
// retired ids of a live identity are the whole chain, and a cyclic map (which
// the ledger refuses on load) still ends the walk.
func TestAliasesResolveChains(t *testing.T) {
	v := New().view
	v.SetAliases(map[string]string{"42a": "42b", "42b": "42c"})
	if got := v.CanonicalHostID("42a"); got != "42c" {
		t.Fatalf("canonical of the first id = %q", got)
	}
	if got := v.CanonicalHostID("42z"); got != "42z" {
		t.Fatalf("an id never retired is not its own: %q", got)
	}
	if v.ReplacedBy("42a") != "42b" || v.ReplacedBy("42c") != "" {
		t.Fatal("ReplacedBy does not name the direct successor")
	}
	ids := v.RetiredIDs("42c")
	if len(ids) != 2 || (ids[0] != "42a" && ids[1] != "42a") {
		t.Fatalf("retired ids = %v", ids)
	}
	if ids := v.RetiredIDs("42z"); ids == nil || len(ids) != 0 {
		t.Fatalf("an identity with no history = %#v, want empty", ids)
	}
	copied := v.Aliases()
	copied["42c"] = "42d"
	if v.ReplacedBy("42c") != "" {
		t.Fatal("Aliases handed out the live map")
	}
	v.SetAliases(map[string]string{"42a": "42b", "42b": "42a"})
	if got := v.CanonicalHostID("42a"); got != "42a" && got != "42b" {
		t.Fatalf("a cyclic map walked off the map: %q", got)
	}
}
