// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"regexp"
	"sort"
	"strings"
)

var textMarker = regexp.MustCompile(`(<[A-Za-z][A-Za-z0-9]*\b[^>]*\bdata-i18n="([a-zA-Z0-9_.-]+)"[^>]*>)[^<]*(</[A-Za-z][A-Za-z0-9]*\s*>)`)
var elementMarker = regexp.MustCompile(`<[^>]+\bdata-i18n-(?:title|aria-label|placeholder|alt)="[a-zA-Z0-9_.-]+"[^>]*>`)
var htmlLanguage = regexp.MustCompile(`<html(?:\s[^>]*)?>`)
var inertMarkup = regexp.MustCompile(`(?is)<!--.*?-->|<script\b[^>]*>.*?</script\s*>|<style\b[^>]*>.*?</style\s*>`)
var argumentMarker = regexp.MustCompile(`\bdata-i18n-args="([^"]*)"`)

// RenderHTML replaces explicit author-owned message slots only. Catalog values
// are text: a translation cannot introduce markup, attributes or script. It is
// called when the immutable page representations are prepared, not per request.
func RenderHTML(body []byte, locale Context, catalog *Catalog) []byte {
	var out strings.Builder
	start := 0
	for _, match := range inertMarkup.FindAllIndex(body, -1) {
		out.Write(renderMarkup(body[start:match[0]], locale, catalog))
		out.Write(body[match[0]:match[1]])
		start = match[1]
	}
	out.Write(renderMarkup(body[start:], locale, catalog))
	return []byte(out.String())
}

func renderMarkup(body []byte, locale Context, catalog *Catalog) []byte {
	source := htmlLanguage.ReplaceAllString(string(body), `<html lang="`+html.EscapeString(locale.ResolvedTag)+`" dir="`+html.EscapeString(locale.Direction)+`" data-yuruna-requested-language="`+html.EscapeString(locale.RequestedTag)+`" data-yuruna-locale-source="`+html.EscapeString(string(locale.Source))+`">`)
	source = textMarker.ReplaceAllStringFunc(source, func(slot string) string {
		parts := textMarker.FindStringSubmatch(slot)
		var args map[string]any
		if argument := argumentMarker.FindStringSubmatch(parts[1]); len(argument) > 0 {
			if err := json.Unmarshal([]byte(html.UnescapeString(argument[1])), &args); err != nil {
				panic("invalid static catalog arguments: " + err.Error())
			}
		}
		return parts[1] + html.EscapeString(catalog.Render(parts[2], args, locale.ResolvedTag)) + parts[3]
	})
	source = elementMarker.ReplaceAllStringFunc(source, func(element string) string {
		for _, name := range []string{"title", "aria-label", "placeholder", "alt"} {
			marker := regexp.MustCompile(`\bdata-i18n-` + name + `="([a-zA-Z0-9_.-]+)"`)
			parts := marker.FindStringSubmatch(element)
			if len(parts) == 0 {
				continue
			}
			value := html.EscapeString(catalog.Render(parts[1], nil, locale.ResolvedTag))
			attribute := regexp.MustCompile(`(^|\s)` + name + `="[^"]*"`)
			if attribute.MatchString(element) {
				element = attribute.ReplaceAllStringFunc(element, func(old string) string { return " " + name + `="` + value + `"` })
			} else {
				element = strings.TrimSuffix(element, ">") + " " + name + `="` + value + `">`
			}
		}
		return element
	})
	return []byte(source)
}

type representation struct {
	body []byte
	etag string
}

// Pages owns a finite set of precomputed locale representations and their
// validators. Request headers select an existing entry; they never create a
// cache key or cause catalog/template parsing on the request path.
type Pages struct {
	Catalog    *Catalog
	Negotiator *Negotiator
	contexts   map[string]Context
	pages      map[string]map[string]representation
	browser    map[string]representation
	names      map[string]string
	kernel     string
}

func pageContextKey(locale Context) string {
	return locale.ResolvedTag + "|" + locale.RequestedTag + "|" + string(locale.Source)
}
func representationFor(body []byte) representation {
	return representation{body, fmt.Sprintf(`"%x"`, sha256.Sum256(body))}
}

// NewPages registers only the data carried by the calling binary. Pseudo
// locales require the service's explicit development switch, just as they do
// in the pool service. Accepted future locales arrive through generated maps.
func NewPages(data map[string]map[string]string, browser map[string]string, kernel, language string, allowPseudo bool) (*Pages, error) {
	p := &Pages{Catalog: NewCatalog(nil), contexts: map[string]Context{}, pages: map[string]map[string]representation{}, browser: map[string]representation{}, names: map[string]string{}, kernel: kernel}
	tags := make([]string, 0, len(data))
	for tag, domains := range data {
		tags = append(tags, tag)
		for domain, value := range domains {
			if err := p.Catalog.Register(tag, domain, value); err != nil {
				return nil, err
			}
		}
		if value, ok := browser[tag]; ok && tag != "en-US" {
			body := []byte(value)
			name := fmt.Sprintf("locale.%x.js", sha256.Sum256(body))
			p.names[tag] = name
			p.browser[name] = representationFor(body)
		}
	}
	sort.Strings(tags)
	p.Negotiator = &Negotiator{Manifest: DefaultManifest(), Available: tags, ConfigLanguage: language, AllowPseudo: allowPseudo}
	headers := append([]string{""}, tags...)
	for alias := range DefaultManifest().Aliases {
		headers = append(headers, alias)
	}
	for _, header := range headers {
		r, _ := http.NewRequest(http.MethodGet, "http://localhost/", nil)
		r.Header.Set("Accept-Language", header)
		locale := p.Negotiator.Resolve(r)
		p.contexts[pageContextKey(locale)] = locale
	}
	return p, nil
}

// Prepare freezes the translated text and catalog loading order. Self-contained
// pages register their runtime and table before the existing application script,
// preserving their zero additional request contract.
func (p *Pages) Prepare(name string, body []byte, inline bool) {
	variants := map[string]representation{}
	for key, locale := range p.contexts {
		text := string(RenderHTML(body, locale, p.Catalog))
		if inline {
			bundle := p.kernel
			if asset := p.names[locale.ResolvedTag]; asset != "" {
				bundle += "\n" + string(p.browser[asset].body)
			}
			bundle += "\nwindow.YurunaI18n.init(document);\n"
			text = strings.Replace(text, "<script>", "<script>\n"+bundle, 1)
		} else if asset := p.names[locale.ResolvedTag]; asset != "" {
			marker := `<script src="/assets/common.js"></script>`
			text = strings.Replace(text, marker, marker+"\n"+`<script src="/assets/`+asset+`"></script>`, 1)
		}
		variants[key] = representationFor([]byte(text))
	}
	p.pages[name] = variants
}

func matchETag(header, etag string) bool {
	for _, value := range strings.Split(header, ",") {
		value = strings.TrimSpace(value)
		if value == "*" || strings.TrimPrefix(value, "W/") == etag {
			return true
		}
	}
	return false
}

// Serve writes a page and its locale-specific validator, including on a 304.
// The caller owns its CSP because self-contained and external-script pages
// deliberately have different script policies.
func (p *Pages) Serve(w http.ResponseWriter, r *http.Request, name string) bool {
	locale := p.Negotiator.Resolve(r)
	page, ok := p.pages[name][pageContextKey(locale)]
	if !ok {
		return false
	}
	Apply(w.Header(), locale)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=0, must-revalidate")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("ETag", page.etag)
	if matchETag(r.Header.Get("If-None-Match"), page.etag) {
		w.WriteHeader(http.StatusNotModified)
		return true
	}
	_, _ = w.Write(page.body)
	return true
}

func (p *Pages) ServeAsset(w http.ResponseWriter, r *http.Request, name string) bool {
	asset, ok := p.browser[name]
	if !ok {
		return false
	}
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("ETag", asset.etag)
	if matchETag(r.Header.Get("If-None-Match"), asset.etag) {
		w.WriteHeader(http.StatusNotModified)
		return true
	}
	_, _ = w.Write(asset.body)
	return true
}
