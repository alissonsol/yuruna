// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.

package gatethrottle

import (
	"fmt"
	"testing"
	"time"
)

func TestScheduledSweep(t *testing.T) {
	now := time.Now()
	last := now
	fails := map[string][]time.Time{"expired": {now.Add(-time.Minute)}, "current": {now.Add(-time.Minute), now}}
	Record(fails, "current", now, time.Minute, &last)
	if len(fails["current"]) != 2 || len(fails["expired"]) != 1 {
		t.Fatal(fails)
	}
	Record(fails, "next", now.Add(time.Minute), time.Minute, &last)
	if len(fails) != 1 {
		t.Fatal(fails)
	}
}
func BenchmarkManySources(b *testing.B) {
	now := time.Now()
	last := now
	fails := map[string][]time.Time{}
	for i := range 10000 {
		fails[fmt.Sprint(i)] = []time.Time{now}
	}
	b.ResetTimer()
	for b.Loop() {
		Record(fails, "same", now, time.Minute, &last)
		fails["same"] = fails["same"][:1]
	}
}
