// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4228c530-1350-4797-a8f3-f7339be169e2

package hostpoll

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func serve(t *testing.T, path, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != path {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// The status read returns the body it parsed, so a reader of fields the public
// subset leaves out reads them from the same answer instead of a second request.
func TestFetchStatusReturnsTheParsedBody(t *testing.T) {
	const body = `{"hostId":"42a","overallStatus":"pass","history":[{"cycleStartUtc":"x","guestSummary":{"g":"pass"}}]}`
	srv := serve(t, "/runtime/status.json", body)
	st, raw, err := FetchStatus(srv.Client(), srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if st.HostId != "42a" || st.OverallStatus != "pass" {
		t.Fatalf("parsed %+v", st)
	}
	if string(raw) != body {
		t.Fatalf("raw body = %q", raw)
	}
	if _, _, err := FetchStatus(srv.Client(), srv.URL+"/missing"); err == nil || !strings.Contains(err.Error(), "HTTP 404") {
		t.Fatalf("a missing status.json must fail, err = %v", err)
	}
}

// A gating block keeps what was authored, so a reader can fill only the knobs
// that were absent: an authored zero is not a missing value.
func TestFetchRegistrationKeepsTheAuthoredGatingBlock(t *testing.T) {
	srv := serve(t, "/runtime/host.registration.json",
		`{"poolId":"lab","gating":{"failuresBeforeAlert":0,"quorum":{"degradedAfterSeconds":0}}}`)
	reg, err := FetchRegistration(srv.Client(), srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	g := reg.Gating
	if reg.PoolID != "lab" || g == nil {
		t.Fatalf("registration %+v", reg)
	}
	if g.FailuresBeforeAlert == nil || *g.FailuresBeforeAlert != 0 || g.DegradedAfterSeconds == nil || *g.DegradedAfterSeconds != 0 {
		t.Fatalf("authored zeros were lost: %+v", g)
	}
	if g.SuccessesBeforeRearm != nil || g.HealthyThreshold != nil {
		t.Fatalf("absent knobs must stay nil: %+v", g)
	}
	none := serve(t, "/runtime/host.registration.json", `{"poolId":""}`)
	if reg, err := FetchRegistration(none.Client(), none.URL); err != nil || reg.Gating != nil || reg.PoolID != "" {
		t.Fatalf("an unpooled host without gating: %+v, %v", reg, err)
	}
}
