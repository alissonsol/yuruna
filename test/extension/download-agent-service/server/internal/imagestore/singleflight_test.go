// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestGroupRunsOneDownloadForConcurrentEnsures(t *testing.T) {
	g := NewGroup(context.Background())
	const callers = 25

	var runs int32
	release := make(chan struct{})
	// The body announces itself here. wg only tracks the CALLERS; the download
	// body runs in a goroutine Start launches, so waiting on wg alone can reach
	// the assertions before the body has run at all.
	running := make(chan struct{}, callers)
	var startedCount int32
	var wg sync.WaitGroup

	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, started := g.Start("ubuntu.kvm/guest.ubuntu.server.26/amd64/stable", false, func(ctx context.Context, p *Progress) error {
				atomic.AddInt32(&runs, 1)
				running <- struct{}{}
				<-release
				return nil
			})
			if started {
				atomic.AddInt32(&startedCount, 1)
			}
		}()
	}
	wg.Wait()
	<-running

	if got := atomic.LoadInt32(&startedCount); got != 1 {
		t.Fatalf("%d callers reported starting the flight, want exactly 1", got)
	}
	if got := atomic.LoadInt32(&runs); got != 1 {
		t.Fatalf("the download body ran %d times, want exactly 1", got)
	}
	if g.Len() != 1 {
		t.Fatalf("group holds %d flights, want 1", g.Len())
	}
	close(release)

	f, ok := g.Lookup("ubuntu.kvm/guest.ubuntu.server.26/amd64/stable")
	if ok {
		<-f.Done()
	}
	deadline := time.Now().Add(2 * time.Second)
	for g.Len() != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if g.Len() != 0 {
		t.Fatalf("a finished flight was not removed from the group")
	}
}

func TestGroupStartsAgainAfterAFlightFinishes(t *testing.T) {
	g := NewGroup(context.Background())
	for i := 0; i < 3; i++ {
		f, started := g.Start("k", false, func(ctx context.Context, p *Progress) error { return nil })
		if !started {
			t.Fatalf("iteration %d joined a flight that should already be gone", i)
		}
		<-f.Done()
	}
}

func TestProgressIsObservableWhileTheFlightRuns(t *testing.T) {
	g := NewGroup(context.Background())
	gate := make(chan struct{})
	f, _ := g.Start("k", false, func(ctx context.Context, p *Progress) error {
		p.SetPhase(PhaseDownloading)
		p.SetTotal(1000)
		_, _ = p.Write(make([]byte, 400))
		close(gate)
		<-ctx.Done()
		return nil
	})
	<-gate

	snap := f.Progress.Snapshot()
	if snap.Phase != PhaseDownloading || snap.Done != 400 || snap.Total != 1000 {
		t.Fatalf("progress snapshot = %+v, want phase=downloading done=400 total=1000", snap)
	}
	f.Cancel()
	<-f.Done()
}

func TestSeedLenCountsOnlySeedFlights(t *testing.T) {
	g := NewGroup(context.Background())
	block := make(chan struct{})
	body := func(ctx context.Context, p *Progress) error { <-block; return nil }
	g.Start("a", true, body)
	g.Start("b", true, body)
	g.Start("c", false, body)

	if got := g.SeedLen(); got != 2 {
		t.Fatalf("SeedLen = %d, want 2 (the seed concurrency cap must not count interactive flights)", got)
	}
	if got := g.Len(); got != 3 {
		t.Fatalf("Len = %d, want 3", got)
	}
	close(block)
}

func TestCancelStopsAFlightAndWaits(t *testing.T) {
	g := NewGroup(context.Background())
	stopped := make(chan struct{})
	g.Start("k", false, func(ctx context.Context, p *Progress) error {
		<-ctx.Done()
		close(stopped)
		return ctx.Err()
	})
	if !g.Cancel("k") {
		t.Fatal("Cancel reported no live flight")
	}
	select {
	case <-stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("Cancel returned before the flight observed cancellation")
	}
	if g.Cancel("k") {
		t.Fatal("Cancel reported a live flight after it finished")
	}
}
