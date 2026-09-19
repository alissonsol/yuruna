// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The fixtures are read from the repository rather than copied here. A copy
// would be the second source of truth for a contract whose whole purpose is
// that three runtimes answer identically, and it would stop agreeing silently.
const fixtureRoot = "../../../../globalization/fixtures"

func readFixture(t *testing.T, name string, into any) {
	t.Helper()
	path := filepath.Join(fixtureRoot, name)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the shared fixture %s is unreadable: %v", path, err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("the shared fixture %s is not decodable: %v", path, err)
	}
}

type localeCorpus struct {
	Default         string            `json:"default"`
	Supported       []string          `json:"supported"`
	Aliases         map[string]string `json:"aliases"`
	MaxTagLength    int               `json:"maxTagLength"`
	MaxHeaderLength int               `json:"maxHeaderLength"`
	Cases           []struct {
		Name                 string `json:"name"`
		Why                  string `json:"why"`
		AcceptLanguage       string `json:"acceptLanguage"`
		ConfigLanguage       string `json:"configLanguage"`
		UserLanguage         string `json:"userLanguage"`
		ProcessCulture       string `json:"processCulture"`
		AcceptLanguageRepeat *struct {
			Unit  string `json:"unit"`
			Times int    `json:"times"`
		} `json:"acceptLanguageRepeat"`
		Expect struct {
			RequestedTag string `json:"requestedTag"`
			ResolvedTag  string `json:"resolvedTag"`
			Source       string `json:"source"`
		} `json:"expect"`
	} `json:"cases"`
}

// corpusManifest builds the world the corpus declares rather than the shipped
// one. The corpus has to exercise matching before a second locale is reviewed,
// and a matcher with one supported locale cannot demonstrate matching at all.
func (c *localeCorpus) manifest() *Manifest {
	data := map[string]LocaleData{}
	for _, tag := range c.Supported {
		if d, ok := generatedLocaleData[tag]; ok {
			data[tag] = d
			continue
		}
		data[tag] = LocaleData{Group: ",", Decimal: ".", GroupSize: 3, PluralRule: "one-if-1", Direction: "ltr"}
	}
	aliases := map[string]string{}
	for k, v := range c.Aliases {
		aliases[lowerASCII(k)] = v
	}
	return &Manifest{
		Default:         c.Default,
		Supported:       append([]string(nil), c.Supported...),
		Aliases:         aliases,
		Data:            data,
		MaxTagLength:    c.MaxTagLength,
		MaxHeaderLength: c.MaxHeaderLength,
	}
}

func lowerASCII(s string) string {
	b := []byte(s)
	for i := range b {
		if 'A' <= b[i] && b[i] <= 'Z' {
			b[i] += 'a' - 'A'
		}
	}
	return string(b)
}

func TestSharedLocaleCorpus(t *testing.T) {
	var corpus localeCorpus
	readFixture(t, "locale-matching.json", &corpus)
	if len(corpus.Cases) < 20 {
		t.Fatalf("the corpus has only %d cases, so it is not the shared contract", len(corpus.Cases))
	}
	m := corpus.manifest()

	for _, tc := range corpus.Cases {
		header := tc.AcceptLanguage
		if tc.AcceptLanguageRepeat != nil {
			header = ""
			for i := 0; i < tc.AcceptLanguageRepeat.Times; i++ {
				header += tc.AcceptLanguageRepeat.Unit
			}
		}
		// Process culture is always pinned, empty when the case does not name
		// one: an unset culture would make the answer depend on the machine.
		got := NewContextWithUser(tc.ConfigLanguage, tc.UserLanguage, header, tc.ProcessCulture, m)
		if got.ResolvedTag != tc.Expect.ResolvedTag {
			t.Errorf("%s: resolved %q, the corpus says %q -- %s",
				tc.Name, got.ResolvedTag, tc.Expect.ResolvedTag, tc.Why)
		}
		if string(got.Source) != tc.Expect.Source {
			t.Errorf("%s: source %q, the corpus says %q", tc.Name, got.Source, tc.Expect.Source)
		}
		if tc.Expect.RequestedTag != "" && got.RequestedTag != tc.Expect.RequestedTag {
			t.Errorf("%s: requested %q, the corpus says %q", tc.Name, got.RequestedTag, tc.Expect.RequestedTag)
		}
	}
}

// The corpus may run ahead of what ships -- it has to, or it could not exercise
// matching -- but it must not test a locale the project has never declared, or
// it would prove behavior for a tag no manifest will ever produce.
func TestCorpusAgreesWithTheShippedManifest(t *testing.T) {
	var corpus localeCorpus
	readFixture(t, "locale-matching.json", &corpus)
	for _, tag := range corpus.Supported {
		if _, ok := generatedLocaleData[tag]; !ok {
			t.Errorf("the corpus tests %q, which locale-manifest.json does not declare", tag)
		}
	}
	if corpus.Default != generatedDefault {
		t.Errorf("the corpus default is %q, the manifest says %q", corpus.Default, generatedDefault)
	}
}

type formatCorpus struct {
	Cases []struct {
		Name   string `json:"name"`
		Why    string `json:"why"`
		Type   string `json:"type"`
		Value  any    `json:"value"`
		Locale string `json:"locale"`
		Expect string `json:"expect"`
	} `json:"cases"`
}

// The agreement that matters: a count rendered by a lab command lands in a
// transcript, the same count rendered here lands in a page, and a reader
// comparing them cannot tell a formatting difference from a real one.
func TestSharedFormatCorpus(t *testing.T) {
	var corpus formatCorpus
	readFixture(t, "format-agreement.json", &corpus)
	if len(corpus.Cases) < 10 {
		t.Fatalf("the format corpus has only %d cases", len(corpus.Cases))
	}
	m := DefaultManifest()
	// Formatting is defined for every locale the manifest describes, not only
	// the ones a reader may select; pt-BR has data long before it is servable.
	for _, tc := range corpus.Cases {
		got := FormatArgument(tc.Value, tc.Type, tc.Locale, m)
		if got != tc.Expect {
			t.Errorf("%s: wrote %q, the contract says %q -- %s", tc.Name, got, tc.Expect, tc.Why)
		}
	}
}

func TestPortugueseCardinalCorpus(t *testing.T) {
	var corpus struct {
		Locale string `json:"locale"`
		Rule   string `json:"rule"`
		Cases  []struct {
			Count    float64 `json:"count"`
			Category string  `json:"category"`
		} `json:"cases"`
	}
	readFixture(t, "pt-BR-plurals.json", &corpus)
	m := DefaultManifest()
	for _, row := range corpus.Cases {
		actual, err := PluralCategory(row.Count, corpus.Locale, m)
		if err != nil || actual != row.Category {
			t.Errorf("count %v: got %q (%v), want %q", row.Count, actual, err, row.Category)
		}
	}
}
