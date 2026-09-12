// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"context"
	"net/http"
	"sync"
)

type contextKey struct{}

var (
	defaultContextOnce  sync.Once
	defaultContextValue Context
)

// defaultContext is what a request carries when nothing negotiated for it. It is
// built through the same constructor a negotiated request goes through, given no
// input to decide on, so the two agree field for field -- including the direction
// the manifest declares for the default language, the time policy, and the
// catalog version and hash a render is traced by. A hand-written struct literal
// here would agree only on the fields someone thought to fill in, and a handler
// mounted without the middleware would then answer with provenance the rest of
// the service does not have. It is resolved once because the manifest allocates:
// an unmounted handler must not pay for it per request.
func defaultContext() Context {
	defaultContextOnce.Do(func() {
		defaultContextValue = NewContext("", "", "", DefaultManifest())
	})
	return defaultContextValue
}

// FromRequest is the locale decision carried on a request, or the default when
// no middleware ran. Handlers read this rather than re-negotiating: a page and
// the API responses it triggers must not disagree about the reader's language.
//
// The no-middleware answer is a complete default context, never a partial one.
// It is also deliberately not a negotiation: a request that reached a handler
// with no middleware has had no locale decided for it, and reading its header
// here would make the answer depend on which of two mounts a route went through.
func FromRequest(r *http.Request) Context {
	if r != nil {
		if ctx, ok := r.Context().Value(contextKey{}).(Context); ok {
			return ctx
		}
	}
	return defaultContext()
}

// Negotiator resolves a locale per request and records what it decided.
type Negotiator struct {
	Manifest *Manifest
	// ConfigLanguage is the operator's lab-wide lock. Empty or "auto" means no
	// lock, and a browser then decides for itself.
	ConfigLanguage string
	// Available restricts negotiation to the locales this binary actually
	// embedded. A manifest-supported locale whose table was not compiled in
	// cannot be served, and answering with it would render every key as itself.
	Available []string
	// AllowPseudo opens the pseudo locales to negotiation. It is off in a
	// release build and must stay off: a pseudo locale exists to make a
	// translation problem visible to someone looking for it, and a reader who
	// received one would read the page as broken rather than as translated.
	// A reference slice turns it on so expanded and mirrored text can be
	// exercised against the running service instead of against a fixture.
	AllowPseudo bool
}

// PseudoLocales is the set that exists only for testing.
func PseudoLocales() []string { return append([]string(nil), generatedPseudo...) }

func (n *Negotiator) manifest() *Manifest {
	if n != nil && n.Manifest != nil {
		return n.Manifest
	}
	return DefaultManifest()
}

// negotiationManifest narrows the supported set to what this binary carries.
func (n *Negotiator) negotiationManifest() *Manifest {
	base := n.manifest()
	if n == nil || len(n.Available) == 0 {
		return base
	}
	have := map[string]bool{}
	for _, a := range n.Available {
		have[a] = true
	}
	candidates := base.Supported
	if n.AllowPseudo {
		candidates = append(append([]string(nil), candidates...), generatedPseudo...)
	}
	supported := make([]string, 0, len(candidates))
	for _, s := range candidates {
		if have[s] {
			supported = append(supported, s)
		}
	}
	narrowed := *base
	narrowed.Supported = supported
	return &narrowed
}

// Resolve decides one request's locale without writing anything.
func (n *Negotiator) Resolve(r *http.Request) Context {
	header := ""
	if r != nil {
		header = r.Header.Get("Accept-Language")
	}
	return NewContext(n.ConfigLanguage, header, "", n.negotiationManifest())
}

// Middleware resolves the locale once and records it on the request. It writes
// no headers.
//
// Only the handler knows whether the thing it is about to send is negotiated.
// A script or a stylesheet is the same bytes in every language, and labeling it
// Content-Language -- or claiming it varies on Accept-Language -- would split
// every cache entry on a header that changes nothing about the response. So the
// middleware decides the language and the handler decides whether the language
// is part of what it is sending.
func (n *Negotiator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		locale := n.Resolve(r)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), contextKey{}, locale)))
	})
}

// Apply writes the locale headers for a negotiated representation.
//
// Vary: Accept-Language is what keeps a shared cache from handing one client
// another client's language. It is set even while only one locale is served,
// because the representation IS negotiated -- a cache that stored an unvaried
// copy today would keep serving it the day a second locale ships, and the bug
// would appear at the moment the feature did.
//
// It is exported so a 304 can repeat these: a conditional response that dropped
// Content-Language would let a cache re-label a body it already holds.
func Apply(h http.Header, locale Context) {
	if locale.ResolvedTag == "" {
		return
	}
	h.Set("Content-Language", locale.ResolvedTag)
	addVary(h, "Accept-Language")
}

func addVary(h http.Header, field string) {
	for _, existing := range h.Values("Vary") {
		if existing == "*" {
			return
		}
		for _, part := range splitAndTrim(existing) {
			if equalFoldASCII(part, field) {
				return
			}
		}
	}
	h.Add("Vary", field)
}

func splitAndTrim(s string) []string {
	out := []string{}
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ',' {
			part := trimSpaceASCII(s[start:i])
			if part != "" {
				out = append(out, part)
			}
			start = i + 1
		}
	}
	return out
}

func trimSpaceASCII(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

func equalFoldASCII(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if 'A' <= ca && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if 'A' <= cb && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}
