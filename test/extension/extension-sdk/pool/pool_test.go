// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package pool

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
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
