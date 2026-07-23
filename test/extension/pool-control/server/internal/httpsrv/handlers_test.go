// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pool-control/internal/intent"
	"pool-control/internal/state"
)

// fakeIntent records the last call and returns a canned Result.
type fakeIntent struct {
	stateRes intent.Result
	ret      intent.Result
	lastCall string
	lastArgs []string
}

func (f *fakeIntent) State(ctx context.Context) intent.Result {
	f.lastCall = "State"
	return f.stateRes
}
func (f *fakeIntent) NewPool(ctx context.Context, a, b, c string) intent.Result {
	f.lastCall, f.lastArgs = "NewPool", []string{a, b, c}
	return f.ret
}
func (f *fakeIntent) RemovePool(ctx context.Context, a string, force bool) intent.Result {
	f.lastCall, f.lastArgs = "RemovePool", []string{a}
	return f.ret
}
func (f *fakeIntent) SetDesiredState(ctx context.Context, a, b string) intent.Result {
	f.lastCall, f.lastArgs = "SetDesiredState", []string{a, b}
	return f.ret
}
func (f *fakeIntent) AddHost(ctx context.Context, a, b string) intent.Result {
	f.lastCall, f.lastArgs = "AddHost", []string{a, b}
	return f.ret
}
func (f *fakeIntent) RemoveHost(ctx context.Context, a, b string) intent.Result {
	f.lastCall, f.lastArgs = "RemoveHost", []string{a, b}
	return f.ret
}
func (f *fakeIntent) AssignTestSet(ctx context.Context, a, b, c, d string) intent.Result {
	f.lastCall, f.lastArgs = "AssignTestSet", []string{a, b, c, d}
	return f.ret
}
func (f *fakeIntent) SetTestSetDef(ctx context.Context, a, b, c string) intent.Result {
	f.lastCall, f.lastArgs = "SetTestSetDef", []string{a, b, c}
	return f.ret
}
func (f *fakeIntent) DeleteTestSetDef(ctx context.Context, a string) intent.Result {
	f.lastCall, f.lastArgs = "DeleteTestSetDef", []string{a}
	return f.ret
}

func newTestServer(f *fakeIntent) *httptest.Server {
	return httptest.NewServer(New(f, Options{Version: "test"}).Handler())
}

func do(t *testing.T, method, url, body string) (*http.Response, map[string]any) {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, url, rdr)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	var m map[string]any
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	_ = json.Unmarshal(b, &m)
	return resp, m
}

func TestStateRelaysCLIJson(t *testing.T) {
	f := &fakeIntent{stateRes: intent.Result{OK: true, Stdout: `{"ok":true,"pools":[{"poolId":"lab"}],"testSets":[]}`}}
	srv := newTestServer(f)
	defer srv.Close()
	resp, m := do(t, "GET", srv.URL+"/api/state", "")
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("state: got %d %v", resp.StatusCode, m)
	}
	pools, _ := m["pools"].([]any)
	if len(pools) != 1 {
		t.Fatalf("state should relay the CLI's pools array verbatim; got %v", m)
	}
}

func TestNewPoolSuccessAndArgs(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: true, Stdout: "Pool 'lab' created."}}
	srv := newTestServer(f)
	defer srv.Close()
	resp, m := do(t, "POST", srv.URL+"/api/pool", `{"poolId":"lab","displayName":"Lab","desiredState":"run"}`)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("new pool: got %d %v", resp.StatusCode, m)
	}
	if f.lastCall != "NewPool" || f.lastArgs[0] != "lab" || f.lastArgs[1] != "Lab" || f.lastArgs[2] != "run" {
		t.Fatalf("new pool forwarded wrong args: %s %v", f.lastCall, f.lastArgs)
	}
}

func TestNewPoolValidation(t *testing.T) {
	f := &fakeIntent{}
	srv := newTestServer(f)
	defer srv.Close()
	resp, m := do(t, "POST", srv.URL+"/api/pool", `{}`)
	if resp.StatusCode != 400 || m["ok"] != false {
		t.Fatalf("missing poolId must be 400; got %d %v", resp.StatusCode, m)
	}
	if f.lastCall != "" {
		t.Fatalf("validation failure must not invoke the CLI; called %s", f.lastCall)
	}
}

// The C4 discipline: a CLI failure (e.g. a failed push) surfaces to the client
// as a 500 with the error text, never a silent success.
func TestFailedPushSurfaces(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: false, Exit: 1, Error: "Committed locally but NOT pushed to the remote", Stderr: "git push failed"}}
	srv := newTestServer(f)
	defer srv.Close()
	resp, m := do(t, "POST", srv.URL+"/api/pool", `{"poolId":"lab"}`)
	if resp.StatusCode != 500 || m["ok"] != false {
		t.Fatalf("failed push must be 500 ok:false; got %d %v", resp.StatusCode, m)
	}
	if !strings.Contains(m["error"].(string), "NOT pushed") {
		t.Fatalf("error text must surface the CLI message; got %v", m["error"])
	}
}

func TestAssignForwardsTriple(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: true}}
	srv := newTestServer(f)
	defer srv.Close()
	resp, _ := do(t, "POST", srv.URL+"/api/pool/testset", `{"poolId":"lab","name":"amisad","frameworkURL":"https://x/f","projectURL":"https://x/p"}`)
	if resp.StatusCode != 200 {
		t.Fatalf("assign: got %d", resp.StatusCode)
	}
	if f.lastCall != "AssignTestSet" || f.lastArgs[2] != "https://x/f" || f.lastArgs[3] != "https://x/p" {
		t.Fatalf("assign forwarded wrong triple: %v", f.lastArgs)
	}
}

func TestMutationAuditsAndHealthz(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: true, Stdout: "ok"}}
	store := state.New(filepath.Join(t.TempDir(), "pc"), time.Now())
	srv := httptest.NewServer(New(f, Options{Store: store}).Handler())
	defer srv.Close()

	if _, m := do(t, "POST", srv.URL+"/api/pool", `{"poolId":"lab"}`); m["ok"] != true {
		t.Fatalf("new pool should succeed: %v", m)
	}
	// /healthz now reports the audited write.
	resp, m := do(t, "GET", srv.URL+"/healthz", "")
	if resp.StatusCode != 200 {
		t.Fatalf("healthz: %d", resp.StatusCode)
	}
	if w, _ := m["writes"].(float64); w != 1 {
		t.Fatalf("healthz should report 1 write; got %v", m["writes"])
	}
	if m["lastAction"] != "new-pool" {
		t.Fatalf("healthz lastAction should be new-pool; got %v", m["lastAction"])
	}
}

func TestPagesServeAndCSP(t *testing.T) {
	srv := newTestServer(&fakeIntent{})
	defer srv.Close()
	for _, p := range []string{"/", "/pools", "/test-sets"} {
		resp, err := http.Get(srv.URL + p)
		if err != nil || resp.StatusCode != 200 {
			t.Fatalf("page %s: %v %d", p, err, resp.StatusCode)
		}
		if !strings.Contains(resp.Header.Get("Content-Security-Policy"), "default-src 'none'") {
			t.Fatalf("page %s missing CSP", p)
		}
		resp.Body.Close()
	}
}
