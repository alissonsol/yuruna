// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"stash-service/internal/config"
)

// Deleting a stash, from either side of the ownership line.
//
// A stash this host received is removed through its own index: artifact,
// sidecar and row, serialized against the flush worker. A stash another host
// received is removed directly on the share, which this daemon may do because
// the stash share is mounted with write access to every host's folder, not just
// its own. The peer keeps an index row for it until its own reconcile pass
// notices both files are gone (reconcile.go) -- which is what makes the second
// case safe to offer: the disk is reclaimed immediately, and the listing
// catches up on its own instead of needing that VM to be reachable, or alive.

// maxBatchDelete bounds one bulk request. It matches the largest page the list
// API will return, which is the largest selection a browser can have built.
const maxBatchDelete = config.MaxListLimit

// deleteStash removes one stash by path key, whichever host owns it. Returns
// sql.ErrNoRows / os.ErrNotExist when there was nothing there, which the
// callers map to a 404.
func (s *Server) deleteStash(k pathKey) error {
	if k.hostID == s.localHostID {
		return s.ssh.DeleteLocal(k.id)
	}
	if err := s.deleteOnShare(k); err != nil {
		return err
	}
	// The local index is never in the pool cache (the scan skips this host), so
	// only a peer's stash needs evicting -- without it the row would linger in
	// this browser's next list until the following rescan, having just been
	// deleted from under it.
	s.pool.Evict(k.hostID, k.id)
	return nil
}

// deleteOnShare unlinks a peer-owned stash from the share.
//
// The sidecar goes first. It is what makes a stash visible pool-wide and what
// the owner's reconcile keys on, so a failure between the two unlinks leaves an
// unreferenced file -- invisible, and reclaimable later -- rather than a stash
// that still lists everywhere with no bytes behind it.
func (s *Server) deleteOnShare(k pathKey) error {
	dir := filepath.Join(s.stashRoot, k.hostID, config.FilesDirName, k.yS, k.mS, k.dS)
	artifact := findArtifact(dir, k.id)
	sidecar := filepath.Join(dir, k.id+config.SidecarExtension)

	sidecarErr := os.Remove(sidecar)
	if sidecarErr != nil && !os.IsNotExist(sidecarErr) {
		return fmt.Errorf("remove sidecar: %w", sidecarErr)
	}
	if artifact == "" {
		// Neither file was there: the id names no stash on that host, and the
		// caller should hear "not found" rather than a silent success.
		if os.IsNotExist(sidecarErr) {
			return os.ErrNotExist
		}
		// A sidecar with no artifact is the half-deleted state this function
		// leaves behind on a crash; finishing it is a success, not an error.
		log.Printf("stash deleted on share: host=%s id=%s (sidecar only -- no artifact was present)", k.hostID, k.id)
		return nil
	}
	if err := os.Remove(artifact); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove artifact: %w", err)
	}
	log.Printf("stash deleted on share: host=%s id=%s path=%s", k.hostID, k.id, artifact)
	return nil
}

// deleteStatus maps a delete failure onto its HTTP status and message. Both
// "nothing there" shapes -- the local index's sql.ErrNoRows and the share's
// os.ErrNotExist -- are the same answer to the caller.
func deleteStatus(err error) (int, string) {
	if errors.Is(err, sql.ErrNoRows) || errors.Is(err, os.ErrNotExist) {
		return http.StatusNotFound, "stash not found"
	}
	return http.StatusInternalServerError, "delete: " + err.Error()
}
