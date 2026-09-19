// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"yuruna.com/test/extension/extension-sdk/i18n"
)

// The reference slice is exercised against the real server rather than against
// a fixture: a static shell that happens to contain the right string proves
// nothing about what a reader receives.
func newLocaleServer(t *testing.T, opts Options) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(New(nil, opts).Handler())
	t.Cleanup(srv.Close)
	return srv
}

func get(t *testing.T, srv *httptest.Server, path string, header map[string]string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, srv.URL+path, nil)
	if err != nil {
		t.Fatalf("building the request: %v", err)
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	// A redirect would hide which representation answered.
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func body(t *testing.T, resp *http.Response) string {
	t.Helper()
	var sb strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := resp.Body.Read(buf)
		sb.Write(buf[:n])
		if err != nil {
			break
		}
	}
	return sb.String()
}

// The language reaches the document before it is served, so the page is already
// in the right one at first paint. A page that corrected itself from script
// would render once in the wrong language, and on the floor browser that flash
// is the whole load.
func TestAPageCarriesTheResolvedLanguage(t *testing.T) {
	srv := newLocaleServer(t, Options{})
	resp := get(t, srv, "/", map[string]string{"Accept-Language": "en-US"})

	if got := resp.Header.Get("Content-Language"); got != "en-US" {
		t.Errorf("Content-Language = %q, want en-US", got)
	}
	vary := strings.ToLower(strings.Join(resp.Header.Values("Vary"), ", "))
	if !strings.Contains(vary, "accept-language") {
		t.Errorf("Vary = %q, want it to include Accept-Language", resp.Header.Values("Vary"))
	}
	html := body(t, resp)
	if !strings.Contains(html, `<html lang="en-US" dir="ltr" data-yuruna-requested-language="en-US" data-yuruna-locale-source="http">`) {
		t.Errorf("the document does not carry the resolved language and direction")
	}
}

func TestPageLocaleContextIsAttributeEscaped(t *testing.T) {
	rendered := string(renderPage([]byte(`<html lang="en"><body></body></html>`), i18n.Context{
		RequestedTag: `en-US" data-injected="yes`,
		ResolvedTag:  "en-US",
		Direction:    "ltr",
		Source:       i18n.Source(`http" data-injected="yes`),
	}, ""))
	if strings.Contains(rendered, ` data-injected="yes`) {
		t.Fatalf("locale context escaped its attribute boundary: %s", rendered)
	}
	if !strings.Contains(rendered, "&#34;") {
		t.Fatalf("locale context did not HTML-escape quotes: %s", rendered)
	}
}

// A pseudo locale is not negotiable unless the run asked for it. A reader who
// received expanded or mirrored text would read the page as broken.
func TestPseudoLocalesAreRefusedUnlessOpened(t *testing.T) {
	closed := newLocaleServer(t, Options{})
	resp := get(t, closed, "/", map[string]string{"Accept-Language": "qps-Ploc"})
	if got := resp.Header.Get("Content-Language"); got != "en-US" {
		t.Errorf("a release build served %q for a pseudo request; it must fall back to the default", got)
	}

	open := newLocaleServer(t, Options{AllowPseudoLocale: true})
	resp = get(t, open, "/", map[string]string{"Accept-Language": "qps-Ploc"})
	if got := resp.Header.Get("Content-Language"); got != "qps-Ploc" {
		t.Errorf("a reference run served %q, want qps-Ploc", got)
	}
	if html := body(t, resp); !strings.Contains(html, `lang="qps-Ploc"`) {
		t.Error("the pseudo document does not carry its own language")
	} else if matched, _ := regexp.MatchString(`src="/assets/qps-Ploc\.[0-9a-f]{64}\.pool\.js"`, html); !matched {
		t.Error("the pseudo document does not load the generated pool catalog")
	}
}

// The mirrored pseudo locale is what exposes a hard-coded direction: the
// document has to say rtl, not merely change its words.
func TestTheMirroredPseudoLocaleFlipsDirection(t *testing.T) {
	srv := newLocaleServer(t, Options{AllowPseudoLocale: true})
	resp := get(t, srv, "/", map[string]string{"Accept-Language": "qps-Plocm"})
	html := body(t, resp)
	if !strings.Contains(html, `dir="rtl"`) {
		t.Error("the mirrored pseudo locale did not set dir=rtl, so a hard-coded direction would go unnoticed")
	}
	assetPattern := regexp.MustCompile(`/assets/qps-Plocm\.([0-9a-f]{64})\.pool\.js`)
	match := assetPattern.FindStringSubmatch(html)
	if len(match) != 2 {
		t.Error("the mirrored pseudo document does not load its generated pool catalog")
		return
	}
	catalog := get(t, srv, match[0], map[string]string{"Accept-Encoding": "identity"})
	if catalog.StatusCode != http.StatusOK {
		t.Fatalf("mirrored pool catalog status = %d, want 200", catalog.StatusCode)
	}
	text := body(t, catalog)
	if !strings.Contains(text, "pool.repo_no_access") {
		t.Error("the served mirrored catalog does not contain the pool domain")
	}
	sum := sha256.Sum256([]byte(text))
	if got := hex.EncodeToString(sum[:]); got != match[1] {
		t.Errorf("catalog URL hash = %s, body hash = %s", match[1], got)
	}
	if got := catalog.Header.Get("ETag"); got != `"`+match[1]+`"` {
		t.Errorf("catalog ETag = %q, want the URL content hash", got)
	}
	if got := catalog.Header.Get("Cache-Control"); got != "public,max-age=31536000,immutable" {
		t.Errorf("catalog Cache-Control = %q, want immutable", got)
	}

	conditional := get(t, srv, match[0], map[string]string{
		"Accept-Encoding": "identity",
		"If-None-Match":   catalog.Header.Get("ETag"),
	})
	if conditional.StatusCode != http.StatusNotModified {
		t.Errorf("catalog conditional status = %d, want 304", conditional.StatusCode)
	}
	if got := conditional.Header.Get("Cache-Control"); got != "public,max-age=31536000,immutable" {
		t.Errorf("catalog 304 dropped immutable Cache-Control: %q", got)
	}
	if got := conditional.Header.Get("ETag"); got != catalog.Header.Get("ETag") {
		t.Errorf("catalog 304 ETag = %q, want %q", got, catalog.Header.Get("ETag"))
	}
}

// Two clients asking for different languages must not be able to receive each
// other's. The validator is of the rendered bytes, which already carry the
// locale, so the two representations cannot collide in a cache.
func TestTwoClientsCannotReceiveEachOthersLanguage(t *testing.T) {
	srv := newLocaleServer(t, Options{AllowPseudoLocale: true})

	english := get(t, srv, "/", map[string]string{"Accept-Language": "en-US"})
	pseudo := get(t, srv, "/", map[string]string{"Accept-Language": "qps-Plocm"})

	englishTag := english.Header.Get("ETag")
	pseudoTag := pseudo.Header.Get("ETag")
	if englishTag == "" || pseudoTag == "" {
		t.Fatal("a negotiated page served no ETag, so a cache has no validator to key on")
	}
	if englishTag == pseudoTag {
		t.Error("two languages of the same page share one validator, so a cache can serve one for the other")
	}

	// The English client's validator must not satisfy the other language's
	// request: that is the exact shape of a cache handing over the wrong one.
	crossed := get(t, srv, "/", map[string]string{
		"Accept-Language": "qps-Plocm",
		"If-None-Match":   englishTag,
	})
	if crossed.StatusCode == http.StatusNotModified {
		t.Error("an English validator satisfied a request for another language")
	}
}

// A conditional request saves the body, not the labeling. A 304 that dropped
// Content-Language would let a cache re-label a body it already holds.
func TestANotModifiedResponseRepeatsTheLocaleHeaders(t *testing.T) {
	srv := newLocaleServer(t, Options{})
	first := get(t, srv, "/", map[string]string{"Accept-Language": "en-US"})
	etag := first.Header.Get("ETag")
	if etag == "" {
		t.Fatal("no ETag on the first response")
	}
	second := get(t, srv, "/", map[string]string{"Accept-Language": "en-US", "If-None-Match": etag})
	if second.StatusCode != http.StatusNotModified {
		t.Fatalf("status %d, want 304 for an unchanged representation", second.StatusCode)
	}
	if got := second.Header.Get("Content-Language"); got != "en-US" {
		t.Errorf("the 304 dropped Content-Language (got %q)", got)
	}
	vary := strings.ToLower(strings.Join(second.Header.Values("Vary"), ", "))
	if !strings.Contains(vary, "accept-language") {
		t.Errorf("the 304 dropped Vary: Accept-Language (got %q)", second.Header.Values("Vary"))
	}
}

// An asset is the same bytes in every language. Declaring it negotiated would
// split every cache entry on a header that changes nothing about the response.
func TestAssetsAreNotNegotiated(t *testing.T) {
	srv := newLocaleServer(t, Options{})
	resp := get(t, srv, "/assets/yuruna.core.js", map[string]string{"Accept-Language": "en-US"})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d for the shared runtime", resp.StatusCode)
	}
	if got := resp.Header.Get("Content-Language"); got != "" {
		t.Errorf("a locale-invariant asset claimed Content-Language %q", got)
	}
	vary := strings.ToLower(strings.Join(resp.Header.Values("Vary"), ", "))
	if strings.Contains(vary, "accept-language") {
		t.Errorf("a locale-invariant asset varies on the language header: %q", resp.Header.Values("Vary"))
	}
	if !strings.Contains(vary, "accept-encoding") {
		t.Errorf("Vary = %q, want Accept-Encoding for a compressible asset", resp.Header.Values("Vary"))
	}
}

// The compressed copy is made once at startup. A handler that compressed per
// request would spend that work on every hit of a file that never changes.
func TestAssetsAreServedPrecompressed(t *testing.T) {
	srv := newLocaleServer(t, Options{})
	resp := get(t, srv, "/assets/yuruna.core.js", map[string]string{"Accept-Encoding": "gzip"})
	if got := resp.Header.Get("Content-Encoding"); got != "gzip" {
		t.Errorf("Content-Encoding = %q, want gzip for a client that accepts it", got)
	}
	if resp.Header.Get("ETag") == "" {
		t.Error("an asset served no ETag, so every reload re-downloads it")
	}

	plain := get(t, srv, "/assets/yuruna.core.js", nil)
	if got := plain.Header.Get("Content-Encoding"); got != "" {
		t.Errorf("a client that did not accept gzip received %q", got)
	}
}

// The catalog this binary carries has to actually decode and render, or the
// service would fall back to printing key names at the first localized label.
func TestTheEmbeddedCatalogRenders(t *testing.T) {
	c, err := messages()
	if err != nil {
		t.Fatalf("the embedded catalog did not decode: %v", err)
	}
	if got := c.Render("status.cycle_paused", nil, "en-US"); got != "Paused, waiting for resume." {
		t.Errorf("en-US render = %q", got)
	}
	// The pseudo locale must differ from English, or a pseudo run would prove
	// nothing: identical text is exactly what an untranslated string looks like.
	pseudo := c.Render("status.cycle_paused", nil, "qps-Ploc")
	if pseudo == c.Render("status.cycle_paused", nil, "en-US") {
		t.Error("the expanded pseudo locale rendered the English text, so it cannot reveal an untranslated string")
	}
	if got := c.Render("pool.repo_no_access", nil, "en-US"); got != "No access" {
		t.Errorf("en-US pool render = %q", got)
	}
	for _, locale := range []string{"qps-Ploc", "qps-Plocm"} {
		got := c.Render("pool.repo_no_access", nil, locale)
		if got == "No access" || got == "pool.repo_no_access" {
			t.Errorf("%s pool render = %q, want generated pseudo text", locale, got)
		}
	}
	if len(c.MissingKeys()) != 0 {
		t.Errorf("keys missing from the embedded catalog: %v", c.MissingKeys())
	}
}

// Every locale the binary carries has to be one the manifest describes, or the
// service could negotiate a tag with no formatting rules behind it.
func TestEveryEmbeddedLocaleIsDeclared(t *testing.T) {
	m := i18n.DefaultManifest()
	for locale, domains := range embeddedCatalogs() {
		if _, ok := m.Data[locale]; !ok {
			t.Errorf("the binary embeds %q, which the locale manifest does not declare", locale)
		}
		for _, domain := range []string{"pool", "status"} {
			if domains[domain] == "" {
				t.Errorf("the binary embeds %q without its %q domain", locale, domain)
			}
		}
	}
}

func TestEveryDeliveredLocaleHasCompleteImmutableBrowserCatalog(t *testing.T) {
	srv := newLocaleServer(t, Options{AllowPseudoLocale: true})
	for _, locale := range availableLocales() {
		for _, route := range []string{"/", "/assign", "/hosts", "/pools", "/test-sets", "/scan", "/diagnostics"} {
			response := get(t, srv, route, map[string]string{"Accept-Language": locale})
			html := body(t, response)
			if response.StatusCode != 200 || response.Header.Get("Content-Language") != locale || !strings.Contains(html, `lang="`+locale+`"`) {
				t.Fatalf("%s %s did not negotiate the production locale: %d %v", locale, route, response.StatusCode, response.Header)
			}
			if locale == "en-US" {
				continue
			}
			pattern := regexp.MustCompile(`/assets/` + regexp.QuoteMeta(locale) + `\.[0-9a-f]{64}\.pool\.js`)
			names := pattern.FindAllString(html, -1)
			if len(names) != 1 {
				t.Fatalf("%s %s has %d selected catalog requests", locale, route, len(names))
			}
			response = get(t, srv, names[0], map[string]string{"Accept-Encoding": "identity"})
			text := body(t, response)
			if !strings.Contains(text, "pool.repo_no_access") || !strings.Contains(text, "status.cycle_paused") {
				t.Fatalf("%s catalog omitted a service or shared chrome domain", locale)
			}
			if response.Header.Get("Cache-Control") != "public,max-age=31536000,immutable" {
				t.Fatal("selected catalog is not immutable")
			}
			again := get(t, srv, names[0], map[string]string{"If-None-Match": response.Header.Get("ETag"), "Accept-Encoding": "identity"})
			if again.StatusCode != 304 || body(t, again) != "" {
				t.Fatal("selected catalog revalidation changed bytes")
			}
		}
	}
}
