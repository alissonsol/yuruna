// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 426cc9d1-e5bc-45db-b9bd-a17d2beca637

//go:build !magika

// Default detection backend: the pure-Go heuristic (no cgo, no model). This
// is what `go build` / `go test` compile. The magika backend
// (detect_magika.go) replaces newBackend when built with -tags magika.
package detect

func newBackend() Detector { return Heuristic{} }
