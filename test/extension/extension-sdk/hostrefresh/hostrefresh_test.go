// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package hostrefresh

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"yuruna.com/test/extension/extension-sdk/pool"
)

func secret(fill byte) []byte { return bytes.Repeat([]byte{fill}, SecretBytes) }

func TestCanonicalHostIDAcceptsOnlyThe32HexForm(t *testing.T) {
	for in, want := range map[string]string{
		"42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":     "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"42AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA":     "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"42aaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa": "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	} {
		if got, ok := CanonicalHostID(in); !ok || got != want {
			t.Errorf("CanonicalHostID(%q) = %q,%v, want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "42aa", "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "zzaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", " 42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} {
		if _, ok := CanonicalHostID(bad); ok {
			t.Errorf("CanonicalHostID(%q) accepted a non-canonical id", bad)
		}
	}
}

func TestRequestIDsAreCanonicalAndRandom(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 64; i++ {
		id, err := NewRequestID()
		if err != nil {
			t.Fatal(err)
		}
		if !ValidRequestID(id) || id[14] != '4' || !strings.ContainsRune("89ab", rune(id[19])) {
			t.Fatalf("NewRequestID() = %q is not a canonical v4 UUID", id)
		}
		if seen[id] {
			t.Fatalf("NewRequestID repeated %q", id)
		}
		seen[id] = true
	}
	for _, bad := range []string{"4242AAAA-0000-4000-8000-000000000001", "4242aaaa00004000800000000000000001", "{4242aaaa-0000-4000-8000-000000000001}", ""} {
		if ValidRequestID(bad) {
			t.Errorf("ValidRequestID(%q) = true", bad)
		}
	}
}

func TestRemoteRungsAreTheRestartTier(t *testing.T) {
	want := []string{pool.RungProbe, pool.RungReclaim, pool.RungStartIfStopped, pool.RungRestartIfHung, pool.RungRestartBroker}
	got := RemoteRungNames()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("remote rungs = %v, want %v", got, want)
	}
	for _, r := range pool.RefreshRungNames() {
		order, _ := pool.RefreshRungOrder(r)
		if ValidRemoteRung(r) != (order <= 4) || !ValidRung(r) {
			t.Errorf("%s: remote=%v order=%d", r, ValidRemoteRung(r), order)
		}
	}
	if ValidRung("Probe") || ValidRemoteRung("") || !ValidTier(TierRestart) || !ValidTier(TierFull) || ValidTier("Restart") {
		t.Fatal("rung/tier vocabulary is not exact")
	}
}

func TestSecretParsingRefusesEverySloppyForm(t *testing.T) {
	good := FormatSecret(AuthorityPrefix, secret(7))
	if b, err := ParseSecret(good, AuthorityPrefix); err != nil || !bytes.Equal(b, secret(7)) {
		t.Fatalf("ParseSecret(good) = %v", err)
	}
	short := FormatSecret(AuthorityPrefix, secret(7)[:31])
	long := FormatSecret(AuthorityPrefix, append(secret(7), 1))
	for name, text := range map[string]string{
		"wrong prefix":         FormatSecret(CredentialPrefix, secret(7)),
		"31 bytes":             short,
		"33 bytes":             long,
		"padding":              good + "=",
		"trailing newline":     good + "\n",
		"leading space":        " " + good,
		"two lines":            good + "\n" + good,
		"standard alphabet":    strings.ReplaceAll(strings.ReplaceAll(good, "-", "+"), "_", "/") + "+",
		"no separator":         "yhra1" + strings.TrimPrefix(good, "yhra1."),
		"empty":                "",
		"host key in the slot": "yhrk1.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa." + strings.TrimPrefix(good, "yhra1."),
	} {
		if _, err := ParseSecret(text, AuthorityPrefix); !errors.Is(err, ErrSecretMalformed) {
			t.Errorf("%s: ParseSecret accepted %q (%v)", name, text, err)
		}
	}
	for name, text := range map[string]string{
		"wrong prefix": "yhra1.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa." + strings.TrimPrefix(good, "yhra1."),
		"bad host":     "yhrk1.42AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA." + strings.TrimPrefix(good, "yhra1."),
		"short key":    "yhrk1.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa." + strings.TrimPrefix(short, "yhra1."),
		"extra field":  "yhrk1.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa." + strings.TrimPrefix(good, "yhra1.") + ".x",
	} {
		if _, _, err := ParseHostKey(text); !errors.Is(err, ErrSecretMalformed) {
			t.Errorf("%s: ParseHostKey accepted %q", name, text)
		}
	}
	if _, err := FormatHostKey("42AA", secret(1)); err == nil {
		t.Error("FormatHostKey accepted a non-canonical host id")
	}
	if _, err := FormatHostKey("42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", secret(1)[:5]); err == nil {
		t.Error("FormatHostKey accepted a short key")
	}
}

func TestLoadSecretFile(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string, mode os.FileMode) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}
		return p
	}
	line := FormatSecret(CredentialPrefix, secret(9))
	for name, content := range map[string]string{"bare": line, "lf": line + "\n", "crlf": line + "\r\n"} {
		p := write(name, content, 0o600)
		if b, err := LoadSecretFile(p, CredentialPrefix); err != nil || !bytes.Equal(b, secret(9)) {
			t.Errorf("%s: LoadSecretFile = %v", name, err)
		}
	}
	if _, err := LoadSecretFile(filepath.Join(dir, "absent"), CredentialPrefix); !errors.Is(err, ErrSecretMissing) {
		t.Errorf("missing file: %v", err)
	}
	if _, err := LoadSecretFile(write("blank-lines", line+"\n\n", 0o600), CredentialPrefix); !errors.Is(err, ErrSecretMalformed) {
		t.Errorf("two terminators: %v", err)
	}
	if _, err := LoadSecretFile(write("wrong-kind", line, 0o600), AuthorityPrefix); !errors.Is(err, ErrSecretMalformed) {
		t.Errorf("credential in the authority slot: %v", err)
	}
	big := write("big", strings.Repeat("A", maxSecretFileBytes+10), 0o600)
	if _, err := LoadSecretFile(big, CredentialPrefix); !errors.Is(err, ErrSecretMalformed) {
		t.Errorf("oversize file: %v", err)
	}
	if runtime.GOOS != "windows" {
		open := write("open", line, 0o644)
		if _, err := LoadSecretFile(open, CredentialPrefix); !errors.Is(err, ErrSecretOpenPermissions) {
			t.Errorf("0644 file: %v", err)
		}
		link := filepath.Join(dir, "link")
		if err := os.Symlink(write("target", line, 0o600), link); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadSecretFile(link, CredentialPrefix); !errors.Is(err, ErrSecretNotRegular) {
			t.Errorf("symlink: %v", err)
		}
	}
	// No refusal may carry the secret it read.
	if _, err := LoadSecretFile(write("leak", line+" trailing", 0o600), CredentialPrefix); err == nil || strings.Contains(err.Error(), line) {
		t.Errorf("refusal leaked content: %v", err)
	}
}

func TestSignerMintsWhatVerifyAccepts(t *testing.T) {
	if _, err := NewSigner(secret(3)[:31]); err == nil {
		t.Fatal("a 31-byte authority must be refused")
	}
	authority := secret(3)
	s, err := NewSigner(authority)
	if err != nil {
		t.Fatal(err)
	}
	authority[0] = 99 // the signer must hold its own copy
	const host = "42cccccccccccccccccccccccccccccc"
	id, _ := NewRequestID()
	now := time.Unix(1900000000, 0)
	wire, claims, err := s.Mint(host, id, TierRestart, pool.RungStartIfStopped, now)
	if err != nil {
		t.Fatal(err)
	}
	if claims.ExpiryUnix-claims.IssuedUnix != int64(ProofTTL/time.Second) || claims.IssuedUnix != now.Unix() {
		t.Fatalf("minted lifetime = %+v", claims)
	}
	key, _ := DeriveHostKey(secret(3), host)
	got, reason := Verify(key, wire, Claims{HostID: host, RequestID: id, Tier: TierRestart, MaxRung: pool.RungStartIfStopped}, now, MaxLifetime, Skew)
	if reason != ReasonOK || got != claims {
		t.Fatalf("Verify(minted) = %+v %s", got, reason)
	}
	if s.AuthorityTag() != AuthorityTag(secret(3)) {
		t.Fatal("authority tag drifted from the copied authority")
	}
	// The key of one host verifies nothing minted for another.
	other, _ := DeriveHostKey(secret(3), "42dddddddddddddddddddddddddddddd")
	if _, r := Verify(other, wire, Claims{HostID: host, RequestID: id, Tier: TierRestart, MaxRung: pool.RungStartIfStopped}, now, MaxLifetime, Skew); r != ReasonProofInvalid {
		t.Fatalf("another host's key = %s", r)
	}
	for name, args := range map[string][4]string{
		"host":    {"42CC", id, TierRestart, pool.RungProbe},
		"request": {host, strings.ToUpper(id), TierRestart, pool.RungProbe},
		"tier":    {host, id, "partial", pool.RungProbe},
		"rung":    {host, id, TierRestart, "all"},
	} {
		if _, _, err := s.Mint(args[0], args[1], args[2], args[3], now); !errors.Is(err, ErrInvalidClaim) {
			t.Errorf("%s: Mint accepted %v (%v)", name, args, err)
		}
	}
	if _, err := DeriveHostKey(nil, host); err == nil {
		t.Error("DeriveHostKey accepted an empty authority")
	}
}
