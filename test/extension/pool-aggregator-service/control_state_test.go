// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestControlTagGolden pins the cross-language control-TAG format, the way
// TestMintControlProofGolden pins the proof. The vector is shared with
// Test.ConfigServiceSync\Get-YurunaControlTag: both ends must derive the same
// tag from the same token, or every host would read as "mismatch" and the
// dashboard would claim the whole pool is onsite-only. A failure means the HMAC
// key/data string or the base64 flavor has drifted between Go and PowerShell.
func TestControlTagGolden(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const want = "cCF1hq19qKkDIatix94HUWPtVrMYO3lw5YZetYYqLF4="
	if got := controlTagFor(token); got != want {
		t.Fatalf("control tag mismatch (Go must match PowerShell Get-YurunaControlTag):\n got  %q\n want %q", got, want)
	}
}

// TestControlTagDomainSeparated: the tag must not be derivable as a proof, nor a
// proof as a tag. Reading a host's published tag is what an unauthenticated LAN
// client can do; it must not hand them anything the control gate would accept.
func TestControlTagDomainSeparated(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	tag := controlTagFor(token)
	// A proof's wire form is "<expiry>.<hmac>"; the tag is a bare HMAC over a
	// message no expiry can produce. Scan a wide expiry range rather than
	// asserting the formats merely look different.
	for _, exp := range []int64{0, 1, 1900000000, 1<<31 - 1} {
		proof := controlProofFor(token, exp)
		if strings.Contains(proof, tag) {
			t.Fatalf("tag appears inside the proof for expiry %d: tag %q proof %q", exp, tag, proof)
		}
	}
	if controlTagFor("") != "" {
		t.Fatal("no token must yield no tag (nothing to publish)")
	}
}

// TestClassifyControl walks every state the Control column can show. The skew
// rows are the ones worth pinning: the accepted band is asymmetric (a host may
// run ahead by the whole mint but trail by only the verifier's surplus over it),
// and getting that backwards would report a working host as onsite-only.
func TestClassifyControl(t *testing.T) {
	const proxyTag = "PROXY-TAG"
	now := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	ok := func(tag string, clock time.Time) controlStatus {
		return controlStatus{Present: true, TokenConfigured: true, TokenTag: tag, UtcNow: clock}
	}
	cases := []struct {
		name  string
		proxy string
		cs    controlStatus
		want  string
	}{
		{"matching token and clock", proxyTag, ok(proxyTag, now), controlReady},
		{"route absent (older build)", proxyTag, controlStatus{}, controlUnknown},
		{"proxy holds no token", "", ok(proxyTag, now), controlUnknown},
		{"host holds no token", proxyTag, controlStatus{Present: true}, controlNone},
		{"host reports empty tag", proxyTag, ok("", now), controlNone},
		{"different token", proxyTag, ok("OTHER-TAG", now), controlMismatch},
		{"no clock reported", proxyTag, ok(proxyTag, time.Time{}), controlReady},
		// Band edges: [-(MaxTTL-TTL), +TTL] == [-5m, +15m] around the proxy clock.
		{"host trails by the whole surplus", proxyTag, ok(proxyTag, now.Add(-5 * time.Minute)), controlReady},
		{"host trails past the surplus", proxyTag, ok(proxyTag, now.Add(-5*time.Minute-time.Second)), controlSkew},
		{"host leads by the whole mint", proxyTag, ok(proxyTag, now.Add(15 * time.Minute)), controlReady},
		{"host leads past the mint", proxyTag, ok(proxyTag, now.Add(15*time.Minute+time.Second)), controlSkew},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := classifyControl(c.proxy, c.cs, now); got != c.want {
				t.Fatalf("classifyControl = %q, want %q", got, c.want)
			}
		})
	}
}

// TestFetchControlStatus covers the three answers that mean different things
// downstream: a usable reading, a host that predates the route (404 -- an
// ANSWER, so the caller must overwrite a stale verdict with "unknown"), and a
// broken one (error -- so the caller keeps what it last knew).
func TestFetchControlStatus(t *testing.T) {
	serve := func(code int, body string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/control/control-status" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.WriteHeader(code)
			fmt.Fprint(w, body)
		}))
	}

	srv := serve(http.StatusOK, `{"ok":true,"tokenConfigured":true,"tokenTag":"TAG","utcNow":"2026-07-29T12:00:00Z"}`)
	defer srv.Close()
	cs, err := fetchControlStatus(srv.Client(), srv.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cs.Present || !cs.TokenConfigured || cs.TokenTag != "TAG" {
		t.Fatalf("unexpected reading: %+v", cs)
	}
	if want := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC); !cs.UtcNow.Equal(want) {
		t.Fatalf("utcNow = %v, want %v", cs.UtcNow, want)
	}

	old := serve(http.StatusNotFound, "not found")
	defer old.Close()
	if cs, err := fetchControlStatus(old.Client(), old.URL); err != nil || cs.Present {
		t.Fatalf("404 must report a definite absence without an error, got %+v err=%v", cs, err)
	}

	broken := serve(http.StatusInternalServerError, "boom")
	defer broken.Close()
	if _, err := fetchControlStatus(broken.Client(), broken.URL); err == nil {
		t.Fatal("a 500 must be an error so the caller keeps the prior verdict")
	}

	// An unparseable clock is not evidence of skew: the reading still stands,
	// with UtcNow left zero for classifyControl to skip.
	noClock := serve(http.StatusOK, `{"ok":true,"tokenConfigured":true,"tokenTag":"TAG","utcNow":"not-a-time"}`)
	defer noClock.Close()
	cs, err = fetchControlStatus(noClock.Client(), noClock.URL)
	if err != nil || !cs.Present || !cs.UtcNow.IsZero() {
		t.Fatalf("bad clock must leave UtcNow zero without failing the read, got %+v err=%v", cs, err)
	}
}

// TestPollOnceControlStickiness pins the rule that decides whether a Control
// cell may go stale. A host that ANSWERS replaces its verdict -- including the
// 404 an older build gives, which must demote "remote" to "unknown" rather than
// leave a promise the dashboard can no longer support. A host that does not
// answer at all keeps what it last knew: the row already says "unreachable", and
// blanking the verdict on every network blip would make the column flicker.
func TestPollOnceControlStickiness(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	now := time.Now().UTC()

	// The control-status handler is swapped between phases to model a host being
	// upgraded, downgraded, or going dark, without moving the status service. It
	// is read on the server's goroutine and written on the test's, so the mutex
	// is what keeps `go test -race` honest.
	var mu sync.Mutex
	serveControl := func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"ok":true,"tokenConfigured":true,"tokenTag":%q,"utcNow":%q}`,
			controlTagFor(token), now.Format(time.RFC3339))
	}
	setControl := func(f func(http.ResponseWriter, *http.Request)) {
		mu.Lock()
		defer mu.Unlock()
		serveControl = f
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/runtime/status.json":
			fmt.Fprintf(w, `{"hostId":%q,"host":"host.ubuntu.kvm","overallStatus":"pass"}`, hid)
		case "/control/control-status":
			mu.Lock()
			f := serveControl
			mu.Unlock()
			f(w, r)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	// Point the collector at the test server: it probes http://<ip>:<statusPort>,
	// so the seeded IP plus the server's port is what makes the host discoverable.
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatalf("cannot parse the test server URL %q: %v", srv.URL, err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatalf("cannot read the test server port from %q: %v", srv.URL, err)
	}
	host := u.Hostname()
	s := newPoolState("default", port)
	s.authToken = token
	s.hosts[hid] = &hostView{HostId: hid, CurrentIP: host, LastSeenUnixMs: now.UnixMilli()}
	client := srv.Client()

	s.pollOnce(client, "no-such-squid.log", "", now)
	if got := s.hosts[hid].Control; got != controlReady {
		t.Fatalf("a host sharing the proxy's token must read %q, got %q", controlReady, got)
	}

	// The host is downgraded to a build without the route: it answered, so the
	// stale "ready" must not survive.
	setControl(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) })
	s.pollOnce(client, "no-such-squid.log", "", now)
	if got := s.hosts[hid].Control; got != controlUnknown {
		t.Fatalf("a route-less host must demote to %q, got %q", controlUnknown, got)
	}

	// Back on a current build, then dark: the last known verdict is kept.
	setControl(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"ok":true,"tokenConfigured":false,"tokenTag":"","utcNow":%q}`, now.Format(time.RFC3339))
	})
	s.pollOnce(client, "no-such-squid.log", "", now)
	if got := s.hosts[hid].Control; got != controlNone {
		t.Fatalf("an un-enrolled host must read %q, got %q", controlNone, got)
	}
	srv.Close()
	s.pollOnce(client, "no-such-squid.log", "", now)
	if hv := s.hosts[hid]; hv.Reachable || hv.Control != controlNone {
		t.Fatalf("an unreachable host must keep its last verdict, got reachable=%v control=%q", hv.Reachable, hv.Control)
	}
}

// TestHostInfoControlLabelNeverCarriesTheTag is the security regression guard.
// /metrics is unauthenticated by design, so the comparison must stay inside the
// process: the STATE may be exported, the token tag it was derived from may not.
func TestHostInfoControlLabelNeverCarriesTheTag(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	s := newPoolState("default", 8080)
	s.authToken = token
	hv := &hostView{HostId: "4253419c", BaseURL: "http://192.168.7.13:8080", Reachable: true, Control: controlReady}
	hv.Status = &hostStatus{HostId: "4253419c", Host: "host.windows.hyper-v", CycleStartUtc: "c1", OverallStatus: "pass"}
	s.hosts[hv.HostId] = hv
	// A second host that was never asked: it must read "unknown", not inherit
	// the first host's verdict and not silently read as un-enrolled.
	s.hosts["b0b0b0b0"] = &hostView{HostId: "b0b0b0b0", BaseURL: "http://192.168.7.14:8080"}

	w := httptest.NewRecorder()
	s.handleMetrics(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := w.Body.String()

	if !strings.Contains(body, `hostId="4253419c"`) || !strings.Contains(body, `control="ready"`) {
		t.Fatalf("host_info missing the control label\n%s", body)
	}
	if !strings.Contains(body, `control="unknown"`) {
		t.Fatalf("a never-probed host must export control=\"unknown\"\n%s", body)
	}
	for _, secret := range []string{token, controlTagFor(token)} {
		if strings.Contains(body, secret) {
			t.Fatalf("token material leaked into /metrics: %q", secret)
		}
	}
}
