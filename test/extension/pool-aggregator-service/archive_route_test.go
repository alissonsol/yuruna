// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// The /archive/ route and the archive-aware half of /go/cycle: the read paths that
// keep a dashboard link working after a host has moved its cycle results to the pool
// share and deleted its local copy.

package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const (
	testArchiveHost  = "4212abcdef0123456789abcdef012345"
	testArchiveCycle = "000123.2026-08-16.14-22-08." + testArchiveHost
)

// newArchiveFixture builds <root>/<hostId>/test-cycles/<cycle>/ with one artifact,
// committing it with the sentinel unless committed is false.
func newArchiveFixture(t *testing.T, committed bool) (root string, state *poolState) {
	t.Helper()
	root = t.TempDir()
	dir := filepath.Join(root, testArchiveHost, "test-cycles", testArchiveCycle)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cycle.html"), []byte("<html>results</html>"), 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	if committed {
		if err := os.WriteFile(filepath.Join(dir, ".yuruna-complete"), []byte("2026-08-16T14:40:11Z\n"), 0o644); err != nil {
			t.Fatalf("write sentinel: %v", err)
		}
	}
	return root, &poolState{archiveRoot: root}
}

func TestArchiveServesCommittedCycle(t *testing.T) {
	_, s := newArchiveFixture(t, true)

	rr := httptest.NewRecorder()
	s.handleArchive(rr, httptest.NewRequest(http.MethodGet, "/archive/"+testArchiveHost+"/test-cycles/"+testArchiveCycle+"/cycle.html", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("file: got %d, want 200", rr.Code)
	}
	if body := rr.Body.String(); body != "<html>results</html>" {
		t.Fatalf("file body = %q", body)
	}
	if cc := rr.Header().Get("Cache-Control"); cc != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", cc)
	}
}

// A dashboard click lands on a FOLDER url, so the route has to answer with a
// listing -- this is what http.ServeContent alone could not do.
func TestArchiveServesDirectoryListing(t *testing.T) {
	_, s := newArchiveFixture(t, true)

	rr := httptest.NewRecorder()
	s.handleArchive(rr, httptest.NewRequest(http.MethodGet, "/archive/"+testArchiveHost+"/test-cycles/"+testArchiveCycle+"/", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("listing: got %d, want 200", rr.Code)
	}
	if body := rr.Body.String(); !contains(body, "cycle.html") {
		t.Fatalf("listing does not mention the artifact: %q", body)
	}
}

func TestArchiveRejectsMalformedPaths(t *testing.T) {
	_, s := newArchiveFixture(t, true)

	cases := []struct {
		name string
		path string
	}{
		{"host id not 32 hex", "/archive/nothex/test-cycles/" + testArchiveCycle + "/"},
		{"host id wrong length", "/archive/4212ab/test-cycles/" + testArchiveCycle + "/"},
		{"second segment not test-cycles", "/archive/" + testArchiveHost + "/services/loki/"},
		{"cycle leaf not a cycle name", "/archive/" + testArchiveHost + "/test-cycles/etc/"},
		// On-share leaves are always the stripped identity, so a suffixed name can
		// only be a probe -- there is nothing it could legitimately address.
		{"incomplete suffix", "/archive/" + testArchiveHost + "/test-cycles/" + testArchiveCycle + ".incomplete/"},
		{"aborted suffix", "/archive/" + testArchiveHost + "/test-cycles/" + testArchiveCycle + ".aborted.2026-08-16T14-30-00Z/"},
		{"traversal in the cycle slot", "/archive/" + testArchiveHost + "/test-cycles/../../../etc/"},
		{"host slot only", "/archive/" + testArchiveHost + "/"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rr := httptest.NewRecorder()
			s.handleArchive(rr, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if rr.Code == http.StatusOK {
				t.Fatalf("%s: got 200, want a refusal", tc.path)
			}
		})
	}
}

// The archive is a read surface. Anything that could mutate the durable copy of a
// host's results is refused before it reaches the filesystem.
func TestArchiveRefusesNonReadMethods(t *testing.T) {
	_, s := newArchiveFixture(t, true)
	target := "/archive/" + testArchiveHost + "/test-cycles/" + testArchiveCycle + "/cycle.html"

	for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		rr := httptest.NewRecorder()
		s.handleArchive(rr, httptest.NewRequest(m, target, nil))
		if rr.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s: got %d, want 405", m, rr.Code)
		}
		if allow := rr.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Fatalf("%s: Allow = %q", m, allow)
		}
	}
	rr := httptest.NewRecorder()
	s.handleArchive(rr, httptest.NewRequest(http.MethodHead, target, nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("HEAD: got %d, want 200", rr.Code)
	}
}

// A symlink inside the archive root must not become a way to read the rest of the
// filesystem. os.Root enforces this in the kernel rather than by string comparison.
func TestArchiveContainsSymlinkEscape(t *testing.T) {
	root, s := newArchiveFixture(t, true)

	secret := filepath.Join(t.TempDir(), "secret.txt")
	if err := os.WriteFile(secret, []byte("do not serve"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	link := filepath.Join(root, testArchiveHost, "test-cycles", testArchiveCycle, "escape.txt")
	if err := os.Symlink(secret, link); err != nil {
		t.Skipf("symlinks unavailable here: %v", err)
	}

	rr := httptest.NewRecorder()
	s.handleArchive(rr, httptest.NewRequest(http.MethodGet, "/archive/"+testArchiveHost+"/test-cycles/"+testArchiveCycle+"/escape.txt", nil))
	if rr.Code == http.StatusOK && contains(rr.Body.String(), "do not serve") {
		t.Fatal("a symlink escaped the archive root")
	}
}

// The proxy's CIFS mount is nofail and comes up asynchronously after boot, so the
// root is resolved PER REQUEST: a service that started before the mount must serve
// once it appears, with no restart.
func TestArchiveResolvesRootPerRequest(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "hosts")
	s := &poolState{archiveRoot: root}
	target := "/archive/" + testArchiveHost + "/test-cycles/" + testArchiveCycle + "/cycle.html"

	rr := httptest.NewRecorder()
	s.handleArchive(rr, httptest.NewRequest(http.MethodGet, target, nil))
	if rr.Code != http.StatusNotFound {
		t.Fatalf("before the mount: got %d, want 404", rr.Code)
	}

	dir := filepath.Join(root, testArchiveHost, "test-cycles", testArchiveCycle)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cycle.html"), []byte("late"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	rr = httptest.NewRecorder()
	s.handleArchive(rr, httptest.NewRequest(http.MethodGet, target, nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("after the mount appeared: got %d, want 200 (the root must be re-resolved per request)", rr.Code)
	}
}

func TestArchiveRouteAbsentWithoutRoot(t *testing.T) {
	s := &poolState{}
	if s.archiveCommitted(testArchiveHost, testArchiveCycle) {
		t.Fatal("no archive root configured, yet a cycle reported as committed")
	}
	if got := s.resolveFolderByArchive(testArchiveHost, time.Now()); got != "" {
		t.Fatalf("resolveFolderByArchive with no root = %q, want empty", got)
	}
}

// A destination exists sentinel-less for the whole duration of its copy. Resolving
// into one would hand an operator a half-copied tree that looks exactly like a
// finished archive.
func TestArchiveResolutionRequiresSentinel(t *testing.T) {
	_, s := newArchiveFixture(t, false)
	at, _ := time.Parse(time.RFC3339, "2026-08-16T14:30:00Z")

	if s.archiveCommitted(testArchiveHost, testArchiveCycle) {
		t.Fatal("a sentinel-less folder reported as committed")
	}
	if got := s.resolveFolderByArchive(testArchiveHost, at); got != "" {
		t.Fatalf("resolved an uncommitted copy: %q", got)
	}
}

func TestResolveFolderByArchivePicksCycleCoveringTime(t *testing.T) {
	root := t.TempDir()
	s := &poolState{archiveRoot: root}
	for _, leaf := range []string{
		"000121.2026-08-16.10-00-00." + testArchiveHost,
		"000122.2026-08-16.12-00-00." + testArchiveHost,
		"000123.2026-08-16.14-22-08." + testArchiveHost,
	} {
		dir := filepath.Join(root, testArchiveHost, "test-cycles", leaf)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(dir, ".yuruna-complete"), []byte("x"), 0o644); err != nil {
			t.Fatalf("sentinel: %v", err)
		}
	}

	at, _ := time.Parse(time.RFC3339, "2026-08-16T13:00:00Z")
	if got, want := s.resolveFolderByArchive(testArchiveHost, at), "000122.2026-08-16.12-00-00."+testArchiveHost+"/"; got != want {
		t.Fatalf("resolveFolderByArchive = %q, want %q (the cycle running at that time)", got, want)
	}

	before, _ := time.Parse(time.RFC3339, "2026-08-16T09:00:00Z")
	if got := s.resolveFolderByArchive(testArchiveHost, before); got != "" {
		t.Fatalf("a time before every cycle resolved to %q, want empty", got)
	}
}

func TestCycleStartFromFolder(t *testing.T) {
	got, ok := cycleStartFromFolder(testArchiveCycle)
	if !ok {
		t.Fatal("failed to parse a well-formed cycle folder")
	}
	want, _ := time.Parse(time.RFC3339, "2026-08-16T14:22:08Z")
	if !got.Equal(want) {
		t.Fatalf("cycleStartFromFolder = %v, want %v", got, want)
	}
	for _, bad := range []string{"", "not-a-cycle", "12345.2026-08-16.14-22-08.h", "000123.2026-13-99.14-22-08." + testArchiveHost} {
		if _, ok := cycleStartFromFolder(bad); ok {
			t.Fatalf("parsed %q as a cycle folder", bad)
		}
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(haystack); i++ {
			if haystack[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}
