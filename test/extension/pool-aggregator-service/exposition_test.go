// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42c4e7b1-9d3a-4f58-b6c2-7e0a5d8f1c39

package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The HELP line of yuruna_pool_members_healthy names every state the gate
// counts healthy, and the gauge beside it counts a stopped runner the way the
// line says.
func TestMembersHealthyHelpNamesEveryCountedState(t *testing.T) {
	const hid = "42cafe0000000000000000000000c0de"
	s := newPoolState("default", 8080)
	s.view().Hosts[hid] = &hostView{HostId: hid, Reachable: true, RunnerStopped: true, LastSeenUnixMs: time.Now().UnixMilli()}
	s.st.Do(func(view *poolstate.View) { s.evaluatePoolGate(view, time.Now()) })
	rec := httptest.NewRecorder()
	s.handleMetricsBody(rec)
	help := ""
	for _, ln := range strings.Split(rec.Body.String(), "\n") {
		if strings.HasPrefix(ln, "# HELP yuruna_pool_members_healthy ") {
			help = ln
		}
	}
	if help == "" {
		t.Fatalf("no HELP line for yuruna_pool_members_healthy in:\n%s", rec.Body.String())
	}
	for _, state := range []string{"running", "pass", "idle", "stopped", "pending a pause", "not in an incident"} {
		if !strings.Contains(help, state) {
			t.Fatalf("the HELP text omits %q, a state the gate counts healthy: %s", state, help)
		}
	}
	if !strings.Contains(rec.Body.String(), "yuruna_pool_members_healthy{pool=\"default\"} 1\n") {
		t.Fatalf("a stopped runner was not counted healthy:\n%s", rec.Body.String())
	}
}

// A line the outbox cannot write to its folder is answered under its own
// code, so the pusher can tell a fault on the collector from the backpressure
// of a full outbox.
func TestIngestTellsAWriteFaultFromAFullOutbox(t *testing.T) {
	const hid = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	dir := t.TempDir() + "/outbox"
	s := newPoolState("default", 8080)
	s.authToken = "secret"
	s.httpClient = &http.Client{}
	s.lokiURL = "http://127.0.0.1:9/loki/api/v1/push"
	s.outbox = newLokiOutbox(dir, s.lokiURL)
	if !s.outbox.Durable() {
		t.Fatalf("the outbox did not open %s as durable", dir)
	}
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "10.0.0.5", PoolId: "lab"}
	post := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(`{"event":"step_end","hostId":"`+hid+`"}`+"\n"))
		req.RemoteAddr = "10.0.0.5:1"
		req.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		s.handleIngest(w, req)
		return w
	}
	if w := post(); w.Code != http.StatusAccepted {
		t.Fatalf("a writable outbox answered %d: %s", w.Code, w.Body.String())
	}
	// The folder goes away under the outbox: the next line cannot be held.
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	w := post()
	if w.Code != http.StatusServiceUnavailable || w.Header().Get("X-Yuruna-Message-Code") != "aggregator.ingest_not_recorded" {
		t.Fatalf("a write fault answered %d %q: %s", w.Code, w.Header().Get("X-Yuruna-Message-Code"), w.Body.String())
	}
	if message := strings.TrimSpace(w.Body.String()); message == "" || strings.Contains(message, "aggregator.ingest_not_recorded") {
		t.Fatalf("a write fault returned an untranslated catalog key instead of a message: %q", message)
	}
}

func TestIngestFullOutboxRequestsBackpressure(t *testing.T) {
	const hid = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	s := newPoolState("default", 8080)
	s.authToken = "secret"
	s.lokiURL = "http://127.0.0.1:9/loki/api/v1/push"
	s.outbox = newLokiOutbox("", s.lokiURL)
	for i := 0; i < loki.DefaultMaxItems; i++ {
		if err := s.outbox.Enqueue([]byte("{}")); err != nil {
			t.Fatalf("filling the outbox at item %d: %v", i, err)
		}
	}
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "10.0.0.5", PoolId: "lab"}
	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(`{"event":"step_end","hostId":"`+hid+`"}`+"\n"))
	req.RemoteAddr = "10.0.0.5:1"
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.handleIngest(w, req)
	if w.Code != http.StatusServiceUnavailable || w.Header().Get("X-Yuruna-Message-Code") != "aggregator.ingest_queue_full" {
		t.Fatalf("a full outbox answered %d %q: %s", w.Code, w.Header().Get("X-Yuruna-Message-Code"), w.Body.String())
	}
	if pending := s.outbox.Pending(); pending != loki.DefaultMaxItems {
		t.Fatalf("a refused ingest changed the queued item count: %d", pending)
	}
}
