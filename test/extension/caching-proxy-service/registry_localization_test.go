// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
	"yuruna.com/test/extension/extension-sdk/i18n"
)

func TestRegistryFailuresLocalizeOwnedProseWithoutChangingState(t *testing.T) {
	for _, scenario := range []struct {
		name   string
		status int
		body   string
	}{{"HTTP refusal", 503, ""}, {"invalid catalog", 200, "not JSON"}} {
		t.Run(scenario.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(scenario.status)
				_, _ = w.Write([]byte(scenario.body))
			}))
			defer server.Close()
			reader := newRegistryReader(server.URL, "", "", time.Second)
			before := reader.state()
			after := reader.state(i18n.Context{ResolvedTag: "qps-Ploc"})
			if before.Reachable || after.Reachable || before.Repositories != after.Repositories {
				t.Fatal("display language changed registry state")
			}
			if before.Error == after.Error || strings.HasPrefix(after.Error, "cache.") {
				t.Fatalf("owned error was not catalog rendered: %q", after.Error)
			}
			if scenario.status == 503 && !strings.Contains(after.Error, "503 Service Unavailable") {
				t.Fatal("raw HTTP status changed")
			}
		})
	}
	reader := newRegistryReader("", "", "", time.Second)
	if reader.state().Error != "no registry URL configured" {
		t.Fatal("English compatibility changed")
	}
	if reader.state(i18n.Context{ResolvedTag: "qps-Ploc"}).Error == reader.state().Error {
		t.Fatal("unconfigured explanation remained English")
	}
}
