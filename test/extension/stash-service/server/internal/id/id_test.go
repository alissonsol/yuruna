// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package id

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"stash-service/internal/config"
)

// TestAllocateUniqueWithinDay verifies that consecutive Allocate calls
// for the same UTC day never repeat, that all IDs are the documented
// 4 chars over the [a-z0-9] alphabet, and that the in-memory seen set
// stays in sync with the on-disk scan path.
func TestAllocateUniqueWithinDay(t *testing.T) {
	tmp := t.TempDir()
	a := New(nil, tmp)
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
	// archive, an in-progress staging dir, and a sidecar (section 8.5). Each
	// reserves the leading 4-char ID -- including the sidecar, so the
	// allocator never hands out an ID a sidecar already claims.
	for _, name := range []string{"a1b2.pdf", "c3d4", "e5f6.yuruna.archive.zip", "g7h8.staging", "i9j0.yuruna.meta.json"} {
		if err := os.WriteFile(filepath.Join(dayDir, name), nil, 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	reserved := map[string]bool{"a1b2": true, "c3d4": true, "e5f6": true, "g7h8": true, "i9j0": true}

	a := New(nil, tmp)
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

// TestAllocateRejectsIDsClaimedOnAnotherDay is the cross-day case. The day
// folder for d2 is empty, so the disk scan alone would happily reissue an id
// stored under d1 -- and the index, whose id column spans every day, would
// then refuse the upload. The existence check has to close that gap.
func TestAllocateRejectsIDsClaimedOnAnotherDay(t *testing.T) {
	tmp := t.TempDir()
	d1 := time.Date(2026, 1, 1, 23, 59, 0, 0, time.UTC)
	d2 := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)

	// Stand in for the index: whatever day 1 handed out stays claimed for good.
	claimed := map[string]bool{}
	a := New(func(id string) (bool, error) { return claimed[id], nil }, tmp)
	first, err := a.Allocate(d1)
	if err != nil {
		t.Fatalf("Allocate on day 1: %v", err)
	}
	claimed[first] = true

	// Day 2, from a fresh allocator: no memory of day 1 and an empty day
	// folder to scan. Refuse the first three candidates outright -- standing
	// in for ids older rows already own -- so the assertion does not depend on
	// the generator happening to redraw one.
	refused := map[string]bool{}
	b := New(func(id string) (bool, error) {
		if len(refused) < 3 {
			refused[id] = true
			return true, nil
		}
		return claimed[id], nil
	}, tmp)
	got, err := b.Allocate(d2)
	if err != nil {
		t.Fatalf("Allocate on day 2: %v", err)
	}
	if len(refused) != 3 {
		t.Fatalf("the index was consulted for %d candidate(s), want 3 -- a day-scoped allocator consults it for none", len(refused))
	}
	if refused[got] {
		t.Fatalf("allocator handed back %q after the index reported it taken", got)
	}
	if got == first {
		t.Fatalf("allocator reissued %q on %s, claimed since %s", got, d2.Format("2006-01-02"), d1.Format("2006-01-02"))
	}
	if !isValidID(got) {
		t.Fatalf("id %q not valid", got)
	}
}

// TestAllocateFailsWhenExistenceCheckFails pins the safe direction: an
// unanswered question about a candidate must fail the allocation, never pass
// as "free".
func TestAllocateFailsWhenExistenceCheckFails(t *testing.T) {
	a := New(func(string) (bool, error) { return false, errors.New("index unavailable") }, t.TempDir())
	if got, err := a.Allocate(time.Date(2026, 5, 4, 9, 0, 0, 0, time.UTC)); err == nil {
		t.Fatalf("Allocate returned %q, want an error when the existence check fails", got)
	}
}

// TestAllocateWithoutExistenceCheck keeps the standalone construction working
// for a caller that has no index behind it.
func TestAllocateWithoutExistenceCheck(t *testing.T) {
	a := New(nil, t.TempDir())
	got, err := a.Allocate(time.Date(2026, 5, 4, 9, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if !isValidID(got) {
		t.Fatalf("id %q not valid", got)
	}
}
