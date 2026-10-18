// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package labgate

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEveryDeliveredAuthorizationLocalePreservesRefusalIdentity(t *testing.T) {
	for _, locale := range authCatalog().Locales() {
		for _, configured := range []bool{false, true} {
			opts := Options{AllowPseudoLocale: true}
			if configured {
				opts.AggregatorURL = "https://unused.example"
			}
			gate := New(opts)
			r := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader("malformed"))
			r.Header.Set("Accept-Language", locale)
			w := httptest.NewRecorder()
			gate.HandleLogin(w, r)
			var payload map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			if w.Header().Get("Content-Language") != locale || w.Header().Get("Cache-Control") != "no-store" || payload["ok"] != false {
				t.Fatalf("%s refusal changed headers/identity: %v %v", locale, w.Header(), payload)
			}
			key := "auth.login_unavailable"
			if configured {
				key = "auth.malformed_request"
				if w.Code != 400 || payload["code"] != key {
					t.Fatalf("bad body lost code: %v", payload)
				}
			} else {
				if w.Code != 503 || payload["reason"] != ReasonUnavailable || payload["message"].(map[string]any)["code"] != CodeUnavailable {
					t.Fatalf("unavailable lost legacy/canonical identity: %v", payload)
				}
			}
			if payload["error"] != authCatalog().Render(key, nil, locale) {
				t.Fatalf("%s refusal did not use the selected catalog: %v", locale, payload)
			}
		}
	}
	if missing := authCatalog().MissingKeys(); len(missing) != 0 {
		t.Fatalf("authorization used fallback: %v", missing)
	}
}

func TestAuthorizationLocaleLockAndPseudoDefault(t *testing.T) {
	for _, options := range []Options{{}, {Language: "en-US", AllowPseudoLocale: true}} {
		gate := New(options)
		r := httptest.NewRequest(http.MethodPost, "/api/login", nil)
		r.Header.Set("Accept-Language", "qps-Plocm")
		w := httptest.NewRecorder()
		gate.HandleLogin(w, r)
		if w.Header().Get("Content-Language") != "en-US" {
			t.Fatalf("pseudo escaped the service language policy: %v", w.Header())
		}
		if !strings.Contains(w.Body.String(), "no aggregator URL is configured, so the pool aggregator cannot check a lab token; actions stay locked") {
			t.Fatal("default English authorization wording changed")
		}
	}
}
