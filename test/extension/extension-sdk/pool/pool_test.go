// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package pool

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeAggregator serves the three routes this client reads, with a hit counter
// so caching and fallback behavior are observable.
type fakeAggregator struct {
	srv        *httptest.Server
	statusHits atomic.Int64
	statusBody string
	extBody    string
	extStatus  int
}

func newFakeAggregator(t *testing.T) *fakeAggregator {
	t.Helper()
	a := &fakeAggregator{extStatus: http.StatusOK}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /api/v1/pool-status", func(w http.ResponseWriter, _ *http.Request) {
		a.statusHits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(a.statusBody))
	})
	mux.HandleFunc("GET /api/v1/extension-hosts", func(w http.ResponseWriter, r *http.Request) {
		if a.extStatus != http.StatusOK {
			http.Error(w, "no live host serves this area", a.extStatus)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Query().Get("area") != "" {
			_, _ = w.Write([]byte(a.extBody))
			return
		}
		_, _ = w.Write([]byte(`{"pool":"default","areas":{"stash-service":` + a.extBody + `},"services":[` + a.extBody + `]}`))
	})
	a.srv = httptest.NewServer(mux)
	t.Cleanup(a.srv.Close)
	return a
}

const twoHostStatus = `{
  "pool": "default",
  "lastPollUtc": "2026-08-03T12:00:00Z",
  "hosts": [
    {"hostId":"aaa","baseUrl":"http://10.0.0.5:8080/","control":"ready","reachable":true,
     "stashBaseUrl":"http://10.0.0.9",
     "extensionTargets":{"stash-service":"http://10.0.0.9","pool-control-service":"http://10.0.0.11"},
     "status":{"hostId":"aaa","host":"host.windows.hyper-v","overallStatus":"PASS"}},
    {"hostId":"bbb","baseUrl":"http://10.0.0.6:8080","control":"none","reachable":false}
  ]
}`

func TestStatusDecodesTheHostView(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = twoHostStatus
	c := New(Options{BaseURL: agg.srv.URL, CacheTTL: NoCache})

	s, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if s.Pool != "default" || len(s.Hosts) != 2 {
		t.Fatalf("status = %+v, want pool default with 2 hosts", s)
	}
	h, ok := s.Host("aaa")
	if !ok {
		t.Fatal("host aaa missing from the snapshot")
	}
	if h.Control != ControlReady {
		t.Errorf("control = %q, want %q", h.Control, ControlReady)
	}
	if h.HostType() != "windows.hyper-v" {
		t.Errorf("hostType = %q, want windows.hyper-v", h.HostType())
	}
	// The trailing slash is trimmed so a caller composing "<base>/path" cannot
	// produce a double slash.
	if h.BaseURL != "http://10.0.0.5:8080" {
		t.Errorf("baseUrl = %q, want the trimmed form", h.BaseURL)
	}
	if missing, _ := s.Host("zzz"); missing.HostID != "" {
		t.Errorf("an unknown hostId resolved to %+v", missing)
	}
	// A host the aggregator could not reach has no status, so its type is not
	// known -- reported as unknown rather than guessed at.
	types, unknown := s.HostTypes()
	if len(types) != 1 || types[0] != "windows.hyper-v" || unknown != 1 {
		t.Errorf("HostTypes = %v (unknown %d), want [windows.hyper-v] with 1 unknown", types, unknown)
	}
}

// Every URL-valued field is sanitized on the way out: these reads do not verify
// who answered, and a UI renders what it gets as a link.
func TestPoisonedURLFieldsAreDropped(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = `{"hosts":[{"hostId":"aaa",
	  "baseUrl":"javascript:alert(1)",
	  "stashBaseUrl":"data:text/html,<script>",
	  "extensionTargets":{"stash-service":"javascript:alert(2)","pool-control-service":"http://10.0.0.11"}}]}`
	c := New(Options{BaseURL: agg.srv.URL, CacheTTL: NoCache})

	s, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	h := s.Hosts[0]
	if h.BaseURL != "" {
		t.Errorf("baseUrl = %q, want it dropped", h.BaseURL)
	}
	if h.StashBaseURL != "" {
		t.Errorf("stashBaseUrl = %q, want it dropped", h.StashBaseURL)
	}
	if _, present := h.ExtensionTargets["stash-service"]; present {
		t.Error("a javascript: extension target survived into the map")
	}
	if h.ExtensionTargets["pool-control-service"] != "http://10.0.0.11" {
		t.Errorf("a legitimate target was dropped: %v", h.ExtensionTargets)
	}
}

func TestSanitizeBaseURL(t *testing.T) {
	cases := map[string]string{
		"http://10.0.0.9":     "http://10.0.0.9",
		"https://host:9400/":  "https://host:9400",
		"  http://host/  ":    "http://host",
		"javascript:alert(1)": "",
		"data:text/html,<b>":  "",
		"//10.0.0.9":          "",
		"not a url":           "",
		"":                    "",
		"ftp://10.0.0.9":      "",
	}
	for in, want := range cases {
		if got := SanitizeBaseURL(in); got != want {
			t.Errorf("SanitizeBaseURL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStatusIsCachedForTheConfiguredWindow(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = twoHostStatus
	c := New(Options{BaseURL: agg.srv.URL, CacheTTL: time.Minute})

	for i := 0; i < 3; i++ {
		if _, err := c.Status(context.Background()); err != nil {
			t.Fatalf("Status %d: %v", i, err)
		}
	}
	if got := agg.statusHits.Load(); got != 1 {
		t.Fatalf("3 reads inside the window made %d requests, want 1", got)
	}

	fresh := New(Options{BaseURL: agg.srv.URL, CacheTTL: NoCache})
	for i := 0; i < 3; i++ {
		if _, err := fresh.Status(context.Background()); err != nil {
			t.Fatalf("uncached Status %d: %v", i, err)
		}
	}
	if got := agg.statusHits.Load(); got != 4 {
		t.Fatalf("total requests = %d, want 4 (1 cached client + 3 uncached)", got)
	}
}

func TestHandoverHostAuthenticatesAndInvalidatesStatusCache(t *testing.T) {
	var handed atomic.Bool
	var posts atomic.Int64
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/pool-status", func(w http.ResponseWriter, _ *http.Request) {
		if handed.Load() {
			_, _ = w.Write([]byte(`{"hosts":[{"hostId":"new"}]}`))
		} else {
			_, _ = w.Write([]byte(`{"hosts":[{"hostId":"old"},{"hostId":"new"}]}`))
		}
	})
	mux.HandleFunc("POST /api/v1/handover-host", func(w http.ResponseWriter, r *http.Request) {
		posts.Add(1)
		if r.Header.Get("Authorization") != "Bearer secret" {
			t.Error("handover omitted the internal bearer")
		}
		handed.Store(true)
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	c := New(Options{BaseURL: srv.URL, CacheTTL: time.Minute})
	before, err := c.Status(context.Background())
	if err != nil || len(before.Hosts) != 2 {
		t.Fatalf("before = %+v, %v", before, err)
	}
	if err := c.HandoverHost(context.Background(), "old", "new", "secret"); err != nil {
		t.Fatal(err)
	}
	after, err := c.Status(context.Background())
	if err != nil || len(after.Hosts) != 1 || after.Hosts[0].HostID != "new" || posts.Load() != 1 {
		t.Fatalf("cached status survived handover: %+v, %v", after, err)
	}
}

func TestHandoverHostDoesNotDowngradeBearerAfterTLSFailure(t *testing.T) {
	var posts atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		posts.Add(1)
	}))
	defer srv.Close()
	c := New(Options{BaseURL: strings.Replace(srv.URL, "http://", "https://", 1)})
	if err := c.HandoverHost(context.Background(), "old", "new", "secret"); err == nil {
		t.Fatal("TLS failure was accepted")
	}
	if posts.Load() != 0 {
		t.Fatal("bearer request fell back to plaintext HTTP")
	}
}

func TestExtensionHostAnswersOneAreaAndDistinguishesNotServed(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.extBody = `{"area":"stash-service","host":"10.0.0.9","target":"http://10.0.0.9",
	  "hostId":"aaa","source":"announce","healthy":true}`
	c := New(Options{BaseURL: agg.srv.URL, CacheTTL: NoCache})

	e, err := c.ExtensionHost(context.Background(), "stash-service")
	if err != nil {
		t.Fatalf("ExtensionHost: %v", err)
	}
	if e.Host != "10.0.0.9" || e.Target != "http://10.0.0.9" || e.Source != "announce" {
		t.Fatalf("entry = %+v", e)
	}

	all, err := c.ExtensionHosts(context.Background())
	if err != nil {
		t.Fatalf("ExtensionHosts: %v", err)
	}
	if len(all.Areas) != 1 || len(all.Services) != 1 {
		t.Fatalf("registry = %+v, want one area and one service", all)
	}

	agg.extStatus = http.StatusNotFound
	if _, err := c.ExtensionHost(context.Background(), "stash-service"); !errors.Is(err, ErrAreaNotServed) {
		t.Fatalf("404 gave %v, want ErrAreaNotServed so a caller can tell it from a transport failure", err)
	}
}

// A pool-less host is a normal state, not a fault: it is reported rather than
// guessed around, and no call panics or blocks.
func TestAnUnconfiguredClientReportsItRatherThanGuessing(t *testing.T) {
	c := New(Options{})
	if c.Configured() {
		t.Fatal("a client with no base URL reports itself configured")
	}
	if _, err := c.Status(context.Background()); !errors.Is(err, ErrNotConfigured) {
		t.Errorf("Status = %v, want ErrNotConfigured", err)
	}
	if _, err := c.ExtensionHost(context.Background(), "stash-service"); !errors.Is(err, ErrNotConfigured) {
		t.Errorf("ExtensionHost = %v, want ErrNotConfigured", err)
	}
	if err := c.Healthz(context.Background()); !errors.Is(err, ErrNotConfigured) {
		t.Errorf("Healthz = %v, want ErrNotConfigured", err)
	}
	if got := c.ExtensionTarget(context.Background(), "aaa", "stash-service"); got != "" {
		t.Errorf("ExtensionTarget = %q, want empty", got)
	}
}

// An aggregator with no TLS leaf answers :9400 in the clear, so an https base
// falls back on a TRANSPORT failure.
func TestHTTPSFallsBackToHTTP(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = twoHostStatus
	httpsBase := "https://" + agg.srv.Listener.Addr().String()
	c := New(Options{BaseURL: httpsBase, CacheTTL: NoCache})

	s, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status over the http downgrade: %v", err)
	}
	if len(s.Hosts) != 2 {
		t.Fatalf("hosts = %d, want 2", len(s.Hosts))
	}
}

// A protocol answer is authoritative: the client must not re-deliver the request
// to the other scheme over one.
func TestAProtocolAnswerIsNotRetried(t *testing.T) {
	var hits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	c := New(Options{BaseURL: "https://" + srv.Listener.Addr().String(), CacheTTL: NoCache})
	if _, err := c.Status(context.Background()); err == nil {
		t.Fatal("a 500 was not surfaced as an error")
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("server hit %d times, want 1", got)
	}
}

func TestExtensionTargetResolvesThroughTheSnapshot(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = twoHostStatus
	c := New(Options{BaseURL: agg.srv.URL})

	if got := c.ExtensionTarget(context.Background(), "aaa", "stash-service"); got != "http://10.0.0.9" {
		t.Errorf("stash target = %q, want http://10.0.0.9", got)
	}
	if got := c.ExtensionTarget(context.Background(), "aaa", "pool-control-service"); got != "http://10.0.0.11" {
		t.Errorf("pool-control target = %q, want http://10.0.0.11", got)
	}
	if got := c.ExtensionTarget(context.Background(), "bbb", "stash-service"); got != "" {
		t.Errorf("a host advertising nothing resolved to %q", got)
	}
	if got := c.ExtensionTarget(context.Background(), "zzz", "stash-service"); got != "" {
		t.Errorf("an unknown host resolved to %q", got)
	}
}

func TestHealthzAndGetReachTheAggregator(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = twoHostStatus
	c := New(Options{BaseURL: agg.srv.URL, CacheTTL: NoCache})

	if err := c.Healthz(context.Background()); err != nil {
		t.Fatalf("Healthz: %v", err)
	}
	var raw struct {
		Pool string `json:"pool"`
	}
	if err := c.Get(context.Background(), "api/v1/pool-status", &raw); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if raw.Pool != "default" {
		t.Errorf("Get decoded pool = %q, want default", raw.Pool)
	}
	if err := c.GetURL(context.Background(), agg.srv.URL+"/api/v1/pool-status", &raw); err != nil {
		t.Fatalf("GetURL: %v", err)
	}
}

// --- REGION: Refresh capability
// An aggregator that predates the refresh field must never make a host look
// remotely refreshable: the zero value decodes, normalizes to "never
// observed", and is not usable.
func TestAnOldAggregatorPayloadIsNotRemoteUsable(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = twoHostStatus
	c := New(Options{BaseURL: agg.srv.URL, CacheTTL: NoCache})
	s, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	for _, h := range s.Hosts {
		if h.Refresh.RemoteUsable() {
			t.Errorf("%s: a payload without refresh reads as usable: %+v", h.HostID, h.Refresh)
		}
		if h.Refresh != UnobservedRefresh() {
			t.Errorf("%s: refresh = %+v, want the unobserved value", h.HostID, h.Refresh)
		}
	}
}

// A capability the aggregator did carry survives the decode unchanged, and the
// Control string keeps its old shape beside it.
func TestANewPayloadRoundTripsTheRefreshCapability(t *testing.T) {
	agg := newFakeAggregator(t)
	agg.statusBody = `{"pool":"default","hosts":[{"hostId":"aaa","control":"ready",
	  "refresh":{"protocol":1,"availability":"available","ceiling":"start-if-stopped","remote":"provisioned","state":"idle","observedUnixMs":1900000000000,"ageSeconds":12}}]}`
	c := New(Options{BaseURL: agg.srv.URL, CacheTTL: NoCache})
	s, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	h, _ := s.Host("aaa")
	want := HostRefresh{Protocol: 1, Availability: RefreshAvailable, Ceiling: RungStartIfStopped, Remote: RefreshRemoteProvisioned,
		State: RefreshStateIdle, ObservedUnixMs: 1900000000000, AgeSeconds: 12}
	if h.Refresh != want {
		t.Fatalf("refresh = %+v, want %+v", h.Refresh, want)
	}
	if !h.Refresh.RemoteUsable() {
		t.Fatal("a provisioned, available protocol-1 capability must be usable")
	}
	if h.Control != ControlReady {
		t.Fatalf("control = %q; the refresh field must not disturb the control string", h.Control)
	}
	body, err := json.Marshal(h.Refresh)
	if err != nil {
		t.Fatal(err)
	}
	var back HostRefresh
	if err := json.Unmarshal(body, &back); err != nil || back != want {
		t.Fatalf("re-encode round trip = %+v (%v), want %+v", back, err, want)
	}
}

func TestUnobservedRefreshIsUnavailable(t *testing.T) {
	u := UnobservedRefresh()
	if u.Availability != RefreshUnavailable || u.Reason != RefreshReasonNeverObserved ||
		u.Remote != RefreshRemoteUnknown || u.State != RefreshStateUnknown || u.RemoteUsable() {
		t.Fatalf("unobserved = %+v", u)
	}
}

// Every value reaches the pool over unauthenticated reads, so each field is
// clamped to its vocabulary and any doubt reads as unavailable.
func TestNormalizedClampsEveryField(t *testing.T) {
	ok := HostRefresh{Protocol: 1, Availability: RefreshAvailable, Ceiling: RungReclaim, Remote: RefreshRemoteProvisioned, State: RefreshStateIdle}
	cases := []struct {
		name    string
		in      HostRefresh
		avail   string
		reason  string
		ceiling string
		remote  string
		state   string
		usable  bool
	}{
		{"valid", ok, RefreshAvailable, "", RungReclaim, RefreshRemoteProvisioned, RefreshStateIdle, true},
		{"protocol 2", with(ok, func(r *HostRefresh) { r.Protocol = 2 }), RefreshUnavailable, RefreshReasonProtocolUnsupported, RungReclaim, RefreshRemoteProvisioned, RefreshStateIdle, false},
		{"protocol 0", with(ok, func(r *HostRefresh) { r.Protocol = 0 }), RefreshUnavailable, RefreshReasonProtocolUnsupported, RungReclaim, RefreshRemoteProvisioned, RefreshStateIdle, false},
		{"unknown availability", with(ok, func(r *HostRefresh) { r.Availability = "maybe" }), RefreshUnavailable, RefreshReasonCapabilityMalformed, RungReclaim, RefreshRemoteProvisioned, RefreshStateIdle, false},
		{"available without ceiling", with(ok, func(r *HostRefresh) { r.Ceiling = "" }), RefreshUnavailable, RefreshReasonCapabilityMalformed, "", RefreshRemoteProvisioned, RefreshStateIdle, false},
		{"ceiling not a rung", with(ok, func(r *HostRefresh) { r.Ceiling = "rm -rf" }), RefreshUnavailable, RefreshReasonCapabilityMalformed, "", RefreshRemoteProvisioned, RefreshStateIdle, false},
		{"reason out of shape", with(ok, func(r *HostRefresh) { r.Availability, r.Reason = RefreshUnavailable, "Has Spaces" }), RefreshUnavailable, RefreshReasonCapabilityMalformed, RungReclaim, RefreshRemoteProvisioned, RefreshStateIdle, false},
		{"remote unknown word", with(ok, func(r *HostRefresh) { r.Remote = "yes" }), RefreshAvailable, "", RungReclaim, RefreshRemoteUnknown, RefreshStateIdle, false},
		{"state unknown word", with(ok, func(r *HostRefresh) { r.State = "busy" }), RefreshAvailable, "", RungReclaim, RefreshRemoteProvisioned, RefreshStateUnknown, true},
		{"unavailable keeps its reason", with(ok, func(r *HostRefresh) { r.Availability, r.Reason = RefreshUnavailable, "no_qualified_rung" }), RefreshUnavailable, "no_qualified_rung", RungReclaim, RefreshRemoteProvisioned, RefreshStateIdle, false},
	}
	for _, c := range cases {
		got := c.in.Normalized()
		if got.Availability != c.avail || got.Reason != c.reason || got.Ceiling != c.ceiling || got.Remote != c.remote || got.State != c.state {
			t.Errorf("%s: normalized = %+v", c.name, got)
		}
		if got.RemoteUsable() != c.usable {
			t.Errorf("%s: usable = %v, want %v", c.name, got.RemoteUsable(), c.usable)
		}
	}
	neg := with(ok, func(r *HostRefresh) { r.ObservedUnixMs, r.AgeSeconds = -5, -7 }).Normalized()
	if neg.ObservedUnixMs != 0 || neg.AgeSeconds != 0 {
		t.Errorf("negative instants must clamp to zero: %+v", neg)
	}
}

func with(r HostRefresh, f func(*HostRefresh)) HostRefresh {
	f(&r)
	return r
}

// The ladder is eight rungs in Order, the constants spell the same names, and
// the exported list is a copy nobody can reorder for everyone else.
func TestRefreshRungNamesAreTheOrderedLadder(t *testing.T) {
	want := []string{RungProbe, RungReclaim, RungStartIfStopped, RungRestartIfHung, RungRestartBroker, RungReapplySettings, RungReinstall, RungReboot}
	got := RefreshRungNames()
	if len(got) != len(want) {
		t.Fatalf("%d rungs, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("rung %d = %q, want %q", i, got[i], want[i])
		}
		if order, ok := RefreshRungOrder(want[i]); !ok || order != i {
			t.Fatalf("RefreshRungOrder(%q) = %d,%v, want %d", want[i], order, ok, i)
		}
	}
	got[0] = "tampered"
	if RefreshRungNames()[0] != RungProbe {
		t.Fatal("RefreshRungNames exposed its backing array")
	}
	if _, ok := RefreshRungOrder("Probe"); ok {
		t.Fatal("rung names are case-sensitive vocabulary")
	}
}

func TestAuthenticatedOperationsRejectMissingTokenBeforeRequest(t *testing.T) {
	var requests atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	client := New(Options{BaseURL: srv.URL})
	for name, operation := range map[string]func() error{
		"handover": func() error { return client.HandoverHost(context.Background(), "old", "new", "") },
		"history": func() error {
			var out any
			return client.GetAuthenticated(context.Background(), "/api/v1/host-history", "", &out)
		},
	} {
		t.Run(name, func(t *testing.T) {
			err := operation()
			if err == nil || err.Error() != "internal authentication token missing" {
				t.Fatalf("missing token = %v", err)
			}
		})
	}
	if requests.Load() != 0 {
		t.Fatalf("missing credentials sent %d requests", requests.Load())
	}
}
