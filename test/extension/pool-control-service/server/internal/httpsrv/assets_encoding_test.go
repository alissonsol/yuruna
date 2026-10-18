// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAcceptsGzipHonorsHTTPQualityValues(t *testing.T) {
	tests := []struct {
		name   string
		values []string
		want   bool
	}{
		{name: "absent", want: false},
		{name: "bare gzip", values: []string{"gzip"}, want: true},
		{name: "case and list", values: []string{"br, GZip"}, want: true},
		{name: "positive quality", values: []string{"gzip; q=0.001"}, want: true},
		{name: "zero quality", values: []string{"gzip;q=0"}, want: false},
		{name: "zero decimal quality", values: []string{"gzip;q=0.000"}, want: false},
		{name: "malformed quality", values: []string{"gzip;q=bogus"}, want: false},
		{name: "missing quality value", values: []string{"gzip;q"}, want: false},
		{name: "out of range", values: []string{"gzip;q=1.1"}, want: false},
		{name: "too precise", values: []string{"gzip;q=0.0000"}, want: false},
		{name: "general float grammar", values: []string{"gzip;q=1e-1"}, want: false},
		{name: "duplicate quality", values: []string{"gzip;q=0.5;q=0.6"}, want: false},
		{name: "wildcard", values: []string{"br, *;q=0.5"}, want: true},
		{name: "explicit refusal beats wildcard", values: []string{"*;q=1, gzip;q=0"}, want: false},
		{name: "malformed explicit beats wildcard", values: []string{"*;q=1, gzip;q=no"}, want: false},
		{name: "best repeated gzip member", values: []string{"gzip;q=0", "gzip;q=0.4"}, want: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/assets/example.js", nil)
			for _, value := range test.values {
				req.Header.Add("Accept-Encoding", value)
			}
			if got := acceptsGzip(req); got != test.want {
				t.Fatalf("acceptsGzip(%q) = %v, want %v", test.values, got, test.want)
			}
		})
	}
}

func TestServeAssetNeverSendsExplicitlyRefusedGzip(t *testing.T) {
	for _, value := range []string{"gzip;q=0", "gzip;q=bogus", "*;q=1, gzip;q=0"} {
		t.Run(value, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/assets/example.js", nil)
			req.Header.Set("Accept-Encoding", value)
			recorder := httptest.NewRecorder()
			prepared := &asset{
				body:        []byte("plain response"),
				gzipBody:    []byte("compressed response"),
				contentType: "text/javascript; charset=utf-8",
				etag:        `"example"`,
			}

			serveAsset(recorder, req, prepared)

			if got := recorder.Header().Get("Content-Encoding"); got != "" {
				t.Fatalf("Content-Encoding = %q for %q; gzip was explicitly refused", got, value)
			}
			if got := recorder.Body.String(); got != "plain response" {
				t.Fatalf("body = %q for %q, want the plain representation", got, value)
			}
		})
	}
}

func TestAssetValidatorsAreSpecificToTheSelectedEncoding(t *testing.T) {
	prepared := newAsset([]byte(strings.Repeat("compressible locale data ", 80)),
		"text/javascript; charset=utf-8")
	if prepared.gzipBody == nil || prepared.gzipETag == "" || prepared.gzipETag == prepared.etag {
		t.Fatal("fixture did not produce distinct identity and gzip representations")
	}

	identityRequest := httptest.NewRequest("GET", "/assets/example.js", nil)
	identityResponse := httptest.NewRecorder()
	serveAsset(identityResponse, identityRequest, prepared)
	identityETag := identityResponse.Header().Get("ETag")
	if identityETag != prepared.etag {
		t.Fatalf("identity ETag = %q, want %q", identityETag, prepared.etag)
	}

	// An identity validator cannot validate the different gzip bytes.
	gzipRequest := httptest.NewRequest("GET", "/assets/example.js", nil)
	gzipRequest.Header.Set("Accept-Encoding", "gzip")
	gzipRequest.Header.Set("If-None-Match", identityETag)
	gzipResponse := httptest.NewRecorder()
	serveAsset(gzipResponse, gzipRequest, prepared)
	if gzipResponse.Code != http.StatusOK {
		t.Fatalf("gzip request with identity validator returned %d, want 200", gzipResponse.Code)
	}
	if got := gzipResponse.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("gzip response Content-Encoding = %q", got)
	}
	gzipETag := gzipResponse.Header().Get("ETag")
	if gzipETag != prepared.gzipETag || gzipETag == identityETag {
		t.Fatalf("gzip ETag = %q, identity ETag = %q", gzipETag, identityETag)
	}

	// A matching gzip validator produces a 304 that still identifies the
	// selected representation's content coding.
	gzipConditional := httptest.NewRequest("GET", "/assets/example.js", nil)
	gzipConditional.Header.Set("Accept-Encoding", "gzip")
	gzipConditional.Header.Set("If-None-Match", gzipETag)
	gzipNotModified := httptest.NewRecorder()
	serveAsset(gzipNotModified, gzipConditional, prepared)
	if gzipNotModified.Code != http.StatusNotModified {
		t.Fatalf("matching gzip validator returned %d, want 304", gzipNotModified.Code)
	}
	if got := gzipNotModified.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("gzip 304 Content-Encoding = %q", got)
	}

	// The inverse crossing is different bytes too.
	identityConditional := httptest.NewRequest("GET", "/assets/example.js", nil)
	identityConditional.Header.Set("If-None-Match", gzipETag)
	identityCrossing := httptest.NewRecorder()
	serveAsset(identityCrossing, identityConditional, prepared)
	if identityCrossing.Code != http.StatusOK {
		t.Fatalf("identity request with gzip validator returned %d, want 200", identityCrossing.Code)
	}
	if got := identityCrossing.Header().Get("Content-Encoding"); got != "" {
		t.Fatalf("identity response Content-Encoding = %q", got)
	}
}
