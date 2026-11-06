// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 426572d2-e30e-42f3-97c4-5ef997f182dd

package labgate

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"yuruna.com/test/extension/extension-sdk/controlproof"
)

// sharedVectors reads the one vector file the aggregator, hostctl, the host's
// PowerShell verifier and the refresh proof all pin. This gate refuses the
// legacy control proof, so it must agree with that file on what that proof is.
func sharedVectors(t *testing.T) (legacyToken, legacyWire string, legacyExpiry, verifyAt int64, refreshWire string) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "hostrefresh", "testdata", "vectors.json"))
	if err != nil {
		t.Fatalf("read shared vectors: %v", err)
	}
	var v struct {
		Legacy struct {
			Token        string `json:"token"`
			ExpiryUnix   int64  `json:"expiryUnix"`
			Wire         string `json:"wire"`
			VerifyAtUnix int64  `json:"verifyAtUnix"`
		} `json:"legacy"`
		Versioned struct {
			Wire string `json:"wire"`
		} `json:"versioned"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse shared vectors: %v", err)
	}
	return v.Legacy.Token, v.Legacy.Wire, v.Legacy.ExpiryUnix, v.Legacy.VerifyAtUnix, v.Versioned.Wire
}

// The legacy vector is still what its HMAC rule produces, and this gate refuses
// it by its shape: a proof that names no audience never reaches a verifier and
// buys no session.
func TestTheLegacyControlProofIsRefused(t *testing.T) {
	token, wire, expiry, _, _ := sharedVectors(t)
	if wire != "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs=" {
		t.Fatalf("the shared legacy vector moved: %q", wire)
	}
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|" + strconv.FormatInt(expiry, 10)))
	if got := strconv.FormatInt(expiry, 10) + "." + base64.StdEncoding.EncodeToString(mac.Sum(nil)); got != wire {
		t.Fatalf("legacy rule drifted:\n got  %s\n want %s", got, wire)
	}
	if controlProofRE.MatchString(wire) {
		t.Error("the local shape check accepted the legacy golden proof")
	}
	g := New(Options{BearerToken: token})
	body, _ := json.Marshal(map[string]string{"proof": controlproof.Mint(token, time.Minute)})
	w := httptest.NewRecorder()
	g.HandleProofUnlock(w, httptest.NewRequest(http.MethodPost, "/api/unlock-proof", strings.NewReader(string(body))))
	if w.Code != http.StatusBadRequest {
		t.Errorf("unlock with a fresh legacy proof = %d, want 400", w.Code)
	}
	var reply map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &reply)
	if reply["code"] != "auth.proof_shape" {
		t.Errorf("refusal code = %v, want auth.proof_shape", reply["code"])
	}
	if len(w.Result().Cookies()) != 0 {
		t.Fatal("a legacy proof bought a session cookie")
	}
}

// A refresh proof is never a control proof: the control-proof verifier refuses
// it under the very token that derived its key.
func TestRefreshWireIsNotALegacyProof(t *testing.T) {
	token, _, _, verifyAt, refreshWire := sharedVectors(t)
	if !strings.HasPrefix(refreshWire, "yhr1.") {
		t.Fatalf("unexpected shared refresh vector %q", refreshWire)
	}
	if controlproof.VerifyFor(token, refreshWire, "", time.Unix(verifyAt, 0), ControlProofMaxTTL) {
		t.Fatal("the control-proof verifier accepted a refresh proof")
	}
	if controlProofRE.MatchString(refreshWire) {
		t.Fatal("the local shape check accepted a refresh proof")
	}
}

// Posting the refresh proof to the unlock route cannot buy a session: it fails
// the local shape check, is not counted as a guess, and sets no cookie.
func TestRefreshWireCannotUnlockASession(t *testing.T) {
	token, _, _, _, refreshWire := sharedVectors(t)
	g := New(Options{BearerToken: token})
	body, _ := json.Marshal(map[string]string{"proof": refreshWire})
	w := httptest.NewRecorder()
	g.HandleProofUnlock(w, httptest.NewRequest(http.MethodPost, "/api/unlock-proof", strings.NewReader(string(body))))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("unlock with a refresh proof = %d, want 400", w.Code)
	}
	var reply map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &reply)
	if reply["code"] != "auth.proof_shape" {
		t.Fatalf("refusal code = %v, want auth.proof_shape", reply["code"])
	}
	if len(w.Result().Cookies()) != 0 {
		t.Fatal("a refresh proof bought a session cookie")
	}
}
