// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 427a9c99-8c33-4393-87a6-bb055fd97a6a

package strictjson

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestScalarsKeepsEachKindAndRefusesTheRest(t *testing.T) {
	known := map[string]bool{"scope": true, "drainSeconds": true}
	fold := func(s string) string { return strings.ToLower(strings.ReplaceAll(s, "_", "")) }
	got, refusal := Scalars([]byte(`{"scope":"full","drainSeconds":3600}`), known, fold)
	if refusal != nil {
		t.Fatal(refusal)
	}
	if got["scope"] != "full" {
		t.Fatalf("scope %#v", got["scope"])
	}
	if n, ok := got["drainSeconds"].(json.Number); !ok || n.String() != "3600" {
		t.Fatalf("drainSeconds %#v", got["drainSeconds"])
	}
	for body, want := range map[string]string{
		`[]`:                                    "not_an_object",
		`{"scope":true}`:                        "value_not_a_scalar",
		`{"scope":null}`:                        "value_not_a_scalar",
		`{"scope":{"a":1}}`:                     "value_not_a_scalar",
		`{"drain":"now"}`:                       "unsupported_field",
		`{"scope":"full","SCOPE":"restart"}`:    "duplicate_key",
		`{"drainSeconds":60,"drain_seconds":1}`: "duplicate_key",
		`{"scope":"full"} {}`:                   "trailing_data",
		`{"scope":"full"`:                       "malformed_json",
	} {
		_, refusal := Scalars([]byte(body), known, fold)
		if refusal == nil || refusal.Detail != want {
			t.Errorf("%s: got %v, want %s", body, refusal, want)
		}
	}
}
