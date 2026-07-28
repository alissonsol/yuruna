// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// /api/v1/extension-hosts is the coordinate lookup a host uses to find a service
// it does not run itself. Knowing the caching-proxy address -- which every host
// already needs -- must be enough to find the stash service and pool control,
// wherever in the pool (or on whichever subnet) they currently live. These cover
// the resolution precedence, the freshness filter, and the two answer shapes.

func TestExtensionHostsResolvesStashAndPoolControl(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "422dd0cac87e4cc6831c3228f12ae689"
	now := time.Now()
	s.announce[announceKey(hid, stashArea)] = &announceView{
		HostId: hid, Area: stashArea, Target: "http://192.168.7.227",
		LastSeenUnixMs: now.UnixMilli(),
	}
	s.announce[announceKey(hid, poolControlArea)] = &announceView{
		HostId: hid, Area: poolControlArea, Target: "http://192.168.7.88",
		LastSeenUnixMs: now.UnixMilli(),
	}

	rec := httptest.NewRecorder()
	s.handleExtensionHosts(rec, httptest.NewRequest("GET", "/api/v1/extension-hosts", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var out struct {
		Pool  string                        `json:"pool"`
		Areas map[string]extensionHostEntry `json:"areas"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Pool != "default" {
		t.Errorf("pool = %q, want default", out.Pool)
	}
	// Host, not the whole URL: a consumer building http://<host>/healthz or an
	// scp target needs the bare address.
	if got := out.Areas[stashArea].Host; got != "192.168.7.227" {
		t.Errorf("stash host = %q, want 192.168.7.227", got)
	}
	if got := out.Areas[stashArea].Target; got != "http://192.168.7.227" {
		t.Errorf("stash target = %q, want http://192.168.7.227", got)
	}
	if got := out.Areas[poolControlArea].Host; got != "192.168.7.88" {
		t.Errorf("pool-control host = %q, want 192.168.7.88", got)
	}
	if got := out.Areas[stashArea].Source; got != "announce" {
		t.Errorf("source = %q, want announce", got)
	}
}

// ?area= narrows to one area, which is the form a host script calls.
func TestExtensionHostsSingleArea(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "422dd0cac87e4cc6831c3228f12ae689"
	s.announce[announceKey(hid, stashArea)] = &announceView{
		HostId: hid, Area: stashArea, Target: "http://192.168.7.227",
		LastSeenUnixMs: time.Now().UnixMilli(),
	}
	rec := httptest.NewRecorder()
	s.handleExtensionHosts(rec, httptest.NewRequest("GET", "/api/v1/extension-hosts?area="+stashArea, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var entry extensionHostEntry
	if err := json.Unmarshal(rec.Body.Bytes(), &entry); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if entry.Area != stashArea || entry.Host != "192.168.7.227" {
		t.Errorf("entry = %+v, want area %s at 192.168.7.227", entry, stashArea)
	}
}

// An area nobody serves must 404. A consumer has to be able to tell "the pool
// does not have one" from "here it is" -- guessing instead is exactly what the
// hard-coded literal did, and it kept pointing at a machine that had moved.
func TestExtensionHostsUnknownArea404(t *testing.T) {
	s := newPoolState("default", 8080)
	rec := httptest.NewRecorder()
	s.handleExtensionHosts(rec, httptest.NewRequest("GET", "/api/v1/extension-hosts?area="+stashArea, nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404 when no host serves the area", rec.Code)
	}
}

// Registration wins over an announce for the same area: the owning host
// re-resolves that target live every cycle, so it tracks a DHCP change sooner
// than the next beacon would.
func TestExtensionHostsRegistrationBeatsAnnounce(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "422dd0cac87e4cc6831c3228f12ae689"
	now := time.Now()
	s.hosts[hid] = &hostView{
		HostId:           hid,
		ExtensionTargets: map[string]string{stashArea: "http://10.0.0.9"},
		LastSeenUnixMs:   now.UnixMilli(),
	}
	s.announce[announceKey(hid, stashArea)] = &announceView{
		HostId: hid, Area: stashArea, Target: "http://10.0.0.5",
		LastSeenUnixMs: now.UnixMilli(),
	}
	entries := s.resolveExtensionHostsLocked(now)
	if got := entries[stashArea].Host; got != "10.0.0.9" {
		t.Errorf("host = %q, want the registration-advertised 10.0.0.9", got)
	}
	if got := entries[stashArea].Source; got != "registration" {
		t.Errorf("source = %q, want registration", got)
	}
}

// A beacon that stopped two TTLs ago must not be handed out just because the
// poll that reaps it has not run yet.
func TestExtensionHostsSkipsExpiredAnnounce(t *testing.T) {
	s := newPoolState("default", 8080)
	s.announceTTL = 45 * time.Minute
	hid := "422dd0cac87e4cc6831c3228f12ae689"
	now := time.Now()
	s.announce[announceKey(hid, stashArea)] = &announceView{
		HostId: hid, Area: stashArea, Target: "http://10.0.0.5",
		LastSeenUnixMs: now.Add(-90 * time.Minute).UnixMilli(),
	}
	entries := s.resolveExtensionHostsLocked(now)
	if _, ok := entries[stashArea]; ok {
		t.Errorf("expired announce was served: %+v", entries[stashArea])
	}
}

// Two hosts announcing the same area resolve to ONE deterministic answer -- the
// freshest, then the lower hostId. A consumer that re-asks must not be walked
// between equally valid addresses.
func TestExtensionHostsPicksDeterministically(t *testing.T) {
	s := newPoolState("default", 8080)
	now := time.Now()
	older := "4200000000000000000000000000000a"
	newer := "4200000000000000000000000000000b"
	s.announce[announceKey(older, stashArea)] = &announceView{
		HostId: older, Area: stashArea, Target: "http://10.0.0.5",
		LastSeenUnixMs: now.Add(-5 * time.Minute).UnixMilli(),
	}
	s.announce[announceKey(newer, stashArea)] = &announceView{
		HostId: newer, Area: stashArea, Target: "http://10.0.0.6",
		LastSeenUnixMs: now.UnixMilli(),
	}
	for i := 0; i < 5; i++ {
		if got := s.resolveExtensionHostsLocked(now)[stashArea].Host; got != "10.0.0.6" {
			t.Fatalf("attempt %d: host = %q, want the freshest 10.0.0.6", i, got)
		}
	}
}

// A presence-only announce (no parseable target -- the shape a Loki rehydrate
// leaves behind) is presence, not an address, and must not be served as one.
func TestExtensionHostsIgnoresTargetlessAnnounce(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "422dd0cac87e4cc6831c3228f12ae689"
	now := time.Now()
	s.announce[announceKey(hid, stashArea)] = &announceView{
		HostId: hid, Area: stashArea, Target: "", LastSeenUnixMs: now.UnixMilli(),
	}
	if _, ok := s.resolveExtensionHostsLocked(now)[stashArea]; ok {
		t.Errorf("a target-less announce was served as an address")
	}
}
