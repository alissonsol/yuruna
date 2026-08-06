// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testHostID = "42512149deadbeef"

// TestHostInfo covers the chrome's host-facts endpoint: ok=true, the local
// hostId, the daemon version, and a serverIps STRING (newline-separated lines,
// possibly empty in a sandboxed CI with no non-loopback interface — the contract
// is the shape, not a specific address).
func TestHostInfo(t *testing.T) {
	srv := httptest.NewServer(New(&fakeIntent{}, Options{Version: "test", HostID: testHostID}).Handler())
	defer srv.Close()

	resp, m := do(t, "GET", srv.URL+"/api/hostinfo", "")
	if resp.StatusCode != http.StatusOK || m["ok"] != true {
		t.Fatalf("hostinfo: got %d %v", resp.StatusCode, m)
	}
	if m["localHostId"] != testHostID || m["version"] != "test" {
		t.Fatalf("hostinfo should carry the host id and version; got %v", m)
	}
	ips, ok := m["serverIps"].(string)
	if !ok {
		t.Fatalf("serverIps must be a string, got %T", m["serverIps"])
	}
	// Every reported line must be a comma-list of parseable IPs (no stray
	// whitespace, no link-local/loopback leaking through).
	if ips != "" {
		for _, line := range strings.Split(ips, "\n") {
			for _, addr := range strings.Split(line, ",") {
				ip := net.ParseIP(addr)
				if ip == nil {
					t.Fatalf("serverIps has non-IP token %q in %q", addr, ips)
				}
				if ip.IsLoopback() || ip.IsLinkLocalUnicast() {
					t.Fatalf("serverIps leaked loopback/link-local %q", addr)
				}
			}
		}
	}
}

// The tables link every host id at the aggregator's /go/host redirect, and the
// value they build that link from has to be plain http even though the
// configured aggregator URL is https. Those redirects land on a host's own
// plain-http status page, so https protects nothing the next hop does not
// already carry in clear -- while an operator's browser, which has no reason to
// trust the proxy CA, would raise a certificate interstitial in front of every
// host link. The aggregator answers both protocols on the same port.
func TestHostInfoHandsTheBrowserAPlainHTTPAggregatorBase(t *testing.T) {
	srv := httptest.NewServer(New(&fakeIntent{}, Options{
		Version: "test", HostID: testHostID,
		AggregatorURL: "https://10.0.0.2:9400",
	}).Handler())
	defer srv.Close()

	_, m := do(t, "GET", srv.URL+"/api/hostinfo", "")
	if got := m["goBaseUrl"]; got != "http://10.0.0.2:9400" {
		t.Fatalf("goBaseUrl = %v, want the https base downgraded to http", got)
	}
	// The configured value stays untouched where it describes configuration:
	// this daemon's own calls to the aggregator should keep their TLS.
	_, d := do(t, "GET", srv.URL+"/api/diagnostics", "")
	env, _ := d["environment"].(map[string]any)
	if env == nil || env["aggregatorUrl"] != "https://10.0.0.2:9400" {
		t.Fatalf("diagnostics must report the CONFIGURED url, got %v", d["environment"])
	}
}

func TestGoBaseURL(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"https://10.0.0.2:9400", "http://10.0.0.2:9400"},
		{"http://10.0.0.2:9400", "http://10.0.0.2:9400"},
		{"https://10.0.0.2:9400/", "http://10.0.0.2:9400"},
		{"  https://proxy.lan:9400//  ", "http://proxy.lan:9400"},
		// No aggregator configured: the UI renders host ids unlinked rather than
		// pointing them at nothing.
		{"", ""},
		// Only a mistyped flag produces these, and an unlinked id beats a dead
		// or dangerous href.
		{"javascript:alert(1)", ""},
		{"ftp://10.0.0.2", ""},
		{"not a url", ""},
	} {
		if got := goBaseURL(c.in); got != c.want {
			t.Errorf("goBaseURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestEveryPageServesChrome verifies that every page of this service carries the
// shared header and footer markup, and that the module driving it ships in
// common.js — i.e. the chrome is wired end-to-end on all of them, not just on
// whichever page it was added to first.
func TestEveryPageServesChrome(t *testing.T) {
	srv := httptest.NewServer(New(&fakeIntent{}, Options{Version: "test"}).Handler())
	defer srv.Close()

	want := []string{
		`id="header-version"`, `id="machine"`, `Yuruna Pool Control`,
		`id="footer-bar"`, `id="footer-ip-list"`, `id="last-loaded"`, `id="countdown"`,
	}
	for _, path := range []string{"/", "/assign", "/pools", "/test-sets", "/hosts", "/diagnostics"} {
		body := getText(t, srv.URL+path)
		for _, w := range want {
			if !strings.Contains(body, w) {
				t.Errorf("page %s is missing chrome element %q", path, w)
			}
		}
		// The chrome only runs if the page's scripts actually load. A page that
		// references an asset the binary does not embed renders as a dead
		// skeleton, which no markup assertion above would catch.
		for _, asset := range assetRefs(body) {
			if resp, err := http.Get(srv.URL + asset); err != nil {
				t.Errorf("page %s references %s: %v", path, asset, err)
			} else {
				resp.Body.Close()
				if resp.StatusCode != http.StatusOK {
					t.Errorf("page %s references %s, which is not served (status %d)", path, asset, resp.StatusCode)
				}
			}
		}
	}

	js := getText(t, srv.URL+"/assets/common.js")
	if !strings.Contains(js, "initChrome") {
		t.Fatalf("common.js missing initChrome module")
	}
}

// assetRefs pulls every /assets/... path a page references from its src= and
// href= attributes.
func assetRefs(page string) []string {
	var out []string
	for _, attr := range []string{`src="`, `href="`} {
		rest := page
		for {
			i := strings.Index(rest, attr)
			if i < 0 {
				break
			}
			rest = rest[i+len(attr):]
			end := strings.IndexByte(rest, '"')
			if end < 0 {
				break
			}
			if v := rest[:end]; strings.HasPrefix(v, "/assets/") {
				out = append(out, v)
			}
			rest = rest[end:]
		}
	}
	return out
}

func getText(t *testing.T, url string) string {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: status %d", url, resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("GET %s: read: %v", url, err)
	}
	return string(b)
}
