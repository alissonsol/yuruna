// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42c7a3f9-1e5b-4d28-8f6a-0b9e4c2d7a15

package poolstate

import (
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
)

// The incident records and the health gate's latch change only here and in the
// forget and retire paths of the host records: the rules in internal/incident
// decide, applied to the fail windows and the records under the one lock, so a
// reader never sees a window pruned without its incident re-judged.

// EvaluateIncidents applies r to every fail window: prunes each to r.HostWindow,
// opens and resolves the host incidents and the pool-wide incident, and
// records what remains open. poolFor labels a host's events. The returned
// events are for the caller to push after the lock is released.
func (v *View) EvaluateIncidents(r incident.Rules, poolFor func(hostID string) string, now time.Time) []incident.Event {
	events, pool := incident.EvaluateHosts(r, v.FailWindow, v.Incident, v.PoolIncident, poolFor, now)
	v.PoolIncident = pool
	return events
}

// EvaluateGate applies each pool's health gate to members, the hosts with the
// caller's verdict on each; a host with an open incident is never counted
// healthy. The latch of every pool with a member is updated and a pool with
// none loses its latch. The returned alert events are for the caller to push
// after the lock is released.
func (v *View) EvaluateGate(members []incident.Member, now time.Time) []incident.Event {
	return incident.EvaluateGate(members, v.Incident, v.Gating, v.PoolGate, now)
}

// SetGating records pool's authored gating policy. Nothing clears one: a
// member that omits the block must not disable a peer's authored alerting, so
// a policy removed from pools.yml leaves with the collector's next restart.
func (v *View) SetGating(pool string, g incident.GatingPolicy) { v.Gating[pool] = g }

// RestoreIncident restores hostID's open incident from its recorded open line.
// When the live fail window already holds more fails than the recorded peak,
// the peak, the class histogram and the dominant class are recomputed from the
// window together, so the three cannot disagree after a class shift that
// followed the open. A missing dominant class is derived from the histogram,
// and "unknown" when that is empty.
func (v *View) RestoreIncident(hostID, id string, started time.Time, peak int, hist map[string]int, dominant string) {
	if n := len(v.FailWindow[hostID]); n > peak {
		peak = n
		hist = incident.ClassHistogram(v.FailWindow[hostID])
		dominant = incident.DominantClass(hist)
	}
	if len(hist) == 0 {
		hist = map[string]int{}
	}
	if dominant == "" {
		dominant = incident.DominantClass(hist)
	}
	if dominant == "" {
		dominant = "unknown"
	}
	v.Incident[hostID] = &incident.HostIncident{ID: id, StartedAt: started, Peak: peak, PeakClassHist: hist, DominantClass: dominant}
}

// RestorePoolIncident restores the open pool-wide incident from its recorded
// open line; a line that predates the pinned class restores as "unknown".
func (v *View) RestorePoolIncident(id string, started time.Time, peakHosts int, class string) {
	if class == "" {
		class = "unknown"
	}
	v.PoolIncident = &incident.PoolIncident{ID: id, StartedAt: started, PeakHosts: peakHosts, Class: class}
}

// RestoreAlert restores pool's firing alert latch with its original id and
// start, so the eventual rearm pairs with the fired line and a pool still
// degraded after a restart does not page again under a new id.
func (v *View) RestoreAlert(pool, id string, started time.Time) {
	gate := v.PoolGate[pool]
	if gate == nil {
		gate = &incident.Gate{}
		v.PoolGate[pool] = gate
	}
	gate.Authored, gate.AlertFired, gate.AlertID, gate.AlertStartedAt = true, true, id, started
}
