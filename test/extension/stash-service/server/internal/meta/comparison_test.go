// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package meta

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/text/unicode/norm"
)

func TestUnicodeComparisonPolicy(t *testing.T) {
	if norm.Version != "17.0.0" {
		t.Fatalf("Unicode comparison tables changed to %s; review the comparison policy before upgrading", norm.Version)
	}
	for _, pair := range [][2]string{{"café.txt", "CAFE\u0301.TXT"}, {"Straße", "STRASSE"}, {"Σ", "ς"}, {"資料😀", "資料😀"}, {"\u1c89.txt", "\u1c8a.TXT"}} {
		if ComparisonKey(pair[0]) != ComparisonKey(pair[1]) || !ContainsName(pair[0], pair[1]) {
			t.Fatalf("equivalence missing: %q", pair)
		}
	}
	if ComparisonKey("cafe") == ComparisonKey("café") {
		t.Fatal("accent distinctions were erased")
	}
	if ContainsName("actual.txt", "%") || ContainsName("actual.txt", "_") {
		t.Fatal("literal search became a SQL wildcard")
	}
}

func TestUnicodeSearchPreservesDistinctOriginalRecordsAndLimit(t *testing.T) {
	m, err := Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	for i, name := range []string{"café.txt", "cafe\u0301.txt", "different.txt"} {
		id := []string{"aaaa", "bbbb", "cccc"}[i]
		if err := m.InsertPending(&Record{ID: id, Username: "Straße", OriginalFilename: name, CreatedAt: time.Unix(int64(i), 0).UTC(), Status: StatusPending}); err != nil {
			t.Fatal(err)
		}
	}
	rows, err := m.Search(&SearchFilter{OriginalSubstring: "CAFÉ", UsernameSubstring: "STRASSE"})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].OriginalFilename != "cafe\u0301.txt" || rows[1].OriginalFilename != "café.txt" || rows[0].ID == rows[1].ID {
		t.Fatalf("equivalent names merged or changed: %#v", rows)
	}
	rows, err = m.Search(&SearchFilter{OriginalSubstring: "CAFÉ", Limit: 1})
	if err != nil || len(rows) != 1 || rows[0].ID != "bbbb" {
		t.Fatalf("limit ran before normalization filter: %#v %v", rows, err)
	}
}

func TestTimestampMigrationAndSearchBoundaries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stash.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(schema); err != nil {
		t.Fatal(err)
	}
	// Reproduce an old database with mixed fractional widths and an offset.
	for i, stamp := range []string{"2026-09-27T00:00:00Z", "2026-09-27T00:00:00.1Z", "2026-09-27T00:00:00.123456789Z", "2026-09-27T01:00:00.2+01:00"} {
		id := []string{"zero", "one", "nano", "offset"}[i]
		if _, err := db.Exec("INSERT INTO uploads(id, storedPath, originalFilename, createdAt, receivedAt, status) VALUES(?, '', '', ?, ?, 'complete')", id, stamp, stamp); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()
	m, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	start := time.Date(2026, 9, 27, 0, 0, 0, 0, time.UTC)
	end := start.Add(time.Second)
	rows, err := m.Search(&SearchFilter{CreatedAtFrom: &start, CreatedAtTo: &end, ReceivedAtFrom: &start, ReceivedAtTo: &end})
	if err != nil {
		t.Fatal(err)
	}
	expected := []string{"offset", "nano", "one", "zero"}
	if len(rows) != len(expected) {
		t.Fatalf("boundary search returned %d rows", len(rows))
	}
	for i, id := range expected {
		if rows[i].ID != id {
			t.Fatalf("order[%d] = %s, want %s", i, rows[i].ID, id)
		}
	}
	if rows[1].CreatedAt.Nanosecond() != 123456789 || rows[1].ReceivedAt.Nanosecond() != 123456789 {
		t.Fatal("migration lost precision")
	}
	var stored string
	if err := m.db.QueryRow("SELECT createdAt FROM uploads WHERE id='zero'").Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != "2026-09-27T00:00:00.000000000Z" {
		t.Fatalf("old timestamp not normalized: %s", stored)
	}
	exact, err := m.Search(&SearchFilter{CreatedAtFrom: &start, CreatedAtTo: &start})
	if err != nil || len(exact) != 1 || exact[0].ID != "zero" {
		t.Fatalf("exact boundary: %v %v", exact, err)
	}
	if err := m.InsertPending(&Record{ID: "new", CreatedAt: start.Add(300 * time.Millisecond), Status: StatusPending}); err != nil {
		t.Fatal(err)
	}
	if err := m.db.QueryRow("SELECT createdAt FROM uploads WHERE id='new'").Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(stored, ".300000000Z") {
		t.Fatalf("new writer not normalized: %s", stored)
	}
}

func TestTimestampMigrationRollsBackOnInvalidLegacyRow(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stash.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(schema); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO uploads(id, storedPath, originalFilename, createdAt, status) VALUES('good','','','2026-09-27T00:00:00Z','complete'),('bad','','','invalid','complete')"); err != nil {
		t.Fatal(err)
	}
	if m, err := Open(path); err == nil {
		m.Close()
		t.Fatal("invalid timestamp migration succeeded")
	}
	var stamp string
	var version int
	if err := db.QueryRow("SELECT createdAt FROM uploads WHERE id='good'").Scan(&stamp); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatal(err)
	}
	if stamp != "2026-09-27T00:00:00Z" || version != 0 {
		t.Fatalf("failed migration changed data/version: %s %d", stamp, version)
	}
}
