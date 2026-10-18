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

func TestPollRunnerFaultPreservesCompletedCycle(t *testing.T) {
	for _, faultKind := range []string{"legacy", "config", "update"} {
		separateFault := faultKind != "legacy"
		failureClass, stage := "config_gate_failed", ""
		if faultKind == "update" {
			failureClass, stage = "bootstrap_sync", "FrameworkPull"
		}
		for _, prior := range []string{"", "pass"} {
			t.Run(fmt.Sprintf("fault=%s/prior=%s", faultKind, prior), func(t *testing.T) {
				const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
				const start = "2026-10-01T12:00:00Z"
				s := newPoolState("default", 8080)
				s.hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.10"}
				if prior != "" {
					s.seen[hid+"|"+start] = prior
					s.counted[hid+"|"+start] = true
					s.pass[hid] = 1
				}
				var cycleLines []map[string]string
				runnerState := "paused"
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
							t.Fatal(err)
						}
						for _, stream := range payload.Streams {
							if stream.Stream["src"] != "cycle" {
								continue
							}
							for _, value := range stream.Values {
								var line map[string]string
								if err := json.Unmarshal([]byte(value[1]), &line); err != nil {
									t.Fatal(err)
								}
								cycleLines = append(cycleLines, line)
							}
						}
						code = http.StatusNoContent
					} else {
						switch r.URL.Path {
						case "/runtime/status.json":
							body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":%q,"overallStatus":"fail","runnerState":%q,"lastFailure":{"failureClass":"preamble_stall"},"history":[{"cycleStartUtc":%q,"overallStatus":"pass","finishedAt":"2026-10-01T12:30:00Z","hostname":"private-host","lastFailure":null}]}`, hid, start, runnerState, start)
							if separateFault {
								body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":%q,"overallStatus":"pass","finishedAt":"2026-10-01T12:30:00Z","runnerState":%q,"runnerFault":{"failureClass":%q,"stage":%q,"severity":"fatal","errorMessage":"private-host","transcriptPath":"private-host"}}`, hid, start, runnerState, failureClass, stage)
							}
						case "/runtime/host.registration.json":
							body = `{"poolId":"test-pool"}`
						default:
							code = http.StatusNotFound
						}
					}
					return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
				})}
				for i := 0; i < 2; i++ {
					s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", time.Now().UTC())
					runnerState = "cycle-start"
				}
				if s.pass[hid] != 1 || s.fail[hid] != 0 || len(s.failWindow[hid]) != 0 {
					t.Fatalf("runner fault counted as cycle failure: pass=%v fail=%v window=%v", s.pass, s.fail, s.failWindow)
				}
				wantLines := 1
				if prior != "" {
					wantLines = 0
				}
				if len(cycleLines) != wantLines {
					t.Fatalf("transitions=%v, want %d", cycleLines, wantLines)
				}
				for _, line := range cycleLines {
					if line["overallStatus"] != "pass" || line["failureClass"] != "" || line["finishedAt"] != "2026-10-01T12:30:00Z" {
						t.Fatalf("incorrect cycle: %v", line)
					}
				}
				wantHealth := "fail"
				if separateFault {
					wantHealth = "preflight-failed"
				}
				if s.hosts[hid].statusLabel() != wantHealth {
					t.Fatalf("runner fault health = %q, want %q", s.hosts[hid].statusLabel(), wantHealth)
				}
				encoded, err := json.Marshal(s.hosts[hid].Status)
				if err != nil {
					t.Fatal(err)
				}
				if strings.Contains(string(encoded), "private-host") {
					t.Fatal("history leaked host details")
				}
			})
		}
	}
}

func TestPollFirstAttemptFaultWithoutCycle(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	s := newPoolState("default", 8080)
	s.hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.10"}
	pushes := 0
	client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
		code, body := http.StatusNotFound, "{}"
		if r.Method == http.MethodPost {
			var payload struct {
				Streams []struct {
					Stream map[string]string `json:"stream"`
				} `json:"streams"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				return nil, err
			}
			for _, stream := range payload.Streams {
				if stream.Stream["src"] == "cycle" {
					pushes++
				}
			}
			code = http.StatusNoContent
		} else {
			switch r.URL.Path {
			case "/runtime/status.json":
				code = http.StatusOK
				body = fmt.Sprintf(`{"hostId":%q,"overallStatus":"unknown","guests":[],"history":[],"runnerFault":{"failureClass":"config_gate_failed","severity":"hard","errorMessage":"private-host"}}`, hid)
			case "/control/runner-status":
				code, body = http.StatusOK, `{"running":true}`
			}
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", time.Now().UTC())
	hv := s.hosts[hid]
	if !hv.Reachable || hv.statusLabel() != "preflight-failed" {
		t.Fatalf("first attempt must be a reachable host with a preflight failure: %+v", hv)
	}
	if s.pass[hid] != 0 || s.fail[hid] != 0 || len(s.seen) != 0 || pushes != 0 {
		t.Fatalf("attempt invented cycle accounting: pass=%v fail=%v seen=%v pushes=%d", s.pass, s.fail, s.seen, pushes)
	}
	encoded, err := json.Marshal(hv.Status)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "private-host") {
		t.Fatal("public snapshot leaked diagnostic text")
	}
}

func TestCycleStatusRequiresMatchingTerminalHistory(t *testing.T) {
	for _, tc := range []struct{ name, historyStart, historyStatus, want string }{
		{"fault overlay", "cycle", "pass", "pass"},
		{"failed cycle keeps cause", "cycle", "fail", "fail"},
		{"aborted refresh stays skipped", "cycle", "skipped", "skipped"},
		{"different cycle", "older", "pass", "fail"},
		{"unfinished history", "cycle", "running", "fail"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := &hostStatus{CycleStartUtc: "cycle", OverallStatus: "fail"}
			st.LastFailure.FailureClass = "preamble_stall"
			row := cycleVerdict{CycleStartUtc: tc.historyStart, OverallStatus: tc.historyStatus}
			row.LastFailure.FailureClass = "script_error"
			st.History = []cycleVerdict{row}
			got := st.cycleStatus()
			if got.OverallStatus != tc.want {
				t.Fatalf("got %s, want %s", got.OverallStatus, tc.want)
			}
			if tc.name == "failed cycle keeps cause" && got.LastFailure.FailureClass != "script_error" {
				t.Fatal("lost cycle cause")
			}
			if st.OverallStatus != "fail" || st.LastFailure.FailureClass != "preamble_stall" {
				t.Fatal("mutated live health")
			}
		})
	}
	st := &hostStatus{OverallStatus: "fail"}
	if st.cycleStatus() != st {
		t.Fatal("missing history must preserve an interrupted cycle")
	}
}
