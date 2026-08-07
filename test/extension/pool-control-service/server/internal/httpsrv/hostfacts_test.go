// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// hostFactsAggStub answers both hops handleHostFacts makes: the aggregator's
// pool-status and one host's own facts route. 42aa answers; 42bb has no
// address, which is the case that must yield a per-host error rather than
// dropping the row.
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
			_, _ = w.Write([]byte(`{"ok":true,"memoryBytes":34359738368,"cores":8,"storageTotalBytes":2199023255552,"storageFreeBytes":549755813888}`))
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
	silent, found := out.Hosts["42bb"]
	if !found {
		t.Fatalf("42bb dropped from the answer: %+v", out.Hosts)
	}
	if silent.OK || silent.Error == "" {
		t.Errorf("42bb should be not-ok with a reason, got %+v", silent)
	}
}
