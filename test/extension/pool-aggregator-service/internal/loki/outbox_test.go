// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 423a80ed-48b6-4767-ae69-796ee7a6b489

package loki

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// recorder is a push function standing in for Loki: it fails with fail while
// fail is set, and records what it accepted.
type recorder struct {
	mu       sync.Mutex
	fail     error
	accepted []string
	events   []string
}

func (r *recorder) push(_ context.Context, data []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fail != nil {
		return r.fail
	}
	r.accepted = append(r.accepted, string(data))
	return nil
}

func (r *recorder) logf(event string, _ map[string]any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
}

func (r *recorder) setFail(err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.fail = err
}

func (r *recorder) got() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.accepted...)
}

// A line queued while Loki is away is on disk before Enqueue returns, so it
// survives the collector's restart and is delivered, in order, once Loki is back.
func TestQueuedLinesSurviveARestartAndArriveInOrder(t *testing.T) {
	dir := t.TempDir()
	down := &recorder{fail: errors.New("connection refused")}
	o := NewOutbox(dir, down.push, down.logf)
	if !o.Durable() {
		t.Fatal("an outbox with a usable directory is not durable")
	}
	for _, line := range []string{"a", "b", "c"} {
		if err := o.Enqueue([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	if o.Flush(context.Background()) {
		t.Fatal("Flush reported an empty outbox while Loki refused every send")
	}
	// A crash mid-write leaves a temp file; it is not a queued line.
	if err := os.WriteFile(filepath.Join(dir, ".tmp-123"), []byte("half"), 0o600); err != nil {
		t.Fatal(err)
	}

	up := &recorder{}
	restarted := NewOutbox(dir, up.push, up.logf)
	if restarted.Pending() != 3 {
		t.Fatalf("after a restart %d line(s) wait, want the 3 queued", restarted.Pending())
	}
	if !restarted.Flush(context.Background()) {
		t.Fatal("Flush did not empty the outbox once Loki accepted")
	}
	if got := up.got(); len(got) != 3 || got[0] != "a" || got[1] != "b" || got[2] != "c" {
		t.Fatalf("delivered %q, want a, b, c in order", got)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "*")); len(left) != 0 {
		t.Fatalf("files left after delivery: %v", left)
	}
}

// A payload Loki refuses outright is dropped, so it cannot hold up every line
// behind it; a timeout or a rate limit is retried.
func TestARefusedPayloadIsDroppedAndARateLimitIsRetried(t *testing.T) {
	r := &recorder{fail: &PushError{Status: http.StatusTooManyRequests}}
	o := NewOutbox("", r.push, r.logf)
	if err := o.Enqueue([]byte("x")); err != nil {
		t.Fatal(err)
	}
	if o.Flush(context.Background()) || o.Pending() != 1 {
		t.Fatalf("a rate-limited send left %d pending, want the line kept", o.Pending())
	}
	r.setFail(&PushError{Status: http.StatusBadRequest})
	if !o.Flush(context.Background()) || o.Pending() != 0 {
		t.Fatalf("a refused line is still pending (%d)", o.Pending())
	}
	if len(r.events) != 1 || r.events[0] != "outbox_refused" {
		t.Fatalf("events = %v, want one refused", r.events)
	}
}

// Past its limit the outbox refuses new lines, and says so once per episode.
func TestAFullOutboxRefusesNewLines(t *testing.T) {
	r := &recorder{fail: errors.New("down")}
	o := NewOutbox("", r.push, r.logf)
	o.maxItems = 2
	for i := 0; i < 2; i++ {
		if err := o.Enqueue([]byte("x")); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 3; i++ {
		if err := o.Enqueue([]byte("y")); !errors.Is(err, ErrFull) {
			t.Fatalf("enqueue past the limit = %v, want ErrFull", err)
		}
	}
	if len(r.events) != 1 || r.events[0] != "outbox_full" {
		t.Fatalf("events = %v, want one full", r.events)
	}
}

// A directory that cannot be used leaves the outbox working in memory, and the
// fallback is logged.
func TestAnUnusableDirectoryFallsBackToMemory(t *testing.T) {
	file := filepath.Join(t.TempDir(), "not-a-dir")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	r := &recorder{}
	o := NewOutbox(file, r.push, r.logf)
	if o.Durable() || len(r.events) != 1 || r.events[0] != "outbox_memory_only" {
		t.Fatalf("durable=%v events=%v, want a logged memory fallback", o.Durable(), r.events)
	}
	if err := o.Enqueue([]byte("m")); err != nil || !o.Flush(context.Background()) || len(r.got()) != 1 {
		t.Fatalf("the memory outbox did not deliver: %v %v", err, r.got())
	}
}

// The worker keeps trying while Loki is away and delivers when it returns.
func TestTheWorkerDeliversOnceLokiReturns(t *testing.T) {
	r := &recorder{fail: errors.New("down")}
	o := NewOutbox(t.TempDir(), r.push, r.logf)
	o.first, o.ceiling = 5*time.Millisecond, 20*time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go o.Run(ctx)
	if err := o.Enqueue([]byte("late")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	if len(r.got()) != 0 {
		t.Fatal("delivered while Loki was down")
	}
	r.setFail(nil)
	deadline := time.Now().Add(2 * time.Second)
	for o.Pending() != 0 {
		if time.Now().After(deadline) {
			t.Fatal("the worker never delivered after Loki came back")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if got := r.got(); len(got) != 1 || got[0] != "late" {
		t.Fatalf("delivered %q", got)
	}
}

// WaitReady waits out a Loki that is still starting and gives up at its bound.
func TestWaitReadyWaitsForLokiAndGivesUpAtItsBound(t *testing.T) {
	var calls atomic.Int32
	starting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/ready" {
			t.Errorf("probed %s, want /ready", r.URL.Path)
		}
		if calls.Add(1) < 3 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ready"))
	}))
	defer starting.Close()
	client := &http.Client{Timeout: time.Second}
	if !WaitReady(context.Background(), client, starting.URL+"/loki/api/v1/push", 5*time.Second, 5*time.Millisecond, 20*time.Millisecond) || calls.Load() != 3 {
		t.Fatalf("WaitReady did not see the third answer as ready (%d calls)", calls.Load())
	}
	never := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer never.Close()
	started := time.Now()
	if WaitReady(context.Background(), client, never.URL+"/loki/api/v1/push", 100*time.Millisecond, 10*time.Millisecond, 20*time.Millisecond) {
		t.Fatal("a Loki that never became ready was reported ready")
	}
	if waited := time.Since(started); waited > 2*time.Second {
		t.Fatalf("WaitReady overran its bound: %v", waited)
	}
}
