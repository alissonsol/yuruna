// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42a3f7c2-6d91-4e0b-b8c5-17f2e9a4d036

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// Two daemons on one share, or one daemon's writes racing each other, each
// publish whole snapshots: a fixed temp name lets one writer rename another's
// half away and report a failure that is not there.
func TestIndependentStoresPublishCompleteStatusSnapshots(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the service runs on Linux; Windows rejects concurrent renames onto one target")
	}
	dir := t.TempDir()
	stores := make([]*Store, 8)
	for i := range stores {
		stores[i] = New(dir, time.Now())
	}
	done := make(chan struct{})
	for _, s := range stores {
		go func(s *Store) {
			for i := 0; i < 50; i++ {
				s.Beat(time.Now(), true)
			}
			done <- struct{}{}
		}(s)
	}
	for range stores {
		<-done
	}
	for i, s := range stores {
		if h := s.Health(); !h.Healthy {
			t.Errorf("store %d reports %q", i, h.LastError)
		}
	}
	b, err := os.ReadFile(filepath.Join(dir, "status.json"))
	if err != nil {
		t.Fatal(err)
	}
	var st Status
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatalf("partial status: %v", err)
	}
	if leftovers, _ := filepath.Glob(filepath.Join(dir, "*.tmp*")); len(leftovers) != 0 {
		t.Fatalf("temporary files left behind: %v", leftovers)
	}
}
