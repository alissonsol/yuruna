// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42e8d5a2-3c7f-4b19-a6e4-1d2f8c9b0e73

package poolstate

import "sort"

// RingRow is one completed cycle as the framework canary ring records it.
type RingRow struct {
	Cycle    string // cycleStartUtc, RFC 3339 UTC
	Revision string // full framework commit
	Passed   bool   // a pass that skipped no planned guest
}

// RingLimits bound the ring facts: a host keeps its newest CyclesPerHost cycles
// at one revision, and the store keeps the Revisions whose newest cycle is
// newest, so the revisions a ring can still choose are always kept.
type RingLimits struct {
	CyclesPerHost int
	Revisions     int
}

// RecordRingCycles merges one host's completed cycles into the ring facts,
// within limits. Recording is idempotent, because every poll re-reads each
// host's whole recent history; it reports whether anything new was recorded.
func (v *View) RecordRingCycles(hostID string, rows []RingRow, limits RingLimits) bool {
	if len(rows) == 0 {
		return false
	}
	if v.Ring == nil {
		v.Ring = RingFacts{}
	}
	changed := false
	for _, row := range rows {
		hosts := v.Ring[row.Revision]
		if hosts == nil {
			hosts = map[string]map[string]bool{}
			v.Ring[row.Revision] = hosts
		}
		cycles := hosts[hostID]
		if cycles == nil {
			cycles = map[string]bool{}
			hosts[hostID] = cycles
		}
		if prev, known := cycles[row.Cycle]; known && prev == row.Passed {
			continue
		}
		cycles[row.Cycle] = row.Passed
		changed = true
		trimRingCycles(cycles, limits.CyclesPerHost)
	}
	if changed {
		trimRingRevisions(v.Ring, limits.Revisions)
	}
	return changed
}

// SetRingFacts replaces the ring facts with ones an earlier run kept, trimmed
// to limits. The caller validates the ids and times before handing them over.
func (v *View) SetRingFacts(facts RingFacts, limits RingLimits) {
	for _, hosts := range facts {
		for _, cycles := range hosts {
			trimRingCycles(cycles, limits.CyclesPerHost)
		}
	}
	trimRingRevisions(facts, limits.Revisions)
	v.Ring = facts
}

// trimRingCycles keeps a host's newest keep cycles at one revision.
func trimRingCycles(cycles map[string]bool, keep int) {
	if len(cycles) <= keep {
		return
	}
	keys := make([]string, 0, len(cycles))
	for k := range cycles {
		keys = append(keys, k)
	}
	sort.Strings(keys) // RFC 3339 UTC sorts chronologically
	for _, k := range keys[:len(keys)-keep] {
		delete(cycles, k)
	}
}

// trimRingRevisions drops the revisions whose newest cycle is oldest until keep
// remain.
func trimRingRevisions(facts RingFacts, keep int) {
	if len(facts) <= keep {
		return
	}
	type aged struct {
		revision string
		newest   string
	}
	all := make([]aged, 0, len(facts))
	for revision, hosts := range facts {
		newest := ""
		for _, cycles := range hosts {
			for cycle := range cycles {
				if cycle > newest {
					newest = cycle
				}
			}
		}
		all = append(all, aged{revision, newest})
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].newest != all[j].newest {
			return all[i].newest < all[j].newest
		}
		return all[i].revision < all[j].revision
	})
	for _, a := range all[:len(all)-keep] {
		delete(facts, a.revision)
	}
}
