// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package labgate

import (
	"context"
	"net/http"
	"sync"

	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/internal/catalog"
)

var authOnce sync.Once
var authMessages *i18n.Catalog

type authLocaleKey struct{}

func authCatalog() *i18n.Catalog {
	authOnce.Do(func() {
		authMessages = i18n.NewCatalog(nil)
		for tag, domains := range catalog.Catalogs {
			for domain, data := range domains {
				if err := authMessages.Register(tag, domain, data); err != nil {
					panic(err)
				}
			}
		}
	})
	return authMessages
}

func newAuthNegotiator(language string, allowPseudo bool) *i18n.Negotiator {
	return &i18n.Negotiator{Manifest: i18n.DefaultManifest(), Available: authCatalog().Locales(), ConfigLanguage: language, AllowPseudo: allowPseudo}
}

func (g *Gate) renderDetail(ctx context.Context, key string, args map[string]any) string {
	tag, _ := ctx.Value(authLocaleKey{}).(string)
	if tag == "" {
		tag = "en-US"
	}
	return authCatalog().Render(key, args, tag)
}

func (g *Gate) refuse(w http.ResponseWriter, r *http.Request, status int, key, reason string, args map[string]any) {
	locale := g.locale.Resolve(r)
	i18n.Apply(w.Header(), locale)
	text := authCatalog().Render(key, args, locale.ResolvedTag)
	if reason != "" {
		writeReason(w, status, reason, text)
		return
	}
	writeJSON(w, status, map[string]any{"ok": false, "error": text, "code": key})
}
