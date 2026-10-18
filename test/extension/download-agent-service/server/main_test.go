// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"testing"
	"time"
)

func TestWaitBoundedSharesOneDeadlineAcrossWaiters(t *testing.T) {
	never := make(chan struct{})
	already := make(chan struct{})
	close(already)

	start := time.Now()
	waitBounded(150*time.Millisecond, never, never, already)
	// One budget for the whole shutdown, not one per waiter: a share that has
	// stopped answering must not multiply the grace period by however many
	// things are being waited on.
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("waited %s for a 150ms grace across three waiters", elapsed)
	}
}

func TestWaitBoundedReturnsAsSoonAsEveryWaiterIsDone(t *testing.T) {
	done := make(chan struct{})
	close(done)
	start := time.Now()
	waitBounded(10*time.Second, done, done)
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("waited %s for two already-finished waiters", elapsed)
	}
}

func TestUIPortIsTheBeaconDeepLinkTarget(t *testing.T) {
	// 0 means "no deep link", so an unparseable address must degrade to that
	// rather than announcing a port nothing listens on.
	for addr, want := range map[string]int{
		"0.0.0.0:80":   80,
		"127.0.0.1:80": 80,
		"[::]:8080":    8080,
		"":             0,
		"not-an-addr":  0,
		"0.0.0.0:http": 0,
	} {
		if got := uiPort(addr); got != want {
			t.Errorf("uiPort(%q) = %d, want %d", addr, got, want)
		}
	}
}
