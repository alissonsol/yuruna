// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package config holds the download-agent-service daemon's frozen constants,
// mirroring the pool-control-service config package so the extension services
// share defaults and idioms. Values here are also the daemon's answer when no
// flag is supplied, so a bare binary runs sensibly without a seed env file.
package config

import (
	"fmt"
	"path/filepath"
	"time"
)

const (
	// PresenceArea is the extension-area token this service announces to the
	// pool-aggregator service; it maps to "Download-agent service" in the
	// Extension hosts table.
	PresenceArea = "download-agent-service"

	// DefaultHTTPAddress is the UI/API listen address (empty disables the server).
	DefaultHTTPAddress = "0.0.0.0:80"

	// DefaultPresenceInterval is the re-announce cadence for the beacon.
	DefaultPresenceInterval = 15 * time.Minute

	// MaxRequestBytes caps mutating request bodies.
	MaxRequestBytes = 1 << 20

	// DefaultScanInterval is the background pool-scan cadence.
	DefaultScanInterval = 15 * time.Minute

	// DefaultFreshness is how long an image stays fresh after its last
	// successful direct origin verification.
	DefaultFreshness = 24 * time.Hour

	// DefaultPrefetchLead makes the scanner act on entries that are about to
	// expire rather than waiting for them to be stale.
	DefaultPrefetchLead = 2 * time.Hour

	// DefaultPoolDir is where the pool share is CIFS-mounted inside the guest.
	DefaultPoolDir = "/mnt/yuruna-pool"

	// DefaultAuthTokenFile holds the lab auth token accepted as a bearer on the
	// gated routes.
	DefaultAuthTokenFile = "/etc/yuruna/lab-auth.token"
)

const (
	// ImagesDirName is the Download pool root under the pool share.
	ImagesDirName = "images"

	// StagingDirName is the agent-private temp area inside each image
	// directory. Dot-prefixed so pool walkers skip it.
	StagingDirName = ".staging"

	// LeaseFileName is the single-writer lease, at the images root.
	LeaseFileName = ".agent-lease.json"

	// PointerFileFormat builds the servable pointer name from arch + variant.
	// The pointer is the only file whose replacement changes what is served,
	// which is why it is always written last.
	PointerFileFormat = "current.%s.%s.json"

	// SidecarSuffix names the per-generation metadata file.
	SidecarSuffix = ".meta.json"

	// ServiceStateDirName is the per-service state directory on the pool share
	// (audit.jsonl + status.json), beside the images root rather than inside it
	// so the images tree stays artifacts-only.
	ServiceStateDirName = "download-agent-service"
)

const (
	// StagingMaxAge is when an abandoned staging entry is swept regardless of
	// which process wrote it. A single abandoned multi-GB attempt is worth more
	// than the chance of interrupting an unusually slow download.
	StagingMaxAge = 24 * time.Hour

	// LeaseExpiryFactor multiplies the scan interval to get the lease expiry, so
	// a holder that misses two renewals loses the lease.
	LeaseExpiryFactor = 3

	// MaxSeedConcurrency caps concurrent auto-seed downloads so seeding never
	// starves an interactive host request.
	MaxSeedConcurrency = 2
)

// ImagesDirFor returns the Download pool root for a pool mount.
func ImagesDirFor(poolDir string) string {
	if poolDir == "" {
		return ""
	}
	return filepath.Join(poolDir, ImagesDirName)
}

// StateDirFor returns the per-service state directory for a pool mount. The
// bring-up script passes this as --state-dir; the daemon never derives it
// silently, because an unwritable pool must degrade to "no persistence" rather
// than to a surprise write location.
func StateDirFor(poolDir string) string {
	if poolDir == "" {
		return ""
	}
	return filepath.Join(poolDir, ServiceStateDirName)
}

// LeaseFileFor returns the lease path for a pool mount.
func LeaseFileFor(poolDir string) string {
	if poolDir == "" {
		return ""
	}
	return filepath.Join(ImagesDirFor(poolDir), LeaseFileName)
}

// PointerName builds "current.<arch>.<variant>.json".
func PointerName(arch, variant string) string {
	return fmt.Sprintf(PointerFileFormat, arch, variant)
}
