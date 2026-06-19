// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Flush worker for the NAS-offline buffer (§8.4). Artifacts that arrived
// while the share was offline live in the VM-local buffer with
// locallyBuffered=true; this worker moves them to the share once it is
// back, writes their sidecars there, clears the flag, and deletes the
// local copy.
package sshsrv

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"time"

	"stash-server/internal/meta"
	"stash-server/internal/store"
)

// flushInterval is the worker's idle cadence; a buffered upload also nudges
// it immediately via triggerFlush, so this is the upper bound on how long a
// returned share waits before the backlog drains.
const flushInterval = 60 * time.Second

// triggerFlush nudges the worker without blocking. The cap-1 channel makes
// a burst of buffered uploads coalesce into a single wake-up.
func (s *Server) triggerFlush() {
	select {
	case s.flushTrigger <- struct{}{}:
	default:
	}
}

// RunFlushWorker drains the buffer backlog on startup (covers a daemon
// restart after the outage ended) and then on every tick or trigger until
// ctx is cancelled. Run it in its own goroutine.
func (s *Server) RunFlushWorker(ctx context.Context) {
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()
	s.flushOnce()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.flushOnce()
		case <-s.flushTrigger:
			s.flushOnce()
		}
	}
}

// flushOnce flushes the whole current backlog if the share is online. A
// per-record failure is logged and left for the next pass (the record
// stays buffered), so a transient error never drops data.
func (s *Server) flushOnce() {
	if !s.ShareOnline() {
		return
	}
	recs, err := s.Meta.ListBuffered()
	if err != nil {
		log.Printf("flush: list buffered: %v", err)
		return
	}
	flushed := 0
	for _, r := range recs {
		if err := s.flushRecord(r); err != nil {
			log.Printf("flush: id=%s: %v", r.ID, err)
			continue
		}
		flushed++
	}
	if flushed > 0 {
		log.Printf("flush: moved %d buffered artifact(s) to the share", flushed)
	}
}

// flushRecord moves one buffered artifact to the share at the same path it
// would have taken there (same yyyy/mm/dd/<name> under files/), writes its
// sidecar, clears the buffered flag, and removes the local copy. Each step
// is idempotent so a retry after a partway crash is safe.
func (s *Server) flushRecord(r *meta.Record) error {
	// Serialize against a concurrent DeleteLocal of the same artifact so a
	// delete can't snapshot a stale buffered path while we move it to the
	// share (which would orphan the on-share copy + sidecar).
	s.mutateMu.Lock()
	defer s.mutateMu.Unlock()
	rel, err := filepath.Rel(s.Buffer.FilesRoot(), r.StoredPath)
	if err != nil {
		return err
	}
	dst := filepath.Join(s.Store.FilesRoot(), rel)
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}
	// Copy only if the share doesn't already hold it (idempotent retry).
	if _, statErr := os.Stat(dst); os.IsNotExist(statErr) {
		if err := store.AtomicCopyFile(r.StoredPath, dst); err != nil {
			return err
		}
	} else if statErr != nil {
		return statErr
	}
	// Sidecar reflects the committed (on-share) record.
	committed := *r
	committed.StoredPath = dst
	committed.LocallyBuffered = false
	if err := meta.WriteSidecar(&committed); err != nil {
		return err
	}
	if err := s.Meta.UpdateOnFlushed(r.ID, dst); err != nil {
		return err
	}
	// Best-effort: a leftover local copy after this point is a harmless
	// orphan the next pass won't re-flush (the row is no longer buffered).
	_ = os.Remove(r.StoredPath)
	return nil
}
