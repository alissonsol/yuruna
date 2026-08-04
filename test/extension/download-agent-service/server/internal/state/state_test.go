// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDisabledStoreIsInert(t *testing.T) {
	s := New("", time.Now())
	if s.Enabled() {
		t.Fatal("an empty state dir must leave the store disabled")
	}
	s.Record(time.Now(), AuditEntry{Action: "delete", Outcome: "ok"})
	s.Beat(time.Now(), true)
	if h := s.Health(); !h.Healthy {
		t.Fatalf("a disabled store must still report healthy: %+v", h)
	}
}

func TestRecordAppendsOneJSONLineAndRefreshesStatus(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, time.Now())
	now := time.Now()
	s.Record(now, AuditEntry{
		AtUTC: now.UTC().Format(time.RFC3339), Action: "delete",
		HostType: "ubuntu.kvm", ImageKey: "guest.ubuntu.server.26", Arch: "amd64", Variant: "stable",
		Outcome: "ok",
	})
	s.Record(now, AuditEntry{AtUTC: now.UTC().Format(time.RFC3339), Action: "prune", Outcome: "ok"})

	b, err := os.ReadFile(filepath.Join(dir, "audit.jsonl"))
	if err != nil {
		t.Fatalf("audit log: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 2 {
		t.Fatalf("audit log has %d lines, want 2", len(lines))
	}
	var first AuditEntry
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("line 1 is not JSON: %v", err)
	}
	if first.Action != "delete" || first.ImageKey != "guest.ubuntu.server.26" || first.Variant != "stable" {
		t.Fatalf("line 1 lost the image identity: %+v", first)
	}

	h := s.Health()
	if h.Actions != 2 || h.LastAction != "prune" || !h.Healthy {
		t.Fatalf("health = %+v", h)
	}
	sb, err := os.ReadFile(filepath.Join(dir, "status.json"))
	if err != nil {
		t.Fatalf("status.json: %v", err)
	}
	var persisted Status
	if err := json.Unmarshal(sb, &persisted); err != nil {
		t.Fatalf("status.json is not JSON: %v", err)
	}
	if persisted.Actions != 2 {
		t.Fatalf("persisted status = %+v", persisted)
	}
}

func TestTargetCarriesTheFullIdentity(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, time.Now())
	s.Record(time.Now(), AuditEntry{
		Action: "refresh", HostType: "macos.utm", ImageKey: "ubuntu.extension.26",
		Arch: "arm64", Variant: "stable", Outcome: "ok",
	})
	if got := s.Health().LastTarget; got != "macos.utm/ubuntu.extension.26/arm64/stable" {
		t.Fatalf("LastTarget = %q", got)
	}
}

func TestAWriteFailureIsRecordedInHealthWhileTheMutationProceeds(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, time.Now())
	// Block the audit path with a directory so its append cannot succeed. The
	// mutation has already happened by the time this runs; losing the record
	// must degrade health, not the service.
	if err := os.MkdirAll(filepath.Join(dir, "audit.jsonl"), 0o755); err != nil {
		t.Fatal(err)
	}
	s.Record(time.Now(), AuditEntry{Action: "delete", Outcome: "ok"})

	h := s.Health()
	if h.Healthy {
		t.Fatal("an audit write failure must surface as unhealthy")
	}
	if !strings.Contains(h.LastError, "audit write") {
		t.Fatalf("LastError = %q, want it to name the audit write", h.LastError)
	}
	if h.Actions != 1 {
		t.Fatalf("the mutation must still be counted: %+v", h)
	}
}

func TestHealthStaysReadableWhileTheStoreIsWriting(t *testing.T) {
	// /healthz is what the launcher polls to decide the daemon is up, and it is
	// served from this snapshot. The snapshot lock must therefore never be held
	// across a write to the share: a NAS that stops answering would otherwise
	// hang the one endpoint whose whole job is to answer while the share is
	// sick. Run under -race, this also pins the two-lock discipline itself.
	const rounds = 200
	s := New(t.TempDir(), time.Now())
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < rounds; i++ {
			s.Record(time.Now(), AuditEntry{Action: "refresh", Outcome: "ok"})
			s.Beat(time.Now(), true)
		}
	}()
	for {
		select {
		case <-done:
			if h := s.Health(); h.Actions != rounds {
				t.Fatalf("actions = %d, want %d", h.Actions, rounds)
			}
			return
		default:
			_ = s.Health()
		}
	}
}

func TestRecordStampsAnEntryThatCarriesNoTime(t *testing.T) {
	s := New(t.TempDir(), time.Now())
	now := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)
	s.Record(now, AuditEntry{Action: "prune", Outcome: "ok"})
	if got := s.Health().LastActionUTC; got != now.Format(time.RFC3339) {
		t.Fatalf("lastActionUtc = %q, want the caller's clock reading", got)
	}
}

func TestBeatTracksPoolAvailability(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, time.Now())
	s.Beat(time.Now(), false)
	if h := s.Health(); h.PoolAvailable || h.HeartbeatUTC == "" {
		t.Fatalf("health = %+v", h)
	}
	s.Beat(time.Now(), true)
	if h := s.Health(); !h.PoolAvailable {
		t.Fatal("a recovered pool must be reflected in the heartbeat")
	}
}
