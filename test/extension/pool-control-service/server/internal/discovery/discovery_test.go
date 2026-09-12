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

// One address:port holds one status service, so two entries claiming it are one
// machine under two names -- and keeping both is what made a reimaged host
// occupy a row for every id it has ever had.
func TestStoreSupersedesAnOlderEntryAtOneBaseURL(t *testing.T) {
	s := NewStore("")
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	const base = "http://192.168.7.49:8080"

	// A sighting that could not read the host's id, so it is known only by the
	// address it answered on.
	s.Add(Host{Address: "192.168.7.49", BaseURL: base}, t0)
	// Then the same machine, naming itself.
	s.Add(Host{Address: "192.168.7.49", BaseURL: base, HostID: "42old", Hostname: "lab-9"}, t0.Add(time.Hour))

	list := s.List()
	if len(list) != 1 || list[0].HostID != "42old" {
		t.Fatalf("an id-less sighting must be subsumed by the same address naming itself; got %+v", list)
	}
	// Its history belongs to the machine, not to the id: the entry that lost was
	// this same host before it could name itself.
	if list[0].FirstSeenUTC != t0.Format(time.RFC3339) {
		t.Errorf("first-seen = %q, want the id-less sighting's %q carried forward",
			list[0].FirstSeenUTC, t0.Format(time.RFC3339))
	}

	// A reimage re-keys the host: same machine, same address, same name, new id.
	s.Add(Host{Address: "192.168.7.49", BaseURL: base, HostID: "42new", Hostname: "lab-9"}, t0.Add(2*time.Hour))
	list = s.List()
	if len(list) != 1 || list[0].HostID != "42new" {
		t.Fatalf("a re-keyed host must render once, under the id it reports now; got %+v", list)
	}
	if list[0].FirstSeenUTC != t0.Format(time.RFC3339) {
		t.Errorf("first-seen = %q, want the machine's own %q", list[0].FirstSeenUTC, t0.Format(time.RFC3339))
	}
	if s.Has("42old") {
		t.Error("the id the machine stopped reporting must leave the list")
	}
}

// An address handed to a DIFFERENT machine is not a re-key, and the newcomer
// must not inherit a history that is not its own.
func TestStoreDoesNotGiveAReusedAddressTheOldHostsHistory(t *testing.T) {
	s := NewStore("")
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	const base = "http://192.168.7.49:8080"

	s.Add(Host{Address: "192.168.7.49", BaseURL: base, HostID: "42one", Hostname: "lab-one"}, t0)
	later := t0.Add(48 * time.Hour)
	s.Add(Host{Address: "192.168.7.49", BaseURL: base, HostID: "42two", Hostname: "lab-two"}, later)

	list := s.List()
	if len(list) != 1 || list[0].HostID != "42two" {
		t.Fatalf("the address must resolve to whatever answers there now; got %+v", list)
	}
	if list[0].FirstSeenUTC != later.Format(time.RFC3339) {
		t.Errorf("first-seen = %q, want this host's own %q -- a different machine's history is not its own",
			list[0].FirstSeenUTC, later.Format(time.RFC3339))
	}
}

// A host that answers on two addresses (a second NIC, wired and wireless) is
// still one entry: it is keyed by the id it reports, and the address it is shown
// at is simply the one most recently confirmed.
func TestStoreKeepsAMultiHomedHostAsOneEntry(t *testing.T) {
	s := NewStore("")
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	s.Add(Host{Address: "192.168.7.46", BaseURL: "http://192.168.7.46:8080", HostID: "42af", Hostname: "mac-a"}, now)
	s.Add(Host{Address: "192.168.7.152", BaseURL: "http://192.168.7.152:8080", HostID: "42af", Hostname: "mac-a"}, now.Add(time.Second))

	list := s.List()
	if len(list) != 1 || list[0].Address != "192.168.7.152" {
		t.Fatalf("one host on two addresses must be one entry at the last confirmed address; got %+v", list)
	}
}

// A machine that re-keyed and then went off the network leaves both ids behind,
// and no future sighting will ever tidy them. Loading the list is the other
// chance to notice, and it fixes the file rather than the render.
func TestStoreCollapsesDuplicatesOnLoad(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "discovered-hosts.json")
	const doc = `[
      {"address":"192.168.7.49","baseUrl":"http://192.168.7.49:8080","hostId":"42old","hostname":"lab-9",
       "firstSeenUtc":"2026-09-02T15:30:00Z","lastSeenUtc":"2026-09-07T20:43:00Z"},
      {"address":"192.168.7.49","baseUrl":"http://192.168.7.49:8080","hostId":"42new","hostname":"lab-9",
       "firstSeenUtc":"2026-09-08T22:02:00Z","lastSeenUtc":"2026-09-09T02:32:00Z"},
      {"address":"192.168.7.50","baseUrl":"http://192.168.7.50:8080","hostId":"42other",
       "firstSeenUtc":"2026-09-08T22:02:00Z","lastSeenUtc":"2026-09-09T02:32:00Z"}]`
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}

	list := NewStore(path).List()
	if len(list) != 2 {
		t.Fatalf("a stored duplicate must collapse at load; got %d entries: %+v", len(list), list)
	}
	if list[0].HostID != "42new" {
		t.Errorf("the survivor must be the newest sighting; got %q", list[0].HostID)
	}
	if list[0].FirstSeenUTC != "2026-09-02T15:30:00Z" {
		t.Errorf("first-seen = %q, want the machine's earliest sighting", list[0].FirstSeenUTC)
	}
	// And the repair is written back, so it does not have to be redone on every
	// start for a machine that never answers again.
	reloaded := NewStore(path).List()
	if len(reloaded) != 2 {
		t.Fatalf("the collapsed list must be persisted; got %d entries", len(reloaded))
	}
}

// The list is a monitored set, so a host that has gone quiet stays -- but not
// forever: a machine retired last month hides the one that went quiet today.
func TestPruneExpiresOnlyWhatIsPastTheTTL(t *testing.T) {
	s := NewStore("")
	now := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	s.Add(Host{Address: "192.168.7.13", BaseURL: "http://192.168.7.13:8080"}, now.Add(-26*24*time.Hour))
	s.Add(Host{Address: "192.168.7.49", BaseURL: "http://192.168.7.49:8080", HostID: "42new"}, now.Add(-2*24*time.Hour))
	s.Add(Host{Address: "192.168.7.50", BaseURL: "http://192.168.7.50:8080", HostID: "42live"}, now)

	if removed := s.Prune(now, 14*24*time.Hour); removed != 1 {
		t.Fatalf("Prune removed %d, want only the entry past the TTL", removed)
	}
	if s.Has("192.168.7.13") {
		t.Error("an address unseen for 26 days must expire")
	}
	if !s.Has("42new") || !s.Has("42live") {
		t.Error("a host seen inside the TTL must stay on the monitored list")
	}

	// Zero or negative keeps everything: a lab that would rather read past a
	// stale row than lose one has to be able to say so.
	if removed := s.Prune(now, 0); removed != 0 {
		t.Errorf("Prune with no TTL removed %d, want 0", removed)
	}
	if removed := s.Prune(now, -time.Hour); removed != 0 {
		t.Errorf("Prune with a negative TTL removed %d, want 0", removed)
	}
}

// Two entries on one address is the duplicate case, and a consumer that keeps
// the first one it sees per address -- the Hosts table and the facts fan-out
// both do -- must be handed the same one every time. Go's sort is not stable,
// so the comparator has to be a total order rather than address alone.
func TestListOrderIsTotalSoOneEntryPerAddressAlwaysWins(t *testing.T) {
	now := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	// Distinct base URLs, so nothing is collapsed and both survive to be sorted.
	build := func() *Store {
		s := NewStore("")
		s.Add(Host{Address: "192.168.7.49", BaseURL: "http://192.168.7.49:8080", HostID: "42old"}, now.Add(-time.Hour))
		s.Add(Host{Address: "192.168.7.49", BaseURL: "http://192.168.7.49:9090", HostID: "42new"}, now)
		return s
	}
	for i := 0; i < 25; i++ {
		list := build().List()
		if len(list) != 2 {
			t.Fatalf("both entries must survive: %+v", list)
		}
		if list[0].HostID != "42new" {
			t.Fatalf("run %d put %q first; the newest sighting must always lead", i, list[0].HostID)
		}
	}
}
