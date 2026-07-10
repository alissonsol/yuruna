// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package beacon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// announceRec is one decoded /announce body a test aggregator captured.
type announceRec struct {
	SchemaVersion int    `json:"schemaVersion"`
	HostID        string `json:"hostId"`
	Area          string `json:"area"`
	TargetPort    int    `json:"targetPort"`
	Active        bool   `json:"active"`
}

// recorder is a fake aggregator that captures every /announce body and can
// fail the first N requests (the boot catch-up scenario).
type recorder struct {
	mu       sync.Mutex
	got      []announceRec
	failLeft int
	notify   chan announceRec
}

func (r *recorder) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/announce" || req.Method != http.MethodPost {
			http.NotFound(w, req)
			return
		}
		r.mu.Lock()
		if r.failLeft > 0 {
			r.failLeft--
			r.mu.Unlock()
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		var a announceRec
		if err := json.NewDecoder(req.Body).Decode(&a); err != nil {
			r.mu.Unlock()
			http.Error(w, "bad body", http.StatusBadRequest)
			return
		}
		r.got = append(r.got, a)
		notify := r.notify
		r.mu.Unlock()
		if notify != nil {
			notify <- a
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func (r *recorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.got)
}

func waitFor(t *testing.T, ch <-chan announceRec, what string) announceRec {
	t.Helper()
	select {
	case a := <-ch:
		return a
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
		return announceRec{}
	}
}

func TestEnabledRequiresURLHostIDAndInterval(t *testing.T) {
	cases := []struct {
		name string
		b    *Beacon
		want bool
	}{
		{"all set", New("http://127.0.0.1:9400", "hid", "stash-service", 80, time.Minute), true},
		{"no url", New("", "hid", "stash-service", 80, time.Minute), false},
		{"no hostId", New("http://127.0.0.1:9400", "", "stash-service", 80, time.Minute), false},
		{"zero interval", New("http://127.0.0.1:9400", "hid", "stash-service", 80, 0), false},
	}
	for _, c := range cases {
		if got := c.b.Enabled(); got != c.want {
			t.Errorf("%s: Enabled = %v, want %v", c.name, got, c.want)
		}
	}
}

// Hello on start, goodbye (active=false) on cancel -- the boot/shutdown agency
// the beacon exists for.
func TestHelloAndGoodbye(t *testing.T) {
	rec := &recorder{notify: make(chan announceRec, 8)}
	srv := httptest.NewServer(rec.handler())
	defer srv.Close()

	b := New(srv.URL, "42512149e3dc437ca677a40828382528", "stash-service", 80, time.Hour)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { b.Run(ctx); close(done) }()

	hello := waitFor(t, rec.notify, "hello announce")
	if !hello.Active || hello.HostID != "42512149e3dc437ca677a40828382528" || hello.Area != "stash-service" || hello.TargetPort != 80 {
		t.Errorf("hello = %+v, want active stash-service announce with targetPort 80", hello)
	}
	if hello.SchemaVersion != 1 {
		t.Errorf("schemaVersion = %d, want 1", hello.SchemaVersion)
	}

	cancel()
	goodbye := waitFor(t, rec.notify, "goodbye announce")
	if goodbye.Active {
		t.Errorf("goodbye = %+v, want active=false", goodbye)
	}
	<-done
}

// The steady-state loop re-announces every Interval so the aggregator's
// announce TTL never expires while the service lives.
func TestPeriodicReannounce(t *testing.T) {
	rec := &recorder{notify: make(chan announceRec, 32)}
	srv := httptest.NewServer(rec.handler())
	defer srv.Close()

	b := New(srv.URL, "hid", "stash-service", 80, 20*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { b.Run(ctx); close(done) }()

	for i := 0; i < 3; i++ {
		waitFor(t, rec.notify, "periodic announce")
	}
	cancel()
	<-done
}

// Until the FIRST announce lands, failures retry on the catch-up cadence
// (min(1m, Interval)); afterwards the loop runs at Interval. Covers the
// whole-lab-reboot ordering where the stash VM is up before the aggregator.
func TestHelloRetriesUntilFirstSuccess(t *testing.T) {
	rec := &recorder{failLeft: 2, notify: make(chan announceRec, 8)}
	srv := httptest.NewServer(rec.handler())
	defer srv.Close()

	b := New(srv.URL, "hid", "stash-service", 80, time.Hour)
	b.helloRetry = 10 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { b.Run(ctx); close(done) }()

	hello := waitFor(t, rec.notify, "hello after retries")
	if !hello.Active {
		t.Errorf("first successful announce = %+v, want active=true", hello)
	}
	cancel()
	<-done
}

// An https-configured beacon downgrades to plain http when the aggregator has
// no TLS leaf (transport-level failure), mirroring the host-side notifier's
// https-then-http candidate order.
func TestHTTPSFallsBackToHTTP(t *testing.T) {
	rec := &recorder{notify: make(chan announceRec, 8)}
	srv := httptest.NewServer(rec.handler())
	defer srv.Close()

	httpsURL := "https://" + strings.TrimPrefix(srv.URL, "http://")
	b := New(httpsURL, "hid", "stash-service", 80, time.Hour)
	if got := b.candidates(); len(got) != 2 || got[0] != httpsURL || got[1] != srv.URL {
		t.Fatalf("candidates = %v, want [%s %s]", got, httpsURL, srv.URL)
	}
	if err := b.announce(context.Background(), true); err != nil {
		t.Fatalf("announce with https->http fallback: %v", err)
	}
	if rec.count() != 1 {
		t.Errorf("aggregator received %d announces, want 1 via the http fallback", rec.count())
	}
}

// A non-2xx from a REACHABLE aggregator is a protocol answer, not a scheme
// mismatch: the beacon must not downgrade over it (the second candidate would
// double-deliver on a validation rejection).
func TestNo2xxDoesNotDowngrade(t *testing.T) {
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		http.Error(w, "bad announce", http.StatusBadRequest)
	}))
	defer srv.Close()

	b := New(srv.URL, "hid", "stash-service", 80, time.Hour)
	if err := b.announce(context.Background(), true); err == nil {
		t.Fatal("announce returned nil, want the HTTP 400 surfaced as an error")
	}
	if hits != 1 {
		t.Errorf("aggregator hit %d times, want exactly 1 (no retry on a protocol answer)", hits)
	}
}
