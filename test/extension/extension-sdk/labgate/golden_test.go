// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

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
)

// sharedVectors reads the one vector file the aggregator, hostctl, the host's
// PowerShell verifier and the refresh proof all pin. This gate verifies the
// legacy control proof too, so it must agree with that file byte for byte.
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

// The legacy vector is literally what this package's verifier accepts, inside
// its window, and what its own HMAC rule produces.
func TestLegacyControlProofGolden(t *testing.T) {
	token, wire, expiry, verifyAt, _ := sharedVectors(t)
	if wire != "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs=" {
		t.Fatalf("the shared legacy vector moved: %q", wire)
	}
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|" + strconv.FormatInt(expiry, 10)))
	if got := strconv.FormatInt(expiry, 10) + "." + base64.StdEncoding.EncodeToString(mac.Sum(nil)); got != wire {
		t.Fatalf("legacy rule drifted:\n got  %s\n want %s", got, wire)
	}
	if !verifyControlProof(token, wire, time.Unix(verifyAt, 0), ControlProofMaxTTL) {
		t.Fatal("the legacy golden proof must verify inside its window")
	}
	if verifyControlProof(token, wire, time.Unix(expiry+1, 0), ControlProofMaxTTL) {
		t.Fatal("the legacy golden proof verified after its expiry")
	}
	if !controlProofRE.MatchString(wire) {
		t.Fatal("the legacy golden proof fails the local shape check")
	}
}

// A refresh proof is never a legacy proof: the legacy verifier refuses it
// under the very token that derived its key.
func TestRefreshWireIsNotALegacyProof(t *testing.T) {
	token, _, _, verifyAt, refreshWire := sharedVectors(t)
	if !strings.HasPrefix(refreshWire, "yhr1.") {
		t.Fatalf("unexpected shared refresh vector %q", refreshWire)
	}
	if verifyControlProof(token, refreshWire, time.Unix(verifyAt, 0), ControlProofMaxTTL) {
		t.Fatal("the legacy verifier accepted a refresh proof")
	}
	if controlProofRE.MatchString(refreshWire) {
		t.Fatal("the legacy shape check accepted a refresh proof")
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
