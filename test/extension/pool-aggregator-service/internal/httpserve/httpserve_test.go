// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42dce1e1-8c50-4078-af64-7f2aafe75833

package httpserve

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
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
	go func() { _ = srv.Serve(NewDualProtocolListener(inner, tlsCfg)) }()
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

// failingListener fails every Accept with a transient error, the way an
// exhausted descriptor table does, and counts the attempts.
type failingListener struct {
	calls  atomic.Int64
	closed chan struct{}
	once   sync.Once
}

var errTooManyOpenFiles = errors.New("accept: too many open files")

func (f *failingListener) Accept() (net.Conn, error) {
	select {
	case <-f.closed:
		return nil, net.ErrClosed
	default:
	}
	f.calls.Add(1)
	return nil, errTooManyOpenFiles
}

func (f *failingListener) Close() error {
	f.once.Do(func() { close(f.closed) })
	return nil
}

func (f *failingListener) Addr() net.Addr { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }

// A transient accept error must not turn the accept loop into a busy loop: the
// http.Server backoff paces only the wrapper's Accept, never the inner one.
func TestDualProtocolListenerBacksOffOnAcceptErrors(t *testing.T) {
	inner := &failingListener{closed: make(chan struct{})}
	l := NewDualProtocolListener(inner, nil)
	if _, err := l.Accept(); !errors.Is(err, errTooManyOpenFiles) {
		t.Fatalf("Accept() error = %v, want the parked transient error", err)
	}
	time.Sleep(300 * time.Millisecond)
	if err := l.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	// 5+10+20+40+80+160ms: about seven attempts fit in the window, where a loop
	// without the backoff makes them by the million.
	if n := inner.calls.Load(); n < 2 || n > 50 {
		t.Errorf("inner Accept called %d times in 300ms, want a handful (capped exponential backoff)", n)
	}
}

func TestNextAcceptDelayDoublesToACeiling(t *testing.T) {
	var got time.Duration
	for _, want := range []time.Duration{5 * time.Millisecond, 10 * time.Millisecond, 20 * time.Millisecond} {
		if got = nextAcceptDelay(got); got != want {
			t.Fatalf("delay = %s, want %s", got, want)
		}
	}
	if got := nextAcceptDelay(800 * time.Millisecond); got != time.Second {
		t.Errorf("nextAcceptDelay(800ms) = %s, want the 1s ceiling", got)
	}
}
