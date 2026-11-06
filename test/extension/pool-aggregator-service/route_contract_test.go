// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 421dfb54-27b0-49bb-b268-c46b66cfc551

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	sdkpool "yuruna.com/test/extension/extension-sdk/pool"
	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The wire contracts of the routes the other tests reach only in part: the
// exact JSON keys a route answers with, the headers it sets and the message
// code it refuses with. Consumers parse these bodies by key -- the guest
// resolver with sed, Test-Config with ConvertFrom-Json, the stash UI by field
// name -- so a key that appears, vanishes or is renamed breaks a caller that
// no compiler sees.

// jsonKeys returns the sorted keys of one JSON object.
func jsonKeys(t *testing.T, raw json.RawMessage) []string {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("not a JSON object: %v (%s)", err, raw)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// assertKeys fails unless raw carries exactly want.
func assertKeys(t *testing.T, what string, raw json.RawMessage, want ...string) {
	t.Helper()
	sort.Strings(want)
	if got := jsonKeys(t, raw); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("%s keys = %v, want %v", what, got, want)
	}
}

// The areas map and the services list carry the same entry type. A
// registration that agrees with the pool's probe, a live announce the pool has
// not confirmed for the same service, and a second host's unconfirmed announce
// together reach every key an entry can carry.
func TestExtensionHostsWireKeys(t *testing.T) {
	s := newPoolState("default", 8080)
	const regHost = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const otherHost = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now()
	s.view().Hosts[regHost] = &hostView{
		HostId:           regHost,
		ActiveExtensions: []string{stashArea},
		ExtensionTargets: map[string]string{stashArea: "http://192.0.2.5"},
		LastSeenUnixMs:   now.UnixMilli(),
	}
	seedExtensionHealth(s, regHost, stashArea, "http://192.0.2.5")
	s.view().Announce[announceKey(regHost, stashArea)] = &announceView{
		HostId: regHost, Area: stashArea, Target: "http://192.0.2.6", SourceIP: "192.0.2.6",
		LastSeenUnixMs: now.UnixMilli(),
	}
	s.view().Announce[announceKey(otherHost, poolControlServiceArea)] = &announceView{
		HostId: otherHost, Area: poolControlServiceArea, Target: "http://192.0.2.9", SourceIP: "192.0.2.9",
		LastSeenUnixMs: now.UnixMilli(),
	}

	rec := httptest.NewRecorder()
	s.handleExtensionHosts(rec, httptest.NewRequest(http.MethodGet, routeExtensionHosts, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
	var out struct {
		Areas    map[string]json.RawMessage `json:"areas"`
		Services []json.RawMessage          `json:"services"`
	}
	body := rec.Body.Bytes()
	assertKeys(t, "extension-hosts", body, "pool", "areas", "services")
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	winner := []string{"area", "host", "target", "hostId", "source", "lastSeenUnixMs",
		"supersededTarget", "healthy", "lastOkUnixMs"}
	if len(out.Areas) != 1 || out.Areas[stashArea] == nil {
		t.Fatalf("areas = %v, want only the reachable %s", out.Areas, stashArea)
	}
	assertKeys(t, "areas entry", out.Areas[stashArea], winner...)
	if len(out.Services) != 2 {
		t.Fatalf("services has %d entries, want 2", len(out.Services))
	}
	assertKeys(t, "services[0]", out.Services[0], winner...)
	assertKeys(t, "services[1]", out.Services[1], "area", "host", "target", "hostId", "source", "lastSeenUnixMs",
		"suppressed", "suppressedTarget", "suppressReason")
	// How the pool learned an address ranks the entry and is never serialized.
	for _, entry := range append([]json.RawMessage{out.Areas[stashArea]}, out.Services...) {
		for _, key := range jsonKeys(t, entry) {
			if strings.EqualFold(key, "confirmed") {
				t.Errorf("the ranking flag reached the wire: %s", entry)
			}
		}
	}

	one := httptest.NewRecorder()
	s.handleExtensionHosts(one, httptest.NewRequest(http.MethodGet, routeExtensionHosts+"?area="+stashArea, nil))
	if one.Code != http.StatusOK {
		t.Fatalf("?area status = %d, want 200", one.Code)
	}
	assertKeys(t, "?area entry", one.Body.Bytes(), winner...)
}

// A host entry is the host view plus the three keys pool-status adds, and the
// announce list never carries the address an announce came from.
func TestPoolStatusWireKeys(t *testing.T) {
	s := newPoolState("default", 8080)
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const retired = "42cccccccccccccccccccccccccccccc"
	const announcer = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now()
	s.view().Hosts[hid] = &hostView{
		HostId:           hid,
		CurrentIP:        "192.0.2.10",
		BaseURL:          "http://192.0.2.10:8080",
		Reachable:        true,
		LastSeenUnixMs:   now.UnixMilli(),
		ActiveExtensions: []string{stashArea},
		ExtensionTargets: map[string]string{stashArea: "http://192.0.2.5"},
	}
	seedExtensionHealth(s, hid, stashArea, "http://192.0.2.5")
	s.view().SetAliases(map[string]string{retired: hid})
	s.view().Announce[announceKey(announcer, stashArea)] = &announceView{
		HostId: announcer, Area: stashArea, Target: "http://192.0.2.7", SourceIP: "192.0.2.77",
		LastSeenUnixMs: now.UnixMilli(),
	}

	rec := httptest.NewRecorder()
	s.handlePoolStatus(rec, httptest.NewRequest(http.MethodGet, routePoolStatus, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
	body := rec.Body.Bytes()
	assertKeys(t, "pool-status", body, "pool", "lastPollUtc", "hosts", "announcedExtensions")
	var out struct {
		Hosts               []json.RawMessage `json:"hosts"`
		AnnouncedExtensions []json.RawMessage `json:"announcedExtensions"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Hosts) != 1 || len(out.AnnouncedExtensions) != 1 {
		t.Fatalf("hosts=%d announcedExtensions=%d, want 1 and 1", len(out.Hosts), len(out.AnnouncedExtensions))
	}
	assertKeys(t, "hosts[0]", out.Hosts[0], "hostId", "currentIp", "baseUrl", "reachable", "lastSeenUnixMs",
		"activeExtensions", "extensionTargets", "stashBaseUrl", "previousHostIds", "refresh")
	var host struct {
		StashBaseURL    string   `json:"stashBaseUrl"`
		PreviousHostIDs []string `json:"previousHostIds"`
	}
	if err := json.Unmarshal(out.Hosts[0], &host); err != nil {
		t.Fatalf("decode host: %v", err)
	}
	if host.StashBaseURL != "http://192.0.2.5" || len(host.PreviousHostIDs) != 1 || host.PreviousHostIDs[0] != retired {
		t.Errorf("host = %+v, want the stash target and the retired id", host)
	}
	assertKeys(t, "announcedExtensions[0]", out.AnnouncedExtensions[0], "hostId", "area", "target", "lastSeenUnixMs")
	if strings.Contains(string(body), "192.0.2.77") {
		t.Errorf("pool-status disclosed an announce's source address: %s", body)
	}
}

// The guest resolver reads this body with sed during bootstrap, so the bytes
// themselves are the contract: one flat object, hostId first and baseUrl next.
func TestHostAddressBodyIsFlatAndOrdered(t *testing.T) {
	s := newPoolState("default", 8080)
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	s.view().Hosts[hid] = &hostView{
		HostId: hid, CurrentIP: "192.0.2.10", BaseURL: "http://192.0.2.10:8080", Reachable: true,
		Status: &hostStatus{HostId: hid, OverallStatus: "running"},
	}

	rec := httptest.NewRecorder()
	s.handleHostAddress(rec, httptest.NewRequest(http.MethodGet, "/api/v1/host-address?hostId="+hid, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	want := `{"hostId":"` + hid + `","baseUrl":"http://192.0.2.10:8080","currentIp":"192.0.2.10","reachable":true}` + "\n"
	if got := rec.Body.String(); got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}

	for _, c := range []struct {
		id   string
		code int
		key  string
	}{
		{"42cccccccccccccccccccccccccccccc", http.StatusNotFound, "aggregator.host_not_known_to_the_pool"},
		{"bad!id", http.StatusBadRequest, "aggregator.invalid_hostid"},
	} {
		rec := httptest.NewRecorder()
		s.handleHostAddress(rec, httptest.NewRequest(http.MethodGet, "/api/v1/host-address?hostId="+url.QueryEscape(c.id), nil))
		if rec.Code != c.code || rec.Header().Get("X-Yuruna-Message-Code") != c.key {
			t.Errorf("hostId %q: status %d code %q, want %d %q", c.id, rec.Code, rec.Header().Get("X-Yuruna-Message-Code"), c.code, c.key)
		}
	}
}

// A host announce is admitted on the same evidence a discovered host is: the
// announced address must serve this hostId's status.json. The address comes
// from the connection, so the test's client sends the announced address to a
// local status server.
func TestHostAnnounceConfirmsAndRelocates(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	status := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/runtime/status.json" {
			http.NotFound(w, r)
			return
		}
		_, _ = io.WriteString(w, `{"hostId":"`+hid+`","overallStatus":"running"}`)
	}))
	defer status.Close()
	var mu sync.Mutex
	var pushes []string
	loki := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		pushes = append(pushes, string(b))
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer loki.Close()
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if addr == "192.0.2.10:8080" {
				addr = status.Listener.Addr().String()
			}
			return dialer.DialContext(ctx, network, addr)
		},
	}}
	s := newPoolState("default", 8080)
	s.httpClient, s.lokiURL = client, loki.URL+"/loki/api/v1/push"
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.99", BaseURL: "http://192.0.2.99:8080", LastError: "dial tcp: timeout"}

	announce := func(remote, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/host-announce", strings.NewReader(body))
		req.RemoteAddr = remote
		rec := httptest.NewRecorder()
		s.handleHostAnnounce(rec, req)
		return rec
	}

	rec := announce("192.0.2.10:5555", `{"hostId":"`+hid+`","statusPort":8080}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d (%s), want 200", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	assertKeys(t, "host-announce", rec.Body.Bytes(), "ok", "hostId", "currentIp", "baseUrl")
	var reply map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &reply)
	if reply["ok"] != true || reply["currentIp"] != "192.0.2.10" || reply["baseUrl"] != "http://192.0.2.10:8080" {
		t.Errorf("reply = %v", reply)
	}
	hv := s.view().Hosts[hid]
	if hv.CurrentIP != "192.0.2.10" || hv.BaseURL != "http://192.0.2.10:8080" || hv.LastError != "" {
		t.Errorf("row = %+v, want it moved to the announced address with the error cleared", hv)
	}
	mu.Lock()
	got := append([]string(nil), pushes...)
	mu.Unlock()
	if len(got) != 1 {
		t.Fatalf("Loki received %d pushes, want 1", len(got))
	}
	var push struct {
		Streams []struct {
			Stream map[string]string `json:"stream"`
			Values [][2]string       `json:"values"`
		} `json:"streams"`
	}
	if err := json.Unmarshal([]byte(got[0]), &push); err != nil || len(push.Streams) != 1 || len(push.Streams[0].Values) != 1 {
		t.Fatalf("push = %s (%v)", got[0], err)
	}
	if labels := push.Streams[0].Stream; labels["src"] != "presence" || labels["pool"] != "default" || labels["hostId"] != hid {
		t.Errorf("stream labels = %v, want the presence stream startup reads", labels)
	}
	if line := push.Streams[0].Values[0][1]; line != `{"baseUrl":"http://192.0.2.10:8080","hostId":"`+hid+`"}` {
		t.Errorf("presence line = %s", line)
	}

	other := announce("192.0.2.10:5555", `{"hostId":"42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","statusPort":8080}`)
	if other.Code != http.StatusBadRequest || other.Header().Get("X-Yuruna-Message-Code") != "aggregator.announced_address_serves_a_different_hostid" {
		t.Errorf("foreign hostId: status %d code %q", other.Code, other.Header().Get("X-Yuruna-Message-Code"))
	}

	// An address no other machine could route to is refused with the reason
	// itself, before any probe.
	loop := announce("127.0.0.1:5555", `{"hostId":"`+hid+`","statusPort":8080}`)
	if loop.Code != http.StatusBadRequest || loop.Header().Get("X-Yuruna-Message-Code") != "" ||
		!strings.HasPrefix(loop.Body.String(), "loopback address") {
		t.Errorf("loopback: status %d code %q body %q", loop.Code, loop.Header().Get("X-Yuruna-Message-Code"), loop.Body.String())
	}

	s.announceTtl = 0
	off := announce("192.0.2.10:5555", `{"hostId":"`+hid+`","statusPort":8080}`)
	if off.Code != http.StatusServiceUnavailable || off.Header().Get("X-Yuruna-Message-Code") != "aggregator.announce_disabled" {
		t.Errorf("disabled: status %d code %q", off.Code, off.Header().Get("X-Yuruna-Message-Code"))
	}
}

// The two JSON twins of the incident and gate exposition: the keys the MCP
// tools document, the window recount, and the not-yet-evaluated gate.
func TestPoolIncidentsAndHealthBodies(t *testing.T) {
	s := newPoolState("default", 8080)
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	now := time.Now().UTC()

	quiet := httptest.NewRecorder()
	s.handlePoolIncidents(quiet, httptest.NewRequest(http.MethodGet, routePoolIncidents, nil))
	assertKeys(t, "quiet pool-incidents", quiet.Body.Bytes(),
		"ok", "pool", "windowMinutes", "failsToOpen", "activeHostCount", "hosts", "poolWide", "asOfUtc")
	var quietOut struct {
		PoolWide json.RawMessage `json:"poolWide"`
		Hosts    []any           `json:"hosts"`
	}
	_ = json.Unmarshal(quiet.Body.Bytes(), &quietOut)
	if string(quietOut.PoolWide) != `{"active":false}` || quietOut.Hosts == nil || len(quietOut.Hosts) != 0 {
		t.Errorf("quiet pool: poolWide=%s hosts=%v, want {active:false} and an empty list", quietOut.PoolWide, quietOut.Hosts)
	}

	unevaluated := httptest.NewRecorder()
	s.handlePoolHealth(unevaluated, httptest.NewRequest(http.MethodGet, routePoolHealth, nil))
	assertKeys(t, "unevaluated pool-health", unevaluated.Body.Bytes(), "evaluated", "ok", "pool", "asOfUtc")

	started := now.Add(-30 * time.Minute)
	s.view().Incident[hid] = &incident.HostIncident{ID: "inc-1", StartedAt: started, Peak: 4, DominantClass: "network_timeout"}
	s.view().FailWindow[hid] = []failRec{
		{At: now.Add(-3 * time.Hour), Class: "network_timeout"},
		{At: now.Add(-20 * time.Minute), Class: "network_timeout"},
		{At: now.Add(-10 * time.Minute), Class: "network_timeout"},
	}
	s.view().PoolIncident = &incident.PoolIncident{ID: "pool-1", StartedAt: started, PeakHosts: 3, Class: "network_timeout"}
	s.view().PoolGate["default"] = &incident.Gate{
		BelowSince: started, Degraded: true, Authored: true, AlertFired: true, ConsecDegraded: 5,
		AlertID: "alert-1", AlertStartedAt: started,
		LastFraction: 0.25, LastHealthy: 1, LastTotal: 4, LastThreshold: 0.5,
	}
	s.view().MarkPolled(now)

	rec := httptest.NewRecorder()
	s.handlePoolIncidents(rec, httptest.NewRequest(http.MethodGet, routePoolIncidents, nil))
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("pool-incidents Content-Type = %q", got)
	}
	var inc struct {
		Pool          string            `json:"pool"`
		WindowMinutes int               `json:"windowMinutes"`
		FailsToOpen   int               `json:"failsToOpen"`
		ActiveHosts   int               `json:"activeHostCount"`
		Hosts         []json.RawMessage `json:"hosts"`
		PoolWide      json.RawMessage   `json:"poolWide"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &inc); err != nil {
		t.Fatalf("decode pool-incidents: %v", err)
	}
	if inc.Pool != "default" || inc.WindowMinutes != 120 || inc.FailsToOpen != 3 || inc.ActiveHosts != 1 || len(inc.Hosts) != 1 {
		t.Fatalf("pool-incidents = %s", rec.Body.String())
	}
	assertKeys(t, "incident host", inc.Hosts[0], "hostId", "incidentId", "startedUtc", "dominantClass", "peakFailCount", "recentFailCount")
	var host map[string]any
	_ = json.Unmarshal(inc.Hosts[0], &host)
	if host["recentFailCount"] != float64(2) || host["peakFailCount"] != float64(4) || host["startedUtc"] != started.Format(time.RFC3339) {
		t.Errorf("incident host = %v, want two fails inside the window and the stored peak", host)
	}
	assertKeys(t, "poolWide", inc.PoolWide, "active", "incidentId", "startedUtc", "class", "peakHostCount")

	health := httptest.NewRecorder()
	s.handlePoolHealth(health, httptest.NewRequest(http.MethodGet, routePoolHealth, nil))
	if got := health.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("pool-health Content-Type = %q", got)
	}
	assertKeys(t, "pool-health", health.Body.Bytes(), "evaluated", "membersHealthy", "membersTotal", "healthyFraction",
		"healthyThreshold", "degraded", "alertActive", "authoredGating", "consecutiveDegraded", "consecutiveHealthy",
		"belowThresholdSinceUtc", "alertStartedUtc", "alertId", "ok", "pool", "asOfUtc", "lastPollUtc")
	var gate map[string]any
	_ = json.Unmarshal(health.Body.Bytes(), &gate)
	if gate["alertId"] != "alert-1" || gate["healthyFraction"] != 0.25 || gate["lastPollUtc"] != now.Format(time.RFC3339) {
		t.Errorf("pool-health = %v", gate)
	}
}

// A host the live view no longer holds, with no archive, no index and no
// listing, still resolves a timeline click through the Loki transition feed:
// first its last-known address, then the cycle whose window holds the click.
func TestGoCycleFallsBackToTheLokiTransitionFeed(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	day := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	folderA := "log/000122.2026-11-01.10-00-00." + hid + "/"
	folderB := "log/000123.2026-11-01.11-05-00." + hid + "/"
	line := func(folder string, started, finished time.Time) string {
		b, _ := json.Marshal(map[string]string{
			"hostId": hid, "cycleStartUtc": started.Format(time.RFC3339), "overallStatus": "pass",
			"startedAt": started.Format(time.RFC3339), "finishedAt": finished.Format(time.RFC3339),
			"baseUrl": "http://192.0.2.10:8080", "cycleFolderUrl": folder,
		})
		return string(b)
	}
	values := [][2]string{
		{fmt.Sprint(day.Add(12 * time.Hour).UnixNano()), line(folderB, day.Add(11*time.Hour+5*time.Minute), day.Add(12*time.Hour))},
		{fmt.Sprint(day.Add(11 * time.Hour).UnixNano()), line(folderA, day.Add(10*time.Hour), day.Add(11*time.Hour))},
	}
	var mu sync.Mutex
	var queries []string
	client := &http.Client{Transport: pollLokiTransport(func(r *http.Request) (*http.Response, error) {
		code, body := http.StatusNotFound, ""
		if r.URL.Host == "loki.invalid" && strings.HasSuffix(r.URL.Path, "/query_range") {
			mu.Lock()
			queries = append(queries, r.URL.Query().Get("query"))
			mu.Unlock()
			b, _ := json.Marshal(map[string]any{"data": map[string]any{"result": []map[string]any{
				{"stream": map[string]string{"pool": "default", "hostId": hid, "src": "cycle"}, "values": values},
			}}})
			code, body = http.StatusOK, string(b)
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	s := newPoolState("default", 8080)
	s.httpClient, s.lokiURL = client, "http://loki.invalid/loki/api/v1/push"

	click := day.Add(10*time.Hour + 30*time.Minute)
	rec := httptest.NewRecorder()
	s.handleGoCycle(rec, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/cycle?host=%s&t=%d", hid, click.UnixMilli()), nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d (%s), want 302", rec.Code, rec.Body.String())
	}
	if loc := rec.Header().Get("Location"); loc != "http://192.0.2.10:8080/"+folderA {
		t.Errorf("Location = %q, want the cycle whose window holds the click", loc)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(queries) != 2 {
		t.Fatalf("Loki was asked %d times, want the address lookup and the cycle lookup", len(queries))
	}
	for _, q := range queries {
		if q != `{pool="default", hostId="`+hid+`", src="cycle"} | json` {
			t.Errorf("query = %q, want the host's transition stream", q)
		}
	}
}

// The flags main() relabels are registered at package initialization, so a
// build that drops the registration fails here rather than at startup.
func TestLanguageFlagsAreRegistered(t *testing.T) {
	for name, def := range map[string]string{"language": "auto", "allow-pseudo-locale": "false"} {
		f := flag.Lookup(name)
		if f == nil {
			t.Errorf("-%s is not registered", name)
			continue
		}
		if f.DefValue != def {
			t.Errorf("-%s default = %q, want %q", name, f.DefValue, def)
		}
	}
}

// Startup restores a self-announced service from the newest line its stream
// holds: an active line restores the entry at the line's own time, and a
// goodbye newer than an active line leaves the entry absent.
func TestRehydrateAnnouncesRestoresTheLatestLinePerService(t *testing.T) {
	const live = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const gone = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC().Truncate(time.Millisecond)
	line := func(host string, active bool) string {
		b, _ := json.Marshal(map[string]any{"hostId": host, "area": stashArea, "target": "http://192.0.2.7", "active": active})
		return string(b)
	}
	liveAt := now.Add(-5 * time.Minute)
	var mu sync.Mutex
	var params url.Values
	loki := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/query_range") {
			http.NotFound(w, r)
			return
		}
		mu.Lock()
		params = r.URL.Query()
		mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"result": []map[string]any{
			{"stream": map[string]string{"pool": "default", "hostId": live, "src": "announce"},
				"values": [][2]string{{fmt.Sprint(liveAt.UnixNano()), line(live, true)}}},
			{"stream": map[string]string{"pool": "default", "hostId": gone, "src": "announce"},
				"values": [][2]string{
					{fmt.Sprint(now.Add(-2 * time.Minute).UnixNano()), line(gone, false)},
					{fmt.Sprint(now.Add(-10 * time.Minute).UnixNano()), line(gone, true)},
				}},
		}}})
	}))
	defer loki.Close()

	s := newPoolState("default", 8080)
	s.rehydrateAnnouncesFromLoki(loki.URL+"/loki/api/v1/push", "default", now)

	mu.Lock()
	query, start := params.Get("query"), params.Get("start")
	mu.Unlock()
	if !strings.Contains(query, `src="announce"`) || !strings.Contains(query, `pool="default"`) {
		t.Errorf("query = %q, want the pool's announce stream", query)
	}
	if want := fmt.Sprint(now.Add(-s.announceTtl).UnixNano()); start != want {
		t.Errorf("start = %s, want the announce TTL before now (%s)", start, want)
	}
	s.st.Do(func(view *poolstate.View) {
		restored := view.Announce[announceKey(live, stashArea)]
		if restored == nil || restored.Target != "http://192.0.2.7" || restored.LastSeenUnixMs != liveAt.UnixMilli() {
			t.Errorf("live entry = %+v, want restored at the line's time", restored)
		}
		if restored != nil && restored.SourceIP != "" {
			t.Errorf("a restored entry carries no source address, got %q", restored.SourceIP)
		}
		if view.Announce[announceKey(gone, stashArea)] != nil {
			t.Error("a service whose newest line is a goodbye was restored")
		}
	})
}

// The exposition counts the hosts that failed inside the configured cross-host
// window, not a default: a failure older than the default window but inside a
// wider configured one still counts.
func TestMetricsCountsFailuresInsideTheConfiguredCrossWindow(t *testing.T) {
	s := newPoolState("default", 8080)
	s.crossWin = 2 * time.Hour
	now := time.Now().UTC()
	s.view().FailWindow["42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] = []failRec{{At: now.Add(-time.Hour), Class: "network_timeout"}}
	s.view().MarkPolled(now)

	rec := httptest.NewRecorder()
	s.handleMetrics(rec, metricsRequest())
	if !strings.Contains(rec.Body.String(), "\nyuruna_pool_wide_incident_hosts 1\n") {
		t.Errorf("a failure an hour old inside a two-hour window was not counted:\n%s", rec.Body.String())
	}
}

// A host's refresh reading stays available for the configured observation
// window, which pool-status and the exposition both read, not for the floor.
func TestPoolStatusAndMetricsReadTheConfiguredRefreshWindow(t *testing.T) {
	s := newPoolState("default", 8080)
	s.refreshTTL = 10 * time.Minute
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	s.view().Hosts[hid] = &hostView{HostId: hid, CurrentIP: "192.0.2.10", Reachable: true, LastSeenUnixMs: time.Now().UnixMilli(),
		Refresh: sdkpool.HostRefresh{Protocol: 1, Availability: sdkpool.RefreshAvailable, Ceiling: sdkpool.RungStartIfStopped,
			Remote: sdkpool.RefreshRemoteProvisioned, State: sdkpool.RefreshStateIdle,
			ObservedUnixMs: time.Now().Add(-5 * time.Minute).UnixMilli()}}

	rec := httptest.NewRecorder()
	s.handlePoolStatus(rec, httptest.NewRequest(http.MethodGet, routePoolStatus, nil))
	var out struct {
		Hosts []struct {
			Refresh sdkpool.HostRefresh `json:"refresh"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || len(out.Hosts) != 1 {
		t.Fatalf("pool-status = %s (%v)", rec.Body.String(), err)
	}
	if got := out.Hosts[0].Refresh; got.Availability != sdkpool.RefreshAvailable {
		t.Errorf("pool-status refresh = %+v, want available inside the configured window", got)
	}
	m := httptest.NewRecorder()
	s.handleMetrics(m, metricsRequest())
	want := fmt.Sprintf("yuruna_pool_host_refresh_available{pool=%q,hostId=%q,hostIdDashed=%q,state=%q} 1\n",
		"default", hid, poolstate.DashedHostID(hid), sdkpool.RefreshStateIdle)
	if !strings.Contains(m.Body.String(), want) {
		t.Errorf("exposition does not read the reading as available:\n%s", m.Body.String())
	}
}

// A memoized pool-stats answer is served only while it is younger than the
// cache TTL; an older one is replaced by a fresh Loki answer.
func TestPoolStatsRequeriesLokiOnceTheCacheEntryExpires(t *testing.T) {
	var seen []string
	stub := newLokiStub(t, map[string]int64{"42aa": 1}, nil, &seen)
	defer stub.Close()
	s := newStatsState(stub.URL)
	stale := []byte(`{"range":"24h","stale":true}`)
	s.statsCache["24h"] = &poolStatsCacheEntry{at: time.Now().Add(-poolStatsCacheTTL - time.Second), payload: stale}

	rec := httptest.NewRecorder()
	s.handlePoolStats(rec, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=24h", nil))
	if rec.Code != http.StatusOK || len(seen) != 2 || strings.Contains(rec.Body.String(), "stale") {
		t.Errorf("status %d after %d Loki queries, body %s; want a fresh answer from two queries", rec.Code, len(seen), rec.Body.String())
	}
}

// A handover that moves the cache epoch while a pool-stats answer is being
// computed keeps that answer out of the cache: it was projected through the
// aliases as they were before the handover.
func TestPoolStatsDoesNotCacheAnAnswerComputedAcrossAHandover(t *testing.T) {
	var s *poolState
	var once sync.Once
	var seen []string
	inner := newLokiStub(t, map[string]int64{"42aa": 1}, nil, &seen)
	defer inner.Close()
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		once.Do(func() {
			s.statsMu.Lock()
			s.statsEpoch++
			s.statsMu.Unlock()
		})
		inner.Config.Handler.ServeHTTP(w, r)
	}))
	defer stub.Close()
	s = newStatsState(stub.URL)

	rec := httptest.NewRecorder()
	s.handlePoolStats(rec, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=24h", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
	}
	s.statsMu.Lock()
	cached := s.statsCache["24h"]
	s.statsMu.Unlock()
	if cached != nil {
		t.Errorf("an answer computed across an epoch change was cached: %s", cached.payload)
	}
}
