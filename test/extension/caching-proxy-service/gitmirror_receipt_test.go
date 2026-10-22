// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var updateMirrorVectors = flag.Bool("update-mirror-vectors", false, "regenerate committed mirror signing vectors")

type mirrorTestVector struct {
	Name           string         `json:"name"`
	ExpectedReason string         `json:"expectedReason"`
	Envelope       mirrorEnvelope `json:"envelope"`
}
type mirrorTestVectors struct {
	SchemaVersion int                `json:"schemaVersion"`
	KeyID         string             `json:"keyId"`
	PublicKey     string             `json:"publicKey"`
	Now           string             `json:"now"`
	Request       mirrorRequest      `json:"request"`
	Vectors       []mirrorTestVector `json:"vectors"`
}

func mirrorFixtureKey(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs("testdata/git-mirror/receipts/test-key.pem")
	if err != nil {
		t.Fatal(err)
	}
	return path
}
func TestMirrorReceiptVectors(t *testing.T) {
	signer, err := loadMirrorSigner(mirrorFixtureKey(t))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	receipt := mirrorReceipt{SchemaVersion: 1, KeyID: signer.keyID, Nonce: "AAAAAAAAAAAAAAAAAAAAAA", Repository: "example/repo",
		Ref: "refs/heads/main", SelectedSHA: strings.Repeat("a", 40), FetchRef: "refs/yuruna/pins/" + strings.Repeat("a", 40),
		ObjectReady: true, UpstreamOutcome: "confirmed", OriginCheckedAt: mirrorStamp(now), IssuedAt: mirrorStamp(now), ExpiresAt: mirrorStamp(now.Add(5 * time.Minute)), Status: "ready"}
	der, _ := x509.MarshalPKIXPublicKey(&signer.key.PublicKey)
	vectors := mirrorTestVectors{SchemaVersion: 1, KeyID: signer.keyID, PublicKey: base64.StdEncoding.EncodeToString(der), Now: mirrorStamp(now),
		Request: mirrorRequest{Repository: receipt.Repository, Ref: receipt.Ref, Nonce: receipt.Nonce}}
	add := func(name, reason string, change func(*mirrorReceipt)) {
		r := receipt
		if change != nil {
			change(&r)
		}
		b, _ := json.Marshal(r)
		envelope, e := signer.signBytes(b)
		if e != nil {
			t.Fatal(e)
		}
		vectors.Vectors = append(vectors.Vectors, mirrorTestVector{Name: name, ExpectedReason: reason, Envelope: envelope})
	}
	add("valid", "", nil)
	add("pending", "", func(r *mirrorReceipt) {
		r.Status, r.UpstreamOutcome = "pending", "not-checked"
		r.ObjectReady = false
		r.SelectedSHA, r.FetchRef, r.OriginCheckedAt = "", "", ""
		r.OperationID, r.OperationExpiresAt = "BBBBBBBBBBBBBBBBBBBBBB", mirrorStamp(now.Add(30*time.Minute))
	})
	for _, outcome := range []string{"capacity", "local-error"} {
		add(outcome, "", func(r *mirrorReceipt) {
			r.Status, r.UpstreamOutcome = "error", outcome
			r.ObjectReady = false
			r.SelectedSHA, r.FetchRef, r.OriginCheckedAt = "", "", ""
			r.Reason = "mirror-unavailable"
			if outcome == "capacity" {
				r.Reason, r.Detail = "mirror-capacity-exhausted", "storage"
			}
		})
	}
	add("wrong-nonce", "mirror-receipt-invalid", func(r *mirrorReceipt) { r.Nonce = "BBBBBBBBBBBBBBBBBBBBBB" })
	add("wrong-repository", "mirror-receipt-invalid", func(r *mirrorReceipt) { r.Repository = "example/other" })
	add("wrong-ref", "mirror-receipt-invalid", func(r *mirrorReceipt) { r.Ref = "refs/heads/other" })
	add("expired", "mirror-receipt-time-invalid", func(r *mirrorReceipt) {
		r.IssuedAt = mirrorStamp(now.Add(-10 * time.Minute))
		r.ExpiresAt = mirrorStamp(now.Add(-5 * time.Minute))
		r.OriginCheckedAt = r.IssuedAt
	})
	add("future-issued", "mirror-receipt-time-invalid", func(r *mirrorReceipt) {
		r.IssuedAt = mirrorStamp(now.Add(61 * time.Second))
		r.ExpiresAt = mirrorStamp(now.Add(361 * time.Second))
	})
	add("unsupported-version", "mirror-unsupported", func(r *mirrorReceipt) { r.SchemaVersion = 2 })
	add("malformed-object", "mirror-receipt-invalid", func(r *mirrorReceipt) { r.SelectedSHA = strings.Repeat("z", 40) })
	add("wrong-fetch-ref", "mirror-receipt-invalid", func(r *mirrorReceipt) { r.FetchRef = "refs/heads/main" })
	add("wrong-payload-key", "mirror-receipt-invalid", func(r *mirrorReceipt) { r.KeyID = strings.Repeat("b", 64) })
	valid := vectors.Vectors[0].Envelope
	b, _ := base64.StdEncoding.DecodeString(valid.Payload)
	duplicate := append([]byte(`{"nonce":"AAAAAAAAAAAAAAAAAAAAAA",`), b[1:]...)
	envelope, _ := signer.signBytes(duplicate)
	vectors.Vectors = append(vectors.Vectors, mirrorTestVector{Name: "duplicate-key", ExpectedReason: "mirror-receipt-invalid", Envelope: envelope})
	envelope, _ = signer.signBytes(append(b, bytes.Repeat([]byte(" "), (64<<10)+1)...))
	vectors.Vectors = append(vectors.Vectors, mirrorTestVector{Name: "oversized-payload", ExpectedReason: "mirror-receipt-invalid", Envelope: envelope})
	envelope = valid
	envelope.Payload = base64.StdEncoding.EncodeToString(bytes.Replace(b, []byte("example/repo"), []byte("example/evil"), 1))
	vectors.Vectors = append(vectors.Vectors, mirrorTestVector{Name: "tampered-payload", ExpectedReason: "mirror-receipt-invalid", Envelope: envelope})
	envelope = valid
	envelope.KeyID = strings.Repeat("b", 64)
	vectors.Vectors = append(vectors.Vectors, mirrorTestVector{Name: "unknown-key", ExpectedReason: "mirror-key-not-enrolled", Envelope: envelope})
	expected, _ := json.MarshalIndent(vectors, "", "  ")
	expected = append(expected, '\n')
	path := "testdata/git-mirror/receipts/vectors.json"
	if *updateMirrorVectors {
		if err = os.WriteFile(path, expected, 0644); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, expected) {
		t.Fatal("receipt vectors differ from production signer; inspect the contract before explicit -update-mirror-vectors regeneration")
	}
}

func TestMirrorSignerNeverMintsMissingKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent.pem")
	if _, err := loadMirrorSigner(path); err == nil {
		t.Fatal("missing key accepted")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("missing signing key was created")
	}
}
