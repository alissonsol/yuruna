// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"pool-control-service/internal/intent"
	"strings"
	"testing"
)

func TestDiagnosticRequestLocalizesOwnedHintsAndPreservesRawProbe(t *testing.T) {
	raw := "external command output: not catalog-owned"
	s := New(&fakeIntent{stateRes: intent.Result{OK: false, Error: raw, Stdout: raw, Stderr: raw}}, Options{Version: "fixture", PwshPath: filepath.Join(t.TempDir(), "missing-pwsh"), AllowPseudoLocale: true})
	english := s.collectDiagnostics(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/api/diagnostics", nil)
	req.Header.Set("Accept-Language", "qps-Ploc")
	recorder := httptest.NewRecorder()
	s.Handler().ServeHTTP(recorder, req)
	var localized Diagnostics
	if err := json.Unmarshal(recorder.Body.Bytes(), &localized); err != nil {
		t.Fatal(err)
	}
	if recorder.Header().Get("Content-Language") != "qps-Ploc" || localized.OK != english.OK {
		t.Fatal("locale negotiation changed diagnostic outcome")
	}
	if localized.IntentProbe.Stdout != raw || localized.IntentProbe.Stderr != raw {
		t.Fatal("raw probe streams were translated")
	}
	for _, name := range []string{"pwsh", "repo-dir", "state-dir", "intent-git-url", "intent-read"} {
		before, after := checkByName(t, english, name), checkByName(t, localized, name)
		if before.OK != after.OK || before.Name != after.Name {
			t.Fatalf("machine identity changed: %s", name)
		}
		if before.Hint != "" && (before.Hint == after.Hint || strings.HasPrefix(after.Hint, "pool.")) {
			t.Fatalf("hint did not use compiled pseudo catalog: %s: %s", name, after.Hint)
		}
	}
	if checkByName(t, localized, "intent-read").Detail != raw {
		t.Fatal("external command detail was translated")
	}
}
