// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCatalogMarkupEscapesTextAndLeavesCodeUntouched(t *testing.T) {
	c := NewCatalog(nil)
	if err := c.Register("en-US", "page", `{"page.label":"<img src=x onerror=alert(1)> & \"quote\""}`); err != nil {
		t.Fatal(err)
	}
	l := NewContext("", "", "", DefaultManifest())
	body := `<html lang="en"><title data-i18n="page.label">Title</title><input title="old" data-i18n-title="page.label"><script>var x='<b data-i18n="page.label">code</b>';</script><!-- <b data-i18n="page.label">comment</b> -->`
	out := string(RenderHTML([]byte(body), l, c))
	if strings.Contains(out, "<img src=") {
		t.Fatal("catalog value became executable markup")
	}
	if !strings.Contains(out, `title="&lt;img src=x onerror=alert(1)&gt; &amp; &#34;quote&#34;"`) {
		t.Fatalf("attribute was not escaped: %s", out)
	}
	if !strings.Contains(out, `<script>var x='<b data-i18n="page.label">code</b>';</script>`) || !strings.Contains(out, `<!-- <b data-i18n="page.label">comment</b> -->`) {
		t.Fatal("code or comments were translated")
	}
}

func TestCatalogPagesBoundedLocaleCacheAndConditionalRequests(t *testing.T) {
	p, err := NewPages(map[string]map[string]string{
		"en-US":     {"page": `{"page.label":"Hello"}`},
		"qps-Ploc":  {"page": `{"page.label":"[Expanded hello]"}`},
		"qps-Plocm": {"page": `{"page.label":"[Mirrored hello]"}`},
	}, map[string]string{"qps-Ploc": "window.example='expanded';", "qps-Plocm": "window.example='mirrored';"}, "", "auto", true)
	if err != nil {
		t.Fatal(err)
	}
	p.Prepare("page", []byte(`<html lang="en"><p data-i18n="page.label">Hello</p><script src="/assets/common.js"></script><script src="/assets/page.js"></script>`), false)
	get := func(language, etag string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set("Accept-Language", language)
		r.Header.Set("If-None-Match", etag)
		w := httptest.NewRecorder()
		if !p.Serve(w, r, "page") {
			t.Fatalf("missing representation for %q", language)
		}
		return w
	}
	english := get("en-US", "")
	expanded := get("qps-Ploc", english.Header().Get("ETag"))
	if expanded.Code != http.StatusOK || !strings.Contains(expanded.Body.String(), "[Expanded hello]") {
		t.Fatal("English validator suppressed expanded text")
	}
	if expanded.Header().Get("Content-Language") != "qps-Ploc" || expanded.Header().Get("Vary") != "Accept-Language" {
		t.Fatal("missing locale/cache contract")
	}
	if strings.Contains(english.Body.String(), "locale.") {
		t.Fatal("English added a catalog request")
	}
	if strings.Index(expanded.Body.String(), "locale.") >= strings.Index(expanded.Body.String(), "/assets/page.js") {
		t.Fatal("catalog arrives after application")
	}
	if again := get("qps-Ploc", expanded.Header().Get("ETag")); again.Code != http.StatusNotModified || again.Body.Len() != 0 || again.Header().Get("Content-Language") != "qps-Ploc" {
		t.Fatal("same-locale revalidation failed")
	}
	before := len(p.contexts)
	for _, language := range []string{"zz-ZZ", "en;q=0.8, fr;q=0.1", strings.Repeat("z", 10000), "<script>"} {
		_ = get(language, "")
	}
	if len(p.contexts) != before {
		t.Fatal("untrusted header expanded representation cache")
	}
	for asset := range p.browser {
		r := httptest.NewRequest(http.MethodGet, "/assets/"+asset, nil)
		w := httptest.NewRecorder()
		if !p.ServeAsset(w, r, asset) || w.Header().Get("Cache-Control") != "public, max-age=31536000, immutable" {
			t.Fatal("catalog is not an immutable asset")
		}
	}
}
