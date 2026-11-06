// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42b1c6e4-7d2a-4f0e-9c3b-5a8d1e6f2c47

package poolstate

import (
	"regexp"
	"sort"
	"strings"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
)

// The host records are keyed by hostId. Every writer keeps two rules: a
// retired identity (one handed over to another id) never regains a row, and a
// row leaves the view together with the per-host state that belongs to it.

// EnsureHost returns hostID's record, adding an empty one when the view holds
// none. It returns nil for a retired identity: a stale presence feed or an
// in-flight probe may still name one, and it must never regain a live row.
func (v *View) EnsureHost(hostID string) *HostView {
	if v.ReplacedBy(hostID) != "" {
		return nil
	}
	hv := v.Hosts[hostID]
	if hv == nil {
		hv = &HostView{HostId: hostID}
		v.Hosts[hostID] = hv
	}
	return hv
}

// SeedHostStub adds an unreachable record for a host whose last-known address
// was recovered from Loki, so the next poll probes that address. The stub
// carries no status, so nothing is exported for it until a probe confirms it;
// it never replaces an existing (possibly live) record, refuses a retired
// identity, and is stamped as seen at now so a transient first-probe miss does
// not evict it before a full host TTL of retries. Reports whether it was added.
func (v *View) SeedHostStub(hostID, ip, baseURL string, now time.Time) bool {
	if hostID == "" || ip == "" || v.ReplacedBy(hostID) != "" {
		return false
	}
	if _, ok := v.Hosts[hostID]; ok {
		return false
	}
	v.Hosts[hostID] = &HostView{HostId: hostID, CurrentIP: ip, BaseURL: baseURL, LastSeenUnixMs: now.UnixMilli()}
	return true
}

// RelocateHost records a host's confirmed current address: a known record
// moves to it and reads as seen at now with its last error cleared, a host the
// view does not hold is seeded as a stub at it. Reports whether a record holds
// the address afterwards (false only for a retired identity or a blank ip).
func (v *View) RelocateHost(hostID, ip, baseURL string, now time.Time) bool {
	if hv := v.Hosts[hostID]; hv != nil {
		hv.CurrentIP, hv.BaseURL, hv.LastSeenUnixMs, hv.LastError = ip, baseURL, now.UnixMilli(), ""
		return true
	}
	return v.SeedHostStub(hostID, ip, baseURL, now)
}

// DropHost removes hostID's record and its address footprint, the host TTL
// reaper's cleanup. The cycle counters, the fail window and an open incident
// stay: a host that returns inside their windows resumes them.
func (v *View) DropHost(hostID string) {
	delete(v.Hosts, hostID)
	delete(v.footprints, hostID)
}

// ForgetHost removes every trace of hostID: its record and footprint, its fail
// window and incident, its cycle records and counters, its announces and the
// verdicts on their addresses. Reports whether a record was present.
func (v *View) ForgetHost(hostID string) bool {
	_, present := v.Hosts[hostID]
	v.DropHost(hostID)
	delete(v.FailWindow, hostID)
	delete(v.Incident, hostID)
	v.ForgetCycles(hostID)
	v.dropHostAnnounces(hostID)
	return present
}

// RetireHost moves oldID's standing to newID after a handover: the old record,
// footprint and incident go, its in-window fails join the new identity's window
// in time order, and its announces and address verdicts go (the service
// re-announces under the new identity). The cycle records and counters stay
// under the old key, which the aliases project onto the new one.
func (v *View) RetireHost(oldID, newID string) {
	v.DropHost(oldID)
	delete(v.Incident, oldID)
	for _, rec := range v.FailWindow[oldID] {
		v.RecordFail(newID, rec)
	}
	delete(v.FailWindow, oldID)
	v.dropHostAnnounces(oldID)
}

// RecordFail adds one failed cycle to hostID's window, which stays ascending by
// At whatever order the fails arrive in: the live poll appends chronologically,
// a Loki rehydrate reads newest first.
func (v *View) RecordFail(hostID string, rec incident.FailRec) {
	fw := append(v.FailWindow[hostID], rec)
	if n := len(fw); n > 1 && rec.At.Before(fw[n-2].At) {
		sort.SliceStable(fw, func(i, j int) bool { return fw[i].At.Before(fw[j].At) })
	}
	v.FailWindow[hostID] = fw
}

// PoolLabel is the pool hostID advertises in its registration record when
// known, else fallback (the collector's default): the per-host telemetry label,
// so each host's data accumulates under its real pool from its first probe.
func (v *View) PoolLabel(hostID, fallback string) string {
	if hv := v.Hosts[hostID]; hv != nil && hv.PoolId != "" {
		return hv.PoolId
	}
	return fallback
}

// dashedHostIDRE and plainHostIDRE are the two spellings of one hostId: the
// GUID-formatted rendering (8-4-4-4-12) every operator-facing surface shows a
// full id in, and the undashed 32-hex form the view keys hosts on. DashedHostID
// renders one, NormalizeHostID folds the other back, and a link built from a
// rendered value therefore resolves either way.
var (
	dashedHostIDRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	plainHostIDRE  = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)
)

// IsPlainHostID reports whether id is spelled the way the view keys hosts:
// 32 hex characters, undashed.
func IsPlainHostID(id string) bool { return plainHostIDRE.MatchString(id) }

// NormalizeHostID folds the GUID-formatted spelling of a hostId back to the
// undashed form the view is keyed on, so a deep link resolves whichever
// spelling a dashboard panel interpolated. Anything not shaped like a dashed
// 32-hex id passes through untouched: hostIds are opaque by contract.
func NormalizeHostID(hostID string) string {
	if dashedHostIDRE.MatchString(hostID) {
		return strings.ReplaceAll(hostID, "-", "")
	}
	return hostID
}

// DashedHostID renders a hostId 8-4-4-4-12, the spelling a full id is shown in
// wherever an operator checks one against another screen or pastes it into a
// command. It is exported beside hostId, never in its place: hostId is the join
// key of every Loki frame and deep link, and re-spelling it would fork those
// series. An id that is not 32 hex passes through untouched, since an announce
// may carry any opaque identifier. See https://yuruna.link/42c29d04-0012.
func DashedHostID(hostID string) string {
	if !plainHostIDRE.MatchString(hostID) {
		return hostID
	}
	return hostID[0:8] + "-" + hostID[8:12] + "-" + hostID[12:16] + "-" + hostID[16:20] + "-" + hostID[20:32]
}
