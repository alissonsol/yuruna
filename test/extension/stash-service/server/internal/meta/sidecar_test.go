// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package meta

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"stash-server/internal/config"
)

// TestSidecarRoundTrip writes a sidecar for a committed record, then —
// against a FRESH (empty) index, simulating a reimaged VM — rebuilds from
// the on-share sidecars and confirms the record comes back intact (§8.5).
func TestSidecarRoundTrip(t *testing.T) {
	share := t.TempDir()
	dayDir := filepath.Join(share, "files", "2026", "06", "14")
	if err := os.MkdirAll(dayDir, 0o700); err != nil {
		t.Fatalf("mkdir dayDir: %v", err)
	}
	// The artifact the sidecar describes (content irrelevant here).
	artifact := filepath.Join(dayDir, "a1b2.pdf")
	if err := os.WriteFile(artifact, []byte("hello"), 0o600); err != nil {
		t.Fatalf("write artifact: %v", err)
	}

	received := time.Date(2026, 6, 14, 16, 41, 30, 0, time.UTC)
	rec := &Record{
		ID:               "a1b2",
		StoredPath:       artifact,
		OriginalFilename: "Quarterly Report.PDF",
		IsArchive:        false,
		Username:         "alice",
		PathMetadata:     "/scratch",
		ClientAddress:    "192.168.1.50",
		CreatedAt:        received.Add(-2 * time.Second),
		ReceivedAt:       &received,
		Status:           StatusComplete,
		SizeBytes:        5,
	}

	if err := WriteSidecar(rec); err != nil {
		t.Fatalf("WriteSidecar: %v", err)
	}
	sidecar := filepath.Join(dayDir, "a1b2"+config.SidecarExtension)
	if _, err := os.Stat(sidecar); err != nil {
		t.Fatalf("sidecar not written: %v", err)
	}

	// Fresh index (reimage): empty DB, rebuild from the share.
	m, err := Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer m.Close()

	if n, err := m.Count(); err != nil || n != 0 {
		t.Fatalf("fresh index Count = %d, %v; want 0, nil", n, err)
	}
	restored, err := m.RebuildFromSidecars(filepath.Join(share, "files"))
	if err != nil {
		t.Fatalf("RebuildFromSidecars: %v", err)
	}
	if restored != 1 {
		t.Fatalf("restored %d records, want 1", restored)
	}

	got, err := m.Get("a1b2")
	if err != nil {
		t.Fatalf("Get after rebuild: %v", err)
	}
	if got.OriginalFilename != rec.OriginalFilename ||
		got.Username != rec.Username ||
		got.PathMetadata != rec.PathMetadata ||
		got.ClientAddress != rec.ClientAddress ||
		got.Status != rec.Status ||
		got.SizeBytes != rec.SizeBytes {
		t.Fatalf("rebuilt record mismatch:\n got %+v\nwant %+v", got, rec)
	}
	if got.ReceivedAt == nil || !got.ReceivedAt.Equal(received) {
		t.Fatalf("rebuilt receivedAt = %v, want %v", got.ReceivedAt, received)
	}
}

// TestRebuildFromSidecarsMissingRoot confirms a brand-new share (no files/
// tree yet) is a clean no-op, not an error.
func TestRebuildFromSidecarsMissingRoot(t *testing.T) {
	m, err := Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer m.Close()

	n, err := m.RebuildFromSidecars(filepath.Join(t.TempDir(), "does-not-exist", "files"))
	if err != nil {
		t.Fatalf("RebuildFromSidecars on missing root: %v", err)
	}
	if n != 0 {
		t.Fatalf("restored %d, want 0", n)
	}
}
