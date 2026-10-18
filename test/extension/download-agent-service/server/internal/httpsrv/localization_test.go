// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"download-agent-service/internal/catalog"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLocalizedServicePagesAndCacheIsolation(t *testing.T) {
	type selection struct {
		language      string
		pseudo        bool
		request, want string
	}
	selections := []selection{
		{"auto", false, "qps-Ploc", "en-US"},
		{"auto", true, "en-US", "en-US"},
		{"auto", true, "qps-Ploc", "qps-Ploc"},
		{"auto", true, "qps-Plocm", "qps-Plocm"},
		{"en-US", true, "qps-Plocm", "en-US"},
		{"auto", true, "en_US, xx-ZZ;q=0.5", "en-US"},
	}
	for _, tag := range deliveredNonDefaultLocales() {
		selections = append(selections, selection{"auto", true, tag, tag})
	}
	for _, options := range selections {
		s := &Server{pages: prepareLocalizedPages(options.language, options.pseudo)}
		for _, page := range []string{"index.html", "diagnostics.html"} {
			request := func(language, etag string) *httptest.ResponseRecorder {
				r := httptest.NewRequest(http.MethodGet, "/", nil)
				r.Header.Set("Accept-Language", language)
				r.Header.Set("If-None-Match", etag)
				w := httptest.NewRecorder()
				s.servePage(page)(w, r)
				return w
			}
			english := request("en-US", "")
			w := request(options.request, "")
			if w.Code != http.StatusOK || w.Header().Get("Content-Language") != options.want {
				t.Fatalf("%s %s: status=%d headers=%v", page, options.request, w.Code, w.Header())
			}
			if !strings.Contains(w.Header().Get("Content-Type"), "charset=utf-8") || !strings.Contains(w.Header().Get("Content-Security-Policy"), "script-src 'self'") || !strings.Contains(w.Header().Get("Vary"), "Accept-Language") {
				t.Fatalf("%s lost UTF-8/CSP/locale cache headers: %v", page, w.Header())
			}
			if !strings.Contains(w.Body.String(), `lang="`+options.want+`"`) {
				t.Fatalf("%s HTML language not negotiated", page)
			}
			if options.want == "qps-Plocm" && !strings.Contains(w.Body.String(), `dir="rtl"`) {
				t.Fatal("missing mirrored direction")
			}
			etag := w.Header().Get("ETag")
			if etag == "" {
				t.Fatal("missing representation validator")
			}
			repeat := request(options.request, etag)
			if repeat.Code != http.StatusNotModified || repeat.Body.Len() != 0 || repeat.Header().Get("Content-Language") != options.want || repeat.Header().Get("Content-Security-Policy") == "" {
				t.Fatalf("%s invalid conditional response", page)
			}
			if options.want != "en-US" {
				if etag == english.Header().Get("ETag") || w.Body.String() == english.Body.String() || !strings.Contains(w.Body.String(), "locale.") {
					t.Fatalf("%s does not deliver a distinct localized page/catalog", page)
				}
				if mixed := request(options.request, english.Header().Get("ETag")); mixed.Code != http.StatusOK {
					t.Fatal("English validator suppressed localized body")
				}
			} else if strings.Contains(w.Body.String(), "locale.") {
				t.Fatal("English added a catalog request")
			}
		}
	}
}

func TestLocalizedAPIErrorRetainsIdentityAcrossEveryDeliveredLocale(t *testing.T) {
	s := &Server{pages: prepareLocalizedPages("auto", true)}
	var english string
	for _, locale := range append([]string{"en-US"}, deliveredNonDefaultLocales()...) {
		r := httptest.NewRequest(http.MethodGet, "/api/invalid", nil)
		r.Header.Set("Accept-Language", locale)
		w := httptest.NewRecorder()
		s.imageID(w, r)
		var body map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if w.Code != http.StatusBadRequest || body["code"] != "download.api_arch_query_parameter_is_required_amd64_or_arm64" || body["ok"] != false || w.Header().Get("Content-Language") != locale || w.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("%s error contract: %d %v %v", locale, w.Code, w.Header(), body)
		}
		if locale == "en-US" {
			english = body["error"].(string)
		} else if strings.HasPrefix(locale, "qps-") && body["error"] == english {
			t.Fatal("pseudo error not localized")
		}
	}
}

func deliveredNonDefaultLocales() []string {
	out := []string{}
	for tag := range catalog.Catalogs {
		if tag != "en-US" {
			out = append(out, tag)
		}
	}
	return out
}
