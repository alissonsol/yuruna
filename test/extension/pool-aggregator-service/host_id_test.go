// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4220e373-f2d4-498a-83ed-d2a1e860bf13

package main

import "testing"

// TestNormalizeHostID: the /go/* deep-links must resolve both spellings of a
// hostId -- the undashed pool key and the GUID-formatted rendering every panel
// and UI reveals a full id in -- and must not touch anything else (hostIds are
// opaque by contract).
func TestNormalizeHostID(t *testing.T) {
	const raw = "4253419c1f0b45a08260f36a1521a857"
	const dashed = "4253419c-1f0b-45a0-8260-f36a1521a857"
	if got := normalizeHostID(dashed); got != raw {
		t.Fatalf("dashed: got %q want %q", got, raw)
	}
	if got := normalizeHostID(raw); got != raw {
		t.Fatalf("raw must pass through, got %q", got)
	}
	if got := normalizeHostID("not-a-guid"); got != "not-a-guid" {
		t.Fatalf("non-guid must pass through, got %q", got)
	}
}
