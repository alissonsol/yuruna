// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type pollLokiTransport func(*http.Request) (*http.Response, error)

func (f pollLokiTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestPollOnceSlowLokiLeavesPoolReadableAndSnapshotsTransitions(t *testing.T) {
	const firstID = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const secondID = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC()
	s := newPoolState("default", 8080)
	s.hosts[firstID] = &hostView{HostId: firstID, CurrentIP: "192.0.2.10"}
	s.hosts[secondID] = &hostView{HostId: secondID, CurrentIP: "192.0.2.11"}
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var unblock sync.Once
	defer func() {
		unblock.Do(func() { close(release) })
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("poll did not finish after Loki was released")
		}
	}()
	var cycleLines []map[string]string
	var cyclePools []string
	client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
		code, body := http.StatusOK, "{}"
		if r.Method == http.MethodPost {
			var payload struct {
				Streams []struct {
					Stream map[string]string `json:"stream"`
					Values [][2]string       `json:"values"`
				} `json:"streams"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				return nil, err
			}
			for _, stream := range payload.Streams {
				if stream.Stream["src"] != "cycle" {
					continue
				}
				var line map[string]string
				if err := json.Unmarshal([]byte(stream.Values[0][1]), &line); err != nil {
					return nil, err
				}
				cycleLines = append(cycleLines, line)
				cyclePools = append(cyclePools, stream.Stream["pool"])
				if len(cycleLines) == 1 {
					close(started)
					select {
					case <-release:
					case <-r.Context().Done():
						return nil, r.Context().Err()
					}
				}
			}
			code = http.StatusNoContent
		} else {
			switch r.URL.Path {
			case "/runtime/status.json":
				hid := firstID
				if r.URL.Hostname() == "192.0.2.11" {
					hid = secondID
				}
				body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":"2026-09-27T12:00:00Z","overallStatus":"fail","lastFailure":{"failureClass":"network"}}`, hid)
			case "/runtime/host.registration.json":
				body = `{"poolId":"original-pool"}`
			default:
				code = http.StatusNotFound
			}
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	go func() {
		s.pollOnce(client, filepath.Join(t.TempDir(), "absent-squid.log"), "http://loki.invalid/push", now)
		close(done)
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("poll did not reach Loki")
	}

	response := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		w := httptest.NewRecorder()
		s.handlePoolStatus(w, httptest.NewRequest(http.MethodGet, routePoolStatus, nil))
		response <- w
	}()
	select {
	case w := <-response:
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), secondID) {
			t.Fatalf("pool response during slow Loki = %d %s", w.Code, w.Body.String())
		}
	case <-time.After(time.Second):
		t.Fatal("pool status blocked behind the Loki write")
	}

	// Later state changes must not rewrite the second transition waiting to send.
	s.mu.Lock()
	s.hosts[secondID].Status.OverallStatus = "running"
	s.hosts[secondID].Status.LastFailure.FailureClass = "changed"
	s.hosts[secondID].PoolId = "changed-pool"
	s.mu.Unlock()
	unblock.Do(func() { close(release) })
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("poll did not finish")
	}
	if len(cycleLines) != 2 {
		t.Fatalf("cycle transitions = %d, want 2", len(cycleLines))
	}
	if got := cycleLines[1]; got["hostId"] != secondID || got["overallStatus"] != "fail" || got["failureClass"] != "network" || cyclePools[1] != "original-pool" {
		t.Fatalf("queued transition changed with live state: pool=%q line=%v", cyclePools[1], got)
	}
	if s.fail[firstID] != 1 || s.fail[secondID] != 1 {
		t.Fatalf("cycle counters changed: %v", s.fail)
	}
}
