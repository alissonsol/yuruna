// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42d6b0e1-7c4f-4b8e-9f2a-5e1c3a7b9d64

package configuration

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// A configuration change commits, pushes and rebases in the admin clone. The
// browser that asked for it may close before it finishes, and killing pwsh then
// would leave the clone mid-rebase for the next caller.
func TestAMutationOutlivesTheRequestThatStartedIt(t *testing.T) {
	r, log := fakeRunner(t, 300)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(50 * time.Millisecond); cancel() }()
	res := r.SetConfiguredState(ctx, "lab", "paused")
	if !res.OK {
		t.Fatalf("a change whose caller left was killed: %+v", res)
	}
	if got := calls(t, log, "pool/Set-PoolConfiguredState.ps1"); got != 1 {
		t.Fatalf("the CLI ran to its end %d time(s), want 1", got)
	}
}

// A credential in the configuration git URL reaches the CLI as configured, and
// nowhere else: not the reported command line, not the CLI's error text, which
// the open diagnostics page and the audit log carry.
func TestCLIOutputNamesNoCredential(t *testing.T) {
	r, log := fakeRunner(t, 0)
	t.Setenv(fakePwshStderr, "fatal: unable to access 'https://operator:s3cret-token@git.example/pool.git/': 403")
	r.ConfigurationGitUrl = "https://operator:s3cret-token@git.example/pool.git"
	res := r.SetConfiguredState(context.Background(), "lab", "paused")
	if res.OK {
		t.Fatal("the fixture CLI failed, but the result reads OK")
	}
	for _, field := range append(append([]string{}, res.Argv...), res.Stderr, res.Error) {
		if strings.Contains(field, "s3cret-token") {
			t.Fatalf("the result repeats the credential: %q", field)
		}
	}
	if !strings.Contains(strings.Join(res.Argv, " "), "https://***@git.example/pool.git") {
		t.Fatalf("the reported command line lost the URL itself: %q", res.Argv)
	}
	b, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(b), "url=https://operator:s3cret-token@git.example/pool.git") {
		t.Fatalf("the CLI did not receive the configured URL (log %q, %v)", b, err)
	}
}
