// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42ebec93-0b18-49a6-bffc-acc18ef41a6b

package main

import (
	"fmt"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// view hands a test the pool view outside its lock, so a test can seed the view
// and read it back between calls. Only for a test that has no other goroutine
// touching the view at that moment; a test that runs the poll, a route or a
// rotation concurrently reads through s.st.Do instead.
func (s *poolState) view() *poolstate.View {
	var v *poolstate.View
	s.st.Do(func(locked *poolstate.View) { v = locked })
	return v
}

// cycleTotals reads one host's terminal pass and fail counters.
func (s *poolState) cycleTotals(hostID string) (pass, fail int64) {
	passTotals, failTotals := s.view().CycleTotals()
	return passTotals[hostID], failTotals[hostID]
}

// countCycles counts passes passing and fails failing terminal cycles for
// hostID, each under a cycle key of its own.
func (s *poolState) countCycles(hostID string, passes, fails int) {
	v := s.view()
	for i := 0; i < passes+fails; i++ {
		v.CountTerminal(poolstate.CycleKey(hostID, fmt.Sprintf("counted-%d", i)), hostID, i < passes)
	}
}

// seedCycle records a cycle as observed with status at at, and counts it as a
// pass when counted is set.
func (s *poolState) seedCycle(hostID, cycleStartUtc, status string, at time.Time, counted bool) {
	v := s.view()
	key := poolstate.CycleKey(hostID, cycleStartUtc)
	v.ObserveCycle(key, status, at)
	if counted {
		v.CountTerminal(key, hostID, true)
	}
}
