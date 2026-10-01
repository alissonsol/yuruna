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

	"pool-control-service/internal/intent"
	"pool-control-service/internal/state"
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
func (f *fakeIntent) AddHost(ctx context.Context, a, b string, moveExisting ...bool) intent.Result {
	f.lastCall, f.lastArgs = "AddHost", []string{a, b}
	return f.ret
}
func (f *fakeIntent) RemoveHost(ctx context.Context, a, b string, exclude ...bool) intent.Result {
	f.lastCall, f.lastArgs = "RemoveHost", []string{a, b}
	return f.ret
}
func (f *fakeIntent) MoveHostIdentity(ctx context.Context, a, b string) intent.Result {
	f.lastCall, f.lastArgs = "MoveHostIdentity", []string{a, b}
	return f.ret
}
func (f *fakeIntent) SetPoolRepositories(ctx context.Context, a, b, c string) intent.Result {
	f.lastCall, f.lastArgs = "SetPoolRepositories", []string{a, b, c}
	return f.ret
}
func (f *fakeIntent) ClearPoolRepositories(ctx context.Context, a string) intent.Result {
	f.lastCall, f.lastArgs = "ClearPoolRepositories", []string{a}
	return f.ret
}

// testBearer stands in for the internal authentication key. Every route that rewrites
// pool configuration is gated on it, so these relay tests carry it: what they
// are about is which CLI a route invokes with which arguments, and the gate has
// its own coverage in board_test.go and in the SDK.
const testBearer = "test-internal-auth-key"

func newTestServer(f *fakeIntent) *httptest.Server {
	return httptest.NewServer(New(f, Options{Version: "test", AuthToken: testBearer}).Handler())
}

func do(t *testing.T, method, url, body string) (*http.Response, map[string]any) {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, url, rdr)
	req.Header.Set("Authorization", "Bearer "+testBearer)
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
	f := &fakeIntent{stateRes: intent.Result{OK: true, Stdout: `{"ok":true,"pools":[{"poolId":"lab"}],"autoEnrollment":{"enabled":false,"targetPoolId":"","excluded":[]}}`}}
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

// A CLI failure (e.g. a failed push) must surface to the client as a 500 with
// the error text, never a silent success: the next run's reset --hard would
// destroy intent that was committed locally but never pushed.
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

// The Pools page sends what an operator typed, so surrounding whitespace is
// trimmed before the pair reaches the CLI.
func TestSetPoolRepositoriesForwardsTrimmedPair(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: true}}
	srv := newTestServer(f)
	defer srv.Close()
	resp, m := do(t, "POST", srv.URL+"/api/pool/repositories", `{"poolId":" lab ","frameworkUrl":" https://x/f ","projectUrl":"https://x/p\t"}`)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("set repositories: got %d %v", resp.StatusCode, m)
	}
	want := []string{"lab", "https://x/f", "https://x/p"}
	if f.lastCall != "SetPoolRepositories" || strings.Join(f.lastArgs, " ") != strings.Join(want, " ") {
		t.Fatalf("set repositories forwarded %s %q, want SetPoolRepositories %q", f.lastCall, f.lastArgs, want)
	}
}

// Both boxes emptied is how an operator hands a pool back to its members' own
// repositories, and an MCP caller may simply omit both.
func TestSetPoolRepositoriesBothEmptyClears(t *testing.T) {
	for _, body := range []string{
		`{"poolId":"lab","frameworkUrl":"","projectUrl":"  "}`,
		`{"poolId":"lab"}`,
	} {
		f := &fakeIntent{ret: intent.Result{OK: true}}
		srv := newTestServer(f)
		resp, m := do(t, "POST", srv.URL+"/api/pool/repositories", body)
		srv.Close()
		if resp.StatusCode != 200 || m["ok"] != true {
			t.Fatalf("%s: got %d %v", body, resp.StatusCode, m)
		}
		if f.lastCall != "ClearPoolRepositories" || len(f.lastArgs) != 1 || f.lastArgs[0] != "lab" {
			t.Fatalf("%s: forwarded %s %q, want ClearPoolRepositories [lab]", body, f.lastCall, f.lastArgs)
		}
	}
}

// One URL alone is refused before the CLI runs: a runner overriding only one
// repository would pair a framework with a project it was never tested against.
func TestSetPoolRepositoriesRefusesOneURL(t *testing.T) {
	for _, body := range []string{
		`{"poolId":"lab","frameworkUrl":"https://x/f","projectUrl":""}`,
		`{"poolId":"lab","projectUrl":"https://x/p"}`,
	} {
		f := &fakeIntent{ret: intent.Result{OK: true}}
		srv := newTestServer(f)
		resp, m := do(t, "POST", srv.URL+"/api/pool/repositories", body)
		srv.Close()
		if resp.StatusCode != 400 || m["ok"] != false {
			t.Fatalf("%s: got %d %v, want 400", body, resp.StatusCode, m)
		}
		if f.lastCall != "" {
			t.Fatalf("%s: a refused pair must not invoke the CLI; called %s", body, f.lastCall)
		}
	}
}

// A value starting with '-' would bind as a pwsh parameter name, and
// whitespace or a control character inside a URL is a paste accident; both
// are refused with a message that names the rule instead of a bind error.
func TestSetPoolRepositoriesRefusesUnsafeURL(t *testing.T) {
	for _, body := range []string{
		`{"poolId":"lab","frameworkUrl":"https://x/f g","projectUrl":"https://x/p"}`,
		`{"poolId":"lab","frameworkUrl":"https://x/f","projectUrl":"https://x/\bp"}`,
		`{"poolId":"lab","frameworkUrl":"https://x/f","projectUrl":"https://x/p\nmore"}`,
		`{"poolId":"lab","frameworkUrl":"-IntentGitUrl","projectUrl":"https://x/p"}`,
		`{"poolId":"lab","frameworkUrl":"https://x/f","projectUrl":" -x"}`,
	} {
		f := &fakeIntent{ret: intent.Result{OK: true}}
		srv := newTestServer(f)
		resp, m := do(t, "POST", srv.URL+"/api/pool/repositories", body)
		srv.Close()
		if resp.StatusCode != 400 || m["ok"] != false {
			t.Fatalf("%s: got %d %v, want 400", body, resp.StatusCode, m)
		}
		if msg, _ := m["error"].(string); !strings.Contains(msg, "whitespace or control characters") {
			t.Fatalf("%s: error %q does not name the rule", body, msg)
		}
		if f.lastCall != "" {
			t.Fatalf("%s: an unsafe URL must not invoke the CLI; called %s", body, f.lastCall)
		}
	}
}

func TestSetPoolRepositoriesRequiresPoolID(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: true}}
	srv := newTestServer(f)
	defer srv.Close()
	resp, m := do(t, "POST", srv.URL+"/api/pool/repositories", `{"poolId":"  ","frameworkUrl":"https://x/f","projectUrl":"https://x/p"}`)
	if resp.StatusCode != 400 || m["ok"] != false {
		t.Fatalf("missing poolId must be 400; got %d %v", resp.StatusCode, m)
	}
	if f.lastCall != "" {
		t.Fatalf("validation failure must not invoke the CLI; called %s", f.lastCall)
	}
}

// Every repository write is audited under its own action name, so the audit
// log tells a set from a clear without reading the CLI output.
func TestSetPoolRepositoriesAuditsSetAndClear(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: true, Stdout: "ok"}}
	store := state.New(filepath.Join(t.TempDir(), "pc"), time.Now())
	srv := httptest.NewServer(New(f, Options{Store: store, AuthToken: testBearer}).Handler())
	defer srv.Close()
	for _, tc := range []struct{ body, action string }{
		{`{"poolId":"lab","frameworkUrl":"https://x/f","projectUrl":"https://x/p"}`, "set-repositories"},
		{`{"poolId":"lab","frameworkUrl":"","projectUrl":""}`, "clear-repositories"},
	} {
		if _, m := do(t, "POST", srv.URL+"/api/pool/repositories", tc.body); m["ok"] != true {
			t.Fatalf("%s should succeed: %v", tc.body, m)
		}
		if _, m := do(t, "GET", srv.URL+"/healthz", ""); m["lastAction"] != tc.action {
			t.Fatalf("healthz lastAction = %v, want %s", m["lastAction"], tc.action)
		}
	}
}

func TestMutationAuditsAndHealthz(t *testing.T) {
	f := &fakeIntent{ret: intent.Result{OK: true, Stdout: "ok"}}
	store := state.New(filepath.Join(t.TempDir(), "pc"), time.Now())
	srv := httptest.NewServer(New(f, Options{Store: store, AuthToken: testBearer}).Handler())
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
	for _, p := range []string{"/", "/pools", "/hosts"} {
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
