// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4271c3a9-0b6e-4d2f-8a15-c94e7d3b2f80

package httpsrv

import (
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"pool-control-service/internal/configuration"
)

// Every value a route hands a pool-admin CLI reaches pwsh as its own argv
// entry, where one that starts with '-' binds as a parameter name. The guard
// the repository URLs had covers every such value, and a display name may
// still carry spaces.
func TestValuesBoundForACLIRefuseALeadingDash(t *testing.T) {
	for _, c := range []struct{ method, path, body string }{
		{"POST", "/api/pool", `{"poolId":"lab","displayName":"-Force"}`},
		{"POST", "/api/pool", `{"poolId":"-lab"}`},
		{"POST", "/api/pool", `{"poolId":"lab","configuredState":"paused -Force"}`},
		{"DELETE", "/api/pool?poolId=-Force", ""},
		{"POST", "/api/pool/configured-state", `{"poolId":"lab","configuredState":"-Force"}`},
		{"POST", "/api/pool/host", `{"poolId":"lab","hostId":"-MoveExisting"}`},
		{"DELETE", "/api/pool/host?poolId=lab&hostId=-Exclude", ""},
		{"POST", "/api/pool/move-host", `{"hostId":"-x","poolId":"lab"}`},
		{"POST", "/api/pool/repositories", `{"poolId":"-Clear","frameworkUrl":"","projectUrl":""}`},
	} {
		f := &fakeConfiguration{ret: configuration.Result{OK: true}}
		srv := newTestServer(f)
		resp, _ := do(t, c.method, srv.URL+c.path, c.body)
		srv.Close()
		if resp.StatusCode != http.StatusBadRequest || f.lastCall != "" {
			t.Errorf("%s %s %s = %d, CLI call %q; want 400 and no call", c.method, c.path, c.body, resp.StatusCode, f.lastCall)
		}
	}
	f := &fakeConfiguration{ret: configuration.Result{OK: true}}
	srv := newTestServer(f)
	defer srv.Close()
	if resp, _ := do(t, "POST", srv.URL+"/api/pool", `{"poolId":"lab","displayName":"Lab pool - west"}`); resp.StatusCode != http.StatusOK || f.lastCall != "NewPool" {
		t.Fatalf("a display name with spaces and an inner dash = %d, call %q; want it relayed", resp.StatusCode, f.lastCall)
	}
}

// The server sets no ReadTimeout, so a request body read anywhere but through
// the shared decoder's deadline lets a client that sent its headers hold a
// goroutine by trickling the rest.
func TestRequestBodiesAreReadUnderTheBodyDeadline(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		file, err := parser.ParseFile(fset, name, src, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(file, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "Body" {
				return true
			}
			if id, ok := sel.X.(*ast.Ident); ok && id.Name == "r" {
				t.Errorf("%s reads r.Body directly; use jsonbody.DecodeRequest or jsonbody.ReadRequest", fset.Position(sel.Pos()))
			}
			return true
		})
	}
}
