// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// The cycle index is the backfill's record of every cycle folder a host holds,
// kept on this machine as <state-dir>/index/<hostId>.json. It answers two
// questions without asking anyone else:
//
//   - "which folder holds this host's cycle at time t?" -- for a timeline click
//     on a cycle weeks old. Rotation files old cycles under history.<date>/
//     buckets named for the day they moved, not the day they ran, so the host's
//     own listing can only answer that by reading bucket after bucket; the
//     backfill has read them anyway. The collector reads the index for /go/cycle.
//   - "how did that cycle end?" -- for every cycle whose event file the backfill
//     read, the outcome it wrote to Loki. The timeline and the incident replay
//     are built from it, because Loki answers for a line stamped days in the past
//     only many minutes after accepting it.
//
// The backfill writes the index; the collector only reads it.
const (
	cycleIndexVersion = 1
	// An index for 90 days of five-minute cycles is about 5 MB.
	maxCycleIndexBytes = 32 << 20
)

// cycleIndex is one host's index file.
type cycleIndex struct {
	Version int               `json:"version"`
	HostID  string            `json:"hostId"`
	Cycles  []cycleIndexEntry `json:"cycles"` // oldest first
}

// cycleIndexEntry is one cycle. RelDir is empty for a cycle only the pool share
// holds; the archive resolver answers for those. The outcome fields are set once
// the backfill has read the cycle's event file, and are what it wrote to Loki.
type cycleIndexEntry struct {
	Identity      string `json:"identity"`
	StartUtc      string `json:"startUtc"`
	RelDir        string `json:"relDir,omitempty"`
	CycleStartUtc string `json:"cycleStartUtc,omitempty"`
	EndUtc        string `json:"endUtc,omitempty"`
	Status        string `json:"status,omitempty"`
	FailureClass  string `json:"failureClass,omitempty"`
}

// indexRelDirRE is the only shape of folder the index may name: a cycle leaf under
// log/, directly or inside one history bucket. The resolved folder ends up in a
// redirect, so nothing else read from the file can steer one.
var indexRelDirRE = regexp.MustCompile(`^log/(?:history\.\d{4}-\d{2}-\d{2}/)?\d{6}\.\d{4}-\d{2}-\d{2}\.\d{2}-\d{2}-\d{2}\.[0-9a-f]{32}(?:\.incomplete|\.aborted\.\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)?/$`)

func cycleIndexPath(stateDir, hostID string) string {
	return filepath.Join(stateDir, indexDirName, strings.ToLower(hostID)+".json")
}

// readCycleIndex reads a host's index, or returns false when there is none that
// this version can trust.
func readCycleIndex(stateDir, hostID string) (cycleIndex, bool) {
	var idx cycleIndex
	data, err := readFileBounded(cycleIndexPath(stateDir, hostID), maxCycleIndexBytes)
	if err != nil || json.Unmarshal(data, &idx) != nil || idx.Version != cycleIndexVersion || !strings.EqualFold(idx.HostID, hostID) {
		return cycleIndex{}, false
	}
	return idx, true
}

// loadCycleOutcomes returns the outcomes the host's index records, by identity.
func loadCycleOutcomes(stateDir, hostID string) map[string]cycleOutcome {
	out := map[string]cycleOutcome{}
	idx, ok := readCycleIndex(stateDir, hostID)
	if !ok {
		return out
	}
	for _, e := range idx.Cycles {
		start, okStart := parseUTC(e.CycleStartUtc)
		end, okEnd := parseUTC(e.EndUtc)
		if e.Status == "" || !okStart || !okEnd {
			continue
		}
		out[e.Identity] = cycleOutcome{CycleStartUtc: e.CycleStartUtc, Start: start, End: end, Status: e.Status, FailureClass: e.FailureClass}
	}
	return out
}

// knownFolders returns the folders the host's cycle index records, for a pass
// that does not list the host. An entry is taken only when its identity is one of
// this host's cycles, and its folder only in the one shape the index may name.
func knownFolders(stateDir, hostID string) map[string]cycleFolder {
	out := map[string]cycleFolder{}
	idx, ok := readCycleIndex(stateDir, hostID)
	if !ok {
		return out
	}
	for _, e := range idx.Cycles {
		if !archiveCycleRe.MatchString(e.Identity) || !strings.HasSuffix(e.Identity, "."+hostID) {
			continue
		}
		start, ok := cycleStartFromFolder(e.Identity)
		if !ok {
			continue
		}
		cf := cycleFolder{Identity: e.Identity, Start: start}
		if indexRelDirRE.MatchString(e.RelDir) {
			cf.RelDir = e.RelDir
		}
		out[e.Identity] = cf
	}
	return out
}

// writeCycleIndex replaces the host's index with the folders just discovered and
// the outcomes known for them. An unchanged index is not rewritten, so a quiet
// pool does not rewrite every file every sweep.
func writeCycleIndex(stateDir, hostID string, folders map[string]cycleFolder, outcomes map[string]cycleOutcome) error {
	idx := cycleIndex{Version: cycleIndexVersion, HostID: hostID, Cycles: make([]cycleIndexEntry, 0, len(folders))}
	for _, cf := range folders {
		e := cycleIndexEntry{Identity: cf.Identity, StartUtc: formatUTC(cf.Start), RelDir: cf.RelDir}
		if o, ok := outcomes[cf.Identity]; ok {
			e.CycleStartUtc, e.EndUtc, e.Status, e.FailureClass = o.CycleStartUtc, formatUTC(o.End), o.Status, o.FailureClass
		}
		idx.Cycles = append(idx.Cycles, e)
	}
	sort.Slice(idx.Cycles, func(i, j int) bool {
		if idx.Cycles[i].StartUtc != idx.Cycles[j].StartUtc {
			return idx.Cycles[i].StartUtc < idx.Cycles[j].StartUtc
		}
		return idx.Cycles[i].Identity < idx.Cycles[j].Identity
	})
	path := cycleIndexPath(stateDir, hostID)
	want, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	if have, err := os.ReadFile(path); err == nil && bytes.Equal(bytes.TrimSpace(have), want) {
		return nil
	}
	return writeJSONAtomic(path, idx, 0o644)
}

// resolveFolderByIndex returns the folder of the cycle active at t from the host's
// cycle index -- the one that started last at or before t -- or "" when the index
// cannot say. It answers only between two listed starts: after the newest one a
// cycle may have begun since the index was written, and before the oldest the
// index knows nothing.
func (s *poolState) resolveFolderByIndex(hostID string, t time.Time) string {
	if s.backfillStateDir == "" || !hostIDRe.MatchString(hostID) || t.IsZero() {
		return ""
	}
	idx, ok := readCycleIndex(s.backfillStateDir, hostID)
	if !ok {
		return ""
	}
	at := formatUTC(t)
	// The first entry that started after t; the one before it is the answer.
	next := sort.Search(len(idx.Cycles), func(i int) bool { return idx.Cycles[i].StartUtc > at })
	if next == 0 || next == len(idx.Cycles) {
		return ""
	}
	rel := idx.Cycles[next-1].RelDir
	if !indexRelDirRE.MatchString(rel) {
		return ""
	}
	return rel
}
