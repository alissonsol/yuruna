// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http"
	"stash-service/internal/catalog"
	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/webui"
)

func prepareLocalizedPages(language string, allowPseudo bool) *webui.Pages {
	pages, err := webui.NewPages(catalog.Catalogs, catalog.BrowserCatalogs, catalog.BrowserKernel, language, allowPseudo)
	if err != nil {
		panic("invalid embedded browser catalog: " + err.Error())
	}
	for _, name := range []string{"index.html", "new.html", "stash.html"} {
		body, err := webFS.ReadFile("web/" + name)
		if err != nil {
			panic("missing embedded page: " + name)
		}
		pages.Prepare(name, body, false)
	}
	return pages
}

// writeLocalizedError keeps the existing error/reason contract and adds a stable
// code so new clients can consume state independently of the selected language.
func (s *Server) writeLocalizedError(w http.ResponseWriter, r *http.Request, status int, code, reason string, args map[string]any) {
	locale := s.pages.Negotiator.Resolve(r)
	i18n.Apply(w.Header(), locale)
	body := map[string]any{"ok": false, "code": code, "error": s.pages.Catalog.Render(code, args, locale.ResolvedTag)}
	if reason != "" {
		body["reason"] = reason
	}
	writeJSON(w, status, body)
}

func (s *Server) writeLocalizedHTTPError(w http.ResponseWriter, r *http.Request, code string, status int) {
	locale := s.pages.Negotiator.Resolve(r)
	i18n.Apply(w.Header(), locale)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Yuruna-Message-Code", code)
	http.Error(w, s.pages.Catalog.Render(code, nil, locale.ResolvedTag), status)
}
