// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42d94b7c-6a1f-4e83-b2d5-9c0e7f3a8b61

package poolstate

import (
	"strings"
	"time"
)

// The announces and the verdicts on their addresses share one key per
// (hostId, area). An announce entry belongs to the connection that made it:
// only that source, or anyone for an entry restored without one, may remove
// it. A verdict belongs to an address, not to a service: a new address starts
// a fresh record that has to earn its own confirmation.

// AnnounceKey is the key one extension area of one host is recorded under.
func AnnounceKey(hostID, area string) string { return hostID + "|" + area }

// RecordAnnounce records a hello from sourceIP for (hostID, area) at target,
// refreshing an entry the view holds or adding one. A new entry is refused
// when the view already holds max entries; an existing one is refreshed
// regardless, so a full map cannot silence a live service. Reports whether the
// hello was recorded.
func (v *View) RecordAnnounce(hostID, area, target, sourceIP string, now time.Time, limit int) bool {
	key := AnnounceKey(hostID, area)
	av := v.Announce[key]
	if av == nil {
		if len(v.Announce) >= limit {
			return false
		}
		av = &AnnounceView{HostId: hostID, Area: area}
		v.Announce[key] = av
	}
	av.Target, av.SourceIP, av.LastSeenUnixMs = target, sourceIP, now.UnixMilli()
	return true
}

// Goodbye removes (hostID, area) on an active=false announce from sourceIP.
// Only the entry's own source, or any sender for an entry restored without
// one, may remove it. removed says the entry went; ignored says one is held
// and the goodbye came from somewhere else, which is left as a silent no-op.
func (v *View) Goodbye(hostID, area, sourceIP string) (removed, ignored bool) {
	key := AnnounceKey(hostID, area)
	av := v.Announce[key]
	if av == nil {
		return false, false
	}
	if av.SourceIP != "" && av.SourceIP != sourceIP {
		return false, true
	}
	delete(v.Announce, key)
	return true, false
}

// RestoreAnnounce restores an entry from the Loki feed: its freshness is the
// line's own time, so the TTL reap stays truthful, and it carries no source
// address, so the next live beacon binds the current owner. An entry the view
// already holds, or a view holding max entries, refuses the restore. Reports
// whether the entry was added.
func (v *View) RestoreAnnounce(hostID, area, target string, at time.Time, limit int) bool {
	key := AnnounceKey(hostID, area)
	if v.Announce[key] != nil || len(v.Announce) >= limit {
		return false
	}
	v.Announce[key] = &AnnounceView{HostId: hostID, Area: area, Target: target, LastSeenUnixMs: at.UnixMilli()}
	return true
}

// ReapAnnounces drops the entries not refreshed within ttl of now. A live
// service re-announces well inside the TTL, so a reaped entry is genuinely
// gone, not merely between beacons.
func (v *View) ReapAnnounces(now time.Time, ttl time.Duration) {
	for k, av := range v.Announce {
		if now.UnixMilli()-av.LastSeenUnixMs > ttl.Milliseconds() {
			delete(v.Announce, k)
		}
	}
}

// RecordExtensionProbe records one probe verdict against (key, target). A
// verdict for a different address than the one now recorded starts a fresh
// record, since an address that changed has to earn its own confirmation; a
// success confirms the address and ends its failure streak, a failure starts
// or extends the streak. See https://yuruna.link/42c29d04-0010.
func (v *View) RecordExtensionProbe(key, target string, probeErr error, now time.Time) {
	h := v.ExtHealth[key]
	if h == nil || h.Target != target {
		h = &ExtHealthView{Target: target}
		v.ExtHealth[key] = h
	}
	if probeErr == nil {
		h.Confirmed, h.LastOkUnixMs, h.FirstFailUnixMs, h.LastError = true, now.UnixMilli(), 0, ""
		h.RefusedLogged = false
		return
	}
	if h.FirstFailUnixMs == 0 {
		h.FirstFailUnixMs = now.UnixMilli()
	}
	h.LastError = probeErr.Error()
}

// PruneExtensionVerdicts forgets the verdicts whose key is not in live, so the
// map tracks the services the pool lists rather than growing with every
// service that ever ran.
func (v *View) PruneExtensionVerdicts(live map[string]bool) {
	for key := range v.ExtHealth {
		if !live[key] {
			delete(v.ExtHealth, key)
		}
	}
}

// dropHostAnnounces removes hostID's announces and the verdicts on their
// addresses, so a host that leaves cannot leave a verdict behind that would
// pre-confirm an address if it returns.
func (v *View) dropHostAnnounces(hostID string) {
	prefix := hostID + "|"
	for k := range v.Announce {
		if strings.HasPrefix(k, prefix) {
			delete(v.Announce, k)
		}
	}
	for k := range v.ExtHealth {
		if strings.HasPrefix(k, prefix) {
			delete(v.ExtHealth, k)
		}
	}
}
