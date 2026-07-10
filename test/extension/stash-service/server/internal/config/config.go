// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package config holds the spec-frozen constants for the Stash
// Service daemon. Everything in §10 "Constants in code" lives here so
// a single edit covers the spec-driven values.
package config

import "time"

// Listen / transport.
const (
	ListenAddress    = "0.0.0.0:22"
	PerFileSizeLimit = 100 * 1024 * 1024
)

// UI HTTP listener (stash-service-ui.md §2, §11). The daemon adds a
// second listener for the browser UI + JSON API alongside the SCP/SFTP
// sink. Port 80 is privileged; the service user holds CAP_NET_BIND_SERVICE
// (already required for :22), so no extra privilege is needed. Both the
// address and the pool-index window are overridable by flag.
const (
	DefaultHTTPAddress = "0.0.0.0:80"
	// DefaultPoolWindowDays bounds how many days of cross-host sidecars the
	// pool index holds in memory (stash-service-ui.md §3.2). Queries older
	// than the window fall back to an on-demand share scan.
	DefaultPoolWindowDays = 30
	// MaxListLimit caps a single /api/stashes response so a large pool can
	// never return unbounded JSON (stash-service-ui.md §9, §11).
	MaxListLimit = 500
	// DefaultListLimit is the recent-list page size when none is requested
	// (stash-service-ui.md §4.1, §11).
	DefaultListLimit = 50
	// InlineTextPreviewCap bounds inline text rendering; larger text is
	// shown truncated with a download prompt (stash-service-ui.md §6.2, §11).
	InlineTextPreviewCap = 1 * 1024 * 1024
	// MaxRequestBytes caps a single create request body (multipart or JSON)
	// so an unauthenticated POST cannot fill /tmp (multipart spill) or the
	// stash with one giant request. Generous enough for a few large files in
	// one multi-file upload; per-file content is still capped at 100 MB.
	MaxRequestBytes = 512 * 1024 * 1024
	// MaxUploadFiles caps the file count in one multi-file UI upload.
	MaxUploadFiles = 64
)

// Presence beacon (§4.7). The daemon self-announces to the pool-aggregator
// so the dashboard's Extension hosts row exists without depending on the
// owning host's status server being up. 15 minutes keeps the row alive well
// inside the aggregator's announce TTL while staying negligible traffic; the
// area is the extension-area name the pool dashboard groups rows by.
const (
	DefaultPresenceInterval = 15 * time.Minute
	PresenceArea            = "stash-service"
)

// Stash creation source (stash-service-ui.md §10). Distinguishes an
// SCP/SFTP-ingested stash from one created through the browser UI; both
// flow through the same storage pipeline (a stash is a stash, §1).
const (
	SourceSCP = "scp"
	SourceUI  = "ui"
)

// Content classes the UI switches on for rendering (stash-service-ui.md
// §6.1). Detection (the detect package) maps a MIME type onto one of
// these; the daemon stores it on the record + sidecar.
const (
	ClassText    = "text"
	ClassImage   = "image"
	ClassPDF     = "pdf"
	ClassAudio   = "audio"
	ClassVideo   = "video"
	ClassArchive = "archive"
	ClassOther   = "other"
)

// ID allocator.
const (
	IDAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	IDLength   = 4
)

// Extension extraction (§6.3).
const (
	ExtensionMaxLength = 32
)

// Archive name for multi / recursive uploads (§6.3, §10).
const (
	ArchiveExtension = ".yuruna.archive.zip"
)

// Sidecar record written next to each committed artifact on the share so
// the rich metadata survives a VM reimage (§8.5). The naming constant
// lives here with the other extensions; meta.WriteSidecar produces it.
const (
	SidecarExtension = ".yuruna.meta.json"
)

// Stderr ID marker (§9, §10).
const (
	StderrIDFormat = "YURUNA-STASH-ID: %s\n"
)

// On-disk layout under the share-side StashFolder (§6.2). Only hostkey/
// and files/ live on the stash share; the metadata index and the offline
// buffer are VM-local (DefaultMetadataDir / DefaultBufferDir below),
// because SQLite locking is unreliable over SMB/CIFS (§6.1, §8).
const (
	HostKeyDirName   = "hostkey"
	FilesDirName     = "files"
	DatabaseFileName = "stash.sqlite"
	HostKeyFileName  = "stash_host_ed25519"
)

// VM-local directories (§6.1, §8, §8.4). The metadata index and the
// NAS-offline buffer live on the VM's local disk, not on the share.
// Provisioning (the bring-up step) creates these owned by the service
// user; for local runs override with --metadata-dir / --buffer-dir.
const (
	DefaultMetadataDir = "/var/lib/stash-server/metadata"
	DefaultBufferDir   = "/var/lib/stash-server/buffer"
)

// Local buffer ceiling (§8.4, §10): once the VM-local buffer reaches this
// size, uploads are rejected rather than filling the VM disk (enforced in
// sshsrv.chooseTarget); the limit lives here with the other size constants.
const (
	BufferCeilingBytes = 5 * 1024 * 1024 * 1024 // 5 GB
)
