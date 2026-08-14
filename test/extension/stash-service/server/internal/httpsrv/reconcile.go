// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"stash-service/internal/meta"
)

// Owner-side reconcile.
//
// A stash's bytes and its sidecar live on the share, where every host's stash
// daemon can reach them; the index row that lists it lives only on the VM that
// received it. So a stash deleted by a peer -- or by an operator working on the
// NAS directly -- leaves its owner listing a row whose artifact is gone, and
// nothing else in the daemon would ever notice: the sidecar rebuild runs only
// on an empty index, and a delete on another host is invisible to this one.
//
// This pass closes that gap from the owning side. It is the only code here that
// removes index rows without anyone asking, so its predicate is deliberately
// timid: every uncertainty -- a share that is not mounted, a directory it could
// not read, a record still being written -- reads as "keep", never as "gone".

// maxReconcilePerPass bounds how many rows one pass may drop. A genuinely
// mass-deleted corpus converges over the following ticks, which costs nothing;
// what the cap buys is a bounded blast radius if this predicate is ever wrong,
// so a mistake shows up as a handful of rows and a run of log lines rather than
// an emptied index.
const maxReconcilePerPass = 200

// runShareScans drives both passes that read the share, on one cadence: the
// pool-index rescan that discovers other hosts' sidecars, and the reconcile
// that drops a local row whose artifact and sidecar are both gone. One ticker
// rather than two because they ask the same question of the same mount, and a
// share that has gone away should not be probed twice a period to be told so
// twice. Run it in its own goroutine; it returns when ctx is canceled.
func (s *Server) runShareScans(ctx context.Context) {
	s.pool.Refresh()
	s.reconcile()
	t := time.NewTicker(s.pool.RefreshInterval())
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.pool.Refresh()
			s.reconcile()
		}
	}
}

// reconcile drops the index rows whose artifact and sidecar have both left the
// share. Best-effort and silent when there is nothing to do: the steady state
// of a healthy daemon is a pass that finds no orphan at all.
func (s *Server) reconcile() {
	// An offline share tells us nothing about what still exists on it -- every
	// stat below would report "gone" and the pass would empty the index. Skip
	// the whole pass rather than trying to interpret it: buffering is already
	// the daemon's answer while the mount is away, and a returning share brings
	// the real answer with it. The same predicate the ingest and flush paths
	// use, so "the share is up" is one answer across the daemon rather than two
	// that can disagree mid-outage.
	if !s.ssh.ShareOnline() {
		return
	}
	recs, err := s.meta().Search(&meta.SearchFilter{})
	if err != nil {
		log.Printf("reconcile: search index: %v", err)
		return
	}
	// Grouped by day directory, and read one directory at a time. A stat per
	// stash would make a pass cost as much as the corpus is large, every
	// minute, over SMB; this way it costs as much as the corpus is OLD -- one
	// listing per day that holds anything, however many stashes that day holds.
	byDir := map[string][]*meta.Record{}
	for _, rec := range recs {
		if !reconcilable(rec) {
			continue
		}
		dir := filepath.Dir(rec.StoredPath)
		byDir[dir] = append(byDir[dir], rec)
	}

	pruned := 0
	for dir, group := range byDir {
		if pruned >= maxReconcilePerPass {
			log.Printf("reconcile: stopped at the %d-row cap; the next pass continues", maxReconcilePerPass)
			return
		}
		entries, rerr := os.ReadDir(dir)
		if rerr != nil {
			// Unreadable is not empty. A day directory that cannot be listed --
			// a half-mounted share, a permission change -- must read as unknown,
			// or one failed read would condemn every stash filed under it.
			continue
		}
		for _, rec := range group {
			if stashFilesPresent(entries, rec.ID) {
				continue
			}
			if derr := s.meta().Delete(rec.ID); derr != nil {
				log.Printf("reconcile: drop index row id=%s: %v", rec.ID, derr)
				continue
			}
			pruned++
			log.Printf("reconcile: dropped index row id=%s path=%s -- nothing for it remains on the share", rec.ID, rec.StoredPath)
		}
	}
}

// reconcilable reports whether rec is in a state where absence on the share
// means anything at all. Both exclusions are records whose files are not
// supposed to be there yet.
func reconcilable(rec *meta.Record) bool {
	// A buffered record's artifact is on the VM's own disk, and its sidecar is
	// written when the flush worker moves it; absence on the share means a
	// flush is still owed, not that anything was deleted.
	if rec.LocallyBuffered {
		return false
	}
	// A pending record is an upload still arriving: its bytes are under a
	// staging name and its sidecar is written when the transfer commits.
	if rec.Status == meta.StatusPending || rec.StoredPath == "" {
		return false
	}
	return true
}

// stashFilesPresent reports whether ANY file belonging to id survives in a day
// directory's listing -- the artifact under any extension, the sidecar, or a
// staging file from an upload in flight. One prefix test covers all of them,
// and it errs toward presence: a row is dropped only when the day it was filed
// under holds nothing for it whatsoever.
func stashFilesPresent(entries []os.DirEntry, id string) bool {
	for _, e := range entries {
		if name := e.Name(); name == id || strings.HasPrefix(name, id+".") {
			return true
		}
	}
	return false
}
