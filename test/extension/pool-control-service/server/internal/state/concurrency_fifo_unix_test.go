// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42c84284-e34b-41ce-acf2-7439b4a886ea

//go:build !windows

package state

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// /healthz is served from the snapshot, and it is how a launcher tells whether
// the daemon is up. A write stuck on a share that stopped answering must not
// hold the snapshot: here the audit log is a FIFO with no reader, which blocks
// the append the way a hung CIFS server does.
func TestHealthAnswersWhileAWriteIsStuck(t *testing.T) {
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
