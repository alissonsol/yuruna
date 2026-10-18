// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func globalizationBenchmarkLocale(b *testing.B) string {
	b.Helper()
	locale := os.Getenv("YURUNA_BENCHMARK_LOCALE")
	if locale == "" {
		locale = "en-US"
	}
	if locale != "en-US" && locale != "pt-BR" {
		b.Fatal("unsupported benchmark locale")
	}
	return locale
}

func BenchmarkGlobalizationLookup(b *testing.B) {
	pages := prepareLocalizedPages("auto", false)
	catalog := pages.Catalog
	locale := globalizationBenchmarkLocale(b)
	if value := catalog.Render("download.diagnostics_yuruna_download_agent", nil, locale); value == "download.diagnostics_yuruna_download_agent" || len(catalog.MissingKeys()) != 0 {
		b.Fatal("benchmark requires the delivered locale catalog")
	}
	b.ReportAllocs()
	b.ResetTimer()
	for index := 0; index < b.N; index++ {
		if catalog.Render("download.diagnostics_yuruna_download_agent", nil, locale) == "" {
			b.Fatal("empty production message")
		}
	}
}

func BenchmarkGlobalizationAllocation(b *testing.B) {
	BenchmarkGlobalizationLookup(b)
}

func BenchmarkGlobalizationConcurrentRender(b *testing.B) {
	pages := prepareLocalizedPages("auto", false)
	catalog := pages.Catalog
	locale := globalizationBenchmarkLocale(b)
	if value := catalog.Render("download.diagnostics_yuruna_download_agent", nil, locale); value == "download.diagnostics_yuruna_download_agent" || len(catalog.MissingKeys()) != 0 {
		b.Fatal("benchmark requires the delivered locale catalog")
	}
	locales := []string{"en-US", locale}
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		index := 0
		for pb.Next() {
			request := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/", nil)
			request.Header.Set("Accept-Language", locales[index%len(locales)])
			response := httptest.NewRecorder()
			if !pages.Serve(response, request, "index.html") || response.Body.Len() == 0 || response.Header().Get("Content-Language") != locales[index%len(locales)] {
				b.Error("wrong production locale response")
				return
			}
			index++
		}
	})
}
