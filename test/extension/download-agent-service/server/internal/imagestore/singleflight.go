// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"sync"
	"time"
)

// Download phases surfaced to the UI while a flight is live.
const (
	PhaseResolving   = "resolving"
	PhaseProbing     = "probing"
	PhaseDownloading = "downloading"
	PhaseVerifying   = "verifying"
	PhasePromoting   = "promoting"
)

// Progress is one flight's live byte counter. It is an io.Writer so the
// download can tee into it without a second copy of the stream.
type Progress struct {
	mu    sync.Mutex
	phase string
	done  int64
	total int64
}

// ProgressSnapshot is a consistent read of a Progress for a handler response.
type ProgressSnapshot struct {
	Phase string `json:"phase,omitempty"`
	Done  int64  `json:"bytesDone"`
	Total int64  `json:"bytesTotal"`
}

// SetPhase records which stage of the pipeline is running.
func (p *Progress) SetPhase(phase string) {
	p.mu.Lock()
	p.phase = phase
	p.mu.Unlock()
}

// SetTotal records the expected byte count once the origin has reported it.
func (p *Progress) SetTotal(n int64) {
	p.mu.Lock()
	p.total = n
	p.mu.Unlock()
}

// Reset zeroes the counters for a retry within the same flight (the direct
// fallback after a proxy attempt already streamed some bytes).
func (p *Progress) Reset() {
	p.mu.Lock()
	p.done = 0
	p.mu.Unlock()
}

// Write counts bytes; it never fails, so a tee through it cannot break a
// download.
func (p *Progress) Write(b []byte) (int, error) {
	p.mu.Lock()
	p.done += int64(len(b))
	p.mu.Unlock()
	return len(b), nil
}

// Snapshot reads phase and counters together.
func (p *Progress) Snapshot() ProgressSnapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	return ProgressSnapshot{Phase: p.phase, Done: p.done, Total: p.total}
}

// Flight is one in-progress operation for a key. Handlers observe it (progress,
// completion, error) without being able to affect it, so a client that gives up
// polling never cancels the work another client is waiting on.
type Flight struct {
	Key       string
	StartedAt time.Time
	Progress  *Progress
	Seed      bool

	done   chan struct{}
	cancel context.CancelFunc

	mu  sync.Mutex
	err error
}

// Done closes when the flight finishes.
func (f *Flight) Done() <-chan struct{} { return f.done }

// Err returns the flight's outcome once Done is closed.
func (f *Flight) Err() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.err
}

// Cancel aborts the flight; used by Delete, which must not race a download that
// would recreate what it just removed.
func (f *Flight) Cancel() { f.cancel() }

// Group deduplicates work per key. With the single-writer lease making one agent
// the writer for a pool, in-process dedup is lab-wide dedup: N hosts asking for
// the same image share one origin download.
type Group struct {
	// Base is the parent context for every flight. It is deliberately NOT a
	// request context: an ensure that answers 202 and returns must leave the
	// download running for whoever polls next.
	Base context.Context

	mu sync.Mutex
	m  map[string]*Flight
}

// NewGroup builds a Group whose flights live as long as base.
func NewGroup(base context.Context) *Group {
	if base == nil {
		base = context.Background()
	}
	return &Group{Base: base, m: map[string]*Flight{}}
}

// Start runs fn for key unless a flight is already live, in which case the
// caller joins it. started reports which of the two happened.
func (g *Group) Start(key string, seed bool, fn func(ctx context.Context, p *Progress) error) (f *Flight, started bool) {
	g.mu.Lock()
	if existing, ok := g.m[key]; ok {
		g.mu.Unlock()
		return existing, false
	}
	ctx, cancel := context.WithCancel(g.Base)
	f = &Flight{
		Key:       key,
		StartedAt: time.Now(),
		Progress:  &Progress{},
		Seed:      seed,
		done:      make(chan struct{}),
		cancel:    cancel,
	}
	g.m[key] = f
	g.mu.Unlock()

	go func() {
		err := fn(ctx, f.Progress)
		f.mu.Lock()
		f.err = err
		f.mu.Unlock()
		cancel()
		g.mu.Lock()
		if g.m[key] == f {
			delete(g.m, key)
		}
		g.mu.Unlock()
		close(f.done)
	}()
	return f, true
}

// Lookup returns the live flight for a key, if any.
func (g *Group) Lookup(key string) (*Flight, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	f, ok := g.m[key]
	return f, ok
}

// Cancel aborts the live flight for a key and reports whether there was one.
func (g *Group) Cancel(key string) bool {
	g.mu.Lock()
	f, ok := g.m[key]
	g.mu.Unlock()
	if !ok {
		return false
	}
	f.Cancel()
	<-f.Done()
	return true
}

// Len is the number of live flights.
func (g *Group) Len() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.m)
}

// SeedLen is the number of live flights started by the auto-seed pass, which is
// what the seed concurrency cap counts.
func (g *Group) SeedLen() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	n := 0
	for _, f := range g.m {
		if f.Seed {
			n++
		}
	}
	return n
}
