// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pool-control-service/internal/discovery"
)

// hostFactsAggStub answers both hops handleHostFacts makes: the aggregator's
// pool-status and one host's own facts route. 42aa answers; 42bb has no
// address, which is the case that must yield a per-host error rather than
// dropping the row. /scanned is a machine the aggregator never reports, standing
// in for one only the network sweep found.
func hostFactsAggStub(t *testing.T) *httptest.Server {
	t.Helper()
	base := ""
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pool-status"):
			_, _ = w.Write([]byte(`{"hosts":[
                {"hostId":"42aa","baseUrl":"` + base + `/42aa"},
                {"hostId":"42bb","baseUrl":""}]}`))
		case r.URL.Path == "/42aa/control/host-facts":
			_, _ = w.Write([]byte(`{"ok":true,"memoryBytes":34359738368,"cores":8,"storageTotalBytes":2199023255552,"storageFreeBytes":549755813888,"frameworkAccess":"yuruna","projectAccess":"No access","frameworkUrl":"https://github.com/alissonsol/yuruna","projectUrl":"https://github.com/alius-git/private"}`))
		case strings.HasPrefix(r.URL.Path, "/scanned") && strings.HasSuffix(r.URL.Path, "/control/host-facts"):
			_, _ = w.Write([]byte(`{"ok":true,"memoryBytes":17179869184,"cores":4,"storageTotalBytes":1099511627776,"storageFreeBytes":274877906944,"frameworkAccess":"yuruna-fork","projectAccess":"amisad.dev","frameworkUrl":"file:///home/operator/git/yuruna-fork","projectUrl":"https://github.com/alius-git/amisad.dev"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	base = "http://" + srv.Listener.Addr().String()
	srv.Start()
	t.Cleanup(srv.Close)
	return srv
}

// A host that answered is relayed with its raw numbers; a host the pool has no
// address for is still a row, marked not-ok -- the page renders "unknown" from
// it, and a silent machine disappearing from the table would read as healthy.
func TestHostFactsRelayAnswersAndKeepSilentHosts(t *testing.T) {
	agg := hostFactsAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	req := httptest.NewRequest(http.MethodGet, "/api/hosts/facts", nil)
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/hosts/facts = %d: %s", rec.Code, rec.Body.String())
	}
	var out struct {
		OK    bool                    `json:"ok"`
		Hosts map[string]hostFactsRow `json:"hosts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !out.OK {
		t.Fatalf("ok = false: %s", rec.Body.String())
	}
	got, found := out.Hosts["42aa"]
	if !found || !got.OK {
		t.Fatalf("42aa missing or not ok: %+v", out.Hosts)
	}
	if got.MemoryBytes != 34359738368 || got.Cores != 8 ||
		got.StorageTotalBytes != 2199023255552 || got.StorageFreeBytes != 549755813888 {
		t.Errorf("42aa facts not relayed verbatim: %+v", got)
	}
	// The repository columns are the host's words, relayed rather than
	// interpreted: "No access" is a value the page renders, not an error to
	// turn the row into a silent host.
	if got.FrameworkAccess != "yuruna" || got.ProjectAccess != "No access" {
		t.Errorf("42aa repository access not relayed verbatim: %+v", got)
	}
	// Each name's location rides with it, so the page can link the cell. The
	// "No access" column carries one too: it is the url the host could not
	// read, which is what an operator opens to find out why.
	if got.FrameworkURL != "https://github.com/alissonsol/yuruna" ||
		got.ProjectURL != "https://github.com/alius-git/private" {
		t.Errorf("42aa repository urls not relayed verbatim: %+v", got)
	}
	silent, found := out.Hosts["42bb"]
	if !found {
		t.Fatalf("42bb dropped from the answer: %+v", out.Hosts)
	}
	if silent.OK || silent.Error == "" {
		t.Errorf("42bb should be not-ok with a reason, got %+v", silent)
	}
}

// A host the sweep found is a machine like any other: it answers the same
// hardware route on the address it was reached at, and the Hosts page has a row
// for it. Its facts arrive under the id it reported, or -- when it reported none
// -- the address, which is the only identity such a row has to be matched by.
func TestHostFactsCoversDiscoveredHosts(t *testing.T) {
	agg := hostFactsAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	s.discovered.Add(discovery.Host{
		Address: "192.168.7.9", BaseURL: agg.URL + "/scanned", HostID: "9999",
	}, time.Now())
	s.discovered.Add(discovery.Host{
		Address: "192.168.7.10", BaseURL: agg.URL + "/scanned-anon",
	}, time.Now())
	// Already the aggregator's: it must be read as a pool host, once, and not a
	// second time under some address-shaped key the page would never look up.
	s.discovered.Add(discovery.Host{
		Address: "192.168.7.11", BaseURL: agg.URL + "/42aa", HostID: "42aa",
	}, time.Now())

	req := httptest.NewRequest(http.MethodGet, "/api/hosts/facts", nil)
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/hosts/facts = %d: %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Hosts map[string]hostFactsRow `json:"hosts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}

	named, found := out.Hosts["9999"]
	if !found || !named.OK {
		t.Fatalf("a discovered host's facts must be keyed by the id it reported: %+v", out.Hosts)
	}
	if named.MemoryBytes != 17179869184 || named.Cores != 4 ||
		named.StorageTotalBytes != 1099511627776 || named.StorageFreeBytes != 274877906944 {
		t.Errorf("discovered host's facts not relayed verbatim: %+v", named)
	}
	// A discovered host belongs to no pool, so its Control column is blank --
	// but the repositories are its OWN answer, and it reports them like any
	// other machine. A blank here would read as "no repository".
	if named.FrameworkAccess != "yuruna-fork" || named.ProjectAccess != "amisad.dev" {
		t.Errorf("a discovered host must still report its repositories: %+v", named)
	}
	// A repository that is a local copy is a legitimate lab setup, and the
	// relay must not lose or rewrite the file: url that says so -- which
	// scheme a browser will follow is the page's decision, not this hop's.
	if named.FrameworkURL != "file:///home/operator/git/yuruna-fork" ||
		named.ProjectURL != "https://github.com/alius-git/amisad.dev" {
		t.Errorf("a discovered host's repository urls must relay unchanged: %+v", named)
	}
	byAddress, found := out.Hosts["192.168.7.10"]
	if !found || !byAddress.OK {
		t.Fatalf("an id-less host's facts must be keyed by its address: %+v", out.Hosts)
	}
	if _, dup := out.Hosts["192.168.7.11"]; dup {
		t.Errorf("a host that is both discovered and registered must be keyed once, by id: %+v", out.Hosts)
	}
}
