// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package webui ships the browser assets every Yuruna extension service UI
// shares. See ../../../../docs/extensions-api.md#filesystem-layout for why
// there is one shared copy and why it lives here. -- webui.go
package webui

import (
	"embed"
	"strings"
)

//go:embed assets
var assetFS embed.FS

// Asset returns the shared asset of that name (as it appears under /assets/,
// e.g. "yuruna.core.js"), its Content-Type, and whether it exists.
//
// A name containing a slash is refused rather than cleaned: every shared asset
// is a flat file in one directory, so a separator can only be a caller passing
// through a path it did not sanitize.
func Asset(name string) ([]byte, string, bool) {
	if name == "" || strings.ContainsAny(name, "/\\") {
		return nil, "", false
	}
	b, err := assetFS.ReadFile("assets/" + name)
	if err != nil {
		return nil, "", false
	}
	return b, ContentType(name), true
}

// ContentType maps an asset name to what it must be served as. Anything
// unrecognized is octet-stream: served with X-Content-Type-Options: nosniff, a
// wrong guess would be executed as the guess rather than as what it is.
func ContentType(name string) string {
	switch {
	case strings.HasSuffix(name, ".js"):
		return "text/javascript; charset=utf-8"
	case strings.HasSuffix(name, ".css"):
		return "text/css; charset=utf-8"
	default:
		return "application/octet-stream"
	}
}

// Names lists the shared assets, sorted, for a service that wants to check what
// it is serving without reaching into the filesystem.
func Names() []string {
	entries, err := assetFS.ReadDir("assets")
	if err != nil {
		return nil
	}
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			out = append(out, e.Name())
		}
	}
	return out
}
