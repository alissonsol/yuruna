// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42c5a002-b58d-4ae8-9a8d-ef3e183db58e

package webui

import (
	"strings"
	"testing"
	"testing/fstest"
)

func TestAssetServesTheSharedRuntime(t *testing.T) {
	b, ct, ok := Asset("yuruna.core.js")
	if !ok {
		t.Fatal("yuruna.core.js is not embedded; every service UI loads it before its own scripts")
	}
	if ct != "text/javascript; charset=utf-8" {
		t.Errorf("Content-Type = %q, want text/javascript", ct)
	}
	if len(b) == 0 {
		t.Fatal("yuruna.core.js is empty")
	}
	for _, want := range []string{"Y.initMenu", "Y.api", "Y.el"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("yuruna.core.js does not define %s", want)
		}
	}
}

func TestAssetRefusesAPath(t *testing.T) {
	for _, name := range []string{"", "../go.mod", "sub/thing.js", "a\\b.js"} {
		if _, _, ok := Asset(name); ok {
			t.Errorf("Asset(%q) resolved; shared assets are a flat directory", name)
		}
	}
}

func TestNamesListsWhatIsShipped(t *testing.T) {
	names := Names()
	if len(names) == 0 {
		t.Fatal("Names() is empty")
	}
	found := false
	for _, n := range names {
		if n == "yuruna.core.js" {
			found = true
		}
	}
	if !found {
		t.Errorf("Names() = %v, missing yuruna.core.js", names)
	}
}

func TestAssetCatalogsReadsEveryNonDefaultLocaleFromItsAsset(t *testing.T) {
	fsys := fstest.MapFS{
		"web/assets/pt-BR.pool.js": {Data: []byte("pt-BR tables")},
		"web/assets/zh-CN.pool.js": {Data: []byte("zh-CN tables")},
		"web/assets/en-US.pool.js": {Data: []byte("never read")},
	}
	data := map[string]map[string]string{"en-US": {}, "pt-BR": {}, "zh-CN": {}}
	got, err := AssetCatalogs(fsys, "web/assets", "pool", data)
	if err != nil {
		t.Fatalf("AssetCatalogs: %v", err)
	}
	if len(got) != 2 || got["pt-BR"] != "pt-BR tables" || got["zh-CN"] != "zh-CN tables" {
		t.Fatalf("AssetCatalogs = %v, want the two non-default locales' asset bytes", got)
	}
	if _, ok := got["en-US"]; ok {
		t.Error("the default locale's tables travel in the runtime; AssetCatalogs returned a second copy")
	}
}

func TestAssetCatalogsRefusesADeliveredLocaleWithNoAsset(t *testing.T) {
	fsys := fstest.MapFS{"web/assets/pt-BR.stash.js": {Data: []byte("pt-BR tables")}}
	data := map[string]map[string]string{"en-US": {}, "pt-BR": {}, "he-IL": {}, "zh-CN": {}}
	got, err := AssetCatalogs(fsys, "web/assets", "stash", data)
	if err == nil || !strings.Contains(err.Error(), "he-IL, zh-CN") {
		t.Fatalf("AssetCatalogs error = %v, want both missing locales named in order", err)
	}
	if got["pt-BR"] != "pt-BR tables" {
		t.Errorf("AssetCatalogs dropped the locale it could read: %v", got)
	}
}
