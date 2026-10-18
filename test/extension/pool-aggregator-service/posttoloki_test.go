// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// TestPostToLoki locks the shared Loki POST tail used by the four push paths
// (cycle, single-line beacon, events, incident): each POSTs the marshaled
// payload to lokiURL with the application/json content-type. The per-caller log
// prefix differs, but the wire behavior is identical, so this test pins the one
// shared behavior every caller depends on.
func TestPostToLoki(t *testing.T) {
	var (
		mu        sync.Mutex
		gotMethod string
		gotCT     string
		gotBody   []byte
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		gotMethod = r.Method
		gotCT = r.Header.Get("Content-Type")
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusNoContent) // a 2xx status: no error is logged
	}))
	defer srv.Close()

	payload := map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": "p", "hostId": "h", "src": "cycle"},
		"values": [][]string{{"1", "line"}},
	}}}
	postToLoki(srv.Client(), srv.URL, payload, "test push")

	mu.Lock()
	defer mu.Unlock()
	if gotMethod != http.MethodPost {
		t.Fatalf("method = %q, want POST", gotMethod)
	}
	if gotCT != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", gotCT)
	}
	want, _ := json.Marshal(payload)
	if string(gotBody) != string(want) {
		t.Fatalf("body = %q, want %q", gotBody, want)
	}
}
