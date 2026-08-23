// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package discovery

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// A scan is only worth trusting if it refuses the ranges it cannot honestly
// walk. The size cap matters more than the syntax check: a mistyped prefix is
// syntactically perfect and would put millions of connection attempts onto the
// lab network.
func TestParseCIDR(t *testing.T) {
	ok := []struct{ in, want string }{
		{"192.168.7.0/24", "192.168.7.0/24"},
		// An operator has their own address to hand, not the network address.
		{"192.168.7.34/24", "192.168.7.0/24"},
		{" 10.0.0.0/28 ", "10.0.0.0/28"},
		{"10.1.2.3/32", "10.1.2.3/32"},
		{"192.168.7.0/20", "192.168.0.0/20"}, // exactly at the cap
	}
	for _, c := range ok {
		got, err := ParseCIDR(c.in)
		if err != nil {
			t.Fatalf("ParseCIDR(%q): %v", c.in, err)
		}
		if got.String() != c.want {
			t.Fatalf("ParseCIDR(%q) = %s, want %s", c.in, got, c.want)
		}
	}

	bad := []string{
		"",
		"192.168.7.0",      // no prefix length
		"192.168.7.0/33",   // not a v4 prefix length
		"not-a-network/24", //
		"192.168.7.0/19",   // one bit past the cap
		"10.0.0.0/8",       // the mistype the cap exists for
		"2001:db8::/120",   // v6
		"192.168.7.0/24 x", // trailing junk
		"192.168.7.256/24", // not an address
	}
	for _, in := range bad {
		if _, err := ParseCIDR(in); err == nil {
			t.Fatalf("ParseCIDR(%q) accepted a range it should refuse", in)
		}
	}

	// The refusal has to be actionable: it names the narrower prefix that would
	// be accepted, because "too big" alone leaves the operator guessing.
	_, err := ParseCIDR("10.0.0.0/8")
	if err == nil || !strings.Contains(err.Error(), "/20") {
		t.Fatalf("over-size refusal should name the narrowest allowed prefix, got %v", err)
	}
}

// The network and broadcast addresses are not machines; probing them is two
// guaranteed timeouts on every sweep of every /24 in the lab.
func TestAddresses(t *testing.T) {
	p, err := ParseCIDR("192.168.7.0/24")
	if err != nil {
		t.Fatal(err)
	}
	got := Addresses(p)
	if len(got) != 254 {
		t.Fatalf("a /24 yielded %d host addresses, want 254", len(got))
	}
	if got[0] != "192.168.7.1" || got[len(got)-1] != "192.168.7.254" {
		t.Fatalf("a /24 spans %s..%s, want .1...254", got[0], got[len(got)-1])
	}

	// /31 and /32 have no network/broadcast pair to set aside (RFC 3021 and a
	// single host), so every address in them is a host to probe.
	p31, _ := ParseCIDR("10.0.0.0/31")
	if got := Addresses(p31); len(got) != 2 {
		t.Fatalf("a /31 yielded %v, want both addresses", got)
	}
	p32, _ := ParseCIDR("10.0.0.5/32")
	if got := Addresses(p32); len(got) != 1 || got[0] != "10.0.0.5" {
		t.Fatalf("a /32 yielded %v, want just the host", got)
	}
}

// The store is what makes "already present" mean something across restarts, so
// re-adding must be idempotent and the file must round-trip.
func TestStoreAddPersistReload(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "discovered-hosts.json")
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)

	s := NewStore(path)
	h := Host{Address: "192.168.7.5", BaseURL: "http://192.168.7.5:8080", HostID: "abc", Hostname: "lab-1", FoundBy: "scan"}
	if !s.Add(h, now) {
		t.Fatal("the first sighting of a host must report as new")
	}
	if s.Add(h, now.Add(time.Minute)) {
		t.Fatal("a second sighting of the same host must NOT report as new")
	}
	if len(s.List()) != 1 {
		t.Fatalf("store holds %d hosts, want 1", len(s.List()))
	}
	// The later sighting moves last-seen and leaves first-seen where it was:
	// how long a host has been known is the fact an operator reads.
	got := s.List()[0]
	if got.FirstSeenUTC != now.Format(time.RFC3339) {
		t.Fatalf("firstSeen = %q, want the original sighting", got.FirstSeenUTC)
	}
	if got.LastSeenUTC != now.Add(time.Minute).Format(time.RFC3339) {
		t.Fatalf("lastSeen = %q, want the latest sighting", got.LastSeenUTC)
	}

	// A host that could not name itself last time and can now is the same
	// machine describing itself better, not a second machine -- but it is keyed
	// by address until it does, so it lands as its own entry. Both must survive
	// a reload.
	if !s.Add(Host{Address: "192.168.7.6", BaseURL: "http://192.168.7.6:8080"}, now) {
		t.Fatal("an id-less host must still be recorded")
	}
	if s.LastError() != "" {
		t.Fatalf("store reported a persistence failure: %s", s.LastError())
	}

	reloaded := NewStore(path)
	if len(reloaded.List()) != 2 {
		t.Fatalf("reloaded store holds %d hosts, want 2", len(reloaded.List()))
	}
	if !reloaded.Has("abc") || !reloaded.Has("192.168.7.6") {
		t.Fatalf("reloaded store lost a key: %+v", reloaded.List())
	}
	if reloaded.Add(Host{Address: "192.168.7.5", HostID: "abc"}, now) {
		t.Fatal("a host already in the loaded file must not report as new")
	}

	// Forget is the way out for a retired machine.
	if !reloaded.Forget("abc") || reloaded.Has("abc") {
		t.Fatal("Forget must drop the host")
	}
	if reloaded.Forget("abc") {
		t.Fatal("forgetting an absent host must report false")
	}
}

// No state dir is the host-side launcher's normal case; it must degrade to
// memory rather than fail.
func TestStoreWithoutPath(t *testing.T) {
	s := NewStore("")
	if !s.Add(Host{Address: "10.0.0.1"}, time.Now()) {
		t.Fatal("a memory-only store must still record")
	}
	if len(s.List()) != 1 || s.LastError() != "" {
		t.Fatalf("memory-only store misbehaved: %v / %q", s.List(), s.LastError())
	}
}

// An unreadable cache must not take the service down: it can rebuild the list
// by scanning, which is the whole point of the feature.
func TestStoreCorruptFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "discovered-hosts.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := NewStore(path)
	if len(s.List()) != 0 {
		t.Fatal("a corrupt file must load as an empty list")
	}
	if s.LastError() == "" {
		t.Fatal("a corrupt file must be reported, not silently swallowed")
	}
}

// The end-to-end shape of a run: only Yuruna hosts are recorded, only additions
// are listed, and a host another registry already monitors is counted rather
// than added.
func TestEngineScan(t *testing.T) {
	store := NewStore("")
	// Pre-existing: this daemon already knows .5 from an earlier run.
	store.Add(Host{Address: "192.168.7.5", HostID: "already-here"}, time.Now())

	probe := func(_ context.Context, ip string) (Host, bool) {
		switch ip {
		case "192.168.7.5":
			return Host{HostID: "already-here"}, true
		case "192.168.7.6":
			return Host{HostID: "fresh", Hostname: "lab-6"}, true
		case "192.168.7.7":
			return Host{HostID: "in-the-pool"}, true
		case "192.168.7.8":
			return Host{}, true // a Yuruna host that would not name itself
		}
		return Host{}, false
	}
	known := func(context.Context) map[string]struct{} {
		return map[string]struct{}{"in-the-pool": {}}
	}

	e := NewEngine(store, probe, known)
	if _, err := e.Start(context.Background(), "192.168.7.0/24", "scan"); err != nil {
		t.Fatal(err)
	}
	p := waitForScan(t, e)

	if p.Total != 254 || p.Done != 254 {
		t.Fatalf("scan covered %d/%d, want 254/254", p.Done, p.Total)
	}
	// .6 and .8 are the additions; .5 was already stored and .7 is monitored
	// elsewhere, so neither is news.
	if len(p.Found) != 2 {
		t.Fatalf("found %+v, want exactly the two additions", p.Found)
	}
	byKey := map[string]bool{}
	for _, h := range p.Found {
		byKey[h.Key()] = true
	}
	if !byKey["fresh"] || !byKey["192.168.7.8"] {
		t.Fatalf("additions were %v, want the fresh host and the id-less one", byKey)
	}
	if p.AlreadyMonitored != 2 {
		t.Fatalf("alreadyMonitored = %d, want 2 (one stored here, one in the pool)", p.AlreadyMonitored)
	}
	if len(store.List()) != 3 {
		t.Fatalf("store holds %d, want 3 (the pool's host is not this list's business)", len(store.List()))
	}
	if p.Running || p.FinishedUTC == "" {
		t.Fatalf("a finished scan must say so: %+v", p)
	}
	// The page shows the sweep moving; the tail is bounded so the poll cannot
	// turn into a log shipper.
	if len(p.Recent) == 0 || len(p.Recent) > recentAddresses {
		t.Fatalf("recent = %d addresses, want 1..%d", len(p.Recent), recentAddresses)
	}
}

// Two scans at once would double the traffic to say the same thing, and the
// progress the page polls has one current answer.
func TestEngineRefusesConcurrentScan(t *testing.T) {
	release := make(chan struct{})
	probe := func(_ context.Context, _ string) (Host, bool) {
		<-release
		return Host{}, false
	}
	e := NewEngine(NewStore(""), probe, nil)
	if _, err := e.Start(context.Background(), "192.168.7.0/30", "scan"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Start(context.Background(), "192.168.7.0/30", "scan"); err != ErrScanning {
		t.Fatalf("second Start = %v, want ErrScanning", err)
	}
	close(release)
	waitForScan(t, e)
}

// A bad range must be refused before anything is scanned -- and must leave the
// engine free, not stuck reporting a run that never began.
func TestEngineRejectsBadCIDR(t *testing.T) {
	e := NewEngine(NewStore(""), func(context.Context, string) (Host, bool) { return Host{}, false }, nil)
	if _, err := e.Start(context.Background(), "10.0.0.0/8", "scan"); err == nil {
		t.Fatal("an over-size range must be refused")
	}
	if e.Running() {
		t.Fatal("a refused range must leave the engine idle")
	}
}

// The prober is the definition of "a Yuruna host": a 200 is not enough, the
// service must name itself, and the identity comes from the host's own record.
func TestHTTPProber(t *testing.T) {
	yuruna := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case livecheckPath:
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "service": statusServiceName})
		case registrationPath:
			_ = json.NewEncoder(w).Encode(map[string]any{
				"hostId": "42", "hostname": "lab-1", "hostType": "host.ubuntu.kvm",
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer yuruna.Close()

	// Same port, same 200, different service: the value check is what keeps a
	// neighboring web server out of the pool's host list.
	impostor := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "service": "something-else"})
	}))
	defer impostor.Close()

	// A host that answers /livecheck but not its registration record is still a
	// host: it is recorded by address, with no id.
	nameless := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == livecheckPath {
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "service": statusServiceName})
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer nameless.Close()

	probeAt := func(ts *httptest.Server) (Host, bool) {
		u, err := url.Parse(ts.URL)
		if err != nil {
			t.Fatal(err)
		}
		port, err := strconv.Atoi(u.Port())
		if err != nil {
			t.Fatal(err)
		}
		return NewHTTPProber(port)(context.Background(), u.Hostname())
	}

	got, ok := probeAt(yuruna)
	if !ok {
		t.Fatal("a status service must be recognized")
	}
	if got.HostID != "42" || got.Hostname != "lab-1" || got.HostType != "ubuntu.kvm" {
		t.Fatalf("probe returned %+v, want the host's own identity with the host. prefix dropped", got)
	}
	if !strings.HasPrefix(got.BaseURL, "http://") {
		t.Fatalf("baseUrl = %q, want a browsable status-service base", got.BaseURL)
	}

	if _, ok := probeAt(impostor); ok {
		t.Fatal("a 200 from another service must NOT count as a Yuruna host")
	}

	got, ok = probeAt(nameless)
	if !ok || got.HostID != "" {
		t.Fatalf("a host with an unreadable registration must still be found, id-less: %+v / %v", got, ok)
	}

	// Nothing listening at all is the common case on a /24 and must simply be
	// "not a host" rather than an error the scan has to handle.
	if _, ok := NewHTTPProber(1)(context.Background(), "127.0.0.1"); ok {
		t.Fatal("a closed port must not be reported as a host")
	}
}

// waitForScan blocks until the engine is idle, so a test asserts on a finished
// run rather than racing it.
func waitForScan(t *testing.T, e *Engine) Progress {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if !e.Running() {
			return e.Progress()
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("scan did not finish within the test's budget")
	return Progress{}
}
