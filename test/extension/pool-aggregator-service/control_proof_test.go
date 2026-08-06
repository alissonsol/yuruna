// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestMintControlProofGolden pins the cross-language control-proof format. The vector is
// shared with Test.ConfigServiceSync\Get-YurunaControlProof (PowerShell): the same token +
// expiry must yield the same wire string on both sides, or a Grafana-minted proof would
// never validate on the host. If this fails, the Go mint and the PowerShell verify have
// drifted (HMAC key/data, base64 flavor, or the "<expiry>.<proof>" framing).
func TestMintControlProofGolden(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const expiry int64 = 1900000000
	const want = "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs="
	if got := controlProofFor(token, expiry); got != want {
		t.Fatalf("control proof mismatch (Go must match PowerShell Get-YurunaControlProof):\n got  %q\n want %q", got, want)
	}
}

// TestMintControlProofEmptyToken: no configured lab-auth-token -> no proof, so /go/host
// adds no fragment and the host falls back to loopback-only control.
func TestMintControlProofEmptyToken(t *testing.T) {
	if got := mintControlProof("", 0); got != "" {
		t.Fatalf("empty token must yield empty proof, got %q", got)
	}
}

// --- verification: the answer an extension service cannot work out for itself -

const proofToken = "sekret-lab-auth-token"

// TestVerifyControlProofAcceptsWhatItMints closes the loop on the format: what this
// daemon hands a browser is what this daemon will later accept back from the service
// that browser landed on.
func TestVerifyControlProofAcceptsWhatItMints(t *testing.T) {
	now := time.Now()
	proof := mintControlProof(proofToken, controlProofTTL)
	if !verifyControlProof(proofToken, proof, now, controlProofMaxTTL) {
		t.Fatalf("a freshly minted proof did not verify: %q", proof)
	}
}

func TestVerifyControlProofRefusesWhatItDidNotMint(t *testing.T) {
	now := time.Now()
	fresh := now.Add(controlProofTTL).Unix()
	cases := []struct {
		name  string
		token string
		wire  string
	}{
		{"another lab's token", proofToken, controlProofFor("a-different-lab", fresh)},
		// The ceiling is what stops a captured token minting an eternal pass.
		{"expiry beyond the ceiling", proofToken, controlProofFor(proofToken, now.Add(controlProofMaxTTL+time.Minute).Unix())},
		{"already expired", proofToken, controlProofFor(proofToken, now.Add(-time.Second).Unix())},
		{"tampered signature", proofToken, strconv.FormatInt(fresh, 10) + ".AAAA"},
		{"no dot", proofToken, "not-a-proof"},
		{"empty proof", proofToken, ""},
		// A daemon holding no token has no key to check against, so nothing verifies.
		{"no token held", "", controlProofFor(proofToken, fresh)},
	}
	for _, c := range cases {
		if verifyControlProof(c.token, c.wire, now, controlProofMaxTTL) {
			t.Errorf("%s: verified, want refused", c.name)
		}
	}
}

// postProof exercises the route an extension service calls when it holds no token of
// its own and so cannot judge an arriving proof.
func postProof(t *testing.T, s *poolState, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	s.handleControlProof(rec, httptest.NewRequest("POST", "/api/v1/control-proof", strings.NewReader(body)))
	return rec
}

func TestControlProofRouteAnswersTheVerdictAndNothingElse(t *testing.T) {
	s := newPoolState("default", 8080)
	s.authToken = proofToken

	rec := postProof(t, s, `{"proof":`+strconv.Quote(mintControlProof(proofToken, controlProofTTL))+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("fresh proof = %d, want 200", rec.Code)
	}
	var ok struct{ OK bool }
	if err := json.Unmarshal(rec.Body.Bytes(), &ok); err != nil || !ok.OK {
		t.Fatalf("body = %q, want {\"ok\":true}", rec.Body.String())
	}

	rec = postProof(t, s, `{"proof":`+strconv.Quote(controlProofFor("a-different-lab", time.Now().Add(time.Minute).Unix()))+`}`)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("proof from another lab = %d, want 401", rec.Code)
	}
}

// No token is not "not valid": a daemon that cannot judge says so with a 503, so the
// asking service reports "could not check" rather than locking an operator out over
// a verdict nobody reached.
func TestControlProofRouteSelfGatesWithoutAToken(t *testing.T) {
	s := newPoolState("default", 8080)
	s.authToken = ""
	if rec := postProof(t, s, `{"proof":"1900000000.AAAA"}`); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("no lab auth token = %d, want 503", rec.Code)
	}
}

// The redirect that carries an operator from the dashboard into a service UI hands
// over the proof in the FRAGMENT, so it never reaches a server or an access log --
// and what it hands over is a proof this daemon will verify.
func TestGoStashCarriesAVerifiableProofInTheFragment(t *testing.T) {
	s := newPoolState("default", 8080)
	s.authToken = proofToken
	hid := "42512149e3dc437ca677a40828382528"
	s.hosts[hid] = &hostView{
		HostId:           hid,
		ExtensionTargets: map[string]string{"download-agent-service": "http://10.0.0.9"},
		LastSeenUnixMs:   time.Now().UnixMilli(),
	}
	seedExtensionHealth(s, hid, "download-agent-service", "http://10.0.0.9")

	rec := httptest.NewRecorder()
	s.handleGoStash(rec, httptest.NewRequest("GET", "/go/stash?host="+hid+"&area=download-agent-service", nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", rec.Code)
	}
	loc := rec.Header().Get("Location")
	base, frag, found := strings.Cut(loc, "#yctl=")
	if !found {
		t.Fatalf("Location = %q, want a #yctl= fragment", loc)
	}
	if base != "http://10.0.0.9" {
		t.Errorf("redirect target = %q, want http://10.0.0.9", base)
	}
	if !verifyControlProof(proofToken, frag, time.Now(), controlProofMaxTTL) {
		t.Errorf("the fragment %q is not a proof this daemon would accept back", frag)
	}
}

// With no token there is nothing to mint, so the link still works and the service UI
// simply asks for the lab token as it always did.
func TestGoStashCarriesNoFragmentWithoutAToken(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "42512149e3dc437ca677a40828382528"
	s.hosts[hid] = &hostView{
		HostId:           hid,
		ExtensionTargets: map[string]string{"stash-service": "http://10.0.0.5"},
		LastSeenUnixMs:   time.Now().UnixMilli(),
	}
	seedExtensionHealth(s, hid, stashArea, "http://10.0.0.5")

	rec := httptest.NewRecorder()
	s.handleGoStash(rec, httptest.NewRequest("GET", "/go/stash?host="+hid, nil))
	if loc := rec.Header().Get("Location"); loc != "http://10.0.0.5" {
		t.Errorf("Location = %q, want the bare target with no fragment", loc)
	}
}
