// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

//go:build magika

// magika detection backend (stash-service-ui.md §6.1, §14). Built only with
// `-tags magika`; it is EXCLUDED from the default build, so `go build` /
// `go test` stay pure-Go and offline. Enabling it requires, in the VM image
// build, all three of:
//
//   - the Go binding:      go get github.com/google/magika/go/magika
//   - ONNX Runtime:        the native shared library (cgo links against it)
//   - the model assets:    e.g. the "standard_v3_3" model directory
//
// The assets dir and model name are read from the environment so the image
// build can point at the vendored copies:
//
//	MAGIKA_ASSETS_DIR  (default: /usr/local/share/magika)
//	MAGIKA_MODEL       (default: standard_v3_3)
//
// The scanner is constructed once at startup and is safe for concurrent
// Scan calls. Any construction or scan failure degrades to the pure-Go
// Heuristic, so a misconfigured model never breaks classification.
package detect

import (
	"log"
	"os"

	"github.com/google/magika/go/magika"

	"stash-server/internal/config"
)

func newBackend() Detector {
	assets := envOr("MAGIKA_ASSETS_DIR", "/usr/local/share/magika")
	model := envOr("MAGIKA_MODEL", "standard_v3_3")
	sc, err := magika.NewScanner(assets, model)
	if err != nil {
		log.Printf("detect: magika scanner init failed (assets=%s model=%s): %v; falling back to heuristic", assets, model, err)
		return Heuristic{}
	}
	log.Printf("detect: magika backend active (assets=%s model=%s)", assets, model)
	return &magikaDetector{sc: sc}
}

type magikaDetector struct {
	sc *magika.Scanner
}

func (d *magikaDetector) DetectFile(path, originalFilename string) Result {
	f, err := os.Open(path)
	if err != nil {
		return Heuristic{}.DetectFile(path, originalFilename)
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return Heuristic{}.DetectFile(path, originalFilename)
	}
	ct, err := d.sc.Scan(f, int(fi.Size()))
	if err != nil {
		// Heuristic on any scan error so a single odd artifact still
		// classifies (DetectFile re-opens the file; cheap and robust).
		return Heuristic{}.DetectFile(path, originalFilename)
	}
	// Reuse the shared MIME->class mapper so SVG/HTML stay download-only
	// (ClassFromMime maps them to "other", §7.4) regardless of backend.
	class := ClassFromMime(ct.MimeType)
	isText := ct.IsText
	if isText && class == config.ClassOther {
		class = config.ClassText
	}
	mt := ct.MimeType
	if mt == "" {
		// Empty MIME from the model: lean on the heuristic for the type but
		// keep magika's label.
		h := Heuristic{}.DetectFile(path, originalFilename)
		mt, class, isText = h.MimeType, h.ContentClass, h.IsText
	}
	// TypeScore is left 0: the public Go binding's Scan returns only
	// (ContentType, error) and ContentType carries no confidence field (the
	// score lives in the unexported scanScore). The spec marks typeScore
	// optional (§10), so the label alone is sufficient here.
	return Result{
		MimeType:     mt,
		ContentClass: class,
		IsText:       isText,
		TypeLabel:    ct.Label,
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
