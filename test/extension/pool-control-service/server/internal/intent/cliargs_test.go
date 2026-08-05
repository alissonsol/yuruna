// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package intent

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// scriptsDir is where the pool-admin CLIs live relative to this package.
const scriptsDir = "../../../../.."

// paramNameRE picks the parameter variables out of a PowerShell param() block.
var paramNameRE = regexp.MustCompile(`\$([A-Za-z_][A-Za-z0-9_]*)`)

// TestRunnerFlagsMatchScriptParameters cross-checks every -Flag this package
// emits against the param() block of the script it is passed to.
//
// The two sides are written in different languages and nothing links them: a
// flag renamed on the PowerShell side (or mistyped here) still compiles, still
// passes every test that fakes the Runner, and fails only when an operator
// triggers that one operation -- at which point pwsh rejects it at parameter
// bind time with "A parameter cannot be found that matches parameter name X".
// Parameters with the same meaning are deliberately NOT named identically
// across the CLIs (-State vs -DesiredState), so the mismatch is easy to
// reintroduce by analogy.
func TestRunnerFlagsMatchScriptParameters(t *testing.T) {
	if _, err := os.Stat(filepath.Join(scriptsDir, "Get-PoolIntent.ps1")); err != nil {
		t.Skipf("pool-admin CLIs not present next to this package: %v", err)
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "intent.go", nil, 0)
	if err != nil {
		t.Fatalf("parse intent.go: %v", err)
	}

	found := 0
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv == nil || fn.Body == nil {
			continue
		}
		script, flags := scriptAndFlags(fn)
		if script == "" {
			continue
		}
		found++
		params, err := scriptParameters(filepath.Join(scriptsDir, script))
		if err != nil {
			t.Errorf("%s: %v", fn.Name.Name, err)
			continue
		}
		for _, flag := range flags {
			// -IntentGitUrl is appended by exec, not by the method bodies, and
			// every CLI accepts it; the loop below still verifies it if seen.
			if !params[strings.ToLower(strings.TrimPrefix(flag, "-"))] {
				t.Errorf("%s passes %s to %s, which has no such parameter", fn.Name.Name, flag, script)
			}
		}
	}
	if found == 0 {
		t.Fatal("no Runner method invoking a pool-admin CLI was found; the AST walk no longer matches the code it guards")
	}
}

// scriptAndFlags returns the CLI a Runner method shells out to and every
// -Flag literal in its body. Flags are collected from the whole body, not just
// the exec call, because some methods assemble their argument slice first.
func scriptAndFlags(fn *ast.FuncDecl) (script string, flags []string) {
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		lit, ok := n.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			return true
		}
		s, err := strconv.Unquote(lit.Value)
		if err != nil {
			return true
		}
		switch {
		case strings.HasSuffix(s, ".ps1"):
			script = s
		case strings.HasPrefix(s, "-") && len(s) > 1:
			flags = append(flags, s)
		}
		return true
	})
	return script, flags
}

// scriptParameters returns the lowercased parameter names declared in a
// script's param() block. PowerShell binds parameters case-insensitively, so
// the comparison is too.
func scriptParameters(path string) (map[string]bool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, err := paramBlock(string(b))
	if err != nil {
		return nil, err
	}
	params := map[string]bool{}
	for _, m := range paramNameRE.FindAllStringSubmatch(block, -1) {
		params[strings.ToLower(m[1])] = true
	}
	if len(params) == 0 {
		return nil, constError("no parameters declared in " + path)
	}
	return params, nil
}

// paramBlock extracts the text between `param(` and its matching `)`.
func paramBlock(src string) (string, error) {
	i := strings.Index(src, "\nparam(")
	if i < 0 {
		return "", errNoParamBlock
	}
	start := i + len("\nparam(")
	depth := 1
	for j := start; j < len(src); j++ {
		switch src[j] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return src[start:j], nil
			}
		}
	}
	return "", errNoParamBlock
}

type constError string

func (e constError) Error() string { return string(e) }

const errNoParamBlock = constError("no param() block")
