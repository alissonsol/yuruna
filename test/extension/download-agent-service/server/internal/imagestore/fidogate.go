// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"sync"
	"time"
)

// One Windows 11 resolve costs one Microsoft session: Fido walks the download
// page, has the session id whitelisted, answers a bot challenge and only then
// asks for a link. Microsoft's front end refuses sessions it considers too
// chatty for the address they come from, and that refusal arrives as a rejected
// request rather than as a retry-after -- "Sentinel marked this request as
// rejected", which Fido reports as exit status 3.
//
// The pool asks for the same ISO once per ROW: every host type carries its own
// guest.windows.11 entry, and a scan pass, a pool-wide refresh or several hosts
// booting together start those rows at the same moment. Left to itself each one
// spends its own session within seconds of the others from a single address,
// which is the shape that gets refused -- and the refusal lands on whichever
// rows lose that race, so the family looks broken for some host types and fine
// for another.
//
// FidoGate makes the resolve a property of the ARCHITECTURE rather than of the
// row: one run at a time, and whatever that run produced -- a URL or a refusal --
// answers everyone who asks soon after. It cannot make Microsoft accept a
// session; it stops the agent from asking for more sessions than there are
// distinct artifacts to fetch.
type FidoGate struct {
	// run admits one resolve at a time. A channel rather than a mutex because a
	// caller whose context is already canceled must not queue behind a run whose
	// answer it will never use.
	run chan struct{}
	now func() time.Time

	mu   sync.Mutex
	last map[string]sharedResolve
}

// sharedResolve is the answer one architecture's last run produced, and when.
type sharedResolve struct {
	attempt FidoAttempt
	at      time.Time
}

// fidoReuseWindow is how long a minted URL answers later callers instead of
// spending another session. Microsoft's signed URLs stay valid for hours, so
// reuse costs nothing but a slightly older signature, while a fresh run costs a
// session the next caller may need.
const fidoReuseWindow = 30 * time.Minute

// fidoRetryDelay is how long a refusal answers later callers. It is short
// enough that an operator who fixes the cause is not locked out for long, and
// long enough that one scan pass, one pool-wide refresh, or a lab of hosts
// booting together produce a single rejected session instead of one per row.
const fidoRetryDelay = 5 * time.Minute

// NewFidoGate builds a gate over an injectable clock.
func NewFidoGate(now func() time.Time) *FidoGate {
	if now == nil {
		now = time.Now
	}
	return &FidoGate{run: make(chan struct{}, 1), now: now, last: map[string]sharedResolve{}}
}

// Do answers with the shared resolve for one architecture: the last one while
// it is still worth reusing, otherwise a fresh run of `attempt`. force skips the
// reuse but still takes the single run slot, which is what the diagnostics
// resolver test needs -- an operator asking "does this work now" wants a real
// run, not a cached verdict, and still must not run beside another one.
//
// The result of a run whose context was canceled is deliberately not
// remembered: a deleted entry or a stopping daemon says nothing about Microsoft,
// and caching it would suppress real resolves for the retry delay.
func (g *FidoGate) Do(ctx context.Context, fidoArch string, force bool, attempt func(context.Context) FidoAttempt) FidoAttempt {
	if g == nil {
		return attempt(ctx)
	}
	// Tested before the select, not only inside it: a select whose slot is free
	// AND whose context is done picks between the two at random, so an already
	// canceled caller would sometimes go on to start a child anyway.
	if err := ctx.Err(); err != nil {
		return g.canceled(fidoArch, err)
	}
	select {
	case g.run <- struct{}{}:
	case <-ctx.Done():
		return g.canceled(fidoArch, ctx.Err())
	}
	defer func() { <-g.run }()

	if !force {
		if prev, ok := g.shared(fidoArch); ok {
			return prev
		}
	}
	at := attempt(ctx)
	if ctx.Err() == nil {
		g.mu.Lock()
		g.last[fidoArch] = sharedResolve{attempt: at, at: g.now()}
		g.mu.Unlock()
	}
	return at
}

// canceled is the answer for a caller that gave up before it held the run slot:
// a real attempt shape, so every caller reads one type, carrying the reason no
// child was started.
func (g *FidoGate) canceled(fidoArch string, err error) FidoAttempt {
	return FidoAttempt{
		AtUTC:    g.now().UTC().Format(time.RFC3339),
		Arch:     fidoArch,
		ExitCode: -1,
		Error:    err.Error(),
	}
}

// shared reports the last run for an architecture while it is still inside its
// reuse window.
func (g *FidoGate) shared(fidoArch string) (FidoAttempt, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	prev, ok := g.last[fidoArch]
	if !ok {
		return FidoAttempt{}, false
	}
	window := fidoReuseWindow
	if prev.attempt.Error != "" {
		window = fidoRetryDelay
	}
	if g.now().Sub(prev.at) >= window {
		return FidoAttempt{}, false
	}
	return prev.attempt, true
}
