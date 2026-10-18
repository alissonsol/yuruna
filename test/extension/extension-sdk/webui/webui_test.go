// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package webui

import (
	"strings"
	"testing"
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
