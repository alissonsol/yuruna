// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428dd1c4-9a0f-4be0-85a2-850d288a9956

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

type pollLokiTransport func(*http.Request) (*http.Response, error)

func (f pollLokiTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestPollOnceSlowLokiLeavesPoolReadableAndSnapshotsTransitions(t *testing.T) {
	const firstID = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const secondID = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC()
	s := newPoolState("default", 8080)
	s.view().Hosts[firstID] = &hostView{HostId: firstID, CurrentIP: "192.0.2.10"}
	s.view().Hosts[secondID] = &hostView{HostId: secondID, CurrentIP: "192.0.2.11"}
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
	s.st.Do(func(view *poolstate.View) {
		view.Hosts[secondID].Status.OverallStatus = "running"
		view.Hosts[secondID].Status.LastFailure.FailureClass = "changed"
		view.Hosts[secondID].PoolId = "changed-pool"
	})
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
	if _, failTotals := s.view().CycleTotals(); failTotals[firstID] != 1 || failTotals[secondID] != 1 {
		t.Fatalf("cycle counters changed: %v", failTotals)
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
				s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.10"}
				if prior != "" {
					s.seedCycle(hid, start, prior, time.Now(), true)
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
				if passes, fails := s.cycleTotals(hid); passes != 1 || fails != 0 || len(s.view().FailWindow[hid]) != 0 {
					t.Fatalf("runner fault counted as cycle failure: pass=%d fail=%d window=%v", passes, fails, s.view().FailWindow)
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
				if s.view().Hosts[hid].StatusLabel() != wantHealth {
					t.Fatalf("runner fault health = %q, want %q", s.view().Hosts[hid].StatusLabel(), wantHealth)
				}
				encoded, err := json.Marshal(s.view().Hosts[hid].Status)
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

// A runner that died inside a cycle reads as its own status, not as the stop an
// operator makes: the host still answers, its status.json still says the cycle
// runs, and only runner-status can tell. An operator's Ctrl+C mid-cycle leaves the
// runner state at in-cycle too, but its orderly shutdown removes runner.pid, so
// it stays "stopped". A probe that misses a tick keeps the last reading.
func TestPollTellsARunnerLostMidCycleFromAStoppedOne(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	for _, tc := range []struct {
		name, runnerStatus, wantLabel string
		wantCode                      int
	}{
		{"runner died mid-cycle", `{"running":false,"pid":11128,"liveness":"idle","runnerState":"in-cycle","lastExit":null}`, "lost", 10},
		{"operator stopped a running cycle", `{"running":false,"pid":null,"liveness":"idle","runnerState":"in-cycle","lastExit":null}`, "stopped", 8},
		{"runner died between cycles", `{"running":false,"pid":11128,"liveness":"idle","runnerState":"idle","lastExit":null}`, "stopped", 8},
		{"older build without a runner state", `{"running":false,"pid":11128,"liveness":"idle"}`, "stopped", 8},
		{"live runner mid-cycle", `{"running":true,"pid":11128,"liveness":"ok","runnerState":"in-cycle"}`, "running", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newPoolState("default", 8080)
			s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.10"}
			routeUp := true
			client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
				code, body := http.StatusNotFound, "{}"
				if r.Method == http.MethodPost {
					code = http.StatusNoContent
				} else {
					switch r.URL.Path {
					case "/runtime/status.json":
						code = http.StatusOK
						body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":"2026-11-07T15:31:53Z","overallStatus":"running","runnerState":"in-cycle"}`, hid)
					case "/control/runner-status":
						if !routeUp {
							return nil, fmt.Errorf("connection reset")
						}
						code, body = http.StatusOK, tc.runnerStatus
					}
				}
				return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
			})}
			for poll := 0; poll < 2; poll++ {
				s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", time.Now().UTC())
				hv := s.view().Hosts[hid]
				if got := hv.StatusLabel(); got != tc.wantLabel {
					t.Fatalf("poll %d: StatusLabel = %q, want %q", poll, got, tc.wantLabel)
				}
				rec := httptest.NewRecorder()
				s.handleMetricsBody(rec)
				want := fmt.Sprintf("hostIdDashed=%q} %d\n", poolstate.DashedHostID(hid), tc.wantCode)
				found := false
				for _, ln := range strings.SplitAfter(rec.Body.String(), "\n") {
					if strings.HasPrefix(ln, "yuruna_pool_host_status{") && strings.HasSuffix(ln, want) {
						found = true
					}
				}
				if !found {
					t.Fatalf("poll %d: no yuruna_pool_host_status line ending %q in:\n%s", poll, want, rec.Body.String())
				}
				routeUp = false
			}
		})
	}
}

func TestPollFirstAttemptFaultWithoutCycle(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	s := newPoolState("default", 8080)
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.10"}
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
	hv := s.view().Hosts[hid]
	if !hv.Reachable || hv.StatusLabel() != "preflight-failed" {
		t.Fatalf("first attempt must be a reachable host with a preflight failure: %+v", hv)
	}
	if passes, fails := s.cycleTotals(hid); passes != 0 || fails != 0 || s.view().CycleCount() != 0 || pushes != 0 {
		t.Fatalf("attempt invented cycle accounting: pass=%d fail=%d cycles=%d pushes=%d", passes, fails, s.view().CycleCount(), pushes)
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
			got := st.CycleStatus()
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
	if st.CycleStatus() != st {
		t.Fatal("missing history must preserve an interrupted cycle")
	}
}

// lokiPushRecorder keeps what a poll pushed, stream by stream in arrival order,
// and applies Loki's rules for a stream it already holds: an exact duplicate of
// an entry is dropped, and an entry more than an hour older than the newest
// entry of its stream -- one accepted earlier in the same push included -- is
// refused.
type lokiPushRecorder struct {
	mu      sync.Mutex
	labels  map[string]map[string]string
	stored  map[string][]lokiRecordedEntry
	refused []string
}

type lokiRecordedEntry struct {
	ns   int64
	line string
}

func (l *lokiPushRecorder) push(r *http.Request) error {
	var payload struct {
		Streams []struct {
			Stream map[string]string `json:"stream"`
			Values [][2]string       `json:"values"`
		} `json:"streams"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stored == nil {
		l.labels, l.stored = map[string]map[string]string{}, map[string][]lokiRecordedEntry{}
	}
	for _, st := range payload.Streams {
		key := labelKey(st.Stream)
		l.labels[key] = st.Stream
		for _, v := range st.Values {
			ns, err := strconv.ParseInt(v[0], 10, 64)
			if err != nil {
				return err
			}
			entries := l.stored[key]
			newest, duplicate := int64(0), false
			for _, e := range entries {
				newest = max(newest, e.ns)
				duplicate = duplicate || (e.ns == ns && e.line == v[1])
			}
			switch {
			case duplicate:
			case len(entries) > 0 && ns < newest-int64(time.Hour):
				l.refused = append(l.refused, v[1])
			default:
				l.stored[key] = append(entries, lokiRecordedEntry{ns: ns, line: v[1]})
			}
		}
	}
	return nil
}

// entries returns the stored entries of every stream whose labels include want.
func (l *lokiPushRecorder) entries(want map[string]string) []lokiRecordedEntry {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []lokiRecordedEntry
	for key, labels := range l.labels {
		match := true
		for k, v := range want {
			match = match && labels[k] == v
		}
		if match {
			out = append(out, l.stored[key]...)
		}
	}
	return out
}

// queryRange serves the startup restore's range queries from what l holds: the
// entries of the streams with the src label the query names (the cycle
// transitions when it names none) inside the query's range, newest first.
func (l *lokiPushRecorder) queryRange() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		src := "cycle"
		if _, rest, named := strings.Cut(q.Get("query"), `src="`); named {
			src, _, _ = strings.Cut(rest, `"`)
		}
		start, _ := strconv.ParseInt(q.Get("start"), 10, 64)
		end, _ := strconv.ParseInt(q.Get("end"), 10, 64)
		entries := l.entries(map[string]string{"src": src})
		sort.Slice(entries, func(i, j int) bool { return entries[i].ns > entries[j].ns })
		values := [][2]string{}
		for _, e := range entries {
			if e.ns >= start && e.ns <= end {
				values = append(values, [2]string{strconv.FormatInt(e.ns, 10), e.line})
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"result": []map[string]any{{"stream": map[string]string{"src": src}, "values": values}}}})
	}))
}

// A host's event file mixes lines that carry their own timestamp with lines
// that carry none: the orchestrator writes step.start and step.end without one.
// Loki refuses an entry more than an hour older than the newest of its stream,
// so stamping such a line with the clock of a catch-up that runs hours after the
// cycle moved the stream's head to that clock, and every older line after it in
// the file was refused. Such a line takes the timestamp of the line before it
// in the file, or the cycle's start when nothing precedes it, across polls, and
// a restart that ships the file again sends the same entries.
func TestEventTailCatchUpLeavesNoLineBehindTheHead(t *testing.T) {
	const hid = "42dddddddddddddddddddddddddddddd"
	const start = "2026-11-08T15:06:04Z"
	first := []string{
		`{"event":"step.start","index":0,"name":"preamble"}`,
		`{"event":"cycle_start","timestamp":"2026-11-08T15:06:05Z","cycleStartUtc":"2026-11-08T15:06:04Z"}`,
		`{"event":"step.start","index":1,"name":"provision"}`,
		`{"event":"step_end","timestamp":"2026-11-08T15:42:41Z","stepNumber":1}`,
		`{"event":"step.end","index":1,"outcome":"pass"}`,
	}
	later := []string{
		`{"event":"step.start","index":2,"name":"workload"}`,
		`{"event":"step_end","timestamp":"2026-11-08T15:55:20Z","stepNumber":2}`,
		`{"event":"step.end","index":2,"outcome":"pass"}`,
		`{"event":"cycle_end","timestamp":"2026-11-08T15:55:28Z","outcome":"pass"}`,
	}
	at := func(s string) int64 {
		ts, err := time.Parse(time.RFC3339, s)
		if err != nil {
			t.Fatal(err)
		}
		return ts.UnixNano()
	}
	want := map[string]int64{
		first[0]: at(start), first[1]: at("2026-11-08T15:06:05Z"), first[2]: at("2026-11-08T15:06:05Z"),
		first[3]: at("2026-11-08T15:42:41Z"), first[4]: at("2026-11-08T15:42:41Z"),
		later[0]: at("2026-11-08T15:42:41Z"), later[1]: at("2026-11-08T15:55:20Z"),
		later[2]: at("2026-11-08T15:55:20Z"), later[3]: at("2026-11-08T15:55:28Z"),
	}
	var mu sync.Mutex
	file := strings.Join(first, "\n") + "\n"
	loki := &lokiPushRecorder{}
	client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
		code, body := http.StatusNotFound, "{}"
		switch {
		case r.Method == http.MethodPost:
			if err := loki.push(r); err != nil {
				return nil, err
			}
			code = http.StatusNoContent
		case r.URL.Path == "/runtime/status.json":
			code = http.StatusOK
			body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":%q,"overallStatus":"pass","cycleFolderUrl":"status/log/001401.2026-11-08.15-06-04.%s/"}`, hid, start, hid)
		case strings.HasSuffix(r.URL.Path, "/"+eventsFile):
			mu.Lock()
			code, body = http.StatusOK, file
			mu.Unlock()
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	now := time.Date(2026, 11, 9, 1, 23, 31, 0, time.UTC) // hours after the cycle ended
	s := newPoolState("default", 8080)
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.20"}
	s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", now)
	mu.Lock()
	file += strings.Join(later, "\n") + "\n"
	mu.Unlock()
	s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", now.Add(30*time.Second))
	// A restarted collector holds no cursor and ships the whole file again.
	restarted := newPoolState("default", 8080)
	restarted.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.20"}
	restarted.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", now.Add(time.Hour))

	if len(loki.refused) != 0 {
		t.Fatalf("Loki refused %d line(s) as too far behind the stream's newest: %v", len(loki.refused), loki.refused)
	}
	got := loki.entries(map[string]string{"pool": "default", "hostId": hid, "src": "event"})
	if len(got) != len(want) {
		t.Fatalf("the stream holds %d entries, want each of the file's %d lines once: %v", len(got), len(want), got)
	}
	for _, e := range got {
		if e.ns != want[e.line] {
			t.Errorf("%s stamped %s, want %s", e.line, time.Unix(0, e.ns).UTC().Format(time.RFC3339), time.Unix(0, want[e.line]).UTC().Format(time.RFC3339))
		}
	}
}

// observedLines returns the lines the collector wrote from its own observation
// of hostID, decoded, in arrival order.
func observedLines(t *testing.T, loki *lokiPushRecorder, hostID string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, e := range loki.entries(map[string]string{"hostId": hostID, "src": "event", "emitter": "pool-aggregator-service"}) {
		var m map[string]any
		if err := json.Unmarshal([]byte(e.line), &m); err != nil {
			t.Fatal(err)
		}
		out = append(out, m)
	}
	return out
}

// A runner that dies inside a cycle while its host keeps answering reads "lost"
// on every poll until someone starts it again. The pool records it once, as a
// runner_lost line in the host's event stream that says how the runner ended,
// whatever the polls between see; a line Loki did not take is sent again; and a
// restarted collector, which remembers nothing, records the same episode under
// the same key once more.
func TestPollRecordsALostRunnerOncePerEpisode(t *testing.T) {
	const hid = "42eeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	const cycleStart = "2026-11-11T23:01:26Z"
	exit := func(pid int, started string) string {
		return fmt.Sprintf(`{"pid":%d,"startedUtc":%q,"recordedUtc":"2026-11-09T02:23:26.0000000Z","sshSession":false,"terminalProgram":"Apple_Terminal","multiplexer":null,"parents":["zsh[1432]","login[1430]"],"hostBootUtc":"2026-10-27T15:34:30.0000000Z","signal":"SIGHUP","signalAtUtc":"2026-11-11T23:18:46.8000000Z","hostRestarted":false}`, pid, started)
	}
	lost := func(pid int, lastExit string) string {
		return fmt.Sprintf(`{"running":false,"pid":%d,"liveness":"idle","runnerState":"in-cycle","lastExit":%s}`, pid, lastExit)
	}
	var mu sync.Mutex
	runner, lokiDown := lost(4242, exit(4242, "2026-11-09T02:23:25.1234567Z")), false
	loki := &lokiPushRecorder{}
	client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		answer, down := runner, lokiDown
		mu.Unlock()
		code, body := http.StatusNotFound, "{}"
		switch {
		case r.Method == http.MethodPost:
			code = http.StatusInternalServerError
			if !down {
				if err := loki.push(r); err != nil {
					return nil, err
				}
				code = http.StatusNoContent
			}
		case r.URL.Path == "/runtime/status.json":
			code = http.StatusOK
			body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":%q,"overallStatus":"running","cycleFolderUrl":"status/log/005171.2026-11-11.23-01-26.%s/"}`, hid, cycleStart, hid)
		case r.URL.Path == "/runtime/host.registration.json":
			code, body = http.StatusOK, `{"poolId":"test-pool"}`
		case r.URL.Path == "/control/runner-status":
			if answer == "" {
				return nil, fmt.Errorf("connection reset")
			}
			code, body = http.StatusOK, answer
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	set := func(answer string, down bool) {
		mu.Lock()
		runner, lokiDown = answer, down
		mu.Unlock()
	}
	now := time.Date(2026, 11, 11, 23, 19, 8, 0, time.UTC)
	poll := func(s *poolState) {
		now = now.Add(30 * time.Second)
		s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", now)
	}
	s := newPoolState("default", 8080)
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.30"}

	poll(s)
	lines := observedLines(t, loki, hid)
	if len(lines) != 1 {
		t.Fatalf("a lost runner wrote %d line(s), want 1: %v", len(lines), lines)
	}
	want := map[string]any{
		"event": "runner_lost", "timestamp": now.Format(time.RFC3339), "hostId": hid, "pool": "test-pool",
		"episodeKey": hid + "/4242/2026-11-09T02:23:25.1234567Z", "pid": float64(4242),
		"runnerStartedUtc": "2026-11-09T02:23:25.1234567Z", "signal": "SIGHUP", "signalAtUtc": "2026-11-11T23:18:46.8000000Z",
		"hostRestarted": false, "terminalProgram": "Apple_Terminal", "sshSession": false,
		"cycleStartUtc": cycleStart, "cycleFolderUrl": "status/log/005171.2026-11-11.23-01-26." + hid + "/",
	}
	if !reflect.DeepEqual(lines[0], want) {
		t.Fatalf("runner_lost line = %v, want %v", lines[0], want)
	}

	// The same episode on later polls: answered again, unanswered, read as a
	// plain stop for a poll, then lost again.
	poll(s)
	set("", false)
	poll(s)
	set(`{"running":false,"pid":null,"liveness":"idle","runnerState":"in-cycle","lastExit":null}`, false)
	poll(s)
	set(lost(4242, exit(4242, "2026-11-09T02:23:25.1234567Z")), false)
	poll(s)
	if lines = observedLines(t, loki, hid); len(lines) != 1 {
		t.Fatalf("one episode wrote %d lines, want 1: %v", len(lines), lines)
	}

	// The next runner dies too, on a host that reports no exit record: the
	// episode is keyed on the cycle, and the line arrives once Loki takes it.
	set(lost(5151, "null"), true)
	poll(s)
	set(lost(5151, "null"), false)
	poll(s)
	poll(s)
	lines = observedLines(t, loki, hid)
	if len(lines) != 2 {
		t.Fatalf("two episodes, one first refused by Loki, wrote %d lines, want 2: %v", len(lines), lines)
	}
	second := lines[1]
	if second["episodeKey"] != hid+"/5151/"+cycleStart || second["signal"] != nil || second["runnerStartedUtc"] != nil || second["hostRestarted"] != nil {
		t.Fatalf("a runner without an exit record = %v", second)
	}

	restarted := newPoolState("default", 8080)
	restarted.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.30"}
	poll(restarted)
	lines = observedLines(t, loki, hid)
	if len(lines) != 3 || lines[2]["episodeKey"] != second["episodeKey"] {
		t.Fatalf("a restart must repeat the open episode once under its key: %v", lines)
	}
}

// A runner reads lost from before the next cycle rewrites status.json until
// after the teardown and the wait that follow a cycle's verdict. A runner that
// dies in those stretches leaves status.json holding a finished cycle, or the
// next cycle's interim document that names no folder yet, so its runner_lost
// line names no cycle rather than one the runner was not running. The episode
// key is the same either way.
func TestPollNamesTheCycleOfALostRunnerOnlyWhileOneIsInProgress(t *testing.T) {
	const hid = "42c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"
	const runnerStarted = "2026-11-09T02:23:25.1234567Z"
	folder := "status/log/005170.2026-11-11.22-47-10." + hid + "/"
	withExit := fmt.Sprintf(`{"running":false,"pid":4242,"liveness":"idle","runnerState":"in-cycle","lastExit":{"pid":4242,"startedUtc":%q,"sshSession":false,"terminalProgram":"Apple_Terminal","signal":"SIGHUP","signalAtUtc":"2026-11-11T23:01:40.0000000Z","hostRestarted":false}}`, runnerStarted)
	lostLine := func(status, runner string) map[string]any {
		t.Helper()
		loki := &lokiPushRecorder{}
		client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
			code, body := http.StatusNotFound, "{}"
			switch {
			case r.Method == http.MethodPost:
				if err := loki.push(r); err != nil {
					return nil, err
				}
				code = http.StatusNoContent
			case r.URL.Path == "/runtime/status.json":
				code, body = http.StatusOK, status
			case r.URL.Path == "/control/runner-status":
				code, body = http.StatusOK, runner
			}
			return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
		})}
		s := newPoolState("default", 8080)
		s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.50"}
		s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", time.Date(2026, 11, 11, 23, 2, 0, 0, time.UTC))
		lines := observedLines(t, loki, hid)
		if len(lines) != 1 || lines[0]["event"] != "runner_lost" {
			t.Fatalf("a lost runner wrote %v, want one runner_lost line", lines)
		}
		return lines[0]
	}
	finished := fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":"2026-11-11T22:47:10Z","overallStatus":"pass","finishedAt":"2026-11-11T23:01:20Z","cycleFolderUrl":%q}`, hid, folder)
	for name, status := range map[string]string{
		"a finished cycle": finished,
		// The host-refresh gate ends a cycle before its first VM change.
		"a skipped cycle":      fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":"2026-11-11T22:47:10Z","overallStatus":"skipped","finishedAt":"2026-11-11T22:48:00Z","cycleFolderUrl":%q}`, hid, folder),
		"the interim document": fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":"2026-11-11T23:01:35Z","startedAt":"2026-11-11T23:01:35Z","finishedAt":null,"overallStatus":"running"}`, hid),
	} {
		line := lostLine(status, withExit)
		for _, k := range []string{"cycleStartUtc", "cycleFolderUrl"} {
			if v, present := line[k]; !present || v != nil {
				t.Errorf("%s: %s = %v (present %v), want null", name, k, v, present)
			}
		}
		if line["episodeKey"] != hid+"/4242/"+runnerStarted {
			t.Errorf("%s: episodeKey = %v, want the runner's pid and start", name, line["episodeKey"])
		}
	}
	// Without an exit record the key falls back to the cycle start in the
	// host's status, which nothing rewrites while the runner stays dead.
	line := lostLine(finished, `{"running":false,"pid":4242,"liveness":"idle","runnerState":"in-cycle","lastExit":null}`)
	if line["episodeKey"] != hid+"/4242/2026-11-11T22:47:10Z" || line["cycleStartUtc"] != nil || line["cycleFolderUrl"] != nil {
		t.Fatalf("a runner without an exit record after a finished cycle = %v", line)
	}
}

// A host the collector reached that stops answering -- shut down, rebooting, or
// its status service gone with its runner -- is recorded once per stretch
// without an answer, after a grace that covers a status service restart, with
// the reason the last probe failed. When the host TTL drops it from the view,
// that is recorded too. A host only seeded from Loki and never reached in this
// run was never seen by this collector: it writes no host_unreachable, and its
// drop is recorded without a last-seen time.
func TestPollRecordsAHostThatStopsAnsweringAndItsDrop(t *testing.T) {
	const hid = "42ffffffffffffffffffffffffffffff"
	const stub = "42ababababababababababababababab"
	t0 := time.Date(2026, 11, 10, 20, 29, 2, 0, time.UTC)
	var mu sync.Mutex
	down := false
	loki := &lokiPushRecorder{}
	client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		isDown := down
		mu.Unlock()
		code, body := http.StatusNotFound, "{}"
		switch {
		case r.Method == http.MethodPost:
			if err := loki.push(r); err != nil {
				return nil, err
			}
			code = http.StatusNoContent
		case r.URL.Hostname() != "192.0.2.40" || isDown:
			return nil, fmt.Errorf("connect: connection refused")
		case r.URL.Path == "/runtime/status.json":
			code = http.StatusOK
			body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":"2026-11-10T20:16:37Z","overallStatus":"running"}`, hid)
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	setDown := func(v bool) {
		mu.Lock()
		down = v
		mu.Unlock()
	}
	s := newPoolState("default", 8080)
	s.hostTtl = time.Hour
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.40"}
	s.view().Hosts[stub] = &hostView{HostId: stub, CurrentIP: "192.0.2.41", LastSeenUnixMs: t0.UnixMilli()}
	poll := func(at time.Time) {
		s.pollOnce(client, filepath.Join(t.TempDir(), "absent.log"), "http://loki.invalid/push", at)
	}
	count := func(event string) (n int, last map[string]any) {
		for _, m := range observedLines(t, loki, hid) {
			if m["event"] == event {
				n, last = n+1, m
			}
		}
		return n, last
	}

	poll(t0)
	setDown(true)
	poll(t0.Add(time.Minute))
	poll(t0.Add(5*time.Minute - time.Second))
	if n, _ := count("host_unreachable"); n != 0 {
		t.Fatalf("host_unreachable inside the grace: %d", n)
	}
	poll(t0.Add(5 * time.Minute))
	poll(t0.Add(10 * time.Minute))
	n, line := count("host_unreachable")
	if n != 1 {
		t.Fatalf("one stretch without an answer wrote %d host_unreachable lines, want 1", n)
	}
	if line["lastSeenUtc"] != t0.Format(time.RFC3339) || line["lastIp"] != "192.0.2.40" || line["pool"] != "default" ||
		line["timestamp"] != t0.Add(5*time.Minute).Format(time.RFC3339) || !strings.Contains(fmt.Sprint(line["lastError"]), "connection refused") {
		t.Fatalf("host_unreachable line = %v", line)
	}

	// It answers once, then stops again: a new stretch, a new line.
	setDown(false)
	back := t0.Add(11 * time.Minute)
	poll(back)
	setDown(true)
	poll(back.Add(6 * time.Minute))
	if n, line = count("host_unreachable"); n != 2 || line["lastSeenUtc"] != back.Format(time.RFC3339) {
		t.Fatalf("a second stretch: %d lines, last %v", n, line)
	}

	dropAt := back.Add(time.Hour + time.Second)
	poll(dropAt)
	if _, held := s.view().Hosts[hid]; held {
		t.Fatal("the host outlived the host TTL")
	}
	n, line = count("host_dropped")
	if n != 1 || line["lastSeenUtc"] != back.Format(time.RFC3339) || line["ttlSeconds"] != float64(3600) || line["timestamp"] != dropAt.Format(time.RFC3339) {
		t.Fatalf("host_dropped: %d lines, last %v", n, line)
	}
	if _, held := s.view().Hosts[stub]; held {
		t.Fatal("the seeded host outlived the host TTL")
	}
	lines := observedLines(t, loki, stub)
	if len(lines) != 1 || lines[0]["event"] != "host_dropped" || lines[0]["lastSeenUtc"] != nil || lines[0]["ttlSeconds"] != float64(3600) {
		t.Fatalf("a host never reached in this run must write only its drop, without a last-seen time: %v", lines)
	}
	if _, present := lines[0]["lastSeenUtc"]; !present {
		t.Fatalf("the drop must say the last-seen time is unknown rather than leave it out: %v", lines[0])
	}
}

// The startup restore seeds every host whose transition or presence line is
// inside the restore window, a host an earlier run already dropped included,
// and stamps it as seen at the restart. A host that still does not answer is
// therefore dropped again one host TTL after the restart, without a last-seen
// time, while host_unreachable is not repeated: the restored host has no
// status. Once the host's last line has left the window, a restart seeds
// nothing.
func TestPollDropsASilentHostAgainAfterARestartReseedsIt(t *testing.T) {
	const hid = "42cdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
	t0 := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	down := false
	loki := &lokiPushRecorder{}
	srv := loki.queryRange()
	defer srv.Close()
	lokiURL := srv.URL + "/loki/api/v1/push"
	client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		isDown := down
		mu.Unlock()
		code, body := http.StatusNotFound, "{}"
		switch {
		case r.Method == http.MethodPost:
			if err := loki.push(r); err != nil {
				return nil, err
			}
			code = http.StatusNoContent
		case isDown:
			return nil, fmt.Errorf("connect: connection refused")
		case r.URL.Path == "/runtime/status.json":
			code = http.StatusOK
			body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":"2026-11-01T09:00:00Z","overallStatus":"pass","finishedAt":"2026-11-01T09:55:00Z"}`, hid)
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	absent := filepath.Join(t.TempDir(), "absent.log")
	count := func(event string) (n int, last map[string]any) {
		for _, m := range observedLines(t, loki, hid) {
			if m["event"] == event {
				n, last = n+1, m
			}
		}
		return n, last
	}
	restart := func(at time.Time) *poolState {
		s := newPoolState("default", 8080)
		s.rehydrateFromLoki(lokiURL, "default", defaultRehydrate, at)
		s.rehydrateHostPresenceFromLoki(lokiURL, "default", defaultRehydrate, at)
		return s
	}

	s := newPoolState("default", 8080)
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.60"}
	s.pollOnce(client, absent, lokiURL, t0)
	mu.Lock()
	down = true
	mu.Unlock()
	s.pollOnce(client, absent, lokiURL, t0.Add(5*time.Minute))
	s.pollOnce(client, absent, lokiURL, t0.Add(s.hostTtl+time.Second))
	if n, line := count("host_dropped"); n != 1 || line["lastSeenUtc"] != t0.Format(time.RFC3339) {
		t.Fatalf("the first drop: %d lines, last %v", n, line)
	}

	at := t0.Add(2 * s.hostTtl)
	s = restart(at)
	if _, seeded := s.view().Hosts[hid]; !seeded {
		t.Fatal("the restore did not seed a host whose lines are inside its window")
	}
	s.pollOnce(client, absent, lokiURL, at)
	s.pollOnce(client, absent, lokiURL, at.Add(10*time.Minute))
	s.pollOnce(client, absent, lokiURL, at.Add(s.hostTtl+time.Second))
	n, line := count("host_dropped")
	if n != 2 || line["timestamp"] != at.Add(s.hostTtl+time.Second).Format(time.RFC3339) {
		t.Fatalf("a restart must drop the still silent host again one host TTL later: %d lines, last %v", n, line)
	}
	if v, present := line["lastSeenUtc"]; !present || v != nil {
		t.Fatalf("the repeated drop carries lastSeenUtc %v (present %v), want null", v, present)
	}
	if n, _ := count("host_unreachable"); n != 1 {
		t.Fatalf("one silence wrote %d host_unreachable lines, want 1", n)
	}

	if _, seeded := restart(t0.Add(defaultRehydrate + time.Hour)).view().Hosts[hid]; seeded {
		t.Fatal("a restart seeded a host whose last line is outside the restore window")
	}
}
