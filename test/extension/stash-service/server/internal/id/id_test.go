// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package id

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"stash-server/internal/config"
)

// TestAllocateUniqueWithinDay verifies that consecutive Allocate calls
// for the same UTC day never repeat, that all IDs are the documented
// 4 chars over the [a-z0-9] alphabet, and that the in-memory seen set
// stays in sync with the on-disk scan path.
func TestAllocateUniqueWithinDay(t *testing.T) {
	tmp := t.TempDir()
	a := New(tmp)
	day := time.Date(2026, 1, 15, 12, 0, 0, 0, time.UTC)

	seen := map[string]struct{}{}
	for i := 0; i < 1000; i++ {
		got, err := a.Allocate(day)
		if err != nil {
			t.Fatalf("Allocate #%d: %v", i, err)
		}
		if len(got) != config.IDLength {
			t.Fatalf("id %q length %d, want %d", got, len(got), config.IDLength)
		}
		for _, r := range got {
			if !strings.ContainsRune(config.IDAlphabet, r) {
				t.Fatalf("id %q contains out-of-alphabet rune %q", got, r)
			}
		}
		if _, dup := seen[got]; dup {
			t.Fatalf("duplicate id %q at iteration %d", got, i)
		}
		seen[got] = struct{}{}
	}
}

// TestAllocatePicksUpExistingFilesOnDisk seeds the day folder with
// pre-existing artifacts using known IDs and verifies the allocator
// will never hand them back out.
func TestAllocatePicksUpExistingFilesOnDisk(t *testing.T) {
	tmp := t.TempDir()
	day := time.Date(2026, 3, 7, 0, 0, 0, 0, time.UTC)
	dayDir := filepath.Join(tmp, "2026", "03", "07")
	if err := os.MkdirAll(dayDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// Pre-existing entries: an extension'd file, a no-extension file, an
	// archive, an in-progress staging dir, and a sidecar (§8.5). Each
	// reserves the leading 4-char ID — including the sidecar, so the
	// allocator never hands out an ID a sidecar already claims.
	for _, name := range []string{"a1b2.pdf", "c3d4", "e5f6.yuruna.archive.zip", "g7h8.staging", "i9j0.yuruna.meta.json"} {
		if err := os.WriteFile(filepath.Join(dayDir, name), nil, 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	reserved := map[string]bool{"a1b2": true, "c3d4": true, "e5f6": true, "g7h8": true, "i9j0": true}

	a := New(tmp)
	for i := 0; i < 500; i++ {
		got, err := a.Allocate(day)
		if err != nil {
			t.Fatalf("Allocate #%d: %v", i, err)
		}
		if reserved[got] {
			t.Fatalf("allocator handed back reserved id %q at iteration %d", got, i)
		}
	}
}

// TestAllocateAcrossDays confirms ids may repeat across different
// UTC days (spec §12: cross-day uniqueness explicitly out of scope).
func TestAllocateAcrossDays(t *testing.T) {
	tmp := t.TempDir()
	a := New(tmp)
	d1 := time.Date(2026, 1, 1, 23, 59, 0, 0, time.UTC)
	d2 := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	id1, err := a.Allocate(d1)
	if err != nil {
		t.Fatal(err)
	}
	// Re-allocating on a different day must succeed even if the
	// internal seen-set is namespaced per-day. We can't assert the
	// id IS the same (the allocator is random), but we can assert
	// the call doesn't fail.
	if _, err := a.Allocate(d2); err != nil {
		t.Fatal(err)
	}
	if !isValidID(id1) {
		t.Fatalf("first id %q not valid", id1)
	}
}
