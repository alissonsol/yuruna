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
	"sync/atomic"
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
	// No pool: discovery monitors a host, it does not enroll one.
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
	if !strings.Contains(page, "Scan — Yuruna Pool Control") {
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

// --- REGION: One machine with two IDs
//
// A host mints its id into its runtime directory, so a reimage or a re-clone
// leaves the same machine running under a new one. Both halves of the list can
// then carry two entries for it: the aggregator keeps each id until its own TTL
// expires, and the scan's list is keyed by id too. The tests below fix what the
// page does about that, on each half.

// rekeyAggStub answers pool-status with two ids on ONE base URL -- a machine
// that re-keyed, the id it stopped reporting still inside the aggregator's TTL
// -- plus the registration record and the facts route each id would be asked
// on. factCalls counts what actually reached the machine.
func rekeyAggStub(t *testing.T) (*httptest.Server, *int32) {
	t.Helper()
	var factCalls int32
	base := ""
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pool-status"):
			// The dead id is listed FIRST and both are named "42..." so neither
			// map order nor id order can be what decides the answer.
			_, _ = w.Write([]byte(`{"hosts":[
                {"hostId":"42dead","control":"ready","reachable":false,"lastSeenUnixMs":1000,
                 "currentIp":"192.168.7.110","baseUrl":"` + base + `/host","status":{"host":"host.windows.hyper-v"}},
                {"hostId":"42live","control":"ready","reachable":true,"lastSeenUnixMs":2000,
                 "currentIp":"192.168.7.110","baseUrl":"` + base + `/host","status":{"host":"host.windows.hyper-v"}}]}`))
		case r.URL.Path == "/host/runtime/host.registration.json":
			_, _ = w.Write([]byte(`{"hostname":"syzor202607b","hostType":"host.windows.hyper-v"}`))
		case r.URL.Path == "/host/control/host-facts":
			atomic.AddInt32(&factCalls, 1)
			_, _ = w.Write([]byte(`{"ok":true,"memoryBytes":66342330368,"cores":8,"frameworkAccess":"yurunadev"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	base = "http://" + srv.Listener.Addr().String()
	srv.Start()
	t.Cleanup(srv.Close)
	return srv, &factCalls
}

// The aggregator holds both ids, so both rows appear -- they have to, because
// the pool membership may be on either and the operator is the one who decides.
// What the page owes them is which is which: the row whose id no longer answers
// says so, and the live one is left alone.
func TestHostsMarksTheRegisteredIdThatNoLongerAnswers(t *testing.T) {
	agg, _ := rekeyAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	_, rows := hostsPayload(t, s, "")
	if got := rows["42dead"]["supersededBy"]; got != "42live" {
		t.Errorf("supersededBy = %v on the id that stopped answering, want 42live", got)
	}
	if got, ok := rows["42live"]["supersededBy"]; ok && got != "" {
		t.Errorf("the live id must not be marked superseded; got %v", got)
	}
	// The address is what makes the pair legible as one machine, so it travels
	// with the row rather than only with a discovered one.
	if got := rows["42dead"]["address"]; got != "192.168.7.110" {
		t.Errorf("address = %v, want the address both ids answer at", got)
	}
}

// Those rows are one machine, so its facts are read once and both rows carry
// the same figures. Two reads would put a needless burst on a single host and,
// sampled moments apart, would differ in free storage -- making the duplicate
// rows read as two similar machines, which is the opposite of the point.
func TestHostFactsAskARekeyedMachineOnce(t *testing.T) {
	agg, calls := rekeyAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	req := httptest.NewRequest(http.MethodGet, "/api/hosts/facts", nil)
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/hosts/facts = %d: %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Hosts map[string]struct {
			OK          bool  `json:"ok"`
			MemoryBytes int64 `json:"memoryBytes"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if n := atomic.LoadInt32(calls); n != 1 {
		t.Errorf("the machine was asked %d times, want once for both of its ids", n)
	}
	for _, id := range []string{"42dead", "42live"} {
		if !out.Hosts[id].OK || out.Hosts[id].MemoryBytes != 66342330368 {
			t.Errorf("%s: facts = %+v, want the machine's own answer", id, out.Hosts[id])
		}
	}
}

// The scan's own list is keyed by id as well, so a re-keyed host can sit in it
// twice. The store collapses that once a scan confirms the address, and the page
// applies the same two tests between discovered rows so a duplicate cannot reach
// it in the window before that happens.
func TestHostsRendersOneRowPerDiscoveredAddress(t *testing.T) {
	agg := hostsAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL, AuthToken: testBearer})

	// Written straight into the store under two keys, which is the state a
	// re-key leaves behind, and with the older sighting added last so insertion
	// order cannot be what picks the survivor.
	now := time.Now()
	s.discovered.Add(discovery.Host{
		Address: "192.168.7.49", BaseURL: "http://192.168.7.49:8080",
		HostID: "42new", Hostname: "lab-9", HostType: "windows.hyper-v",
	}, now)
	s.discovered.Add(discovery.Host{
		Address: "192.168.7.49", BaseURL: "http://192.168.7.49:8080",
		HostID: "42old", Hostname: "lab-9", HostType: "windows.hyper-v",
	}, now.Add(-48*time.Hour))

	_, rows := hostsPayload(t, s, testBearer)
	if _, dup := rows["42old"]; dup {
		t.Error("the id a discovered machine stopped reporting must not get a row of its own")
	}
	if got := rows["42new"]["address"]; got != "192.168.7.49" {
		t.Errorf("the surviving row must be the newest sighting; got %v", rows["42new"])
	}

	// Two hosts that merely could not name themselves are still two machines:
	// an empty base URL identifies nothing and must not let the first of them
	// hide the second.
	s.discovered.Add(discovery.Host{Address: "192.168.7.60"}, now)
	s.discovered.Add(discovery.Host{Address: "192.168.7.61"}, now)
	payload, _ := hostsPayload(t, s, testBearer)
	addresses := map[string]bool{}
	for _, r := range payload["hosts"].([]any) {
		row := r.(map[string]any)
		if row["discovered"] == true {
			addresses[row["address"].(string)] = true
		}
	}
	if !addresses["192.168.7.60"] || !addresses["192.168.7.61"] {
		t.Errorf("a host with no base URL must not hide another; got %v", addresses)
	}
}

// The repair: the pool membership moves to the id that answers, the retired id
// leaves the scan's list, and the operator does not have to read two 32-hex ids
// off a table and get four steps right by hand.
func TestAdoptRekeyMovesMembershipToTheLiveId(t *testing.T) {
	agg, _ := rekeyAggStub(t)
	// The dead id holds the membership; the live one is in no pool, which is
	// exactly the state that costs the pool a member.
	const doc = `{"ok":true,"autoEnrollment":{"targetPoolId":""},
      "pools":[{"poolId":"lab","poolGuid":"42l","members":["42dead"]}],"testSets":[]}`
	fake := &boardIntent{doc: doc}
	s := New(fake, Options{AggregatorURL: agg.URL, AuthToken: testBearer})
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()
	s.discovered.Add(discovery.Host{Address: "192.168.7.110", HostID: "42dead"}, time.Now())

	resp, m := do(t, "POST", srv.URL+"/api/pool/adopt-rekey", `{"oldHostId":"42dead","newHostId":"42live"}`)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("adopt-rekey: got %d %v", resp.StatusCode, m)
	}
	if m["movedToPool"] != "lab" {
		t.Errorf("movedToPool = %v, want lab", m["movedToPool"])
	}
	// Removed BEFORE the add: a host belongs to at most one pool, and adding the
	// live id while the dead one is still a member would put one machine in a
	// pool twice under two names -- the state being repaired.
	want := []string{"RemoveHost:lab:42dead", "AddHost:lab:42live"}
	if len(fake.calls) != len(want) {
		t.Fatalf("intent calls = %v, want %v", fake.calls, want)
	}
	for i, c := range want {
		if fake.calls[i] != c {
			t.Fatalf("intent calls = %v, want %v", fake.calls, want)
		}
	}
	if s.discovered.Has("42dead") {
		t.Error("the retired id must leave the monitored list too")
	}
}

// Every refusal here is protecting the same thing: this route rewrites pool
// membership from a pair of ids, and a pair that is not one machine -- or is no
// longer the current reading -- would move a live host's membership somewhere
// wrong. So the relation is re-derived from the aggregator and never taken from
// the request.
func TestAdoptRekeyRefusesAPairItCannotConfirm(t *testing.T) {
	agg, _ := rekeyAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL, AuthToken: testBearer})
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()

	cases := []struct {
		name, body string
		want       int
	}{
		{"no ids", `{}`, 400},
		{"one id", `{"oldHostId":"42dead"}`, 400},
		{"the same id twice", `{"oldHostId":"42dead","newHostId":"42dead"}`, 400},
		{"an id the aggregator does not report", `{"oldHostId":"42dead","newHostId":"42ghost"}`, 404},
		// The direction matters: the live id cannot be retired in favor of the
		// dead one, which is what a page loaded before the re-key would send.
		{"the pair the wrong way round", `{"oldHostId":"42live","newHostId":"42dead"}`, 409},
	}
	for _, c := range cases {
		resp, m := do(t, "POST", srv.URL+"/api/pool/adopt-rekey", c.body)
		if resp.StatusCode != c.want {
			t.Errorf("%s: got %d (%v), want %d", c.name, resp.StatusCode, m["error"], c.want)
		}
	}
}

// Two hosts at two addresses are two machines however alike they look, and
// merging them would take one out of its pool for good.
func TestAdoptRekeyRefusesTwoDistinctMachines(t *testing.T) {
	agg := hostsAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL, AuthToken: testBearer})
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()

	resp, m := do(t, "POST", srv.URL+"/api/pool/adopt-rekey", `{"oldHostId":"42aa","newHostId":"42bb"}`)
	if resp.StatusCode != 409 {
		t.Fatalf("two hosts on different addresses: got %d (%v), want 409", resp.StatusCode, m["error"])
	}
}
