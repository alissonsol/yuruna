// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"stash-server/internal/config"
	"stash-server/internal/id"
	"stash-server/internal/meta"
	"stash-server/internal/store"
)

// newTestServer builds a Server with the storage layers wired but no SSH
// config (the flush path needs none) and an injectable ShareOnline.
func newTestServer(t *testing.T, online bool) *Server {
	t.Helper()
	shareStore, err := store.New(t.TempDir())
	if err != nil {
		t.Fatalf("share store: %v", err)
	}
	bufStore, err := store.NewFilesOnly(t.TempDir())
	if err != nil {
		t.Fatalf("buffer store: %v", err)
	}
	m, err := meta.Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatalf("meta open: %v", err)
	}
	t.Cleanup(func() { _ = m.Close() })
	return &Server{
		Store:        shareStore,
		Buffer:       bufStore,
		Meta:         m,
		IDs:          id.New(shareStore.FilesRoot(), bufStore.FilesRoot()),
		ShareOnline:  func() bool { return online },
		flushTrigger: make(chan struct{}, 1),
	}
}

// seedBuffered drops a buffered artifact on disk and records it as a
// completed-but-still-buffered upload, mimicking an offline receive.
func seedBuffered(t *testing.T, s *Server, id, name string, content []byte) string {
	t.Helper()
	now := time.Date(2026, 6, 14, 16, 0, 0, 0, time.UTC)
	dayDir := filepath.Join(s.Buffer.FilesRoot(), "2026", "06", "14")
	if err := os.MkdirAll(dayDir, 0o700); err != nil {
		t.Fatal(err)
	}
	artifact := filepath.Join(dayDir, id+filepath.Ext(name))
	if err := os.WriteFile(artifact, content, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Meta.InsertPending(&meta.Record{ID: id, Username: "u", CreatedAt: now, Status: meta.StatusPending, LocallyBuffered: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.Meta.UpdateOnComplete(id, artifact, name, false, meta.StatusComplete, int64(len(content)), now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	return artifact
}

func TestFlushOnceMovesBufferedToShare(t *testing.T) {
	s := newTestServer(t, true)
	content := []byte("buffered payload")
	bufArtifact := seedBuffered(t, s, "a1b2", "note.txt", content)

	s.flushOnce()

	shareArtifact := filepath.Join(s.Store.FilesRoot(), "2026", "06", "14", "a1b2.txt")
	got, err := os.ReadFile(shareArtifact)
	if err != nil {
		t.Fatalf("artifact not on share: %v", err)
	}
	if string(got) != string(content) {
		t.Fatalf("share content = %q, want %q", got, content)
	}
	// Sidecar written on the share next to the artifact.
	sidecar := filepath.Join(s.Store.FilesRoot(), "2026", "06", "14", "a1b2"+config.SidecarExtension)
	if _, err := os.Stat(sidecar); err != nil {
		t.Fatalf("sidecar not written on share: %v", err)
	}
	// Local buffer copy removed.
	if _, err := os.Stat(bufArtifact); !os.IsNotExist(err) {
		t.Fatalf("buffer copy still present (err=%v)", err)
	}
	// Record now committed.
	rec, err := s.Meta.Get("a1b2")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if rec.LocallyBuffered || rec.StoredPath != shareArtifact {
		t.Fatalf("record not committed: buffered=%v path=%q", rec.LocallyBuffered, rec.StoredPath)
	}
	if listed, _ := s.Meta.ListBuffered(); len(listed) != 0 {
		t.Fatalf("ListBuffered = %+v, want empty", listed)
	}
}

func TestFlushOnceNoOpWhenShareOffline(t *testing.T) {
	s := newTestServer(t, false)
	seedBuffered(t, s, "c3d4", "x.bin", []byte("still buffered"))

	s.flushOnce() // share offline: must not touch anything

	if listed, _ := s.Meta.ListBuffered(); len(listed) != 1 {
		t.Fatalf("offline flush drained the buffer; ListBuffered = %+v", listed)
	}
}

func TestFlushRecordIsIdempotent(t *testing.T) {
	s := newTestServer(t, true)
	seedBuffered(t, s, "e5f6", "doc.pdf", []byte("idempotent"))

	s.flushOnce()
	// A second pass with the record already flushed must be a clean no-op
	// (nothing left buffered, no error path).
	s.flushOnce()

	if listed, _ := s.Meta.ListBuffered(); len(listed) != 0 {
		t.Fatalf("ListBuffered after double flush = %+v, want empty", listed)
	}
}
