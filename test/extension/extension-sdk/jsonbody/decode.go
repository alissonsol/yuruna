// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4244fe2f-e751-4969-a9a8-7d2b20b815a4

// Package jsonbody validates bounded, single-document JSON request bodies.
package jsonbody

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"
)

var (
	ErrOversize  = errors.New("request body exceeds limit")
	ErrMalformed = errors.New("invalid JSON body")
	ErrTrailing  = errors.New("unexpected data after JSON body")
)

// bodyReadTimeout bounds how long a small JSON request body may take to arrive.
// The services leave http.Server.ReadTimeout unset because some of their routes
// stream gigabytes, so without it a client that sends its headers and then
// trickles the body holds a goroutine and a connection for as long as it likes.
var bodyReadTimeout = 30 * time.Second

// DecodeRequest is Decode over a request body that must arrive within the body
// read timeout. The deadline is cleared once the body is read: one that fired
// while the handler was still working would cancel the request.
func DecodeRequest(w http.ResponseWriter, r *http.Request, dst any, limit int64, allowEmpty bool) error {
	data, err := ReadRequest(w, r, limit)
	if err != nil {
		return err
	}
	return decodeData(data, dst, allowEmpty)
}

// ReadRequest reads a request body of at most limit bytes that must arrive
// within the body read timeout, for a handler that parses the bytes itself. A
// body over the limit is ErrOversize.
func ReadRequest(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, error) {
	control := http.NewResponseController(w)
	_ = control.SetReadDeadline(time.Now().Add(bodyReadTimeout))
	defer func() { _ = control.SetReadDeadline(time.Time{}) }()
	return readLimited(r.Body, limit)
}

// Decode accepts whitespace-only input only when allowEmpty is true.
// Unknown fields follow encoding/json defaults; endpoint schemas own that policy.
func Decode(r io.Reader, dst any, limit int64, allowEmpty bool) error {
	data, err := readLimited(r, limit)
	if err != nil {
		return err
	}
	return decodeData(data, dst, allowEmpty)
}

func readLimited(r io.Reader, limit int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, ErrOversize
	}
	return data, nil
}

func decodeData(data []byte, dst any, allowEmpty bool) error {
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
