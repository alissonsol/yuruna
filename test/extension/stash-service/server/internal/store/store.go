// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package store owns the filesystem side of the Stash Service: path
// resolution under the StashFolder (§6), per-day file directories,
// extension extraction (§6.3), and the staging-to-final move/zip step
// invoked by sshsrv after the SCP wire protocol completes.
package store

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"stash-server/internal/config"
)

// Store roots the per-VM Stash filesystem layout. All paths the daemon
// writes are derived from Folder; callers never compose paths by hand.
type Store struct {
	Folder string
}

// New initialises the on-disk layout (hostkey/, metadata/, files/) and
// returns a Store rooted at folder. Idempotent: re-running against an
// existing layout is a no-op.
func New(folder string) (*Store, error) {
	for _, sub := range []string{config.HostKeyDirName, config.MetadataDirName, config.FilesDirName} {
		if err := os.MkdirAll(filepath.Join(folder, sub), 0o700); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", sub, err)
		}
	}
	return &Store{Folder: folder}, nil
}

// HostKeyPath returns the path to the persistent SSH host key file.
func (s *Store) HostKeyPath() string {
	return filepath.Join(s.Folder, config.HostKeyDirName, config.HostKeyFileName)
}

// MetadataDBPath returns the SQLite file path under metadata/.
func (s *Store) MetadataDBPath() string {
	return filepath.Join(s.Folder, config.MetadataDirName, config.DatabaseFileName)
}

// DayDir returns the absolute path to files/yyyy/mm/dd/ for t (UTC).
// Creates the day directory if missing.
func (s *Store) DayDir(t time.Time) (string, error) {
	// time.Format with the magic reference date is zero-alloc for these
	// fields and produces the same string as three separate Sprintf calls.
	dir := filepath.Join(
		s.Folder,
		config.FilesDirName,
		t.UTC().Format("2006/01/02"),
	)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// FilesRoot returns the absolute path to <Folder>/files/.
func (s *Store) FilesRoot() string {
	return filepath.Join(s.Folder, config.FilesDirName)
}

// StagingDir returns and creates a per-invocation staging directory
// under the day folder. Files received via SCP land here first; the
// finalisation step either renames the single file out or zips the
// whole tree into <id>.yuruna.archive.zip.
func (s *Store) StagingDir(t time.Time, id string) (string, error) {
	dayDir, err := s.DayDir(t)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(dayDir, id+".staging")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// ExtractExtension implements §6.3's extension-extraction rules with
// the §13 decision (option c: discard the whole extension on any
// disallowed character). Returns the leading-dot extension lowercased,
// or the empty string when the filename has none / is a dotfile /
// contains a disallowed char.
func ExtractExtension(filename string) string {
	// Rule 1: no dot.
	idx := strings.Index(filename, ".")
	if idx < 0 {
		return ""
	}
	// Rule 2: leading-dot dotfile.
	if idx == 0 {
		return ""
	}
	// Rule 3: from first dot onward.
	ext := filename[idx:]
	// Rule 4: length cap (including leading dot).
	if len(ext) > config.ExtensionMaxLength {
		ext = ext[:config.ExtensionMaxLength]
	}
	// Rule 5: charset check. §13 decision is option (c): discard.
	for _, r := range ext {
		if !isAllowedExtensionRune(r) {
			return ""
		}
	}
	// Rule 6: lowercase.
	return strings.ToLower(ext)
}

func isAllowedExtensionRune(r rune) bool {
	switch {
	case r >= 'A' && r <= 'Z':
		return true
	case r >= 'a' && r <= 'z':
		return true
	case r >= '0' && r <= '9':
		return true
	case r == '.' || r == '_' || r == '-':
		return true
	}
	return false
}

// FinalizeResult is what FinalizeStaging returns to the caller so it
// can update the metadata record.
type FinalizeResult struct {
	StoredPath       string
	OriginalFilename string
	IsArchive        bool
	SizeBytes        int64
}

// FinalizeStaging promotes the staging directory at stagingDir to its
// final on-disk artifact based on what was received:
//
//   - Recursive flag set on the SCP command, OR more than one file, OR
//     any directory entry: zip the whole tree into <id>.yuruna.archive.zip.
//   - Exactly one file at the root and no directory entry: rename it
//     to <id>[.ext] (extension extracted from its filename per §6.3).
//
// The OriginalFilename returned mirrors §8.1:
//   - Single file: the client-supplied filename, original case.
//   - Recursive: the top-level directory name received.
//   - Multi-file: the first filename received (informative for the
//     human reading the dashboard later).
//
// The staging directory is removed on success.
func (s *Store) FinalizeStaging(stagingDir, dayDir, id string, recursive bool, fileNames []string, firstDirName string) (*FinalizeResult, error) {
	wantArchive := recursive || firstDirName != "" || len(fileNames) > 1

	if !wantArchive {
		if len(fileNames) != 1 {
			return nil, fmt.Errorf("finalize: expected exactly one file in single-mode, got %d", len(fileNames))
		}
		orig := fileNames[0]
		ext := ExtractExtension(orig)
		finalName := id + ext
		src := filepath.Join(stagingDir, orig)
		dst := filepath.Join(dayDir, finalName)
		if err := os.Rename(src, dst); err != nil {
			return nil, fmt.Errorf("rename single file: %w", err)
		}
		_ = os.RemoveAll(stagingDir)
		fi, err := os.Stat(dst)
		if err != nil {
			return nil, fmt.Errorf("stat final: %w", err)
		}
		return &FinalizeResult{
			StoredPath:       dst,
			OriginalFilename: orig,
			IsArchive:        false,
			SizeBytes:        fi.Size(),
		}, nil
	}

	// Archive path.
	finalName := id + config.ArchiveExtension
	dst := filepath.Join(dayDir, finalName)
	if err := zipDir(stagingDir, dst); err != nil {
		return nil, fmt.Errorf("zip staging: %w", err)
	}
	_ = os.RemoveAll(stagingDir)
	fi, err := os.Stat(dst)
	if err != nil {
		return nil, fmt.Errorf("stat archive: %w", err)
	}
	orig := firstDirName
	if orig == "" && len(fileNames) > 0 {
		orig = fileNames[0]
	}
	return &FinalizeResult{
		StoredPath:       dst,
		OriginalFilename: orig,
		IsArchive:        true,
		SizeBytes:        fi.Size(),
	}, nil
}

func zipDir(srcDir, dstZip string) error {
	out, err := os.Create(dstZip)
	if err != nil {
		return err
	}
	defer out.Close()
	zw := zip.NewWriter(out)
	defer zw.Close()
	return filepath.Walk(srcDir, func(p string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(srcDir, p)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		// Use forward slashes inside the archive (cross-platform).
		rel = filepath.ToSlash(rel)
		if info.IsDir() {
			_, err := zw.Create(rel + "/")
			return err
		}
		w, err := zw.Create(rel)
		if err != nil {
			return err
		}
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(w, f)
		return err
	})
}
