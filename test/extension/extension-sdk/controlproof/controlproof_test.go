// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package controlproof

import (
	"strings"
	"testing"
	"time"
)

func TestVerifyGoldenAndExpiryBoundaries(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const expiry int64 = 1900000000
	const wire = "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs="
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
			if got := Verify(token, wire, tc.now, ceiling); got != tc.want {
				t.Fatalf("Verify = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestVerifyWireAndTokenCompatibility(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const signature = "0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs="
	const wire = "1900000000." + signature
	now := time.Unix(1899999999, 0)
	for _, tc := range []struct {
		name, token, wire string
		want              bool
	}{
		{"wrong key", "another-token", wire, false},
		{"key bytes are not trimmed", " " + token, wire, false},
		{"empty key", "", wire, false},
		{"blank key", " \t\r\n", wire, false},
		{"empty wire", token, "", false},
		{"no separator", token, "1900000000", false},
		{"empty expiry", token, "." + signature, false},
		{"empty MAC", token, "1900000000.", false},
		{"expiry overflow", token, "9223372036854775808." + signature, false},
		{"expiry whitespace", token, " 1900000000." + signature, false},
		{"invalid base64", token, "1900000000.!!!!", false},
		{"wrong MAC length", token, "1900000000.AAAA", false},
		{"changed MAC", token, "1900000000.Al+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs=", false},
		{"unpadded base64", token, strings.TrimSuffix(wire, "="), false},
		// The numeric expiry is canonicalized before the MAC is computed.
		{"signed decimal expiry", token, "+" + wire, true},
		{"leading zero expiry", token, "0" + wire, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := Verify(tc.token, tc.wire, now, time.Minute); got != tc.want {
				t.Fatalf("Verify = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestSharedMintGoldenAndBlankKey(t *testing.T) {
	const want = "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs="
	if got := Proof("yuruna-net1-golden-token", 1900000000); got != want {
		t.Fatalf("Proof = %q", got)
	}
	for _, token := range []string{"", " \t\r\n"} {
		if Proof(token, 1900000000) != "" || Mint(token, time.Minute) != "" {
			t.Fatal("blank key minted a proof")
		}
	}
	now := time.Now()
	if wire := Mint("key", time.Minute); !Verify("key", wire, now, 2*time.Minute) {
		t.Fatal("minted proof did not verify")
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
		{"unbound proof during the transition", "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs=", audience, at, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := VerifyFor(token, tc.wire, tc.audience, tc.now, 20*time.Minute); got != tc.want {
				t.Fatalf("VerifyFor = %v, want %v", got, tc.want)
			}
		})
	}
	if Verify(token, wire, at, 20*time.Minute) {
		t.Fatal("a verifier that predates audiences must refuse the bound form")
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
	if VerifyFor(token, wire, audience, at, 20*time.Minute) || Verify(token, wire, at, 20*time.Minute) {
		t.Fatal("a verifier that takes only the bound and unbound forms must refuse a scoped proof")
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
