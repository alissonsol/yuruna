// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
package fsutil

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type failingFile struct {
	syncErr, closeErr error
	operations        []string
}

func (f *failingFile) Sync() error  { f.operations = append(f.operations, "sync"); return f.syncErr }
func (f *failingFile) Close() error { f.operations = append(f.operations, "close"); return f.closeErr }
func TestSyncCloseReportsWritebackFailures(t *testing.T) {
	syncErr, closeErr := errors.New("sync failed"), errors.New("close failed")
	for _, pair := range [][2]error{{nil, nil}, {syncErr, nil}, {nil, closeErr}, {syncErr, closeErr}} {
		f := &failingFile{syncErr: pair[0], closeErr: pair[1]}
		got := SyncClose(f)
		if len(f.operations) != 2 || f.operations[0] != "sync" || f.operations[1] != "close" {
			t.Fatalf("operations=%v", f.operations)
		}
		for _, want := range pair {
			if want != nil && !errors.Is(got, want) {
				t.Fatalf("got %v, missing %v", got, want)
			}
		}
		if pair[0] == nil && pair[1] == nil && got != nil {
			t.Fatal(got)
		}
	}
}

func TestUploadNameCrossPlatform(t *testing.T) {
	for _, raw := range []string{"report.txt", `C:\folder\report.txt`, "/folder/report.txt"} {
		if name := UploadName(raw); name != "report.txt" {
			t.Fatalf("%q sanitized to %q", raw, name)
		}
	}
	for _, raw := range []string{"", "..", "/", "\x00"} {
		if name := UploadName(raw); name != "" {
			t.Fatalf("unsafe name %q survived", name)
		}
	}
}
func TestUniqueUploadPathPreservesExistingFiles(t *testing.T) {
	dir := t.TempDir()
	original := filepath.Join(dir, "report.txt")
	if err := os.WriteFile(original, []byte("first"), 0600); err != nil {
		t.Fatal(err)
	}
	second, err := UniqueUploadPath(dir, "report.txt")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte("second"), 0600); err != nil {
		t.Fatal(err)
	}
	third, err := UniqueUploadPath(dir, "report.txt")
	if err != nil || third == original || third == second {
		t.Fatalf("duplicate path: %s %v", third, err)
	}
	if b, err := os.ReadFile(original); err != nil || string(b) != "first" {
		t.Fatalf("original overwritten: %q %v", b, err)
	}
}
