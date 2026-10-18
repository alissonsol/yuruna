// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http/httptest"
	"testing"
)

var (
	staticCatalogSink map[string]map[string]string
	staticLocaleSink  []string
)

func TestEmbeddedLocaleAuthorityIsProcessStatic(t *testing.T) {
	if len(embeddedCatalogs()) != len(availableLocales()) {
		t.Fatalf("%d embedded locale maps but %d available locale tags",
			len(embeddedCatalogs()), len(availableLocales()))
	}
	for _, locale := range availableLocales() {
		if _, ok := embeddedCatalogs()[locale]; !ok {
			t.Errorf("available locale %q has no embedded catalog map", locale)
		}
	}

	allocations := testing.AllocsPerRun(100, func() {
		staticCatalogSink = embeddedCatalogs()
		staticLocaleSink = availableLocales()
	})
	if allocations != 0 {
		t.Fatalf("reading the immutable embedded locale authority allocates %.2f object(s) per call", allocations)
	}
}

func TestServerReusesItsStartupNegotiator(t *testing.T) {
	server := New(nil, Options{AllowPseudoLocale: true})
	first := server.negotiator()
	if first == nil || first != server.negotiator() {
		t.Fatal("the server rebuilt its locale negotiator instead of reusing startup state")
	}

	request := httptest.NewRequest("GET", "/", nil)
	request.Header.Set("Accept-Language", "qps-Plocm")
	if got := first.Resolve(request).ResolvedTag; got != "qps-Plocm" {
		t.Fatalf("startup negotiator resolved %q, want qps-Plocm", got)
	}

	production := New(nil, Options{}).negotiator()
	if got := production.Resolve(request).ResolvedTag; got != "en-US" {
		t.Fatalf("production negotiator exposed pseudo locale %q", got)
	}
}
