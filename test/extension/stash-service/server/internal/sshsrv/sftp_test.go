// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pkg/sftp"
	"stash-service/internal/config"
	"stash-service/internal/meta"
)

// TestSFTPUploadStoresArtifactAndSidecar drives the SFTP ingest the way
// pkg/sftp would (newSFTPUpload -> WriteAt -> Close) and verifies the file
// lands in the stash with the right metadata + a sidecar, with the path
// captured as metadata (not used as a location, section 5.1).
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
	// On-disk name is <id>.pdf (extension lowercased, section 6.3); content intact.
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
// still reporting a full-length write to the client (section 5.5).
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
// sidecar yet) like the legacy path (section 8.4).
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

func TestSFTPDisconnectedUploadRemainsPartial(t *testing.T) {
	s := newTestServer(t, true)
	serverConn, clientConn := net.Pipe()
	h := &stashSFTP{srv: s, username: "alice", clientIP: "127.0.0.1"}
	rs := sftp.NewRequestServer(serverConn, sftp.Handlers{FileGet: h, FilePut: h, FileCmd: h, FileList: h})
	done := make(chan error, 1)
	go func() { done <- rs.Serve() }()
	t.Cleanup(func() { _ = clientConn.Close(); _ = serverConn.Close(); _ = rs.Close() })
	client, err := sftp.NewClientPipe(clientConn, clientConn)
	if err != nil {
		t.Fatal(err)
	}
	f, err := client.Create("/upload/interrupted.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write([]byte("incomplete payload")); err != nil {
		t.Fatal(err)
	}
	// Close the transport without the SFTP CLOSE that proves completion.
	_ = clientConn.Close()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("SFTP server did not observe the closed transport")
	}
	records, err := s.Meta.ListBuffered()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 0 {
		t.Fatal("interrupted upload was queued as a completed buffered artifact")
	}
	// The pending ID is the only metadata row in this isolated server.
	entries, err := s.Meta.Search(&meta.SearchFilter{})
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Status != meta.StatusPartial {
		t.Fatalf("records after disconnect = %+v; want one partial upload", entries)
	}
}

func TestSFTPCloseReturnsMetadataFailure(t *testing.T) {
	s := newTestServer(t, true)
	up, err := s.newSFTPUpload("/scratch/report.txt", "alice", "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := up.WriteAt([]byte("complete bytes"), 0); err != nil {
		t.Fatal(err)
	}
	if err := s.Meta.Close(); err != nil {
		t.Fatal(err)
	}
	if err := up.Close(); err == nil {
		t.Fatal("Close hid the metadata commit failure")
	}
}

func TestSFTPTransferErrorBeforeClose(t *testing.T) {
	s := newTestServer(t, true)
	up, err := s.newSFTPUpload("/scratch/partial.txt", "alice", "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := up.WriteAt([]byte("partial"), 0); err != nil {
		t.Fatal(err)
	}
	up.TransferError(io.ErrUnexpectedEOF)
	if err := up.Close(); err != nil {
		t.Fatal(err)
	}
	rec, err := s.Meta.Get(up.id)
	if err != nil {
		t.Fatal(err)
	}
	if rec.Status != meta.StatusPartial {
		t.Fatalf("status = %s; want partial", rec.Status)
	}
}

func TestSFTPReservedArtifactNamesKeepPayload(t *testing.T) {
	for _, name := range []string{"x.yuruna.meta.json", "app.staging", "x.yuruna.archive.zip"} {
		t.Run(name, func(t *testing.T) {
			s := newTestServer(t, true)
			up, err := s.newSFTPUpload("/scratch/"+name, "alice", "127.0.0.1")
			if err != nil {
				t.Fatal(err)
			}
			const payload = "original upload, never sidecar metadata"
			if _, err := up.WriteAt([]byte(payload), 0); err != nil {
				t.Fatal(err)
			}
			if err := up.Close(); err != nil {
				t.Fatal(err)
			}
			record, err := s.Meta.Get(up.id)
			if err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(record.StoredPath)
			if err != nil {
				t.Fatal(err)
			}
			if string(data) != payload {
				t.Fatalf("artifact overwritten: %q", data)
			}
			if record.OriginalFilename != name || record.IsArchive {
				t.Fatalf("original metadata changed: %+v", record)
			}
		})
	}
}

func TestSFTPWritebackFailureIsPartial(t *testing.T) {
	s := newTestServer(t, true)
	up, err := s.newSFTPUpload("/scratch/failure.txt", "alice", "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := up.WriteAt([]byte("buffered data"), 0); err != nil {
		t.Fatal(err)
	}
	if err := up.f.Close(); err != nil {
		t.Fatal(err)
	}
	if err := up.Close(); err == nil {
		t.Fatal("writeback failure was hidden")
	}
	record, err := s.Meta.Get(up.id)
	if err != nil {
		t.Fatal(err)
	}
	if record.Status != meta.StatusPartial || record.StoredPath != "" {
		t.Fatalf("failed upload finalized: %+v", record)
	}
}
