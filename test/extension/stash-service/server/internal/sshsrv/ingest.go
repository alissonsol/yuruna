// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// UI-facing ingest + delete entry points (stash-service-ui.md §5, §8). The
// browser UI creates stashes (pasted text or uploaded files) and deletes
// its own host's stashes. Both routes go through the SAME storage pipeline
// as SCP/SFTP — chooseTarget → staging → FinalizeStaging → commit — so a
// UI-created stash is indistinguishable from an SCP one (a stash is a
// stash, §1). The only difference is the recorded source = config.SourceUI.
package sshsrv

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"stash-server/internal/config"
	"stash-server/internal/meta"
	"stash-server/internal/store"
)

// IngestResult is returned to the HTTP create handler (§5.4).
type IngestResult struct {
	ID       string
	Buffered bool
}

// NamedReader is one file in a multi-file UI upload (§5.2).
type NamedReader struct {
	Name string
	Body io.Reader
}

// IngestSingle stores one artifact — a pasted text blob or a single
// uploaded file — through the shared pipeline (§5.1, §5.2). name is the
// client-supplied filename (the §6.3 extension rules apply); an empty name
// falls back to the bare ID. pathMeta is empty for the UI (no SCP
// destination path). source is normally config.SourceUI.
func (s *Server) IngestSingle(name, username, clientIP, pathMeta, source string, content io.Reader) (*IngestResult, error) {
	id, target, buffered, dayDir, stagingDir, err := s.beginIngest(username, clientIP, pathMeta, source)
	if err != nil {
		return nil, err
	}
	origName := sanitizeUploadName(name)
	if origName == "" {
		origName = id
	}
	truncated, werr := writeCapped(filepath.Join(stagingDir, origName), content)
	if werr != nil {
		_ = s.Meta.UpdateOnPartial(id, 0, time.Now().UTC())
		_ = os.RemoveAll(stagingDir)
		return nil, werr
	}
	return s.finishIngest(id, target, dayDir, stagingDir, buffered, username, false, []string{origName}, "", truncated)
}

// IngestText stores a pasted text blob (§5.1). When title is empty the
// artifact's originalFilename defaults to paste-<id>.txt (§5.3); a title
// with a usable extension drives the §6.3 extension rules like any name.
func (s *Server) IngestText(text, title, username, clientIP string) (*IngestResult, error) {
	id, target, buffered, dayDir, stagingDir, err := s.beginIngest(username, clientIP, "", config.SourceUI)
	if err != nil {
		return nil, err
	}
	origName := sanitizeUploadName(title)
	if origName == "" {
		origName = "paste-" + id + ".txt"
	}
	truncated, werr := writeCapped(filepath.Join(stagingDir, origName), strings.NewReader(text))
	if werr != nil {
		_ = s.Meta.UpdateOnPartial(id, 0, time.Now().UTC())
		_ = os.RemoveAll(stagingDir)
		return nil, werr
	}
	return s.finishIngest(id, target, dayDir, stagingDir, buffered, username, false, []string{origName}, "", truncated)
}

// IngestMulti stores several uploaded files as ONE ZIP archive, mirroring
// the legacy multi-file grouping (§5.2 / SS§5.3): one ID, one record. A
// single-element slice is handled by IngestSingle's single-file path
// instead (callers should route accordingly).
func (s *Server) IngestMulti(files []NamedReader, username, clientIP, pathMeta, source string) (*IngestResult, error) {
	if len(files) == 0 {
		return nil, fmt.Errorf("ingest: no files")
	}
	id, target, buffered, dayDir, stagingDir, err := s.beginIngest(username, clientIP, pathMeta, source)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(files))
	truncatedAny := false
	for i, fr := range files {
		name := sanitizeUploadName(fr.Name)
		if name == "" {
			name = fmt.Sprintf("file-%d", i+1)
		}
		truncated, werr := writeCapped(filepath.Join(stagingDir, name), fr.Body)
		if werr != nil {
			_ = s.Meta.UpdateOnPartial(id, 0, time.Now().UTC())
			_ = os.RemoveAll(stagingDir)
			return nil, werr
		}
		truncatedAny = truncatedAny || truncated
		names = append(names, name)
	}
	// Force the archive path even if only one file slipped through, and use
	// the first name as the informative originalFilename (firstDirName=""
	// with recursive=true selects the ZIP branch in FinalizeStaging).
	return s.finishIngest(id, target, dayDir, stagingDir, buffered, username, true, names, "", truncatedAny)
}

// beginIngest allocates the ID, picks the share/buffer target, creates the
// day + staging dirs, and writes the up-front pending row (§8.2 step 2).
func (s *Server) beginIngest(username, clientIP, pathMeta, source string) (id string, target *store.Store, buffered bool, dayDir, stagingDir string, err error) {
	now := time.Now().UTC()
	id, err = s.IDs.Allocate(now)
	if err != nil {
		return "", nil, false, "", "", err
	}
	tgt, buffered, err := s.chooseTarget(id)
	if err != nil {
		return "", nil, false, "", "", err
	}
	dayDir, err = tgt.DayDir(now)
	if err != nil {
		return "", nil, false, "", "", err
	}
	stagingDir, err = tgt.StagingDir(now, id)
	if err != nil {
		return "", nil, false, "", "", err
	}
	rec := &meta.Record{
		ID:              id,
		Username:        username,
		PathMetadata:    pathMeta,
		ClientAddress:   clientIP,
		CreatedAt:       now,
		Status:          meta.StatusPending,
		LocallyBuffered: buffered,
		Source:          source,
	}
	if err := s.Meta.InsertPending(rec); err != nil {
		_ = os.RemoveAll(stagingDir)
		return "", nil, false, "", "", err
	}
	return id, tgt, buffered, dayDir, stagingDir, nil
}

// finishIngest finalizes the staged files into the artifact and commits the
// terminal row + sidecar (+ detection), shared by IngestSingle/IngestMulti.
func (s *Server) finishIngest(id string, target *store.Store, dayDir, stagingDir string, buffered bool, username string, recursive bool, names []string, firstDir string, truncated bool) (*IngestResult, error) {
	final, err := target.FinalizeStaging(stagingDir, dayDir, id, recursive, names, firstDir)
	if err != nil {
		// FinalizeStaging only removes the staging dir on success, so clean
		// up here on failure to match the writeCapped error paths (no orphan
		// <id>.staging tree left behind).
		_ = os.RemoveAll(stagingDir)
		_ = s.Meta.UpdateOnPartial(id, 0, time.Now().UTC())
		return nil, err
	}
	status := meta.StatusComplete
	if truncated {
		status = meta.StatusTruncated
	}
	if err := s.commit(id, status, final, buffered, username); err != nil {
		return nil, err
	}
	return &IngestResult{ID: id, Buffered: buffered}, nil
}

// writeCapped streams content into path, enforcing the 100 MB per-file cap
// (§5.5 / SS§5.5): bytes past the cap are discarded and truncated=true is
// returned, but the read is drained so the caller's request body completes.
func writeCapped(path string, content io.Reader) (truncated bool, err error) {
	f, err := os.Create(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	cap := int64(config.PerFileSizeLimit)
	n, err := io.Copy(f, io.LimitReader(content, cap))
	if err != nil {
		return false, err
	}
	if n >= cap {
		// Drain any remainder so an HTTP body fully reads (avoids a broken
		// pipe on the client) and flag truncation.
		extra, derr := io.Copy(io.Discard, content)
		if derr != nil {
			return true, nil // already capped; ignore drain error
		}
		if extra > 0 {
			truncated = true
		}
	}
	return truncated, nil
}

// DeleteLocal hard-deletes a stash OWNED BY THIS HOST (§8.1, §8.2): it
// removes the artifact (share or buffer), its on-share sidecar, and the
// local index row. The HTTP layer enforces the local-host-only boundary
// (foreign hostId → 403, §8.3) before calling this; here we operate purely
// on the local index by ID. Returns sql.ErrNoRows when the id is unknown.
func (s *Server) DeleteLocal(id string) error {
	// Serialize against the flush worker so we never act on a record whose
	// buffered/share location is changing under us (orphan-on-flush race).
	s.mutateMu.Lock()
	defer s.mutateMu.Unlock()
	rec, err := s.Meta.Get(id)
	if err != nil {
		return err
	}
	if rec.StoredPath != "" {
		if rerr := os.Remove(rec.StoredPath); rerr != nil && !os.IsNotExist(rerr) {
			return fmt.Errorf("remove artifact: %w", rerr)
		}
		// The sidecar sits next to the artifact (only present once committed
		// to the share; a still-buffered record has none yet).
		if !rec.LocallyBuffered {
			sidecar := filepath.Join(filepath.Dir(rec.StoredPath), rec.ID+config.SidecarExtension)
			if rerr := os.Remove(sidecar); rerr != nil && !os.IsNotExist(rerr) {
				log.Printf("delete: remove sidecar id=%s: %v", id, rerr)
			}
		}
	}
	if derr := s.Meta.Delete(id); derr != nil {
		return fmt.Errorf("delete index row: %w", derr)
	}
	log.Printf("stash deleted: id=%s path=%s buffered=%v", id, rec.StoredPath, rec.LocallyBuffered)
	return nil
}
