// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4204ec66-1575-44d4-b9fb-fd25d1598b33

package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// flakyLoki refuses pushes with 500 until up is set, and records what it took.
type flakyLoki struct {
	mu     sync.Mutex
	up     bool
	bodies []string
}

func (f *flakyLoki) handler(w http.ResponseWriter, r *http.Request) {
	b, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.up {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	f.bodies = append(f.bodies, string(b))
	w.WriteHeader(http.StatusNoContent)
}

func (f *flakyLoki) accepted(substr string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, b := range f.bodies {
		if strings.Contains(b, substr) {
			return true
		}
	}
	return false
}

// A cycle transition and a host's event lines that Loki refused are sent again
// on the next poll. seen and the event file's cursor used to move on before
// Loki answered, so a Loki outage lost both for good: the dashboard's counts
// and the event drill-down came from lines never written.
func TestLinesLokiRefusedAreSentOnTheNextPoll(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	now := time.Now().UTC()
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/runtime/status.json":
			fmt.Fprintf(w, `{"hostId":%q,"host":"host.ubuntu.kvm","cycleStartUtc":"2026-01-01T00:00:00Z","overallStatus":"pass","cycleFolderUrl":"/status/log/cycle-1/"}`, hid)
		case strings.HasSuffix(r.URL.Path, "/"+eventsFile):
			fmt.Fprint(w, `{"event":"step_done","timestamp":"2026-01-01T00:00:05Z","marker":"event-line-one"}`+"\n")
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer host.Close()
	flaky := &flakyLoki{}
	lokiSrv := httptest.NewServer(http.HandlerFunc(flaky.handler))
	defer lokiSrv.Close()

	u, _ := url.Parse(host.URL)
	port, _ := strconv.Atoi(u.Port())
	s := newPoolState("default", port)
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: u.Hostname(), LastSeenUnixMs: now.UnixMilli()}
	client := &http.Client{Timeout: 5 * time.Second}
	pushURL := lokiSrv.URL + "/loki/api/v1/push"

	s.pollOnce(client, "no-such-squid.log", pushURL, now)
	if flaky.accepted("") {
		t.Fatal("precondition: Loki was down and accepted nothing")
	}
	flaky.mu.Lock()
	flaky.up = true
	flaky.mu.Unlock()
	s.pollOnce(client, "no-such-squid.log", pushURL, now.Add(time.Minute))

	if !flaky.accepted(`"src":"cycle"`) {
		t.Error("the cycle transition Loki refused was never sent again")
	}
	if !flaky.accepted("event-line-one") {
		t.Error("the event lines Loki refused were never sent again")
	}
}

// With the outbox, a poll during a Loki outage holds its lines on disk, and they
// reach Loki once it is back -- the startup flush and the worker deliver them.
func TestTheOutboxHoldsAPollsLinesUntilLokiReturns(t *testing.T) {
	const hid = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC()
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/runtime/status.json":
			fmt.Fprintf(w, `{"hostId":%q,"host":"host.ubuntu.kvm","cycleStartUtc":"2026-01-01T00:00:00Z","overallStatus":"fail","cycleFolderUrl":"/status/log/cycle-2/"}`, hid)
		case strings.HasSuffix(r.URL.Path, "/"+eventsFile):
			fmt.Fprint(w, `{"event":"step_failed","timestamp":"2026-01-01T00:00:05Z","marker":"event-line-two"}`+"\n")
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer host.Close()
	flaky := &flakyLoki{}
	lokiSrv := httptest.NewServer(http.HandlerFunc(flaky.handler))
	defer lokiSrv.Close()
	u, _ := url.Parse(host.URL)
	port, _ := strconv.Atoi(u.Port())
	s := newPoolState("default", port)
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: u.Hostname(), LastSeenUnixMs: now.UnixMilli()}
	pushURL := lokiSrv.URL + "/loki/api/v1/push"
	dir := t.TempDir()
	s.outbox = newLokiOutbox(dir, pushURL)

	s.pollOnce(&http.Client{Timeout: 5 * time.Second}, "no-such-squid.log", pushURL, now)
	if s.outbox.Pending() < 2 {
		t.Fatalf("the outbox holds %d line(s) after a poll with Loki down, want the transition and the events", s.outbox.Pending())
	}
	// A restart in between: the next run picks the lines up from disk.
	restarted := newLokiOutbox(dir, pushURL)
	flaky.mu.Lock()
	flaky.up = true
	flaky.mu.Unlock()
	if !restarted.Flush(t.Context()) {
		t.Fatal("the outbox did not empty once Loki was back")
	}
	if !flaky.accepted(`"src":"cycle"`) || !flaky.accepted("event-line-two") {
		t.Fatal("the lines held through the outage did not reach Loki")
	}
}
