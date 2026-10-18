// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package hostrefresh

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type auditLog struct {
	mu      sync.Mutex
	entries []string
}

func (a *auditLog) record(ip, outcome string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.entries = append(a.entries, ip+" "+outcome)
}

func (a *auditLog) text() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return strings.Join(a.entries, "\n")
}

func gateRequest(header map[string]string, cookie *http.Cookie, remote string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/host/refresh", strings.NewReader("{}"))
	for k, v := range header {
		r.Header.Set(k, v)
	}
	if cookie != nil {
		r.AddCookie(cookie)
	}
	if remote != "" {
		r.RemoteAddr = remote
	}
	return r
}

func serve(g *Gate, r *http.Request) (*httptest.ResponseRecorder, map[string]any, bool) {
	called := false
	w := httptest.NewRecorder()
	g.Require(func(http.ResponseWriter, *http.Request) { called = true })(w, r)
	var body map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	return w, body, called
}

func TestGateAdmitsOnlyTheDedicatedHeader(t *testing.T) {
	credential := FormatSecret(CredentialPrefix, secret(5))
	audit := &auditLog{}
	g := NewGate(GateOptions{Credential: credential, Audit: audit.record})
	if !g.Configured() {
		t.Fatal("a well-formed credential must configure the gate")
	}

	w, _, called := serve(g, gateRequest(map[string]string{CredentialHeader: credential}, nil, ""))
	if !called || w.Code != http.StatusOK {
		t.Fatalf("the credential header was refused: %d", w.Code)
	}

	// The same value in every other slot a legacy credential travels in.
	for name, r := range map[string]*http.Request{
		"authorization bearer": gateRequest(map[string]string{"Authorization": "Bearer " + credential}, nil, ""),
		"legacy control proof": gateRequest(map[string]string{"X-Yuruna-Control": credential}, nil, ""),
		"session cookie":       gateRequest(nil, &http.Cookie{Name: "yuruna_board", Value: credential}, ""),
		"no credential":        gateRequest(nil, nil, ""),
	} {
		w, body, called := serve(g, r)
		if called || w.Code != http.StatusUnauthorized || body["reason"] != ReasonCredentialRequired || body["code"] != "auth.refresh_credential_required" || body["ok"] != false {
			t.Errorf("%s: %d %v called=%v", name, w.Code, body, called)
		}
		if w.Header().Get("Set-Cookie") != "" {
			t.Errorf("%s: the gate set a cookie", name)
		}
	}
	if strings.Contains(audit.text(), credential) {
		t.Fatal("the audit trail carries the presented credential")
	}
	if !strings.Contains(audit.text(), AuditOK) || !strings.Contains(audit.text(), AuditRefused) {
		t.Fatalf("audit outcomes missing: %s", audit.text())
	}
}

func TestAnUnconfiguredGateRefusesEverything(t *testing.T) {
	for _, cred := range []string{"", "yhrc1.short", FormatSecret(AuthorityPrefix, secret(5)), " " + FormatSecret(CredentialPrefix, secret(5))} {
		audit := &auditLog{}
		g := NewGate(GateOptions{Credential: cred, Audit: audit.record})
		if g.Configured() {
			t.Fatalf("credential %q configured the gate", cred)
		}
		w, body, called := serve(g, gateRequest(map[string]string{CredentialHeader: cred}, nil, ""))
		if called || w.Code != http.StatusServiceUnavailable || body["reason"] != ReasonGateUnconfigured || body["code"] != "auth.refresh_unconfigured" {
			t.Fatalf("unconfigured gate answered %d %v", w.Code, body)
		}
		if ok, reason, _ := g.Allow(gateRequest(nil, nil, "")); ok || reason != ReasonGateUnconfigured {
			t.Fatalf("Allow on an unconfigured gate = %v %s", ok, reason)
		}
		if !strings.Contains(audit.text(), AuditUnconfigured) {
			t.Fatalf("unconfigured refusal not audited: %s", audit.text())
		}
	}
	var nilGate *Gate
	if nilGate.Configured() {
		t.Fatal("a nil gate is configured")
	}
	w, body, called := serve(nilGate, gateRequest(map[string]string{CredentialHeader: FormatSecret(CredentialPrefix, secret(5))}, nil, ""))
	if called || w.Code != http.StatusServiceUnavailable || body["reason"] != ReasonGateUnconfigured {
		t.Fatalf("a nil gate answered %d %v", w.Code, body)
	}
	if ok, reason, _ := nilGate.Allow(gateRequest(nil, nil, "")); ok || reason != ReasonGateUnconfigured {
		t.Fatalf("Allow on a nil gate = %v %s", ok, reason)
	}
}

// A guesser is throttled per source address after the legacy gate's allowance,
// the throttle holds even against the right credential, and it lifts once the
// window has passed. Absent headers are not guesses and spend nothing.
func TestWrongCredentialsAreThrottledPerSource(t *testing.T) {
	credential := FormatSecret(CredentialPrefix, secret(5))
	now := time.Unix(1900000000, 0)
	clock := func() time.Time { return now }
	g := NewGate(GateOptions{Credential: credential, Now: clock})
	wrong := FormatSecret(CredentialPrefix, secret(6))
	for i := 0; i < 20; i++ {
		if w, _, _ := serve(g, gateRequest(nil, nil, "192.0.2.7:1000")); w.Code != http.StatusUnauthorized {
			t.Fatalf("absent header %d: %d", i, w.Code)
		}
	}
	for i := 0; i < MaxFailedAttempts; i++ {
		if w, _, _ := serve(g, gateRequest(map[string]string{CredentialHeader: wrong}, nil, "192.0.2.7:1000")); w.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: %d", i, w.Code)
		}
	}
	w, body, called := serve(g, gateRequest(map[string]string{CredentialHeader: credential}, nil, "192.0.2.7:1001"))
	if called || w.Code != http.StatusTooManyRequests || body["reason"] != ReasonGateThrottled || body["code"] != "auth.refresh_throttled" {
		t.Fatalf("throttled source got through: %d %v", w.Code, body)
	}
	if ok, reason, _ := g.Allow(gateRequest(map[string]string{CredentialHeader: credential}, nil, "192.0.2.7:1002")); ok || reason != ReasonGateThrottled {
		t.Fatalf("Allow on a throttled source = %v %s", ok, reason)
	}
	// Another source is unaffected.
	if w, _, called := serve(g, gateRequest(map[string]string{CredentialHeader: credential}, nil, "192.0.2.8:1000")); !called || w.Code != http.StatusOK {
		t.Fatalf("an innocent source was throttled: %d", w.Code)
	}
	now = now.Add(FailWindow + time.Second)
	if w, _, called := serve(g, gateRequest(map[string]string{CredentialHeader: credential}, nil, "192.0.2.7:1003")); !called || w.Code != http.StatusOK {
		t.Fatalf("the throttle did not lift after the window: %d", w.Code)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.fails) != 0 {
		t.Fatalf("expired failures were not swept: %v", g.fails)
	}
}

func TestAllowMatchesRequire(t *testing.T) {
	credential := FormatSecret(CredentialPrefix, secret(5))
	g := NewGate(GateOptions{Credential: credential})
	if ok, reason, msg := g.Allow(gateRequest(map[string]string{CredentialHeader: credential}, nil, "")); !ok || reason != "" || msg != "" {
		t.Fatalf("Allow(credential) = %v %q %q", ok, reason, msg)
	}
	ok, reason, msg := g.Allow(gateRequest(map[string]string{"Authorization": "Bearer " + credential}, nil, ""))
	if ok || reason != ReasonCredentialRequired || msg == "" || strings.Contains(msg, credential) {
		t.Fatalf("Allow(bearer) = %v %q %q", ok, reason, msg)
	}
}
