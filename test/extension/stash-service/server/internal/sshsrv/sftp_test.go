// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"stash-server/internal/config"
	"stash-server/internal/meta"
)

// TestSFTPUploadStoresArtifactAndSidecar drives the SFTP ingest the way
// pkg/sftp would (newSFTPUpload -> WriteAt -> Close) and verifies the file
// lands in the stash with the right metadata + a sidecar, with the path
// captured as metadata (not used as a location, §5.1).
func TestSFTPUploadStoresArtifactAndSidecar(t *testing.T) {
	s := newTestServer(t, true) // share online -> stores on the share store
	up, err := s.newSFTPUpload("/scratch/report.PDF", "alice", "10.0.0.5")
	if err != nil {
		t.Fatalf("newSFTPUpload: %v", err)
	}
	data := []byte("hello sftp world")
	if n, err := up.WriteAt(data, 0); err != nil || n != len(data) {
		t.Fatalf("WriteAt = %d,%v; want %d,nil", n, err, len(data))
	}
	if err := up.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	rec, err := s.Meta.Get(up.id)
	if err != nil {
		t.Fatalf("Get(%s): %v", up.id, err)
	}
	if rec.Status != meta.StatusComplete || rec.LocallyBuffered {
		t.Fatalf("status=%s buffered=%v; want complete/false", rec.Status, rec.LocallyBuffered)
	}
	if rec.OriginalFilename != "report.PDF" {
		t.Fatalf("originalFilename=%q; want report.PDF (original case)", rec.OriginalFilename)
	}
	if rec.PathMetadata != "/scratch/report.PDF" {
		t.Fatalf("pathMetadata=%q; want /scratch/report.PDF", rec.PathMetadata)
	}
	if rec.Username != "alice" || rec.ClientAddress != "10.0.0.5" {
		t.Fatalf("username=%q client=%q; want alice/10.0.0.5", rec.Username, rec.ClientAddress)
	}
	// On-disk name is <id>.pdf (extension lowercased, §6.3); content intact.
	if !strings.HasSuffix(rec.StoredPath, up.id+".pdf") {
		t.Fatalf("storedPath=%q; want suffix %s.pdf", rec.StoredPath, up.id)
	}
	got, err := os.ReadFile(rec.StoredPath)
	if err != nil || string(got) != string(data) {
		t.Fatalf("artifact read=%q err=%v; want %q", got, err, data)
	}
	sidecar := filepath.Join(filepath.Dir(rec.StoredPath), up.id+config.SidecarExtension)
	if _, err := os.Stat(sidecar); err != nil {
		t.Fatalf("sidecar missing: %v", err)
	}
}

// TestSFTPUploadTruncates verifies the per-file cap flags truncation while
// still reporting a full-length write to the client (§5.5).
func TestSFTPUploadTruncates(t *testing.T) {
	s := newTestServer(t, true)
	up, err := s.newSFTPUpload("/scratch/big.bin", "u", "10.0.0.6")
	if err != nil {
		t.Fatalf("newSFTPUpload: %v", err)
	}
	// A write entirely past the cap is dropped but acknowledged in full.
	chunk := []byte("XYZ")
	if n, err := up.WriteAt(chunk, int64(config.PerFileSizeLimit)); err != nil || n != len(chunk) {
		t.Fatalf("over-cap WriteAt = %d,%v; want %d,nil", n, err, len(chunk))
	}
	if err := up.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	rec, err := s.Meta.Get(up.id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if rec.Status != meta.StatusTruncated {
		t.Fatalf("status=%s; want truncated", rec.Status)
	}
}

// TestSFTPUploadBuffersWhenShareOffline confirms an offline share routes
// the SFTP upload into the VM-local buffer (locallyBuffered=true, no
// sidecar yet) like the legacy path (§8.4).
func TestSFTPUploadBuffersWhenShareOffline(t *testing.T) {
	s := newTestServer(t, false) // share offline -> buffer
	up, err := s.newSFTPUpload("/scratch/note.txt", "u", "10.0.0.7")
	if err != nil {
		t.Fatalf("newSFTPUpload: %v", err)
	}
	if _, err := up.WriteAt([]byte("buffered"), 0); err != nil {
		t.Fatalf("WriteAt: %v", err)
	}
	if err := up.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	rec, err := s.Meta.Get(up.id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !rec.LocallyBuffered {
		t.Fatalf("expected locallyBuffered=true for offline share")
	}
	if !strings.HasPrefix(rec.StoredPath, s.Buffer.FilesRoot()) {
		t.Fatalf("storedPath=%q; want under buffer %q", rec.StoredPath, s.Buffer.FilesRoot())
	}
	if listed, _ := s.Meta.ListBuffered(); len(listed) != 1 {
		t.Fatalf("ListBuffered=%d; want 1", len(listed))
	}
}
