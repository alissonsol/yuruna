// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

type artifactCountingTransport struct {
	base http.RoundTripper
	gets atomic.Int64
}

func (c *artifactCountingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, ".iso") {
		c.gets.Add(1)
	}
	return c.base.RoundTrip(r)
}

func staleProxyClient(t *testing.T, body []byte, hits *atomic.Int64) *http.Client {
	t.Helper()
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		_, _ = w.Write(body)
	}))
	t.Cleanup(proxy.Close)
	u, err := url.Parse(proxy.URL)
	if err != nil {
		t.Fatal(err)
	}
	return &http.Client{Transport: fixtureTransport{base: http.DefaultTransport, host: u.Host}}
}

func TestRefreshRetriesStaleProxyContentDirectly(t *testing.T) {
	fresh := []byte("fresh current artifact")
	for _, tc := range []struct {
		name  string
		stale []byte
	}{
		{"different size", []byte("old artifact")},
		{"same size different checksum", bytes.Repeat([]byte("x"), len(fresh))},
	} {
		t.Run(tc.name, func(t *testing.T) {
			direct := &artifactCountingTransport{base: ubuntuFixture(t, fresh, true, 0)}
			a := newTestAgent(t, Options{PoolDir: t.TempDir(), Transport: direct})
			var hits atomic.Int64
			a.proxyBytes = staleProxyClient(t, tc.stale, &hits)
			id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}
			flight, started := a.startRefresh(id, false)
			if !started {
				t.Fatal("refresh did not start")
			}
			<-flight.Done()
			if err := flight.Err(); err != nil {
				t.Fatalf("refresh through a stale proxy: %v", err)
			}
			if hits.Load() != 1 || direct.gets.Load() != 1 {
				t.Fatalf("wanted one proxy GET and one direct GET, got proxy=%d direct=%d", hits.Load(), direct.gets.Load())
			}
			pointer, ok, err := a.store.ReadPointer(id)
			if err != nil || !ok {
				t.Fatalf("ReadPointer: ok=%v err=%v", ok, err)
			}
			got, err := os.ReadFile(filepath.Join(a.store.Dir(id), pointer.GenerationFile))
			if err != nil || !bytes.Equal(got, fresh) {
				t.Fatalf("promoted bytes=%q err=%v", got, err)
			}
			sc, err := a.store.ReadSidecar(id, pointer.GenerationFile)
			if err != nil {
				t.Fatal(err)
			}
			if sc.SHA256 != sha256Hex(fresh) || sc.ByteCount != int64(len(fresh)) || sc.ChecksumVerdict != VerdictVerified {
				t.Fatalf("direct retry was not independently verified: %+v", sc)
			}
			if progress := flight.Progress.Snapshot(); progress.Done != int64(len(fresh)) || progress.Total != int64(len(fresh)) {
				t.Fatalf("progress includes discarded proxy bytes: %+v", progress)
			}
		})
	}
}

func TestInvalidDirectRetryKeepsThePreviousGeneration(t *testing.T) {
	good := []byte("known good artifact")
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Transport: ubuntuFixture(t, good, true, 0)})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}
	if err := a.refreshNow(context.Background(), id, &Progress{}); err != nil {
		t.Fatal(err)
	}
	before, _, err := a.store.ReadPointer(id)
	if err != nil {
		t.Fatal(err)
	}
	// Both sources now disagree with HEAD. Neither the stale hit nor the
	// invalid direct response can replace the previously verified generation.
	direct := &artifactCountingTransport{base: ubuntuFixture(t, []byte("short"), true, 4096)}
	a.direct.Transport = direct
	a.directBytes.Transport = direct
	var hits atomic.Int64
	a.proxyBytes = staleProxyClient(t, []byte("stale"), &hits)
	if err := a.refreshNow(context.Background(), id, &Progress{}); err == nil {
		t.Fatal("a failed direct verification must fail the refresh")
	}
	if hits.Load() != 1 || direct.gets.Load() != 1 {
		t.Fatalf("invalid bytes caused repeated retries: proxy=%d direct=%d", hits.Load(), direct.gets.Load())
	}
	after, ok, err := a.store.ReadPointer(id)
	if err != nil || !ok || before.GenerationFile != after.GenerationFile {
		t.Fatalf("failed refresh changed the current pointer: before=%+v after=%+v err=%v", before, after, err)
	}
	staged, err := os.ReadDir(a.store.StagingDir(id))
	if err != nil || len(staged) != 0 {
		t.Fatalf("failed retry left staging artifacts: entries=%d err=%v", len(staged), err)
	}
}
