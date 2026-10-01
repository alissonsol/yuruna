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
// possibly empty in a sandboxed CI with no non-loopback interface -- the contract
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
// shared header and footer markup, and that the module driving it is actually
// served -- i.e. the chrome is wired end-to-end on all of them, not just on
// whichever page it was added to first.
//
// The module lives in the SDK's yuruna.core.js rather than in this service's
// common.js, so the assertion below also covers the asset fallback: the file is
// embedded in another module and reaches the browser only if this service hands
// it over.
func TestEveryPageServesChrome(t *testing.T) {
	s := New(&fakeIntent{}, Options{Version: "test"})
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()

	want := []string{
		`id="header-version"`, `id="machine"`, `Yuruna Pool Control`,
		`id="footer-bar"`, `id="footer-ip-list"`, `id="last-loaded"`, `id="countdown"`,
	}
	// One list for both loops below. Stated twice, the two drift: a page added
	// to one is checked for its markup and not for its runtime, or the reverse,
	// and either way the gap reads as coverage.
	pages := []string{"/", "/pools", "/scan", "/hosts", "/diagnostics"}

	// The list above has to cover every page the binary embeds. A page file
	// whose route is gone is unreachable dead weight, and a route whose file is
	// gone answers 500 at request time rather than failing at startup.
	embedded := map[string]bool{}
	for variant := range s.assets.pages {
		embedded[variant.name] = true
	}
	if len(embedded) != len(pages) {
		t.Errorf("the binary embeds %d pages but this test serves %d; a page and its route must come and go together", len(embedded), len(pages))
	}

	for _, path := range pages {
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
		// Every menu and in-page link to another page of this service has to
		// answer. A link to a route this binary does not serve is a dead end
		// that none of the markup assertions above would notice.
		links := pageLinks(body)
		if len(links) == 0 {
			t.Errorf("page %s carries no links to other pages, so its menu is missing", path)
		}
		for _, link := range links {
			if resp, err := http.Get(srv.URL + link); err != nil {
				t.Errorf("page %s links to %s: %v", path, link, err)
			} else {
				resp.Body.Close()
				if resp.StatusCode != http.StatusOK {
					t.Errorf("page %s links to %s, which is not served (status %d)", path, link, resp.StatusCode)
				}
			}
		}
	}

	for _, path := range pages {
		if body := getText(t, srv.URL+path); !strings.Contains(body, "/assets/yuruna.core.js") {
			t.Errorf("page %s does not load the shared runtime, so it has no chrome to wire", path)
		}
	}

	js := getText(t, srv.URL+"/assets/yuruna.core.js")
	for _, module := range []string{"initChrome", "initMenu", "initFooter"} {
		if !strings.Contains(js, module) {
			t.Errorf("the shared runtime is served but does not define %s", module)
		}
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

// pageLinks pulls every same-origin page link a page carries: each href="/..."
// that is neither an /assets/ file nor a protocol-relative "//host" URL, with
// any query or fragment dropped.
func pageLinks(page string) []string {
	var out []string
	rest := page
	for {
		i := strings.Index(rest, `href="/`)
		if i < 0 {
			return out
		}
		rest = rest[i+len(`href="`):]
		end := strings.IndexByte(rest, '"')
		if end < 0 {
			return out
		}
		v := rest[:end]
		rest = rest[end:]
		if strings.HasPrefix(v, "//") || strings.HasPrefix(v, "/assets/") {
			continue
		}
		if cut := strings.IndexAny(v, "?#"); cut >= 0 {
			v = v[:cut]
		}
		out = append(out, v)
	}
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
