// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428d7fbb-4dfd-47a5-9721-79096a894692

package poolstate

import (
	"strings"
	"time"
)

// cycleLedger is the per-cycle dedup set and the terminal cycle counters. The
// dedup records are keyed by CycleKey and expire; the counters are cumulative
// per hostId and leave only through ForgetCycles, so a reaped host keeps
// reporting its totals.
type cycleLedger struct {
	seen    map[string]string    // CycleKey -> the overallStatus last recorded for that cycle
	seenAt  map[string]time.Time // CycleKey -> when that status was last observed
	counted map[string]bool      // CycleKey -> its terminal status has been counted
	pass    map[string]int64     // hostId -> terminal passing cycles
	fail    map[string]int64     // hostId -> terminal failing cycles
}

func newCycleLedger() cycleLedger {
	return cycleLedger{seen: map[string]string{}, seenAt: map[string]time.Time{},
		counted: map[string]bool{}, pass: map[string]int64{}, fail: map[string]int64{}}
}

// CycleKey is the key one cycle of one host is recorded under.
func CycleKey(hostID, cycleStartUtc string) string { return hostID + "|" + cycleStartUtc }

// ObserveCycle records status as the cycle's current status, observed at at. It
// reports what was recorded before (known is false when nothing was) and
// whether the status changed.
func (v *View) ObserveCycle(key, status string, at time.Time) (prev string, known, changed bool) {
	prev, known = v.cycles.seen[key]
	v.cycles.seen[key] = status
	v.cycles.seenAt[key] = at
	return prev, known, !known || prev != status
}

// RevertCycle puts back what an ObserveCycle replaced, provided status is still
// the cycle's recorded status, so a transition that could not be delivered is
// seen as new by the next observation.
func (v *View) RevertCycle(key, status, prev string, known bool) {
	if v.cycles.seen[key] != status {
		return
	}
	if known {
		v.cycles.seen[key] = prev
	} else {
		delete(v.cycles.seen, key)
	}
}

// CountTerminal counts a cycle's terminal status for hostID once, as a pass or
// a fail. It reports whether this call counted it.
func (v *View) CountTerminal(key, hostID string, passed bool) bool {
	if v.cycles.counted[key] {
		return false
	}
	v.cycles.counted[key] = true
	if passed {
		v.cycles.pass[hostID]++
	} else {
		v.cycles.fail[hostID]++
	}
	return true
}

// ReapCycles drops the dedup records of cycles last observed more than ttl
// before now. The counters stay.
func (v *View) ReapCycles(now time.Time, ttl time.Duration) {
	for k, t := range v.cycles.seenAt {
		if now.Sub(t) > ttl {
			delete(v.cycles.seenAt, k)
			delete(v.cycles.seen, k)
			delete(v.cycles.counted, k)
		}
	}
}

// ForgetCycles drops hostID's counters and every dedup record of its cycles.
func (v *View) ForgetCycles(hostID string) {
	delete(v.cycles.pass, hostID)
	delete(v.cycles.fail, hostID)
	prefix := hostID + "|"
	for k := range v.cycles.seen {
		if strings.HasPrefix(k, prefix) {
			delete(v.cycles.seen, k)
			delete(v.cycles.seenAt, k)
			delete(v.cycles.counted, k)
		}
	}
}

// CycleTotals returns copies of the terminal pass and fail counters, keyed by
// the hostId each cycle was counted under (a retired id keeps its own entry).
func (v *View) CycleTotals() (pass, fail map[string]int64) {
	pass = make(map[string]int64, len(v.cycles.pass))
	for k, n := range v.cycles.pass {
		pass[k] = n
	}
	fail = make(map[string]int64, len(v.cycles.fail))
	for k, n := range v.cycles.fail {
		fail[k] = n
	}
	return pass, fail
}

// CycleRecord is what the dedup set holds for one cycle.
type CycleRecord struct {
	Status     string
	ObservedAt time.Time
	Counted    bool
}

// Cycle returns the dedup record of one cycle, and whether one is held.
func (v *View) Cycle(key string) (CycleRecord, bool) {
	status, ok := v.cycles.seen[key]
	at, timed := v.cycles.seenAt[key]
	if !ok && !timed {
		return CycleRecord{}, false
	}
	return CycleRecord{Status: status, ObservedAt: at, Counted: v.cycles.counted[key]}, true
}

// CycleCount is how many cycles the dedup set holds.
func (v *View) CycleCount() int { return len(v.cycles.seen) }
