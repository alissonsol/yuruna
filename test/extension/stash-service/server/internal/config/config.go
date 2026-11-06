// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42ebbda3-4d19-44a4-917c-afc8889b3216

// Package config holds the spec-frozen constants for the Stash
// Service daemon. Everything https://yuruna.link/429e934f-0010 lists as a constant in code lives here so
// a single edit covers the spec-driven values.
package config

import "time"

// Listen / transport.
const (
	ListenAddress    = "0.0.0.0:22"
	PerFileSizeLimit = 100 * 1024 * 1024
)

// UI HTTP listener for the browser UI + JSON API, alongside the SCP/SFTP
// sink. Port 80 is privileged; the service user already holds
// CAP_NET_BIND_SERVICE for :22, so no extra privilege is needed. Both the
// address and the pool-index window are overridable by flag.
const (
	DefaultHTTPAddress = "0.0.0.0:80"
	// DefaultPoolWindowDays bounds how many days of cross-host sidecars the
	// pool index holds in memory. Queries older than the window fall back to
	// an on-demand share scan.
	DefaultPoolWindowDays = 30
	// MaxListLimit caps a single /api/stashes response so a large pool can
	// never return unbounded JSON.
	MaxListLimit = 500
	// DefaultListLimit is the recent-list page size when none is requested.
	DefaultListLimit = 50
	// InlineTextPreviewCap bounds inline text rendering; larger text is
	// shown truncated with a download prompt.
	InlineTextPreviewCap = 1 * 1024 * 1024
	// MaxRequestBytes caps a single create request body (multipart or JSON)
	// so an unauthenticated POST cannot fill /tmp (multipart spill) or the
	// stash with one giant request. Generous enough for a few large files in
	// one multi-file upload; per-file content is still capped at 100 MB.
	MaxRequestBytes = 512 * 1024 * 1024
	// MaxUploadFiles caps the file count in one multi-file UI upload.
	MaxUploadFiles = 64
	// TextBodyReadTimeout bounds how long a large text body (JSON or
	// urlencoded) may take to arrive: 100 MB in five minutes is under 3 Mbit/s.
	// Only one such body is read at a time, so it also bounds how long one slow
	// client can keep the next one waiting.
	TextBodyReadTimeout = 5 * time.Minute
	// MaxConcurrentMultipartCreates bounds the multipart creates (web UI
	// pastes and file uploads) received at once. Each one can hold up to 32
	// MiB of parts and 10 MB of form values in memory while it is parsed, so
	// the budget bounds that memory; another create answers 503 with
	// Retry-After.
	MaxConcurrentMultipartCreates = 4
)

// Presence beacon (https://yuruna.link/429e934f-0006). The daemon self-announces to the pool-aggregator-service
// so the dashboard's Extension hosts row exists without depending on the
// owning host's status service being up; the area is the extension-area name
// the pool dashboard groups rows by.
//
// The period is set by the aggregator's health grace, not by the announce TTL.
// An announce carries no address -- the aggregator derives one from the
// connection's source address -- so re-announcing is also the ONLY way a
// renumbered service tells the pool where it went, and the aggregator refuses
// the previous address once it has been unanswerable for that grace. A period
// longer than the grace therefore opens a window where the pool holds neither
// address and every consumer resolves nothing; several periods inside it mean a
// service that renumbers is re-learned before, or shortly after, the address it
// left is refused. Two minutes is still negligible traffic (one small POST per
// service) and stays far inside the announce TTL.
const (
	DefaultPresenceInterval = 2 * time.Minute
	PresenceArea            = "stash-service"
)

// Stash creation source: SCP/SFTP ingest versus the browser UI. Both flow
// through the same storage pipeline (a stash is a stash, https://yuruna.link/429e934f-0002).
const (
	SourceSCP = "scp"
	SourceUI  = "ui"
)

// Content classes the UI switches on for rendering. The detect package maps
// a MIME type onto one of these; the daemon stores it on the record + sidecar.
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

// Extension extraction (https://yuruna.link/429e934f-000b).
const (
	ExtensionMaxLength = 32
)

// Archive name for multi / recursive uploads (https://yuruna.link/429e934f-000b, https://yuruna.link/429e934f-0010).
const (
	ArchiveExtension = ".yuruna.archive.zip"
)

// Sidecar record written next to each committed artifact on the share so
// the rich metadata survives a VM reimage (https://yuruna.link/429e934f-000f). The naming constant
// lives here with the other extensions; meta.WriteSidecar produces it.
const (
	SidecarExtension = ".yuruna.meta.json"
)

// Stderr ID marker (https://yuruna.link/429e934f-0009, https://yuruna.link/429e934f-0010).
const (
	StderrIDFormat = "YURUNA-STASH-ID: %s\n"
)

// On-disk layout under the share-side StashFolder (https://yuruna.link/429e934f-000a). Only hostkey/
// and files/ live on the stash share; the metadata index and the offline
// buffer are VM-local (DefaultMetadataDir / DefaultBufferDir below),
// because SQLite locking is unreliable over SMB/CIFS (https://yuruna.link/429e934f-000a, https://yuruna.link/429e934f-000c).
const (
	HostKeyDirName   = "hostkey"
	FilesDirName     = "files"
	DatabaseFileName = "stash.sqlite"
	HostKeyFileName  = "stash_host_ed25519"
)

// VM-local directories (https://yuruna.link/429e934f-000a, https://yuruna.link/429e934f-000c, https://yuruna.link/429e934f-000e). The metadata index and the
// NAS-offline buffer live on the VM's local disk, not on the share.
// Provisioning (the bring-up step) creates these owned by the service
// user; for local runs override with --metadata-dir / --buffer-dir.
const (
	DefaultMetadataDir = "/var/lib/stash-service/metadata"
	DefaultBufferDir   = "/var/lib/stash-service/buffer"
)

// Local buffer ceiling (https://yuruna.link/429e934f-000e, https://yuruna.link/429e934f-0010): once the VM-local buffer reaches this
// size, uploads are rejected rather than filling the VM disk (enforced in
// sshsrv.chooseTarget); the limit lives here with the other size constants.
const (
	BufferCeilingBytes = 5 * 1024 * 1024 * 1024 // 5 GB
)
