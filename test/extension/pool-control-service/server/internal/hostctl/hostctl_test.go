// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package hostctl

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"yuruna.com/test/extension/extension-sdk/hostrefresh"
)

// TestProofGolden pins the cross-language control-proof format against the same
// vector the aggregator (Go) and Test.ConfigServiceSync\Get-YurunaControlProof
// (PowerShell) hold. A proof this package mints is verified by the PowerShell
// side on every host, so a drift in the HMAC key/data, the base64 flavor or the
// "<expiry>.<proof>" framing would refuse pool-wide control everywhere at once
// -- and would do it with a plain 403, which reads like an unenrolled lab.
func TestProofGolden(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const expiry int64 = 1900000000
	const want = "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs="
	if got := Proof(token, expiry); got != want {
		t.Fatalf("control proof mismatch (must match the aggregator and the host verifier):\n got  %q\n want %q", got, want)
	}
}

// A service holding no token mints nothing: the caller then has to obtain a
// proof elsewhere, and an empty string must never be sent as one.
func TestMintWithoutTokenYieldsNothing(t *testing.T) {
	for _, token := range []string{"", "   "} {
		if got := Mint(token, ProofTTL); got != "" {
			t.Errorf("Mint(%q) = %q, want empty", token, got)
		}
	}
	if Mint("t", ProofTTL) == "" {
		t.Error("Mint with a token returned nothing")
	}
}

// hostStub records every control route it is called on, with the headers.
type hostStub struct {
	mu     sync.Mutex
	calls  []string
	header http.Header
	status int
	body   string
	// statusJSON is what /runtime/status.json serves.
	statusJSON string
	srv        *httptest.Server
}

func newHostStub(t *testing.T) *hostStub {
	t.Helper()
	h := &hostStub{status: http.StatusOK, body: `{"ok":true}`, statusJSON: `{"stepPaused":false,"cyclePaused":false}`}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/runtime/status.json" {
			_, _ = w.Write([]byte(h.statusJSON))
			return
		}
		h.mu.Lock()
		h.calls = append(h.calls, strings.TrimPrefix(r.URL.Path, "/control/"))
		h.header = r.Header.Clone()
		status, body := h.status, h.body
		h.mu.Unlock()
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *hostStub) recorded() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.calls...)
}

// Each action leaves exactly ONE switch armed, and arms it before clearing the
// other. The two switches are independent files on the host, so an Apply that
// only set its own would leave a host that had been armed both ways sitting in
// a state the pool selector cannot name -- and the armed-first order means a
// call that dies between the two writes overshoots into MORE paused, never
// into a host that quietly carried on.
func TestApplyArmsExactlyOneSwitch(t *testing.T) {
	cases := map[string][]string{
		ActionContinue:        {"cycle-resume", "step-resume"},
		ActionPauseAfterCycle: {"cycle-pause", "step-resume"},
		ActionPauseAfterStep:  {"step-pause", "cycle-resume"},
	}
	for action, want := range cases {
		t.Run(action, func(t *testing.T) {
			host := newHostStub(t)
			if err := New(Options{}).Apply(context.Background(), host.srv.URL, action, "proof"); err != nil {
				t.Fatalf("Apply: %v", err)
			}
			got := host.recorded()
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Errorf("routes called = %v, want %v", got, want)
			}
		})
	}
}

// The host requires both headers on a mutating control route: X-Yuruna is its
// cross-site request guard and X-Yuruna-Control carries the proof. Sending one
// without the other is refused, so both are asserted here rather than assuming
// a 200 means they were right.
func TestApplyCarriesGuardAndProof(t *testing.T) {
	host := newHostStub(t)
	proof := Proof("token", 1900000000)
	if err := New(Options{}).Apply(context.Background(), host.srv.URL, ActionPauseAfterStep, proof); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if got := host.header.Get("X-Yuruna"); got != "1" {
		t.Errorf("X-Yuruna = %q, want \"1\"", got)
	}
	if got := host.header.Get("X-Yuruna-Control"); got != proof {
		t.Errorf("X-Yuruna-Control = %q, want %q", got, proof)
	}
}

// Nothing is sent without a proof: the host would refuse it, and a fan-out that
// spent a round trip per member to collect identical 403s would report a lab
// full of broken hosts instead of one unconfigured service.
func TestApplyWithoutProofSendsNothing(t *testing.T) {
	host := newHostStub(t)
	err := New(Options{}).Apply(context.Background(), host.srv.URL, ActionContinue, "  ")
	if !errors.Is(err, ErrNoProof) {
		t.Fatalf("error = %v, want ErrNoProof", err)
	}
	if got := host.recorded(); len(got) != 0 {
		t.Errorf("routes called = %v, want none", got)
	}
}

// A refusal keeps its machine-readable reason and turns it into the fix. Every
// one of these arrives as the same 403, and they need completely different
// actions from the operator.
func TestRefusalReasonBecomesTheFix(t *testing.T) {
	cases := map[string]string{
		"host-token-missing": "Set-LabToken",
		"proof-invalid":      "different lab token",
		"proof-expired":      "clock",
	}
	for reason, want := range cases {
		t.Run(reason, func(t *testing.T) {
			host := newHostStub(t)
			host.status = http.StatusForbidden
			host.body = `{"ok":false,"reason":"` + reason + `","error":"follow guidance at https://yuruna.link/42185271-0007"}`
			err := New(Options{}).Apply(context.Background(), host.srv.URL, ActionContinue, "proof")
			if err == nil {
				t.Fatal("a 403 was reported as success")
			}
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error %q does not name the fix (%q)", err.Error(), want)
			}
			var hostErr *Error
			if !errors.As(err, &hostErr) || hostErr.Reason != reason {
				t.Errorf("reason not carried: %#v", err)
			}
		})
	}
}

// A refusal with no reason still reports the host's own message rather than a
// bare status: an older status service predating the reason field is the case.
func TestRefusalWithoutReasonKeepsTheMessage(t *testing.T) {
	host := newHostStub(t)
	host.status = http.StatusForbidden
	host.body = `{"ok":false,"error":"forbidden: missing X-Yuruna request header (cross-site request guard)"}`
	err := New(Options{}).Apply(context.Background(), host.srv.URL, ActionContinue, "proof")
	if err == nil || !strings.Contains(err.Error(), "cross-site request guard") {
		t.Fatalf("error = %v, want the host's own message", err)
	}
}

// The read maps the two independent flags onto the three states an operator
// picks between -- plus "both", which only a person standing at the host's own
// page (one button per switch) can produce.
func TestStateMapsBothFlags(t *testing.T) {
	cases := map[string]string{
		`{"stepPaused":false,"cyclePaused":false}`: ActionContinue,
		`{"stepPaused":false,"cyclePaused":true}`:  ActionPauseAfterCycle,
		`{"stepPaused":true,"cyclePaused":false}`:  ActionPauseAfterStep,
		`{"stepPaused":true,"cyclePaused":true}`:   StateBoth,
		// A status document from a runner that never wrote the fields at all.
		`{"overallStatus":"idle"}`: ActionContinue,
	}
	for doc, want := range cases {
		host := newHostStub(t)
		host.statusJSON = doc
		got, err := New(Options{}).State(context.Background(), host.srv.URL)
		if err != nil {
			t.Fatalf("State(%s): %v", doc, err)
		}
		if got != want {
			t.Errorf("State(%s) = %q, want %q", doc, got, want)
		}
	}
}

// A host that cannot be reached is unknown, never a state. Reporting "continue"
// for a silent host would put a pool's selector on a value nobody set.
func TestStateOfAnUnreachableHostIsUnknown(t *testing.T) {
	got, err := New(Options{}).State(context.Background(), "http://127.0.0.1:1")
	if err == nil {
		t.Fatal("an unreachable host reported success")
	}
	if got != StateUnknown {
		t.Errorf("state = %q, want %q", got, StateUnknown)
	}
	if _, err := New(Options{}).State(context.Background(), ""); err == nil {
		t.Error("an empty address reported success")
	}
}

// The aggregator fallback reads the proof out of the redirect FRAGMENT without
// following the redirect: following it would fetch a host's page and drop the
// one part of the answer that matters.
func TestProofFromAggregatorReadsTheFragment(t *testing.T) {
	const proof = "1900000000.abc="
	agg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("host") == "" {
			http.Error(w, "host required", http.StatusNotFound)
			return
		}
		http.Redirect(w, r, "http://192.0.2.7:8080#yctl="+proof, http.StatusFound)
	}))
	defer agg.Close()

	got, err := New(Options{}).ProofFromAggregator(context.Background(), agg.URL, "42aa")
	if err != nil {
		t.Fatalf("ProofFromAggregator: %v", err)
	}
	if got != proof {
		t.Errorf("proof = %q, want %q", got, proof)
	}
}

// A redirect with no fragment means the aggregator holds no internal authentication key, so
// the whole lab is loopback-only. That is one report about the lab, not a
// refusal per host.
func TestProofFromAggregatorWithoutAFragment(t *testing.T) {
	agg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://192.0.2.7:8080", http.StatusFound)
	}))
	defer agg.Close()

	if _, err := New(Options{}).ProofFromAggregator(context.Background(), agg.URL, "42aa"); err == nil ||
		!strings.Contains(err.Error(), "no internal authentication key") {
		t.Fatalf("error = %v, want one naming the missing internal authentication key", err)
	}
}

// An unusable host address is rejected before a request is built. These come
// from an unauthenticated pool read, so a value that is not an absolute http(s)
// URL must not reach the HTTP client.
func TestUnusableHostAddressesAreRefused(t *testing.T) {
	for _, addr := range []string{"", "   ", "javascript:alert(1)", "192.168.1.1:8080", "file:///etc/passwd"} {
		if err := New(Options{}).Apply(context.Background(), addr, ActionContinue, "proof"); err == nil {
			t.Errorf("Apply(%q) was accepted", addr)
		}
	}
}

// KnownAction is what the API validates a request body against, so it must
// accept exactly the three real states and nothing observation-only.
func TestKnownActionAcceptsOnlyTheThreeStates(t *testing.T) {
	for _, ok := range []string{ActionContinue, ActionPauseAfterCycle, ActionPauseAfterStep} {
		if !KnownAction(ok) {
			t.Errorf("KnownAction(%q) = false", ok)
		}
	}
	for _, bad := range []string{"", "run", "paused", "drain", StateBoth, StateMixed, StateUnknown, "CONTINUE"} {
		if KnownAction(bad) {
			t.Errorf("KnownAction(%q) = true", bad)
		}
	}
}

// --- REGION: Per-host refresh client
const (
	refreshTestID   = "4242aaaa-0000-4000-8000-000000000001"
	refreshTestHost = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
)

// findSharedVectors walks up from the package directory to the shared vector
// file, which sits in the SDK beside this module in the enlistment and in the
// staged build layout alike.
func findSharedVectors(t *testing.T) []byte {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for ; dir != filepath.Dir(dir); dir = filepath.Dir(dir) {
		p := filepath.Join(dir, "extension-sdk", "hostrefresh", "testdata", "vectors.json")
		if raw, err := os.ReadFile(p); err == nil {
			return raw
		}
	}
	t.Fatal("the shared vector file is not reachable from this package")
	return nil
}

// The refresh proof this service sends is the shared golden wire, byte for
// byte, when minted from the golden authority for the golden claims: the host
// verifier (PowerShell) pins the same vector, so a drift here would refuse
// every remote refresh with a plain 403.
func TestRefreshProofGolden(t *testing.T) {
	const want = "yhr1.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.4242aaaa-0000-4000-8000-000000000001.restart.start-if-stopped.1899999880.1900000000.orGIvWqvVzUG1Vm_ZOGm7vW4Dr4N4FmEVGxub6x0Zyk"
	var v struct {
		Legacy struct {
			Token      string `json:"token"`
			ExpiryUnix int64  `json:"expiryUnix"`
			Wire       string `json:"wire"`
		} `json:"legacy"`
		Versioned struct {
			AuthorityText string `json:"authorityText"`
			Wire          string `json:"wire"`
		} `json:"versioned"`
	}
	if err := json.Unmarshal(findSharedVectors(t), &v); err != nil {
		t.Fatal(err)
	}
	key, err := hostrefresh.DeriveHostKey([]byte(v.Versioned.AuthorityText), refreshTestHost)
	if err != nil {
		t.Fatal(err)
	}
	got, err := hostrefresh.Proof(key, hostrefresh.Claims{HostID: refreshTestHost, RequestID: refreshTestID, Tier: "restart",
		MaxRung: "start-if-stopped", IssuedUnix: 1899999880, ExpiryUnix: 1900000000})
	if err != nil || got != want || v.Versioned.Wire != want {
		t.Fatalf("refresh proof mismatch:\n got    %s\n vector %s\n want   %s", got, v.Versioned.Wire, want)
	}
	if Proof(v.Legacy.Token, v.Legacy.ExpiryUnix) != v.Legacy.Wire {
		t.Fatal("the legacy proof drifted from the shared vector")
	}
}

// refreshStub is a host listener that records every refresh POST and answers
// with the status and body the test supplies.
type refreshStub struct {
	mu      sync.Mutex
	bodies  []string
	headers []http.Header
	paths   []string
	status  int
	body    string
	hangup  bool
	srv     *httptest.Server
}

func newRefreshStub(t *testing.T, status int, body string) *refreshStub {
	t.Helper()
	h := &refreshStub{status: status, body: body}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.bodies = append(h.bodies, string(b))
		h.headers = append(h.headers, r.Header.Clone())
		h.paths = append(h.paths, r.Method+" "+r.URL.Path)
		status, body, hangup := h.status, h.body, h.hangup
		h.mu.Unlock()
		if hangup {
			// A connection dropped with no answer at all: the transport
			// failure the one same-id resend exists for.
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				_ = conn.Close()
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if status == http.StatusFound {
			w.Header().Set("Location", "http://192.0.2.99/elsewhere")
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *refreshStub) calls() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.bodies)
}

func refreshReq() RefreshRequest {
	return RefreshRequest{RequestID: refreshTestID, Tier: "restart", MaxRung: "start-if-stopped"}
}

func TestRefreshSendsOneTypedRequest(t *testing.T) {
	host := newRefreshStub(t, http.StatusAccepted,
		`{"ok":true,"requestId":"`+refreshTestID+`","action":"spawned","ceiling":"start-if-stopped","stateUrl":"/runtime/host-refresh.state.json"}`)
	reply, err := New(Options{}).Refresh(context.Background(), host.srv.URL, refreshReq(), "legacy-proof", "yhr1.proof")
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	if host.calls() != 1 || host.paths[0] != "POST /control/host-refresh" {
		t.Fatalf("calls = %v", host.paths)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(host.bodies[0]), &body); err != nil || len(body) != 3 ||
		body["requestId"] != refreshTestID || body["tier"] != "restart" || body["maxRung"] != "start-if-stopped" {
		t.Fatalf("body = %s", host.bodies[0])
	}
	hdr := host.headers[0]
	for name, want := range map[string]string{"Content-Type": "application/json", "X-Yuruna": "1",
		"X-Yuruna-Control": "legacy-proof", hostrefresh.ProofHeader: "yhr1.proof"} {
		if hdr.Get(name) != want {
			t.Errorf("%s = %q, want %q", name, hdr.Get(name), want)
		}
	}
	if hdr.Get(hostrefresh.CredentialHeader) != "" || hdr.Get("Authorization") != "" {
		t.Error("the operator credential or a bearer traveled to the host")
	}
	if reply.Status != http.StatusAccepted || reply.Action != RefreshActionSpawned || reply.Replay || reply.Ceiling != "start-if-stopped" ||
		reply.StateURL != host.srv.URL+"/runtime/host-refresh.state.json" {
		t.Fatalf("reply = %+v", reply)
	}
}

func TestRefreshDecodesAlreadyClaimedAndAReplay(t *testing.T) {
	host := newRefreshStub(t, http.StatusAccepted, `{"ok":true,"requestId":"`+refreshTestID+`","action":"already_claimed","stateUrl":"/runtime/host-refresh.state.json"}`)
	if reply, err := New(Options{}).Refresh(context.Background(), host.srv.URL, refreshReq(), "p", "r"); err != nil || reply.Action != RefreshActionAlreadyClaimed {
		t.Fatalf("already_claimed: %+v %v", reply, err)
	}
	replay := newRefreshStub(t, http.StatusOK,
		`{"ok":true,"requestId":"`+refreshTestID+`","action":"completed","state":"completed","verdict":"repaired","ceiling":"reclaim","stateUrl":"/runtime/host-refresh.state.json"}`)
	reply, err := New(Options{}).Refresh(context.Background(), replay.srv.URL, refreshReq(), "p", "r")
	if err != nil || !reply.Replay || reply.Verdict != "repaired" || reply.State != "completed" || reply.Status != http.StatusOK {
		t.Fatalf("replay: %+v %v", reply, err)
	}
}

func refreshErr(t *testing.T, err error) *RefreshError {
	t.Helper()
	var e *RefreshError
	if !errors.As(err, &e) {
		t.Fatalf("error = %v, want a *RefreshError", err)
	}
	return e
}

func TestRefreshTypesEveryRefusal(t *testing.T) {
	cases := []struct {
		name      string
		status    int
		body      string
		reason    string
		retryable bool
		active    string
		kind      string
		stateURL  bool
	}{
		{"busy", http.StatusConflict, `{"ok":false,"code":"status.x","error":"busy","reason":"busy","activeKind":"host_refresh","activeRequestId":"4242aaaa-0000-4000-8000-000000000009","stateUrl":"/runtime/host-refresh.state.json"}`,
			RefreshReasonBusy, false, "4242aaaa-0000-4000-8000-000000000009", "host_refresh", true},
		{"conflict", http.StatusConflict, `{"ok":false,"reason":"request_conflict","requestId":"` + refreshTestID + `","stateUrl":"/runtime/host-refresh.state.json"}`,
			RefreshReasonRequestConflict, false, "", "", true},
		{"closed", http.StatusConflict, `{"ok":false,"reason":"request_closed","requestId":"` + refreshTestID + `","state":"refused","verdict":"refused"}`,
			RefreshReasonRequestClosed, false, "", "", false},
		{"launcher failed", http.StatusServiceUnavailable, `{"ok":false,"reason":"launcher_failed","requestId":"` + refreshTestID + `","stateUrl":"/runtime/host-refresh.state.json"}`,
			"launcher_failed", true, "", "", true},
		{"listener busy", http.StatusServiceUnavailable, `{"ok":false,"reason":"listener_busy"}`, "listener_busy", true, "", "", false},
		{"body timeout", http.StatusRequestTimeout, `{"ok":false,"reason":"body_timeout"}`, "body_timeout", true, "", "", false},
		{"internal error", http.StatusInternalServerError, `{"ok":false,"reason":"internal_error"}`, "internal_error", true, "", "", false},
		{"proof refused", http.StatusForbidden, `{"ok":false,"code":"status.api_host_refresh_authorization_refused","reason":"refresh_proof_expired"}`,
			"refresh_proof_expired", false, "", "", false},
		{"forbidden field", http.StatusBadRequest, `{"ok":false,"reason":"forbidden_field","field":"force"}`, "forbidden_field", false, "", "", false},
		{"too large", http.StatusRequestEntityTooLarge, `{"ok":false,"reason":"payload_too_large"}`, "payload_too_large", false, "", "", false},
		{"media type", http.StatusUnsupportedMediaType, `{"ok":false,"reason":"unsupported_media_type"}`, "unsupported_media_type", false, "", "", false},
		{"html error page", http.StatusBadGateway, `<html>bad gateway</html>`, "", true, "", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			host := newRefreshStub(t, c.status, c.body)
			_, err := New(Options{}).Refresh(context.Background(), host.srv.URL, refreshReq(), "p", "r")
			e := refreshErr(t, err)
			if e.Status != c.status || e.Reason != c.reason || e.Retryable != c.retryable || e.ActiveRequestID != c.active ||
				e.ActiveKind != c.kind || e.RequestID != refreshTestID || (e.StateURL != "") != c.stateURL {
				t.Fatalf("error = %+v", e)
			}
			if host.calls() != 1 {
				t.Fatalf("an answered refusal was resent: %d calls", host.calls())
			}
			if !strings.Contains(e.Error(), "HTTP") {
				t.Fatalf("Error() = %q", e.Error())
			}
		})
	}
}

// Any other success or redirect, a mismatched id, or a body that is not the
// acceptance shape is an answer this client cannot use.
func TestRefreshRefusesUnusableReplies(t *testing.T) {
	cases := map[string]struct {
		status int
		body   string
	}{
		"204":                      {http.StatusNoContent, ``},
		"302":                      {http.StatusFound, ``},
		"200 not a replay":         {http.StatusOK, `{"ok":true,"requestId":"` + refreshTestID + `","action":"spawned"}`},
		"202 for another request":  {http.StatusAccepted, `{"ok":true,"requestId":"4242aaaa-0000-4000-8000-00000000000f","action":"spawned"}`},
		"202 without an id":        {http.StatusAccepted, `{"ok":true,"action":"spawned"}`},
		"202 unknown action":       {http.StatusAccepted, `{"ok":true,"requestId":"` + refreshTestID + `","action":"started"}`},
		"202 not json":             {http.StatusAccepted, `accepted`},
		"409 for another request":  {http.StatusConflict, `{"ok":false,"reason":"request_conflict","requestId":"4242aaaa-0000-4000-8000-00000000000f"}`},
		"202 ok false":             {http.StatusAccepted, `{"ok":false,"requestId":"` + refreshTestID + `","action":"spawned"}`},
		"oversize acceptance body": {http.StatusAccepted, `{"ok":true,"requestId":"` + refreshTestID + `","action":"spawned","pad":"` + strings.Repeat("x", maxRefreshReplyBytes) + `"}`},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			host := newRefreshStub(t, c.status, c.body)
			_, err := New(Options{}).Refresh(context.Background(), host.srv.URL, refreshReq(), "p", "r")
			if e := refreshErr(t, err); e.Reason != RefreshReasonReplyInvalid || e.Status != c.status || e.Retryable {
				t.Fatalf("error = %+v", e)
			}
		})
	}
}

// A dropped connection is resent exactly once, byte-identical, and then
// reported as retryable with the same request id: a retry never mints a new
// request.
func TestRefreshResendsOnceOnATransportFailure(t *testing.T) {
	host := newRefreshStub(t, http.StatusAccepted, "")
	host.hangup = true
	_, err := New(Options{}).Refresh(context.Background(), host.srv.URL, refreshReq(), "legacy", "versioned")
	e := refreshErr(t, err)
	if e.Status != 0 || !e.Retryable || e.RequestID != refreshTestID {
		t.Fatalf("error = %+v", e)
	}
	if host.calls() != 2 {
		t.Fatalf("calls = %d, want exactly one resend", host.calls())
	}
	if host.bodies[0] != host.bodies[1] || host.headers[0].Get(hostrefresh.ProofHeader) != host.headers[1].Get(hostrefresh.ProofHeader) ||
		host.headers[0].Get("X-Yuruna-Control") != host.headers[1].Get("X-Yuruna-Control") {
		t.Fatal("the resend differed from the original")
	}
}

// With too little time left the resend would only be cut off, so it is not
// attempted.
func TestRefreshDoesNotResendPastTheDeadline(t *testing.T) {
	host := newRefreshStub(t, http.StatusAccepted, "")
	host.hangup = true
	ctx, cancel := context.WithTimeout(context.Background(), refreshResendFloor/2)
	defer cancel()
	_, err := New(Options{}).Refresh(ctx, host.srv.URL, refreshReq(), "legacy", "versioned")
	if e := refreshErr(t, err); e.Status != 0 || host.calls() != 1 {
		t.Fatalf("error = %+v after %d calls", e, host.calls())
	}
}

// A state URL that leaves the host's own origin is dropped rather than handed
// to a caller.
func TestRefreshDropsACrossOriginStateURL(t *testing.T) {
	for ref, keep := range map[string]bool{
		"/runtime/host-refresh.state.json": true,
		"runtime/host-refresh.state.json":  true,
		"http://192.0.2.99/state.json":     false,
		"//192.0.2.99/state.json":          false,
		"javascript:alert(1)":              false,
	} {
		host := newRefreshStub(t, http.StatusAccepted, `{"ok":true,"requestId":"`+refreshTestID+`","action":"spawned","stateUrl":`+jsonString(ref)+`}`)
		reply, err := New(Options{}).Refresh(context.Background(), host.srv.URL, refreshReq(), "p", "r")
		if err != nil {
			t.Fatalf("%s: %v", ref, err)
		}
		if keep != (reply.StateURL != "") || (keep && !strings.HasPrefix(reply.StateURL, host.srv.URL+"/")) {
			t.Errorf("%s -> %q", ref, reply.StateURL)
		}
	}
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// Nothing is sent without both proofs or with an invalid field.
func TestRefreshValidatesBeforeAnyIO(t *testing.T) {
	host := newRefreshStub(t, http.StatusAccepted, "")
	c := New(Options{})
	if _, err := c.Refresh(context.Background(), host.srv.URL, refreshReq(), " ", "r"); !errors.Is(err, ErrNoProof) {
		t.Errorf("no control proof: %v", err)
	}
	if _, err := c.Refresh(context.Background(), host.srv.URL, refreshReq(), "p", ""); !errors.Is(err, ErrNoRefreshProof) {
		t.Errorf("no refresh proof: %v", err)
	}
	for name, req := range map[string]RefreshRequest{
		"uppercase id": {RequestID: strings.ToUpper(refreshTestID), Tier: "restart", MaxRung: "probe"},
		"tier":         {RequestID: refreshTestID, Tier: "all", MaxRung: "probe"},
		"rung":         {RequestID: refreshTestID, Tier: "restart", MaxRung: "everything"},
	} {
		if _, err := c.Refresh(context.Background(), host.srv.URL, req, "p", "r"); !errors.Is(err, hostrefresh.ErrInvalidClaim) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := c.Refresh(context.Background(), "ftp://host", refreshReq(), "p", "r"); err == nil {
		t.Error("a non-http base was accepted")
	}
	if host.calls() != 0 {
		t.Fatalf("%d requests were sent", host.calls())
	}
}

// Refresh is a typed per-host method and never an action of the pool-wide
// fan-out, so the action list that fan-out validates against cannot gain it.
func TestRefreshIsNeverAKnownAction(t *testing.T) {
	for _, a := range []string{"refresh", "Refresh", "host-refresh", "restart"} {
		if KnownAction(a) {
			t.Errorf("KnownAction(%q) = true", a)
		}
	}
	if err := New(Options{}).Apply(context.Background(), "http://192.0.2.1", "refresh", "p"); err == nil {
		t.Error("Apply accepted refresh")
	}
}

// The client never waits past the caller's context.
func TestRefreshHonorsTheCallerDeadline(t *testing.T) {
	release := make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer slow.Close()
	defer close(release)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := New(Options{}).Refresh(ctx, slow.URL, refreshReq(), "p", "r")
	if e := refreshErr(t, err); e.Status != 0 || time.Since(start) > 3*time.Second {
		t.Fatalf("error = %+v after %v", e, time.Since(start))
	}
}

// An unusable host address matches ErrHostAddress, so a caller relaying the
// failure can name it without forwarding the address, while the error's own
// text still quotes it for the operator.
func TestUnusableHostAddressIsTyped(t *testing.T) {
	c := New(Options{})
	for _, base := range []string{"", "   ", "gopher://host.example/x", "not a url"} {
		err := c.Apply(context.Background(), base, "continue", "proof")
		if !errors.Is(err, ErrHostAddress) {
			t.Errorf("Apply(%q) = %v, want ErrHostAddress", base, err)
		}
		_, err = c.Refresh(context.Background(), base, RefreshRequest{RequestID: "4242aaaa-0000-4000-8000-000000000001", Tier: "restart", MaxRung: "probe"}, "p", "r")
		if !errors.Is(err, ErrHostAddress) {
			t.Errorf("Refresh(%q) = %v, want ErrHostAddress", base, err)
		}
	}
	if err := c.Apply(context.Background(), "gopher://host.example/x", "continue", "proof"); err == nil || !strings.Contains(err.Error(), "gopher://host.example/x") {
		t.Errorf("the operator text lost the address: %v", err)
	}
}
