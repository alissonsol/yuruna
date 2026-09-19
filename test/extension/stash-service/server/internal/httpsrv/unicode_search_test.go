// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"stash-service/internal/meta"
	"testing"
)

func TestPeerUnicodeSearchUsesLocalComparisonPolicy(t *testing.T) {
	for _, name := range []string{"café.txt", "CAFE\u0301.txt", "資料😀.txt", "مرحبا.txt"} {
		filter := listFilter{Filename: name, Username: "STRASSE"}
		record := &meta.Record{OriginalFilename: name, Username: "Straße"}
		if !filter.match(record) || !meta.ContainsName(record.OriginalFilename, filter.toMetaFilter(0).OriginalSubstring) {
			t.Fatalf("local/peer policy diverged for %q", name)
		}
	}
	if cmpText("café", "CAFE\u0301") != 0 {
		t.Fatal("equivalent names have different ordering keys")
	}
	rows := []StashView{{ID: "bbbb", OriginalFilename: "cafe\u0301.txt"}, {ID: "aaaa", OriginalFilename: "café.txt"}}
	sortViews(rows, "filename", true)
	if rows[0].OriginalFilename == rows[1].OriginalFilename || rows[0].ID == rows[1].ID {
		t.Fatal("sorting rewrote colliding display names or identifiers")
	}
}
