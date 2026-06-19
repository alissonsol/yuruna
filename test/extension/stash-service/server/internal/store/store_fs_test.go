// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package store

import (
	"os"
	"path/filepath"
	"testing"
)

// TestNetworkMountFromMountinfo covers the cifs-nofail trap: an unmounted
// share leaves a writable LOCAL mountpoint, so "online" must require an
// actual network mount under the path, not mere writability.
func TestNetworkMountFromMountinfo(t *testing.T) {
	const mounted = `23 28 0:1 / / rw,relatime - ext4 /dev/sda1 rw
26 23 0:21 / /mnt/ystash-nas rw,relatime shared:1 - cifs //server/work rw,vers=3.1.1`
	const unmounted = `23 28 0:1 / / rw,relatime - ext4 /dev/sda1 rw`

	cases := []struct {
		name    string
		content string
		target  string
		want    bool
	}{
		{"share mounted, nested target", mounted, "/mnt/ystash-nas/stash/42ab", true},
		{"share mounted, exact mountpoint", mounted, "/mnt/ystash-nas", true},
		{"share unmounted -> local fallback", unmounted, "/mnt/ystash-nas/stash/42ab", false},
		{"unrelated path on root fs", mounted, "/var/lib/stash-server", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := networkMountFromMountinfo(tc.content, tc.target); got != tc.want {
				t.Fatalf("networkMountFromMountinfo(%q) = %v, want %v", tc.target, got, tc.want)
			}
		})
	}
}

func TestDirSize(t *testing.T) {
	root := t.TempDir()
	sub := filepath.Join(root, "a", "b")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "f1"), make([]byte, 100), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "f2"), make([]byte, 250), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := DirSize(root)
	if err != nil {
		t.Fatalf("DirSize: %v", err)
	}
	if got != 350 {
		t.Fatalf("DirSize = %d, want 350", got)
	}

	// A missing root is size 0, not an error (the buffer may not exist yet).
	if got, err := DirSize(filepath.Join(root, "nope")); err != nil || got != 0 {
		t.Fatalf("DirSize(missing) = %d, %v; want 0, nil", got, err)
	}
}

func TestAtomicCopyFile(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.bin")
	want := []byte("the payload")
	if err := os.WriteFile(src, want, 0o600); err != nil {
		t.Fatal(err)
	}
	dstDir := filepath.Join(dir, "share", "files", "2026", "06", "14")
	if err := os.MkdirAll(dstDir, 0o700); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dstDir, "a1b2.bin")
	if err := AtomicCopyFile(src, dst); err != nil {
		t.Fatalf("AtomicCopyFile: %v", err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dst: %v", err)
	}
	if string(got) != string(want) {
		t.Fatalf("copied content = %q, want %q", got, want)
	}
	// No temp file should remain in the destination directory.
	entries, _ := os.ReadDir(dstDir)
	if len(entries) != 1 {
		t.Fatalf("dst dir has %d entries, want 1 (temp leftover?)", len(entries))
	}
}
