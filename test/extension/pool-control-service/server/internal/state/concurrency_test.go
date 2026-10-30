// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42a3f7c2-6d91-4e0b-b8c5-17f2e9a4d036

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
	"time"
)

// /healthz is served from the snapshot, and it is how a launcher tells whether
// the daemon is up. A write stuck on a share that stopped answering must not
// hold the snapshot: here the audit log is a FIFO with no reader, which blocks
// the append the way a hung CIFS server does.
func TestHealthAnswersWhileAWriteIsStuck(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs a FIFO")
	}
	dir := t.TempDir()
	fifo := filepath.Join(dir, "audit.jsonl")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Skipf("cannot make a FIFO here: %v", err)
	}
	s := New(dir, time.Now())
	recorded := make(chan struct{})
	go func() {
		s.Record(time.Now(), AuditEntry{Publish: true, TimeUTC: time.Now().UTC().Format(time.RFC3339), Action: "new-pool", OK: true})
		close(recorded)
	}()
	time.Sleep(100 * time.Millisecond)
	answered := make(chan Status, 1)
	go func() { answered <- s.Health() }()
	select {
	case h := <-answered:
		if h.Writes != 1 {
			t.Errorf("health = %+v, want the counted write", h)
		}
	case <-time.After(2 * time.Second):
		t.Error("Health waited on a stuck write")
	}
	// Release the append so the writer goroutine ends.
	if r, err := os.OpenFile(fifo, os.O_RDONLY|syscall.O_NONBLOCK, 0); err == nil {
		defer r.Close()
	}
	select {
	case <-recorded:
	case <-time.After(5 * time.Second):
		t.Fatal("the stuck write never finished")
	}
}

// Two daemons on one share, or one daemon's writes racing each other, each
// publish whole snapshots: a fixed temp name lets one writer rename another's
// half away and report a failure that is not there.
func TestIndependentStoresPublishCompleteStatusSnapshots(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the service runs on Linux; Windows rejects concurrent renames onto one target")
	}
	dir := t.TempDir()
	stores := make([]*Store, 8)
	for i := range stores {
		stores[i] = New(dir, time.Now())
	}
	done := make(chan struct{})
	for _, s := range stores {
		go func(s *Store) {
			for i := 0; i < 50; i++ {
				s.Beat(time.Now(), true)
			}
			done <- struct{}{}
		}(s)
	}
	for range stores {
		<-done
	}
	for i, s := range stores {
		if h := s.Health(); !h.Healthy {
			t.Errorf("store %d reports %q", i, h.LastError)
		}
	}
	b, err := os.ReadFile(filepath.Join(dir, "status.json"))
	if err != nil {
		t.Fatal(err)
	}
	var st Status
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatalf("partial status: %v", err)
	}
	if leftovers, _ := filepath.Glob(filepath.Join(dir, "*.tmp*")); len(leftovers) != 0 {
		t.Fatalf("temporary files left behind: %v", leftovers)
	}
}
