// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	sdkpool "yuruna.com/test/extension/extension-sdk/pool"
)

// The refresh capability's path through this daemon: read from each host's
// control-status, clamped, merged with an expiry, published in pool-status and
// one bounded gauge -- and never minted, never carried in a redirect, never
// exposed through MCP.

const refreshHostID = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func serveControlStatus(code int, body string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/control/control-status" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(code)
		fmt.Fprint(w, body)
	}))
}

func TestFetchControlStatusReadsTheRefreshSummary(t *testing.T) {
	const head = `{"ok":true,"tokenConfigured":true,"tokenTag":"TAG","utcNow":"2026-07-29T12:00:00Z"`
	cases := []struct {
		name     string
		body     string
		wantNil  bool
		avail    string
		reason   string
		ceiling  string
		remote   string
		state    string
		protocol int
	}{
		{"present", head + `,"refresh":{"protocol":1,"availability":"available","ceiling":"start-if-stopped","reason":"","remote":"provisioned","state":"idle"}}`,
			false, sdkpool.RefreshAvailable, "", sdkpool.RungStartIfStopped, sdkpool.RefreshRemoteProvisioned, sdkpool.RefreshStateIdle, 1},
		{"absent", head + `}`, true, "", "", "", "", "", 0},
		{"explicit null", head + `,"refresh":null}`, true, "", "", "", "", "", 0},
		{"other protocol", head + `,"refresh":{"protocol":2,"availability":"available","ceiling":"probe","remote":"provisioned","state":"idle"}}`,
			false, sdkpool.RefreshUnavailable, sdkpool.RefreshReasonProtocolUnsupported, sdkpool.RungProbe, sdkpool.RefreshRemoteProvisioned, sdkpool.RefreshStateIdle, 2},
		{"protocol as a string", head + `,"refresh":{"protocol":"1","availability":"available","ceiling":"probe"}}`,
			false, sdkpool.RefreshUnavailable, sdkpool.RefreshReasonCapabilityMalformed, "", sdkpool.RefreshRemoteUnknown, sdkpool.RefreshStateUnknown, 0},
		{"not an object", head + `,"refresh":"available"}`,
			false, sdkpool.RefreshUnavailable, sdkpool.RefreshReasonCapabilityMalformed, "", sdkpool.RefreshRemoteUnknown, sdkpool.RefreshStateUnknown, 0},
		{"unknown availability", head + `,"refresh":{"protocol":1,"availability":"sure","ceiling":"probe","remote":"missing","state":"idle"}}`,
			false, sdkpool.RefreshUnavailable, sdkpool.RefreshReasonCapabilityMalformed, sdkpool.RungProbe, sdkpool.RefreshRemoteMissing, sdkpool.RefreshStateIdle, 1},
		{"no availability", head + `,"refresh":{"protocol":1,"ceiling":"probe"}}`,
			false, sdkpool.RefreshUnavailable, sdkpool.RefreshReasonCapabilityMalformed, "", sdkpool.RefreshRemoteUnknown, sdkpool.RefreshStateUnknown, 0},
		{"ceiling not a rung", head + `,"refresh":{"protocol":1,"availability":"unavailable","ceiling":"everything","reason":"no_qualified_rung","remote":"missing","state":"idle"}}`,
			false, sdkpool.RefreshUnavailable, "no_qualified_rung", "", sdkpool.RefreshRemoteMissing, sdkpool.RefreshStateIdle, 1},
		{"reason out of shape", head + `,"refresh":{"protocol":1,"availability":"unavailable","reason":"<script>","remote":"missing","state":"idle"}}`,
			false, sdkpool.RefreshUnavailable, sdkpool.RefreshReasonCapabilityMalformed, "", sdkpool.RefreshRemoteMissing, sdkpool.RefreshStateIdle, 1},
		{"remote and state out of vocabulary", head + `,"refresh":{"protocol":1,"availability":"available","ceiling":"reclaim","remote":"root","state":"hung"}}`,
			false, sdkpool.RefreshAvailable, "", sdkpool.RungReclaim, sdkpool.RefreshRemoteUnknown, sdkpool.RefreshStateUnknown, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := serveControlStatus(http.StatusOK, c.body)
			defer srv.Close()
			cs, err := fetchControlStatus(srv.Client(), srv.URL)
			if err != nil || !cs.Present || cs.TokenTag != "TAG" {
				t.Fatalf("the legacy fields must still read: %+v %v", cs, err)
			}
			if c.wantNil {
				if cs.Refresh != nil {
					t.Fatalf("refresh = %+v, want absent", *cs.Refresh)
				}
				return
			}
			if cs.Refresh == nil {
				t.Fatal("refresh absent")
			}
			r := *cs.Refresh
			if r.Availability != c.avail || r.Reason != c.reason || r.Ceiling != c.ceiling || r.Remote != c.remote || r.State != c.state || r.Protocol != c.protocol {
				t.Fatalf("refresh = %+v", r)
			}
		})
	}
}

// An answer past the cap is an error, not a truncation: a truncated document
// fails to parse and would otherwise leave every verdict stuck at its previous
// value.
func TestFetchControlStatusRefusesAnOversizeAnswer(t *testing.T) {
	pad := strings.Repeat("x", 5000)
	srv := serveControlStatus(http.StatusOK, `{"ok":true,"tokenConfigured":true,"tokenTag":"TAG","pad":"`+pad+`"}`)
	defer srv.Close()
	if _, err := fetchControlStatus(srv.Client(), srv.URL); err != errControlStatusOversize {
		t.Fatalf("oversize answer: err = %v, want errControlStatusOversize", err)
	}
	exact := `{"ok":true,"tokenConfigured":true,"tokenTag":"TAG","pad":"`
	exact += strings.Repeat("y", maxControlStatusBytes-len(exact)-2) + `"}`
	if len(exact) != maxControlStatusBytes {
		t.Fatalf("fixture is %d bytes", len(exact))
	}
	at := serveControlStatus(http.StatusOK, exact)
	defer at.Close()
	if cs, err := fetchControlStatus(at.Client(), at.URL); err != nil || !cs.Present {
		t.Fatalf("an answer of exactly the cap must read: %+v %v", cs, err)
	}
}

// refreshHost is a status service whose control-status answer the test swaps
// between phases, like TestPollOnceControlStickiness does for the control
// verdict.
type refreshHost struct {
	mu      sync.Mutex
	control func(http.ResponseWriter)
	srv     *httptest.Server
}

func newRefreshHost(t *testing.T) *refreshHost {
	t.Helper()
	h := &refreshHost{}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/runtime/status.json":
			fmt.Fprintf(w, `{"hostId":%q,"host":"host.ubuntu.kvm","overallStatus":"pass"}`, refreshHostID)
		case "/control/control-status":
			h.mu.Lock()
			f := h.control
			h.mu.Unlock()
			f(w)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *refreshHost) set(f func(http.ResponseWriter)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.control = f
}

func availableAnswer(w http.ResponseWriter) {
	fmt.Fprint(w, `{"ok":true,"tokenConfigured":false,"tokenTag":"","utcNow":"","refresh":{"protocol":1,"availability":"available","ceiling":"start-if-stopped","reason":"","remote":"provisioned","state":"idle"}}`)
}

func pollState(t *testing.T, h *refreshHost, now time.Time) (*poolState, *http.Client) {
	t.Helper()
	u, err := url.Parse(h.srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	s := newPoolState("default", port)
	s.hosts[refreshHostID] = &hostView{HostId: refreshHostID, CurrentIP: u.Hostname(), LastSeenUnixMs: now.UnixMilli()}
	return s, h.srv.Client()
}

// A host that answers replaces its reading; one whose control-status fails
// keeps the ceiling for display but is demoted; one that answers without the
// field is not_advertised; one that goes dark is host_unreachable; and a
// recovered host is available again. The legacy control verdict keeps its
// own stickiness beside it.
func TestPollOnceMergesTheRefreshCapability(t *testing.T) {
	now := time.Now().UTC()
	h := newRefreshHost(t)
	h.set(availableAnswer)
	s, client := pollState(t, h, now)

	s.pollOnce(client, "no-such-squid.log", "", now)
	got := s.hosts[refreshHostID].refreshView(now, s.refreshTTL)
	if got.Availability != sdkpool.RefreshAvailable || got.Ceiling != sdkpool.RungStartIfStopped || !got.RemoteUsable() || got.ObservedUnixMs != now.UnixMilli() {
		t.Fatalf("after an available answer: %+v", got)
	}

	h.set(func(w http.ResponseWriter) { w.WriteHeader(http.StatusInternalServerError) })
	s.pollOnce(client, "no-such-squid.log", "", now)
	got = s.hosts[refreshHostID].refreshView(now, s.refreshTTL)
	if got.Availability != sdkpool.RefreshUnavailable || got.Reason != sdkpool.RefreshReasonControlStatusUnreadable || got.Ceiling != sdkpool.RungStartIfStopped || got.RemoteUsable() {
		t.Fatalf("after a failed control-status read: %+v", got)
	}

	h.set(func(w http.ResponseWriter) { fmt.Fprint(w, `{"ok":true,"pad":"`+strings.Repeat("z", 5000)+`"}`) })
	s.pollOnce(client, "no-such-squid.log", "", now)
	if got = s.hosts[refreshHostID].refreshView(now, s.refreshTTL); got.Reason != sdkpool.RefreshReasonControlStatusUnreadable {
		t.Fatalf("after an oversize answer: %+v", got)
	}

	h.set(availableAnswer)
	s.pollOnce(client, "no-such-squid.log", "", now)
	h.set(func(w http.ResponseWriter) { w.WriteHeader(http.StatusNotFound) })
	s.pollOnce(client, "no-such-squid.log", "", now)
	got = s.hosts[refreshHostID].refreshView(now, s.refreshTTL)
	if got.Availability != sdkpool.RefreshUnavailable || got.Reason != sdkpool.RefreshReasonNotAdvertised {
		t.Fatalf("after a route-less answer: %+v", got)
	}

	h.set(func(w http.ResponseWriter) {
		fmt.Fprint(w, `{"ok":true,"tokenConfigured":false,"tokenTag":"","utcNow":""}`)
	})
	s.pollOnce(client, "no-such-squid.log", "", now)
	if got = s.hosts[refreshHostID].refreshView(now, s.refreshTTL); got.Reason != sdkpool.RefreshReasonNotAdvertised {
		t.Fatalf("after an answer without the field: %+v", got)
	}

	h.set(availableAnswer)
	s.pollOnce(client, "no-such-squid.log", "", now)
	h.srv.Close()
	s.pollOnce(client, "no-such-squid.log", "", now)
	hv := s.hosts[refreshHostID]
	got = hv.refreshView(now, s.refreshTTL)
	if hv.Reachable || got.Availability != sdkpool.RefreshUnavailable || got.Reason != sdkpool.RefreshReasonHostUnreachable || got.Ceiling != sdkpool.RungStartIfStopped {
		t.Fatalf("after the host went dark: reachable=%v %+v", hv.Reachable, got)
	}
}

func TestPollOnceRecoversAnAvailableCapability(t *testing.T) {
	now := time.Now().UTC()
	h := newRefreshHost(t)
	h.set(func(w http.ResponseWriter) { w.WriteHeader(http.StatusInternalServerError) })
	s, client := pollState(t, h, now)
	s.pollOnce(client, "no-such-squid.log", "", now)
	if got := s.hosts[refreshHostID].refreshView(now, s.refreshTTL); got.Availability != sdkpool.RefreshUnavailable {
		t.Fatalf("a host never read must not be available: %+v", got)
	}
	h.set(availableAnswer)
	later := now.Add(time.Minute)
	s.pollOnce(client, "no-such-squid.log", "", later)
	if got := s.hosts[refreshHostID].refreshView(later, s.refreshTTL); !got.RemoteUsable() || got.Reason != "" {
		t.Fatalf("a recovered host must read available again: %+v", got)
	}
}

// The single expiry rule: an available reading is believed for the TTL and
// not one millisecond longer; age is always stamped; the zero value reads as
// never observed.
func TestRefreshViewExpiresAnAvailableReading(t *testing.T) {
	observed := time.Unix(1900000000, 0)
	ttl := 2 * time.Minute
	hv := &hostView{Refresh: sdkpool.HostRefresh{Protocol: 1, Availability: sdkpool.RefreshAvailable, Ceiling: sdkpool.RungReclaim,
		Remote: sdkpool.RefreshRemoteProvisioned, State: sdkpool.RefreshStateIdle, ObservedUnixMs: observed.UnixMilli()}}
	if v := hv.refreshView(observed.Add(ttl), ttl); v.Availability != sdkpool.RefreshAvailable || v.AgeSeconds != 120 {
		t.Fatalf("at the TTL: %+v", v)
	}
	v := hv.refreshView(observed.Add(ttl+time.Second), ttl)
	if v.Availability != sdkpool.RefreshUnavailable || v.Reason != sdkpool.RefreshReasonObservationExpired || v.RemoteUsable() || v.AgeSeconds != 121 {
		t.Fatalf("past the TTL: %+v", v)
	}
	if hv.Refresh.Availability != sdkpool.RefreshAvailable {
		t.Fatal("refreshView must not mutate the stored reading")
	}
	if v := (&hostView{}).refreshView(observed, ttl); v != sdkpool.UnobservedRefresh() {
		t.Fatalf("zero value = %+v, want the unobserved value", v)
	}
	// A clock behind the observation is age 0, not a negative age.
	if v := hv.refreshView(observed.Add(-time.Hour), ttl); v.AgeSeconds != 0 || v.Availability != sdkpool.RefreshAvailable {
		t.Fatalf("clock behind the observation: %+v", v)
	}
}

// The window follows the poll interval upward but never below the floor.
func TestRefreshTTLDefaultsToTheFloor(t *testing.T) {
	if s := newPoolState("default", 8080); s.refreshTTL != refreshObservationFloor {
		t.Fatalf("default refreshTTL = %v, want %v", s.refreshTTL, refreshObservationFloor)
	}
	if !strings.Contains(readSource(t, "main.go"), "state.refreshTTL = max(refreshObservationFloor, 3**interval)") {
		t.Fatal("main no longer derives the refresh window from the poll interval")
	}
}

func readSource(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return string(b)
}

// pool-status keeps control as a string and adds refresh as an object, and
// nothing in it is a key, a tag, a proof or a request id.
func TestPoolStatusCarriesRefreshBesideTheControlString(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	s := newPoolState("default", 8080)
	s.authToken = token
	now := time.Now()
	s.hosts[refreshHostID] = &hostView{HostId: refreshHostID, BaseURL: "http://192.0.2.10:8080", Reachable: true, Control: controlReady,
		LastSeenUnixMs: now.UnixMilli(), Refresh: sdkpool.HostRefresh{Protocol: 1, Availability: sdkpool.RefreshAvailable,
			Ceiling: sdkpool.RungStartIfStopped, Remote: sdkpool.RefreshRemoteProvisioned, State: sdkpool.RefreshStateIdle, ObservedUnixMs: now.UnixMilli()}}
	s.hosts["42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] = &hostView{HostId: "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", BaseURL: "http://192.0.2.11:8080"}
	rec := httptest.NewRecorder()
	s.handlePoolStatus(rec, httptest.NewRequest(http.MethodGet, routePoolStatus, nil))
	body := rec.Body.String()
	var doc struct {
		Hosts []map[string]json.RawMessage `json:"hosts"`
	}
	if err := json.Unmarshal([]byte(body), &doc); err != nil || len(doc.Hosts) != 2 {
		t.Fatalf("pool-status did not parse: %v\n%s", err, body)
	}
	for _, h := range doc.Hosts {
		var control string
		if err := json.Unmarshal(h["control"], &control); err != nil && len(h["control"]) > 0 {
			t.Fatalf("control is no longer a string: %s", h["control"])
		}
		var r sdkpool.HostRefresh
		if err := json.Unmarshal(h["refresh"], &r); err != nil || r.Availability == "" {
			t.Fatalf("refresh is not an object with an availability: %s", h["refresh"])
		}
	}
	var hid string
	_ = json.Unmarshal(doc.Hosts[0]["hostId"], &hid)
	var first, second sdkpool.HostRefresh
	_ = json.Unmarshal(doc.Hosts[0]["refresh"], &first)
	_ = json.Unmarshal(doc.Hosts[1]["refresh"], &second)
	if hid != refreshHostID || !first.RemoteUsable() || second.Reason != sdkpool.RefreshReasonNeverObserved {
		t.Fatalf("refresh entries: %s %+v %+v", hid, first, second)
	}
	for _, secret := range []string{token, controlTagFor(token), "yhr", "requestId"} {
		if strings.Contains(body, secret) {
			t.Fatalf("pool-status carries %q", secret)
		}
	}
}

var refreshGaugeRE = regexp.MustCompile(`(?m)^yuruna_pool_host_refresh_available\{pool="[^"]*",hostId="([^"]*)",hostIdDashed="[^"]*",state="([^"]*)"\} (\d+)$`)

// Garbage from fifty hosts cannot grow the series: the gauge carries only the
// four states and a 0/1 value, and host_info's label set is untouched.
func TestRefreshGaugeCardinalityIsBounded(t *testing.T) {
	s := newPoolState("default", 8080)
	now := time.Now()
	for i := 0; i < 50; i++ {
		id := fmt.Sprintf("42%030x", i)
		s.hosts[id] = &hostView{HostId: id, BaseURL: "http://192.0.2.1:8080", LastSeenUnixMs: now.UnixMilli(),
			Refresh: sdkpool.HostRefresh{Protocol: 1, Availability: []string{sdkpool.RefreshAvailable, "garbage-" + strconv.Itoa(i)}[i%2],
				Ceiling: sdkpool.RungProbe, State: fmt.Sprintf("state-%d\"}", i), ObservedUnixMs: now.UnixMilli()}}
	}
	s.hosts["42ffffffffffffffffffffffffffffff"] = &hostView{HostId: "42ffffffffffffffffffffffffffffff", LastSeenUnixMs: now.UnixMilli(),
		Refresh: sdkpool.HostRefresh{Protocol: 1, Availability: sdkpool.RefreshAvailable, Ceiling: sdkpool.RungProbe,
			State: sdkpool.RefreshStateRecoveryPending, ObservedUnixMs: now.UnixMilli()}}
	rec := httptest.NewRecorder()
	s.handleMetrics(rec, metricsRequest())
	body := rec.Body.String()
	rows := refreshGaugeRE.FindAllStringSubmatch(body, -1)
	if len(rows) != 51 {
		t.Fatalf("%d refresh gauge rows, want 51\n%s", len(rows), body)
	}
	states := map[string]bool{}
	ones := 0
	for _, m := range rows {
		states[m[2]] = true
		switch m[3] {
		case "1":
			ones++
		case "0":
		default:
			t.Fatalf("gauge value %q is not 0 or 1", m[3])
		}
	}
	allowed := map[string]bool{"idle": true, "active": true, "recovery_pending": true, "unknown": true}
	for st := range states {
		if !allowed[st] {
			t.Fatalf("state label %q escaped the vocabulary", st)
		}
	}
	if !states["recovery_pending"] || ones != 26 {
		t.Fatalf("states %v, %d available rows (want 26)", sortedStates(states), ones)
	}
	info := regexp.MustCompile(`(?m)^yuruna_pool_host_info\{([^}]*)\}`).FindStringSubmatch(body)
	if info == nil {
		t.Fatal("no host_info row")
	}
	var keys []string
	for _, kv := range regexp.MustCompile(`(\w+)="`).FindAllStringSubmatch(info[1], -1) {
		keys = append(keys, kv[1])
	}
	want := "pool,poolGuid,hostId,hostIdDashed,hostType,version,commit,commitUrl,projectCommitUrl,baseUrl,cycleStartUtc,cycleFolderUrl,status,control"
	if strings.Join(keys, ",") != want {
		t.Fatalf("host_info labels changed:\n got  %s\n want %s", strings.Join(keys, ","), want)
	}
}

// The redirects keep minting only legacy proofs, nothing here mints or serves a
// refresh proof, and the lab-token exchange still hands out only the legacy
// key.
func TestTheAggregatorMintsNoRefreshAuthority(t *testing.T) {
	s := newPoolState("default", 8080)
	s.authToken = proofToken
	s.hosts[refreshHostID] = &hostView{HostId: refreshHostID, BaseURL: "http://192.0.2.10:8080", CurrentIP: "192.0.2.10",
		Reachable: true, LastSeenUnixMs: time.Now().UnixMilli(), ExtensionTargets: map[string]string{"stash-service": "http://192.0.2.12"}}
	seedExtensionHealth(s, refreshHostID, stashArea, "http://192.0.2.12")
	fragment := regexp.MustCompile(`#yctl=[0-9]+\.[A-Za-z0-9+/]+=*$`)
	for _, target := range []string{"/go/host?host=" + refreshHostID, "/go/stash?host=" + refreshHostID} {
		rec := httptest.NewRecorder()
		if strings.HasPrefix(target, "/go/host") {
			s.handleGoHost(rec, httptest.NewRequest(http.MethodGet, target, nil))
		} else {
			s.handleGoStash(rec, httptest.NewRequest(http.MethodGet, target, nil))
		}
		loc := rec.Header().Get("Location")
		if rec.Code != http.StatusFound || !fragment.MatchString(loc) || strings.Contains(loc, "yhr") {
			t.Fatalf("%s: %d Location %q", target, rec.Code, loc)
		}
		_, proof, _ := strings.Cut(loc, "#yctl=")
		if !verifyControlProof(proofToken, proof, time.Now(), controlProofMaxTTL) {
			t.Fatalf("%s: the fragment is not a legacy proof this daemon accepts", target)
		}
	}

	ls := newLabState("abc123")
	rec := postLabToken(ls, "10.0.0.7:5555", `{"labToken":"abc123"}`)
	var env labEnvelope
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatal(err)
	}
	opened, err := openLabEnvelope(t, "abc123", env)
	if err != nil || opened != ls.authToken || strings.HasPrefix(opened, "yhr") {
		t.Fatalf("the exchange opened %q (%v), want only the legacy key", opened, err)
	}

	// The mux is assembled in main(), so the registrations are read from the
	// source: no route mints, verifies or forwards a refresh credential, and
	// the refresh package is not linked into this daemon at all.
	for _, name := range []string{"main.go", "mcp.go"} {
		src := readSource(t, name)
		if strings.Contains(src, "extension-sdk/hostrefresh") || strings.Contains(src, `"yhr`) {
			t.Fatalf("%s links or spells refresh authority material", name)
		}
		for _, line := range strings.Split(src, "\n") {
			if strings.Contains(line, "mux.HandleFunc(") && strings.Contains(strings.ToLower(line), "refresh") {
				t.Fatalf("%s registers a refresh route: %s", name, strings.TrimSpace(line))
			}
		}
	}
}

// The versioned refresh wire from the shared vector file is refused by this
// daemon's legacy verifier under the very token that derives its key.
func TestLegacyVerifierRefusesTheSharedRefreshVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "extension-sdk", "hostrefresh", "testdata", "vectors.json"))
	if err != nil {
		t.Fatalf("read shared vectors: %v", err)
	}
	var v struct {
		Legacy struct {
			Token, Wire  string
			ExpiryUnix   int64 `json:"expiryUnix"`
			VerifyAtUnix int64 `json:"verifyAtUnix"`
		} `json:"legacy"`
		Versioned struct {
			Wire string `json:"wire"`
		} `json:"versioned"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if got := controlProofFor(v.Legacy.Token, v.Legacy.ExpiryUnix); got != v.Legacy.Wire {
		t.Fatalf("the legacy mint drifted from the shared vector: %s", got)
	}
	at := time.Unix(v.Legacy.VerifyAtUnix, 0)
	if !verifyControlProof(v.Legacy.Token, v.Legacy.Wire, at, controlProofMaxTTL) {
		t.Fatal("the shared legacy vector must verify here")
	}
	if verifyControlProof(v.Legacy.Token, v.Versioned.Wire, at, controlProofMaxTTL) {
		t.Fatal("the legacy verifier accepted a refresh proof")
	}
}

// Sorted state names so a failure message is stable.
func sortedStates(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
