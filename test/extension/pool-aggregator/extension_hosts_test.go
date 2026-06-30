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

// Extension hosts are now discovered from each host's registration record
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
	pid, gating, ext, tgt, err := fetchRegistration(client, srv.URL)
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
	_, _, ext, tgt, err := fetchRegistration(client, srv.URL)
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

	rec := httptest.NewRecorder()
	s.handleMetrics(rec, httptest.NewRequest("GET", "/metrics", nil))
	body := rec.Body.String()
	// baseUrl + target ride as labels so the Grafana table can deep-link each cell
	// directly (string columns carry no field labels); the dashboard hides these
	// columns and links Host ID -> baseUrl and Extension -> target.
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

// /go/stash 302s to the stash VM UI URL the owning host advertised in
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

// A paused host reports its own "paused" status (code 5) above the last cycle's
// terminal result, matching the host status page's effective-pause badge: paused
// when cyclePaused is set and the host is not mid-cycle; a pause-pending running
// cycle stays "running" until it stops.
func TestStatusLabelPaused(t *testing.T) {
	mk := func(reachable bool, st *hostStatus) *hostView {
		return &hostView{Reachable: reachable, Status: st}
	}
	cases := []struct {
		name      string
		hv        *hostView
		wantLabel string
		wantCode  int
	}{
		{"paused after a pass", mk(true, &hostStatus{OverallStatus: "pass", CyclePaused: true}), "paused", 5},
		{"paused after a fail", mk(true, &hostStatus{OverallStatus: "fail", CyclePaused: true}), "paused", 5},
		{"pause pending mid-cycle stays running", mk(true, &hostStatus{OverallStatus: "running", CyclePaused: true}), "running", 1},
		{"not paused keeps the terminal status", mk(true, &hostStatus{OverallStatus: "pass", CyclePaused: false}), "pass", 2},
		{"unreachable is never paused", mk(false, &hostStatus{OverallStatus: "pass", CyclePaused: true}), "unreachable", 0},
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
