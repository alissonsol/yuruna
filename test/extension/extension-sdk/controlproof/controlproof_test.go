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
