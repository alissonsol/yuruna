// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The extension-presence announce (POST /announce): a service VM self-reports
// the extension it runs so the Extension hosts row survives the owning host's
// status server being down. These cover the handler's validation + identity
// binding, the metric union with registration rows, the TTL reap, the Loki
// rehydrate, and the /go/stash + pool-status fallbacks.

const testHostID = "42512149e3dc437ca677a40828382528"

// postAnnounce sends one announce body from the given source address.
func postAnnounce(s *poolState, remoteAddr, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", "/announce", strings.NewReader(body))
	req.RemoteAddr = remoteAddr
	rec := httptest.NewRecorder()
	s.handleAnnounce(rec, req)
	return rec
}

func TestAnnounceCreatesExtensionRow(t *testing.T) {
	s := newPoolState("default", 8080)
	rec := postAnnounce(s, "10.0.0.7:5555",
		fmt.Sprintf(`{"schemaVersion":1,"hostId":%q,"area":"stash-service","targetPort":80,"active":true}`, testHostID))
	if rec.Code/100 != 2 {
		t.Fatalf("announce status = %d, want 2xx", rec.Code)
	}
	m := httptest.NewRecorder()
	s.handleMetrics(m, httptest.NewRequest("GET", "/metrics", nil))
	// The target derives from the SOURCE address (port 80 -> no port suffix);
	// baseUrl is empty because the owning host is not in the view.
	want := "yuruna_pool_host_extension{pool=\"default\",hostId=\"" + testHostID + "\",area=\"stash-service\",baseUrl=\"\",target=\"http://10.0.0.7\"} 1"
	if !strings.Contains(m.Body.String(), want) {
		t.Errorf("/metrics missing the announce-sourced row.\nwant: %s\ngot:\n%s", want, m.Body.String())
	}
}

func TestAnnounceNonDefaultPortRidesInTarget(t *testing.T) {
	s := newPoolState("default", 8080)
	postAnnounce(s, "10.0.0.7:5555", fmt.Sprintf(`{"hostId":%q,"targetPort":8081}`, testHostID))
	s.mu.Lock()
	av := s.announce[announceKey(testHostID, stashArea)]
	s.mu.Unlock()
	if av == nil || av.Target != "http://10.0.0.7:8081" {
		t.Errorf("announce target = %+v, want http://10.0.0.7:8081 (area defaults to stash-service)", av)
	}
}

// An explicit target URL must point at the SENDER -- an announcer can only
// advertise itself, never paint a row that redirects to a third party.
func TestAnnounceExplicitTargetMustMatchSource(t *testing.T) {
	s := newPoolState("default", 8080)
	rec := postAnnounce(s, "10.0.0.7:5555",
		fmt.Sprintf(`{"hostId":%q,"target":"http://10.0.0.99"}`, testHostID))
	if rec.Code != 403 {
		t.Errorf("mismatched explicit target: status = %d, want 403", rec.Code)
	}
	rec = postAnnounce(s, "10.0.0.7:5555",
		fmt.Sprintf(`{"hostId":%q,"target":"http://10.0.0.7:8081"}`, testHostID))
	if rec.Code/100 != 2 {
		t.Errorf("self-matching explicit target: status = %d, want 2xx", rec.Code)
	}
}

func TestAnnounceRejectsInvalidIdentity(t *testing.T) {
	s := newPoolState("default", 8080)
	cases := []struct {
		name string
		body string
	}{
		{"hostId with label-breaking chars", `{"hostId":"bad\"id{}","targetPort":80}`},
		{"hostId too short", `{"hostId":"ab","targetPort":80}`},
		{"area with uppercase", fmt.Sprintf(`{"hostId":%q,"area":"Stash-Service"}`, testHostID)},
		{"non-http target scheme", fmt.Sprintf(`{"hostId":%q,"target":"javascript:alert(1)"}`, testHostID)},
		{"not json", `hostId=x`},
	}
	for _, c := range cases {
		if rec := postAnnounce(s, "10.0.0.7:5555", c.body); rec.Code != 400 {
			t.Errorf("%s: status = %d, want 400", c.name, rec.Code)
		}
	}
}

// A goodbye (active=false) removes the row immediately -- but only when it
// comes from the entry's own source address.
func TestAnnounceGoodbyeIdentityBound(t *testing.T) {
	s := newPoolState("default", 8080)
	postAnnounce(s, "10.0.0.7:5555", fmt.Sprintf(`{"hostId":%q,"targetPort":80}`, testHostID))

	postAnnounce(s, "10.0.0.99:5555", fmt.Sprintf(`{"hostId":%q,"active":false}`, testHostID))
	s.mu.Lock()
	kept := s.announce[announceKey(testHostID, stashArea)] != nil
	s.mu.Unlock()
	if !kept {
		t.Fatal("a goodbye from a DIFFERENT source removed the entry")
	}

	postAnnounce(s, "10.0.0.7:6666", fmt.Sprintf(`{"hostId":%q,"active":false}`, testHostID))
	s.mu.Lock()
	kept = s.announce[announceKey(testHostID, stashArea)] != nil
	s.mu.Unlock()
	if kept {
		t.Fatal("the owner's goodbye did not remove the entry")
	}
}

// When BOTH sources cover one (hostId, area), the registration row wins and
// exactly one row is emitted.
func TestAnnounceRegistrationRowWins(t *testing.T) {
	s := newPoolState("default", 8080)
	s.hosts[testHostID] = &hostView{
		HostId:           testHostID,
		BaseURL:          "http://10.0.0.1:8080",
		ActiveExtensions: []string{"stash-service"},
		ExtensionTargets: map[string]string{"stash-service": "http://10.0.0.5"},
		LastSeenUnixMs:   time.Now().UnixMilli(),
	}
	postAnnounce(s, "10.0.0.7:5555", fmt.Sprintf(`{"hostId":%q,"targetPort":80}`, testHostID))

	m := httptest.NewRecorder()
	s.handleMetrics(m, httptest.NewRequest("GET", "/metrics", nil))
	body := m.Body.String()
	if got := strings.Count(body, "yuruna_pool_host_extension{"); got != 1 {
		t.Errorf("emitted %d extension rows, want exactly 1 (registration wins)", got)
	}
	if !strings.Contains(body, "target=\"http://10.0.0.5\"") {
		t.Errorf("winning row must carry the registration target, got:\n%s", body)
	}
}

// An entry whose beacon stopped refreshing is reaped after announceTTL; a
// fresh one survives the same sweep.
func TestAnnounceTTLReap(t *testing.T) {
	s := newPoolState("default", 8080)
	now := time.Now().UTC()
	s.announce[announceKey("stalehost1", stashArea)] = &announceView{
		HostId: "stalehost1", Area: stashArea,
		LastSeenUnixMs: now.Add(-s.announceTTL - time.Minute).UnixMilli(),
	}
	s.announce[announceKey("freshhost1", stashArea)] = &announceView{
		HostId: "freshhost1", Area: stashArea,
		LastSeenUnixMs: now.Add(-time.Minute).UnixMilli(),
	}
	// The reap runs inside pollOnce's locked section; exercised via pollOnce
	// with no squid log and no hosts (a no-op poll otherwise).
	s.pollOnce(nil, "no-such-squid.log", "", now)
	s.mu.Lock()
	_, stale := s.announce[announceKey("stalehost1", stashArea)]
	_, fresh := s.announce[announceKey("freshhost1", stashArea)]
	s.mu.Unlock()
	if stale {
		t.Error("stale announce survived the TTL reap")
	}
	if !fresh {
		t.Error("fresh announce was reaped")
	}
}

// The newest Loki line per (hostId, area) decides restart state: active
// restores (with the line's own timestamp as freshness), a goodbye leaves the
// entry absent, and garbage lines are ignored.
func TestApplyAnnounceLines(t *testing.T) {
	s := newPoolState("default", 8080)
	now := time.Now().UTC()
	ns := func(d time.Duration) string { return fmt.Sprintf("%d", now.Add(d).UnixNano()) }
	line := func(host string, active bool, target string) string {
		b, _ := json.Marshal(map[string]any{"hostId": host, "area": stashArea, "target": target, "active": active})
		return string(b)
	}
	streams := [][][2]string{
		{ // newest-first within a stream: latest hello wins over the older goodbye
			{ns(-time.Minute), line("livehost1", true, "http://10.0.0.7")},
			{ns(-2 * time.Minute), line("livehost1", false, "")},
		},
		{ // latest line is a goodbye -> stays absent
			{ns(-time.Minute), line("gonehost1", false, "")},
			{ns(-2 * time.Minute), line("gonehost1", true, "http://10.0.0.8")},
		},
		{ // non-http target restores as presence-only
			{ns(-time.Minute), line("nolinkhost", true, "ftp://10.0.0.9")},
		},
		{ // invalid identity never restores
			{ns(-time.Minute), `{"hostId":"x","area":"stash-service","active":true}`},
		},
	}
	if n := s.applyAnnounceLines(streams, now); n != 2 {
		t.Errorf("restored %d entries, want 2", n)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	live := s.announce[announceKey("livehost1", stashArea)]
	if live == nil || live.Target != "http://10.0.0.7" {
		t.Errorf("livehost1 = %+v, want restored with its target", live)
	}
	if live != nil && live.LastSeenUnixMs != now.Add(-time.Minute).UnixMilli() {
		t.Errorf("livehost1 freshness = %d, want the LINE's timestamp", live.LastSeenUnixMs)
	}
	if s.announce[announceKey("gonehost1", stashArea)] != nil {
		t.Error("gonehost1 restored despite its latest line being a goodbye")
	}
	if nl := s.announce[announceKey("nolinkhost", stashArea)]; nl == nil || nl.Target != "" {
		t.Errorf("nolinkhost = %+v, want restored presence-only (no target)", nl)
	}
}

// /go/stash falls back to the self-announced target when the registration
// path has nothing (host absent from the view entirely).
func TestGoStashFallsBackToAnnounce(t *testing.T) {
	s := newPoolState("default", 8080)
	postAnnounce(s, "10.0.0.7:5555", fmt.Sprintf(`{"hostId":%q,"targetPort":80}`, testHostID))
	rec := httptest.NewRecorder()
	s.handleGoStash(rec, httptest.NewRequest("GET", "/go/stash?host="+testHostID, nil))
	if rec.Code != 302 {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "http://10.0.0.7" {
		t.Errorf("Location = %q, want the announced target", loc)
	}
}

// pool-status carries stashBaseUrl per host (registration first, announce
// fallback) and the raw announcedExtensions list.
func TestPoolStatusStashBaseURL(t *testing.T) {
	s := newPoolState("default", 8080)
	s.hosts["reghost11"] = &hostView{
		HostId:           "reghost11",
		ExtensionTargets: map[string]string{"stash-service": "http://10.0.0.5"},
	}
	s.hosts[testHostID] = &hostView{HostId: testHostID} // in view, no registration target
	postAnnounce(s, "10.0.0.7:5555", fmt.Sprintf(`{"hostId":%q,"targetPort":80}`, testHostID))

	rec := httptest.NewRecorder()
	s.handlePoolStatus(rec, httptest.NewRequest("GET", "/api/v1/pool-status", nil))
	var out struct {
		Hosts []struct {
			HostID       string `json:"hostId"`
			StashBaseURL string `json:"stashBaseUrl"`
		} `json:"hosts"`
		AnnouncedExtensions []struct {
			HostID string `json:"hostId"`
			Area   string `json:"area"`
			Target string `json:"target"`
		} `json:"announcedExtensions"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("pool-status parse: %v", err)
	}
	got := map[string]string{}
	for _, h := range out.Hosts {
		got[h.HostID] = h.StashBaseURL
	}
	if got["reghost11"] != "http://10.0.0.5" {
		t.Errorf("reghost11 stashBaseUrl = %q, want the registration target", got["reghost11"])
	}
	if got[testHostID] != "http://10.0.0.7" {
		t.Errorf("%s stashBaseUrl = %q, want the announce fallback", testHostID, got[testHostID])
	}
	if len(out.AnnouncedExtensions) != 1 || out.AnnouncedExtensions[0].HostID != testHostID {
		t.Errorf("announcedExtensions = %+v, want the one live announce", out.AnnouncedExtensions)
	}
}

// -announce-ttl 0 disables the route: an open write surface must have an off
// switch.
func TestAnnounceDisabledByZeroTTL(t *testing.T) {
	s := newPoolState("default", 8080)
	s.announceTTL = 0
	rec := postAnnounce(s, "10.0.0.7:5555", fmt.Sprintf(`{"hostId":%q,"targetPort":80}`, testHostID))
	if rec.Code != 503 {
		t.Errorf("status = %d, want 503 when announce is disabled", rec.Code)
	}
}
