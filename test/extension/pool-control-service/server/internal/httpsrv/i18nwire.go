// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"sync"

	"pool-control-service/internal/catalog"
	"yuruna.com/test/extension/extension-sdk/i18n"
)

// The catalog this binary carries. Only the domains this service renders are
// compiled in, and only the locales it can answer for -- a locale that is not
// here cannot be negotiated, because serving it would render every key as its
// own name.
//
// The data is copied into this module by tools/Invoke-CatalogEmbed.ps1 rather
// than imported, because Go cannot import across a module boundary this service
// does not own. The drift gate compares the copy against the compiler's output.
var (
	catalogOnce         sync.Once
	catalogInst         *i18n.Catalog
	catalogErr          error
	embeddedCatalogData = map[string]map[string]string{
		"en-US": {
			"pool":   catalog.DataenUSpool,
			"status": catalog.DataenUSstatus,
		},
		"qps-Ploc": {
			"pool":   catalog.DataqpsPlocpool,
			"status": catalog.DataqpsPlocstatus,
		},
		"qps-Plocm": {
			"pool":   catalog.DataqpsPlocmpool,
			"status": catalog.DataqpsPlocmstatus,
		},
	}
	embeddedLocaleTags = []string{"en-US", "qps-Ploc", "qps-Plocm"}
)

// embeddedCatalogs maps each locale to every domain this binary renders. The
// pseudo locales travel with the real one so a reference slice can be exercised
// in expanded and mirrored pseudo against the running service rather than
// against a fixture.
func embeddedCatalogs() map[string]map[string]string {
	return embeddedCatalogData
}

// messages is the process-wide catalog, decoded once. A handler that rendered
// a hundred labels would otherwise decode the same JSON a hundred times.
func messages() (*i18n.Catalog, error) {
	catalogOnce.Do(func() {
		c := i18n.NewCatalog(nil)
		for locale, domains := range embeddedCatalogs() {
			for domain, data := range domains {
				if err := c.Register(locale, domain, data); err != nil {
					catalogErr = err
					return
				}
			}
		}
		catalogInst = c
	})
	return catalogInst, catalogErr
}

// availableLocales is what negotiation may choose from: the intersection of
// what the manifest supports and what this binary actually carries.
func availableLocales() []string {
	return embeddedLocaleTags
}

// newServiceNegotiator narrows the generated manifest once at startup. The
// generic SDK can narrow arbitrary caller-provided sets, but this binary's set
// is compiled and immutable; rebuilding a map and slice on every asset or API
// request would turn locale resolution into avoidable hot-path allocation.
func newServiceNegotiator(configLanguage string, allowPseudo bool) *i18n.Negotiator {
	manifest := i18n.DefaultManifest()
	supported := make([]string, 0, len(availableLocales()))
	for _, locale := range availableLocales() {
		if locale == "qps-Ploc" || locale == "qps-Plocm" {
			if allowPseudo {
				supported = append(supported, locale)
			}
			continue
		}
		supported = append(supported, locale)
	}
	manifest.Supported = supported
	return &i18n.Negotiator{Manifest: manifest, ConfigLanguage: configLanguage}
}

// negotiator returns the startup-built resolver, so a page and the API
// responses it triggers share one immutable locale authority.
func (s *Server) negotiator() *i18n.Negotiator {
	return s.localeNegotiator
}

// Translate renders one catalog key in a request's resolved locale. A catalog
// that failed to decode falls back to the key rather than taking the response
// down: a page that cannot name a control is still a page an operator can read.
func Translate(locale i18n.Context, key string, args map[string]any) string {
	c, err := messages()
	if err != nil || c == nil {
		return key
	}
	return c.Render(key, args, locale.ResolvedTag)
}
