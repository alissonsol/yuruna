// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package hostctl

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
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
			host.body = `{"ok":false,"reason":"` + reason + `","error":"follow guidance at https://yuruna.link/control-proof"}`
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

// A redirect with no fragment means the aggregator holds no lab-auth-token, so
// the whole lab is loopback-only. That is one report about the lab, not a
// refusal per host.
func TestProofFromAggregatorWithoutAFragment(t *testing.T) {
	agg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://192.0.2.7:8080", http.StatusFound)
	}))
	defer agg.Close()

	if _, err := New(Options{}).ProofFromAggregator(context.Background(), agg.URL, "42aa"); err == nil ||
		!strings.Contains(err.Error(), "no lab auth token") {
		t.Fatalf("error = %v, want one naming the missing lab auth token", err)
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
