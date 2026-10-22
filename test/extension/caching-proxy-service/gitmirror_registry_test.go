// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMirrorRepositoryNormalization(t *testing.T) {
	for _, input := range []string{"Example/Repo", "https://github.com/Example/Repo.git", "git@github.com:Example/Repo.git", "ssh://git@github.com/Example/Repo.git"} {
		got, err := canonicalMirrorRepository(input)
		if err != nil || got != "example/repo" {
			t.Fatalf("%q: %q %v", input, got, err)
		}
	}
	for _, input := range []string{"https://token@github.com/a/b", "https://github.com.evil/a/b", "https://github.com:443/a/b", "-x/a", "a/../b", "file:///tmp/a", "a/b?x", "a/b#x", "a/%2e%2e", " a/b", "a//b", "ssh://password@github.com/a/b"} {
		if _, err := canonicalMirrorRepository(input); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
	if mirrorRepoKey("a--b/c") == mirrorRepoKey("a/b--c") {
		t.Fatal("repository storage identities collide")
	}
}
func TestMirrorRefValidation(t *testing.T) {
	for _, ref := range []string{"HEAD", "refs/heads/main", "refs/heads/feature/topic", "refs/tags/v1", strings.Repeat("a", 40)} {
		if !validMirrorRef(ref) {
			t.Fatal(ref)
		}
	}
	for _, ref := range []string{"main", "--help", "refs/heads/../x", "refs/heads/a.lock", "refs/heads/a b", "refs/heads/x@{1}", "refs/heads/a\nb"} {
		if validMirrorRef(ref) {
			t.Fatal(ref)
		}
	}
}
func TestMirrorStrictJSONRejectsAmbiguousBodies(t *testing.T) {
	for _, body := range []string{`{"repository":"a/b","repository":"c/d"}`, `{"repository":"a/b"} {}`, `{"unknown":true}`, string([]byte{'{', '"', 0xff, '"', ':', '1', '}'})} {
		var request mirrorRequest
		if strictMirrorJSON([]byte(body), &request, 4096) == nil {
			t.Fatalf("accepted %q", body)
		}
	}
}
func TestMirrorRegistrationPersistsAndPoolFailureRetainsDiscovery(t *testing.T) {
	h := newMirrorHarness(t)
	if err := persistMirrorRegistration(h.c.options, "other/repo"); err != nil {
		t.Fatal(err)
	}
	if err := h.c.registry.reload(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !h.c.registry.contains("other/repo") {
		t.Fatal("registration lost")
	}
	h.c.registry.mu.Lock()
	h.c.registry.pool = []string{"pool/repo"}
	h.c.registry.mu.Unlock()
	h.c.registry.options.PoolStore = filepath.Join(t.TempDir(), "unavailable.git")
	h.c.registry.options.PoolRef = "main"
	if err := h.c.registry.reload(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !h.c.registry.contains("pool/repo") {
		t.Fatal("unavailable pool lost previous discovery")
	}
}
func TestMirrorPoolScalarsPreserveNonGitHubSources(t *testing.T) {
	repos, err := parseMirrorPoolRepositories("frameworkUrl: 'https://github.com/example/repo.git'\nprojectUrl: file:///operator/project\n")
	if err != nil || len(repos) != 1 || repos[0] != "example/repo" {
		t.Fatalf("%v %v", repos, err)
	}
}
func TestMirrorRejectsRetentionBelowHostMaximum(t *testing.T) {
	h := newMirrorHarness(t)
	options := h.c.options
	options.Limits.Retention = 8 * 24 * 60 * 60 * 1e9
	if c, err := newMirrorCoordinator(context.Background(), options); err == nil {
		c.close()
		t.Fatal("eight-day retention accepted")
	}
}
func TestMirrorMissingCredentialFileStaysAbsent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent")
	var output strings.Builder
	if err := mirrorCredential(path, "get", strings.NewReader("protocol=https\nhost=github.com\n"), &output); err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatal("missing credential produced a token")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("credential file was minted")
	}
}
