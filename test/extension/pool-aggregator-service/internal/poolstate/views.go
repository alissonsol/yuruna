// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42d6317d-f6c4-4343-94a9-cc227fc7504a

package poolstate

import (
	"time"

	sdkpool "yuruna.com/test/extension/extension-sdk/pool"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
)

// A host's control state, from comparing the host's published internal
// authentication key tag (/control/control-status) with this proxy's.
const (
	ControlReady    = "ready"    // host holds the same token this proxy mints with
	ControlNone     = "none"     // host holds no internal authentication key: loopback control only
	ControlMismatch = "mismatch" // host holds a DIFFERENT token (enrolled against a rebuilt proxy)
	ControlSkew     = "skew"     // tokens agree but the clocks do not, so a fresh proof reads as expired
	ControlUnknown  = "unknown"  // not determinable: route absent (older build), never probed, or this proxy holds no token to compare
)

// RefreshObservationFloor bounds how long a host's refresh capability is
// believed after it was last read from the host itself (or three poll
// intervals, when that is longer). Unlike Control, a refresh reading is never
// carried forward indefinitely: it authorizes a disruptive action, so a reading
// nobody has renewed reads as unavailable.
const RefreshObservationFloor = 2 * time.Minute

// HostView is a discovered pool member, keyed by the stable hostId.
type HostView struct {
	HostId         string               `json:"hostId"`
	CurrentIP      string               `json:"currentIp"`
	BaseURL        string               `json:"baseUrl"`
	Reachable      bool                 `json:"reachable"`
	LastSeenUnixMs int64                `json:"lastSeenUnixMs"`
	LastError      string               `json:"lastError,omitempty"`
	Status         *hostpoll.HostStatus `json:"status,omitempty"`
	// Version is the host's framework version (the one CalVer line in the repo's
	// VERSION file, served at /yuruna-repo/VERSION -- the same source the host's
	// own status pages read for their header). Refreshed each poll; kept across a
	// transient fetch miss (it is stable). "" until first learned.
	Version string `json:"version,omitempty"`
	// PoolId is the pool this host advertises in its registration record, which
	// the runner derived from pools.yml members[] (the single source of truth).
	// Empty until learned; the aggregator then falls back to the -pool flag.
	PoolId string `json:"poolId,omitempty"`
	// PoolGuid is the pool's stable 42-GUID; empty until learned.
	PoolGuid string `json:"poolGuid,omitempty"`
	// ActiveExtensions are the extension areas this host is ACTIVELY running right
	// now (e.g. "stash-service" when it hosts a stash-service VM) -- distinct from
	// capabilities.extensions (what it COULD run). Read from the host's
	// registration record each poll; drives the dashboard's Extension hosts table.
	// Registration-sourced, so the aggregator never mounts ystash-nas to discover
	// stash services (no cross-host config service / NAS-credential dependency).
	ActiveExtensions []string `json:"activeExtensions,omitempty"`
	// ExtensionTargets maps an active extension area to the deep-link URL the host
	// advertises for it (e.g. "stash-service" -> the stash-service VM's UI base URL the host
	// resolved into its marker via Get-VMIp). Lets the dashboard's Extension cell
	// /go/stash to the stash-service VM without the aggregator keeping an address store of its
	// own. Registration-sourced like ActiveExtensions; empty until the host advertises
	// one. Also exposed in /api/v1/pool-status for the stash UI's hostId->stashBaseUrl
	// resolution.
	ExtensionTargets map[string]string `json:"extensionTargets,omitempty"`
	// Control is whether the dashboard's Host link can actually DRIVE this host:
	// one of the Control* constants, from comparing the host's published
	// internal authentication key tag (/control/control-status) with this proxy's. "" until
	// first learned; kept across a transient probe miss like Version, since the
	// answer changes only on enrollment. Drives host_info's control label -> the
	// dashboard's Control column.
	Control string `json:"control,omitempty"`
	// RunnerStopped is true when the host answered /control/runner-status with a
	// verified-dead outer runner. Refreshed each poll and kept across a transient
	// probe miss like Version/Control, since a host whose runner is stopped keeps
	// answering everything else normally -- its status.json simply stops moving.
	RunnerStopped bool `json:"runnerStopped,omitempty"`
	// StepPauseReached is true when the host's current-action sidecar says the runner
	// is SITTING at a step boundary rather than still executing the step the armed
	// flag will stop after. It is meaningful only while Status.StepPaused is set,
	// which is the only condition under which it is read (StatusLabel) and the only
	// condition under which it is refreshed: the sidecar line outlives a resume until
	// the next step overwrites it, so an unarmed host must not carry it forward.
	StepPauseReached bool `json:"stepPauseReached,omitempty"`
	// Refresh is the host's refresh capability as last merged from its
	// control-status answer. Never serialized from here: every reader goes
	// through RefreshView, which applies the one expiry rule, so no route can
	// publish a reading older than the observation window allows.
	Refresh sdkpool.HostRefresh `json:"-"`
}

// RefreshView is the single expiry rule for the refresh capability: an
// available reading older than ttl reads as unavailable, observation_expired,
// and a host never read reads as never observed. It also stamps the reading's
// age, so a consumer can show how old the answer is.
func (hv *HostView) RefreshView(now time.Time, ttl time.Duration) sdkpool.HostRefresh {
	r := hv.Refresh
	if r.Availability == "" {
		return sdkpool.UnobservedRefresh()
	}
	if ttl <= 0 {
		ttl = RefreshObservationFloor
	}
	r.AgeSeconds = 0
	if r.ObservedUnixMs > 0 {
		if age := now.UnixMilli() - r.ObservedUnixMs; age > 0 {
			r.AgeSeconds = age / 1000
		}
	}
	if r.Availability == sdkpool.RefreshAvailable &&
		(r.ObservedUnixMs <= 0 || now.UnixMilli()-r.ObservedUnixMs > ttl.Milliseconds()) {
		r.Availability, r.Reason = sdkpool.RefreshUnavailable, sdkpool.RefreshReasonObservationExpired
	}
	return r
}

// RefreshLabels is the metric label pair for a host's refresh capability,
// clamped to two availabilities and four states so no host-supplied value can
// grow the series count.
func (hv *HostView) RefreshLabels(now time.Time, ttl time.Duration) (availability, state string) {
	v := hv.RefreshView(now, ttl)
	availability = sdkpool.RefreshUnavailable
	if v.Availability == sdkpool.RefreshAvailable {
		availability = sdkpool.RefreshAvailable
	}
	switch v.State {
	case sdkpool.RefreshStateIdle, sdkpool.RefreshStateActive, sdkpool.RefreshStateRecoveryPending:
		state = v.State
	default:
		state = sdkpool.RefreshStateUnknown
	}
	return availability, state
}

// ControlLabel is Control with the never-learned case folded onto the state that
// says so, so the metric always carries a value the dashboard can map.
func (hv *HostView) ControlLabel() string {
	if hv.Control == "" {
		return ControlUnknown
	}
	return hv.Control
}

// StatusLabel folds reachability, runner liveness, overallStatus and the two
// pause flags into one value for the per-host table; StatusCode is its numeric
// twin for the state-timeline panel (unreachable=0, running=1, pass=2, fail=3,
// idle=4, paused=5, pausing-cycle=6, pausing-step=7, stopped=8,
// preflight-failed=9). See https://yuruna.link/42c29d04-0005.
func (hv *HostView) StatusLabel() string {
	if hv == nil || !hv.Reachable {
		return "unreachable"
	}
	if hv.RunnerStopped {
		return "stopped"
	}
	if hv.Status == nil {
		return "idle"
	}
	if hv.Status.RunnerFault != nil && hv.Status.RunnerFault.FailureClass != "" {
		fault := hv.Status.RunnerFault
		if fault.FailureClass == "config_gate_failed" || (fault.FailureClass == "bootstrap_sync" && fault.Stage == "FrameworkPull") {
			return "preflight-failed"
		}
		return "fail"
	}
	if hv.Status.StepPaused {
		// Only the current-action sidecar separates "parked at the boundary" from
		// "still running the step it will stop after" -- the flag alone reads the same
		// in both states.
		if hv.StepPauseReached {
			return "paused"
		}
		return "pausing-step"
	}
	if hv.Status.CyclePaused {
		// Mid-cycle the stop has not happened yet. Anything else means the host is
		// sitting at the cycle boundary the flag stopped it at -- reported ABOVE the
		// last cycle's pass/fail so it reads as paused, not as a stale terminal result.
		if hv.Status.OverallStatus == "running" {
			return "pausing-cycle"
		}
		return "paused"
	}
	switch hv.Status.OverallStatus {
	case "running", "pass", "fail":
		return hv.Status.OverallStatus
	default:
		return "idle"
	}
}

// StatusCode is StatusLabel's numeric twin; see StatusLabel for the mapping.
func (hv *HostView) StatusCode() int {
	switch hv.StatusLabel() {
	case "running":
		return 1
	case "pass":
		return 2
	case "fail":
		return 3
	case "idle":
		return 4
	case "paused":
		return 5
	case "pausing-cycle":
		return 6
	case "pausing-step":
		return 7
	case "stopped":
		return 8
	case "preflight-failed":
		return 9
	default: // unreachable
		return 0
	}
}

// AnnounceView is one extension service's SELF-ANNOUNCED presence (POST
// /announce): the service VM itself reports "hostId X actively runs area Y at
// target Z", refreshed every beacon period, with the target taken from the
// request's source address. It outranks the registration path when the two
// disagree; see https://yuruna.link/42c29d04-0006. Entries are reaped after the
// announce TTL without a refresh, or immediately on an active=false goodbye.
// Serialized into /api/v1/pool-status (announcedExtensions); SourceIP is never
// serialized, so the snapshot exposes no requester address.
type AnnounceView struct {
	HostId         string `json:"hostId"`
	Area           string `json:"area"`
	Target         string `json:"target,omitempty"`
	LastSeenUnixMs int64  `json:"lastSeenUnixMs"`
	// SourceIP is the announcing connection's address, kept so only the same
	// sender (the service's current IP) can goodbye the entry. "" when the
	// entry was rehydrated from a target-less Loki line, which then accepts
	// any goodbye rather than pinning a stale address.
	SourceIP string `json:"-"`
}

// ExtHealthView is this aggregator's own verdict on one advertised extension
// address: has THIS process reached <target>/healthz, and when did that last
// work. Keyed by hostId|area, and reset whenever the advertised address
// changes -- a verdict belongs to an address, not to a service. Confirmed
// separates "never reached" (refused outright) from "reached, then lost"
// (carried through the health grace); see https://yuruna.link/42c29d04-0010.
type ExtHealthView struct {
	Target          string
	Confirmed       bool  // /healthz answered for this exact target at least once
	LastOkUnixMs    int64 // last successful probe (0 = never)
	FirstFailUnixMs int64 // start of the current failure streak (0 = not failing)
	LastError       string
	// RefusedLogged keeps the crossing of the health grace to ONE log line,
	// since the verdict is re-derived every poll. Reset with the rest of the
	// verdict when the address changes.
	RefusedLogged bool `json:"-"`
}

// AddressFootprintView is one host's latest answer to "is your address use
// bounded by identity, or by elapsed time?".
//
// Verdict and pin are kept SEPARATE because together they name four different
// faults with different owners, and either one alone is ambiguous: a pin the
// DHCP server ignores looks identical to no pin from the address log, and
// identical to a working pin from the configuration. Only the pair separates
// "nobody pinned it" (fixable on the host) from "it is pinned and the server
// does not care" (fixable only with a reservation).
type AddressFootprintView struct {
	Verdict  string // stable | moved | renewal-churn | unknown
	Severity string // ok | advisory | warning
	Changes  int    // address changes in the lookback window; -1 = not measurable
	Distinct int    // distinct addresses this host held in that window
	Pinned   int    // 1 pinned, 0 not pinned, -1 could not be read
	Backend  string // networkmanager | networkd | unknown
	Observed time.Time
}

// RingFacts is revision -> hostId -> cycleStartUtc -> passed: the framework
// canary ring's record of each host's completed cycles. Recording is
// idempotent, because every poll re-reads each host's whole recent history.
type RingFacts map[string]map[string]map[string]bool
