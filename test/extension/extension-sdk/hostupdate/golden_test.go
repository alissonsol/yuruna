// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42baa9ce-08ed-4d35-8e35-575525241e54

package hostupdate

import (
	"crypto/rsa"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// goldenVectors is testdata/vectors.json: the vector file this package and
// the PowerShell verifier both read. Its signatures were made with the openssl
// CLI, so a drift in the message, the field order or the encoding fails both
// against the same literal values.
type goldenVectors struct {
	SchemaVersion      int    `json:"schemaVersion"`
	PrivateKeyFile     string `json:"privateKeyFile"`
	PublicKey          string `json:"publicKey"`
	KeyTag             string `json:"keyTag"`
	OtherPublicKey     string `json:"otherPublicKey"`
	Message            string `json:"message"`
	Wire               string `json:"wire"`
	WireNoCommit       string `json:"wireNoCommit"`
	SkewSeconds        int64  `json:"skewSeconds"`
	MaxLifetimeSeconds int64  `json:"maxLifetimeSeconds"`
	MaxWireBytes       int    `json:"maxWireBytes"`
	Claims             struct {
		HostID       string `json:"hostId"`
		RequestID    string `json:"requestId"`
		Scope        string `json:"scope"`
		DrainSeconds int    `json:"drainSeconds"`
		ExpectCommit string `json:"expectCommit"`
		Iat          int64  `json:"iat"`
		Exp          int64  `json:"exp"`
	} `json:"claims"`
	Cases []struct {
		Name         string `json:"name"`
		Wire         string `json:"wire"`
		Key          string `json:"key"`
		HostID       string `json:"hostId"`
		RequestID    string `json:"requestId"`
		Scope        string `json:"scope"`
		DrainSeconds int    `json:"drainSeconds"`
		ExpectCommit string `json:"expectCommit"`
		NowUnix      int64  `json:"nowUnix"`
		Want         string `json:"want"`
	} `json:"cases"`
}

func loadGolden(t *testing.T) (goldenVectors, *rsa.PrivateKey) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v goldenVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if v.SchemaVersion != 1 {
		t.Fatalf("schemaVersion %d", v.SchemaVersion)
	}
	pemBytes, err := os.ReadFile(filepath.Join("testdata", v.PrivateKeyFile))
	if err != nil {
		t.Fatal(err)
	}
	key, err := ParsePrivateKeyPEM(pemBytes)
	if err != nil {
		t.Fatal(err)
	}
	return v, key
}

func TestGoldenProofMatchesTheReferenceSignature(t *testing.T) {
	v, key := loadGolden(t)
	c := Claims{HostID: v.Claims.HostID, RequestID: v.Claims.RequestID, Scope: v.Claims.Scope, DrainSeconds: v.Claims.DrainSeconds,
		ExpectCommit: v.Claims.ExpectCommit, IssuedUnix: v.Claims.Iat, ExpiryUnix: v.Claims.Exp}
	if got := Message(c); got != v.Message {
		t.Fatalf("message\n got %q\nwant %q", got, v.Message)
	}
	wire, err := Proof(key, c)
	if err != nil {
		t.Fatal(err)
	}
	if wire != v.Wire {
		t.Fatalf("wire differs from the reference signature\n got %s\nwant %s", wire, v.Wire)
	}
	c.ExpectCommit = ""
	if wire, _ = Proof(key, c); wire != v.WireNoCommit {
		t.Fatalf("wire without expectCommit differs\n got %s\nwant %s", wire, v.WireNoCommit)
	}
	line, err := FormatPublicKey(&key.PublicKey)
	if err != nil || line != v.PublicKey {
		t.Fatalf("public key line %q, %v", line, err)
	}
	if tag := KeyTag(&key.PublicKey); tag != v.KeyTag {
		t.Fatalf("key tag %q, want %q", tag, v.KeyTag)
	}
	if v.MaxWireBytes != MaxWireBytes || v.SkewSeconds != int64(Skew/time.Second) || v.MaxLifetimeSeconds != int64(MaxLifetime/time.Second) {
		t.Fatalf("vector bounds %d/%d/%d differ from the package constants", v.MaxWireBytes, v.SkewSeconds, v.MaxLifetimeSeconds)
	}
}

func TestGoldenCases(t *testing.T) {
	v, _ := loadGolden(t)
	pub, err := ParsePublicKey(v.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range v.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			var verifier *rsa.PublicKey
			if tc.Key == "golden" {
				verifier = pub
			}
			want := Claims{HostID: tc.HostID, RequestID: tc.RequestID, Scope: tc.Scope, DrainSeconds: tc.DrainSeconds, ExpectCommit: tc.ExpectCommit}
			_, got := Verify(verifier, tc.Wire, want, time.Unix(tc.NowUnix, 0), MaxLifetime, Skew)
			if got != tc.Want {
				t.Fatalf("got %s, want %s", got, tc.Want)
			}
		})
	}
}
