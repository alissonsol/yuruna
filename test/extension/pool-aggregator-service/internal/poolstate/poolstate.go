// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42006566-1313-42cc-8c80-5f8e9ad2843d

// Package poolstate holds the collector's live view of the pool and the one
// mutex that guards it. The poll merge, the HTTP routes, the metrics and the
// Loki rehydrate all read and change the view, and several of them change more
// than one map in one step, so the whole view stays under a single lock: a
// caller reaches it only inside State.Do, which holds that lock for the call.
// Network and disk work stays outside Do; see
// https://yuruna.link/42c29d04-0011.
package poolstate

import (
	"sync"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
)

// State owns the pool view and its mutex.
type State struct {
	mu   sync.Mutex
	view View
}

// View is the pool view. A View is valid only inside the State.Do call that
// handed it out; a caller that kept it past that call would read and write it
// without the lock.
type View struct {
	Hosts map[string]*HostView // keyed by hostId
	// cycles is the per-cycle dedup set and the terminal cycle counters, read
	// and changed through the View's cycle methods.
	cycles cycleLedger
	// FailWindow holds each host's in-window fails (ascending by At), the input
	// of the incident correlation.
	FailWindow   map[string][]incident.FailRec
	Incident     map[string]*incident.HostIncident // hostId -> active incident (absent = none)
	PoolIncident *incident.PoolIncident            // single active pool-wide incident (nil = none)
	Gating       map[string]incident.GatingPolicy  // pool -> authored gating policy (key present = authored)
	PoolGate     map[string]*incident.Gate         // pool -> advisory degraded/alert latch
	Announce     map[string]*AnnounceView          // hostId|area -> self-announced extension presence
	ExtHealth    map[string]*ExtHealthView         // hostId|area -> this aggregator's own reachability verdict on the advertised address
	// lab is the lab connection token (dashboard enrollment code) state, read
	// and changed through RotateLabCode, RedeemLabCode and their readers.
	lab labCodes
	// footprints is the latest host_address_footprint event seen per host: how
	// many addresses that host is spending and whether its DHCP identity is
	// pinned. Kept as state rather than left in the log because the question it
	// answers -- is this lab's address use bounded? -- has to be answerable
	// BEFORE the pool runs dry, and a log line is only ever read afterwards.
	// Written by the poll goroutine, read by the metrics handler.
	footprints map[string]AddressFootprintView // keyed by hostId
	// addresses is the lab-wide address scan's last result, read and changed
	// through AddressScanDue, RecordAddressScan and AddressCounts.
	addresses AddressCounts
	// aliases maps a retired hostId to the hostId that replaced it, read and
	// changed through CanonicalHostID and its siblings. Loaded before Loki
	// rehydration, so a retired id cannot be restored as a second live host.
	aliases map[string]string
	// Ring holds the framework revision and verdict of each host's completed
	// cycles for the canary ring.
	Ring RingFacts
	last time.Time // the end of the last completed poll; zero before the first
}

// New returns an empty pool view.
func New() *State {
	return &State{view: View{
		Hosts: map[string]*HostView{}, cycles: newCycleLedger(),
		FailWindow: map[string][]incident.FailRec{}, Incident: map[string]*incident.HostIncident{},
		Gating: map[string]incident.GatingPolicy{}, PoolGate: map[string]*incident.Gate{},
		Announce: map[string]*AnnounceView{}, ExtHealth: map[string]*ExtHealthView{},
		lab:        newLabCodes(),
		footprints: map[string]AddressFootprintView{}, aliases: map[string]string{},
	}}
}

// Do runs fn with the lock held and the view in hand. fn must not call Do
// again (the lock is not reentrant) and must not wait on the network: every
// route and the poll goroutine wait for the same lock.
func (s *State) Do(fn func(view *View)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(&s.view)
}

// MarkPolled records now as the end of the last completed poll.
func (v *View) MarkPolled(now time.Time) { v.last = now }

// LastPoll is the end of the last completed poll; zero before the first.
func (v *View) LastPoll() time.Time { return v.last }
