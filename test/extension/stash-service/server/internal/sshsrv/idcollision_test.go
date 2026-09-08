// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"stash-service/internal/meta"
)

// scriptedIDs is an IDSource that hands back a fixed sequence, repeating the
// last entry once the script runs out. It puts a KNOWN collision in front of
// the ingest path: the real allocator is random, so a test that waited for one
// to happen would never finish.
type scriptedIDs struct {
	mu    sync.Mutex
	queue []string
	drawn []string
}

func (s *scriptedIDs) Allocate(time.Time) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := s.queue[len(s.queue)-1]
	if len(s.queue) > 1 {
		next = s.queue[0]
		s.queue = s.queue[1:]
	}
	s.drawn = append(s.drawn, next)
	return next, nil
}

// dayDirOf is the share-side folder an upload made now lands in.
func dayDirOf(s *Server, now time.Time) string {
	return filepath.Join(s.Store.FilesRoot(), now.UTC().Format("2006"), now.UTC().Format("01"), now.UTC().Format("02"))
}

// TestIngestRedrawsAnIDTheIndexAlreadyHolds is the regression case. An id the
// allocator may legally reissue on a later day is still owned, for all time,
// by the row an earlier day wrote. The upload must land under a fresh id
// instead of dying on the index write with nothing but a lost connection at
// the client -- and the older artifact's row must be left exactly as it was.
func TestIngestRedrawsAnIDTheIndexAlreadyHolds(t *testing.T) {
	s := newTestServer(t, true)
	yesterday := time.Now().UTC().Add(-24 * time.Hour)
	if err := s.Meta.InsertPending(&meta.Record{
		ID: "6tat", Username: "amisad-poc", CreatedAt: yesterday, Status: meta.StatusComplete,
	}); err != nil {
		t.Fatalf("seed the older row: %v", err)
	}
	ids := &scriptedIDs{queue: []string{"6tat", "9xk2"}}
	s.IDs = ids

	now := time.Now().UTC()
	res, err := s.IngestText("binaries manifest", "note.txt", "amisad-poc", "192.168.7.46")
	if err != nil {
		t.Fatalf("ingest aborted on a taken id instead of redrawing: %v", err)
	}
	if res.ID != "9xk2" {
		t.Fatalf("stored under id %q, want the redrawn %q", res.ID, "9xk2")
	}
	if len(ids.drawn) != 2 {
		t.Fatalf("allocator was asked %d time(s) (%v), want 2", len(ids.drawn), ids.drawn)
	}

	// The row that owned the id keeps everything it had.
	older, err := s.Meta.Get("6tat")
	if err != nil {
		t.Fatalf("older row gone after the collision: %v", err)
	}
	if older.Username != "amisad-poc" || older.Status != meta.StatusComplete {
		t.Fatalf("older row was overwritten: username=%q status=%q", older.Username, older.Status)
	}

	// The losing attempt must not leave <id>.staging behind: the allocator's
	// disk scan reads one as a claim and would hold that id out of the day's
	// pool forever.
	orphan := filepath.Join(dayDirOf(s, now), "6tat.staging")
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("orphan staging tree left at %s (stat err = %v)", orphan, err)
	}

	// And the artifact really is stored under the redrawn id.
	stored, err := s.Meta.Get("9xk2")
	if err != nil {
		t.Fatalf("redrawn row missing: %v", err)
	}
	if stored.Status != meta.StatusComplete {
		t.Fatalf("redrawn row status = %q, want %q", stored.Status, meta.StatusComplete)
	}
	if _, err := os.Stat(stored.StoredPath); err != nil {
		t.Fatalf("artifact not on disk at the recorded path: %v", err)
	}
}

// TestSFTPUploadRedrawsAnIDTheIndexAlreadyHolds covers the second of the three
// ingest paths. It has no channel to tell the client anything, so an abort
// here is the most silent of the three.
func TestSFTPUploadRedrawsAnIDTheIndexAlreadyHolds(t *testing.T) {
	s := newTestServer(t, true)
	if err := s.Meta.InsertPending(&meta.Record{
		ID: "6tat", Username: "amisad-poc", CreatedAt: time.Now().UTC().Add(-24 * time.Hour), Status: meta.StatusComplete,
	}); err != nil {
		t.Fatalf("seed the older row: %v", err)
	}
	s.IDs = &scriptedIDs{queue: []string{"6tat", "9xk2"}}

	up, err := s.newSFTPUpload("/amisad/amisad-x86_64-binaries.tgz", "amisad-poc", "192.168.7.46")
	if err != nil {
		t.Fatalf("sftp upload aborted on a taken id instead of redrawing: %v", err)
	}
	if up.id != "9xk2" {
		t.Fatalf("sftp upload took id %q, want the redrawn %q", up.id, "9xk2")
	}
	if _, err := up.WriteAt([]byte("payload"), 0); err != nil {
		t.Fatalf("WriteAt: %v", err)
	}
	if err := up.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	rec, err := s.Meta.Get("9xk2")
	if err != nil {
		t.Fatalf("redrawn row missing: %v", err)
	}
	if rec.OriginalFilename != "amisad-x86_64-binaries.tgz" {
		t.Fatalf("originalFilename = %q, want the uploaded name", rec.OriginalFilename)
	}
}

// TestIngestGivesUpWhenEveryIDCollides bounds the redraw: a ladder that never
// ends would hang the session instead of failing it. The upload fails, says
// why, and leaves nothing staged behind.
func TestIngestGivesUpWhenEveryIDCollides(t *testing.T) {
	s := newTestServer(t, true)
	if err := s.Meta.InsertPending(&meta.Record{
		ID: "6tat", Username: "amisad-poc", CreatedAt: time.Now().UTC(), Status: meta.StatusComplete,
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	ids := &scriptedIDs{queue: []string{"6tat"}}
	s.IDs = ids

	now := time.Now().UTC()
	_, err := s.IngestText("payload", "note.txt", "u", "192.168.7.46")
	if err == nil {
		t.Fatal("ingest succeeded even though every drawn id was taken")
	}
	if !errors.Is(err, meta.ErrDuplicateID) {
		t.Fatalf("error %v does not carry ErrDuplicateID, so the client cannot be told why", err)
	}
	if len(ids.drawn) != idCollisionAttempts {
		t.Fatalf("allocator was asked %d time(s), want the bounded %d", len(ids.drawn), idCollisionAttempts)
	}
	orphan := filepath.Join(dayDirOf(s, now), "6tat.staging")
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("orphan staging tree left at %s (stat err = %v)", orphan, err)
	}
}

// TestUploadStageReasonsAreCategorical guards what the client is told: a
// reason for every post-banner abort, and no server-side detail in any of
// them. The scp client is untrusted, and a path or driver string tells it
// about the daemon's insides while telling the operator nothing new.
func TestUploadStageReasonsAreCategorical(t *testing.T) {
	detail := errors.New("open /srv/stash/2026/09/07: permission denied (sqlite3 error 1555)")
	for _, st := range []uploadStage{stageAllocate, stageTarget, stageDayDir, stageStaging, stageIndex} {
		got := st.clientReason(detail)
		if !strings.HasPrefix(got, "stash-service: ") {
			t.Fatalf("stage %d reason %q lacks the client-message prefix", st, got)
		}
		for _, leak := range []string{"/srv", "sqlite", "permission denied", "1555"} {
			if strings.Contains(strings.ToLower(got), leak) {
				t.Fatalf("stage %d reason %q leaks server detail %q", st, got, leak)
			}
		}
	}
	if got := stageTarget.clientReason(errBufferFull); !strings.Contains(got, "buffer full") {
		t.Fatalf("a full buffer must keep its own reason, got %q", got)
	}
}
