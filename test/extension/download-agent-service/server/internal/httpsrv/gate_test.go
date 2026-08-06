// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"download-agent-service/internal/state"
	"download-agent-service/internal/yex/labgate"
)

// The gate's own semantics -- sessions, throttling, the bearer compare, the
// source-address key -- are covered where the gate lives, in the SDK's labgate
// suite. What is covered HERE is the wiring: that this daemon's mutating routes
// are behind it, that its unlock route reaches a real aggregator, and that its
// audit records what happened.

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
		if r.URL.Path != "/api/v1/lab-token" || r.Method != http.MethodPost {
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
			// This one is deliberately unopenable: the daemon's verdict has to
			// come from the status alone.
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

// An operator who reached this UI by clicking it out of the Yuruna hosts
// dashboard arrives holding a control proof in the URL fragment instead of a
// code, and the page spends it on /api/unlock-proof. What this covers is the
// wiring -- that the route is mounted and reaches the gate; the proof's own
// rules (window, ceiling, forgery, who verifies it) live in the labgate suite.
func TestAControlProofFromTheDashboardUnlocksTheGatedRoutes(t *testing.T) {
	const labAuthToken = "lab-auth-token-for-the-whole-pool"
	srv, _ := newServer(t, Options{AuthToken: labAuthToken})

	if r := post(t, srv, imgPath+"/refresh"+imgQuery, "", nil); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no session = %d, want 401", r.StatusCode)
	}
	expiry := strconv.FormatInt(time.Now().Add(15*time.Minute).Unix(), 10)
	proof := expiry + "." + hmacB64(labAuthToken, "yuruna-control|proof|"+expiry)
	resp, err := srv.Client().Post(srv.URL+"/api/unlock-proof", "application/json",
		strings.NewReader(`{"proof":`+strconv.Quote(proof)+`}`))
	if err != nil {
		t.Fatalf("POST /api/unlock-proof: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("unlock with a fresh proof = %d, want 200", resp.StatusCode)
	}
	if r := post(t, srv, imgPath+"/refresh"+imgQuery, "", resp.Cookies()); r.StatusCode != http.StatusAccepted {
		t.Fatalf("with the proof session = %d, want 202", r.StatusCode)
	}
}

// hmacB64 is the proof's signature step, written out rather than imported so a
// change to the format has to be made twice before this test stops noticing.
func hmacB64(key, data string) string {
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(data))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func TestAValidLabTokenGrantsASessionForTheGatedRoutes(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	srv, f := newServer(t, Options{AggregatorURL: agg.srv.URL})

	if r := post(t, srv, imgPath+"/refresh"+imgQuery, "", nil); r.StatusCode != http.StatusUnauthorized {
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
	if r := post(t, srv, imgPath+"/refresh"+imgQuery, "", cookies); r.StatusCode != http.StatusAccepted {
		t.Fatalf("with the session = %d, want 202", r.StatusCode)
	}
	if len(f.refreshed) != 1 {
		t.Fatal("the session-authorized mutation did not reach the store")
	}
}

func TestARejectedLabTokenLeavesTheMutatingRoutesShut(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	srv, _ := newServer(t, Options{AggregatorURL: agg.srv.URL})

	resp := login(t, srv, "zz9999")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("rejected code = %d, want 401", resp.StatusCode)
	}
	// The aggregator answers 403 for a code it is not showing; a client of this
	// daemon must still see the ordinary "you are not authenticated" answer.
	if body := decodeBody(t, resp); body["ok"] != false {
		t.Fatalf("rejected login body = %+v", body)
	}
	if r := post(t, srv, imgPath+"/refresh"+imgQuery, "", nil); r.StatusCode != http.StatusUnauthorized {
		t.Fatal("a refused unlock must leave the mutating routes shut")
	}
}

func TestAnUnavailableAggregatorFailsClosedNamingTheReason(t *testing.T) {
	// Three ways the check cannot be made, one answer: never an open gate.
	t.Run("unreachable", func(t *testing.T) {
		agg := newFakeAggregator(t, labCode)
		url := agg.srv.URL
		agg.srv.Close() // nothing is listening on that port any more
		srv, _ := newServer(t, Options{AggregatorURL: url})
		assertLabTokenUnavailable(t, login(t, srv, labCode))
	})
	t.Run("exchange disabled", func(t *testing.T) {
		agg := newFakeAggregator(t, labCode)
		agg.force(http.StatusServiceUnavailable)
		srv, _ := newServer(t, Options{AggregatorURL: agg.srv.URL})
		assertLabTokenUnavailable(t, login(t, srv, labCode))
	})
	t.Run("no aggregator configured", func(t *testing.T) {
		srv, _ := newServer(t, Options{AuthToken: labToken})
		assertLabTokenUnavailable(t, login(t, srv, labCode))
	})
}

func assertLabTokenUnavailable(t *testing.T, resp *http.Response) {
	t.Helper()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("login = %d, want 503", resp.StatusCode)
	}
	body := decodeBody(t, resp)
	if body["ok"] != false || body["reason"] != labgate.ReasonUnavailable {
		t.Fatalf("body = %+v, want ok:false + reason:%s", body, labgate.ReasonUnavailable)
	}
	// The operator has to be able to tell "wrong code" from "the validator is
	// down", or they retype a correct code until they give up.
	if msg, _ := body["error"].(string); !strings.Contains(msg, "aggregator") {
		t.Fatalf("error = %q, want it to name the aggregator as the reason", msg)
	}
}

func TestAMalformedLabTokenNeverReachesTheAggregator(t *testing.T) {
	// The aggregator throttles by source address, and every operator arrives as
	// this daemon: a typo must not spend one of the lab's shared attempts.
	agg := newFakeAggregator(t, labCode)
	srv, _ := newServer(t, Options{AggregatorURL: agg.srv.URL})

	for _, bad := range []string{"", "abc", "abcdefg", "ab-12c", "abc123 x", "AB 12C"} {
		if r := login(t, srv, bad); r.StatusCode != http.StatusBadRequest {
			t.Errorf("login %q = %d, want 400", bad, r.StatusCode)
		}
	}
	if got := agg.calls(); len(got) != 0 {
		t.Fatalf("the aggregator was asked %v; a locally-malformed code must not leave", got)
	}
	// A locally-rejected string is not a guess, so it must not push the operator
	// toward the throttle either.
	if r := login(t, srv, labCode); r.StatusCode != http.StatusOK {
		t.Fatalf("login after six malformed submissions = %d, want 200", r.StatusCode)
	}
}

func TestTheDaemonThrottlesPerClientRatherThanLeaningOnTheAggregator(t *testing.T) {
	// Without a local throttle, one brute-forcer would burn the aggregator's
	// per-source budget for the whole lab, because that source is this daemon.
	agg := newFakeAggregator(t, labCode)
	srv, _ := newServer(t, Options{AggregatorURL: agg.srv.URL})

	for i := 0; i < labgate.MaxFailedAttempts; i++ {
		if r := login(t, srv, "zz999"+strconv.Itoa(i%10)); r.StatusCode != http.StatusUnauthorized {
			t.Fatalf("attempt %d = %d, want 401", i, r.StatusCode)
		}
	}
	if r := login(t, srv, labCode); r.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("attempt %d = %d, want 429", labgate.MaxFailedAttempts+1, r.StatusCode)
	}
	if got := agg.calls(); len(got) != labgate.MaxFailedAttempts {
		t.Fatalf("the aggregator saw %d attempts, want %d: a throttled attempt must stop here", len(got), labgate.MaxFailedAttempts)
	}
}

// Every unlock attempt reaches this daemon's audit with the address that made
// it. The aggregator's own audit cannot answer that question: from there, every
// operator in the lab is this one source address.
func TestUnlockAttemptsAreAudited(t *testing.T) {
	agg := newFakeAggregator(t, labCode)
	dir := t.TempDir()
	srv, _ := newServer(t, Options{AggregatorURL: agg.srv.URL, Store: state.New(dir, time.Now())})

	login(t, srv, "zz9999")
	login(t, srv, labCode)

	var outcomes []string
	for _, line := range strings.Split(strings.TrimSpace(readFile(t, filepath.Join(dir, "audit.jsonl"))), "\n") {
		var e struct {
			Action  string `json:"action"`
			Outcome string `json:"outcome"`
			Detail  string `json:"detail"`
		}
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("audit line %q: %v", line, err)
		}
		if e.Action != "unlock" {
			continue
		}
		if !strings.HasPrefix(e.Detail, "from ") {
			t.Errorf("audit entry %+v does not record the source address", e)
		}
		outcomes = append(outcomes, e.Outcome)
	}
	if len(outcomes) != 2 || outcomes[0] != "refused" || outcomes[1] != "ok" {
		t.Fatalf("audited unlock outcomes = %v, want [refused ok]", outcomes)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}
