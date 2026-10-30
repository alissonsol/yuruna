// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42f27f67-3bf5-4a08-bebe-7d7657a62b7c

package incident

import (
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)

func rules() Rules {
	return Rules{HostN: 3, HostWindow: time.Hour, CrossN: 2, CrossWindow: 30 * time.Minute, PoolLabel: "lab"}
}

func poolOf(string) string { return "lab" }

// A host opens one incident at N fails, keeps it while it keeps failing, and
// resolves it, with the peak breakdown, once the window empties.
func TestEvaluateHostsOpensAtNAndResolvesAtZero(t *testing.T) {
	fw := map[string][]FailRec{"42a": {{At: t0, Class: "net"}, {At: t0.Add(time.Minute), Class: "net"}}}
	open := map[string]*HostIncident{}
	if ev, pool := EvaluateHosts(rules(), fw, open, nil, poolOf, t0.Add(2*time.Minute)); len(ev) != 0 || pool != nil || len(open) != 0 {
		t.Fatalf("two fails must not open: %v %v %v", ev, pool, open)
	}
	fw["42a"] = append(fw["42a"], FailRec{At: t0.Add(3 * time.Minute), Class: "disk"})
	ev, _ := EvaluateHosts(rules(), fw, open, nil, poolOf, t0.Add(4*time.Minute))
	if len(ev) != 1 || !ev[0].Open || ev[0].Count != 3 || ev[0].DominantClass != "net" || open["42a"] == nil {
		t.Fatalf("the third fail opens one incident: %+v", ev)
	}
	ev, _ = EvaluateHosts(rules(), fw, open, nil, poolOf, t0.Add(2*time.Hour))
	if len(ev) != 1 || ev[0].Open || ev[0].Peak != 3 || ev[0].ClassHist["disk"] != 1 || len(open) != 0 || len(fw) != 0 {
		t.Fatalf("an emptied window resolves with the peak breakdown: %+v open=%v fw=%v", ev, open, fw)
	}
}

// A pool-wide incident needs CrossN hosts failing the SAME class; it stays pinned
// to that class and resolves below the floor.
func TestEvaluateHostsPoolIncidentIsSameClassAndPinned(t *testing.T) {
	r := rules()
	r.HostN = 99 // only the cross-host rule is under test
	fw := map[string][]FailRec{"42a": {{At: t0, Class: "net"}}, "42b": {{At: t0, Class: "disk"}}}
	if ev, pool := EvaluateHosts(r, fw, map[string]*HostIncident{}, nil, poolOf, t0.Add(time.Minute)); len(ev) != 0 || pool != nil {
		t.Fatalf("two classes are not a shared cause: %v %v", ev, pool)
	}
	fw["42b"] = append(fw["42b"], FailRec{At: t0.Add(time.Minute), Class: "net"})
	ev, pool := EvaluateHosts(r, fw, map[string]*HostIncident{}, nil, poolOf, t0.Add(2*time.Minute))
	if len(ev) != 1 || !ev[0].Pool || !ev[0].Open || pool == nil || pool.Class != "net" || ev[0].PoolLabel != "lab" || len(ev[0].Hosts) != 2 {
		t.Fatalf("two hosts failing net open a pool incident: %+v %+v", ev, pool)
	}
	ev, after := EvaluateHosts(r, fw, map[string]*HostIncident{}, pool, poolOf, t0.Add(time.Hour))
	if len(ev) != 1 || ev[0].Pool == false || ev[0].Open || after != nil {
		t.Fatalf("the pinned class leaving the window resolves it: %+v %+v", ev, after)
	}
}

// A host with an open incident never counts as healthy; an authored pool fires
// after FailuresBeforeAlert degraded evaluations and re-arms after the successes.
func TestEvaluateGateFiresAndRearms(t *testing.T) {
	policy := GatingPolicy{FailuresBeforeAlert: 2, SuccessesBeforeRearm: 1, HealthyThreshold: 0.9, DegradedAfter: 0}
	gating := map[string]GatingPolicy{"lab": policy}
	gates := map[string]*Gate{}
	open := map[string]*HostIncident{"42a": {ID: "inc"}}
	members := []Member{{HostID: "42a", Pool: "lab", Healthy: true}, {HostID: "42b", Pool: "lab", Healthy: true}}
	if ev := EvaluateGate(members, open, gating, gates, t0); len(ev) != 0 || !gates["lab"].Degraded || gates["lab"].LastHealthy != 1 {
		t.Fatalf("the first degraded evaluation latches without paging: %+v %+v", ev, gates["lab"])
	}
	ev := EvaluateGate(members, open, gating, gates, t0.Add(time.Minute))
	if len(ev) != 1 || !ev[0].Alert || ev[0].Rearm || !gates["lab"].AlertFired {
		t.Fatalf("the second fires: %+v", ev)
	}
	delete(open, "42a")
	ev = EvaluateGate(members, open, gating, gates, t0.Add(2*time.Minute))
	if len(ev) != 1 || !ev[0].Rearm || gates["lab"].AlertFired {
		t.Fatalf("a healthy evaluation re-arms: %+v", ev)
	}
	if ev := EvaluateGate(nil, open, gating, gates, t0.Add(3*time.Minute)); len(ev) != 0 || len(gates) != 0 {
		t.Fatalf("an emptied pool drops its gate: %+v %v", ev, gates)
	}
}

func TestDominantClassBreaksTiesLexically(t *testing.T) {
	if got := DominantClass(map[string]int{"net": 2, "disk": 2, "auth": 1}); got != "disk" {
		t.Fatalf("got %q", got)
	}
	if got := DominantClass(nil); got != "" {
		t.Fatalf("empty histogram: %q", got)
	}
}
