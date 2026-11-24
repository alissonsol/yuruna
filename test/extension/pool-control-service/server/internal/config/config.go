// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42e923b8-c6d5-4ac2-b4d8-f1c382db04d7

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

	// DefaultAuthTokenFile holds the internal authentication key accepted as a
	// bearer on the routes that change pool configuration.
	DefaultAuthTokenFile = "/etc/yuruna/internal-auth.key"

	// LegacyAuthTokenFile is the key file path a guest built earlier still
	// carries. Read only when the default path is absent and the operator named
	// no path of their own, so a service VM that predates the current layout
	// keeps its bearer route working until it is rebuilt.
	LegacyAuthTokenFile = "/etc/yuruna/lab-auth.token"

	// DefaultRepairAuthorityFile holds the host repair signing authority
	// (one "yrpa1." line, owner-only). Without it this service cannot mint a
	// repair proof, and remote repair stays disabled.
	DefaultRepairAuthorityFile = "/etc/yuruna/host-repair/authority.key"

	// DefaultOperatorCredentialFile holds the operator credential (one
	// "yoc1." line, owner-only) that the per-host repair route and its MCP
	// tool require in the X-Yuruna-Operator-Credential header.
	DefaultOperatorCredentialFile = "/etc/yuruna/host-repair/operator.credential"

	// MaxRepairRequestBytes caps the per-host repair request body, which
	// carries four short strings.
	MaxRepairRequestBytes = 4096

	// DefaultUpdateSigningKeyFile holds the host update signing key (one
	// PKCS#8 RSA PEM block, owner-only), beside the repair authority. Without
	// it this service cannot sign a yup1 proof, and remote host update stays
	// disabled.
	DefaultUpdateSigningKeyFile = "/etc/yuruna/host-repair/update-signing.key"

	// MaxUpdateRequestBytes caps the per-host update request body, which
	// carries four short strings and one integer.
	MaxUpdateRequestBytes = 4096
)
