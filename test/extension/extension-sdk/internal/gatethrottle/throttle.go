// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package gatethrottle

import (
	"net"
	"net/http"
	"time"
)

// KeepRecent removes expired attempts and empty source entries. The caller owns synchronization.
func KeepRecent(fails map[string][]time.Time, ip string, cutoff time.Time) []time.Time {
	kept := fails[ip][:0]
	for _, t := range fails[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(fails, ip)
		return nil
	}
	fails[ip] = kept
	return kept
}

// Record prunes the current source and sweeps others at most once per window.
// The caller owns synchronization and the sweep clock.
func Record(fails map[string][]time.Time, ip string, now time.Time, window time.Duration, lastSweep *time.Time) {
	cutoff := now.Add(-window)
	if lastSweep.IsZero() || now.Sub(*lastSweep) >= window || now.Before(*lastSweep) {
		for known := range fails {
			KeepRecent(fails, known, cutoff)
		}
		*lastSweep = now
	} else {
		KeepRecent(fails, ip, cutoff)
	}
	fails[ip] = append(fails[ip], now)
}

// ClientIP ignores forwarding headers and removes only a valid transport port.
func ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
