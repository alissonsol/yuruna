// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"sync"
	"testing"
	"time"
)

// countingAttempt stands in for a Fido run: it records how many sessions were
// spent and what each caller got back. The count is the whole point -- the gate
// exists to make the number of Microsoft sessions a property of the artifacts
// wanted, not of the pool rows that want them.
type countingAttempt struct {
	mu    sync.Mutex
	runs  int
	reply func(n int) FidoAttempt
}

func (c *countingAttempt) run(context.Context) FidoAttempt {
	c.mu.Lock()
	c.runs++
	n := c.runs
	c.mu.Unlock()
	return c.reply(n)
}

func (c *countingAttempt) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.runs
}

func okAttempt(url string) FidoAttempt {
	return FidoAttempt{Arch: "x64", URL: url}
}

func rejectedAttempt() FidoAttempt {
	// Verbatim in shape from the failure this gate was built for: Fido reports
	// Microsoft's refusal on stdout and exits 3.
	return FidoAttempt{Arch: "x64", ExitCode: 3, Error: "Fido failed: exit status 3 (Error: Sentinel marked this request as rejected.)"}
}

func TestOneResolveServesEveryRowThatWantsTheSameArtifact(t *testing.T) {
	now := fixedNow
	g := NewFidoGate(func() time.Time { return now })
	att := &countingAttempt{reply: func(int) FidoAttempt { return okAttempt(signedURL1) }}

	// Three host types carry a guest.windows.11 row and all three come due in
	// the same scan pass. Without the gate that is three sessions inside a few
	// seconds from one address, which is the shape Microsoft rejects.
	for i := 0; i < 3; i++ {
		at := g.Do(context.Background(), "x64", false, att.run)
		if at.URL != signedURL1 {
			t.Fatalf("caller %d got %+v, want the shared URL", i, at)
		}
	}
	if att.count() != 1 {
		t.Errorf("%d Microsoft sessions spent for one artifact, want 1", att.count())
	}

	// Past the reuse window the next caller pays for a fresh URL: the signature
	// on the old one does not last forever.
	now = now.Add(fidoReuseWindow + time.Minute)
	if at := g.Do(context.Background(), "x64", false, att.run); at.URL != signedURL1 {
		t.Fatalf("post-window resolve = %+v, want a fresh run", at)
	}
	if att.count() != 2 {
		t.Errorf("%d sessions after the reuse window expired, want 2", att.count())
	}
}

func TestARejectedResolveIsNotRetriedOncePerRow(t *testing.T) {
	now := fixedNow
	g := NewFidoGate(func() time.Time { return now })
	att := &countingAttempt{reply: func(int) FidoAttempt { return rejectedAttempt() }}

	for i := 0; i < 4; i++ {
		at := g.Do(context.Background(), "x64", false, att.run)
		if at.Error == "" {
			t.Fatalf("caller %d got %+v, want the shared refusal", i, at)
		}
	}
	if att.count() != 1 {
		t.Errorf("%d sessions spent on a refusal, want 1 -- asking again from the same address is what earns the rejection", att.count())
	}

	// A refusal is held for far less time than a success, so an operator who
	// fixes the cause is not locked out for the rest of the reuse window.
	now = now.Add(fidoRetryDelay + time.Second)
	if at := g.Do(context.Background(), "x64", false, att.run); at.Error == "" {
		t.Fatalf("retry = %+v, want the stub's refusal", at)
	}
	if att.count() != 2 {
		t.Errorf("%d sessions after the retry delay, want 2", att.count())
	}
	if fidoRetryDelay >= fidoReuseWindow {
		t.Error("a refusal must expire sooner than a minted URL, or a broken resolve outlives a working one")
	}
}

func TestEachArchitectureKeepsItsOwnResolve(t *testing.T) {
	g := NewFidoGate(func() time.Time { return fixedNow })
	att := &countingAttempt{reply: func(n int) FidoAttempt {
		if n == 1 {
			return okAttempt(signedURL1)
		}
		return okAttempt(signedURL2)
	}}

	x64 := g.Do(context.Background(), "x64", false, att.run)
	arm := g.Do(context.Background(), ArchARM64, false, att.run)
	if x64.URL == arm.URL {
		t.Fatal("the two architectures are different ISOs; sharing one resolve between them would serve arm64 hosts an x64 image")
	}
	if again := g.Do(context.Background(), "x64", false, att.run); again.URL != x64.URL {
		t.Errorf("second x64 resolve = %q, want the shared %q", again.URL, x64.URL)
	}
	if att.count() != 2 {
		t.Errorf("%d sessions for two architectures, want 2", att.count())
	}
}

func TestTheResolverTestForcesARealRunAndBecomesWhatRowsShare(t *testing.T) {
	g := NewFidoGate(func() time.Time { return fixedNow })
	att := &countingAttempt{reply: func(n int) FidoAttempt {
		if n == 1 {
			return rejectedAttempt()
		}
		return okAttempt(signedURL2)
	}}

	if at := g.Do(context.Background(), "x64", false, att.run); at.Error == "" {
		t.Fatal("the first resolve must report the stub's refusal")
	}
	// The operator fixes the cause and presses the diagnostics test. Answering
	// that with the cached refusal would tell them the fix did not work.
	forced := g.Do(context.Background(), "x64", true, att.run)
	if forced.URL != signedURL2 {
		t.Fatalf("forced run = %+v, want a real run", forced)
	}
	if att.count() != 2 {
		t.Fatalf("%d sessions, want 2: a forced run must not be answered from the cache", att.count())
	}
	// And the rows must see the good news without waiting out the retry delay.
	if at := g.Do(context.Background(), "x64", false, att.run); at.URL != signedURL2 {
		t.Errorf("row resolve after a successful test = %+v, want the URL the test minted", at)
	}
}

func TestOnlyOneResolveRunsAtATime(t *testing.T) {
	g := NewFidoGate(func() time.Time { return fixedNow })
	var mu sync.Mutex
	live, peak := 0, 0
	release := make(chan struct{})
	att := func(context.Context) FidoAttempt {
		mu.Lock()
		live++
		if live > peak {
			peak = live
		}
		mu.Unlock()
		<-release
		mu.Lock()
		live--
		mu.Unlock()
		return okAttempt(signedURL1)
	}

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			g.Do(context.Background(), "x64", true, att)
		}()
	}
	// Forced runs, so nothing is answered from the cache: whatever overlap the
	// gate allows is real overlap. Releasing them one at a time proves each was
	// waiting for the slot rather than running beside the others.
	for i := 0; i < 4; i++ {
		release <- struct{}{}
	}
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	if peak != 1 {
		t.Errorf("%d resolves ran at once, want 1", peak)
	}
}

func TestACanceledCallerNeitherWaitsNorPoisonsTheSharedAnswer(t *testing.T) {
	g := NewFidoGate(func() time.Time { return fixedNow })
	att := &countingAttempt{reply: func(int) FidoAttempt { return okAttempt(signedURL1) }}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	at := g.Do(ctx, "x64", false, att.run)
	if at.Error == "" {
		t.Fatalf("canceled resolve = %+v, want the cancellation reported", at)
	}
	if att.count() != 0 {
		t.Errorf("a canceled caller spent %d session(s), want 0", att.count())
	}
	// A deleted entry or a stopping daemon says nothing about Microsoft, so the
	// next caller must still get a real run.
	if next := g.Do(context.Background(), "x64", false, att.run); next.URL != signedURL1 {
		t.Errorf("resolve after a cancellation = %+v, want a real run", next)
	}
}
