// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package meta

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// TestInsertPendingReportsADuplicateID pins the classification the ingest
// paths branch on. Every constraint violation shares one primary result code,
// so a duplicate must be told apart from a schema violation by the extended
// code -- get that wrong and a broken row looks like a collision worth
// retrying, or a collision looks like a fatal storage failure.
func TestInsertPendingReportsADuplicateID(t *testing.T) {
	m, err := Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer m.Close()
	now := time.Date(2026, 9, 6, 8, 13, 29, 0, time.UTC)

	if err := m.InsertPending(&Record{ID: "6tat", Username: "amisad-poc", CreatedAt: now, Status: StatusPending}); err != nil {
		t.Fatalf("first insert: %v", err)
	}
	// The same id a day later: legal for the allocator's day-scoped scan,
	// refused by the id column, which is a primary key over the whole table.
	err = m.InsertPending(&Record{ID: "6tat", Username: "other", CreatedAt: now.Add(24 * time.Hour), Status: StatusPending})
	if err == nil {
		t.Fatal("second insert of the same id succeeded; the id column is not enforcing uniqueness")
	}
	if !errors.Is(err, ErrDuplicateID) {
		t.Fatalf("duplicate insert error = %v, want it to match ErrDuplicateID", err)
	}

	// A different constraint violation (status is CHECK-constrained) must NOT
	// be read as a collision: retrying it would loop on a row that can never
	// be written.
	err = m.InsertPending(&Record{ID: "9xk2", Username: "u", CreatedAt: now, Status: "not-a-status"})
	if err == nil {
		t.Fatal("insert with an out-of-domain status succeeded; the CHECK constraint is gone")
	}
	if errors.Is(err, ErrDuplicateID) {
		t.Fatalf("CHECK violation classified as a duplicate: %v", err)
	}
}

// TestExistsSpansEveryDay covers the lookup the allocator asks before it
// hands an id out.
func TestExistsSpansEveryDay(t *testing.T) {
	m, err := Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer m.Close()

	if got, err := m.Exists("6tat"); err != nil || got {
		t.Fatalf("Exists on an empty index = (%v, %v), want (false, nil)", got, err)
	}
	if err := m.InsertPending(&Record{ID: "6tat", Username: "amisad-poc", CreatedAt: time.Date(2026, 9, 6, 8, 13, 29, 0, time.UTC), Status: StatusPending}); err != nil {
		t.Fatalf("insert: %v", err)
	}
	if got, err := m.Exists("6tat"); err != nil || !got {
		t.Fatalf("Exists after insert = (%v, %v), want (true, nil)", got, err)
	}
}
