// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func constantCatalogString(expression ast.Expr) (string, bool) {
	switch value := expression.(type) {
	case *ast.BasicLit:
		if value.Kind != token.STRING {
			return "", false
		}
		text, err := strconv.Unquote(value.Value)
		return text, err == nil
	case *ast.BinaryExpr:
		if value.Op != token.ADD {
			return "", false
		}
		left, leftOK := constantCatalogString(value.X)
		right, rightOK := constantCatalogString(value.Y)
		return left + right, leftOK && rightOK
	case *ast.ParenExpr:
		return constantCatalogString(value.X)
	}
	return "", false
}

// Read the compiler's actual Go constant with the Go parser. A second JSON
// fixture would let a stale or omitted production catalog pass these checks.
func compiledProductionCatalog(t *testing.T, locale, domain string) string {
	t.Helper()
	name := strings.ReplaceAll(locale, "-", "") + "_" + domain + ".go"
	file, err := parser.ParseFile(token.NewFileSet(), filepath.Join(fixtureRoot, "../generated/go/catalog", name), nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, decl := range file.Decls {
		group, ok := decl.(*ast.GenDecl)
		if !ok || group.Tok != token.CONST {
			continue
		}
		for _, spec := range group.Specs {
			value := spec.(*ast.ValueSpec)
			if len(value.Values) == 1 {
				if text, ok := constantCatalogString(value.Values[0]); ok {
					return text
				}
			}
		}
	}
	t.Fatalf("%s/%s has no compiled string constant", locale, domain)
	return ""
}

func TestEveryEnabledProductionCatalogRendersWithoutFallback(t *testing.T) {
	var manifest struct {
		Locales map[string]struct{ Status string }
	}
	bytes, err := os.ReadFile(filepath.Join(fixtureRoot, "../locale-manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(bytes, &manifest); err != nil {
		t.Fatal(err)
	}
	files, err := filepath.Glob(filepath.Join(fixtureRoot, "../catalogs/en-US/*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("catalog source discovery: %v", err)
	}
	c := NewCatalog(nil)
	rows := 0
	for locale, metadata := range manifest.Locales {
		if metadata.Status != "supported" && metadata.Status != "pseudo" {
			continue
		}
		for _, file := range files {
			var source struct {
				Domain   string
				Messages map[string]struct {
					Lifecycle    string
					Placeholders map[string]struct {
						Type    string
						Example any
					}
					Plural *struct{ Selector string }
					Select *struct {
						Selector string
						Variants map[string]any
					}
				}
			}
			raw, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(raw, &source); err != nil {
				t.Fatal(err)
			}
			compiled := compiledProductionCatalog(t, locale, source.Domain)
			if err := c.Register(locale, source.Domain, compiled); err != nil {
				t.Fatal(err)
			}
			var table map[string]any
			if err := json.Unmarshal([]byte(compiled), &table); err != nil {
				t.Fatal(err)
			}
			for key, message := range source.Messages {
				if message.Lifecycle != "active" {
					continue
				}
				if _, ok := table[key]; !ok {
					t.Fatalf("%s/%s missing production key %s", locale, source.Domain, key)
				}
				args := map[string]any{}
				for name, placeholder := range message.Placeholders {
					args[name] = placeholder.Example
					if args[name] == nil || args[name] == "" {
						switch placeholder.Type {
						case "integer", "duration":
							args[name] = float64(2)
						case "datetime":
							args[name] = "2026-09-18T12:00:00Z"
						default:
							args[name] = "fixture café 日本語"
						}
					}
				}
				render := func() {
					if text := c.Render(key, args, locale); text == key || text == "" {
						t.Fatalf("%s/%s returned no rendered text", locale, key)
					}
					rows++
				}
				render()
				if message.Plural != nil {
					for _, count := range []float64{0, 1, 2, 1000000} {
						args[message.Plural.Selector] = count
						render()
					}
				}
				if message.Select != nil {
					for selector := range message.Select.Variants {
						args[message.Select.Selector] = selector
						render()
					}
				}
			}
		}
	}
	if rows == 0 {
		t.Fatal("no production locale rows ran")
	}
	if missing := c.MissingKeys(); len(missing) != 0 {
		t.Fatalf("production renders used fallback: %v", missing)
	}
	t.Logf("rendered %d production locale/message/selector rows", rows)
}
