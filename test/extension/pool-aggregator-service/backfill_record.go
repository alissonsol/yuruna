// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"time"
)

// maxBackfillLineBytes keeps a single oversized event line from failing a whole
// Loki batch: Loki refuses a push containing any line over its 256 KB limit.
const maxBackfillLineBytes = 200 << 10

// cycleRecord is one finished cycle as its event file describes it.
type cycleRecord struct {
	// CycleStartUtc is the cycle's key exactly as the host wrote it, so a
	// backfilled line names the same cycle a live line does.
	CycleStartUtc string
	Start         time.Time
	End           time.Time
	// Status is the overallStatus the host's status.json recorded for the cycle:
	// pass, fail, or skipped for a cycle a host refresh aborted.
	Status string
	// FailureClass is set on a fail: the class of the last step failure in the
	// file, or "unknown" when nothing classified the failure.
	FailureClass string
	// Lines are the file's events with line endings trimmed, and Stamps their
	// Loki timestamps in Unix nanoseconds, index for index.
	Lines  []string
	Stamps []int64
}

// cycleOutcome is how a cycle ended, as the backfill wrote it to Loki.
type cycleOutcome struct {
	CycleStartUtc string
	Start, End    time.Time
	Status        string
	FailureClass  string
}

func outcomeOf(rec cycleRecord) cycleOutcome {
	return cycleOutcome{CycleStartUtc: rec.CycleStartUtc, Start: rec.Start, End: rec.End, Status: rec.Status, FailureClass: rec.FailureClass}
}

// statusForOutcome maps a cycle_end outcome to the overallStatus the runner wrote
// for the same cycle. A cycle a host refresh aborted is "skipped", which the
// dashboard counts as neither pass nor fail; every other aborted or unknown end
// is a failed cycle, as the runner records it.
func statusForOutcome(outcome, reason string) string {
	switch outcome {
	case "pass":
		return "pass"
	case "aborted":
		if strings.Contains(strings.ToLower(reason), "host refresh") {
			return "skipped"
		}
		return "fail"
	default:
		return "fail"
	}
}

// reconstructCycle reads a cycle's event file.
//
// A file with no cycle_end belongs to a cycle whose process was killed: the
// runner records such a cycle as failed, and its last event is the last moment
// anything was known about it. Event lines without a timestamp of their own (the
// orchestrator's step.start and step.end) take the previous event's, so a replay
// of the same file always produces the same Loki entries.
func reconstructCycle(cf cycleFolder, data []byte) cycleRecord {
	rec := cycleRecord{Start: cf.Start}
	var cycleStart, endAt, outcome, reason, lastClass string
	sawEnd := false
	last := cf.Start
	for _, raw := range bytes.Split(data, []byte{'\n'}) {
		line := strings.TrimRight(string(raw), "\r")
		if strings.TrimSpace(line) == "" || len(line) > maxBackfillLineBytes {
			continue
		}
		var e struct {
			Event         string `json:"event"`
			Timestamp     string `json:"timestamp"`
			CycleStartUtc string `json:"cycleStartUtc"`
			CycleID       string `json:"cycleId"`
			Outcome       string `json:"outcome"`
			Reason        string `json:"reason"`
			FailureClass  string `json:"failureClass"`
		}
		if json.Unmarshal([]byte(line), &e) != nil {
			continue
		}
		if t, ok := parseUTC(e.Timestamp); ok {
			last = t
		}
		if cycleStart == "" {
			if e.CycleStartUtc != "" {
				cycleStart = e.CycleStartUtc
			} else if e.CycleID != "" {
				cycleStart = e.CycleID
			}
		}
		switch e.Event {
		case "cycle_end":
			sawEnd = true
			endAt, outcome, reason = e.Timestamp, e.Outcome, e.Reason
		case "step_failure":
			if e.FailureClass != "" {
				lastClass = e.FailureClass
			}
		}
		rec.Lines = append(rec.Lines, redactEventLine(line))
		rec.Stamps = append(rec.Stamps, last.UnixNano())
	}
	if t, ok := parseUTC(cycleStart); ok {
		rec.CycleStartUtc = strings.TrimSpace(cycleStart)
		rec.Start = t
	} else {
		rec.CycleStartUtc = formatUTC(cf.Start)
	}
	if t, ok := parseUTC(endAt); sawEnd && ok {
		rec.End = t
		rec.Status = statusForOutcome(outcome, reason)
	} else {
		rec.End = last
		rec.Status = "fail"
	}
	if rec.End.Before(rec.Start) {
		rec.End = rec.Start
	}
	if rec.Status == "fail" {
		rec.FailureClass = lastClass
		if rec.FailureClass == "" {
			rec.FailureClass = "unknown"
		}
	}
	return rec
}
