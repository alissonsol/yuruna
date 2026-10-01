// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.

// Package jsonbody validates bounded, single-document JSON request bodies.
package jsonbody

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

var (
	ErrOversize  = errors.New("request body exceeds limit")
	ErrMalformed = errors.New("invalid JSON body")
	ErrTrailing  = errors.New("unexpected data after JSON body")
)

// Decode accepts whitespace-only input only when allowEmpty is true.
// Unknown fields follow encoding/json defaults; endpoint schemas own that policy.
func Decode(r io.Reader, dst any, limit int64, allowEmpty bool) error {
	data, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return err
	}
	if int64(len(data)) > limit {
		return ErrOversize
	}
	if len(bytes.TrimSpace(data)) == 0 && allowEmpty {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(dst); err != nil {
		return errors.Join(ErrMalformed, err)
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return ErrTrailing
	}
	return nil
}
