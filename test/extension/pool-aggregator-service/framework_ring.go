// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428e8be3-c9af-4a2f-875d-4d28e07c513b

package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The framework canary ring. A pool's pools.yml may name canary members that
// track the framework tip while every other member waits until a revision has
// enough valid canary passes. The collector keeps the facts that decision needs
// -- which full framework revision each host's completed cycles ran, and whether
// each one passed -- and answers the question with the canary list and pass
// count the asking host reads from its own copy of pools.yml. Keeping the policy
// out of the collector means a ring change takes effect with the pools.yml pull
// every member already makes, with nothing to propagate here.
const (
	defaultFrameworkRingStateFile = "/var/lib/pool-aggregator-service/framework-ring.json"

	// Bounds on what the collector keeps and answers. A revision ages out by the
	// start of its newest cycle once the store is full, so the revisions a ring
	// can still choose are always kept.
	ringMaxRevisions     = 256
	ringMaxCyclesPerHost = 64
	ringMaxCanaries      = 64
	ringMaxPasses        = 1000
	ringListedRevisions  = 20
)

var ringRevisionRE = regexp.MustCompile(`^[0-9a-f]{40}$`)

// ringRow is one completed cycle as the ring reads it.
type ringRow struct {
	cycle    string // cycleStartUtc, RFC 3339 UTC
	revision string // full framework commit
	passed   bool   // a pass that skipped no planned guest
}

// ringFacts is the pool view's record of each host's completed cycles,
// revision -> hostId -> cycleStartUtc -> passed.
type ringFacts = poolstate.RingFacts

type ringStateDoc struct {
	Version   int       `json:"version"`
	Revisions ringFacts `json:"revisions"`
}

// parseRingRows reads the completed cycles of a status.json body. A history row
// counts only when it names the full framework revision it ran: selectedSha
// carries it whenever the cycle had a source handoff, which every cycle of the
// resident runner has; sha is the abbreviated display hash and counts only if it
// happens to be complete. A pass that skipped a planned guest (a quarantined
// one) is recorded as not passed: it proved nothing about that guest.
func parseRingRows(body []byte) []ringRow {
	var doc struct {
		History []struct {
			CycleStartUtc string                     `json:"cycleStartUtc"`
			OverallStatus string                     `json:"overallStatus"`
			GitCommits    gitCommitRefs              `json:"gitCommits"`
			GuestSummary  map[string]json.RawMessage `json:"guestSummary"`
		} `json:"history"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil
	}
	var rows []ringRow
	for _, row := range doc.History {
		if row.OverallStatus != "pass" && row.OverallStatus != "fail" {
			continue
		}
		started, err := time.Parse(time.RFC3339, row.CycleStartUtc)
		if err != nil || len(row.GitCommits) == 0 {
			continue
		}
		revision := ringRevisionOf(row.GitCommits[0])
		if revision == "" {
			continue
		}
		rows = append(rows, ringRow{
			cycle:    started.UTC().Format(time.RFC3339),
			revision: revision,
			passed:   row.OverallStatus == "pass" && !ringSkippedGuest(row.GuestSummary),
		})
	}
	return rows
}

func ringRevisionOf(c gitCommitRef) string {
	for _, candidate := range []string{c.SelectedSHA, c.Sha} {
		candidate = strings.ToLower(strings.TrimSpace(candidate))
		if ringRevisionRE.MatchString(candidate) {
			return candidate
		}
	}
	return ""
}

// ringSkippedGuest reports a guest the cycle planned but skipped. A summary
// value is an object with a status field, or a bare status string in rows
// written before guest summaries carried durations.
func ringSkippedGuest(summary map[string]json.RawMessage) bool {
	for _, raw := range summary {
		var status string
		if json.Unmarshal(raw, &status) != nil {
			var entry struct {
				Status string `json:"status"`
			}
			if json.Unmarshal(raw, &entry) != nil {
				continue
			}
			status = entry.Status
		}
		if status == "skipped" {
			return true
		}
	}
	return false
}

// recordRingRows merges one host's completed cycles into the locked view.
// Returns true when anything new was recorded.
func (s *poolState) recordRingRows(view *poolstate.View, hostID string, rows []ringRow) bool {
	if len(rows) == 0 {
		return false
	}
	if view.Ring == nil {
		view.Ring = ringFacts{}
	}
	changed := false
	for _, row := range rows {
		hosts := view.Ring[row.revision]
		if hosts == nil {
			hosts = map[string]map[string]bool{}
			view.Ring[row.revision] = hosts
		}
		cycles := hosts[hostID]
		if cycles == nil {
			cycles = map[string]bool{}
			hosts[hostID] = cycles
		}
		if prev, known := cycles[row.cycle]; known && prev == row.passed {
			continue
		}
		cycles[row.cycle] = row.passed
		changed = true
		trimRingCycles(cycles)
	}
	if changed {
		trimRingRevisions(view.Ring)
	}
	return changed
}

// trimRingCycles keeps a host's newest cycles at one revision.
func trimRingCycles(cycles map[string]bool) {
	if len(cycles) <= ringMaxCyclesPerHost {
		return
	}
	keys := make([]string, 0, len(cycles))
	for k := range cycles {
		keys = append(keys, k)
	}
	sort.Strings(keys) // RFC 3339 UTC sorts chronologically
	for _, k := range keys[:len(keys)-ringMaxCyclesPerHost] {
		delete(cycles, k)
	}
}

// trimRingRevisions drops the revisions whose newest cycle is oldest.
func trimRingRevisions(facts ringFacts) {
	if len(facts) <= ringMaxRevisions {
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
	for _, a := range all[:len(all)-ringMaxRevisions] {
		delete(facts, a.revision)
	}
}

// ringCandidate is one revision as the canaries saw it.
type ringCandidate struct {
	Revision     string `json:"revision"`
	FirstSeenUtc string `json:"firstSeenUtc"`
	Passes       int    `json:"passes"`
	Failures     int    `json:"failures"`
}

type ringAnswer struct {
	CanaryMembers      []string        `json:"canaryMembers"`
	RequiredPasses     int             `json:"requiredPasses"`
	QualifyingRevision string          `json:"qualifyingRevision"`
	QualifyingPasses   int             `json:"qualifyingPasses"`
	Revisions          []ringCandidate `json:"revisions"`
}

// qualifyRing answers for one canary list. Only the canaries' cycles count. A
// revision is ordered by the start of the first canary cycle that ran it, not by
// when the collector happened to read it: canaries install the tip in commit
// order, so that start is a commit-order proxy that does not depend on polling
// order or on which host answered first. The qualifying revision is the newest
// one with at least requiredPasses passes; failures do not subtract, and a newer
// revision that has not reached the count leaves the previous answer in place.
// Retired host IDs count for the host that replaced them. view is the locked
// pool view.
func (s *poolState) qualifyRing(view *poolstate.View, canaries []string, requiredPasses int) ringAnswer {
	answer := ringAnswer{CanaryMembers: canaries, RequiredPasses: requiredPasses, Revisions: []ringCandidate{}}
	counted := map[string]bool{}
	for _, id := range canaries {
		counted[view.CanonicalHostID(id)] = true
	}
	var candidates []ringCandidate
	for revision, hosts := range view.Ring {
		c := ringCandidate{Revision: revision}
		for hostID, cycles := range hosts {
			if !counted[view.CanonicalHostID(hostID)] {
				continue
			}
			for cycle, passed := range cycles {
				if c.FirstSeenUtc == "" || cycle < c.FirstSeenUtc {
					c.FirstSeenUtc = cycle
				}
				if passed {
					c.Passes++
				} else {
					c.Failures++
				}
			}
		}
		if c.FirstSeenUtc != "" {
			candidates = append(candidates, c)
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].FirstSeenUtc != candidates[j].FirstSeenUtc {
			return candidates[i].FirstSeenUtc > candidates[j].FirstSeenUtc
		}
		return candidates[i].Revision < candidates[j].Revision
	})
	for _, c := range candidates {
		if c.Passes >= requiredPasses {
			answer.QualifyingRevision = c.Revision
			answer.QualifyingPasses = c.Passes
			break
		}
	}
	if len(candidates) > ringListedRevisions {
		candidates = candidates[:ringListedRevisions]
	}
	answer.Revisions = append(answer.Revisions, candidates...)
	return answer
}

// parseRingQuery reads canary=<id>,<id>... (repeatable) and passes=<n>.
func parseRingQuery(r *http.Request) ([]string, int, string) {
	var canaries []string
	seen := map[string]bool{}
	for _, value := range r.URL.Query()["canary"] {
		for _, part := range strings.Split(value, ",") {
			id := strings.ToLower(strings.TrimSpace(part))
			if id == "" {
				continue
			}
			if !validForgetHostID(id) {
				return nil, 0, "aggregator.framework_ring_canary_invalid"
			}
			if !seen[id] {
				seen[id] = true
				canaries = append(canaries, id)
			}
		}
	}
	if len(canaries) > ringMaxCanaries {
		return nil, 0, "aggregator.framework_ring_canary_invalid"
	}
	passes, err := strconv.Atoi(strings.TrimSpace(r.URL.Query().Get("passes")))
	if err != nil || passes < 1 || passes > ringMaxPasses {
		return nil, 0, "aggregator.framework_ring_passes_invalid"
	}
	sort.Strings(canaries)
	return canaries, passes, ""
}

// handleFrameworkRing is an open read, like pool-status: it names host IDs and
// commits, which that snapshot already publishes, and changes nothing.
func (s *poolState) handleFrameworkRing(w http.ResponseWriter, r *http.Request) {
	canaries, passes, problem := parseRingQuery(r)
	if problem != "" {
		localizedHTTPError(w, r, problem, http.StatusBadRequest)
		return
	}
	if canaries == nil {
		canaries = []string{}
	}
	var answer ringAnswer
	s.st.Do(func(view *poolstate.View) { answer = s.qualifyRing(view, canaries, passes) })
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(answer)
}

// loadRingState restores the facts an earlier run kept. Hosts re-report only the
// cycles still in their recent history, so without this a restart would forget
// the passes that qualified the current revision. An unreadable file is logged
// and the collector starts from what the hosts report next.
func (s *poolState) loadRingState() {
	if s.ringStateFile == "" {
		return
	}
	data, err := os.ReadFile(s.ringStateFile)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	var doc ringStateDoc
	if err == nil {
		err = json.Unmarshal(data, &doc)
	}
	if err == nil && (doc.Version != 1 || doc.Revisions == nil) {
		err = errors.New("unsupported version")
	}
	if err != nil {
		log.Print(operatorMessage("aggregator.log_framework_ring_state_unreadable", map[string]any{"path": s.ringStateFile, "reason": err.Error()}))
		return
	}
	facts := ringFacts{}
	for revision, hosts := range doc.Revisions {
		if !ringRevisionRE.MatchString(revision) {
			continue
		}
		for hostID, cycles := range hosts {
			if !validForgetHostID(hostID) {
				continue
			}
			for cycle, passed := range cycles {
				if _, err := time.Parse(time.RFC3339, cycle); err != nil {
					continue
				}
				if facts[revision] == nil {
					facts[revision] = map[string]map[string]bool{}
				}
				if facts[revision][hostID] == nil {
					facts[revision][hostID] = map[string]bool{}
				}
				facts[revision][hostID][cycle] = passed
			}
			if cycles := facts[revision][hostID]; cycles != nil {
				trimRingCycles(cycles)
			}
		}
	}
	trimRingRevisions(facts)
	s.st.Do(func(view *poolstate.View) { view.Ring = facts })
}

// ringStateSnapshot encodes the locked view's facts for persistRingState, so
// the file write itself can run after the unlock.
func (s *poolState) ringStateSnapshot(view *poolstate.View) []byte {
	if s.ringStateFile == "" {
		return nil
	}
	revisions := view.Ring
	if revisions == nil {
		revisions = ringFacts{}
	}
	data, err := json.Marshal(ringStateDoc{Version: 1, Revisions: revisions})
	if err != nil {
		return nil
	}
	return data
}

// persistRingState replaces the state file atomically. A failed write keeps the
// facts in memory and is logged once until a write succeeds again.
func (s *poolState) persistRingState(data []byte) {
	if s.ringStateFile == "" || data == nil {
		return
	}
	err := writeRingStateFile(s.ringStateFile, data)
	if err != nil {
		if !s.ringWriteFailed {
			log.Print(operatorMessage("aggregator.log_framework_ring_state_unwritten", map[string]any{"path": s.ringStateFile, "reason": err.Error()}))
		}
		s.ringWriteFailed = true
		return
	}
	s.ringWriteFailed = false
}

func writeRingStateFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".framework-ring-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
