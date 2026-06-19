// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

//go:build !magika

// Default detection backend: the pure-Go heuristic (no cgo, no model). This
// is what `go build` / `go test` compile. The magika backend
// (detect_magika.go) replaces newBackend when built with -tags magika.
package detect

func newBackend() Detector { return Heuristic{} }
