// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The discovery-liveness seed path: a host that is up + reachable + advertising its
// extension but generating no fresh proxy traffic (a paused runner, or a stash-only
// host) must survive a collector restart. The aggregator discovers ONLY from the
// squid log UNION its in-memory view, and that view is wiped on restart -- so on
// startup it re-seeds the view from Loki (last-known IPs) and, while running,
// beacons each host's address to Loki on discovery/IP-change. These cover the seed
// helpers, the presence beacon, and the two rehydrate paths.

func TestHostIPFromBaseURL(t *testing.T) {
	cases := map[string]string{
		"http://192.168.7.13:8080":  "192.168.7.13",
		"http://10.0.0.5:8080/":     "10.0.0.5",
		"http://[fe80::1]:8080":     "fe80::1",
		"":                          "",
		"http://":                   "",        // no host
		"   http://1.2.3.4:8080   ": "1.2.3.4", // trimmed
	}
	for in, want := range cases {
		if got := hostIPFromBaseURL(in); got != want {
			t.Errorf("hostIPFromBaseURL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSeedHostStubLocked(t *testing.T) {
	s := newPoolState("default", 8080)
	now := time.Now().UTC()

	// (a) seeds a NEW host as an unreachable probe candidate at the parsed IP.
	if !s.seedHostStubLocked("42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "http://192.168.7.13:8080", now) {
		t.Fatal("(a) expected a new host to be seeded")
	}
	hv := s.hosts["42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
	if hv == nil || hv.CurrentIP != "192.168.7.13" || hv.BaseURL != "http://192.168.7.13:8080" {
		t.Fatalf("(a) stub = %+v, want CurrentIP 192.168.7.13", hv)
	}
	if hv.Reachable {
		t.Error("(a) a seeded stub must be unreachable until a real probe confirms it")
	}
	if hv.LastSeenUnixMs != now.UnixMilli() {
		t.Errorf("(a) LastSeenUnixMs = %d, want now (%d) so a transient first-probe miss does not evict it early", hv.LastSeenUnixMs, now.UnixMilli())
	}

	// (b) never clobbers an existing (possibly live) entry.
	s.hosts["42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] = &hostView{HostId: "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", CurrentIP: "1.2.3.4", Reachable: true}
	if s.seedHostStubLocked("42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "http://9.9.9.9:8080", now) {
		t.Error("(b) seed must not overwrite an existing host")
	}
	if got := s.hosts["42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]; got.CurrentIP != "1.2.3.4" || !got.Reachable {
		t.Errorf("(b) existing host mutated: %+v", got)
	}

	// (c) rejects empty hostId / unparseable-or-hostless baseURL.
	if s.seedHostStubLocked("42cccccccccccccccccccccccccccccc", "", now) {
		t.Error("(c) empty baseURL must not seed")
	}
	if s.seedHostStubLocked("", "http://1.1.1.1:8080", now) {
		t.Error("(c) empty hostId must not seed")
	}
}

func TestApplyPresenceLines(t *testing.T) {
	s := newPoolState("default", 8080)
	now := time.Now().UTC()
	// A live host already in the view must NOT be reseeded (seed never clobbers).
	s.hosts["42live1111111111111111111111111"] = &hostView{HostId: "42live1111111111111111111111111", CurrentIP: "1.1.1.1", Reachable: true}

	hostA := [][2]string{ // newest-first within a stream: the first line wins
		{"200", `{"hostId":"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseUrl":"http://10.0.0.9:8080"}`},
		{"100", `{"hostId":"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseUrl":"http://10.0.0.1:8080"}`},
	}
	hostLive := [][2]string{{"150", `{"hostId":"42live1111111111111111111111111","baseUrl":"http://2.2.2.2:8080"}`}}
	junk := [][2]string{{"50", `not-json`}, {"60", `{"hostId":"","baseUrl":"http://3.3.3.3:8080"}`}}

	if n := s.applyPresenceLines([][][2]string{hostA, hostLive, junk}, now); n != 1 {
		t.Fatalf("seeded = %d, want 1 (only hostA is new + valid)", n)
	}
	if hv := s.hosts["42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]; hv == nil || hv.CurrentIP != "10.0.0.9" {
		t.Errorf("hostA seed = %+v, want newest IP 10.0.0.9", hv)
	}
	if hv := s.hosts["42live1111111111111111111111111"]; hv.CurrentIP != "1.1.1.1" || !hv.Reachable {
		t.Errorf("live host must be untouched, got %+v", hv)
	}
}

func TestPushPresence(t *testing.T) {
	loki, bodies, mu := captureLoki()
	defer loki.Close()
	client := &http.Client{}

	pushPresence(client, loki.URL, "default", "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "http://192.168.7.13:8080", time.Now().UTC())
	mu.Lock()
	got := append([]string{}, *bodies...)
	mu.Unlock()
	if len(got) != 1 {
		t.Fatalf("captured %d Loki bodies, want 1", len(got))
	}
	// Stream labels are unescaped; the line body is a JSON-escaped string, so assert
	// the baseUrl by its (escape-agnostic) value.
	for _, want := range []string{`"src":"presence"`, `"pool":"default"`, `"hostId":"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `192.168.7.13:8080`} {
		if !strings.Contains(got[0], want) {
			t.Errorf("presence push body missing %s\nbody: %s", want, got[0])
		}
	}

	// Disabled (no Loki URL) / incomplete args -> no push, no panic.
	pushPresence(client, "", "default", "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "http://x:8080", time.Now().UTC())
	pushPresence(client, loki.URL, "default", "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "", time.Now().UTC())
	mu.Lock()
	n := len(*bodies)
	mu.Unlock()
	if n != 1 {
		t.Errorf("empty lokiURL / empty baseURL must not push; captured %d", n)
	}
}

// fakeLokiQuery serves a Loki query_range response carrying one stream of the given
// [ts,line] values, so the rehydrate paths can be exercised without a live Loki.
func fakeLokiQuery(values [][2]string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "query_range") {
			http.NotFound(w, r)
			return
		}
		resp := map[string]any{"data": map[string]any{"result": []map[string]any{{"values": values}}}}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
}

func TestRehydrateFromLokiSeedsHostIPs(t *testing.T) {
	const hid = "42512149e3dc437ca677a40828382528"
	ts := fmt.Sprintf("%d", time.Now().Add(-time.Hour).UnixNano())
	srv := fakeLokiQuery([][2]string{
		{ts, `{"hostId":"` + hid + `","cycleId":"c1","overallStatus":"pass","baseUrl":"http://192.168.7.13:8080"}`},
	})
	defer srv.Close()

	s := newPoolState("default", 8080)
	lokiURL := srv.URL + "/loki/api/v1/push" // TrimSuffix("push") -> .../query_range
	s.lokiURL = lokiURL
	now := time.Now().UTC()
	s.rehydrateFromLoki(lokiURL, "default", 7*24*time.Hour, now)

	hv := s.hosts[hid]
	if hv == nil {
		t.Fatal("host not seeded from its transition baseUrl")
	}
	if hv.CurrentIP != "192.168.7.13" || hv.Reachable {
		t.Errorf("seed = %+v, want CurrentIP 192.168.7.13 + unreachable", hv)
	}
	if s.pass[hid] != 1 {
		t.Errorf("pass count = %d, want 1 (rehydrate still restores counts)", s.pass[hid])
	}
}

func TestRehydrateHostPresenceFromLokiSeeds(t *testing.T) {
	const hid = "4253419c1f0b45a08260f36a1521a857"
	ts := fmt.Sprintf("%d", time.Now().Add(-2*time.Hour).UnixNano())
	srv := fakeLokiQuery([][2]string{
		{ts, `{"hostId":"` + hid + `","baseUrl":"http://192.168.7.42:8080"}`},
	})
	defer srv.Close()

	s := newPoolState("default", 8080)
	lokiURL := srv.URL + "/loki/api/v1/push"
	s.lokiURL = lokiURL
	now := time.Now().UTC()
	s.rehydrateHostPresenceFromLoki(lokiURL, "default", 7*24*time.Hour, now)

	hv := s.hosts[hid]
	if hv == nil || hv.CurrentIP != "192.168.7.42" || hv.Reachable {
		t.Fatalf("presence seed = %+v, want CurrentIP 192.168.7.42 + unreachable", hv)
	}
}
