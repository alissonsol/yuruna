// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import "testing"

// TestMintControlProofGolden pins the cross-language control-proof format. The vector is
// shared with Test.HostConfigSync\Get-YurunaControlProof (PowerShell): the same token +
// expiry must yield the same wire string on both sides, or a Grafana-minted proof would
// never validate on the host. If this fails, the Go mint and the PowerShell verify have
// drifted (HMAC key/data, base64 flavor, or the "<expiry>.<proof>" framing).
func TestMintControlProofGolden(t *testing.T) {
	const token = "yuruna-net1-golden-token"
	const expiry int64 = 1900000000
	const want = "1900000000.0l+y7qrGppfHhBxHwLiLx702JdmA5KuxcFOmENJnZDs="
	if got := controlProofFor(token, expiry); got != want {
		t.Fatalf("control proof mismatch (Go must match PowerShell Get-YurunaControlProof):\n got  %q\n want %q", got, want)
	}
}

// TestMintControlProofEmptyToken: no configured pool-auth-token -> no proof, so /go/host
// adds no fragment and the host falls back to loopback-only control.
func TestMintControlProofEmptyToken(t *testing.T) {
	if got := mintControlProof("", 0); got != "" {
		t.Fatalf("empty token must yield empty proof, got %q", got)
	}
}
