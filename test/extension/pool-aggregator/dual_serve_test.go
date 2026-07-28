// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"testing"
	"time"
)

// newTestTLSConfig mints a throwaway self-signed leaf for 127.0.0.1 so the
// dual-listener test can complete a real TLS handshake without touching disk.
func newTestTLSConfig(t *testing.T) *tls.Config {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "dual-listener-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
	}
}

// TestDualProtocolListenerServesBoth: one port must answer BOTH a plain-http
// client (the browser following a dashboard deep-link) and a TLS client (the
// bearer-carrying ingest forwarder, Set-LabToken, the Prometheus scrape). The
// handler reports which path served it via Request.TLS, which http.Server only
// populates when the listener really handed it a *tls.Conn.
func TestDualProtocolListenerServesBoth(t *testing.T) {
	inner, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.TLS != nil {
				fmt.Fprint(w, "tls")
			} else {
				fmt.Fprint(w, "plain")
			}
		}),
		ReadTimeout: 5 * time.Second,
	}
	// Built before the serve goroutine: t.Fatalf is only valid on the test goroutine.
	tlsCfg := newTestTLSConfig(t)
	go func() { _ = srv.Serve(newDualProtocolListener(inner, tlsCfg)) }()
	defer srv.Close()
	base := inner.Addr().String()

	get := func(client *http.Client, url string) string {
		t.Helper()
		res, err := client.Get(url)
		if err != nil {
			t.Fatalf("GET %s: %v", url, err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatalf("read %s: %v", url, err)
		}
		if res.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: status %d", url, res.StatusCode)
		}
		return string(body)
	}

	plainClient := &http.Client{Timeout: 5 * time.Second}
	if got := get(plainClient, "http://"+base+"/"); got != "plain" {
		t.Fatalf("plain client served by %q path, want plain", got)
	}
	tlsClient := &http.Client{
		Timeout: 5 * time.Second,
		// The leaf is self-signed and per-test; trust is not what this test checks.
		Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
	}
	if got := get(tlsClient, "https://"+base+"/"); got != "tls" {
		t.Fatalf("tls client served by %q path, want tls", got)
	}
	// Interleave once more so a stray state assumption (one protocol poisoning
	// the listener for the other) cannot hide behind ordering.
	if got := get(plainClient, "http://"+base+"/"); got != "plain" {
		t.Fatalf("second plain request served by %q path, want plain", got)
	}
}

// TestNormalizeHostID: the /go/* deep-links must resolve both spellings of a
// hostId -- the undashed pool key and the GUID-formatted rendering the
// dashboard tables display -- and must not touch anything else (hostIds are
// opaque by contract).
func TestNormalizeHostID(t *testing.T) {
	const raw = "4253419c1f0b45a08260f36a1521a857"
	const dashed = "4253419c-1f0b-45a0-8260-f36a1521a857"
	if got := normalizeHostID(dashed); got != raw {
		t.Fatalf("dashed: got %q want %q", got, raw)
	}
	if got := normalizeHostID(raw); got != raw {
		t.Fatalf("raw must pass through, got %q", got)
	}
	if got := normalizeHostID("not-a-guid"); got != "not-a-guid" {
		t.Fatalf("non-guid must pass through, got %q", got)
	}
}
