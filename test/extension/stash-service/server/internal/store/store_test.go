// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package store

import "testing"

// Each case mirrors a §6.3 rule or its boundary. Cases for §13's
// option-c outcome cover the disallowed-character path.
func TestExtractExtension(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		// Rule 1: no dot.
		{"no-dot/Makefile", "Makefile", ""},
		{"no-dot/LICENSE", "LICENSE", ""},
		{"empty", "", ""},

		// Rule 2: leading-dot dotfile (wins over multi-dot).
		{"dotfile/.bashrc", ".bashrc", ""},
		{"dotfile/.gitignore", ".gitignore", ""},
		{"dotfile/.config.json", ".config.json", ""},

		// Rule 3: from first dot onward — preserves compound extensions.
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

		// Rule 5 + §13 decision (option c): any disallowed char -> "".
		{"charset/space", "file.bad name", ""},
		{"charset/colon", "file.bad:name", ""},
		{"charset/unicode", "file.café", ""},
		{"charset/parens", "file.(1)", ""},
		// Underscore and hyphen ARE allowed per §10's table.
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
