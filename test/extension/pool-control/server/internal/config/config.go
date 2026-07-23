// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package config holds the pool-control daemon's frozen constants, mirroring the
// stash-service config package so the two services share defaults and idioms.
package config

import "time"

const (
	// PresenceArea is the extension-area token this service announces to the
	// pool aggregator and that the host advertises in its registration record;
	// it maps to "Pool control" in the Extension hosts table.
	PresenceArea = "pool-control"

	// DefaultHTTPAddress is the UI/API listen address (empty disables the server).
	DefaultHTTPAddress = "0.0.0.0:80"

	// DefaultPresenceInterval is the re-announce cadence for the beacon.
	DefaultPresenceInterval = 15 * time.Minute

	// MaxRequestBytes caps mutating request bodies.
	MaxRequestBytes = 1 << 20
)
