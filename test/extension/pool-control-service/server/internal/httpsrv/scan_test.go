// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pool-control-service/internal/discovery"
)

// waitForIdle blocks until the server's scan engine is idle, so a test asserts
// on a finished run rather than racing it.
func waitForIdle(t *testing.T, s *Server) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if !s.scan.Running() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the scan did not finish within the test's budget")
}

// The whole loop the Scan page drives: start a scan, watch it, and see the
// hosts it found land on the monitored list. The range is a /30 (two host
// addresses) so the test scans real closed ports quickly instead of standing up
// a network.
func TestScanStartAndStatus(t *testing.T) {
	srv := httptest.NewServer(New(&fakeIntent{}, Options{Version: "test", AuthToken: testBearer}).Handler())
	defer srv.Close()

	resp, m := do(t, "POST", srv.URL+"/api/scan", `{"cidr":"127.0.0.0/30"}`)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("scan start: got %d %v", resp.StatusCode, m)
	}
	scan, _ := m["scan"].(map[string]any)
	if scan["cidr"] != "127.0.0.0/30" || scan["total"].(float64) != 2 {
		t.Fatalf("a /30 must scan its two host addresses; got %v", scan)
	}

	// The status read is open -- the page polls it without unlocking -- and it
	// carries what a cold page needs to render itself.
	sresp, err := http.Get(srv.URL + "/api/scan")
	if err != nil {
		t.Fatal(err)
	}
	var status map[string]any
	b, _ := io.ReadAll(sresp.Body)
	sresp.Body.Close()
	if err := json.Unmarshal(b, &status); err != nil {
		t.Fatal(err)
	}
	if sresp.StatusCode != 200 || status["ok"] != true {
		t.Fatalf("scan status must be readable without unlocking; got %d %s", sresp.StatusCode, b)
	}
	if _, ok := status["defaultCidr"]; !ok {
		t.Fatalf("status must offer the default range for the field: %s", b)
	}
	if status["maxAddresses"].(float64) != float64(discovery.MaxAddresses) {
		t.Fatalf("status must publish the cap the field validates against: %s", b)
	}
}

// Scanning changes what this daemon monitors and aims connection attempts at a
// network the caller names, so it is gated with the writes, not the reads.
func TestScanRequiresUnlock(t *testing.T) {
	srv := httptest.NewServer(New(&fakeIntent{}, Options{Version: "test", AuthToken: testBearer}).Handler())
	defer srv.Close()

	for _, path := range []string{"/api/scan", "/api/scan/forget"} {
		resp, err := http.Post(srv.URL+path, "application/json", strings.NewReader(`{"cidr":"127.0.0.0/30","key":"x"}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("POST %s without the lab token = %d, want 401", path, resp.StatusCode)
		}
	}
}

// A range the daemon will not walk is refused before anything is probed, and
// the refusal says what would be accepted instead.
func TestScanRejectsOversizeRange(t *testing.T) {
	srv := httptest.NewServer(New(&fakeIntent{}, Options{Version: "test", AuthToken: testBearer}).Handler())
	defer srv.Close()

	resp, m := do(t, "POST", srv.URL+"/api/scan", `{"cidr":"10.0.0.0/8"}`)
	if resp.StatusCode != 400 || m["ok"] != false {
		t.Fatalf("an over-size range must be refused; got %d %v", resp.StatusCode, m)
	}
	if !strings.Contains(m["error"].(string), "/20") {
		t.Fatalf("the refusal must name the narrowest allowed prefix; got %v", m["error"])
	}
}

// An empty range means "the one you would sweep", which is what the page sends
// when the operator has not typed anything of their own.
func TestScanEmptyCIDRUsesConfigured(t *testing.T) {
	s := New(&fakeIntent{}, Options{Version: "test", AuthToken: testBearer, ScanCIDR: "127.0.0.0/30"})
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()

	resp, m := do(t, "POST", srv.URL+"/api/scan", `{}`)
	if resp.StatusCode != 200 {
		t.Fatalf("empty cidr: got %d %v", resp.StatusCode, m)
	}
	scan, _ := m["scan"].(map[string]any)
	if scan["cidr"] != "127.0.0.0/30" {
		t.Fatalf("an empty cidr must fall back to the configured range; got %v", scan)
	}
	waitForIdle(t, s)
}

// Discovered hosts belong on the Hosts page: "which machines does this lab
// have" is one question, and a host that registered with nobody is the one an
// operator most needs to see next to the ones that did.
func TestHostsIncludesDiscovered(t *testing.T) {
	dir := t.TempDir()
	agg := hostsAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL, AuthToken: testBearer, StateDir: dir})

	s.discovered.Add(discovery.Host{
		Address: "192.168.7.9", BaseURL: "http://192.168.7.9:8080",
		HostID: "9999", Hostname: "lab-9", HostType: "ubuntu.kvm",
	}, time.Now())
	// One that never named itself: it must still reach the page, keyed by the
	// address it answered at.
	s.discovered.Add(discovery.Host{Address: "192.168.7.10", BaseURL: "http://192.168.7.10:8080"}, time.Now())
	// And one the aggregator already reports: the page must render it once, as
	// the pool's host, not twice.
	s.discovered.Add(discovery.Host{Address: "192.168.7.11", BaseURL: "http://192.168.7.11:8080", HostID: "42aa"}, time.Now())

	payload, _ := hostsPayload(t, s, testBearer)
	found := map[string]map[string]any{}
	dupes := 0
	for _, r := range payload["hosts"].([]any) {
		row := r.(map[string]any)
		if row["discovered"] == true {
			found[row["address"].(string)] = row
		}
		if row["hostId"] == "42aa" {
			dupes++
		}
	}
	if len(found) != 2 {
		t.Fatalf("both unregistered hosts must reach the Hosts page; got %v", found)
	}
	if dupes != 1 {
		t.Fatalf("a host that is both discovered and registered must render once; got %d rows", dupes)
	}
	if found["192.168.7.9"]["hostId"] != "9999" || found["192.168.7.9"]["hostname"] != "lab-9" {
		t.Fatalf("a discovered host must carry what it reported about itself: %v", found["192.168.7.9"])
	}
	if found["192.168.7.9"]["type"] != "ubuntu.kvm" {
		t.Fatalf("a discovered host's type must reach the page: %v", found["192.168.7.9"])
	}
	// The status-service base is the row's only working way in: the aggregator's
	// /go/host redirect resolves what a host registered, and this one registered
	// nothing, so the page links the address instead of the id.
	if found["192.168.7.9"]["baseUrl"] != "http://192.168.7.9:8080" {
		t.Fatalf("a discovered host must carry the base URL it answered on: %v", found["192.168.7.9"])
	}
	// No pool: discovery monitors a host, it does not enrol one.
	if pool, ok := found["192.168.7.9"]["pool"]; ok && pool != "" {
		t.Fatalf("a discovered host must belong to no pool: %v", found["192.168.7.9"])
	}
	// The id-less one is identified by its address and nothing else.
	if got := found["192.168.7.10"]["hostId"]; got != "" {
		t.Fatalf("an id-less host must not be given one: %v", got)
	}

	// The list survives a restart, because the store is a file beside the audit
	// log rather than something the process holds.
	if _, err := os.Stat(filepath.Join(dir, discoveredHostsFile)); err != nil {
		t.Fatalf("the discovered list must be persisted under the state dir: %v", err)
	}
}

// Forget is the way out for a retired machine, and it is gated like the scan
// that put the host there.
func TestScanForget(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{Version: "test", AuthToken: testBearer})
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()
	s.discovered.Add(discovery.Host{Address: "192.168.7.9", HostID: "9999"}, time.Now())

	resp, m := do(t, "POST", srv.URL+"/api/scan/forget", `{"key":"9999"}`)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("forget: got %d %v", resp.StatusCode, m)
	}
	if s.discovered.Has("9999") {
		t.Fatal("a forgotten host must leave the monitored list")
	}
	resp, _ = do(t, "POST", srv.URL+"/api/scan/forget", `{"key":"9999"}`)
	if resp.StatusCode != 404 {
		t.Fatalf("forgetting an absent host = %d, want 404", resp.StatusCode)
	}
	resp, _ = do(t, "POST", srv.URL+"/api/scan/forget", `{}`)
	if resp.StatusCode != 400 {
		t.Fatalf("forget with no key = %d, want 400", resp.StatusCode)
	}
}

// The page has to be reachable from the menu on every page, and its script has
// to ship: a menu item pointing at a 404 is worse than no menu item.
func TestScanPageServed(t *testing.T) {
	srv := httptest.NewServer(New(&fakeIntent{}, Options{Version: "test"}).Handler())
	defer srv.Close()

	page := getText(t, srv.URL+"/scan")
	if !strings.Contains(page, "Scan &mdash; Yuruna Pool Control") {
		t.Fatalf("the Scan page must carry its own title: %.120s", page)
	}
	if !strings.Contains(page, `src="/assets/scan.js"`) {
		t.Fatal("the Scan page must load its script")
	}
	if !strings.Contains(getText(t, srv.URL+"/assets/scan.js"), "/api/scan") {
		t.Fatal("scan.js must ship and drive the scan API")
	}
	// Every page carries the menu, so the item has to be on all of them, and
	// ahead of Diagnostics.
	for _, path := range []string{"/", "/assign", "/hosts", "/pools", "/test-sets", "/scan", "/diagnostics"} {
		body := getText(t, srv.URL+path)
		scan := strings.Index(body, `href="/scan"`)
		diag := strings.Index(body, `href="/diagnostics"`)
		if scan < 0 {
			t.Fatalf("%s has no Scan menu item", path)
		}
		if diag < 0 || scan > diag {
			t.Fatalf("%s puts Scan after Diagnostics", path)
		}
	}
}
