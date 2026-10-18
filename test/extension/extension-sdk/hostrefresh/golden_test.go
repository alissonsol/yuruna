// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package hostrefresh

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// goldenVectors is testdata/vectors.json: the one vector file the Go SDK,
// pool-control, the aggregator and the PowerShell verifier all read, so a
// drift in any HMAC input, encoding or field order fails every one of them
// against the same literal values.
type goldenVectors struct {
	SchemaVersion int `json:"schemaVersion"`
	Legacy        struct {
		Token        string `json:"token"`
		ExpiryUnix   int64  `json:"expiryUnix"`
		Wire         string `json:"wire"`
		ControlTag   string `json:"controlTag"`
		VerifyAtUnix int64  `json:"verifyAtUnix"`
	} `json:"legacy"`
	Versioned struct {
		AuthorityText      string `json:"authorityText"`
		HostID             string `json:"hostId"`
		RequestID          string `json:"requestId"`
		Tier               string `json:"tier"`
		MaxRung            string `json:"maxRung"`
		IssuedUnix         int64  `json:"issuedUnix"`
		ExpiryUnix         int64  `json:"expiryUnix"`
		HostKey            string `json:"hostKey"`
		HostKeyLine        string `json:"hostKeyLine"`
		KeyTag             string `json:"keyTag"`
		AuthorityTag       string `json:"authorityTag"`
		Wire               string `json:"wire"`
		SkewSeconds        int64  `json:"skewSeconds"`
		MaxLifetimeSeconds int64  `json:"maxLifetimeSeconds"`
	} `json:"versioned"`
	Cases []goldenCase `json:"cases"`
}

type goldenCase struct {
	Name      string `json:"name"`
	Wire      string `json:"wire"`
	Key       string `json:"key"`
	HostID    string `json:"hostId"`
	RequestID string `json:"requestId"`
	Tier      string `json:"tier"`
	MaxRung   string `json:"maxRung"`
	NowUnix   int64  `json:"nowUnix"`
	Want      string `json:"want"`
}

func loadVectors(t testing.TB) goldenVectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "vectors.json"))
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var v goldenVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse vectors: %v", err)
	}
	if v.SchemaVersion != 1 || len(v.Cases) < 20 {
		t.Fatalf("vector file is not the expected schema: version %d, %d cases", v.SchemaVersion, len(v.Cases))
	}
	return v
}

func caseKey(t testing.TB, v goldenVectors, name string) []byte {
	t.Helper()
	switch name {
	case "golden":
		k, err := DeriveHostKey([]byte(v.Versioned.AuthorityText), v.Versioned.HostID)
		if err != nil {
			t.Fatal(err)
		}
		return k
	case "empty":
		return nil
	case "authority":
		return []byte(v.Versioned.AuthorityText)
	}
	t.Fatalf("unknown vector key %q", name)
	return nil
}

func TestGoldenDerivationTagsAndWire(t *testing.T) {
	v := loadVectors(t)
	authority := []byte(v.Versioned.AuthorityText)
	key, err := DeriveHostKey(authority, v.Versioned.HostID)
	if err != nil {
		t.Fatal(err)
	}
	if got := base64.RawURLEncoding.EncodeToString(key); got != v.Versioned.HostKey {
		t.Fatalf("host key = %s, want %s", got, v.Versioned.HostKey)
	}
	if got := KeyTag(key); got != v.Versioned.KeyTag {
		t.Fatalf("key tag = %s, want %s", got, v.Versioned.KeyTag)
	}
	if got := AuthorityTag(authority); got != v.Versioned.AuthorityTag {
		t.Fatalf("authority tag = %s, want %s", got, v.Versioned.AuthorityTag)
	}
	line, err := FormatHostKey(v.Versioned.HostID, key)
	if err != nil || line != v.Versioned.HostKeyLine {
		t.Fatalf("host key line = %q (%v), want %q", line, err, v.Versioned.HostKeyLine)
	}
	hid, back, err := ParseHostKey(v.Versioned.HostKeyLine)
	if err != nil || hid != v.Versioned.HostID || string(back) != string(key) {
		t.Fatalf("ParseHostKey(golden) = %q %v", hid, err)
	}
	wire, err := Proof(key, Claims{HostID: v.Versioned.HostID, RequestID: v.Versioned.RequestID, Tier: v.Versioned.Tier,
		MaxRung: v.Versioned.MaxRung, IssuedUnix: v.Versioned.IssuedUnix, ExpiryUnix: v.Versioned.ExpiryUnix})
	if err != nil {
		t.Fatal(err)
	}
	if wire != v.Versioned.Wire {
		t.Fatalf("wire mismatch (Go must match the shared vector):\n got  %s\n want %s", wire, v.Versioned.Wire)
	}
	// The golden constants of this package are the vector's constants.
	if v.Versioned.SkewSeconds != int64(Skew/time.Second) || v.Versioned.MaxLifetimeSeconds != int64(MaxLifetime/time.Second) {
		t.Fatalf("vector skew/lifetime %d/%d disagree with the package constants", v.Versioned.SkewSeconds, v.Versioned.MaxLifetimeSeconds)
	}
}

// Every case of the shared verdict table, with the explicit clock and skew the
// PowerShell verifier also receives.
func TestGoldenVerdictTable(t *testing.T) {
	v := loadVectors(t)
	skew := time.Duration(v.Versioned.SkewSeconds) * time.Second
	life := time.Duration(v.Versioned.MaxLifetimeSeconds) * time.Second
	for _, c := range v.Cases {
		t.Run(c.Name, func(t *testing.T) {
			want := Claims{HostID: c.HostID, RequestID: c.RequestID, Tier: c.Tier, MaxRung: c.MaxRung}
			got, reason := Verify(caseKey(t, v, c.Key), c.Wire, want, time.Unix(c.NowUnix, 0), life, skew)
			if reason != c.Want {
				t.Fatalf("verdict = %s, want %s", reason, c.Want)
			}
			if reason == ReasonOK && (got.HostID != c.HostID || got.RequestID != c.RequestID || got.Tier != c.Tier || got.MaxRung != c.MaxRung) {
				t.Fatalf("accepted claims %+v do not match the request", got)
			}
		})
	}
}

// The table covers every verdict the verifier can return, so no reason is
// reachable only in production.
func TestGoldenVerdictTableCoversEveryReason(t *testing.T) {
	v := loadVectors(t)
	seen := map[string]bool{}
	for _, c := range v.Cases {
		seen[c.Want] = true
	}
	for _, r := range []string{ReasonOK, ReasonProofMissing, ReasonProofMalformed, ReasonProofVersionUnsupported, ReasonProofInvalid,
		ReasonProofHostMismatch, ReasonProofRequestMismatch, ReasonProofPolicyMismatch, ReasonProofLifetimeInvalid,
		ReasonProofNotYetValid, ReasonProofExpired} {
		if !seen[r] {
			t.Errorf("no vector case expects %s", r)
		}
	}
}

// The legacy vector and the versioned one cannot be confused: the legacy wire
// fails the refresh parser, and the versioned wire does not look like a legacy
// "<expiry>.<std base64>" proof.
func TestGoldenFormatsAreDisjoint(t *testing.T) {
	v := loadVectors(t)
	if strings.HasPrefix(v.Versioned.Wire, v.Legacy.Wire[:strings.IndexByte(v.Legacy.Wire, '.')]) {
		t.Fatal("the versioned wire starts like a legacy expiry")
	}
	key := caseKey(t, v, "golden")
	if _, r := Verify(key, v.Legacy.Wire, Claims{}, time.Unix(v.Legacy.VerifyAtUnix, 0), MaxLifetime, Skew); r != ReasonProofMalformed {
		t.Fatalf("legacy wire in the refresh verifier = %s, want %s", r, ReasonProofMalformed)
	}
}

// Verify is fed attacker-controlled header text, so it must return a verdict
// for any input rather than panic. `go test` runs the seed corpus; a fuzzing
// session extends it.
func FuzzVerify(f *testing.F) {
	v := loadVectors(f)
	for _, c := range v.Cases {
		f.Add(c.Wire, c.HostID, c.RequestID, c.Tier, c.MaxRung, c.NowUnix)
	}
	f.Add(strings.Repeat(".", 7), "", "", "", "", int64(-1))
	f.Add("yhr1........", "x", "y", "z", "w", int64(1)<<62)
	key := caseKey(f, v, "golden")
	f.Fuzz(func(t *testing.T, wire, host, req, tier, rung string, now int64) {
		_, reason := Verify(key, wire, Claims{HostID: host, RequestID: req, Tier: tier, MaxRung: rung}, time.Unix(now, 0), MaxLifetime, Skew)
		switch reason {
		case ReasonOK, ReasonProofMissing, ReasonProofMalformed, ReasonProofVersionUnsupported, ReasonProofInvalid,
			ReasonProofHostMismatch, ReasonProofRequestMismatch, ReasonProofPolicyMismatch, ReasonProofLifetimeInvalid,
			ReasonProofNotYetValid, ReasonProofExpired:
		default:
			t.Fatalf("Verify returned an undeclared reason %q", reason)
		}
	})
}
