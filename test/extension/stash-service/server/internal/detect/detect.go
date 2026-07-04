// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package detect classifies a stored artifact's content type
// (stash-service-ui.md §6.1). Detection runs server-side at upload/flush
// so it runs ONCE per artifact (not per view) and classifies SCP- and
// UI-created stashes identically — the classifier sees bytes, not origin.
//
// Two backends share one Detector interface:
//
//   - Heuristic (this file): pure-Go, no cgo, always compiled. Uses the
//     stored extension plus a content sniff (net/http's DetectContentType
//     algorithm) plus a UTF-8/printable-text check. This is the default
//     and the fallback the magika backend leans on for low confidence.
//   - magika (detect_magika.go, behind `//go:build magika`): wraps the
//     official Go binding github.com/google/magika/go/magika. It needs cgo
//   - the ONNX Runtime native library + the model assets, all vendored
//     into the VM image — a build/packaging concern, so it is OFF in the
//     default build to keep `go build`/`go test` pure-Go and offline.
//
// New() returns whichever backend the build selected (newBackend, defined
// per build tag in detect_default.go / detect_magika.go).
package detect

import (
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"stash-server/internal/config"
)

// Result is the classification stored on the metadata record + sidecar
// (stash-service-ui.md §10).
type Result struct {
	MimeType     string
	ContentClass string // config.Class* bucket the UI switches on
	IsText       bool
	TypeLabel    string  // detector label (optional, diagnostics)
	TypeScore    float64 // detector confidence 0..1 (optional)
}

// Detector classifies an artifact. Implementations must be safe for
// concurrent use (the HTTP server calls them from request goroutines).
type Detector interface {
	// DetectFile classifies the artifact at path. originalFilename is the
	// client-supplied name (its extension is a secondary hint, never
	// authoritative per §6.1). A read error yields a best-effort "other"
	// result rather than failing the caller.
	DetectFile(path, originalFilename string) Result
}

// New returns the build-selected detector (heuristic by default; magika
// when built with -tags magika).
func New() Detector { return newBackend() }

// sniffLen mirrors net/http.DetectContentType's fixed 512-byte window.
const sniffLen = 512

// Heuristic is the pure-Go default detector.
type Heuristic struct{}

// DetectFile implements Detector with extension + content sniffing.
func (Heuristic) DetectFile(path, originalFilename string) Result {
	f, err := os.Open(path)
	if err != nil {
		return Result{MimeType: "application/octet-stream", ContentClass: config.ClassOther}
	}
	defer f.Close()
	head := make([]byte, sniffLen)
	n, err := io.ReadFull(f, head)
	// EOF (empty file) and ErrUnexpectedEOF (file shorter than the sniff
	// window -- the common case for small text files) are normal: classify
	// the n bytes actually read. Any other read error means the buffer is
	// not a faithful prefix of the file, so classifying it would mislabel an
	// unreadable file as empty text; fall back to the same best-effort
	// "other" result an Open failure yields.
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		log.Printf("detect: read %s failed: %v", path, err)
		return Result{MimeType: "application/octet-stream", ContentClass: config.ClassOther}
	}
	head = head[:n]
	return Classify(head, originalFilename)
}

// Classify is the pure core of the heuristic detector, separated so tests
// can drive it without a file. It resolves a MIME type (extension first,
// then a content sniff) and maps it to a content class, then refines the
// text decision with a UTF-8/printable check on the bytes.
func Classify(head []byte, originalFilename string) Result {
	mt := mimeFromExtension(originalFilename)
	if mt == "" {
		mt = strings.TrimSpace(http.DetectContentType(head))
	}
	// Strip any "; charset=..." parameter for the stored mimeType + class
	// decision; the raw endpoint re-adds charset for text (§7.3).
	base := mt
	if i := strings.IndexByte(base, ';'); i >= 0 {
		base = strings.TrimSpace(base[:i])
	}
	class := ClassFromMime(base)
	isText := class == config.ClassText
	// http.DetectContentType returns application/octet-stream for content it
	// can't place; if the bytes are in fact valid printable UTF-8 text, treat
	// it as text/plain so a README with no extension still renders inline.
	// Only override an UNKNOWN type — a concrete type (pdf, svg, html, image)
	// is authoritative even when its bytes happen to be printable text.
	if (base == "" || base == "application/octet-stream") && looksLikeText(head) {
		base = "text/plain"
		class = config.ClassText
		isText = true
	}
	if base == "" {
		base = "application/octet-stream"
		class = config.ClassOther
	}
	return Result{MimeType: base, ContentClass: class, IsText: isText}
}

// mimeFromExtension maps the artifact's stored extension to a MIME type
// using the Go stdlib table plus a few additions the table misses. Returns
// "" when there is no usable extension (then the caller sniffs content).
func mimeFromExtension(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if ext == "" {
		return ""
	}
	switch ext {
	case ".md", ".markdown":
		return "text/markdown"
	case ".log", ".txt", ".text":
		return "text/plain"
	case ".yml", ".yaml":
		return "text/yaml"
	case ".toml", ".ini", ".cfg", ".conf":
		return "text/plain"
	case ".go", ".py", ".sh", ".ps1", ".psm1", ".rb", ".rs", ".c", ".h", ".cpp", ".java", ".ts", ".tsx", ".jsx", ".sql":
		return "text/plain"
	case ".csv":
		return "text/csv"
	case ".svg":
		// SVG is image/svg+xml but the UI treats it as download-only active
		// content (§7.4); ClassFromMime maps it to "other" deliberately.
		return "image/svg+xml"
	case ".html", ".htm":
		// Pinned (not registry-dependent) so HTML is reliably classed
		// "other" / download-only on every platform (§7.4).
		return "text/html"
	case ".xhtml":
		return "application/xhtml+xml"
	case ".xml":
		return "application/xml"
	case ".json":
		return "application/json"
	}
	return mime.TypeByExtension(ext)
}

// ClassFromMime maps a (parameter-stripped) MIME type onto a UI content
// class (stash-service-ui.md §6.1). SVG and HTML/XHTML are classed "other"
// on purpose: they are active content the UI serves download-only (§7.4),
// so they must never land in an inline-rendered class.
func ClassFromMime(mt string) string {
	mt = strings.ToLower(strings.TrimSpace(mt))
	switch mt {
	case "image/svg+xml":
		return config.ClassOther
	case "text/html", "application/xhtml+xml":
		return config.ClassOther
	case "application/pdf":
		return config.ClassPDF
	case "application/zip", "application/gzip", "application/x-gzip",
		"application/x-tar", "application/x-7z-compressed",
		"application/x-bzip2", "application/x-rar-compressed", "application/vnd.rar":
		return config.ClassArchive
	case "application/json", "application/xml", "application/javascript",
		"application/x-sh", "application/x-yaml", "application/yaml",
		"application/x-shellscript", "application/toml":
		return config.ClassText
	}
	switch {
	case strings.HasPrefix(mt, "text/"):
		return config.ClassText
	case strings.HasPrefix(mt, "image/"):
		return config.ClassImage
	case strings.HasPrefix(mt, "audio/"):
		return config.ClassAudio
	case strings.HasPrefix(mt, "video/"):
		return config.ClassVideo
	}
	return config.ClassOther
}

// looksLikeText reports whether head is plausibly UTF-8 text: no NUL byte,
// valid UTF-8, and a low share of non-printable control bytes. Empty input
// counts as text (a zero-byte stash renders as empty text, not a download).
func looksLikeText(head []byte) bool {
	if len(head) == 0 {
		return true
	}
	if !utf8.Valid(head) {
		return false
	}
	ctrl := 0
	for _, b := range head {
		if b == 0 {
			return false
		}
		// Allow tab/newline/carriage-return/form-feed; count other C0 controls.
		if b < 0x20 && b != '\t' && b != '\n' && b != '\r' && b != '\f' {
			ctrl++
		}
	}
	// More than ~10% odd control bytes → treat as binary.
	return ctrl*10 <= len(head)
}
