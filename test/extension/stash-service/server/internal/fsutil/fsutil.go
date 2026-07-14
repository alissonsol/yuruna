// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package fsutil holds small filesystem-durability primitives shared by the
// store and meta packages, so a fix to one cannot silently diverge from a copy.
package fsutil

import (
	"io"
	"os"
	"path/filepath"
)

// SyncDir fsyncs a directory so a rename/create within it survives a crash
// (Linux). Best-effort: not every platform supports directory sync, and the
// service runs on Linux where it does.
func SyncDir(dir string) {
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
}

// AtomicCommit crash-safely publishes a file at dst: it creates a temp file
// (named from tmpPrefix, e.g. ".sidecar-*.tmp") in dst's directory, runs fill to
// write the payload, fsyncs and closes it, chmods it to perm when perm != 0
// (perm == 0 skips the chmod, keeping os.CreateTemp's 0600), renames it over dst,
// and fsyncs dst's directory so the rename itself survives a crash. The temp is
// removed on any error. Shared by store.AtomicCopyFile (io.Copy from a source)
// and meta.atomicWriteFile (write a byte slice); the payload step is the only
// difference, injected as fill.
func AtomicCommit(dst, tmpPrefix string, perm os.FileMode, fill func(w io.Writer) error) error {
	tmp, err := os.CreateTemp(filepath.Dir(dst), tmpPrefix)
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // no-op once renamed away
	if err := fill(tmp); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if perm != 0 {
		if err := os.Chmod(tmpName, perm); err != nil {
			return err
		}
	}
	if err := os.Rename(tmpName, dst); err != nil {
		return err
	}
	SyncDir(filepath.Dir(dst))
	return nil
}
