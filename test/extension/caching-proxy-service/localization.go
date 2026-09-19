// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"flag"
	"sync"
	"yuruna.com/test/extension/caching-proxy-service/internal/catalog"
	"yuruna.com/test/extension/extension-sdk/i18n"
)

var pageLanguage = flag.String("language", "auto", "Display language: auto or a supported locale")
var pageAllowPseudo = flag.Bool("allow-pseudo-locale", false, "Enable diagnostic pseudo locales")
var localizedPageOnce sync.Once
var localizedPageStore *i18n.Pages

func localizedPages() *i18n.Pages {
	localizedPageOnce.Do(func() {
		pages, err := i18n.NewPages(catalog.Catalogs, catalog.BrowserCatalogs, catalog.BrowserKernel, *pageLanguage, *pageAllowPseudo)
		if err != nil {
			panic("invalid embedded browser catalog: " + err.Error())
		}
		pages.Prepare("index.html", []byte(indexPage), true)
		localizedPageStore = pages
	})
	return localizedPageStore
}
