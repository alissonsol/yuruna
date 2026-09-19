// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"yuruna.com/test/extension/caching-proxy-parser-service/internal/catalog"
	"yuruna.com/test/extension/extension-sdk/i18n"
)

func TestGeneratedPageLocaleHeadersAndConditionalCache(t *testing.T) {
	prior := localizedPages()
	defer func() { localizedPageStore = prior }()
	for locale := range catalog.Catalogs {
		pages, err := i18n.NewPages(catalog.Catalogs, catalog.BrowserCatalogs, catalog.BrowserKernel, "auto", true)
		if err != nil {
			t.Fatal(err)
		}
		pages.Prepare("index.html", []byte(indexPage), true)
		localizedPageStore = pages
		localizedPageOnce = sync.Once{}
		localizedPageOnce.Do(func() {})
		get := func(language, etag string) *httptest.ResponseRecorder {
			r := httptest.NewRequest(http.MethodGet, "/", nil)
			r.Header.Set("Accept-Language", language)
			r.Header.Set("If-None-Match", etag)
			w := httptest.NewRecorder()
			handleHTML(w, r)
			return w
		}
		english := get("en-US", "")
		w := get(locale, "")
		if w.Code != http.StatusOK || w.Header().Get("Content-Language") != locale || !strings.Contains(w.Header().Get("Vary"), "Accept-Language") {
			t.Fatalf("%s: status=%d headers=%v", locale, w.Code, w.Header())
		}
		if !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") || !strings.Contains(w.Header().Get("Content-Type"), "charset=utf-8") {
			t.Fatal("generated page lost CSP/UTF-8")
		}
		if !strings.Contains(w.Body.String(), `lang="`+locale+`"`) || !strings.Contains(w.Body.String(), "YurunaI18n.init(document)") {
			t.Fatal("generated page missing locale or runtime")
		}
		if locale == "qps-Plocm" && !strings.Contains(w.Body.String(), `dir="rtl"`) {
			t.Fatal("generated page missing direction")
		}
		etag := w.Header().Get("ETag")
		repeat := get(locale, etag)
		if etag == "" || repeat.Code != http.StatusNotModified || repeat.Body.Len() != 0 || repeat.Header().Get("Content-Language") != locale {
			t.Fatal("generated page lost conditional cache contract")
		}
		if locale != "en-US" && get(locale, english.Header().Get("ETag")).Code != http.StatusOK {
			t.Fatal("cross-language validator reused")
		}
		if strings.Contains(w.Body.String(), `<script src=`) {
			t.Fatal("self-contained generated page added external script request")
		}
	}
}
