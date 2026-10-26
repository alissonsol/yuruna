// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 424578c0-b942-44c7-8ff6-622391a444f2

package configuration

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// The test binary doubles as the pool-admin CLI: with fakePwshEnv set it
// appends the script it was asked to run to the log file and answers like the
// CLI, before the testing flags (which the CLI argv would fail) are parsed.
const (
	fakePwshEnv   = "POOLCONTROL_FAKE_PWSH_LOG"
	fakePwshDelay = "POOLCONTROL_FAKE_PWSH_DELAY_MS"
)

func TestMain(m *testing.M) {
	if log := os.Getenv(fakePwshEnv); log != "" {
		script := ""
		for i, arg := range os.Args {
			if arg == "-File" && i+1 < len(os.Args) {
				script = os.Args[i+1]
			}
		}
		if delay := os.Getenv(fakePwshDelay); delay != "" {
			var ms int
			fmt.Sscanf(delay, "%d", &ms)
			time.Sleep(time.Duration(ms) * time.Millisecond)
		}
		f, err := os.OpenFile(log, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err == nil {
			fmt.Fprintln(f, script)
			f.Close()
		}
		fmt.Println(`{"ok":true,"pools":[],"autoEnrollment":{"enabled":false,"targetPoolId":"","excluded":[]}}`)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fakeRunner(t *testing.T, delayMs int) (*Runner, string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("test binary path: %v", err)
	}
	log := t.TempDir() + "/calls.log"
	t.Setenv(fakePwshEnv, log)
	t.Setenv(fakePwshDelay, fmt.Sprint(delayMs))
	return &Runner{Pwsh: exe, RepoDir: t.TempDir()}, log
}

func calls(t *testing.T, log string, script string) int {
	t.Helper()
	b, err := os.ReadFile(log)
	if err != nil {
		return 0
	}
	return strings.Count(string(b), script)
}

// The open read routes ran Get-PoolConfiguration.ps1 -- a pwsh start and the
// admin clone's exclusive lock -- on every request.
func TestStateAnswersRepeatReadsFromOneRead(t *testing.T) {
	r, log := fakeRunner(t, 0)
	for i := 0; i < 3; i++ {
		if res := r.State(context.Background()); !res.OK {
			t.Fatalf("read %d failed: %+v", i, res)
		}
	}
	if got := calls(t, log, "pool/Get-PoolConfiguration.ps1"); got != 1 {
		t.Fatalf("three reads inside the cache window ran the CLI %d times, want 1", got)
	}
}

func TestStateSharesOneReadAcrossConcurrentCallers(t *testing.T) {
	r, log := fakeRunner(t, 300)
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if res := r.State(context.Background()); !res.OK {
				t.Errorf("concurrent read failed: %+v", res)
			}
		}()
	}
	wg.Wait()
	if got := calls(t, log, "pool/Get-PoolConfiguration.ps1"); got != 1 {
		t.Fatalf("six concurrent reads ran the CLI %d times, want 1", got)
	}
}

func TestStateRereadsAfterAChange(t *testing.T) {
	r, log := fakeRunner(t, 0)
	_ = r.State(context.Background())
	if res := r.SetConfiguredState(context.Background(), "lab", "run"); !res.OK {
		t.Fatalf("mutation failed: %+v", res)
	}
	_ = r.State(context.Background())
	if got := calls(t, log, "pool/Get-PoolConfiguration.ps1"); got != 2 {
		t.Fatalf("a read after a change ran the CLI %d times in all, want 2 (the change invalidates the cache)", got)
	}
}

func TestStateIsNotCanceledByTheCallerThatStartedIt(t *testing.T) {
	r, _ := fakeRunner(t, 300)
	ctx, cancel := context.WithCancel(context.Background())
	var waiter Result
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(50 * time.Millisecond)
		waiter = r.State(context.Background())
	}()
	go func() { time.Sleep(100 * time.Millisecond); cancel() }()
	_ = r.State(ctx)
	wg.Wait()
	if !waiter.OK {
		t.Fatalf("a caller waiting on a shared read received another caller's cancellation: %+v", waiter)
	}
}
