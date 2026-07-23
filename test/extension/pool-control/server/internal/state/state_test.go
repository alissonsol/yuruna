// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRecordWritesAuditAndStatus(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	s := New(filepath.Join(dir, "pool-control"), now)
	if !s.Enabled() {
		t.Fatal("store with a dir must be Enabled")
	}
	s.Record(now, AuditEntry{TimeUTC: now.Format(time.RFC3339), Action: "new-pool", Target: "lab", OK: true})

	audit, err := os.ReadFile(filepath.Join(dir, "pool-control", "audit.jsonl"))
	if err != nil || !strings.Contains(string(audit), `"action":"new-pool"`) {
		t.Fatalf("audit.jsonl missing the entry: %v %q", err, string(audit))
	}
	st := s.Health()
	if !st.Healthy || st.Writes != 1 || st.LastAction != "new-pool" || !st.LastPublishOK {
		t.Fatalf("status not updated: %+v", st)
	}
	if _, err := os.Stat(filepath.Join(dir, "pool-control", "status.json")); err != nil {
		t.Fatalf("status.json not written: %v", err)
	}
}

func TestAuditSurvivesRestart(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "pc")
	now := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	s1 := New(dir, now)
	s1.Record(now, AuditEntry{TimeUTC: now.Format(time.RFC3339), Action: "new-pool", Target: "lab", OK: true})
	// A fresh Store (a service restart) appends to the same audit log; prior lines survive.
	s2 := New(dir, now.Add(time.Minute))
	s2.Record(now.Add(time.Minute), AuditEntry{TimeUTC: now.Add(time.Minute).Format(time.RFC3339), Action: "assign-testset", Target: "lab", OK: true})
	audit, _ := os.ReadFile(filepath.Join(dir, "audit.jsonl"))
	lines := strings.Count(strings.TrimSpace(string(audit)), "\n") + 1
	if lines != 2 || !strings.Contains(string(audit), "new-pool") || !strings.Contains(string(audit), "assign-testset") {
		t.Fatalf("audit log must accumulate across restarts; got %d line(s):\n%s", lines, string(audit))
	}
}

func TestDisabledStoreIsNoOp(t *testing.T) {
	s := New("", time.Now())
	if s.Enabled() {
		t.Fatal("empty dir must be disabled")
	}
	s.Record(time.Now(), AuditEntry{Action: "x", OK: true}) // must not panic / touch disk
	if !s.Health().Healthy {
		t.Fatal("disabled store reports healthy")
	}
}

func TestBeatUpdatesHeartbeat(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "pc")
	now := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	s := New(dir, now)
	s.Beat(now.Add(30*time.Second), true)
	st := s.Health()
	if st.HeartbeatUTC == "" || !st.IntentReadable {
		t.Fatalf("beat did not update heartbeat/intent-readable: %+v", st)
	}
}
