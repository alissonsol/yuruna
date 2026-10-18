// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"yuruna.com/test/extension/extension-sdk/i18n"
)

func pageRequest(header, encoding, validator string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	if header != "" {
		r.Header.Set("Accept-Language", header)
	}
	if encoding != "" {
		r.Header.Set("Accept-Encoding", encoding)
	}
	if validator != "" {
		r.Header.Set("If-None-Match", validator)
	}
	return r
}

func TestNegotiatedPageVariantsArePreparedAtStartup(t *testing.T) {
	s := New(nil, Options{AllowPseudoLocale: true})
	cases := []struct {
		header    string
		requested string
		resolved  string
		source    i18n.Source
	}{
		{resolved: "en-US", requested: "en-US", source: i18n.SourceDefault},
		{header: "fr-FR", requested: "en-US", resolved: "en-US", source: i18n.SourceDefault},
		{header: "*", requested: "en-US", resolved: "en-US", source: i18n.SourceDefault},
		{header: "en", requested: "en", resolved: "en-US", source: i18n.SourceHTTP},
		{header: "en-US", requested: "en-US", resolved: "en-US", source: i18n.SourceHTTP},
		{header: "fr-FR, en;q=0.8", requested: "en", resolved: "en-US", source: i18n.SourceHTTP},
		{header: "qps-Ploc", requested: "qps-Ploc", resolved: "qps-Ploc", source: i18n.SourceHTTP},
		{header: "fr-FR, qps-Ploc;q=0.8", requested: "qps-Ploc", resolved: "qps-Ploc", source: i18n.SourceHTTP},
		{header: "qps-Plocm", requested: "qps-plocm", resolved: "qps-Plocm", source: i18n.SourceHTTP},
	}
	for _, tc := range cases {
		locale := s.negotiator().Resolve(pageRequest(tc.header, "", ""))
		if locale.RequestedTag != tc.requested || locale.ResolvedTag != tc.resolved || locale.Source != tc.source {
			t.Fatalf("%q context = %+v", tc.header, locale)
		}
		prepared, ok := s.assets.page("board.html", locale)
		if !ok {
			t.Fatalf("%q context has no startup-built page", tc.header)
		}
		if prepared.etag == "" || prepared.gzipETag == "" || len(prepared.gzipBody) == 0 {
			t.Fatalf("%q page was not hashed and precompressed: %+v", tc.header, prepared)
		}
		if !strings.Contains(string(prepared.body), `data-yuruna-requested-language="`+tc.requested+`"`) ||
			!strings.Contains(string(prepared.body), `data-yuruna-locale-source="`+string(tc.source)+`"`) {
			t.Fatalf("%q prepared page lost its locale provenance", tc.header)
		}
		if strings.HasPrefix(tc.resolved, "qps-") &&
			!strings.Contains(string(prepared.body), tc.resolved+".") {
			t.Fatalf("%q prepared page has no content-addressed pseudo catalog", tc.header)
		}
	}
	for variant, prepared := range s.assets.pages {
		if prepared.contentType != "text/html; charset=utf-8" || prepared.etag == "" ||
			prepared.gzipETag == "" || len(prepared.gzipBody) == 0 {
			t.Errorf("page variant %+v was not completely prepared", variant)
		}
	}

	locale := s.negotiator().Resolve(pageRequest("qps-Plocm", "", ""))
	allocations := testing.AllocsPerRun(100, func() {
		if _, ok := s.assets.page("board.html", locale); !ok {
			panic("prepared page disappeared")
		}
	})
	if allocations != 0 {
		t.Fatalf("prepared page lookup allocates %.2f object(s) per request", allocations)
	}
}

func TestNegotiatedPageUsesPreparedEncodingValidators(t *testing.T) {
	s := New(nil, Options{AllowPseudoLocale: true})
	handler := s.routes()

	identityRequest := pageRequest("qps-Plocm", "identity", "")
	identityResponse := httptest.NewRecorder()
	handler.ServeHTTP(identityResponse, identityRequest)
	if identityResponse.Code != http.StatusOK {
		t.Fatalf("identity page status = %d", identityResponse.Code)
	}
	identityETag := identityResponse.Header().Get("ETag")
	if identityETag == "" {
		t.Fatal("identity page has no prepared validator")
	}

	gzipRequest := pageRequest("qps-Plocm", "gzip", identityETag)
	gzipResponse := httptest.NewRecorder()
	handler.ServeHTTP(gzipResponse, gzipRequest)
	if gzipResponse.Code != http.StatusOK {
		t.Fatalf("gzip page with identity validator status = %d, want 200", gzipResponse.Code)
	}
	if got := gzipResponse.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("gzip page Content-Encoding = %q", got)
	}
	gzipETag := gzipResponse.Header().Get("ETag")
	if gzipETag == "" || gzipETag == identityETag {
		t.Fatalf("gzip ETag = %q, identity ETag = %q", gzipETag, identityETag)
	}
	zr, err := gzip.NewReader(gzipResponse.Body)
	if err != nil {
		t.Fatalf("open prepared page gzip: %v", err)
	}
	uncompressed, err := io.ReadAll(zr)
	if closeErr := zr.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		t.Fatalf("read prepared page gzip: %v", err)
	}
	if string(uncompressed) != identityResponse.Body.String() {
		t.Fatal("prepared identity and gzip pages contain different representations")
	}

	conditionalRequest := pageRequest("qps-Plocm", "gzip", gzipETag)
	conditionalResponse := httptest.NewRecorder()
	handler.ServeHTTP(conditionalResponse, conditionalRequest)
	if conditionalResponse.Code != http.StatusNotModified {
		t.Fatalf("matching gzip page validator status = %d, want 304", conditionalResponse.Code)
	}
	if got := conditionalResponse.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("gzip page 304 Content-Encoding = %q", got)
	}
	if got := conditionalResponse.Header().Get("Content-Language"); got != "qps-Plocm" {
		t.Fatalf("gzip page 304 Content-Language = %q", got)
	}
	vary := strings.Join(conditionalResponse.Header().Values("Vary"), ",")
	if !strings.Contains(vary, "Accept-Language") || !strings.Contains(vary, "Accept-Encoding") {
		t.Fatalf("gzip page 304 Vary = %q", vary)
	}
}

func TestConfigLockedPageHasOnePreparedContext(t *testing.T) {
	s := New(nil, Options{Language: "en-US", AllowPseudoLocale: true})
	if got := len(s.assets.pageContexts); got != 1 {
		t.Fatalf("config-locked page contexts = %d, want 1", got)
	}
	locked := s.negotiator().Resolve(pageRequest("qps-Plocm", "", ""))
	if locked.ResolvedTag != "en-US" || locked.Source != i18n.SourceConfig {
		t.Fatalf("config-locked context = %+v", locked)
	}
	if _, ok := s.assets.page("board.html", locked); !ok {
		t.Fatal("config-locked page representation was not prepared")
	}
}

func TestInvalidConfigLockStillHasOnePreparedFallbackContext(t *testing.T) {
	s := New(nil, Options{Language: "not_a_locale", AllowPseudoLocale: true})
	if got := len(s.assets.pageContexts); got != 1 {
		t.Fatalf("invalid config-lock page contexts = %d, want 1", got)
	}
	locked := s.negotiator().Resolve(pageRequest("qps-Plocm", "", ""))
	if locked.RequestedTag != "en-US" || locked.ResolvedTag != "en-US" || locked.Source != i18n.SourceConfig {
		t.Fatalf("invalid config-lock fallback context = %+v", locked)
	}
	if _, ok := s.assets.page("board.html", locked); !ok {
		t.Fatal("invalid config-lock fallback page representation was not prepared")
	}
}
