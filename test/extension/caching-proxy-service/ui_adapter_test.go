// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import "testing"

// This page is a string literal and loads no shared runtime, so the adapter
// every other page inherits has to travel inside it. Without one the page
// renders its shell and fills in nothing whenever the request behind it never
// answers -- an empty table that reads as a lab with no data rather than as a
// page that failed.
func TestTheServedPageInstallsTheRequestAdapter(t *testing.T) {
	if requestAdapterScript == "" {
		t.Fatal("the generated request adapter is empty; run tools/Invoke-CatalogEmbed.ps1")
	}
	if !contains(indexPage, requestAdapterScript) {
		t.Error("the served page does not carry the request adapter")
	}
	// Before the page's own script, not after: an adapter installed afterwards
	// is installed after the call it was meant to serve.
	adapterAt := index(indexPage, requestAdapterScript)
	bodyAt := index(indexPage, "<body")
	if adapterAt < 0 || bodyAt < 0 || adapterAt > bodyAt {
		t.Errorf("the adapter is at %d and the body starts at %d; it must be installed in the head", adapterAt, bodyAt)
	}
	if !contains(requestAdapterScript, "window.yurunaRequest = function") {
		t.Error("the bounded helper is not defined unconditionally")
	}
	// The page's own request must be bounded. A bare fetch on a page that
	// refreshes on a timer leaves a stale table with nothing to say it is
	// stale, and a request nothing ever gives up on never reports a failure
	// the page could show instead.
	if !contains(requestAdapterScript, "window.yurunaRequest") {
		t.Error("the adapter offers no bounded request for the page to use")
	}
	if !contains(indexPage, "yurunaRequest(") {
		t.Error("the page still issues an unbounded request")
	}
	if contains(indexPage, "fetch('/") {
		t.Error("the page calls fetch directly instead of the bounded helper")
	}
}

func contains(haystack, needle string) bool { return index(haystack, needle) >= 0 }

func index(haystack, needle string) int {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return -1
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
