// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The lab-token exchange (POST /api/v1/lab-token): the dashboard shows a
// rotating 6-char lab connection token; a joining host redeems it here for the
// shared lab-auth-token (Set-LabToken.ps1). These cover the code generator's
// alphabet, the rotation's retention window, the handler's verify /
// grace-window / throttle / self-disable behavior, and the /metrics exposition
// the dashboard tile reads.

// newLabState returns a poolState with the exchange live: a configured shared
// token, rotation on, and a seeded current code.
func newLabState(codes ...string) *poolState {
	s := newPoolState("default", 8080)
	s.authToken = "sekret-lab-auth-token"
	s.labRotate = time.Minute
	s.labCodes = codes
	return s
}

func postLabToken(s *poolState, remoteAddr, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", "/api/v1/lab-token", strings.NewReader(body))
	req.RemoteAddr = remoteAddr
	rec := httptest.NewRecorder()
	s.handleLabToken(rec, req)
	return rec
}

func TestNewLabCodeShape(t *testing.T) {
	for i := 0; i < 32; i++ {
		code, err := newLabCode()
		if err != nil {
			t.Fatalf("newLabCode: %v", err)
		}
		if !labTokenRE.MatchString(code) {
			t.Fatalf("code %q does not match ^[a-z0-9]{6}$", code)
		}
	}
}

func TestRotateLabTokenRetainsGraceWindow(t *testing.T) {
	s := newLabState()
	now := time.Now().UTC()
	var minted []string
	for i := 0; i < labKeepCodes+2; i++ {
		s.rotateLabToken(now)
		minted = append(minted, s.labCodes[0])
	}
	if len(s.labCodes) != labKeepCodes {
		t.Fatalf("retained %d codes, want %d", len(s.labCodes), labKeepCodes)
	}
	if s.labCodes[0] != minted[len(minted)-1] {
		t.Errorf("labCodes[0] = %q, want the most recently minted %q", s.labCodes[0], minted[len(minted)-1])
	}
}

// labEnvelope is the sealed exchange response; openLabEnvelope is the Go-side
// twin of Test.ConfigServiceSync\Unprotect-LabTokenEnvelope, so these tests
// exercise the same seal/open contract the PowerShell client depends on.
type labEnvelope struct {
	Ok         bool   `json:"ok"`
	V          int    `json:"v"`
	Salt       string `json:"salt"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
	Tag        string `json:"tag"`
}

func openLabEnvelope(t *testing.T, code string, env labEnvelope) (string, error) {
	t.Helper()
	salt, err := base64.StdEncoding.DecodeString(env.Salt)
	if err != nil {
		return "", err
	}
	nonce, err := base64.StdEncoding.DecodeString(env.Nonce)
	if err != nil {
		return "", err
	}
	ct, err := base64.StdEncoding.DecodeString(env.Ciphertext)
	if err != nil {
		return "", err
	}
	tag, err := base64.StdEncoding.DecodeString(env.Tag)
	if err != nil {
		return "", err
	}
	key, err := pbkdf2.Key(sha256.New, code, salt, labEnvelopeIters, 32)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	plain, err := gcm.Open(nil, nonce, append(ct, tag...), []byte(labEnvelopeLabel))
	if err != nil {
		return "", err
	}
	return string(plain), nil
}

func TestLabTokenExchangeCurrentAndPrevious(t *testing.T) {
	s := newLabState("abc123", "old456", "old789")
	for _, code := range []string{"abc123", "old456", "old789"} {
		rec := postLabToken(s, "10.0.0.7:5555", fmt.Sprintf(`{"labToken":%q}`, code))
		if rec.Code != 200 {
			t.Fatalf("code %q: status = %d, want 200", code, rec.Code)
		}
		var env labEnvelope
		if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
			t.Fatalf("code %q: unmarshal: %v", code, err)
		}
		if !env.Ok || env.V != 1 {
			t.Errorf("code %q: response %+v, want ok with v=1", code, env)
		}
		got, err := openLabEnvelope(t, code, env)
		if err != nil {
			t.Fatalf("code %q: envelope did not open: %v", code, err)
		}
		if got != s.authToken {
			t.Errorf("code %q: opened %q, want the shared token %q", code, got, s.authToken)
		}
	}
}

// The seal is what authenticates the ANSWER to an enrolling host that cannot
// verify the aggregator's TLS leaf: an envelope must not open under any code
// other than the one redeemed, or an on-path responder could plant a token.
func TestLabTokenEnvelopeOnlyOpensWithRedeemedCode(t *testing.T) {
	s := newLabState("abc123", "old456")
	rec := postLabToken(s, "10.0.0.7:5555", `{"labToken":"abc123"}`)
	var env labEnvelope
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, err := openLabEnvelope(t, "old456", env); err == nil {
		t.Error("envelope opened under a different retained code")
	}
	if _, err := openLabEnvelope(t, "zzz999", env); err == nil {
		t.Error("envelope opened under an unrelated code")
	}
}

// The shared token must never appear in the clear on the wire: the listener is
// plain HTTP whenever the proxy has no TLS leaf.
func TestLabTokenExchangeBodyNeverCarriesRawToken(t *testing.T) {
	s := newLabState("abc123")
	rec := postLabToken(s, "10.0.0.7:5555", `{"labToken":"abc123"}`)
	if strings.Contains(rec.Body.String(), s.authToken) {
		t.Errorf("exchange body carries the raw shared token:\n%s", rec.Body.String())
	}
}

// A pasted code arrives however the operator typed it; surrounding space and
// upper case are normalized rather than refused.
func TestLabTokenExchangeNormalizesInput(t *testing.T) {
	s := newLabState("abc123")
	rec := postLabToken(s, "10.0.0.7:5555", `{"labToken":" ABC123 "}`)
	if rec.Code != 200 {
		t.Errorf("normalized code: status = %d, want 200", rec.Code)
	}
}

func TestLabTokenExchangeRefusesUnknownCode(t *testing.T) {
	s := newLabState("abc123")
	rec := postLabToken(s, "10.0.0.7:5555", `{"labToken":"zzz999"}`)
	if rec.Code != 403 {
		t.Fatalf("wrong code: status = %d, want 403", rec.Code)
	}
	if strings.Contains(rec.Body.String(), s.authToken) {
		t.Error("refusal body leaks the shared token")
	}
}

func TestLabTokenExchangeRejectsMalformed(t *testing.T) {
	s := newLabState("abc123")
	cases := map[string]string{
		"not json":       `not-json`,
		"wrong shape":    `{"labToken":"toolongcode"}`,
		"empty token":    `{"labToken":""}`,
		"invalid chars":  `{"labToken":"ab!123"}`,
		"uppercase only": `{"labToken":"ABC12"}`,
	}
	for name, body := range cases {
		rec := postLabToken(s, "10.0.0.7:5555", body)
		if rec.Code != 400 {
			t.Errorf("%s: status = %d, want 400", name, rec.Code)
		}
	}
}

func TestLabTokenExchangeSelfDisables(t *testing.T) {
	noRotate := newLabState("abc123")
	noRotate.labRotate = 0
	if rec := postLabToken(noRotate, "10.0.0.7:1", `{"labToken":"abc123"}`); rec.Code != 503 {
		t.Errorf("rotation off: status = %d, want 503", rec.Code)
	}
	noToken := newLabState("abc123")
	noToken.authToken = ""
	if rec := postLabToken(noToken, "10.0.0.7:1", `{"labToken":"abc123"}`); rec.Code != 503 {
		t.Errorf("no shared token: status = %d, want 503", rec.Code)
	}
}

func TestLabTokenExchangeMethodNotAllowed(t *testing.T) {
	s := newLabState("abc123")
	req := httptest.NewRequest("GET", "/api/v1/lab-token", nil)
	req.RemoteAddr = "10.0.0.7:5555"
	rec := httptest.NewRecorder()
	s.handleLabToken(rec, req)
	if rec.Code != 405 {
		t.Errorf("GET: status = %d, want 405", rec.Code)
	}
}

// Once an IP burns its failed-attempt budget, even the CORRECT code answers
// 429 until the window drains -- the throttle decision precedes verification
// so a guesser gets no oracle after tripping it.
func TestLabTokenExchangeThrottlesPerIP(t *testing.T) {
	s := newLabState("abc123")
	for i := 0; i < labFailLimit; i++ {
		if rec := postLabToken(s, "10.0.0.7:5555", `{"labToken":"zzz999"}`); rec.Code != 403 {
			t.Fatalf("attempt %d: status = %d, want 403", i, rec.Code)
		}
	}
	if rec := postLabToken(s, "10.0.0.7:5555", `{"labToken":"abc123"}`); rec.Code != 429 {
		t.Errorf("throttled correct code: status = %d, want 429", rec.Code)
	}
	// Another address is unaffected: the throttle is per source IP.
	if rec := postLabToken(s, "10.0.0.8:5555", `{"labToken":"abc123"}`); rec.Code != 200 {
		t.Errorf("other IP: status = %d, want 200", rec.Code)
	}
}

// Rotation prunes throttle records that have aged out of the window, so a
// host that mistyped a while ago is not still locked out.
func TestRotateLabTokenPrunesExpiredFails(t *testing.T) {
	s := newLabState("abc123")
	old := time.Now().UTC().Add(-labFailWindow - time.Minute)
	s.labFails["10.0.0.7"] = []time.Time{old, old}
	s.rotateLabToken(time.Now().UTC())
	if _, ok := s.labFails["10.0.0.7"]; ok {
		t.Error("expired throttle records survived rotation")
	}
}

// A single delegated IPv6 prefix offers more addresses than the map could ever
// hold, so per-address buckets there would throttle nothing: v6 callers share a
// /64 bucket while v4 stays per-address.
func TestLabThrottleKeyGroupsIPv6By64(t *testing.T) {
	a := labThrottleKey("2001:db8:1:2:3:4:5:6")
	b := labThrottleKey("2001:db8:1:2:ffff:ffff:ffff:ffff")
	if a != b {
		t.Errorf("addresses in one /64 got different buckets: %q vs %q", a, b)
	}
	if c := labThrottleKey("2001:db8:1:3::1"); c == a {
		t.Error("a different /64 shares the bucket")
	}
	if labThrottleKey("10.0.0.7") != "10.0.0.7" {
		t.Error("IPv4 must stay per-address")
	}
}

// An anonymous caller must not be able to grow the throttle map without bound
// by spraying source addresses.
func TestLabFailsMapIsBounded(t *testing.T) {
	s := newLabState("abc123")
	for i := 0; i < maxLabFailKeys+200; i++ {
		postLabToken(s, fmt.Sprintf("10.%d.%d.%d:5555", i/65536, (i/256)%256, i%256), `{"labToken":"zzz999"}`)
	}
	if len(s.labFails) > maxLabFailKeys {
		t.Errorf("throttle map holds %d keys, want <= %d", len(s.labFails), maxLabFailKeys)
	}
	// Overflow must fail SAFE: a correct code still redeems.
	if rec := postLabToken(s, "10.99.99.99:5555", `{"labToken":"abc123"}`); rec.Code != 200 {
		t.Errorf("correct code at map capacity: status = %d, want 200", rec.Code)
	}
}

func TestMetricsExposeLabToken(t *testing.T) {
	s := newLabState("abc123")
	rec := httptest.NewRecorder()
	s.handleMetrics(rec, httptest.NewRequest("GET", "/metrics", nil))
	want := `yuruna_pool_lab_token{pool="default",token="abc123"} 1`
	if !strings.Contains(rec.Body.String(), want) {
		t.Errorf("/metrics missing the lab-token gauge.\nwant: %s\ngot:\n%s", want, rec.Body.String())
	}
}

// A disabled exchange exports NO lab-token series: the tile shows "No data"
// instead of a code nobody can redeem.
func TestMetricsOmitLabTokenWhenDisabled(t *testing.T) {
	s := newLabState("abc123")
	s.labRotate = 0
	rec := httptest.NewRecorder()
	s.handleMetrics(rec, httptest.NewRequest("GET", "/metrics", nil))
	if strings.Contains(rec.Body.String(), "yuruna_pool_lab_token") {
		t.Error("/metrics exports a lab-token series while the exchange is disabled")
	}
}
