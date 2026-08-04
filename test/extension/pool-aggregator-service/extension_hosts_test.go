// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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
	s.hosts[hid] = &hostView{
		HostId:           hid,
		BaseURL:          "http://10.0.0.1:8080",
		ActiveExtensions: []string{"stash-service"},
		ExtensionTargets: map[string]string{"stash-service": "http://10.0.0.5"},
		LastSeenUnixMs:   time.Now().UnixMilli(),
	}
	seedExtensionHealth(s, hid, stashArea, "http://10.0.0.5")

	rec := httptest.NewRecorder()
	s.handleMetrics(rec, httptest.NewRequest("GET", "/metrics", nil))
	body := rec.Body.String()
	// baseUrl + target ride as labels (string columns carry no field labels); the
	// dashboard hides both columns and deep-links Extension -> target. baseUrl is
	// exported but NOT linked: an extension host that runs no cycles has no status
	// page, so a Host ID link would land on /go/host's "host not known to the pool".
	want := "yuruna_pool_host_extension{pool=\"default\",hostId=\"" + hid + "\",area=\"stash-service\",baseUrl=\"http://10.0.0.1:8080\",target=\"http://10.0.0.5\"} 1"
	if !strings.Contains(body, want) {
		t.Errorf("/metrics missing the extension row.\nwant: %s", want)
	}
}

func TestExtensionMetricAbsentWhenNoActiveExtension(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "42512149e3dc437ca677a40828382528"
	// A host with NO activeExtensions (capability-only) must NOT appear.
	s.hosts[hid] = &hostView{HostId: hid, LastSeenUnixMs: time.Now().UnixMilli()}

	rec := httptest.NewRecorder()
	s.handleMetrics(rec, httptest.NewRequest("GET", "/metrics", nil))
	if strings.Contains(rec.Body.String(), "yuruna_pool_host_extension{") {
		t.Errorf("yuruna_pool_host_extension must be absent when no host runs an extension")
	}
}

// /go/stash 302s to the stash-service VM UI URL the owning host advertised in
// extensionTargets, resolving hostId -> stashBaseUrl server-side (the Extension
// cell's deep-link). The dashboard passes the RAW hostId label, so the undashed id
// keys s.hosts directly.
func TestGoStashRedirectsToAdvertisedTarget(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "42512149e3dc437ca677a40828382528"
	s.hosts[hid] = &hostView{
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
	s.hosts[hid] = &hostView{HostId: hid, LastSeenUnixMs: time.Now().UnixMilli()}
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
	}
	for _, c := range cases {
		if got := c.hv.statusLabel(); got != c.wantLabel {
			t.Errorf("%s: statusLabel = %q, want %q", c.name, got, c.wantLabel)
		}
		if got := c.hv.statusCode(); got != c.wantCode {
			t.Errorf("%s: statusCode = %d, want %d", c.name, got, c.wantCode)
		}
	}
}

// The current-action sidecar is read for exactly one bit: is the runner sitting at
// a step boundary. A sidecar that has not been written this cycle answers 404,
// which is a definite "not parked" -- so an armed host between sequences reports
// "will pause" instead of failing the read and inheriting whatever it last saw.
func TestFetchCurrentActionStepPause(t *testing.T) {
	cases := []struct {
		name string
		line string
		want bool
	}{
		{"parked at the boundary", "[3/9] Paused (waiting for resume)", true},
		{"still running the step", "[3/9] takeScreenshot: capture the desktop", false},
		{"no sidecar written yet", "", false}, // 404
	}
	for _, c := range cases {
		body := ""
		if c.line != "" {
			body = `{"guestKey":"g1","vmName":"vm1","line":"` + c.line + `","updatedAt":"2026-08-03T00:00:00Z"}`
		}
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/runtime/current-action.json" || body == "" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
		}))
		got, err := fetchCurrentAction(srv.Client(), srv.URL)
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
// the pool at once.
func TestFetchRunnerStopped(t *testing.T) {
	cases := []struct {
		name string
		body string // "" -> 404
		want bool
	}{
		{"runner alive", `{"running":true,"pid":4242,"liveness":"ok"}`, false},
		{"runner verified dead", `{"running":false,"pid":null,"liveness":"idle"}`, true},
		{"answer without the field", `{"pid":null,"liveness":"unknown"}`, false},
		{"route absent on an older build", "", false},
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
		got, err := fetchRunnerStopped(srv.Client(), srv.URL)
		srv.Close()
		if err != nil {
			t.Errorf("%s: unexpected error: %v", c.name, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s: fetchRunnerStopped = %v, want %v", c.name, got, c.want)
		}
	}
}
