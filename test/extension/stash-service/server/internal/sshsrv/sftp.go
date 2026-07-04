// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// SFTP ingest path. Modern OpenSSH scp (>= 9.0) speaks the SFTP protocol
// by default and does NOT fall back to the legacy scp wire protocol, so
// the daemon serves a minimal, WRITE-ONLY SFTP backend that routes every
// uploaded file through the same stash storage as the legacy path
// (chooseTarget + FinalizeStaging + commit). Downloads and listings are
// refused; the stash is a sink.
//
// Path handling (§5.1): the client-supplied path is metadata, not a real
// location. Stat reports EVERY path as a directory, so scp appends the
// real local filename and we always capture a sensible originalFilename;
// the full requested path is stored verbatim as pathMetadata.
//
// Limitation: the SFTP protocol has no channel to surface the §9
// "YURUNA-STASH-ID: <id>" line to the scp client (that marker only shows
// under the legacy protocol, which renders server stderr). Over SFTP the
// ID is logged server-side and recorded in metadata, not echoed to the
// client. Each uploaded file becomes its own record (the §5.3/§5.4
// multi-file/recursive ZIP grouping is a legacy-protocol behavior).
package sshsrv

import (
	"io"
	"log"
	"net"
	"os"
	"path"
	"path/filepath"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"

	"stash-server/internal/config"
	"stash-server/internal/meta"
	"stash-server/internal/store"
)

// serveSFTP runs the SFTP request server over the SSH channel until the
// session ends. Every write is routed into the stash by stashSFTP.
func (s *Server) serveSFTP(ch ssh.Channel, username, remote string) {
	defer ch.Close()
	clientIP := remote
	if h, _, err := net.SplitHostPort(remote); err == nil {
		clientIP = h
	}
	h := &stashSFTP{srv: s, username: username, clientIP: clientIP}
	handlers := sftp.Handlers{FileGet: h, FilePut: h, FileCmd: h, FileList: h}
	rs := sftp.NewRequestServer(ch, handlers)
	defer rs.Close()
	if err := rs.Serve(); err != nil && err != io.EOF {
		log.Printf("sftp serve (user=%s remote=%s): %v", username, clientIP, err)
	}
	log.Printf("sftp session ended: user=%s remote=%s", username, clientIP)
}

// stashSFTP implements the pkg/sftp request handler interfaces, scoped to
// one SSH connection (so it carries the captured username + client IP).
type stashSFTP struct {
	srv      *Server
	username string
	clientIP string
}

// Fileread — downloads are not supported; the stash is write-only.
func (h *stashSFTP) Fileread(*sftp.Request) (io.ReaderAt, error) {
	return nil, sftp.ErrSSHFxOpUnsupported
}

// Filewrite routes an upload into the stash and returns a writer whose
// Close() finalizes the artifact.
func (h *stashSFTP) Filewrite(r *sftp.Request) (io.WriterAt, error) {
	return h.srv.newSFTPUpload(r.Filepath, h.username, h.clientIP)
}

// Filecmd accepts the metadata operations scp issues (setstat/mtime,
// mkdir for -r, rename, remove) as no-ops — none map to a real filesystem
// here, and failing them would abort an otherwise-fine transfer.
func (h *stashSFTP) Filecmd(*sftp.Request) error { return nil }

// Filelist answers Stat/List/Readlink. Stat reports any path as a
// directory so scp appends the local filename (§5.1 path-is-metadata);
// List is empty; Readlink is unsupported.
func (h *stashSFTP) Filelist(r *sftp.Request) (sftp.ListerAt, error) {
	switch r.Method {
	case "Stat", "Lstat":
		return listerAt{virtualDirInfo{name: path.Base(r.Filepath)}}, nil
	case "List":
		return listerAt{}, nil
	default:
		return nil, sftp.ErrSSHFxOpUnsupported
	}
}

// listerAt is a fixed slice of FileInfo satisfying sftp.ListerAt.
type listerAt []os.FileInfo

func (l listerAt) ListAt(out []os.FileInfo, off int64) (int, error) {
	if off >= int64(len(l)) {
		return 0, io.EOF
	}
	n := copy(out, l[off:])
	if int(off)+n >= len(l) {
		return n, io.EOF
	}
	return n, nil
}

// virtualDirInfo is a synthetic directory FileInfo (no real fs entry).
type virtualDirInfo struct{ name string }

func (v virtualDirInfo) Name() string       { return v.name }
func (v virtualDirInfo) Size() int64        { return 0 }
func (v virtualDirInfo) Mode() os.FileMode  { return os.ModeDir | 0o755 }
func (v virtualDirInfo) ModTime() time.Time { return time.Unix(0, 0).UTC() }
func (v virtualDirInfo) IsDir() bool        { return true }
func (v virtualDirInfo) Sys() any           { return nil }

// sftpUpload is one in-flight SFTP file write. It stages to the chosen
// store, enforces the per-file cap, and finalizes on Close.
type sftpUpload struct {
	srv        *Server
	now        time.Time
	id         string
	target     *store.Store
	buffered   bool
	dayDir     string
	stagingDir string
	origName   string
	username   string
	f          *os.File
	size       int64
	truncated  bool
	failed     bool
}

// newSFTPUpload allocates an ID, picks the share/buffer target, inserts a
// pending row, and opens a staging file. reqPath is the client-supplied
// path, stored verbatim as pathMetadata (§5.1).
func (s *Server) newSFTPUpload(reqPath, username, clientIP string) (*sftpUpload, error) {
	now := time.Now().UTC()
	id, err := s.IDs.Allocate(now)
	if err != nil {
		return nil, err
	}
	target, buffered, err := s.chooseTarget(id)
	if err != nil {
		return nil, err // errBufferFull surfaces to the client as a write error
	}
	dayDir, err := target.DayDir(now)
	if err != nil {
		return nil, err
	}
	stagingDir, err := target.StagingDir(now, id)
	if err != nil {
		return nil, err
	}
	origName := sanitizeUploadName(path.Base(reqPath))
	if origName == "" {
		origName = id
	}
	f, err := os.Create(filepath.Join(stagingDir, origName))
	if err != nil {
		return nil, err
	}
	rec := &meta.Record{
		ID:              id,
		Username:        username,
		PathMetadata:    reqPath,
		ClientAddress:   clientIP,
		CreatedAt:       now,
		Status:          meta.StatusPending,
		LocallyBuffered: buffered,
		Source:          config.SourceSCP,
	}
	if err := s.Meta.InsertPending(rec); err != nil {
		_ = f.Close()
		_ = os.RemoveAll(stagingDir)
		return nil, err
	}
	log.Printf("sftp upload start: id=%s user=%s path=%q buffered=%v", id, username, reqPath, buffered)
	return &sftpUpload{
		srv: s, now: now, id: id, target: target, buffered: buffered,
		dayDir: dayDir, stagingDir: stagingDir, origName: origName,
		username: username, f: f,
	}, nil
}

// WriteAt writes a chunk to the staging file, enforcing the 100 MB cap
// (§5.5): bytes past the cap are dropped and the record flagged truncated,
// but the client still sees a full-length write so the transfer completes.
func (u *sftpUpload) WriteAt(p []byte, off int64) (int, error) {
	capN := int64(config.PerFileSizeLimit)
	if off >= capN {
		u.truncated = true
		return len(p), nil
	}
	n := int64(len(p))
	if off+n > capN {
		n = capN - off
		u.truncated = true
	}
	w, err := u.f.WriteAt(p[:n], off)
	if end := off + int64(w); end > u.size {
		u.size = end
	}
	if err != nil {
		u.failed = true
		return w, err
	}
	return len(p), nil
}

// Close finalizes the staged file into the stash (single-file artifact)
// and commits the metadata + sidecar. pkg/sftp calls this on the SFTP
// CLOSE request. A mid-transfer failure is recorded as partial (§8.2).
func (u *sftpUpload) Close() error {
	_ = u.f.Close()
	if u.failed {
		_ = u.srv.Meta.UpdateOnPartial(u.id, u.size, time.Now().UTC())
		_ = os.RemoveAll(u.stagingDir)
		log.Printf("sftp upload partial: id=%s size=%d", u.id, u.size)
		return nil
	}
	final, err := u.target.FinalizeStaging(u.stagingDir, u.dayDir, u.id, false, []string{u.origName}, "")
	if err != nil {
		log.Printf("sftp finalize id=%s: %v", u.id, err)
		_ = u.srv.Meta.UpdateOnPartial(u.id, u.size, time.Now().UTC())
		// Return the error so the SFTP client sees the upload FAILED rather than a silent
		// success -- a fully-received-then-dropped upload is exactly the undetected loss the
		// buffer/flush design exists to prevent. The staging dir is retained for retry/backfill.
		return err
	}
	status := meta.StatusComplete
	if u.truncated {
		status = meta.StatusTruncated
	}
	if err := u.srv.commit(u.id, status, final, u.buffered, u.username); err != nil {
		log.Printf("sftp commit id=%s: %v", u.id, err)
	}
	return nil
}

// sanitizeUploadName reduces a client-supplied name to a safe basename:
// no path separators, no traversal. Empty result tells the caller to fall
// back to the bare ID.
func sanitizeUploadName(raw string) string {
	clean := filepath.Base(raw)
	if clean == "." || clean == ".." || clean == string(filepath.Separator) {
		return ""
	}
	return clean
}
