// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package labgate

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// labCode is a code shaped exactly like one the dashboard tile shows.
const labCode = "k3f9qz"

// fakeAggregator stands in for the pool-aggregator's /api/v1/lab-token route:
// the same statuses, the same opaque sealed body, and no live network.
type fakeAggregator struct {
	srv *httptest.Server

	mu     sync.Mutex
	asked  []string
	accept string
	status int
}

func newFakeAggregator(t *testing.T, accept string) *fakeAggregator {
	t.Helper()
	a := &fakeAggregator{accept: accept}
	a.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != labTokenPath || r.Method != http.MethodPost {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		var req struct {
			LabToken string `json:"labToken"`
		}
		b, _ := io.ReadAll(io.LimitReader(r.Body, 1<<10))
		_ = json.Unmarshal(b, &req)
		a.mu.Lock()
		a.asked = append(a.asked, req.LabToken)
		forced, accepted := a.status, a.accept
		a.mu.Unlock()

		switch {
		case forced != 0:
			http.Error(w, "forced", forced)
		case req.LabToken != accepted:
			// What the aggregator answers for a code it is not showing.
			http.Error(w, "unknown or expired lab token", http.StatusForbidden)
		default:
			// The real answer is an envelope sealed under the submitted code.
			// This one is deliberately unopenable: the verdict has to come from
			// the status alone.
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"ok":true,"v":1,"salt":"AA==","nonce":"AA==","ciphertext":"AA==","tag":"AA=="}`)
		}
	}))
	t.Cleanup(a.srv.Close)
	return a
}

func (a *fakeAggregator) calls() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]string(nil), a.asked...)
}

func (a *fakeAggregator) force(status int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.status = status
}

// gated builds a test server exposing a login route and one mutating route
// behind the gate, which is the whole contract a service consumes.
func gated(t *testing.T, opts Options) (*httptest.Server, *Gate) {
	t.Helper()
	g := New(opts)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/login", g.HandleLogin)
	mux.HandleFunc("GET /api/session", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, g.Session(r))
	})
	mux.HandleFunc("POST /api/mutate", g.Require(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "mutated": true})
	}))
	mux.HandleFunc("POST /api/pool-wide", g.RequireBearer(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	}))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, g
}

func login(t *testing.T, srv *httptest.Server, code string) *http.Response {
	t.Helper()
	resp, err := srv.Client().Post(srv.URL+"/api/login", "application/json",
		strings.NewReader(`{"labToken":`+strconv.Quote(code)+`}`))
	if err != nil {
		t.Fatalf("POST /api/login: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func mutate(t *testing.T, srv *httptest.Server, path string, cookies []*http.Cookie, bearer string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+path, nil)
	if err != nil {
		t.Fatalf("build %s: %v", path, err)
	}
	for _, c := range cookies {
		req.AddCookie(c)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestAValidLabTokenGrantsASessionForTheGatedRoutes(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	srv, _ := gated(t, Options{AggregatorURL: agg.srv.URL})

	if r := mutate(t, srv, "/api/mutate", nil, ""); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no session = %d, want 401", r.StatusCode)
	}
	resp := login(t, srv, labCode)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login with the displayed code = %d, want 200", resp.StatusCode)
	}
	cookies := resp.Cookies()
	if len(cookies) == 0 {
		t.Fatal("login minted no session cookie")
	}
	if got := agg.calls(); len(got) != 1 || got[0] != labCode {
		t.Fatalf("aggregator was asked %v, want exactly [%s]", got, labCode)
	}
	if r := mutate(t, srv, "/api/mutate", cookies, ""); r.StatusCode != http.StatusOK {
		t.Fatalf("with the session = %d, want 200", r.StatusCode)
	}
}

func TestTheSubmittedCodeIsNormalisedBeforeItLeaves(t *testing.T) {
	// An operator reading the tile types what they see, including its case.
	agg := newFakeAggregator(t, labCode)
	srv, _ := gated(t, Options{AggregatorURL: agg.srv.URL})

	if r := login(t, srv, "  "+strings.ToUpper(labCode)+" \n"); r.StatusCode != http.StatusOK {
		t.Fatalf("login with an upper-cased, padded code = %d, want 200", r.StatusCode)
	}
	if got := agg.calls(); len(got) != 1 || got[0] != labCode {
		t.Fatalf("aggregator was asked %v, want the normalised [%s]", got, labCode)
	}
}

func TestARejectedLabTokenAnswers401(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	srv, _ := gated(t, Options{AggregatorURL: agg.srv.URL})

	resp := login(t, srv, "zzzzzz")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("login with a wrong code = %d, want 401", resp.StatusCode)
	}
	if len(resp.Cookies()) != 0 {
		t.Fatal("a refused login minted a cookie")
	}
}

// "Could not check" is not "wrong code": the gate stays shut either way, but the
// answer says which, or an operator retypes a correct code until they give up.
func TestAnUnavailableAggregatorFailsClosedNamingTheReason(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	agg.force(http.StatusServiceUnavailable)
	srv, _ := gated(t, Options{AggregatorURL: agg.srv.URL})

	resp := login(t, srv, labCode)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("login against a broken validator = %d, want 503", resp.StatusCode)
	}
	var body struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if body.Reason != ReasonUnavailable {
		t.Fatalf("reason = %q, want %q", body.Reason, ReasonUnavailable)
	}
}

func TestAMalformedLabTokenNeverReachesTheAggregator(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	srv, _ := gated(t, Options{AggregatorURL: agg.srv.URL})

	if r := login(t, srv, "not-a-code"); r.StatusCode != http.StatusBadRequest {
		t.Fatalf("login with a malformed code = %d, want 400", r.StatusCode)
	}
	if got := agg.calls(); len(got) != 0 {
		t.Fatalf("aggregator was asked %v, want nothing -- a typo must not spend the lab's shared attempts", got)
	}
}

func TestTheServiceThrottlesPerClientRatherThanLeaningOnTheAggregator(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	srv, _ := gated(t, Options{AggregatorURL: agg.srv.URL})

	for i := 0; i < MaxFailedAttempts; i++ {
		if r := login(t, srv, "zzzzzz"); r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("attempt %d = %d, want 401", i, r.StatusCode)
		}
	}
	if r := login(t, srv, labCode); r.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("attempt past the cap = %d, want 429 even for the correct code", r.StatusCode)
	}
}

func TestFailedLoginsNeverAccumulateAPermanentEntryPerSource(t *testing.T) {
	g := New(Options{AggregatorURL: "http://aggregator"})
	stale := time.Now().Add(-2 * FailWindow)
	g.fails["10.0.0.1"] = []time.Time{stale}
	g.fails["10.0.0.2"] = []time.Time{stale}

	g.recordFail("10.0.0.3")

	if _, ok := g.fails["10.0.0.1"]; ok {
		t.Error("a source whose attempts all expired kept its map entry")
	}
	if _, ok := g.fails["10.0.0.2"]; ok {
		t.Error("the sweep only pruned the source being recorded")
	}
	if len(g.fails["10.0.0.3"]) != 1 {
		t.Errorf("the live attempt was not recorded: %v", g.fails["10.0.0.3"])
	}
}

func TestThrottlingStillCountsLiveAttempts(t *testing.T) {
	g := New(Options{AggregatorURL: "http://aggregator"})
	for i := 0; i < MaxFailedAttempts; i++ {
		g.recordFail("10.0.0.9")
	}
	if !g.throttled("10.0.0.9") {
		t.Error("a source at the cap is not throttled")
	}
	if g.throttled("10.0.0.8") {
		t.Error("an unrelated source is throttled")
	}
}

// Automation carries the bearer instead of a session; both open the same routes.
func TestTheBearerOpensTheSameRoutes(t *testing.T) {
	srv, _ := gated(t, Options{BearerToken: "shared-lab-auth-token"})

	if r := mutate(t, srv, "/api/mutate", nil, ""); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no credential = %d, want 401", r.StatusCode)
	}
	if r := mutate(t, srv, "/api/mutate", nil, "wrong"); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong bearer = %d, want 401", r.StatusCode)
	}
	if r := mutate(t, srv, "/api/mutate", nil, "shared-lab-auth-token"); r.StatusCode != http.StatusOK {
		t.Fatalf("correct bearer = %d, want 200", r.StatusCode)
	}
}

// A pool-wide route takes the bearer alone: one unlocked phone must not be able
// to start work on every host in the lab.
func TestRequireBearerRefusesASession(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	srv, _ := gated(t, Options{AggregatorURL: agg.srv.URL, BearerToken: "shared-lab-auth-token"})

	cookies := login(t, srv, labCode).Cookies()
	if r := mutate(t, srv, "/api/mutate", cookies, ""); r.StatusCode != http.StatusOK {
		t.Fatalf("session on the per-service route = %d, want 200", r.StatusCode)
	}
	if r := mutate(t, srv, "/api/pool-wide", cookies, ""); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("session on the pool-wide route = %d, want 401", r.StatusCode)
	}
	if r := mutate(t, srv, "/api/pool-wide", nil, "shared-lab-auth-token"); r.StatusCode != http.StatusOK {
		t.Fatalf("bearer on the pool-wide route = %d, want 200", r.StatusCode)
	}
}

// With nothing configured a mutation is refused with a machine-readable reason
// -- never allowed through because there is no gate to fail.
func TestAnUnconfiguredGateRefusesEveryMutation(t *testing.T) {
	srv, g := gated(t, Options{})
	if g.Configured() {
		t.Fatal("a gate with neither credential reports itself configured")
	}
	resp := mutate(t, srv, "/api/mutate", nil, "")
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("mutation with no gate configured = %d, want 503", resp.StatusCode)
	}
	var body struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if body.Reason != ReasonUnconfigured {
		t.Fatalf("reason = %q, want %q", body.Reason, ReasonUnconfigured)
	}
}

// An expired or forged cookie is not a session, and a cookie signed by ANOTHER
// gate's key never opens this one.
func TestSessionCookiesAreSignedAndExpiring(t *testing.T) {
	g := New(Options{AggregatorURL: "http://aggregator"})
	now := time.Now()

	if !g.validSession(g.mint(now), now) {
		t.Error("a freshly minted session did not validate")
	}
	if g.validSession(g.mint(now), now.Add(DefaultSessionTTL+time.Minute)) {
		t.Error("an expired session validated")
	}
	if g.validSession("9999999999.deadbeef", now) {
		t.Error("a forged signature validated")
	}
	other := New(Options{AggregatorURL: "http://aggregator"})
	if g.validSession(other.mint(now), now) {
		t.Error("a session minted by another gate validated")
	}
}

func TestSessionReportsWhichWaysInExist(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/session", nil)

	none := New(Options{}).Session(req)
	if none.Configured || none.LabToken || none.Bearer || none.MutationsOpen {
		t.Errorf("unconfigured session = %+v, want every way in false", none)
	}
	both := New(Options{AggregatorURL: "http://aggregator", BearerToken: "t"}).Session(req)
	if !both.Configured || !both.LabToken || !both.Bearer {
		t.Errorf("fully configured session = %+v, want both ways in true", both)
	}
	if both.Authed || both.MutationsOpen {
		t.Errorf("a request with no credential reported authed: %+v", both)
	}
}

func TestClientIPUnwrapsTheSourceAddress(t *testing.T) {
	// The throttling key has to be the address itself: brackets left on an IPv6
	// literal, or a port-less address chopped at a colon inside that literal,
	// give the same peer more than one bucket to spend attempts from.
	cases := map[string]string{
		"192.0.2.7:54321":     "192.0.2.7",
		"[2001:db8::1]:54321": "2001:db8::1",
		"[2001:db8::1]:54322": "2001:db8::1",
		"192.0.2.7":           "192.0.2.7",
		"2001:db8::1":         "2001:db8::1",
	}
	for remote, want := range cases {
		if got := ClientIP(&http.Request{RemoteAddr: remote}); got != want {
			t.Errorf("ClientIP(%q) = %q, want %q", remote, got, want)
		}
	}
}

func TestAuditSeesEveryUnlockAttempt(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	var mu sync.Mutex
	var outcomes []string
	srv, _ := gated(t, Options{
		AggregatorURL: agg.srv.URL,
		Audit: func(_, outcome, _ string) {
			mu.Lock()
			outcomes = append(outcomes, outcome)
			mu.Unlock()
		},
	})

	login(t, srv, "zzzzzz")
	login(t, srv, labCode)

	mu.Lock()
	defer mu.Unlock()
	if len(outcomes) != 2 || outcomes[0] != "refused" || outcomes[1] != "ok" {
		t.Fatalf("audited outcomes = %v, want [refused ok]", outcomes)
	}
}
