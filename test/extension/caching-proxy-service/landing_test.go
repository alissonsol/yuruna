// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"yuruna.com/test/extension/extension-sdk/pool"
)

// fakeGrafana answers /api/search with the uids given, which is how this page
// decides a dashboard exists at all.
func fakeGrafana(t *testing.T, uids ...string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/search") {
			http.NotFound(w, r)
			return
		}
		var b strings.Builder
		b.WriteString("[")
		for i, uid := range uids {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"uid":"` + uid + `","url":"/d/` + uid + `/board"}`)
		}
		b.WriteString("]")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(b.String()))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// fakeAggregator answers the extension registry with one entry per area named.
func fakeAggregator(t *testing.T, areas map[string]string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/extension-hosts" {
			http.NotFound(w, r)
			return
		}
		var b strings.Builder
		b.WriteString(`{"pool":"default","areas":{`)
		first := true
		for area, hostID := range areas {
			if !first {
				b.WriteString(",")
			}
			first = false
			b.WriteString(`"` + area + `":{"area":"` + area + `","hostId":"` + hostID +
				`","target":"http://10.0.0.9:8080","host":"10.0.0.9","healthy":true}`)
		}
		b.WriteString(`},"services":[]}`)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(b.String()))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func getLanding(t *testing.T, d *daemon, host string) (string, *http.Response) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/landing", nil)
	if host != "" {
		req.Host = host
	}
	rec := httptest.NewRecorder()
	d.handleLanding(rec, req)
	resp := rec.Result()
	body, _ := readAllString(resp)
	return body, resp
}

func readAllString(resp *http.Response) (string, error) {
	defer func() { _ = resp.Body.Close() }()
	var b strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := resp.Body.Read(buf)
		b.Write(buf[:n])
		if err != nil {
			return b.String(), nil
		}
	}
}

// The page's whole job: name every destination, whether or not it is reachable.
// An operator hunting a service that is down needs to be told it is down, which
// an omitted row does not do.
func TestLandingListsEveryDashboardAndServiceEvenWhenAbsent(t *testing.T) {
	d := &daemon{}
	body, _ := getLanding(t, d, "10.0.0.2")

	for _, want := range []string{
		"Dashboards (may demand a compatible browser)", "Extension hosts",
		"Yuruna hosts", "Hosts and test execution progress",
		"Yuruna caching-proxy service", "Caching proxy statistics",
		"Zot (official, Grafana ID 20501)", "Community Zot statistics",
		"Caching-proxy service", "Statistics summary",
		"Download-agent service", "Download agent control",
		"Pool-control service", "Assign hosts to pools and pools to test sequences",
		"Stash service", "Stash inspection and creating",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("the landing page does not name %q", want)
		}
	}
	// Nothing was reachable, so every one of the seven says so.
	if got := strings.Count(body, "(unavailable)"); got != 7 {
		t.Errorf("marked %d entries unavailable, want all 7", got)
	}
}

// The cache-health board is a canary the alerting rules read, not a page anyone
// browses to. Listing it would answer a question the operator did not ask.
func TestLandingDoesNotOfferTheCacheHealthBoard(t *testing.T) {
	d := &daemon{}
	body, _ := getLanding(t, d, "10.0.0.2")
	if strings.Contains(body, "cache health") || strings.Contains(body, "yuruna-cache-health") {
		t.Error("the landing page offers the cache-health board, which is not an operator page")
	}
}

// A link is the page's claim that something is there, so it may only appear for
// a dashboard Grafana actually holds. The Zot board is downloaded at boot and
// genuinely may be missing.
func TestLandingLinksOnlyTheDashboardsGrafanaHolds(t *testing.T) {
	graf := fakeGrafana(t, "yuruna-pool", "yuruna-squid")
	d := &daemon{grafanaURL: graf.URL}
	body, _ := getLanding(t, d, "10.0.0.2")

	if !strings.Contains(body, `href="http://10.0.0.2:3000/d/yuruna-pool/board"`) {
		t.Error("the hosts dashboard is not linked, though Grafana holds it")
	}
	if !strings.Contains(body, `href="http://10.0.0.2:3000/d/yuruna-squid/board"`) {
		t.Error("the caching-proxy dashboard is not linked, though Grafana holds it")
	}
	if strings.Contains(body, "yuruna-zot-official/board") {
		t.Error("the Zot dashboard is linked, though Grafana does not hold it")
	}
	if !strings.Contains(body, "Zot (official, Grafana ID 20501)</span> <span class=\"what\">&mdash; Community Zot statistics (unavailable)") {
		t.Error("the missing Zot dashboard is not reported as unavailable")
	}
}

// Grafana being unreachable must read as "no dashboards", not as a page full of
// links into nothing.
func TestLandingUnlinksEveryDashboardWhenGrafanaIsDown(t *testing.T) {
	d := &daemon{grafanaURL: "http://127.0.0.1:1"}
	body, _ := getLanding(t, d, "10.0.0.2")
	if strings.Contains(body, ":3000/d/") {
		t.Error("a dashboard is linked though Grafana could not be asked")
	}
}

// The service link goes through the aggregator's redirect, exactly as the
// dashboard's Extension hosts cell does: that is what resolves the service's
// current address and hands over the control proof that opens its UI unlocked.
func TestLandingLinksServicesThroughTheAggregatorRedirect(t *testing.T) {
	agg := fakeAggregator(t, map[string]string{
		"stash-service":        "426d17ef0b88426b922180dad1a9e921",
		"pool-control-service": "426d17ef0b88426b922180dad1a9e922",
	})
	d := &daemon{aggregatorURL: agg.URL, poolClient: pool.New(pool.Options{BaseURL: agg.URL})}
	body, _ := getLanding(t, d, "10.0.0.2")

	// Built from the address the browser reached this page on, carrying the
	// aggregator's port -- NOT from the URL this daemon read the pool over.
	// Those are the same machine and, off a port map, different addresses.
	port := agg.URL[strings.LastIndex(agg.URL, ":")+1:]
	want := "http://10.0.0.2:" + port + "/go/stash?host=426d17ef0b88426b922180dad1a9e921&amp;area=stash-service"
	if !strings.Contains(body, want) {
		t.Errorf("the stash row does not link through the aggregator redirect; want %q", want)
	}
	if !strings.Contains(body, "area=pool-control-service") {
		t.Error("the pool-control row does not link through the aggregator redirect")
	}
	// The two areas nothing announced are still listed, and still say so.
	for _, absent := range []string{"Download-agent service", "Caching-proxy service"} {
		if !strings.Contains(body, absent) {
			t.Errorf("%s dropped off the page when the pool could not locate it", absent)
		}
	}
	if got := strings.Count(body, "(unavailable)"); got != 5 {
		t.Errorf("marked %d entries unavailable, want 5 (3 dashboards + 2 services)", got)
	}
}

// The aggregator is configured with https here -- which is right for the read
// this daemon makes, and wrong for a link. Its TLS leaf is signed by the squid
// CA: this VM trusts it, an operator's browser does not, so an https link puts
// a certificate warning in front of a redirect that lands on a plain-http page.
// The scheme is forced back down for the browser, and only for the browser.
func TestLandingLinksServicesOverPlainHttpEvenWhenTheReadIsTls(t *testing.T) {
	agg := fakeAggregator(t, map[string]string{"stash-service": "426d17ef0b88426b922180dad1a9e921"})
	d := &daemon{
		// The scheme the seed writes into caching-proxy-service.env.
		aggregatorURL: "https://10.0.0.9:9400",
		poolClient:    pool.New(pool.Options{BaseURL: agg.URL}),
	}
	body, _ := getLanding(t, d, "10.0.0.2")

	if strings.Contains(body, "https://") {
		t.Error("the landing page emits an https link; the operator's browser does not hold the squid CA and is asked to accept a warning")
	}
	want := "http://10.0.0.2:9400/go/stash?host=426d17ef0b88426b922180dad1a9e921&amp;area=stash-service"
	if !strings.Contains(body, want) {
		t.Errorf("the stash link is not %q", want)
	}
}

// The port follows the configured aggregator; the host follows the request.
// Neither is guessed, and neither is taken from the other.
func TestAggregatorLinkBaseKeepsThePortAndDropsTheScheme(t *testing.T) {
	cases := []struct{ configured, host, want string }{
		{"https://10.0.0.9:9400", "10.0.0.2", "http://10.0.0.2:9400"},
		{"http://10.0.0.9:9400", "192.168.7.5", "http://192.168.7.5:9400"},
		// No port configured: the lab-wide default, not an empty authority.
		{"https://10.0.0.9", "10.0.0.2", "http://10.0.0.2:9400"},
		// A lab that moved the aggregator is followed.
		{"https://10.0.0.9:9999", "10.0.0.2", "http://10.0.0.2:9999"},
		// An IPv6 literal keeps the brackets an authority needs.
		{"https://[fd00::9]:9400", "[fd00::2]", "http://[fd00::2]:9400"},
		// Nothing to build from.
		{"", "10.0.0.2", ""},
		{"https://10.0.0.9:9400", "", ""},
	}
	for _, c := range cases {
		if got := aggregatorLinkBase(c.configured, c.host); got != c.want {
			t.Errorf("aggregatorLinkBase(%q, %q) = %q, want %q", c.configured, c.host, got, c.want)
		}
	}
}

// A suppressed entry is an address the pool has never reached or has stopped
// reaching, and it refuses to resolve through it. Linking it would offer a door
// the aggregator itself will not open.
func TestLandingWillNotLinkASuppressedService(t *testing.T) {
	agg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"pool":"default","areas":{"stash-service":` +
			`{"area":"stash-service","hostId":"426d17ef0b88426b922180dad1a9e921","target":"",` +
			`"suppressed":true,"suppressedTarget":"http://10.0.0.9:8080","suppressReason":"never reached"}},"services":[]}`))
	}))
	defer agg.Close()
	d := &daemon{aggregatorURL: agg.URL, poolClient: pool.New(pool.Options{BaseURL: agg.URL})}
	body, _ := getLanding(t, d, "10.0.0.2")
	if strings.Contains(body, "area=stash-service") {
		t.Error("a suppressed stash service is linked, though the pool refuses to resolve it")
	}
}

// The operator reached this page on some address -- its own LAN address, or a
// port map on their machine -- and every link has to be built from that one.
// Loopback would be right only for a browser running on the VM.
func TestLandingBuildsLinksFromTheAddressTheBrowserUsed(t *testing.T) {
	graf := fakeGrafana(t, "yuruna-pool")
	d := &daemon{grafanaURL: graf.URL}

	for _, host := range []string{"10.0.0.2", "10.0.0.2:80", "192.168.7.5:8080"} {
		body, _ := getLanding(t, d, host)
		bare := host
		if i := strings.LastIndex(bare, ":"); i >= 0 {
			bare = bare[:i]
		}
		want := "http://" + bare + ":3000/d/yuruna-pool/board"
		if !strings.Contains(body, want) {
			t.Errorf("reached on %q, the dashboard link is not %q", host, want)
		}
	}
}

// The reason this page exists. A browser that cannot run Grafana must still get
// a usable page, so there is nothing here to run: no script, and a policy that
// forbids one rather than merely omitting it.
func TestLandingCarriesNoScriptAtAll(t *testing.T) {
	graf := fakeGrafana(t, "yuruna-pool")
	d := &daemon{grafanaURL: graf.URL}
	body, resp := getLanding(t, d, "10.0.0.2")

	if strings.Contains(strings.ToLower(body), "<script") {
		t.Error("the landing page carries a script; it is served to browsers that cannot run one")
	}
	for _, attr := range []string{"onclick", "onload", "javascript:"} {
		if strings.Contains(strings.ToLower(body), attr) {
			t.Errorf("the landing page carries %q", attr)
		}
	}
	if strings.Contains(body, "https://") {
		t.Error("the landing page carries an https link; every destination on this VM is plain http to a browser")
	}
	csp := resp.Header.Get("Content-Security-Policy")
	if !strings.Contains(csp, "default-src 'none'") {
		t.Errorf("Content-Security-Policy = %q, want default-src 'none'", csp)
	}
	if strings.Contains(csp, "script-src") {
		t.Errorf("Content-Security-Policy names script-src (%q); default-src 'none' already forbids one", csp)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("Content-Type = %q", ct)
	}
}

// The stylesheet is held to the same browser baseline the service UIs are, for
// the same reason: this is the page an operator on an old tablet lands on.
func TestLandingStyleStaysOnTheBrowserBaseline(t *testing.T) {
	for _, banned := range []string{"display: grid", "display:grid", "gap:", "margin-inline", "padding-inline", "var(--"} {
		if strings.Contains(landingStyle, banned) {
			t.Errorf("the landing stylesheet uses %q, which the browser baseline does not carry", banned)
		}
	}
}

// The page is reached through Apache, and its route has to be the one the
// Apache config proxies to.
func TestLandingIsServedAtItsOwnRouteAndTheStatsPageKeepsRoot(t *testing.T) {
	d := newTestDaemon(t, modeLocal, t.TempDir(), &fakeExec{}, "")
	srv := httptest.NewServer(d.routes())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/landing")
	if err != nil {
		t.Fatalf("GET /landing: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /landing = %d, want 200", resp.StatusCode)
	}
	body, _ := readAllString(resp)
	if !strings.Contains(body, "Extension hosts") {
		t.Error("/landing is not the landing page")
	}

	// The statistics page stays where the dashboard's Extension hosts cell and
	// the landing page's own Caching-proxy row both point.
	root, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	defer func() { _ = root.Body.Close() }()
	rootBody, _ := readAllString(root)
	if strings.Contains(rootBody, "Extension hosts") {
		t.Error("/ now serves the landing page; the service's statistics page has nowhere left to live")
	}
}
