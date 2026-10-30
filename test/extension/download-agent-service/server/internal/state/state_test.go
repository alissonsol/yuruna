// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42f3242c-4c61-4c7a-9b1c-4366e142a3da

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestDisabledStoreIsInert(t *testing.T) {
	s := New("", "agent-a", time.Now())
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
	s := New(dir, "agent-a", time.Now())
	now := time.Now()
	s.Record(now, AuditEntry{
		AtUTC: now.UTC().Format(time.RFC3339), Action: "delete",
		HostType: "ubuntu.kvm", ImageKey: "guest.ubuntu.server.26", Arch: "amd64", Variant: "stable",
		Outcome: "ok",
	})
	s.Record(now, AuditEntry{AtUTC: now.UTC().Format(time.RFC3339), Action: "prune", Outcome: "ok"})

	b, err := os.ReadFile(filepath.Join(dir, AuditFile("agent-a")))
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
	sb, err := os.ReadFile(filepath.Join(dir, StatusFile("agent-a")))
	if err != nil {
		t.Fatalf("status file: %v", err)
	}
	var persisted Status
	if err := json.Unmarshal(sb, &persisted); err != nil {
		t.Fatalf("status file is not JSON: %v", err)
	}
	if persisted.Actions != 2 {
		t.Fatalf("persisted status = %+v", persisted)
	}
}

func TestTargetCarriesTheFullIdentity(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, "agent-a", time.Now())
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
	s := New(dir, "agent-a", time.Now())
	// Block the audit path with a directory so its append cannot succeed. The
	// mutation has already happened by the time this runs; losing the record
	// must degrade health, not the service.
	if err := os.MkdirAll(filepath.Join(dir, AuditFile("agent-a")), 0o755); err != nil {
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
	s := New(t.TempDir(), "agent-a", time.Now())
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
	s := New(t.TempDir(), "agent-a", time.Now())
	now := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)
	s.Record(now, AuditEntry{Action: "prune", Outcome: "ok"})
	if got := s.Health().LastActionUTC; got != now.Format(time.RFC3339) {
		t.Fatalf("lastActionUtc = %q, want the caller's clock reading", got)
	}
}

func TestBeatTracksPoolAvailability(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, "agent-a", time.Now())
	s.Beat(time.Now(), false)
	if h := s.Health(); h.PoolAvailable || h.HeartbeatUTC == "" {
		t.Fatalf("health = %+v", h)
	}
	s.Beat(time.Now(), true)
	if h := s.Health(); !h.PoolAvailable {
		t.Fatal("a recovered pool must be reflected in the heartbeat")
	}
}

func TestIndependentStoresPublishCompleteStatusSnapshots(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the service runs on Linux; Windows rejects concurrent renames onto one target with access denied")
	}
	dir := t.TempDir()
	stores := make([]*Store, 8)
	for i := range stores {
		stores[i] = New(dir, "agent-a", time.Now())
	}
	errs := make(chan error, len(stores))
	for _, s := range stores {
		go func(s *Store) {
			for i := 0; i < 100; i++ {
				if err := s.writeStatus(Status{Actions: i, Healthy: true}); err != nil {
					errs <- err
					return
				}
			}
			errs <- nil
		}(s)
	}
	for range stores {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	b, err := os.ReadFile(filepath.Join(dir, StatusFile("agent-a")))
	if err != nil {
		t.Fatal(err)
	}
	var status Status
	if err := json.Unmarshal(b, &status); err != nil {
		t.Fatalf("partial status: %v", err)
	}
	names, err := filepath.Glob(filepath.Join(dir, "."+StatusFile("agent-a")+".tmp-*"))
	if err != nil || len(names) != 0 {
		t.Fatalf("temporary files left behind: %v %v", names, err)
	}
}

// Every agent of a pool shares the state directory on the share, where an
// append is not atomic across clients. Each agent therefore keeps its own log
// and status, so one agent's lines and snapshot are never another's to tear.
func TestAgentsSharingADirectoryKeepTheirOwnFiles(t *testing.T) {
	dir := t.TempDir()
	a := New(dir, "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", time.Now())
	b := New(dir, "host/with:odd name", time.Now())
	a.Record(time.Now(), AuditEntry{Action: "delete", Outcome: "ok"})
	b.Record(time.Now(), AuditEntry{Action: "prune", Outcome: "ok"})
	b.Record(time.Now(), AuditEntry{Action: "refresh", Outcome: "ok"})

	read := func(name string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		return string(data)
	}
	if got := strings.Count(read(AuditFile("42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")), "\n"); got != 1 {
		t.Fatalf("first agent's log holds %d line(s), want its own 1", got)
	}
	if got := strings.Count(read(AuditFile("host/with:odd name")), "\n"); got != 2 {
		t.Fatalf("second agent's log holds %d line(s), want its own 2", got)
	}
	var sa, sb Status
	if err := json.Unmarshal([]byte(read(StatusFile("42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))), &sa); err != nil || sa.Actions != 1 {
		t.Fatalf("first agent's status = %+v (%v), want its own 1 action", sa, err)
	}
	if err := json.Unmarshal([]byte(read(StatusFile("host/with:odd name"))), &sb); err != nil || sb.Actions != 2 {
		t.Fatalf("second agent's status = %+v (%v), want its own 2 actions", sb, err)
	}
	if name := AuditFile("host/with:odd name"); strings.ContainsAny(name, "/: ") {
		t.Fatalf("audit file name %q carries characters a share may refuse", name)
	}
	if _, err := os.Stat(filepath.Join(dir, "audit.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("a shared audit.jsonl was written (stat err = %v)", err)
	}
}
