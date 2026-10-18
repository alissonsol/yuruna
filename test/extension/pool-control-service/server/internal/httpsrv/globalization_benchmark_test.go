// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"os"
	"testing"
	"yuruna.com/test/extension/extension-sdk/i18n"
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
	catalog, err := messages()
	if err != nil {
		b.Fatal(err)
	}
	locale := globalizationBenchmarkLocale(b)
	if value := catalog.Render("pool.repo_no_access", nil, locale); value == "pool.repo_no_access" || len(catalog.MissingKeys()) != 0 {
		b.Fatal("benchmark requires the delivered locale catalog")
	}
	b.ReportAllocs()
	b.ResetTimer()
	for index := 0; index < b.N; index++ {
		if catalog.Render("pool.repo_no_access", nil, locale) == "" {
			b.Fatal("empty production message")
		}
	}
}

func BenchmarkGlobalizationAllocation(b *testing.B) {
	BenchmarkGlobalizationLookup(b)
}

func BenchmarkGlobalizationConcurrentRender(b *testing.B) {
	catalog, err := messages()
	if err != nil {
		b.Fatal(err)
	}
	locale := globalizationBenchmarkLocale(b)
	if value := catalog.Render("pool.repo_no_access", nil, locale); value == "pool.repo_no_access" || len(catalog.MissingKeys()) != 0 {
		b.Fatal("benchmark requires the delivered locale catalog")
	}
	locales := []string{"en-US", locale}
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		index := 0
		for pb.Next() {
			value := Translate(i18n.Context{ResolvedTag: locales[index%len(locales)]}, "pool.repo_no_access", nil)
			if value == "" || value == "pool.repo_no_access" {
				b.Error("unresolved production catalog")
				return
			}
			index++
		}
	})
}
