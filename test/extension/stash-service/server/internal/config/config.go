// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package config holds the spec-frozen constants for the Stash
// Service daemon. Everything in §10 "Constants in code" lives here so
// a single edit covers the spec-driven values.
package config

// Listen / transport.
const (
	ListenAddress    = "0.0.0.0:22"
	PerFileSizeLimit = 100 * 1024 * 1024
)

// ID allocator.
const (
	IDAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	IDLength   = 6
)

// Extension extraction (§6.3).
const (
	ExtensionMaxLength = 32
)

// Archive name for multi / recursive uploads (§6.3, §10).
const (
	ArchiveExtension = ".yuruna.archive.zip"
)

// Stderr ID marker (§9, §10).
const (
	StderrIDFormat = "YURUNA-STASH-ID: %s\n"
)

// On-disk layout under the StashFolder.
const (
	HostKeyDirName   = "hostkey"
	MetadataDirName  = "metadata"
	FilesDirName     = "files"
	DatabaseFileName = "stash.sqlite"
	HostKeyFileName  = "stash_host_ed25519"
)

// Default StashFolder when --folder is not supplied. Resolved against
// the user's $HOME at startup so each per-user invocation gets its
// own folder under the Yuruna enlistment that update.sh clones.
const (
	DefaultFolderRelative = "yuruna/test/status/stash"
)
