// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writeSquidLog writes a squid-format access log whose entries are `at` old.
// Field 1 is the epoch timestamp and field 3 the client address, which is all
// the scanners read.
func writeSquidLog(t *testing.T, clients []string, at time.Time) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "access.log")
	var b strings.Builder
	for _, ip := range clients {
		fmt.Fprintf(&b, "%d.000 100 %s TCP_MISS/200 512 GET http://example.com/ - HIER_DIRECT/93.184.216.34 text/html\n",
			at.Unix(), ip)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatalf("write squid log: %v", err)
	}
	return path
}

// The union is the whole point of the measurement: a host that never talks to
// the proxy is invisible to the log, and a host that does appears in both
// sources. Summing the two counts would report addresses the lab does not hold,
// which is the failure mode this metric exists to stop -- an inflated figure is
// how a healthy lab gets diagnosed as a draining pool.
func TestAddressesInUseUnionsHostsAndProxyWithoutDoubleCounting(t *testing.T) {
	now := time.Now()
	// .10 is shared: it proxies AND registers as a host. .11 proxies only.
	// .12 registers only -- the statically-addressed host that holds no lease.
	logPath := writeSquidLog(t, []string{"192.168.7.10", "192.168.7.11", "192.168.7.10"}, now.Add(-time.Minute))

	seen, complete := distinctClientIPs(logPath, addrScanWindow, now, addrScanMaxBytes)
	if !complete {
		t.Fatalf("scan should have covered the window")
	}
	if len(seen) != 2 {
		t.Fatalf("proxy log holds 2 distinct clients, got %d (%v)", len(seen), seen)
	}

	inUse := map[string]bool{}
	for ip := range seen {
		inUse[ip] = true
	}
	for _, ip := range []string{"192.168.7.10", "192.168.7.12"} {
		inUse[ip] = true
	}
	// 2 proxy + 2 host - 1 overlap = 3, not 4.
	if len(inUse) != 3 {
		t.Fatalf("union must dedupe the shared address: want 3, got %d (%v)", len(inUse), inUse)
	}
}

// An unreadable or absent log is a measurement that did not happen. It must not
// present as "the lab is holding zero addresses", because zero reads as an idle
// lab rather than as a broken scan.
func TestAddressesInUseReportsIncompleteWhenLogUnreadable(t *testing.T) {
	seen, complete := distinctClientIPs(filepath.Join(t.TempDir(), "absent.log"), addrScanWindow, time.Now(), addrScanMaxBytes)
	if complete {
		t.Fatalf("a log that could not be opened must not report a complete scan")
	}
	if len(seen) != 0 {
		t.Fatalf("want no addresses from an unreadable log, got %v", seen)
	}
}

// The exported help text is load-bearing: this metric was previously read as a
// pool forecast, and that reading is what sent an investigation to audit a DHCP
// server whose pool was mostly free. The gauge must say what it measured and
// must not imply a pool verdict it has no inputs for.
func TestAddressMetricsDoNotClaimAPoolVerdict(t *testing.T) {
	s := newPoolState("default", 8080)
	s.addrInUse, s.addrInUseHosts, s.addrDistinct = 7, 3, 5
	rec := httptest.NewRecorder()
	s.handleMetrics(rec, metricsRequest())
	body := rec.Body.String()
	for _, want := range []string{
		"yuruna_pool_lab_addresses_in_use 7",
		"yuruna_pool_lab_addresses_in_use_hosts 3",
		"yuruna_pool_lab_distinct_addresses_24h 5",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics body missing %q", want)
		}
	}
	for _, banned := range []string{"exhaustion", "drain"} {
		if strings.Contains(strings.ToLower(body), banned) {
			t.Errorf("metrics help must not assert a pool verdict; found %q", banned)
		}
	}
}

// A log read in full spans everything it contains, so the count is a
// measurement even when no entry is older than the window. Reporting it as a
// floor would disclaim the number permanently on any lab whose log is small
// enough to read whole -- which is every young lab and every freshly rotated
// one, i.e. exactly where an operator is most likely to be checking.
func TestFullyReadShortLogCountsAsComplete(t *testing.T) {
	now := time.Now()
	logPath := writeSquidLog(t, []string{"192.168.7.10"}, now.Add(-time.Minute))
	_, complete := distinctClientIPs(logPath, addrScanWindow, now, addrScanMaxBytes)
	if !complete {
		t.Fatalf("a log read from byte 0 holds nothing older to miss, so the scan is complete")
	}
}

// The other half of that boundary: once the read is truncated, entries below
// the seek point are genuinely unread and the count really is a floor.
func TestTruncatedReadCountsAsIncomplete(t *testing.T) {
	now := time.Now()
	many := make([]string, 0, 400)
	for i := 0; i < 400; i++ {
		many = append(many, fmt.Sprintf("192.168.7.%d", (i%200)+10))
	}
	logPath := writeSquidLog(t, many, now.Add(-time.Minute))
	// maxBytes far below the file size forces the seek.
	if _, complete := distinctClientIPs(logPath, addrScanWindow, now, 512); complete {
		t.Fatalf("a truncated read must report the count as a floor")
	}
}
