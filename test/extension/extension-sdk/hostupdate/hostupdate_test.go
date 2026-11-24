// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42e34357-a046-4e0f-b5a4-6d6838434ced

package hostupdate

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func goldenKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	_, key := loadGolden(t)
	return key
}

func TestMintIssuesAProofTheVerifierAccepts(t *testing.T) {
	key := goldenKey(t)
	s, err := NewSigner(key)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1900000000, 0)
	wire, c, err := s.Mint("42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90", ScopeFull, 3600, "", now)
	if err != nil {
		t.Fatal(err)
	}
	if c.ExpiryUnix-c.IssuedUnix != int64(ProofTTL/time.Second) {
		t.Fatalf("lifetime %d", c.ExpiryUnix-c.IssuedUnix)
	}
	if len(wire) > MaxWireBytes {
		t.Fatalf("a minted proof is %d bytes, over the %d bound", len(wire), MaxWireBytes)
	}
	want := Claims{HostID: c.HostID, RequestID: c.RequestID, Scope: ScopeFull, DrainSeconds: 3600}
	if _, reason := Verify(&key.PublicKey, wire, want, now.Add(ProofTTL), MaxLifetime, Skew); reason != ReasonOK {
		t.Fatalf("verify: %s", reason)
	}
	if s.KeyTag() != KeyTag(&key.PublicKey) {
		t.Fatal("signer tag differs from the public key tag")
	}
}

func TestMintRefusesEveryInvalidField(t *testing.T) {
	s, err := NewSigner(goldenKey(t))
	if err != nil {
		t.Fatal(err)
	}
	ok := struct {
		host, req, scope string
		drain            int
		commit           string
	}{"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90", ScopeRestart, 7200, ""}
	for name, mutate := range map[string]func(){
		"dashed host":       func() { ok.host = "42aaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" },
		"uppercase request": func() { ok.req = strings.ToUpper(ok.req) },
		"scope":             func() { ok.scope = "reboot" },
		"drain below":       func() { ok.drain = 59 },
		"drain above":       func() { ok.drain = 21601 },
		"commit":            func() { ok.commit = "3EFE0768A" },
	} {
		saved := ok
		mutate()
		if _, _, err := s.Mint(ok.host, ok.req, ok.scope, ok.drain, ok.commit, time.Unix(1900000000, 0)); !errors.Is(err, ErrInvalidClaim) {
			t.Errorf("%s: got %v, want ErrInvalidClaim", name, err)
		}
		ok = saved
	}
}

func TestSignerRefusesAKeyBelowTheFloor(t *testing.T) {
	small, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewSigner(small); !errors.Is(err, ErrKeyTooSmall) {
		t.Fatalf("got %v", err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(small)
	if _, err := ParsePrivateKeyPEM(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})); !errors.Is(err, ErrKeyTooSmall) {
		t.Fatalf("parse: got %v", err)
	}
	line, _ := FormatPublicKey(&small.PublicKey)
	if _, err := ParsePublicKey(line); !errors.Is(err, ErrKeyTooSmall) {
		t.Fatalf("public: got %v", err)
	}
}

func TestParsePrivateKeyRefusesOtherShapes(t *testing.T) {
	good, err := os.ReadFile(filepath.Join("testdata", "test-key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(good)
	parsed, _ := x509.ParsePKCS8PrivateKey(block.Bytes)
	pkcs1 := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(parsed.(*rsa.PrivateKey))})
	for name, raw := range map[string][]byte{
		"empty":          nil,
		"PKCS#1 block":   pkcs1,
		"two blocks":     append(append([]byte{}, good...), good...),
		"trailing text":  append(append([]byte{}, good...), []byte("extra\n")...),
		"public key pem": pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: []byte{1, 2, 3}}),
	} {
		if _, err := ParsePrivateKeyPEM(raw); !errors.Is(err, ErrKeyMalformed) {
			t.Errorf("%s: got %v, want ErrKeyMalformed", name, err)
		}
	}
}

func TestLoadSigningKeyFileChecksTheFile(t *testing.T) {
	good, err := os.ReadFile(filepath.Join("testdata", "test-key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "update-signing.key")
	if err := os.WriteFile(path, good, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadSigningKeyFile(path); err != nil {
		t.Fatalf("owner-only key refused: %v", err)
	}
	if _, err := LoadSigningKeyFile(filepath.Join(dir, "absent")); !errors.Is(err, ErrKeyMissing) {
		t.Fatalf("absent: %v", err)
	}
	if err := os.Mkdir(filepath.Join(dir, "a-directory"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadSigningKeyFile(filepath.Join(dir, "a-directory")); !errors.Is(err, ErrKeyNotRegular) {
		t.Fatalf("directory: %v", err)
	}
	if runtime.GOOS == "windows" {
		return
	}
	link := filepath.Join(dir, "link.key")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadSigningKeyFile(link); !errors.Is(err, ErrKeyNotRegular) {
		t.Fatalf("link: %v", err)
	}
	if err := os.Chmod(path, 0o640); err != nil {
		t.Fatal(err)
	}
	_, err = LoadSigningKeyFile(path)
	if !errors.Is(err, ErrKeyOpenPermissions) {
		t.Fatalf("group-readable: %v", err)
	}
	if strings.Contains(err.Error(), "PRIVATE") {
		t.Fatal("the error carries file content")
	}
}

func TestParsePublicKeyRefusesOtherLines(t *testing.T) {
	v, _ := loadGolden(t)
	for _, line := range []string{"", "yupk2." + strings.TrimPrefix(v.PublicKey, "yupk1."), v.PublicKey + "=", v.PublicKey + "\n", "yupk1.AAAA"} {
		if _, err := ParsePublicKey(line); err == nil {
			t.Errorf("%q accepted", line)
		}
	}
}
