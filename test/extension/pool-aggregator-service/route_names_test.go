// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"os"
	"strings"
	"testing"
)

// crossLanguageRoute pins the routes this area serves to PowerShell callers.
// The same five literals live in default.psm1's Endpoints map, and
// Test.ExtensionArea.Tests.ps1 asserts that side against this same list.
//
// The two sides are wired independently -- Go registers a handler, PowerShell
// builds a URL -- so a rename on one side alone produces a 404 for a host that
// is asking exactly the right question, and nothing fails until some later
// cycle cannot find the service it needs. This test is the cheap half of the
// pair: it turns a silent rename into a red build on the side that renamed.
var crossLanguageRoute = map[string]string{
	"Health":         "/healthz",
	"Metrics":        "/metrics",
	"Status":         "/api/v1/pool-status",
	"ExtensionHosts": "/api/v1/extension-hosts",
	"LabToken":       "/api/v1/lab-token",
}

// TestCrossLanguageRouteNamesPinned fails when a route constant changes value.
// If it fails, change default.psm1's Endpoints map in the same commit -- the
// constant is not the contract, the pair is.
func TestCrossLanguageRouteNamesPinned(t *testing.T) {
	got := map[string]string{
		"Health":         routeHealth,
		"Metrics":        routeMetrics,
		"Status":         routePoolStatus,
		"ExtensionHosts": routeExtensionHosts,
		"LabToken":       routeLabToken,
	}
	if len(got) != len(crossLanguageRoute) {
		t.Fatalf("route vector has %d entries, constants cover %d", len(crossLanguageRoute), len(got))
	}
	for name, want := range crossLanguageRoute {
		if got[name] != want {
			t.Errorf("route %s is %q, the PowerShell client asks for %q", name, got[name], want)
		}
	}
}

// TestCrossLanguageRoutesAreRegisteredByConstant guards the other way a rename
// goes wrong: the constant is updated, the mux keeps a stale string literal,
// and the pinning test above still passes while the route moved. Reading the
// registration source is the only way to see that from here -- the mux is
// assembled inside main(), which a test cannot call.
func TestCrossLanguageRoutesAreRegisteredByConstant(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	body := string(src)
	for _, name := range []string{"routeHealth", "routeMetrics", "routePoolStatus", "routeExtensionHosts", "routeLabToken"} {
		if !strings.Contains(body, "mux.HandleFunc("+name+",") {
			t.Errorf("no mux registration uses %s; the constant and the served path can now differ", name)
		}
	}
	for _, literal := range crossLanguageRoute {
		if strings.Contains(body, `mux.HandleFunc("`+literal+`"`) {
			t.Errorf("mux still registers %q as a literal; register it through its constant", literal)
		}
	}
}
