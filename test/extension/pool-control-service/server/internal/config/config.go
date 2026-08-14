// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package config holds the pool-control-service daemon's frozen constants, mirroring the
// stash-service config package so the two services share defaults and idioms.
package config

import "time"

const (
	// PresenceArea is the extension-area token this service announces to the
	// pool-aggregator service and that the host advertises in its registration record;
	// it maps to "Pool-control service" in the Extension hosts table.
	PresenceArea = "pool-control-service"

	// DefaultHTTPAddress is the UI/API listen address (empty disables the server).
	DefaultHTTPAddress = "0.0.0.0:80"

	// DefaultPresenceInterval is the re-announce cadence for the beacon. Kept
	// shorter than the aggregator's extension health grace: re-announcing is
	// how a renumbered service tells the pool its new address, so a cadence
	// slower than the grace leaves the area unresolvable between the moment the
	// old address is refused and the next announce.
	DefaultPresenceInterval = 2 * time.Minute

	// MaxRequestBytes caps mutating request bodies.
	MaxRequestBytes = 1 << 20

	// DefaultAuthTokenFile holds the lab auth token accepted as a bearer on the
	// routes that change pool configuration.
	DefaultAuthTokenFile = "/etc/yuruna/lab-auth.token"
)
