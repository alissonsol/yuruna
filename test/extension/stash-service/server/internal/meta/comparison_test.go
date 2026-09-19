// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package meta

import (
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/text/unicode/norm"
)

func TestUnicodeComparisonPolicy(t *testing.T) {
	if norm.Version != "15.0.0" {
		t.Fatalf("Unicode comparison tables changed to %s; review the comparison policy before upgrading", norm.Version)
	}
	for _, pair := range [][2]string{{"café.txt", "CAFE\u0301.TXT"}, {"Straße", "STRASSE"}, {"Σ", "ς"}, {"資料😀", "資料😀"}} {
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
