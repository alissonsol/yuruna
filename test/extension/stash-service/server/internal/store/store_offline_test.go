// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package store

import (
	"os"
	"path/filepath"
	"testing"
)

// New must be best-effort: when the share is offline at startup the folder is
// an unmountable/unwritable mountpoint and the pre-create mkdirs fail, but the
// daemon must still come up and buffer locally (§8.4). Simulate an
// uncreatable share by rooting it under a regular file (MkdirAll then fails).
func TestNewIsBestEffortWhenShareUncreatable(t *testing.T) {
	tmp := t.TempDir()
	blocker := filepath.Join(tmp, "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := New(filepath.Join(blocker, "stash", "host")) // parent is a file
	if err != nil {
		t.Fatalf("New must not fail when share dirs are uncreatable, got: %v", err)
	}
	if st == nil {
		t.Fatal("New returned a nil store")
	}
}
