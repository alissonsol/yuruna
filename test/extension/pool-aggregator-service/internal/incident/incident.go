// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 427ee616-540d-488a-927a-ca26fd244bd1

// Package incident holds the collector's incident rules: when a host's failed
// cycles open and resolve a host incident, when failures of one class across
// hosts open a pool-wide incident, and when a pool's health gate degrades and
// fires or re-arms its alert. It holds no lock and keeps no state of its own:
// the pool view owns the maps these rules read and change, and calls them under
// its lock. See https://yuruna.link/42c29d04-0004 for the gate.
package incident

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

// Pool gating defaults (mirror test/schemas/pools.schema.yml gating.*): the
// advisory degraded/alert policy a pool inherits when it authors a partial (or
// no) gating block. DefaultDegradedAfter is the sustained-below-threshold
// window; failures/successes are the poll-count alert hysteresis.
const (
	DefaultFailuresBeforeAlert  = 3
	DefaultSuccessesBeforeRearm = 2
	DefaultHealthyThreshold     = 0.5
	DefaultDegradedAfter        = 1800 * time.Second
)

// Rules are the thresholds EvaluateHosts applies.
type Rules struct {
	HostN       int           // open a host incident at >= HostN fails within HostWindow
	HostWindow  time.Duration // trailing window for the fail-burst rule
	CrossN      int           // distinct hosts failing one class within CrossWindow open a pool-wide incident
	CrossWindow time.Duration // window for cross-host "failing together"
	PoolLabel   string        // the pool label pool-wide events carry
}

// Member is one pool host as the health gate counts it. Healthy is the caller's
// verdict on the host's own state; a host with an open incident is never counted
// healthy, whatever that verdict says.
type Member struct {
	HostID  string
	Pool    string
	Healthy bool
}

// FailRec is one in-window failed cycle: when it failed + its failure class.
// Replaces the bare fail-time slice so an incident can carry a class histogram.
type FailRec struct {
	At    time.Time
	Class string // failureClass; "unknown" when the cycle had no classified lastFailure
}

// HostIncident is an open per-host incident: the host has had >= Rules.HostN
// failed cycles within the trailing Rules.HostWindow. It resolves once that
// window empties of fails.
type HostIncident struct {
	ID        string
	StartedAt time.Time // earliest fail in the window when the incident opened
	Peak      int       // most concurrent in-window fails seen during the incident
	// PeakClassHist is the failure-class histogram captured at the moment Peak
	// was last (re)assigned -- so the resolve line (when the window has aged to ~0)
	// still reports the breakdown the incident peaked at. DominantClass = argmax
	// (lexical tiebreak), the headline class for metrics + display.
	PeakClassHist map[string]int
	DominantClass string
}

// PoolIncident is the single open pool-wide (cross-host) incident: >=
// Rules.CrossN distinct hosts failed within Rules.CrossWindow WITH THE SAME
// failure class -- a systemic signal (shared cause), not unrelated single-host
// churn.
type PoolIncident struct {
	ID        string
	StartedAt time.Time
	PeakHosts int    // most distinct same-class affected hosts seen during the incident
	Class     string // the triggering class, PINNED at open; resolve is evaluated against it
}

// GatingPolicy is a pool's authored alerting policy (from pools.yml `gating`,
// carried per-host in host.registration.json). Missing fields are filled from the
// schema defaults at parse time, so a partial block is always complete here.
type GatingPolicy struct {
	FailuresBeforeAlert  int           // consecutive degraded polls before the alert fires
	SuccessesBeforeRearm int           // consecutive non-degraded polls before it re-arms
	HealthyThreshold     float64       // fraction of members that must be healthy
	DegradedAfter        time.Duration // sustained below-threshold window before "degraded"
}

func DefaultGatingPolicy() GatingPolicy {
	return GatingPolicy{
		FailuresBeforeAlert:  DefaultFailuresBeforeAlert,
		SuccessesBeforeRearm: DefaultSuccessesBeforeRearm,
		HealthyThreshold:     DefaultHealthyThreshold,
		DegradedAfter:        DefaultDegradedAfter,
	}
}

// Gate is the per-pool advisory degraded/alert latch. READ-SIDE ONLY: no
// runner consumes it (consensus-gated control is deferred) -- it drives alerting
// (the host-side notifier reads yuruna_pool_alert_active) + dashboard de-noise,
// never a cycle decision. degraded latches when the healthy fraction stays below
// the threshold for >= DegradedAfter (wall-clock); the alert fires/re-arms on a
// poll-count hysteresis so a single flapping poll neither pages nor clears.
type Gate struct {
	BelowSince     time.Time // zero = currently at/above threshold
	Degraded       bool
	Authored       bool // the pool advertised a gating block -> eligible to ALERT (not just observe)
	AlertFired     bool
	ConsecDegraded int
	ConsecHealthy  int
	AlertID        string
	AlertStartedAt time.Time
	// last* snapshot the most recent poll's computation so handleMetrics emits
	// gauges consistent with the latch decision (same poll), without recomputing.
	LastFraction  float64
	LastHealthy   int
	LastTotal     int
	LastThreshold float64
}

// Event is a pending incident lifecycle change to push to Loki.
type Event struct {
	Open          bool
	Pool          bool     // pool-wide (cross-host) incident vs per-host
	HostID        string   // per-host incidents
	Hosts         []string // pool-wide: affected host IDs at open (hostname-free)
	ID            string
	Count         int            // per-host: in-window fails at open; pool: affected host count at open
	Peak          int            // per-host: peak in-window fails; pool: peak affected hosts
	ClassHist     map[string]int // per-host: failure-class breakdown (live at open, peak at resolve)
	DominantClass string         // per-host: argmax class of classHist
	Class         string         // pool-wide: the pinned triggering (same) failure class
	PoolLabel     string         // pool label for the Loki stream (per-host: poolFor(hostId); pool-wide: the -pool flag)
	StartedAt     time.Time
	Now           time.Time
	// Pool gating ALERT lifecycle (distinct from the heuristic incidents above):
	// Alert=true marks a quorum-degraded Alert event; rearm distinguishes recovered
	// from fired. healthyFraction/membersHealthy/membersTotal carry the gate snapshot.
	Alert           bool
	Rearm           bool
	HealthyFraction float64
	MembersHealthy  int
	MembersTotal    int
}

// ClassHistogram counts the failure classes in a fail window (empty -> empty map).
func ClassHistogram(fw []FailRec) map[string]int {
	h := map[string]int{}
	for _, r := range fw {
		c := r.Class
		if c == "" {
			c = "unknown"
		}
		h[c]++
	}
	return h
}

// dominantClass is the argmax class of a histogram, ties broken lexically (so the
// headline class is deterministic); "" for an empty histogram.
func DominantClass(h map[string]int) string {
	best, bestN := "", -1
	for c, n := range h {
		if n > bestN || (n == bestN && c < best) {
			best, bestN = c, n
		}
	}
	return best
}

// ID names a host incident by the host's short id and the first failure's time.
func ID(hostID string, t time.Time) string {
	short := hostID
	if len(short) > 8 {
		short = short[:8]
	}
	return fmt.Sprintf("inc-%s-%d", short, t.Unix())
}

// PoolID names a pool-wide incident by its opening time.
func PoolID(t time.Time) string { return fmt.Sprintf("inc-pool-%d", t.Unix()) }

// AlertID names a pool gate alert by its firing time.
func AlertID(t time.Time) string { return fmt.Sprintf("alert-pool-%d", t.Unix()) }

// StreamLine builds an incident lifecycle line and the labels of the
// stream it belongs to. The history backfill writes replayed incidents through it,
// so a replayed line reads exactly like a live one.
func StreamLine(pool string, ev Event) (map[string]string, []byte) {
	rec := map[string]any{
		"incidentId": ev.ID,
		"startedAt":  ev.StartedAt.UTC().Format(time.RFC3339),
		"timestamp":  ev.Now.UTC().Format(time.RFC3339),
	}
	stream := map[string]string{"pool": pool, "src": "incident"}
	switch {
	case ev.Alert:
		// Pool-level advisory ALERT (quorum-degraded). kind=alert distinguishes it
		// from pool_incident_* on the same pool-scoped stream; the host-side notifier
		// reads the yuruna_pool_alert_active gauge (not this line) to deliver, so this
		// is the audit trail + the rehydrate-free record of the latch transition.
		stream["scope"] = "pool"
		stream["kind"] = "alert"
		rec["scope"] = "pool"
		rec["healthyFraction"] = ev.HealthyFraction
		rec["membersHealthy"] = ev.MembersHealthy
		rec["membersTotal"] = ev.MembersTotal
		if ev.Rearm {
			rec["event"] = "pool_alert_rearmed"
			rec["durationSeconds"] = int64(ev.Now.Sub(ev.StartedAt) / time.Second)
		} else {
			rec["event"] = "pool_alert_fired"
		}
	case ev.Pool:
		stream["scope"] = "pool"
		rec["scope"] = "pool"
		if ev.Class != "" {
			rec["class"] = ev.Class // the same-class that triggered the pool-wide incident
		}
		if ev.Open {
			rec["event"] = "pool_incident_open"
			rec["affectedHostCount"] = ev.Count
			rec["affectedHosts"] = ev.Hosts
		} else {
			rec["event"] = "pool_incident_resolved"
			rec["peakHosts"] = ev.Peak
			rec["durationSeconds"] = int64(ev.Now.Sub(ev.StartedAt) / time.Second)
		}
	default:
		stream["hostId"] = ev.HostID
		rec["hostId"] = ev.HostID
		// The failure-class breakdown on the incident OBJECT: dominantClass is the
		// headline; ClassHistogram is the full per-class count (live at open, peak at
		// resolve). Empty/unknown when the cycles carried no classified lastFailure.
		if ev.DominantClass != "" {
			rec["dominantClass"] = ev.DominantClass
		}
		if len(ev.ClassHist) > 0 {
			rec["ClassHistogram"] = ev.ClassHist
		}
		if ev.Open {
			rec["event"] = "incident_open"
			rec["failCount"] = ev.Count
		} else {
			rec["event"] = "incident_resolved"
			rec["peakFails"] = ev.Peak
			rec["durationSeconds"] = int64(ev.Now.Sub(ev.StartedAt) / time.Second)
		}
	}
	line, _ := json.Marshal(rec)
	return stream, line
}

// EvaluateHosts prunes each host's in-window fail list, opens an incident
// when a host reaches incidentN fails within incidentWin, and resolves it once
// the window empties of fails. Hysteresis (open at >=N, resolve at 0) keeps a
// host that keeps failing in ONE incident instead of flapping. Returns the
// open/resolve events for the caller to push to Loki after releasing its lock,
// and the pool-wide incident that remains open (nil when none). The caller holds
// the lock that guards failWindow, open and pool.
func EvaluateHosts(r Rules, failWindow map[string][]FailRec, open map[string]*HostIncident, pool *PoolIncident, poolFor func(hostID string) string, now time.Time) ([]Event, *PoolIncident) {
	cutoff := now.Add(-r.HostWindow)
	ids := map[string]bool{}
	for h := range failWindow {
		ids[h] = true
	}
	for h := range open {
		ids[h] = true
	}
	var events []Event
	for hid := range ids {
		kept := failWindow[hid][:0]
		for _, r := range failWindow[hid] {
			if r.At.After(cutoff) {
				kept = append(kept, r)
			}
		}
		if len(kept) == 0 {
			delete(failWindow, hid)
		} else {
			failWindow[hid] = kept
		}
		n := len(kept)
		inc := open[hid]
		switch {
		case inc == nil && n >= r.HostN:
			hist := ClassHistogram(kept)
			dom := DominantClass(hist)
			if dom == "" {
				dom = "unknown"
			}
			inc = &HostIncident{ID: ID(hid, kept[0].At), StartedAt: kept[0].At, Peak: n, PeakClassHist: hist, DominantClass: dom}
			open[hid] = inc
			events = append(events, Event{Open: true, HostID: hid, ID: inc.ID, Count: n, StartedAt: kept[0].At, Now: now, ClassHist: hist, DominantClass: dom, PoolLabel: poolFor(hid)})
		case inc != nil:
			// Snapshot the class histogram whenever peak is (re)assigned so the
			// resolve line -- emitted when the window has aged to ~0 -- reports the
			// breakdown the incident PEAKED at, like peakFails.
			if n > inc.Peak {
				inc.Peak = n
				inc.PeakClassHist = ClassHistogram(kept)
				inc.DominantClass = DominantClass(inc.PeakClassHist)
				if inc.DominantClass == "" {
					inc.DominantClass = "unknown"
				}
			}
			if n == 0 {
				delete(open, hid)
				events = append(events, Event{HostID: hid, ID: inc.ID, StartedAt: inc.StartedAt, Peak: inc.Peak, Now: now, ClassHist: inc.PeakClassHist, DominantClass: inc.DominantClass, PoolLabel: poolFor(hid)})
			}
		}
	}

	// Cross-host same-class correlation: a pool-wide incident opens when >= CrossN
	// distinct hosts failed with one class within CrossWindow. The class is pinned
	// at open and only it is checked for resolve. See https://yuruna.link/42c29d04-000f.
	crossCut := now.Add(-r.CrossWindow)
	hostsByClass := map[string]map[string]bool{} // class -> set of hostIds with an in-window fail of that class
	for hid, fw := range failWindow {
		for _, r := range fw {
			if r.At.After(crossCut) {
				c := r.Class
				if c == "" {
					c = "unknown"
				}
				if hostsByClass[c] == nil {
					hostsByClass[c] = map[string]bool{}
				}
				hostsByClass[c][hid] = true
			}
		}
	}
	// affectedFor returns the sorted hostId list for a class (hostname-free: the pool
	// feed drives the unauthenticated dashboard).
	affectedFor := func(c string) []string {
		a := make([]string, 0, len(hostsByClass[c]))
		for hid := range hostsByClass[c] {
			a = append(a, hid)
		}
		sort.Strings(a)
		return a
	}
	// The class with the most distinct hosts (lexical tiebreak) is the open candidate.
	topClass, topN := "", 0
	for c, hs := range hostsByClass {
		nc := len(hs)
		if nc > topN || (nc == topN && (topClass == "" || c < topClass)) {
			topClass, topN = c, nc
		}
	}
	crossFloor := r.CrossN - 1
	if crossFloor < 1 {
		crossFloor = 1
	}
	// Resolve first (against the pinned class), so a cleared incident can reopen for a
	// different systemic class in this same pass.
	if pool != nil {
		pinnedN := len(hostsByClass[pool.Class])
		if pinnedN > pool.PeakHosts {
			pool.PeakHosts = pinnedN
		}
		if pinnedN < crossFloor {
			events = append(events, Event{Pool: true, ID: pool.ID, StartedAt: pool.StartedAt, Peak: pool.PeakHosts, Now: now, Class: pool.Class, PoolLabel: r.PoolLabel})
			pool = nil
		}
	}
	if pool == nil && topN >= r.CrossN {
		pool = &PoolIncident{ID: PoolID(now), StartedAt: now, PeakHosts: topN, Class: topClass}
		events = append(events, Event{Open: true, Pool: true, ID: pool.ID, Count: topN, StartedAt: now, Now: now, Hosts: affectedFor(topClass), Class: topClass, PoolLabel: r.PoolLabel})
	}
	return events, pool
}

// EvaluateGate computes each pool's advisory health gate (healthy fraction,
// degraded latch, alert hysteresis). Read-side only: it drives alerting and the
// dashboard, never a cycle. It reads open and gating and changes gates; the
// caller holds the lock that guards them. Returns the alert lifecycle events to
// ship to Loki after the unlock.
func EvaluateGate(members []Member, open map[string]*HostIncident, gating map[string]GatingPolicy, gates map[string]*Gate, now time.Time) []Event {
	membersByPool := map[string][]Member{}
	for _, m := range members {
		membersByPool[m.Pool] = append(membersByPool[m.Pool], m)
	}
	var events []Event
	// Drop gate state for pools that no longer have a member (their gauge series
	// vanish; the notifier preserves last-state on an absent gauge + a rearm cooldown,
	// so a pool that simply emptied does not page). If such a pool was still FIRING,
	// emit a rearm first so the kind=alert Loki lifecycle feed closes cleanly -- this is
	// otherwise the one path that could leave a dangling pool_alert_fired.
	for p, gate := range gates {
		if _, ok := membersByPool[p]; ok {
			continue
		}
		if gate.Authored && gate.AlertFired {
			events = append(events, Event{
				Alert: true, Rearm: true, Pool: true, ID: gate.AlertID, PoolLabel: p,
				StartedAt: gate.AlertStartedAt, Now: now,
				HealthyFraction: 0, MembersHealthy: 0, MembersTotal: 0,
			})
		}
		delete(gates, p)
	}
	for p, pm := range membersByPool {
		total := len(pm)
		healthy := 0
		for _, m := range pm {
			if m.Healthy && open[m.HostID] == nil {
				healthy++
			}
		}
		policy, authored := gating[p]
		if !authored {
			policy = DefaultGatingPolicy()
		}
		gate := gates[p]
		if gate == nil {
			gate = &Gate{}
			gates[p] = gate
		}
		gate.Authored = authored
		frac := 1.0
		if total > 0 {
			frac = float64(healthy) / float64(total)
		}
		gate.LastFraction, gate.LastHealthy, gate.LastTotal, gate.LastThreshold = frac, healthy, total, policy.HealthyThreshold

		below := frac < policy.HealthyThreshold
		if below {
			if gate.BelowSince.IsZero() {
				gate.BelowSince = now
			}
		} else {
			gate.BelowSince = time.Time{}
		}
		gate.Degraded = below && !gate.BelowSince.IsZero() && now.Sub(gate.BelowSince) >= policy.DegradedAfter

		// Alert hysteresis runs only for authored pools; an un-configured pool keeps
		// its counters/latch reset (observed via gauges, never paged).
		if !authored {
			gate.ConsecDegraded, gate.ConsecHealthy, gate.AlertFired = 0, 0, false
			continue
		}
		if gate.Degraded {
			gate.ConsecDegraded++
			gate.ConsecHealthy = 0
		} else {
			gate.ConsecHealthy++
			gate.ConsecDegraded = 0
		}
		if !gate.AlertFired && gate.ConsecDegraded >= policy.FailuresBeforeAlert {
			gate.AlertFired = true
			gate.AlertID = AlertID(now)
			gate.AlertStartedAt = now
			events = append(events, Event{
				Alert: true, Pool: true, ID: gate.AlertID, PoolLabel: p, StartedAt: now, Now: now,
				HealthyFraction: frac, MembersHealthy: healthy, MembersTotal: total,
			})
		} else if gate.AlertFired && gate.ConsecHealthy >= policy.SuccessesBeforeRearm {
			events = append(events, Event{
				Alert: true, Rearm: true, Pool: true, ID: gate.AlertID, PoolLabel: p, StartedAt: gate.AlertStartedAt, Now: now,
				HealthyFraction: frac, MembersHealthy: healthy, MembersTotal: total,
			})
			gate.AlertFired, gate.AlertID, gate.AlertStartedAt = false, "", time.Time{}
		}
	}
	return events
}
