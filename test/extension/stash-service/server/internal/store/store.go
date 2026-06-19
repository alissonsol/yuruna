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
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"stash-server/internal/config"
)

// Store roots the share-side Stash filesystem layout (hostkey/ + files/)
// on the mounted stash share. All share paths the daemon writes are
// derived from Folder; callers never compose paths by hand. The metadata
// index and the offline buffer are VM-local and owned elsewhere (main).
type Store struct {
	Folder string
}

// New returns a Store rooted at the share folder and BEST-EFFORT pre-creates
// the share-side layout (hostkey/, files/). Pre-creation failure is NOT
// fatal: at startup the share may be offline/unmounted (§8.4), in which case
// folder is the unmounted, root-owned mountpoint and these mkdirs fail with
// EACCES — the daemon must still come up and buffer locally, creating the
// share dirs lazily (DayDir / the flush worker) once the share is writable.
// metadata/ is intentionally NOT created here — the SQLite index lives on the
// VM's local disk (§6.1, §8).
func New(folder string) (*Store, error) {
	for _, sub := range []string{config.HostKeyDirName, config.FilesDirName} {
		_ = os.MkdirAll(filepath.Join(folder, sub), 0o700) // best-effort; see doc
	}
	return &Store{Folder: folder}, nil
}

// NewFilesOnly returns a Store rooted at folder with only files/ created —
// used for the VM-local NAS-offline buffer (§8.4), which mirrors the
// share's files/yyyy/mm/dd layout (so a flush is a same-relative-path
// copy) but has no hostkey/ of its own.
func NewFilesOnly(folder string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(folder, config.FilesDirName), 0o700); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", config.FilesDirName, err)
	}
	return &Store{Folder: folder}, nil
}

// HostKeyPath returns the path to the persistent SSH host key file.
func (s *Store) HostKeyPath() string {
	return filepath.Join(s.Folder, config.HostKeyDirName, config.HostKeyFileName)
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

// ShareOnline reports whether the share-side StashFolder is backed by a
// live network mount AND is writable (§8.4). The network-mount check is
// essential: with cifs `nofail`, an unmounted share leaves a writable
// LOCAL mountpoint dir, so a write probe alone would silently store
// "on the share" on local disk and lose the data on reimage. Requiring
// a cifs/smb mount underneath the path defeats that trap.
func ShareOnline(shareFolder string) bool {
	return IsNetworkMount(shareFolder) && probeWritable(shareFolder)
}

// IsNetworkMount reports whether shareFolder sits on a cifs/smb mount,
// per /proc/self/mountinfo (Linux). On a non-Linux host or an unreadable
// mountinfo it returns false (treated as offline → uploads buffer).
func IsNetworkMount(shareFolder string) bool {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	return networkMountFromMountinfo(string(data), filepath.Clean(shareFolder))
}

// networkMountFromMountinfo is the pure core of IsNetworkMount: given the
// mountinfo text and a target path, it finds the most specific mount whose
// mount point is an ancestor of (or equal to) target and reports whether
// that mount's filesystem type is a network share.
func networkMountFromMountinfo(content, target string) bool {
	best, bestIsNet := -1, false
	for _, line := range strings.Split(content, "\n") {
		// Format (man 5 proc): ... <mountPoint(5)> ... " - " <fstype> <source> ...
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		sep := -1
		for i, f := range fields {
			if f == "-" {
				sep = i
				break
			}
		}
		if sep < 0 || sep+1 >= len(fields) {
			continue
		}
		mountPoint := fields[4]
		fstype := fields[sep+1]
		if !pathHasPrefix(target, mountPoint) {
			continue
		}
		if len(mountPoint) > best {
			best = len(mountPoint)
			bestIsNet = isNetworkFSType(fstype)
		}
	}
	return bestIsNet
}

func isNetworkFSType(fstype string) bool {
	switch fstype {
	case "cifs", "smb3", "smb", "nfs", "nfs4":
		return true
	}
	return false
}

// pathHasPrefix reports whether mountPoint is target itself or an ancestor
// directory of it. "/" is an ancestor of every absolute path.
func pathHasPrefix(target, mountPoint string) bool {
	if mountPoint == "/" {
		return true
	}
	return target == mountPoint || strings.HasPrefix(target, mountPoint+"/")
}

// probeWritable confirms dir accepts a create+remove. Cheap belt to the
// mount check (catches a read-only remount or a permission problem).
func probeWritable(dir string) bool {
	f, err := os.CreateTemp(dir, ".probe-*")
	if err != nil {
		return false
	}
	name := f.Name()
	_ = f.Close()
	_ = os.Remove(name)
	return true
}

// DirSize sums the bytes of regular files under root (the buffer-ceiling
// check, §8.4). A missing root is size 0, not an error.
func DirSize(root string) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		info, ierr := d.Info()
		if ierr != nil {
			return ierr
		}
		total += info.Size()
		return nil
	})
	return total, err
}

// AtomicCopyFile copies src to dst via a temp file in dst's directory plus
// fsync + rename, so a reader (or a crash) never sees a partial artifact
// on the share. Used by the flush worker (§8.4).
func AtomicCopyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".flush-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // no-op once renamed away
	if _, err := io.Copy(tmp, in); err != nil {
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
	return os.Rename(tmpName, dst)
}
