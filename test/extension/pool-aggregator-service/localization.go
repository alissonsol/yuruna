// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"flag"
	"net/http"
	"os"
	"strings"
	"sync"
	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/pool-aggregator-service/internal/catalog"
)

var pageLanguage = flag.String("language", "auto", "")
var pageAllowPseudo = flag.Bool("allow-pseudo-locale", false, "")
var localizedPageOnce sync.Once
var localizedPageStore *i18n.Pages

func localizedPages() *i18n.Pages {
	localizedPageOnce.Do(func() {
		pages, err := i18n.NewPages(catalog.Catalogs, catalog.BrowserCatalogs, catalog.BrowserKernel, *pageLanguage, *pageAllowPseudo)
		if err != nil {
			panic("invalid embedded browser catalog: " + err.Error())
		}
		localizedPageStore = pages
	})
	return localizedPageStore
}

func localizedHTTPError(w http.ResponseWriter, r *http.Request, key string, status int) {
	localizedHTTPErrorArgs(w, r, key, status, nil)
}

func localizedHTTPErrorArgs(w http.ResponseWriter, r *http.Request, key string, status int, args map[string]any) {
	pages := localizedPages()
	locale := pages.Negotiator.Resolve(r)
	i18n.Apply(w.Header(), locale)
	w.Header().Set("X-Yuruna-Message-Code", key)
	w.Header().Set("Cache-Control", "no-store")
	http.Error(w, pages.Catalog.Render(key, args, locale.ResolvedTag), status)
}

func localizedJSONError(w http.ResponseWriter, r *http.Request, key string, status int) {
	pages := localizedPages()
	locale := pages.Negotiator.Resolve(r)
	i18n.Apply(w.Header(), locale)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"code": key, "error": pages.Catalog.Render(key, nil, locale.ResolvedTag)})
}

var operatorCatalogOnce sync.Once
var operatorCatalog *i18n.Catalog

// Flag help is constructed before flag.Parse, so read only the two language
// switches early. Their normal flag handlers still validate the command line.
func operatorLanguage() (string, bool) {
	language := os.Getenv("YURUNA_LANGUAGE")
	if language == "" {
		language = "auto"
	}
	pseudo := false
	for index := 1; index < len(os.Args); index++ {
		arg := os.Args[index]
		if arg == "--" {
			break
		}
		arg = strings.TrimLeft(arg, "-")
		if arg == "language" && index+1 < len(os.Args) {
			index++
			language = os.Args[index]
		}
		if strings.HasPrefix(arg, "language=") {
			language = strings.TrimPrefix(arg, "language=")
		}
		if arg == "allow-pseudo-locale" || arg == "allow-pseudo-locale=true" {
			pseudo = true
		}
		if arg == "allow-pseudo-locale=false" {
			pseudo = false
		}
	}
	if flag.Parsed() {
		language = *pageLanguage
		pseudo = *pageAllowPseudo
	}
	return language, pseudo
}

func operatorMessage(key string, args map[string]any) string {
	operatorCatalogOnce.Do(func() {
		operatorCatalog = i18n.NewCatalog(nil)
		for tag, domains := range catalog.Catalogs {
			for domain, source := range domains {
				if err := operatorCatalog.Register(tag, domain, source); err != nil {
					panic(err)
				}
			}
		}
	})
	language, pseudo := operatorLanguage()
	manifest := i18n.DefaultManifest()
	if pseudo {
		for tag := range catalog.Catalogs {
			if strings.HasPrefix(tag, "qps-") {
				manifest.Supported = append(manifest.Supported, tag)
			}
		}
	}
	culture := os.Getenv("LC_ALL")
	if culture == "" {
		culture = os.Getenv("LC_MESSAGES")
	}
	if culture == "" {
		culture = os.Getenv("LANG")
	}
	if index := strings.IndexAny(culture, ".@"); index >= 0 {
		culture = culture[:index]
	}
	locale := i18n.NewContext(language, "", culture, manifest)
	return operatorCatalog.Render(key, args, locale.ResolvedTag)
}
