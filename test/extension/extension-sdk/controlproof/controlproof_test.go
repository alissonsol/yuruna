// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4238ba2b-a276-4ec2-acab-d9b36e90ddf3

package controlproof

import (
	"strings"
	"testing"
	"time"
)

// The bound golden wire, shared with the host-side PowerShell verifier through
// hostrefresh/testdata/vectors.json, carries the window and parsing rules every
// verifier applies.
const (
	goldenToken    = "yuruna-net1-golden-token"
	goldenAudience = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	goldenMAC      = "a0Wqks0pmYUhAAvAhd5PpFiumw9ZOnS++xnPkqO8ylI="
	goldenWire     = "1900000000." + goldenAudience + "." + goldenMAC
	// unboundGoldenWire is the retired unbound form of the same expiry.
	unboundGoldenWire = "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs="
)

func TestVerifyGoldenAndExpiryBoundaries(t *testing.T) {
	const expiry int64 = 1900000000
	const ceiling = 20 * time.Minute
	for _, tc := range []struct {
		name string
		now  time.Time
		want bool
	}{
		{"fresh", time.Unix(expiry-60, 0), true},
		{"at expiry", time.Unix(expiry, 0), true},
		{"at maximum TTL", time.Unix(expiry-int64(ceiling/time.Second), 0), true},
		{"expired", time.Unix(expiry+1, 0), false},
		{"beyond maximum TTL", time.Unix(expiry-int64(ceiling/time.Second)-1, 0), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := VerifyFor(goldenToken, goldenWire, goldenAudience, tc.now, ceiling); got != tc.want {
				t.Fatalf("VerifyFor = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestVerifyWireAndTokenCompatibility(t *testing.T) {
	const prefix = "1900000000." + goldenAudience + "."
	now := time.Unix(1899999999, 0)
	for _, tc := range []struct {
		name, token, wire string
		want              bool
	}{
		{"wrong key", "another-token", goldenWire, false},
		{"key bytes are not trimmed", " " + goldenToken, goldenWire, false},
		{"empty key", "", goldenWire, false},
		{"blank key", " \t\r\n", goldenWire, false},
		{"empty wire", goldenToken, "", false},
		{"no separator", goldenToken, "1900000000", false},
		{"empty expiry", goldenToken, "." + goldenAudience + "." + goldenMAC, false},
		{"empty MAC", goldenToken, prefix, false},
		{"expiry overflow", goldenToken, "9223372036854775808." + goldenAudience + "." + goldenMAC, false},
		{"expiry whitespace", goldenToken, " " + goldenWire, false},
		{"invalid base64", goldenToken, prefix + "!!!!", false},
		{"wrong MAC length", goldenToken, prefix + "AAAA", false},
		{"changed MAC", goldenToken, prefix + "A" + goldenMAC[1:], false},
		{"unpadded base64", goldenToken, strings.TrimSuffix(goldenWire, "="), false},
		// The numeric expiry is canonicalized before the MAC is computed.
		{"signed decimal expiry", goldenToken, "+" + goldenWire, true},
		{"leading zero expiry", goldenToken, "0" + goldenWire, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := VerifyFor(tc.token, tc.wire, goldenAudience, now, time.Minute); got != tc.want {
				t.Fatalf("VerifyFor = %v, want %v", got, tc.want)
			}
		})
	}
}

// The unbound form is still minted, for the shared golden vector and as the
// test that a key is held, but no verifier accepts it.
func TestSharedMintGoldenAndBlankKey(t *testing.T) {
	if got := Proof(goldenToken, 1900000000); got != unboundGoldenWire {
		t.Fatalf("Proof = %q", got)
	}
	for _, token := range []string{"", " \t\r\n"} {
		if Proof(token, 1900000000) != "" || Mint(token, time.Minute) != "" {
			t.Fatal("blank key minted a proof")
		}
	}
	now := time.Now()
	wire := Mint("key", time.Minute)
	if wire == "" {
		t.Fatal("a usable key minted no proof")
	}
	if VerifyFor("key", wire, "", now, 2*time.Minute) || VerifyFor("key", wire, goldenAudience, now, 2*time.Minute) {
		t.Fatal("a freshly minted unbound proof verified")
	}
}

// The bound vector is shared with the host-side PowerShell verifier through
// hostrefresh/testdata/vectors.json.
func TestBoundProofGoldenAudienceAndWindow(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const audience = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const wire = "1900000000.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.a0Wqks0pmYUhAAvAhd5PpFiumw9ZOnS++xnPkqO8ylI="
	if got := ProofFor(token, audience, 1900000000); got != wire {
		t.Fatalf("ProofFor = %q", got)
	}
	at := time.Unix(1899999940, 0)
	for _, tc := range []struct {
		name, wire, audience string
		now                  time.Time
		want                 bool
	}{
		{"its own audience", wire, audience, at, true},
		{"audience case is not significant", wire, strings.ToUpper(audience), at, true},
		{"another host", wire, "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", at, false},
		{"a service audience", wire, "svc-stash-service", at, false},
		{"any audience when the caller names none", wire, "", at, true},
		{"audience swapped in the wire", strings.Replace(wire, audience, "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1), "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", at, false},
		{"expired", wire, audience, time.Unix(1900000001, 0), false},
		{"beyond maximum TTL", wire, audience, time.Unix(1900000000-1201, 0), false},
		{"malformed audience", "1900000000.a.b.c", audience, at, false},
		{"an unbound proof is refused", unboundGoldenWire, audience, at, false},
		{"an unbound proof is refused when the caller names no audience", unboundGoldenWire, "", at, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := VerifyFor(token, tc.wire, tc.audience, tc.now, 20*time.Minute); got != tc.want {
				t.Fatalf("VerifyFor = %v, want %v", got, tc.want)
			}
		})
	}
	for _, bad := range []string{"", "has.dot", "has space", strings.Repeat("a", 81)} {
		if ProofFor(token, bad, 1900000000) != "" {
			t.Fatalf("minted a proof for audience %q", bad)
		}
	}
	if MintFor("", audience, time.Minute) != "" {
		t.Fatal("blank key minted a bound proof")
	}
}

// The scoped vector is shared with the host-side PowerShell verifier through
// hostrefresh/testdata/vectors.json. A scoped proof opens only the routes its
// scope names on its own target, and no verifier that predates scopes takes it.
func TestScopedProofGoldenAudienceScopeAndWindow(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const audience = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const wire = "1900000000.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pause.kgVL7yBFnM42HvobAL1Po4z3MTLIZYYbJC31D+6eBZk="
	if got := ProofForScope(token, audience, ScopePause, 1900000000); got != wire {
		t.Fatalf("ProofForScope = %q", got)
	}
	at := time.Unix(1899999940, 0)
	pause := []string{ScopePause}
	for _, tc := range []struct {
		name, wire, audience string
		scopes               []string
		now                  time.Time
		want                 bool
	}{
		{"its own audience and scope", wire, audience, pause, at, true},
		{"audience case is not significant", wire, strings.ToUpper(audience), pause, at, true},
		{"a route its scope does not cover", wire, audience, nil, at, false},
		{"another scope only", wire, audience, []string{"config"}, at, false},
		{"another host", wire, "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", pause, at, false},
		{"no audience named", wire, "", pause, at, false},
		{"scope swapped in the wire", strings.Replace(wire, ".pause.", ".config.", 1), audience, []string{"config"}, at, false},
		{"expired", wire, audience, pause, time.Unix(1900000001, 0), false},
		{"beyond maximum TTL", wire, audience, pause, time.Unix(1900000000-1201, 0), false},
		{"a bound proof is not a scoped one", "1900000000.42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.a0Wqks0pmYUhAAvAhd5PpFiumw9ZOnS++xnPkqO8ylI=", audience, pause, at, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := VerifyScoped(token, tc.wire, tc.audience, tc.scopes, tc.now, 20*time.Minute); got != tc.want {
				t.Fatalf("VerifyScoped = %v, want %v", got, tc.want)
			}
		})
	}
	if VerifyFor(token, wire, audience, at, 20*time.Minute) || VerifyFor(token, wire, "", at, 20*time.Minute) {
		t.Fatal("the bound-form verifier must refuse a scoped proof")
	}
	for _, bad := range []string{"", "Pause", "has.dot", "has space", strings.Repeat("a", 33)} {
		if ProofForScope(token, audience, bad, 1900000000) != "" {
			t.Fatalf("minted a proof for scope %q", bad)
		}
	}
	if ProofForScope(token, "bad audience", ScopePause, 1900000000) != "" || MintForScope("", audience, ScopePause, time.Minute) != "" {
		t.Fatal("minted a scoped proof without a usable audience or key")
	}
}
