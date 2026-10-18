// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package i18n decides which language a reader gets, and renders the compiled
// catalog in it.
//
// Three runtimes make this decision -- PowerShell for the lab commands, this
// package for the Go services, and a compiled kernel in the browser -- and they
// have to make it identically. A page in one language beside a transcript in
// another is worse than either language alone, and nothing in either surface
// tells the reader which one is wrong. So the rules live in a fixture under
// globalization/fixtures that every runtime runs, not in three implementations
// written from the same paragraph.
//
// Nothing here reads Go's own locale database. Separators and plural rules
// come from the compiled locale data, because ICU data differs between engines
// and a runtime's locale database shifts between releases.
package i18n

import (
	"sort"
	"strings"
)

// LocaleData is what one locale needs in order to be written: how its numbers
// are punctuated, which plural rule it takes, and which way it reads.
type LocaleData struct {
	Group     string
	Decimal   string
	GroupSize int
	// PluralRule is empty for a locale whose rule has not been pinned. Callers
	// must refuse such a locale rather than borrow another's: English and
	// Portuguese disagree about zero, and a borrowed rule reads as fluent,
	// confident, wrong grammar to anyone who does not speak the language.
	PluralRule string
	Direction  string
}

// Manifest is the world a resolution happens in. It is a parameter rather than
// a package global so the shared fixture can declare its own supported set --
// the corpus has to exercise matching before a second locale ships, and a
// matcher with one supported locale cannot demonstrate matching at all.
type Manifest struct {
	Default         string
	Supported       []string
	Aliases         map[string]string
	Data            map[string]LocaleData
	MaxTagLength    int
	MaxHeaderLength int
}

// Source names what decided a locale, so a surprising language can be traced
// to the input that chose it rather than guessed at.
type Source string

const (
	SourceDefault Source = "default"
	SourceConfig  Source = "config"
	SourceUser    Source = "user"
	SourceHTTP    Source = "http"
	SourceProcess Source = "process"
)

// Context is the decision, made once at a boundary and handed down. Everything
// downstream is given this rather than asking again, so a page, its API
// responses and the transcript of the same request cannot disagree.
//
// Passed by value, so a handler that changes its copy changes nothing for
// anyone else. That is the Go equivalent of the read-only dictionary the
// PowerShell side returns, and it exists for the same reason: two halves of
// one render must not be able to disagree about the reader's language.
type Context struct {
	RequestedTag string
	ResolvedTag  string
	Direction    string
	Source       Source
	// TimeZone is the policy a timestamp is written under. Timestamps are
	// written in one fixed UTC shape in every locale, so a value read off a
	// page and pasted into a transcript search is the string the transcript
	// holds. Carried rather than assumed, so a surface that needs the reader's
	// own zone has to say so and can be found.
	TimeZone string
	// CatalogVersion and CatalogHash name the compiled set this decision was
	// made against. A rendered message and the artifacts that produced it can
	// otherwise be correlated only by timestamp, which is no correlation at all
	// once a lab is running two versions at once.
	CatalogVersion string
	CatalogHash    string
}

func boundedTagLength(m *Manifest) int {
	if m != nil && m.MaxTagLength > 0 {
		return m.MaxTagLength
	}
	return 35
}

func isTagShape(s string) bool {
	parts := strings.Split(s, "-")
	if len(parts) == 0 {
		return false
	}
	lang := parts[0]
	if len(lang) < 2 || len(lang) > 3 {
		return false
	}
	for _, r := range lang {
		if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') {
			return false
		}
	}
	for _, p := range parts[1:] {
		if len(p) < 2 || len(p) > 8 {
			return false
		}
		for _, r := range p {
			if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') {
				return false
			}
		}
	}
	return true
}

// CanonicalTag is a tag in the one spelling everything else compares against,
// or "" when it is not a tag at all.
//
// Underscores become hyphens because process cultures and hand-edited config
// arrive POSIX-style. Anything outside letters, digits and hyphens within the
// length bound is refused rather than repaired: this value goes on to select a
// file, and a repaired path separator is still a path separator.
func CanonicalTag(tag string, maxLength int) string {
	t := strings.ReplaceAll(strings.TrimSpace(tag), "_", "-")
	if t == "" {
		return ""
	}
	if maxLength <= 0 {
		maxLength = 35
	}
	if len(t) > maxLength {
		return ""
	}
	if !isTagShape(t) {
		return ""
	}
	parts := strings.Split(t, "-")
	out := strings.ToLower(parts[0])
	for _, p := range parts[1:] {
		switch len(p) {
		case 2:
			out += "-" + strings.ToUpper(p)
		case 4:
			out += "-" + strings.ToUpper(p[:1]) + strings.ToLower(p[1:])
		default:
			out += "-" + strings.ToLower(p)
		}
	}
	return out
}

// ResolveSupported is the supported tag one requested tag selects, or "".
//
// Exact match first, then an alias the manifest declares. There is deliberately
// no prefix fallback: pt-AO is not pt-BR, and inventing that relationship ships
// a reader a dialect nobody reviewed, with no way to tell until the wording is
// wrong.
func ResolveSupported(tag string, m *Manifest) string {
	if m == nil {
		return ""
	}
	canonical := CanonicalTag(tag, boundedTagLength(m))
	if canonical == "" {
		return ""
	}
	for _, s := range m.Supported {
		if strings.EqualFold(s, canonical) {
			return s
		}
	}
	if alias, ok := m.Aliases[strings.ToLower(canonical)]; ok {
		for _, s := range m.Supported {
			if strings.EqualFold(s, alias) {
				return s
			}
		}
	}
	return ""
}

// Weights decide, not document order. A q of zero removes its tag rather than
// ranking it last, so a client that explicitly refused a language is never
// served it as a last resort. A bare wildcard expresses no preference and
// selects nothing here -- answering it with anything but the caller's default
// would make the served language depend on the order of a table.
type localeDecision struct {
	requested string
	resolved  string
	weight    float64
}

// parseQuality accepts exactly the HTTP qvalue grammar: zero with up to three
// decimal digits, or one followed only by up to three zeroes. General-purpose
// float parsing would also admit NaN, exponents and out-of-range values, none
// of which is a preference a server may rank.
func parseQuality(raw string) (float64, bool) {
	s := strings.TrimSpace(raw)
	if len(s) == 0 || (s[0] != '0' && s[0] != '1') {
		return 0, false
	}
	value := float64(s[0] - '0')
	if len(s) == 1 {
		return value, true
	}
	if s[1] != '.' || len(s) > 5 {
		return 0, false
	}
	place := 0.1
	for i := 2; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' || (s[0] == '1' && s[i] != '0') {
			return 0, false
		}
		value += float64(s[i]-'0') * place
		place /= 10
	}
	return value, true
}

func selectFromHeader(header string, m *Manifest) localeDecision {
	if m == nil {
		return localeDecision{}
	}
	h := strings.TrimSpace(header)
	if h == "" {
		return localeDecision{}
	}
	maxHeader := m.MaxHeaderLength
	if maxHeader <= 0 {
		maxHeader = 512
	}
	// Bounded before parsing. A megabyte of tags is not a preference; it is a
	// way to spend the server's time.
	if len(h) > maxHeader {
		return localeDecision{}
	}

	best := map[string]localeDecision{}
	for _, part := range strings.Split(h, ",") {
		piece := strings.TrimSpace(part)
		if piece == "" {
			continue
		}
		bits := strings.Split(piece, ";")
		tag := strings.TrimSpace(bits[0])
		if tag == "" {
			continue
		}
		q := 1.0
		validQ := true
		seenQ := false
		for _, raw := range bits[1:] {
			param := strings.TrimSpace(raw)
			eq := strings.Index(param, "=")
			if eq < 0 {
				if strings.EqualFold(param, "q") {
					validQ = false
					break
				}
				continue
			}
			if !strings.EqualFold(strings.TrimSpace(param[:eq]), "q") {
				continue
			}
			if seenQ {
				validQ = false
				break
			}
			seenQ = true
			// A header is attacker-reachable, so a malformed q must not abort
			// the parse. parseQuality reads only the ASCII HTTP grammar, which
			// keeps a host that writes decimals with a comma from reading q=0.5
			// as 5.
			parsed, ok := parseQuality(param[eq+1:])
			if !ok {
				validQ = false
				break
			}
			q = parsed
		}
		if !validQ || q <= 0 || tag == "*" {
			continue
		}
		resolved := ResolveSupported(tag, m)
		if resolved == "" {
			continue
		}
		candidate := localeDecision{
			requested: CanonicalTag(tag, boundedTagLength(m)),
			resolved:  resolved,
			weight:    q,
		}
		if existing, ok := best[resolved]; !ok || existing.weight < q ||
			(existing.weight == q && candidate.requested < existing.requested) {
			best[resolved] = candidate
		}
	}
	if len(best) == 0 {
		return localeDecision{}
	}
	candidates := make([]localeDecision, 0, len(best))
	for _, candidate := range best {
		candidates = append(candidates, candidate)
	}
	// Weight descending, then tag ascending. The tie-break exists so the answer
	// does not depend on map iteration order, which Go deliberately randomizes.
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].weight != candidates[j].weight {
			return candidates[i].weight > candidates[j].weight
		}
		if candidates[i].resolved != candidates[j].resolved {
			return candidates[i].resolved < candidates[j].resolved
		}
		return candidates[i].requested < candidates[j].requested
	})
	return candidates[0]
}

// SelectFromHeader is the supported tag an Accept-Language header asks for, or
// "" when it asks for nothing this manifest can answer. The request boundary
// uses the internal decision form as well, so it can retain the canonical tag
// that selected an alias rather than falsely reporting the resolved tag twice.
func SelectFromHeader(header string, m *Manifest) string {
	return selectFromHeader(header, m).resolved
}

// NewContext resolves the language for one boundary: a request, or a command.
//
// Precedence is config, then the request header, then the process culture,
// then the default. A configured lock is the operator's decision for the whole
// lab and a browser cannot override it -- and an unsupported lock is refused
// rather than obeyed, because a typo must not serve a catalog that does not
// exist. The refusal still reports config as the source, so the operator can
// see that their setting was the thing that was read.
func NewContext(configLanguage, acceptLanguage, processCulture string, m *Manifest) Context {
	return NewContextWithUser(configLanguage, "", acceptLanguage, processCulture, m)
}

// NewContextWithUser resolves the same boundary with an explicit persisted
// web preference. The preference is considered only while configuration is
// absent or "auto"; a lab-wide lock always wins. NewContext remains the
// compatibility entry point for callers that have no user preference yet.
func NewContextWithUser(configLanguage, userLanguage, acceptLanguage, processCulture string, m *Manifest) Context {
	if m == nil {
		m = DefaultManifest()
	}
	ctx := Context{Source: SourceDefault}

	cfg := strings.TrimSpace(configLanguage)
	if cfg != "" && !strings.EqualFold(cfg, "auto") {
		ctx.RequestedTag = CanonicalTag(cfg, boundedTagLength(m))
		ctx.Source = SourceConfig
		ctx.ResolvedTag = ResolveSupported(cfg, m)
	}

	if ctx.ResolvedTag == "" && ctx.Source != SourceConfig {
		if fromUser := ResolveSupported(userLanguage, m); fromUser != "" {
			ctx.RequestedTag = CanonicalTag(userLanguage, boundedTagLength(m))
			ctx.ResolvedTag = fromUser
			ctx.Source = SourceUser
		}
	}

	if ctx.ResolvedTag == "" && ctx.Source != SourceConfig {
		if fromHeader := selectFromHeader(acceptLanguage, m); fromHeader.resolved != "" {
			ctx.RequestedTag = fromHeader.requested
			ctx.ResolvedTag = fromHeader.resolved
			ctx.Source = SourceHTTP
		}
	}

	if ctx.ResolvedTag == "" && ctx.Source != SourceConfig {
		if fromProcess := ResolveSupported(processCulture, m); fromProcess != "" {
			ctx.RequestedTag = CanonicalTag(processCulture, boundedTagLength(m))
			ctx.ResolvedTag = fromProcess
			ctx.Source = SourceProcess
		}
	}

	if ctx.ResolvedTag == "" {
		ctx.ResolvedTag = m.Default
		if ctx.RequestedTag == "" {
			ctx.RequestedTag = m.Default
		}
	}

	ctx.Direction = "ltr"
	if data, ok := m.Data[ctx.ResolvedTag]; ok && data.Direction != "" {
		ctx.Direction = data.Direction
	}
	ctx.TimeZone = "utc"
	ctx.CatalogVersion = generatedCatalogVersion
	ctx.CatalogHash = generatedCatalogHash
	return ctx
}
