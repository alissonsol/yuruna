// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42d98c05-c523-4537-9404-944af592da82

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
)

// Extension hosts are discovered from each host's registration record
// (activeExtensions) -- no ystash-nas mount/scan. These cover the parse + the
// metric emit.

func TestFetchRegistrationActiveExtensions(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/runtime/host.registration.json" {
			_, _ = w.Write([]byte(`{"poolId":"default","activeExtensions":["stash-service"],"extensionTargets":{"stash-service":"http://10.0.0.5"}}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	pid, _, gating, ext, tgt, err := fetchRegistration(client, srv.URL)
	if err != nil {
		t.Fatalf("fetchRegistration: %v", err)
	}
	if pid != "default" {
		t.Errorf("poolID = %q, want default", pid)
	}
	if gating != nil {
		t.Errorf("gating = %v, want nil (none authored)", gating)
	}
	if len(ext) != 1 || ext[0] != "stash-service" {
		t.Errorf("activeExtensions = %v, want [stash-service]", ext)
	}
	if tgt["stash-service"] != "http://10.0.0.5" {
		t.Errorf("extensionTargets[stash-service] = %q, want http://10.0.0.5", tgt["stash-service"])
	}
}

func TestFetchRegistrationNoActiveExtensions(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"poolId":"default"}`))
	}))
	defer srv.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	_, _, _, ext, tgt, err := fetchRegistration(client, srv.URL)
	if err != nil {
		t.Fatalf("fetchRegistration: %v", err)
	}
	if len(ext) != 0 {
		t.Errorf("activeExtensions = %v, want empty (capability-only host runs no extension)", ext)
	}
	if len(tgt) != 0 {
		t.Errorf("extensionTargets = %v, want empty when no extension is advertised", tgt)
	}
}

func TestExtensionMetricFromActiveExtensions(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "42512149e3dc437ca677a40828382528"
	s.view().Hosts[hid] = &hostView{
		HostId:           hid,
		BaseURL:          "http://10.0.0.1:8080",
		ActiveExtensions: []string{"stash-service"},
		ExtensionTargets: map[string]string{"stash-service": "http://10.0.0.5"},
		LastSeenUnixMs:   time.Now().UnixMilli(),
	}
	seedExtensionHealth(s, hid, stashArea, "http://10.0.0.5")

	rec := httptest.NewRecorder()
	s.handleMetrics(rec, metricsRequest())
	body := rec.Body.String()
	// baseUrl, target and goPath ride as labels (string columns carry no field
	// labels); the dashboard hides all three and deep-links Extension -> goPath,
	// which routes through the aggregator so the redirect can hand the service UI
	// a control proof. baseUrl is exported but NOT linked: an extension host that
	// runs no cycles has no status page, so a Host ID hop to /go/host would land
	// on "host not known to the pool" -- that cell's menu opens the extension UI.
	want := "yuruna_pool_host_extension{pool=\"default\",hostId=\"" + hid + "\",hostIdDashed=\"" + dashedHostID(hid) + "\",area=\"stash-service\",baseUrl=\"http://10.0.0.1:8080\",target=\"http://10.0.0.5\",goPath=\"/go/stash?host=" + hid + "&area=stash-service\"} 1"
	if !strings.Contains(body, want) {
		t.Errorf("/metrics missing the extension row.\nwant: %s", want)
	}
}

func TestExtensionMetricAbsentWhenNoActiveExtension(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "42512149e3dc437ca677a40828382528"
	// A host with NO activeExtensions (capability-only) must NOT appear.
	s.view().Hosts[hid] = &hostView{HostId: hid, LastSeenUnixMs: time.Now().UnixMilli()}

	rec := httptest.NewRecorder()
	s.handleMetrics(rec, metricsRequest())
	if strings.Contains(rec.Body.String(), "yuruna_pool_host_extension{") {
		t.Errorf("yuruna_pool_host_extension must be absent when no host runs an extension")
	}
}

// /go/stash 302s to the stash-service VM UI URL the owning host advertised in
// extensionTargets, resolving hostId -> stashBaseUrl server-side (the Extension
// cell's deep-link). The dashboard passes the RAW hostId label, so the undashed id
// keys the view's hosts directly.
func TestGoStashRedirectsToAdvertisedTarget(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "42512149e3dc437ca677a40828382528"
	s.view().Hosts[hid] = &hostView{
		HostId:           hid,
		ExtensionTargets: map[string]string{"stash-service": "http://10.0.0.5"},
		LastSeenUnixMs:   time.Now().UnixMilli(),
	}
	seedExtensionHealth(s, hid, stashArea, "http://10.0.0.5")
	rec := httptest.NewRecorder()
	s.handleGoStash(rec, httptest.NewRequest("GET", "/go/stash?host="+hid+"&pool=default", nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "http://10.0.0.5" {
		t.Errorf("Location = %q, want http://10.0.0.5", loc)
	}
}

// A host present in the view but advertising no stash target degrades to 404 (no
// link), never a redirect to an empty URL.
func TestGoStashUnknownTarget404(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "42512149e3dc437ca677a40828382528"
	s.view().Hosts[hid] = &hostView{HostId: hid, LastSeenUnixMs: time.Now().UnixMilli()}
	rec := httptest.NewRecorder()
	s.handleGoStash(rec, httptest.NewRequest("GET", "/go/stash?host="+hid, nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404 when no stash target advertised", rec.Code)
	}
}

// The pause and runner readings match the host status page's banner: a host that
// has actually stopped is "paused" (code 5) above the last cycle's terminal result,
// and one that is merely ARMED to stop is its own "pausing-*" status rather than a
// plain "running" that would hide the pending stop. Step pause resolves before
// cycle pause, and the current-action sidecar is what separates parked-at-the-
// boundary from still-running-the-step. A verified-dead runner outranks all of it:
// nothing below it describes anything that is still happening.
func TestStatusLabelPaused(t *testing.T) {
	mk := func(reachable bool, st *hostStatus) *hostView {
		return &hostView{Reachable: reachable, Status: st}
	}
	parked := func(hv *hostView) *hostView { hv.StepPauseReached = true; return hv }
	dead := func(hv *hostView) *hostView { hv.RunnerStopped = true; return hv }
	lost := func(hv *hostView) *hostView { hv.RunnerStopped, hv.RunnerLostMidCycle = true, true; return hv }
	fault := func(hv *hostView) *hostView {
		hv.Status.RunnerFault = &runnerFault{FailureClass: "config_gate_failed", Severity: "fatal"}
		return hv
	}
	cases := []struct {
		name      string
		hv        *hostView
		wantLabel string
		wantCode  int
	}{
		{"paused after a pass", mk(true, &hostStatus{OverallStatus: "pass", CyclePaused: true}), "paused", 5},
		{"paused after a fail", mk(true, &hostStatus{OverallStatus: "fail", CyclePaused: true}), "paused", 5},
		{"cycle pause pending mid-cycle", mk(true, &hostStatus{OverallStatus: "running", CyclePaused: true}), "pausing-cycle", 6},
		{"step pause pending mid-step", mk(true, &hostStatus{OverallStatus: "running", StepPaused: true}), "pausing-step", 7},
		{"step pause armed between cycles", mk(true, &hostStatus{OverallStatus: "pass", StepPaused: true}), "pausing-step", 7},
		{"step pause reached is paused", parked(mk(true, &hostStatus{OverallStatus: "running", StepPaused: true})), "paused", 5},
		{"step pause wins over cycle pause", mk(true, &hostStatus{OverallStatus: "running", StepPaused: true, CyclePaused: true}), "pausing-step", 7},
		{"not paused keeps the terminal status", mk(true, &hostStatus{OverallStatus: "pass", CyclePaused: false}), "pass", 2},
		{"unreachable is never paused", mk(false, &hostStatus{OverallStatus: "pass", CyclePaused: true}), "unreachable", 0},
		{"stopped runner outranks a stale pass", dead(mk(true, &hostStatus{OverallStatus: "pass"})), "stopped", 8},
		{"stopped runner outranks an armed pause", dead(mk(true, &hostStatus{OverallStatus: "running", StepPaused: true})), "stopped", 8},
		{"stopped runner with no cycle data", dead(&hostView{Reachable: true}), "stopped", 8},
		{"unreachable outranks stopped", dead(mk(false, &hostStatus{OverallStatus: "pass"})), "unreachable", 0},
		{"preflight failure above passing cycle", fault(mk(true, &hostStatus{OverallStatus: "pass"})), "preflight-failed", 9},
		{"preflight failure before first cycle", fault(mk(true, &hostStatus{})), "preflight-failed", 9},
		{"preflight failure above armed pause", fault(mk(true, &hostStatus{OverallStatus: "pass", CyclePaused: true})), "preflight-failed", 9},
		{"cycle failure stays red", mk(true, &hostStatus{OverallStatus: "fail"}), "fail", 3},
		{"runner crash stays red", mk(true, &hostStatus{OverallStatus: "pass", RunnerFault: &runnerFault{FailureClass: "preamble_stall"}}), "fail", 3},
		{"framework update is preflight", mk(true, &hostStatus{OverallStatus: "pass", RunnerFault: &runnerFault{FailureClass: "bootstrap_sync", Stage: "FrameworkPull"}}), "preflight-failed", 9},
		{"guest bootstrap stays red", mk(true, &hostStatus{OverallStatus: "pass", RunnerFault: &runnerFault{FailureClass: "bootstrap_sync", Stage: "GuestBootstrap"}}), "fail", 3},
		{"unknown bootstrap phase stays red", mk(true, &hostStatus{OverallStatus: "pass", RunnerFault: &runnerFault{FailureClass: "bootstrap_sync"}}), "fail", 3},
		{"stopped above attempt failure", dead(fault(mk(true, &hostStatus{OverallStatus: "pass"}))), "stopped", 8},
		{"unreachable above attempt failure", fault(mk(false, &hostStatus{OverallStatus: "pass"})), "unreachable", 0},
		{"lost runner outranks the cycle it was running", lost(mk(true, &hostStatus{OverallStatus: "running"})), "lost", 10},
		{"lost runner outranks an armed pause", lost(mk(true, &hostStatus{OverallStatus: "running", CyclePaused: true})), "lost", 10},
		{"lost runner above attempt failure", lost(fault(mk(true, &hostStatus{OverallStatus: "pass"}))), "lost", 10},
		{"unreachable outranks lost", lost(mk(false, &hostStatus{OverallStatus: "running"})), "unreachable", 0},
		{"a lost reading needs a stopped runner", func() *hostView {
			hv := mk(true, &hostStatus{OverallStatus: "running"})
			hv.RunnerLostMidCycle = true
			return hv
		}(), "running", 1},
	}
	for _, c := range cases {
		if got := c.hv.StatusLabel(); got != c.wantLabel {
			t.Errorf("%s: StatusLabel = %q, want %q", c.name, got, c.wantLabel)
		}
		if got := c.hv.StatusCode(); got != c.wantCode {
			t.Errorf("%s: StatusCode = %d, want %d", c.name, got, c.wantCode)
		}
	}
}

// The current-action sidecar is read for exactly one bit: is the runner sitting at
// a step boundary. A sidecar that has not been written this cycle answers 404,
// which is a definite "not parked" -- so an armed host between sequences reports
// "pausing" instead of failing the read and inheriting whatever it last saw.
func TestFetchCurrentActionStepPause(t *testing.T) {
	cases := []struct {
		name string
		line string
		code string
		want bool
	}{
		{"parked at the boundary", "[3/9] awaiting resume", stepPauseCode, true},
		{"still running the step", "[3/9] takeScreenshot: capture the desktop", "", false},
		{"no sidecar written yet", "", "", false}, // 404
	}
	for _, c := range cases {
		body := ""
		if c.line != "" {
			body = `{"guestKey":"g1","vmName":"vm1","line":"` + c.line + `","code":"` + c.code + `","updatedAt":"2026-08-03T00:00:00Z"}`
		}
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/runtime/current-action.json" || body == "" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
		}))
		got, err := hostpoll.FetchCurrentAction(srv.Client(), srv.URL)
		srv.Close()
		if err != nil {
			t.Errorf("%s: unexpected error: %v", c.name, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s: fetchCurrentAction = %v, want %v", c.name, got, c.want)
		}
	}
}

// The pause is stated in a code, so the sentence beside it is ordinary prose:
// it can be reworded, or written in the operator's own language, without this
// service losing sight of a parked runner. A sentence cannot establish state.
func TestFetchCurrentActionPauseCode(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{"code says parked, sentence is translated",
			`{"line":"Pausado, aguardando retomada.","code":"sequence_paused_waiting_resume"}`, true},
		{"code says parked without display prose",
			`{"code":"sequence_paused_waiting_resume"}`, true},
		{"code says parked, display prose has a different type",
			`{"line":{"ignored":"display detail"},"code":"sequence_paused_waiting_resume"}`, true},
		{"code says running, stale sentence must not override it",
			`{"line":"[3/9] Paused (waiting for resume)","code":"step_running"}`, false},
		{"no code: display prose does not establish state",
			`{"line":"[3/9] Paused (waiting for resume)"}`, false},
		{"empty code: display prose does not establish state",
			`{"line":"[3/9] Paused (waiting for resume)","code":""}`, false},
		{"unknown code: display prose does not establish state",
			`{"line":"[3/9] Paused (waiting for resume)","code":"unknown_state"}`, false},
		{"no code and not parked", `{"line":"[3/9] takeScreenshot"}`, false},
	}
	for _, c := range cases {
		body := c.body
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/runtime/current-action.json" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
		}))
		got, err := hostpoll.FetchCurrentAction(srv.Client(), srv.URL)
		srv.Close()
		if err != nil {
			t.Errorf("%s: unexpected error: %v", c.name, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s: fetchCurrentAction = %v, want %v", c.name, got, c.want)
		}
	}
}

// Only an explicit running:false is evidence of a stopped runner. A host that
// predates the route (404) or answers without the field cannot say, and must not be
// reported stopped -- otherwise a route that moved would blank every real status in
// the pool at once. A stopped runner is lost mid-cycle only when its state still
// reads in-cycle AND its pid file was left behind: an operator's Ctrl+C stops a
// running cycle with the state at in-cycle too, but removes the pid file.
func TestFetchRunnerStopped(t *testing.T) {
	cases := []struct {
		name     string
		body     string // "" -> 404
		want     bool
		wantLost bool
	}{
		{"runner alive", `{"running":true,"pid":4242,"liveness":"ok"}`, false, false},
		{"runner verified dead", `{"running":false,"pid":null,"liveness":"idle"}`, true, false},
		{"answer without the field", `{"pid":null,"liveness":"unknown"}`, false, false},
		{"route absent on an older build", "", false, false},
		{"runner died mid-cycle", `{"running":false,"pid":11128,"liveness":"idle","runnerState":"in-cycle"}`, true, true},
		{"operator stopped a running cycle", `{"running":false,"pid":null,"liveness":"idle","runnerState":"in-cycle"}`, true, false},
		{"runner died between cycles", `{"running":false,"pid":4242,"liveness":"idle","runnerState":"idle"}`, true, false},
		{"runner died in its pause", `{"running":false,"pid":4242,"liveness":"idle","runnerState":"paused"}`, true, false},
		{"answer without a runner state", `{"running":false,"pid":4242,"liveness":"idle"}`, true, false},
		{"live runner mid-cycle is not lost", `{"running":true,"pid":4242,"liveness":"ok","runnerState":"in-cycle"}`, false, false},
	}
	for _, c := range cases {
		body := c.body
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/control/runner-status" || body == "" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
		}))
		got, err := hostpoll.FetchRunnerStopped(srv.Client(), srv.URL)
		srv.Close()
		if err != nil {
			t.Errorf("%s: unexpected error: %v", c.name, err)
			continue
		}
		if got.Stopped != c.want || got.LostMidCycle != c.wantLost {
			t.Errorf("%s: fetchRunnerStopped = (%v, %v), want (%v, %v)", c.name, got.Stopped, got.LostMidCycle, c.want, c.wantLost)
		}
	}
}

// A lost runner's lastExit says how it ended, and the pool records it on the
// runner_lost line. The report is decoded on its own: one this collector cannot
// read is dropped, and the stopped and lost verdicts stand without it.
func TestFetchRunnerStoppedDecodesTheExitReport(t *testing.T) {
	const lost = `{"running":false,"pid":4242,"liveness":"idle","runnerState":"in-cycle","lastExit":%s}`
	sighup := `{"pid":4242,"startedUtc":"2026-11-09T02:23:25.1234567Z","recordedUtc":"2026-11-09T02:23:26.0000000Z","sshSession":false,"terminalProgram":"Apple_Terminal","multiplexer":null,"parents":["zsh[1432]","login[1430]"],"hostBootUtc":"2026-10-27T15:34:30.0000000Z","signal":"SIGHUP","signalAtUtc":"2026-11-11T23:18:46.8000000Z","hostRestarted":false}`
	uncaught := `{"pid":4242,"startedUtc":"2026-11-09T02:23:25.1234567Z","recordedUtc":"2026-11-09T02:23:26.0000000Z","sshSession":true,"terminalProgram":null,"multiplexer":"tmux","parents":[],"hostBootUtc":null,"signal":null,"signalAtUtc":null,"hostRestarted":null}`
	for _, c := range []struct {
		name, lastExit string
		want           *hostpoll.RunnerExit
	}{
		{"signal caught", sighup, &hostpoll.RunnerExit{Pid: 4242, StartedUtc: "2026-11-09T02:23:25.1234567Z",
			Signal: ptr("SIGHUP"), SignalAtUtc: ptr("2026-11-11T23:18:46.8000000Z"), HostRestarted: ptr(false), TerminalProgram: ptr("Apple_Terminal")}},
		{"no signal caught and boot unknown", uncaught, &hostpoll.RunnerExit{Pid: 4242, StartedUtc: "2026-11-09T02:23:25.1234567Z", SSHSession: true}},
		{"no session record", `null`, nil},
		{"unreadable report", `{"pid":"4242","signal":7}`, nil},
		{"report of no process", `{"startedUtc":"2026-11-09T02:23:25Z"}`, nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprintf(w, lost, c.lastExit)
			}))
			defer srv.Close()
			got, err := hostpoll.FetchRunnerStopped(srv.Client(), srv.URL)
			if err != nil {
				t.Fatal(err)
			}
			if !got.Stopped || !got.LostMidCycle || got.Pid != 4242 {
				t.Fatalf("verdicts = %+v, want a lost runner 4242 whatever its report says", got)
			}
			if !reflect.DeepEqual(got.LastExit, c.want) {
				t.Fatalf("lastExit = %s, want %s", describeExit(got.LastExit), describeExit(c.want))
			}
		})
	}
}

func ptr[T any](v T) *T { return &v }

func describeExit(x *hostpoll.RunnerExit) string {
	b, _ := json.Marshal(x)
	return string(b)
}
