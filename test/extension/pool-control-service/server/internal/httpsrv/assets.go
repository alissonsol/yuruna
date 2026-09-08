// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"html"
	"net/http"
	"strings"
	"sync"

	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/webui"
)

// asset is one immutable response body, prepared once.
//
// Everything a handler needs is computed at startup: the bytes, a gzip copy,
// the content type, and the ETag. A handler that read embed.FS and compressed
// per request would spend that work on every hit of a file that never changes,
// and would spend it again on the next hit.
type asset struct {
	body        []byte
	gzipBody    []byte
	contentType string
	etag        string
	gzipETag    string
	immutable   bool
}

// pageVariant is the bounded identity of one negotiated HTML representation.
// HTTP pages can be decided only by this service's config lock, supported tag
// and declared aliases, so every value is enumerable at startup. Raw request
// headers never become cache keys.
type pageVariant struct {
	name         string
	requestedTag string
	resolvedTag  string
	source       i18n.Source
}

func pageVariantFor(name string, locale i18n.Context) pageVariant {
	return pageVariant{
		name:         name,
		requestedTag: locale.RequestedTag,
		resolvedTag:  locale.ResolvedTag,
		source:       locale.Source,
	}
}

// assetStore is the startup-built name -> asset map.
type assetStore struct {
	once         sync.Once
	items        map[string]*asset
	pages        map[pageVariant]*asset
	catalogNames map[string]string
	pageContexts []i18n.Context
}

// gzipWorthwhile is the size below which compressing costs more than it saves.
// A short response fits in one packet either way, and the gzip framing can make
// it larger.
const gzipWorthwhile = 512

func newAsset(body []byte, contentType string) *asset {
	a := &asset{
		body:        body,
		contentType: contentType,
		// A strong validator: the tag is of the bytes actually served, so a
		// rebuild that changes nothing keeps the client's cached copy valid.
		etag: assetETag(body),
	}
	if len(body) >= gzipWorthwhile {
		var buf bytes.Buffer
		zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
		if err == nil {
			if _, err := zw.Write(body); err == nil && zw.Close() == nil {
				// Only keep it when it actually helped. Storing a "compressed"
				// copy that is larger would make the negotiated response worse
				// than the plain one.
				if buf.Len() < len(body) {
					a.gzipBody = append([]byte(nil), buf.Bytes()...)
					a.gzipETag = assetETag(a.gzipBody)
				}
			}
		}
	}
	return a
}

func assetETag(body []byte) string {
	sum := sha256.Sum256(body)
	return `"` + hex.EncodeToString(sum[:]) + `"`
}

// build walks the embedded trees once. It runs under sync.Once so the map is
// read-only for the life of the process and needs no lock on the serving path.
func (s *assetStore) build() {
	s.items = map[string]*asset{}
	s.pages = map[pageVariant]*asset{}
	s.catalogNames = map[string]string{}

	entries, err := webFS.ReadDir("web/assets")
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			b, err := webFS.ReadFile("web/assets/" + e.Name())
			if err != nil {
				continue
			}
			prepared := newAsset(b, webui.ContentType(e.Name()))
			s.items[e.Name()] = prepared
			for _, locale := range []string{"qps-Ploc", "qps-Plocm"} {
				if e.Name() != locale+".pool.js" {
					continue
				}
				// The URL names the identity representation's complete SHA-256.
				// A rebuild can therefore cache forever without making an old
				// catalog reachable from newly rendered HTML.
				hash := strings.Trim(prepared.etag, `"`)
				name := locale + "." + hash + ".pool.js"
				immutable := *prepared
				immutable.immutable = true
				s.items[name] = &immutable
				s.catalogNames[locale] = name
			}
		}
	}

	// The shared runtime every page loads first lives in the SDK so there is
	// one copy of it. A service overrides a shared name by shipping its own,
	// which is why the service's files were read first and are not replaced.
	for _, name := range webui.Names() {
		if _, taken := s.items[name]; taken {
			continue
		}
		if b, ct, ok := webui.Asset(name); ok {
			s.items[name] = newAsset(b, ct)
		}
	}

	contexts := s.pageContexts
	if len(contexts) == 0 {
		contexts = []i18n.Context{i18n.NewContext("", "", "", i18n.DefaultManifest())}
	}
	pages, err := webFS.ReadDir("web")
	if err == nil {
		for _, e := range pages {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".html") {
				continue
			}
			if b, err := webFS.ReadFile("web/" + e.Name()); err == nil {
				for _, locale := range contexts {
					catalogName := s.catalogNames[locale.ResolvedTag]
					rendered := renderPage(b, locale, catalogName)
					s.pages[pageVariantFor(e.Name(), locale)] = newAsset(
						rendered, "text/html; charset=utf-8")
				}
			}
		}
	}
}

// preparePages enumerates the request-boundary contexts and eagerly builds all
// page and static representations. Calling it from New makes first request
// latency a map lookup rather than an embed read, HTML rewrite, hash and gzip.
func (s *assetStore) preparePages(negotiator *i18n.Negotiator) {
	s.pageContexts = negotiatedPageContexts(negotiator)
	s.once.Do(s.build)
}

func (s *assetStore) asset(name string) (*asset, bool) {
	s.once.Do(s.build)
	a, ok := s.items[name]
	return a, ok
}

func (s *assetStore) page(name string, locale i18n.Context) (*asset, bool) {
	s.once.Do(s.build)
	a, ok := s.pages[pageVariantFor(name, locale)]
	return a, ok
}

func (s *assetStore) catalogName(locale string) (string, bool) {
	s.once.Do(s.build)
	name, ok := s.catalogNames[locale]
	return name, ok
}

// negotiatedPageContexts is the finite set an HTTP request can produce. A
// config lock makes exactly one context. In auto mode, empty/invalid/wildcard
// headers produce the default, while supported tags and declared aliases
// produce the remaining HTTP contexts. Weighted or differently cased headers
// reduce to one of the same canonical decisions.
func negotiatedPageContexts(negotiator *i18n.Negotiator) []i18n.Context {
	if negotiator == nil {
		negotiator = &i18n.Negotiator{Manifest: i18n.DefaultManifest()}
	}
	manifest := negotiator.Manifest
	if manifest == nil {
		manifest = i18n.DefaultManifest()
	}
	seen := map[pageVariant]bool{}
	contexts := make([]i18n.Context, 0, 1+len(manifest.Supported)+len(manifest.Aliases))
	add := func(header string) {
		r := &http.Request{Header: make(http.Header)}
		if header != "" {
			r.Header.Set("Accept-Language", header)
		}
		locale := negotiator.Resolve(r)
		key := pageVariantFor("", locale)
		if !seen[key] {
			seen[key] = true
			contexts = append(contexts, locale)
		}
	}

	config := strings.TrimSpace(negotiator.ConfigLanguage)
	if config != "" && !strings.EqualFold(config, "auto") {
		add("")
		return contexts
	}
	add("")
	for _, tag := range manifest.Supported {
		add(tag)
	}
	for alias := range manifest.Aliases {
		add(alias)
	}
	return contexts
}

func acceptsGzip(r *http.Request) bool {
	explicit := false
	gzipQuality := -1
	wildcardQuality := -1
	for _, v := range r.Header.Values("Accept-Encoding") {
		for _, part := range strings.Split(v, ",") {
			pieces := strings.Split(part, ";")
			token := strings.TrimSpace(pieces[0])
			isGzip := strings.EqualFold(token, "gzip")
			isWildcard := token == "*"
			if !isGzip && !isWildcard {
				continue
			}
			if isGzip {
				explicit = true
			}

			quality := 1000
			valid := true
			seenQuality := false
			for _, raw := range pieces[1:] {
				parameter := strings.TrimSpace(raw)
				name, value, found := strings.Cut(parameter, "=")
				if !found {
					if strings.EqualFold(parameter, "q") {
						valid = false
						break
					}
					continue
				}
				if !strings.EqualFold(strings.TrimSpace(name), "q") {
					continue
				}
				if seenQuality {
					valid = false
					break
				}
				seenQuality = true
				quality, valid = parseEncodingQuality(value)
				if !valid {
					break
				}
			}
			// An invalid weight does not turn compression on. Remember an
			// explicit gzip member even when it is malformed: a later wildcard
			// must not override a client that tried (and failed) to name gzip.
			if !valid {
				quality = 0
			}
			if isGzip && quality > gzipQuality {
				gzipQuality = quality
			}
			if isWildcard && quality > wildcardQuality {
				wildcardQuality = quality
			}
		}
	}
	if explicit {
		return gzipQuality > 0
	}
	return wildcardQuality > 0
}

// parseEncodingQuality reads the bounded HTTP qvalue grammar without using a
// locale-sensitive or general-purpose float parser. It returns thousandths so
// NaN, exponents, values above one and more than three fractional digits can
// never become an accidental opt-in to compression.
func parseEncodingQuality(raw string) (int, bool) {
	value := strings.TrimSpace(raw)
	if value == "0" {
		return 0, true
	}
	if value == "1" {
		return 1000, true
	}
	if len(value) < 2 || len(value) > 5 || value[1] != '.' ||
		(value[0] != '0' && value[0] != '1') {
		return 0, false
	}

	digits := value[2:]
	quality := 0
	place := 100
	for i := 0; i < len(digits); i++ {
		if digits[i] < '0' || digits[i] > '9' ||
			(value[0] == '1' && digits[i] != '0') {
			return 0, false
		}
		quality += int(digits[i]-'0') * place
		place /= 10
	}
	if value[0] == '1' {
		return 1000, true
	}
	return quality, true
}

// serveAsset writes prepared bytes, honoring encoding negotiation and a
// representation-specific conditional request. Its caller owns semantic
// headers: static assets add no language headers, while a prepared page sets
// Content-Language and Vary: Accept-Language before arriving here.
func serveAsset(w http.ResponseWriter, r *http.Request, a *asset) {
	h := w.Header()
	h.Set("Content-Type", a.contentType)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Add("Vary", "Accept-Encoding")
	if a.immutable {
		h.Set("Cache-Control", "public,max-age=31536000,immutable")
	}

	selectedETag := a.etag
	useGzip := a.gzipBody != nil && acceptsGzip(r)
	if useGzip {
		h.Set("Content-Encoding", "gzip")
		selectedETag = a.gzipETag
	}
	h.Set("ETag", selectedETag)

	if matchesETag(r.Header.Get("If-None-Match"), selectedETag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if useGzip {
		_, _ = w.Write(a.gzipBody)
		return
	}
	_, _ = w.Write(a.body)
}

// matchesETag reports whether a client's If-None-Match covers this tag. The
// weak prefix is accepted because a weak match is still a match for a body the
// client would render identically.
func matchesETag(header, etag string) bool {
	if header == "" || etag == "" {
		return false
	}
	for _, candidate := range strings.Split(header, ",") {
		c := strings.TrimSpace(candidate)
		if c == "*" {
			return true
		}
		c = strings.TrimPrefix(c, "W/")
		if c == etag || c == strings.TrimPrefix(etag, "W/") {
			return true
		}
	}
	return false
}

// renderPage puts the resolved locale into the document before it is served.
//
// The language is decided by the server and written into the markup, so it is
// already correct at first paint. A page that set its own language from script
// would render once in the wrong one, and on the floor browser that flash is
// the whole load.
func renderPage(body []byte, locale i18n.Context, catalogName string) []byte {
	if locale.ResolvedTag == "" {
		return body
	}
	requested := locale.RequestedTag
	if requested == "" {
		requested = locale.ResolvedTag
	}
	replacement := []byte(`<html lang="` + html.EscapeString(locale.ResolvedTag) +
		`" dir="` + html.EscapeString(locale.Direction) +
		`" data-yuruna-requested-language="` + html.EscapeString(requested) +
		`" data-yuruna-locale-source="` + html.EscapeString(string(locale.Source)) + `">`)
	for _, existing := range [][]byte{[]byte(`<html lang="en">`), []byte("<html>")} {
		if idx := bytes.Index(body, existing); idx >= 0 {
			out := make([]byte, 0, len(body)+len(replacement))
			out = append(out, body[:idx]...)
			out = append(out, replacement...)
			out = append(out, body[idx+len(existing):]...)
			return injectCatalogAsset(out, catalogName)
		}
	}
	return injectCatalogAsset(body, catalogName)
}

// injectCatalogAsset adds the generated non-default catalog before a page's
// own script runs. English already travels inside common.js. Keeping pseudo
// catalogs separate leaves the ordinary request count unchanged, while a
// pseudo reference run still exercises the exact shipped builder and asset.
func injectCatalogAsset(body []byte, catalogName string) []byte {
	if catalogName == "" {
		return body
	}
	marker := []byte("<script src=\"/assets/common.js\"></script>")
	idx := bytes.Index(body, marker)
	if idx < 0 {
		return body
	}
	insertAt := idx + len(marker)
	tag := []byte("\n<script src=\"/assets/" + html.EscapeString(catalogName) + "\"></script>")
	out := make([]byte, 0, len(body)+len(tag))
	out = append(out, body[:insertAt]...)
	out = append(out, tag...)
	out = append(out, body[insertAt:]...)
	return out
}
