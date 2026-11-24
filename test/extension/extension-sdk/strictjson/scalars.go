// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4265c765-1b2b-4190-8b2b-9b1812ddc21f

package strictjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// Scalars reads exactly one object with known, unique keys whose values are
// strings or numbers, with the rules of Strings. A string arrives as a string
// and a number as its json.Number text, so the caller decides which kind each
// key takes and a number is never rounded through a float on the way.
func Scalars(raw []byte, known map[string]bool, normalize func(string) string) (map[string]any, *Refusal) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	out := map[string]any{}
	seen := map[string]bool{}
	fail := func(detail, field string) (map[string]any, *Refusal) { return nil, &Refusal{detail, field} }
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
		switch v := val.(type) {
		case string, json.Number:
			out[name] = v
		default:
			return fail("value_not_a_scalar", name)
		}
	}
	if tok, err := dec.Token(); err != nil || tok != json.Delim('}') {
		return fail("malformed_json", "")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return fail("trailing_data", "")
	}
	return out, nil
}
