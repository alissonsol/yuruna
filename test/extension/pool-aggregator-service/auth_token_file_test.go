// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The internal authentication key reaches this proxy as a file baked by cloud-init.
// Everything that matters hangs off reading it: control proofs, the /ingest gate, and
// the lab-token exchange the dashboard's tile advertises. These pin the three
// behaviors the guest layout depends on -- the trim, the legacy-path fallback, and
// the refusal to substitute a file the operator did not name.

func writeKeyFile(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("writing %s: %v", p, err)
	}
	return p
}

// A key file written by cloud-init routinely ends in a newline. The PowerShell side
// trims at its own read before computing the control tag both ends compare, so a
// proxy that kept the newline would report every host as "onsite (token mismatch)"
// while genuinely holding the same secret.
func TestReadAuthTokenFileTrimsSurroundingWhitespace(t *testing.T) {
	dir := t.TempDir()
	p := writeKeyFile(t, dir, "internal-auth.key", "  0123456789abcdef\r\n")
	if got := readAuthTokenFile(p, "/nonexistent/default", "/nonexistent/legacy"); got != "0123456789abcdef" {
		t.Fatalf("token not trimmed: got %q", got)
	}
}

// An absent key file leaves the token empty, which disables the gated surfaces rather
// than opening them: never an unauthenticated /ingest.
func TestReadAuthTokenFileMissingYieldsEmpty(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "absent.key")
	if got := readAuthTokenFile(missing, "/nonexistent/default", "/nonexistent/legacy"); got != "" {
		t.Fatalf("absent file must yield no token, got %q", got)
	}
	if got := readAuthTokenFile("", "/nonexistent/default", "/nonexistent/legacy"); got != "" {
		t.Fatalf("empty path must yield no token, got %q", got)
	}
	if got := readAuthTokenFile("   ", "/nonexistent/default", "/nonexistent/legacy"); got != "" {
		t.Fatalf("blank path must yield no token, got %q", got)
	}
}

// A proxy built under the older layout carries the key at the legacy path only. The
// unit still names the current path, so without this fallback such a VM comes up with
// no key at all: no control proofs, /ingest 503, and a dashboard tile reading "off".
func TestReadAuthTokenFileFallsBackToLegacyPath(t *testing.T) {
	dir := t.TempDir()
	defaultPath := filepath.Join(dir, "internal-auth.key") // deliberately not created
	legacyPath := writeKeyFile(t, dir, "lab-auth.token", "legacy-key-value\n")
	if got := readAuthTokenFile(defaultPath, defaultPath, legacyPath); got != "legacy-key-value" {
		t.Fatalf("legacy fallback not taken: got %q", got)
	}
}

// The current path wins whenever it exists, so a VM that has been rebuilt does not
// keep serving a stale key left behind at the legacy path.
func TestReadAuthTokenFilePrefersDefaultOverLegacy(t *testing.T) {
	dir := t.TempDir()
	defaultPath := writeKeyFile(t, dir, "internal-auth.key", "current-key\n")
	legacyPath := writeKeyFile(t, dir, "lab-auth.token", "stale-key\n")
	if got := readAuthTokenFile(defaultPath, defaultPath, legacyPath); got != "current-key" {
		t.Fatalf("default path must win: got %q", got)
	}
}

// The fallback is licensed by the path being the provisioned default and nothing else.
// An operator who passed -auth-token-file meant that file; silently reading a
// different one would hand this proxy a token they never pointed it at, and mint
// control proofs the whole pool would then have to match.
func TestReadAuthTokenFileDoesNotFallBackForAnOperatorNamedPath(t *testing.T) {
	dir := t.TempDir()
	operatorPath := filepath.Join(dir, "operator-chosen.key") // deliberately not created
	legacyPath := writeKeyFile(t, dir, "lab-auth.token", "legacy-key-value\n")
	if got := readAuthTokenFile(operatorPath, filepath.Join(dir, "internal-auth.key"), legacyPath); got != "" {
		t.Fatalf("an operator-named path must not fall back, got %q", got)
	}
}

// The constants the daemon actually runs with are the paths documented for the guest
// image; a rename on either side silently strands a rebuilt or a legacy proxy.
func TestAuthTokenFilePathsMatchTheGuestLayout(t *testing.T) {
	if defaultAuthTokenFile != "/etc/yuruna/internal-auth.key" {
		t.Errorf("default key path drifted from the baked guest layout: %q", defaultAuthTokenFile)
	}
	if legacyAuthTokenFile != "/etc/yuruna/lab-auth.token" {
		t.Errorf("legacy key path drifted from the older guest layout: %q", legacyAuthTokenFile)
	}
}
