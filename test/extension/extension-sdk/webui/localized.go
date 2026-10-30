// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42507c16-6876-4469-b255-cf14c5bb0906

package webui

import (
	"fmt"
	"io/fs"
	"path"
	"sort"
	"strings"

	"yuruna.com/test/extension/extension-sdk/i18n"
)

// Pages shares catalog rendering without requiring self-contained services to
// embed the extension browser runtime or its unrelated assets.
type Pages = i18n.Pages

var NewPages = i18n.NewPages
var RenderHTML = i18n.RenderHTML

// AssetCatalogs returns the browser table of every non-default locale in data,
// read from the <locale>.<domain>.js assets a service embeds under dir. Those
// files are the one copy of each table the binary carries; the default
// locale's tables travel inside the runtime the pages already load. A
// delivered locale with no asset is an error: its pages would load no catalog.
func AssetCatalogs(fsys fs.FS, dir, domain string, data map[string]map[string]string) (map[string]string, error) {
	defaultTag := i18n.DefaultManifest().Default
	catalogs := make(map[string]string, len(data))
	var missing []string
	for tag := range data {
		if tag == defaultTag {
			continue
		}
		body, err := fs.ReadFile(fsys, path.Join(dir, tag+"."+domain+".js"))
		if err != nil {
			missing = append(missing, tag)
			continue
		}
		catalogs[tag] = string(body)
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return catalogs, fmt.Errorf("no %s browser catalog asset for %s", domain, strings.Join(missing, ", "))
	}
	return catalogs, nil
}
