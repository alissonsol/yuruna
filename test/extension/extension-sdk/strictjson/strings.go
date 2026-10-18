// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package strictjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// Refusal names the rejected structure without echoing request content.
type Refusal struct{ Detail, Field string }

func (r *Refusal) Error() string { return r.Detail }

// Strings reads exactly one object with known, unique string values. A normalizer
// folds duplicate identities without allowing alternate spellings of accepted fields.
func Strings(raw []byte, known map[string]bool, normalize func(string) string) (map[string]string, *Refusal) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	out := map[string]string{}
	seen := map[string]bool{}
	fail := func(detail, field string) (map[string]string, *Refusal) { return nil, &Refusal{detail, field} }
	tok, err := dec.Token()
	if err != nil || tok != json.Delim('{') {
		return fail("not_an_object", "")
	}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return fail("malformed_json", "")
		}
		name, _ := tok.(string)
		norm := name
		if normalize != nil {
			norm = normalize(name)
			if seen[norm] {
				return fail("duplicate_key", name)
			}
		}
		if !known[name] {
			return fail("unsupported_field", name)
		}
		if seen[norm] {
			return fail("duplicate_key", name)
		}
		seen[norm] = true
		val, err := dec.Token()
		if err != nil {
			return fail("malformed_json", name)
		}
		str, ok := val.(string)
		if !ok {
			return fail("value_not_a_string", name)
		}
		out[name] = str
	}
	if tok, err := dec.Token(); err != nil || tok != json.Delim('}') {
		return fail("malformed_json", "")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return fail("trailing_data", "")
	}
	return out, nil
}
