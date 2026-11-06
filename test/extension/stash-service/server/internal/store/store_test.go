// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 420ad081-4aa4-49a2-bc82-cd16a29f1d4f

package store

import "testing"

// Each case mirrors one stored-name rule or its boundary (see
// https://yuruna.link/429e934f-000b); the disallowed-character cases cover the
// rule that discards the whole extension.
func TestExtractExtension(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		// Reserved names must not collide with bookkeeping or archive markers.
		{"reserved/sidecar", "x.yuruna.meta.json", ""},
		{"reserved/sidecar-case", "x.YURUNA.META.JSON", ""},
		{"reserved/staging", "app.staging", ""},
		{"reserved/archive", "x.yuruna.archive.zip", ""},
		{"reserved/compound", "x.notes.yuruna.meta.json", ""},
		// Rule 1: no dot.
		{"no-dot/Makefile", "Makefile", ""},
		{"no-dot/LICENSE", "LICENSE", ""},
		{"empty", "", ""},

		// Rule 2: leading-dot dotfile (wins over multi-dot).
		{"dotfile/.bashrc", ".bashrc", ""},
		{"dotfile/.gitignore", ".gitignore", ""},
		{"dotfile/.config.json", ".config.json", ""},

		// Rule 3: from first dot onward -- preserves compound extensions.
		{"compound/report.final.v2.pdf", "report.final.v2.pdf", ".final.v2.pdf"},
		{"compound/archive.tar.gz", "archive.tar.gz", ".tar.gz"},
		{"single/notes.txt", "notes.txt", ".txt"},

		// Rule 6: lowercased on disk; originalFilename keeps case.
		{"case/report.PDF", "report.PDF", ".pdf"},
		{"case/IMG.JPEG", "IMG.JPEG", ".jpeg"},

		// Rule 4: 32-char cap including leading dot.
		// 33-char extension (incl dot) trims to 32, then lowercase.
		{
			"length/32-cap",
			"x." + repeat("a", 50), // produces .aaaa...
			"." + repeat("a", 31),
		},

		// Any disallowed character rejects the whole extension.
		{"charset/space", "file.bad name", ""},
		{"charset/colon", "file.bad:name", ""},
		{"charset/unicode", "file.café", ""},
		{"charset/parens", "file.(1)", ""},
		// Underscore and hyphen are valid extension characters.
		{"charset/underscore-ok", "file.tar_gz", ".tar_gz"},
		{"charset/hyphen-ok", "file.tar-gz", ".tar-gz"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ExtractExtension(tc.in); got != tc.want {
				t.Fatalf("ExtractExtension(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func repeat(s string, n int) string {
	out := make([]byte, 0, n*len(s))
	for i := 0; i < n; i++ {
		out = append(out, s...)
	}
	return string(out)
}
