// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 427d0983-e97f-4030-b293-0896ffab4031

package poolstate

import "time"

// AddressCounts is the lab-wide address scan's last result. Complete says the
// scan reached the far end of its window: a scan that did not returns a floor,
// and a floor exported as a measurement is how a draining pool reads as a
// healthy one. InUse is the MEASURED count of addresses the lab is holding:
// the proxy's observed clients UNION every host's current address (see
// https://yuruna.link/42c29d04-0002); InUseHosts is the host-only half, the
// part that does not depend on the proxy being up.
type AddressCounts struct {
	Distinct   int // distinct client addresses the proxy saw in the scan window
	Complete   bool
	InUse      int
	InUseHosts int
	ScannedAt  time.Time // zero until the first scan
}

// AddressScanDue reports whether the address scan has never run, or last ran
// interval or more before now.
func (v *View) AddressScanDue(now time.Time, interval time.Duration) bool {
	return v.addresses.ScannedAt.IsZero() || now.Sub(v.addresses.ScannedAt) >= interval
}

// RecordAddressScan stores one scan of the proxy log: seen holds the client
// addresses in the scan window and complete says whether the scan reached its
// far end. The union with the hosts' current addresses is taken here, under the
// lock that owns the hosts, so the host half and the log half describe one
// instant; counting them in two passes would let a host register between them
// and be counted twice.
func (v *View) RecordAddressScan(seen map[string]bool, complete bool, now time.Time) {
	inUse := make(map[string]bool, len(seen)+len(v.Hosts))
	for ip := range seen {
		inUse[ip] = true
	}
	hostOnly := 0
	for _, h := range v.Hosts {
		if h.CurrentIP == "" {
			continue
		}
		hostOnly++
		inUse[h.CurrentIP] = true
	}
	v.addresses = AddressCounts{Distinct: len(seen), Complete: complete, InUse: len(inUse), InUseHosts: hostOnly, ScannedAt: now}
}

// AddressCounts returns the last scan's result.
func (v *View) AddressCounts() AddressCounts { return v.addresses }

// SetFootprint records hostID's latest address footprint.
func (v *View) SetFootprint(hostID string, fp AddressFootprintView) { v.footprints[hostID] = fp }

// Footprint returns hostID's latest address footprint, and whether one is held.
func (v *View) Footprint(hostID string) (AddressFootprintView, bool) {
	fp, ok := v.footprints[hostID]
	return fp, ok
}

// DropFootprint forgets hostID's address footprint.
func (v *View) DropFootprint(hostID string) { delete(v.footprints, hostID) }
