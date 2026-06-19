// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package meta

import (
	"path/filepath"
	"testing"
	"time"
)

// TestBufferedLifecycle walks an upload that lands in the offline buffer
// (§8.4): pending(buffered) -> complete(still buffered) -> flushed. It
// guards the easy-to-miss invariant that UpdateOnComplete must NOT clear
// locallyBuffered, and that ListBuffered tracks the flag both ways.
func TestBufferedLifecycle(t *testing.T) {
	m, err := Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer m.Close()

	now := time.Date(2026, 6, 14, 16, 0, 0, 0, time.UTC)

	// A normal (on-share) upload — must never appear in ListBuffered.
	if err := m.InsertPending(&Record{ID: "shr1", Username: "u", CreatedAt: now, Status: StatusPending}); err != nil {
		t.Fatalf("insert on-share pending: %v", err)
	}
	// A buffered upload.
	if err := m.InsertPending(&Record{ID: "buf1", Username: "u", CreatedAt: now, Status: StatusPending, LocallyBuffered: true}); err != nil {
		t.Fatalf("insert buffered pending: %v", err)
	}

	// Complete the buffered one — the flag must survive.
	if err := m.UpdateOnComplete("buf1", "/var/lib/stash-server/buffer/files/2026/06/14/buf1.txt", "note.txt", false, StatusComplete, 12, now.Add(time.Second)); err != nil {
		t.Fatalf("UpdateOnComplete: %v", err)
	}

	listed, err := m.ListBuffered()
	if err != nil {
		t.Fatalf("ListBuffered: %v", err)
	}
	if len(listed) != 1 || listed[0].ID != "buf1" {
		t.Fatalf("ListBuffered = %+v, want exactly [buf1]", listed)
	}
	if !listed[0].LocallyBuffered {
		t.Fatalf("UpdateOnComplete cleared locallyBuffered; want it preserved")
	}

	// Flush: storedPath moves to the share, flag clears.
	sharePath := "/mnt/ystash-nas/stash/HOST/files/2026/06/14/buf1.txt"
	if err := m.UpdateOnFlushed("buf1", sharePath); err != nil {
		t.Fatalf("UpdateOnFlushed: %v", err)
	}
	if listed, err := m.ListBuffered(); err != nil || len(listed) != 0 {
		t.Fatalf("ListBuffered after flush = %+v, %v; want empty", listed, err)
	}
	got, err := m.Get("buf1")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.LocallyBuffered {
		t.Fatalf("flushed record still marked locallyBuffered")
	}
	if got.StoredPath != sharePath {
		t.Fatalf("storedPath = %q, want %q", got.StoredPath, sharePath)
	}
}
