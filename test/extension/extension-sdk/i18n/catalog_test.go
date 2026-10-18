// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A compiled table in the shape the catalog compiler emits: a literal, a
// message with a typed argument, a plural, and an external value.
const testStatusEN = `{
  "status.cycle_paused": "Paused, waiting for resume.",
  "status.cycle_duration": ["Duration: ", {"arg":"elapsed","type":"duration","trust":"internal"}],
  "status.host_online_count": {"kind":"plural","selector":"count","variants":{
     "one": [{"arg":"count","type":"integer","trust":"internal"}, " host online."],
     "other": [{"arg":"count","type":"integer","trust":"internal"}, " hosts online."]}},
  "status.external_detail": ["The tool reported: ", {"arg":"detail","type":"detail","trust":"external"}]
}`

const testStatusPseudo = `{
  "status.cycle_paused": "[!!! Paused, waiting for resume. !!!]"
}`

func newTestCatalog(t *testing.T) *Catalog {
	t.Helper()
	c := NewCatalog(nil)
	if err := c.Register("en-US", "status", testStatusEN); err != nil {
		t.Fatalf("registering en-US: %v", err)
	}
	if err := c.Register("qps-Ploc", "status", testStatusPseudo); err != nil {
		t.Fatalf("registering qps-Ploc: %v", err)
	}
	return c
}

func TestRenderWalksTheCompiledShape(t *testing.T) {
	c := newTestCatalog(t)
	cases := []struct {
		name string
		key  string
		args map[string]any
		want string
	}{
		{"a literal", "status.cycle_paused", nil, "Paused, waiting for resume."},
		{"a typed argument", "status.cycle_duration", map[string]any{"elapsed": 5400}, "Duration: 1h 30m"},
		{"one takes the singular", "status.host_online_count", map[string]any{"count": 1}, "1 host online."},
		{"four takes the plural", "status.host_online_count", map[string]any{"count": 4}, "4 hosts online."},
		{"zero is plural in English", "status.host_online_count", map[string]any{"count": 0}, "0 hosts online."},
		{"an argument is grouped", "status.host_online_count", map[string]any{"count": 1234567}, "1,234,567 hosts online."},
		{"external text is placed as given", "status.external_detail", map[string]any{"detail": "Connection refused"},
			"The tool reported: Connection refused"},
	}
	for _, tc := range cases {
		if got := c.Render(tc.key, tc.args, "en-US"); got != tc.want {
			t.Errorf("%s: got %q want %q", tc.name, got, tc.want)
		}
	}
}

// A key the requested locale lacks falls back to the default's text rather than
// rendering blank -- a partially translated catalog must still produce a
// readable page -- and the gap is recorded once so it can be found.
func TestAMissingKeyFallsBackAndIsRecordedOnce(t *testing.T) {
	c := newTestCatalog(t)
	got := c.Render("status.cycle_duration", map[string]any{"elapsed": 90}, "qps-Ploc")
	if got != "Duration: 1m 30s" {
		t.Errorf("a key missing from the requested locale should fall back to the default text, got %q", got)
	}
	for i := 0; i < 50; i++ {
		c.Render("status.cycle_duration", map[string]any{"elapsed": 90}, "qps-Ploc")
	}
	missing := c.MissingKeys()
	if len(missing) != 1 {
		t.Fatalf("50 renders of one missing key recorded %d diagnostics: %v", len(missing), missing)
	}
	if !strings.Contains(missing[0], "qps-Ploc") || !strings.Contains(missing[0], "status.cycle_duration") {
		t.Errorf("the diagnostic does not name the locale and key: %q", missing[0])
	}
}

// A key no catalog carries surfaces as itself. Blank text would hide the
// mistake in the one place someone would notice it.
func TestAnUnknownKeyRendersAsItself(t *testing.T) {
	c := newTestCatalog(t)
	if got := c.Render("status.no_such_key", nil, "en-US"); got != "status.no_such_key" {
		t.Errorf("got %q, want the key itself", got)
	}
}

// The requested locale answers when it has the key, so a pseudo-locale run
// actually shows pseudo text rather than quietly rendering English.
func TestTheRequestedLocaleWins(t *testing.T) {
	c := newTestCatalog(t)
	got := c.Render("status.cycle_paused", nil, "qps-Ploc")
	if got != "[!!! Paused, waiting for resume. !!!]" {
		t.Errorf("the pseudo locale did not answer for a key it carries: %q", got)
	}
}

func TestNegotiationReadsTheHeader(t *testing.T) {
	n := &Negotiator{}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept-Language", "de-DE;q=0.9, en-US;q=1.0")
	got := n.Resolve(req)
	if got.ResolvedTag != "en-US" || got.Source != SourceHTTP {
		t.Errorf("got %q from %q, want en-US from http", got.ResolvedTag, got.Source)
	}
}

// The operator's lab-wide lock outranks the browser, and an unsupported lock is
// refused rather than obeyed -- a typo must not serve a catalog that does not
// exist.
func TestTheConfigLockOutranksTheHeader(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept-Language", "pt-BR")

	locked := (&Negotiator{ConfigLanguage: "en-US"}).Resolve(req)
	if locked.ResolvedTag != "en-US" || locked.Source != SourceConfig {
		t.Errorf("a config lock should win: got %q from %q", locked.ResolvedTag, locked.Source)
	}
	auto := (&Negotiator{ConfigLanguage: "auto"}).Resolve(req)
	if auto.Source == SourceConfig {
		t.Error("'auto' is not a lock and must behave as though nothing were configured")
	}
	typo := (&Negotiator{ConfigLanguage: "de-DE"}).Resolve(req)
	if typo.ResolvedTag != "en-US" || typo.Source != SourceConfig {
		t.Errorf("an unsupported lock should fall back but still name config: got %q from %q",
			typo.ResolvedTag, typo.Source)
	}
}

// A locale the manifest supports but this binary did not embed cannot be
// served: answering with it would render every key as itself.
func TestNegotiationIsLimitedToWhatTheBinaryCarries(t *testing.T) {
	n := &Negotiator{Available: []string{}}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept-Language", "en-US")
	if got := n.Resolve(req); got.ResolvedTag != generatedDefault {
		t.Errorf("got %q, want the default when nothing is embedded", got.ResolvedTag)
	}
}

// The middleware decides the language; the handler decides whether the language
// is part of what it is sending. A handler that calls Apply gets the headers
// that keep a shared cache from handing one client another client's language.
func TestANegotiatedResponseVariesOnTheHeader(t *testing.T) {
	handler := (&Negotiator{}).Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		locale := FromRequest(r)
		if locale.ResolvedTag == "" {
			t.Error("the handler received no locale, so the middleware did not record one")
		}
		Apply(w.Header(), locale)
		w.WriteHeader(http.StatusOK)
	}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept-Language", "en-US")
	handler.ServeHTTP(rec, req)

	if got := rec.Header().Get("Content-Language"); got != "en-US" {
		t.Errorf("Content-Language = %q, want en-US", got)
	}
	vary := strings.Join(rec.Header().Values("Vary"), ", ")
	if !strings.Contains(strings.ToLower(vary), "accept-language") {
		t.Errorf("Vary = %q, want it to include Accept-Language", vary)
	}
}

// Applying twice must not accumulate duplicates: a handler that sets its own
// Vary and then hands the response to the middleware would otherwise emit the
// field twice, and some caches take a malformed Vary as "do not store".
func TestVaryIsNotDuplicated(t *testing.T) {
	h := http.Header{}
	h.Add("Vary", "Accept-Encoding")
	Apply(h, Context{ResolvedTag: "en-US"})
	Apply(h, Context{ResolvedTag: "en-US"})
	joined := strings.ToLower(strings.Join(h.Values("Vary"), ","))
	if strings.Count(joined, "accept-language") != 1 {
		t.Errorf("Vary = %q, want exactly one Accept-Language", h.Values("Vary"))
	}
	if !strings.Contains(joined, "accept-encoding") {
		t.Errorf("Vary = %q, want the caller's own field kept", h.Values("Vary"))
	}
}

// A plural rule that was never pinned must not silently borrow English's.
func TestAnUnpinnedPluralRuleIsRefused(t *testing.T) {
	m := DefaultManifest()
	m.Data["xx-XX"] = LocaleData{Group: ",", Decimal: ".", GroupSize: 3, Direction: "ltr"}
	if _, err := PluralCategory(0, "xx-XX", m); err == nil {
		t.Error("a locale with no pinned rule should be refused, not guessed")
	}
	if got, err := PluralCategory(1, "en-US", m); err != nil || got != "one" {
		t.Errorf("en-US count 1 = %q (%v), want one", got, err)
	}
	if got, err := PluralCategory(0, "en-US", m); err != nil || got != "other" {
		t.Errorf("en-US count 0 = %q (%v), want other -- English zero is plural", got, err)
	}
}

// A handler that sends the same bytes in every language must be able to stay
// out of negotiation entirely, or every static file splits the cache.
func TestTheMiddlewareLabelsNothingByItself(t *testing.T) {
	handler := (&Negotiator{}).Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/asset.js", nil)
	req.Header.Set("Accept-Language", "en-US")
	handler.ServeHTTP(rec, req)

	if got := rec.Header().Get("Content-Language"); got != "" {
		t.Errorf("the middleware labeled a response the handler never called negotiated: %q", got)
	}
	if vary := strings.ToLower(strings.Join(rec.Header().Values("Vary"), ",")); strings.Contains(vary, "accept-language") {
		t.Errorf("the middleware made an unnegotiated response vary on the language: %q", rec.Header().Values("Vary"))
	}
}

// The context has to carry the same fields the PowerShell side carries, or a
// message rendered by a service and one rendered by a lab command cannot be
// traced to the same catalog set.
func TestContextCarriesEverythingARenderNeeds(t *testing.T) {
	ctx := (&Negotiator{}).Resolve(httptest.NewRequest(http.MethodGet, "/", nil))

	if ctx.ResolvedTag == "" {
		t.Error("the context resolved no language")
	}
	if ctx.TimeZone != "utc" {
		t.Errorf("TimeZone = %q, want utc -- timestamps are written in one fixed shape in every locale", ctx.TimeZone)
	}
	if ctx.CatalogVersion == "" {
		t.Error("the context names no catalog version, so a render cannot be traced to the compiler that produced it")
	}
	if len(ctx.CatalogHash) != 64 {
		t.Errorf("CatalogHash = %q (%d chars), want a 64-character hash naming the compiled set",
			ctx.CatalogHash, len(ctx.CatalogHash))
	}
}

// Passed by value: a handler that edits its copy must not be able to change
// what any other part of the same request sees.
func TestContextIsCopiedNotShared(t *testing.T) {
	original := (&Negotiator{}).Resolve(httptest.NewRequest(http.MethodGet, "/", nil))
	mutated := original
	mutated.ResolvedTag = "xx-XX"
	mutated.CatalogHash = ""

	if original.ResolvedTag == "xx-XX" {
		t.Error("editing a copy changed the original; two halves of one render could disagree")
	}
	if original.CatalogHash == "" {
		t.Error("editing a copy cleared the original's provenance")
	}
}

// A route can be mounted without the negotiating middleware -- a second mux, a
// test harness, a service that adopts the adapter before it adopts the
// middleware. The context such a handler reads has to be the whole default, not
// the fields a struct literal happened to fill: pageVariantFor and the response
// headers key on RequestedTag and Source as well as the resolved tag, and a
// half-populated context misses the prepared representation entirely.
func TestFromRequestWithoutMiddlewareCarriesTheWholeDefault(t *testing.T) {
	want := NewContext("", "", "", DefaultManifest())
	got := FromRequest(httptest.NewRequest(http.MethodGet, "/", nil))

	if got != want {
		t.Errorf("FromRequest without middleware = %+v, want the negotiated default %+v", got, want)
	}
	if got.RequestedTag == "" {
		t.Error("the fallback names no requested tag, so a prepared page keyed on it cannot be found")
	}
	if got.TimeZone != "utc" {
		t.Errorf("TimeZone = %q, want utc", got.TimeZone)
	}
	if got.CatalogVersion == "" {
		t.Error("the fallback names no catalog version, so its render cannot be traced to a compiler")
	}
	if len(got.CatalogHash) != 64 {
		t.Errorf("CatalogHash = %q (%d chars), want a 64-character hash", got.CatalogHash, len(got.CatalogHash))
	}
	if got.Source != SourceDefault {
		t.Errorf("Source = %q, want %q -- nothing chose this language", got.Source, SourceDefault)
	}
}

// The direction has to be derived from the manifest entry for the language that
// was resolved, not written as a literal. The shipped manifest is left to right,
// so asserting "ltr" against it would pass for either implementation; the only
// way to tell them apart is a manifest whose default is right to left.
//
// The subject is the constructor rather than FromRequest because the fallback
// cannot be handed a manifest -- it is the shipped world by definition. What
// makes this cover the fallback is the assertion next door that the fallback
// equals what this constructor returns.
func TestTheDefaultDirectionIsDerivedNotAssumed(t *testing.T) {
	rtl := &Manifest{
		Default:         "ar-SA",
		Supported:       []string{"ar-SA"},
		Aliases:         map[string]string{},
		Data:            map[string]LocaleData{"ar-SA": {Direction: "rtl", PluralRule: "other"}},
		MaxTagLength:    generatedMaxTagLength,
		MaxHeaderLength: generatedMaxHeaderLength,
	}

	if got := NewContext("", "", "", rtl); got.Direction != "rtl" {
		t.Errorf("Direction = %q, want rtl from the manifest entry for %q", got.Direction, rtl.Default)
	}
}

// A nil request is the same question with less to read, and it must not panic:
// callers reach this from background work that has no request at all.
func TestFromRequestWithoutARequestCarriesTheWholeDefault(t *testing.T) {
	if got, want := FromRequest(nil), NewContext("", "", "", DefaultManifest()); got != want {
		t.Errorf("FromRequest(nil) = %+v, want the negotiated default %+v", got, want)
	}
}

// Without middleware there is no decision to report, so the header must not
// become one. Reading Accept-Language here would make the same request answer
// differently depending on which mux served it, which is the disagreement the
// single negotiation point exists to prevent.
//
// The header names a supported alias on purpose. An unsupported tag resolves to
// the default anyway, so a test using one would pass against a FromRequest that
// negotiated fully -- it would be asserting that pt-BR is unsupported, not that
// nothing negotiated. "en" resolves, and it resolves to a context that differs
// from the default in both the requested tag and the source.
func TestTheFallbackDoesNotNegotiateFromTheHeader(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Accept-Language", "en")

	negotiated := (&Negotiator{}).Resolve(req)
	if negotiated == NewContext("", "", "", DefaultManifest()) {
		t.Fatal("the header does not change what negotiation produces, so this test cannot detect one")
	}
	if got, want := FromRequest(req), NewContext("", "", "", DefaultManifest()); got != want {
		t.Errorf("FromRequest with a header but no middleware = %+v, want the untouched default %+v", got, want)
	}
}
