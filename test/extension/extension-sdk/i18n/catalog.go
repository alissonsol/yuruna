// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
)

// Catalog holds the compiled messages for a set of locales and domains.
//
// The compiler already broke every message into the pieces a renderer walks: a
// message with no arguments is a plain string, one with arguments is an
// alternating list of literal text and argument descriptors, and one that
// varies by count carries its variants beside the argument that selects them.
// Nothing here parses a message grammar, which is what keeps a render cheap
// enough to sit in a per-row loop.
//
// Decoding happens once, at Register. A handler that renders a hundred labels
// decodes nothing.
type Catalog struct {
	mu       sync.RWMutex
	byLocale map[string]map[string]map[string]any
	manifest *Manifest
	// missing records one diagnostic per locale and key. A key absent from a
	// table would otherwise log once per row, burying the first report in its
	// own repetitions.
	missing map[string]bool
}

// NewCatalog returns an empty catalog resolving against a manifest.
func NewCatalog(m *Manifest) *Catalog {
	if m == nil {
		m = DefaultManifest()
	}
	return &Catalog{
		byLocale: map[string]map[string]map[string]any{},
		manifest: m,
		missing:  map[string]bool{},
	}
}

// Manifest is the world this catalog resolves locales in.
func (c *Catalog) Manifest() *Manifest { return c.manifest }

// Register decodes one compiled domain for one locale.
//
// The data is the compiler's own output, copied into this module rather than
// imported across a module boundary the service does not own.
func (c *Catalog) Register(locale, domain, compiled string) error {
	var table map[string]any
	if err := json.Unmarshal([]byte(compiled), &table); err != nil {
		return fmt.Errorf("catalog %s/%s is not decodable: %w", locale, domain, err)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.byLocale[locale] == nil {
		c.byLocale[locale] = map[string]map[string]any{}
	}
	c.byLocale[locale][domain] = table
	return nil
}

// Locales lists the locales this catalog can answer in, which is not the same
// as the locales the manifest supports: a binary embeds only what it renders.
func (c *Catalog) Locales() []string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make([]string, 0, len(c.byLocale))
	for l := range c.byLocale {
		out = append(out, l)
	}
	return out
}

func (c *Catalog) lookup(locale, key string) (any, bool) {
	domain, _, _ := strings.Cut(key, ".")
	c.mu.RLock()
	defer c.mu.RUnlock()
	if byDomain, ok := c.byLocale[locale]; ok {
		if table, ok := byDomain[domain]; ok {
			if entry, ok := table[key]; ok {
				return entry, true
			}
		}
	}
	return nil, false
}

func (c *Catalog) reportMissing(what string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.missing[what] = true
}

// MissingKeys is every (locale, key) this catalog was asked for and did not
// have, each recorded once. A test asserts it is empty; a running service uses
// it to report a gap without logging per render.
func (c *Catalog) MissingKeys() []string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make([]string, 0, len(c.missing))
	for k := range c.missing {
		out = append(out, k)
	}
	return out
}

// Render is the message for a key in a locale, with its arguments placed.
//
// A key nothing declares comes back as itself. A supported catalog is complete
// by definition and the compiler fails on a gap, so reaching that fallback
// means a caller asked for something no catalog carries; showing the key keeps
// the surface readable and puts the mistake where someone will see it, which
// blank text would not.
func (c *Catalog) Render(key string, args map[string]any, locale string) string {
	use := locale
	entry, ok := c.lookup(use, key)
	if !ok && use != c.manifest.Default {
		c.reportMissing(use + "|" + key)
		use = c.manifest.Default
		entry, ok = c.lookup(use, key)
	}
	if !ok {
		c.reportMissing(use + "|" + key)
		return key
	}
	return c.renderEntry(entry, key, args, use)
}

func (c *Catalog) renderEntry(entry any, key string, args map[string]any, locale string) string {
	switch e := entry.(type) {
	case string:
		return e
	case []any:
		return c.renderSegments(e, args, locale)
	case map[string]any:
		kind, _ := e["kind"].(string)
		if kind == "" {
			return key
		}
		selector, _ := e["selector"].(string)
		variants, _ := e["variants"].(map[string]any)
		if variants == nil {
			return key
		}
		var chosen any
		if kind == "plural" {
			count := 0.0
			if raw, ok := args[selector]; ok {
				if n, ok := toFloat(raw); ok {
					count = n
				}
			}
			category, err := PluralCategory(count, locale, c.manifest)
			if err != nil {
				// A supported locale always has a pinned rule, so reaching here
				// means a binary embedded a locale the manifest never blessed.
				// Falling back beats aborting a response mid-render.
				c.reportMissing(locale + "|" + key + "|plural-rule")
				category = "other"
			}
			chosen = variants[category]
		} else {
			value := ""
			if raw, ok := args[selector]; ok {
				value = fmt.Sprint(raw)
			}
			chosen = variants[value]
		}
		if chosen == nil {
			chosen = variants["other"]
		}
		if chosen == nil {
			return key
		}
		return c.renderEntry(chosen, key, args, locale)
	}
	return key
}

func (c *Catalog) renderSegments(segments []any, args map[string]any, locale string) string {
	var b strings.Builder
	for _, piece := range segments {
		switch p := piece.(type) {
		case string:
			b.WriteString(p)
		case map[string]any:
			name, _ := p["arg"].(string)
			argType, _ := p["type"].(string)
			b.WriteString(FormatArgument(args[name], argType, locale, c.manifest))
		default:
			b.WriteString(fmt.Sprint(piece))
		}
	}
	return b.String()
}
