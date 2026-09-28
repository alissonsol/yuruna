// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
package fsutil

import (
	"errors"
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
