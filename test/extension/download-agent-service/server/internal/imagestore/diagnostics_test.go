// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"runtime"
	"strings"
	"testing"
)

// --- attempt capture ---------------------------------------------------------

func TestAttemptCapturesARefusalPrintedToStdout(t *testing.T) {
	// The incident class this guards: Fido refuses non-Windows platforms by
	// printing the reason to STDOUT and exiting 403 (reported as 147). An error
	// that quotes only stderr reads "exit status 147 ()" -- evidence discarded.
	stub := newFidoStub(t, stubRefuse)
	at := stub.cfg.Attempt(context.Background(), "x64")

	if at.ExitCode != 147 {
		t.Fatalf("ExitCode = %d, want 147", at.ExitCode)
	}
	const refusal = "not available on this platform"
	if !strings.Contains(at.Stdout, refusal) {
		t.Fatalf("Stdout = %q, want the refusal text captured", at.Stdout)
	}
	if !strings.Contains(at.Error, refusal) {
		t.Fatalf("Error = %q, want the stdout refusal quoted when stderr is silent", at.Error)
	}
	if at.URL != "" || at.TimedOut {
		t.Fatalf("attempt = %+v, want no URL and no timeout", at)
	}
}

func TestAttemptReportsSuccessWithArgvAndURL(t *testing.T) {
	stub := newFidoStub(t, stubEcho)
	stub.setURL(t, signedURL1)
	at := stub.cfg.Attempt(context.Background(), "x64")

	if at.Error != "" || at.ExitCode != 0 || at.URL != signedURL1 {
		t.Fatalf("attempt = %+v, want a clean success minting %s", at, signedURL1)
	}
	if at.AtUTC == "" {
		t.Fatal("a success must still be stamped")
	}
	if !strings.Contains(strings.Join(at.Argv, " "), "-GetUrl") {
		t.Fatalf("Argv = %v, want the real parameter list recorded", at.Argv)
	}
}

func TestObserveSeesAttemptsThatNeverStartAChild(t *testing.T) {
	var seen []FidoAttempt
	cfg := FidoConfig{
		Interpreter: []string{"no-such-interpreter-for-this-suite"},
		Observe:     func(at FidoAttempt) { seen = append(seen, at) },
	}
	at := cfg.Attempt(context.Background(), "x64")
	if at.Error == "" || at.ExitCode != -1 {
		t.Fatalf("attempt = %+v, want a no-child failure", at)
	}
	if len(seen) != 1 || seen[0].Error != at.Error {
		t.Fatalf("observer saw %v, want exactly the returned attempt", seen)
	}
}

// --- the agent surface -------------------------------------------------------

func TestFidoTestArmsAndClearsTheRememberedFailure(t *testing.T) {
	stub := newFidoStub(t, stubEcho)
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: stub.cfg})

	// Empty output first: the resolve fails and the family goes unavailable.
	stub.setURL(t, "")
	at, err := a.FidoTest(context.Background(), ArchAMD64)
	if err != nil {
		t.Fatalf("FidoTest: %v", err)
	}
	if at.Error == "" {
		t.Fatal("an empty stub must fail the resolve")
	}
	if reason := a.familyUnavailable(ImageID{ImageKey: KeyWindows11}); reason == "" {
		t.Fatal("a failed test must arm the remembered failure")
	}
	rep := a.Diagnostics(context.Background())
	if rep.RememberedFailure == nil || rep.LastFidoAttempt == nil {
		t.Fatalf("report = %+v, want the failure and the attempt surfaced", rep)
	}
	if rep.LastFidoAttempt.Error != at.Error {
		t.Fatalf("LastFidoAttempt.Error = %q, want %q", rep.LastFidoAttempt.Error, at.Error)
	}

	// A working resolve must clear it on the spot -- an operator who just fixed
	// the guest should not wait out the failure TTL.
	stub.setURL(t, signedURL1)
	at, err = a.FidoTest(context.Background(), ArchAMD64)
	if err != nil || at.Error != "" || at.URL != signedURL1 {
		t.Fatalf("FidoTest after fix = %+v (%v), want success", at, err)
	}
	if reason := a.familyUnavailable(ImageID{ImageKey: KeyWindows11}); reason != "" {
		t.Fatalf("family still unavailable (%q) after a successful test", reason)
	}
	if rep := a.Diagnostics(context.Background()); rep.RememberedFailure != nil {
		t.Fatal("a successful test must clear the remembered failure from the report")
	}

	if _, err := a.FidoTest(context.Background(), "x86"); err == nil {
		t.Fatal("an unknown pool arch must be refused, not guessed at")
	}
}

func TestDiagnosticsReportsInterpreterScriptAndEnvironment(t *testing.T) {
	stub := newFidoStub(t, stubEcho)
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: stub.cfg})
	rep := a.Diagnostics(context.Background())

	if rep.GOOS != runtime.GOOS || rep.GOARCH != runtime.GOARCH {
		t.Fatalf("report says %s/%s, want the build's own platform", rep.GOOS, rep.GOARCH)
	}
	if rep.Interpreter.ResolvedPath == "" {
		t.Fatalf("interpreter = %+v, want the stub shell resolved on PATH", rep.Interpreter)
	}
	b, err := os.ReadFile(stub.cfg.Script)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	if rep.Script.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatalf("script SHA-256 = %s, want the live hash of the vendored file", rep.Script.SHA256)
	}
	if rep.Script.Path != stub.cfg.Script || rep.Script.SizeBytes != int64(len(b)) {
		t.Fatalf("script = %+v, want the stub's path and size", rep.Script)
	}
	if !rep.PoolAvailable {
		t.Fatal("the fixture pool dir must read as available")
	}
	if len(rep.BestEffort) == 0 {
		t.Fatal("the report must carry the best-effort family answers")
	}
}
