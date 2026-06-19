// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package detect

import (
	"os"
	"path/filepath"
	"testing"

	"stash-server/internal/config"
)

func TestClassifyByExtension(t *testing.T) {
	cases := []struct {
		name      string
		filename  string
		body      []byte
		wantClass string
		wantText  bool
	}{
		{"plain text ext", "notes.txt", []byte("hello world\n"), config.ClassText, true},
		{"markdown", "README.md", []byte("# Title\n"), config.ClassText, true},
		{"json by ext", "data.json", []byte(`{"a":1}`), config.ClassText, true},
		{"yaml", "config.yaml", []byte("a: 1\n"), config.ClassText, true},
		{"png magic", "pic.png", []byte("\x89PNG\r\n\x1a\n0000"), config.ClassImage, false},
		{"pdf magic", "doc.pdf", []byte("%PDF-1.7\n%..."), config.ClassPDF, false},
		{"svg is download-only other", "logo.svg", []byte(`<svg xmlns="http://www.w3.org/2000/svg"></svg>`), config.ClassOther, false},
		{"html is download-only other", "page.html", []byte("<!doctype html><html></html>"), config.ClassOther, false},
		{"gif image", "anim.gif", []byte("GIF89a\x00\x00"), config.ClassImage, false},
		{"binary other", "blob.bin", []byte{0x00, 0x01, 0x02, 0x00, 0xff, 0xfe}, config.ClassOther, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Classify(c.body, c.filename)
			if got.ContentClass != c.wantClass {
				t.Errorf("class = %q, want %q (mime=%q)", got.ContentClass, c.wantClass, got.MimeType)
			}
			if got.IsText != c.wantText {
				t.Errorf("isText = %v, want %v", got.IsText, c.wantText)
			}
		})
	}
}

func TestClassifyExtensionlessText(t *testing.T) {
	// No extension, printable UTF-8 → text/plain (a README/LICENSE/Makefile).
	got := Classify([]byte("all: build\n\tgo build ./...\n"), "Makefile")
	if got.ContentClass != config.ClassText || !got.IsText {
		t.Fatalf("extensionless text misclassified: %+v", got)
	}
}

func TestClassifyEmptyIsText(t *testing.T) {
	got := Classify(nil, "empty")
	if !got.IsText || got.ContentClass != config.ClassText {
		t.Fatalf("empty artifact should be text, got %+v", got)
	}
}

func TestLooksLikeTextRejectsNUL(t *testing.T) {
	if looksLikeText([]byte("ab\x00cd")) {
		t.Fatal("content with a NUL byte must not be text")
	}
}

func TestDetectFileHeuristic(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.txt")
	if err := os.WriteFile(p, []byte("plain text content"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := New().DetectFile(p, "a.txt")
	if !got.IsText || got.ContentClass != config.ClassText {
		t.Fatalf("DetectFile text = %+v", got)
	}
	// Missing file degrades to other, never panics.
	missing := New().DetectFile(filepath.Join(dir, "nope"), "nope")
	if missing.ContentClass != config.ClassOther {
		t.Fatalf("missing file should be other, got %+v", missing)
	}
}
