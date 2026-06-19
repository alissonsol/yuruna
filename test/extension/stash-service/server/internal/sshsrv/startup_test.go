// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import (
	"os"
	"path/filepath"
	"testing"

	"stash-server/internal/config"
	"stash-server/internal/id"
	"stash-server/internal/meta"
	"stash-server/internal/store"
)

// Regression for the NAS-offline lockout: when the share is offline at
// startup (cifs mount failed), the host key cannot be written to the share,
// but the daemon must still start (§8.4) using a VM-local fallback key —
// rather than crash-looping and taking SSH + the UI down with it.
func TestNewStartsWhenShareUnwritable(t *testing.T) {
	tmp := t.TempDir()
	// Root the "share" under a regular file so every write beneath it fails,
	// mimicking an unmounted, root-owned /mnt/ystash-nas.
	blocker := filepath.Join(tmp, "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	shareFolder := filepath.Join(blocker, "stash", "host")
	st, err := store.New(shareFolder)
	if err != nil {
		t.Fatalf("store.New: %v", err)
	}
	buf, err := store.NewFilesOnly(filepath.Join(tmp, "buffer"))
	if err != nil {
		t.Fatalf("buffer store: %v", err)
	}
	m, err := meta.Open(filepath.Join(tmp, "stash.sqlite"))
	if err != nil {
		t.Fatalf("meta.Open: %v", err)
	}
	defer m.Close()
	ids := id.New(st.FilesRoot(), buf.FilesRoot())

	srv, err := New(st, buf, m, ids)
	if err != nil {
		t.Fatalf("New must start with the share offline, got: %v", err)
	}
	if srv == nil {
		t.Fatal("nil server")
	}
	// The host key must have landed on the VM-local fallback (under buffer/).
	fallback := filepath.Join(buf.Folder, config.HostKeyDirName, config.HostKeyFileName)
	if _, err := os.Stat(fallback); err != nil {
		t.Fatalf("fallback host key not written under buffer: %v", err)
	}
}

// A PRESENT-but-corrupt share host key must NOT be silently overwritten — the
// daemon must fail loud so systemd retries, preserving the durable key
// (regression guard: a transient cifs read must not rotate the host key).
func TestHostKeyFailLoudOnCorruptShareKey(t *testing.T) {
	tmp := t.TempDir()
	primary := filepath.Join(tmp, "share", "hostkey", "key")
	if err := os.MkdirAll(filepath.Dir(primary), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(primary, []byte("not a valid pem key"), 0o600); err != nil {
		t.Fatal(err)
	}
	fallback := filepath.Join(tmp, "buffer", "hostkey", "key")
	if _, err := loadOrGenerateHostKey(primary, fallback); err == nil {
		t.Fatal("expected an error for a present-but-corrupt share key, got nil (key would have been overwritten)")
	}
	// The corrupt key must be left intact (not overwritten with a fresh one).
	if b, _ := os.ReadFile(primary); string(b) != "not a valid pem key" {
		t.Fatal("present share key was overwritten despite being unreadable")
	}
}

// An offline-first key living only in the VM-local fallback must be PROMOTED
// to the share once the share is reachable + keyless, so a later reimage does
// not mint a new key and break client trust (§4.4).
func TestHostKeyPromotedFromFallback(t *testing.T) {
	tmp := t.TempDir()
	// Generate a valid key by writing one to a throwaway "primary".
	seed := filepath.Join(tmp, "seed", "key")
	if _, err := loadOrGenerateHostKey(seed, filepath.Join(tmp, "seedfb", "key")); err != nil {
		t.Fatal(err)
	}
	validKey, err := os.ReadFile(seed)
	if err != nil {
		t.Fatal(err)
	}
	// Place it ONLY in the fallback; the share primary is absent but writable.
	fallback := filepath.Join(tmp, "buffer", "hostkey", "key")
	if err := os.MkdirAll(filepath.Dir(fallback), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fallback, validKey, 0o600); err != nil {
		t.Fatal(err)
	}
	primary := filepath.Join(tmp, "share", "hostkey", "key") // absent, parent creatable
	if _, err := loadOrGenerateHostKey(primary, fallback); err != nil {
		t.Fatalf("loadOrGenerateHostKey: %v", err)
	}
	got, err := os.ReadFile(primary)
	if err != nil {
		t.Fatalf("key was not promoted to the share: %v", err)
	}
	if string(got) != string(validKey) {
		t.Fatal("promoted key differs from the fallback key")
	}
}
