// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 423c63f3-3ae1-4d4d-af14-fa00cc7bb2fe

package routes

import (
	"testing"
	"time"
)

func TestPickCycleForTime(t *testing.T) {
	at := func(s string) time.Time { tt, _ := time.Parse(time.RFC3339, s); return tt }
	mk := func(start, fin string) cycleCand {
		return cycleCand{folderURL: "f-" + start, started: at(start), finished: at(fin), ingest: at(fin)}
	}
	cands := []cycleCand{
		mk("2026-06-12T10:00:00Z", "2026-06-12T10:30:00Z"),
		mk("2026-06-12T11:00:00Z", "2026-06-12T11:20:00Z"),
	}
	// (a) t inside a cycle window -> that cycle (containment beats proximity).
	if c, ok := pickCycleForTime(cands, at("2026-06-12T11:10:00Z")); !ok || c.folderURL != "f-2026-06-12T11:00:00Z" {
		t.Fatalf("(a) containment: ok=%v folder=%q", ok, c.folderURL)
	}
	// (b) t in the gap between cycles -> nearest by timestamp (10:40 is 10m past the
	// first finish, 40m before the second) -> the first cycle.
	if c, ok := pickCycleForTime(cands, at("2026-06-12T10:40:00Z")); !ok || c.folderURL != "f-2026-06-12T10:00:00Z" {
		t.Fatalf("(b) gap-nearest: ok=%v folder=%q", ok, c.folderURL)
	}
	// (c) empty input -> not found.
	if _, ok := pickCycleForTime(nil, at("2026-06-12T11:10:00Z")); ok {
		t.Fatalf("(c) empty want ok=false")
	}
}
