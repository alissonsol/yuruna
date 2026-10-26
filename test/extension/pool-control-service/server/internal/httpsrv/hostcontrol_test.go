// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4257dc18-6ee2-4794-bad3-d13258f8dcbc

package httpsrv

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"pool-control-service/internal/configuration"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/state"

	"yuruna.com/test/extension/extension-sdk/controlproof"
)

// Pool-wide host control. What a wrong implementation gets subtly wrong: it
// drives hosts the aggregator labels with this pool rather than the pool's
// MEMBERS, it reports a pool as settled when a member never answered, it lets
// one refusing host swallow the whole fan-out, and it sends control calls a
// host cannot verify.

// ctlHost is one member's status service: it records the control routes it was
// driven on and serves the status.json the read side maps.
type ctlHost struct {
	mu     sync.Mutex
	calls  []string
	proofs []string
	status int
	body   string
	doc    string
	srv    *httptest.Server
}

func newCtlHost(t *testing.T, doc string) *ctlHost {
	t.Helper()
	h := &ctlHost{status: http.StatusOK, body: `{"ok":true}`, doc: doc}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/runtime/status.json" {
			h.mu.Lock()
			doc := h.doc
			h.mu.Unlock()
			if doc == "" {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte(doc))
			return
		}
		h.mu.Lock()
		h.calls = append(h.calls, strings.TrimPrefix(r.URL.Path, "/control/"))
		h.proofs = append(h.proofs, r.Header.Get("X-Yuruna-Control"))
		status, body := h.status, h.body
		h.mu.Unlock()
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *ctlHost) recorded() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.calls...)
}

func (h *ctlHost) lastProof() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.proofs) == 0 {
		return ""
	}
	return h.proofs[len(h.proofs)-1]
}

// ctlAggregator serves pool-status for the given hostId -> baseUrl map, and
// optionally the /go/host redirect the proof fallback reads.
func ctlAggregator(t *testing.T, addr map[string]string, fallbackProof string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pool-status"):
			hosts := make([]map[string]any, 0, len(addr))
			for id, base := range addr {
				hosts = append(hosts, map[string]any{"hostId": id, "baseUrl": base, "control": "ready"})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"hosts": hosts})
		case r.URL.Path == "/go/host":
			if fallbackProof == "" {
				http.Redirect(w, r, "http://192.0.2.9:8080", http.StatusFound)
				return
			}
			http.Redirect(w, r, "http://192.0.2.9:8080#yctl="+fallbackProof, http.StatusFound)
		case r.URL.Path == "/api/v1/lab-token":
			// The gate validates an operator's dashboard code here; the tests
			// that arrive on a session rather than the bearer need it to answer.
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// ctlConfiguration is two pools: "lab" with two members, "solo" with one, plus a host
// in no pool at all.
func ctlConfiguration(members ...string) *fakeConfiguration {
	quoted := make([]string, 0, len(members))
	for _, m := range members {
		quoted = append(quoted, `"`+m+`"`)
	}
	doc := `{"ok":true,"pools":[{"poolId":"lab","poolGuid":"42l","members":[` + strings.Join(quoted, ",") + `]},
	         {"poolId":"empty","poolGuid":"42e","members":[]}]}`
	return &fakeConfiguration{stateRes: configuration.Result{OK: true, Stdout: doc}}
}

func ctlServer(t *testing.T, f *fakeConfiguration, aggURL, token string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(New(f, Options{AggregatorURL: aggURL, AuthToken: token}).Handler())
	t.Cleanup(srv.Close)
	return srv
}

// sessionCookieFor unlocks a server the way an operator does: exchange the
// dashboard's rotating code for a session. It is how the tests reach a route on
// a credential that is NOT the bearer.
func sessionCookieFor(t *testing.T, baseURL string) *http.Cookie {
	t.Helper()
	resp, err := http.Post(baseURL+"/api/login", "application/json", strings.NewReader(`{"labToken":"abc123"}`))
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login: HTTP %d", resp.StatusCode)
	}
	for _, c := range resp.Cookies() {
		if c.Name == sessionCookie {
			return c
		}
	}
	t.Fatal("login set no session cookie")
	return nil
}

func hostRows(t *testing.T, m map[string]any) map[string]map[string]any {
	t.Helper()
	out := map[string]map[string]any{}
	rows, _ := m["hosts"].([]any)
	for _, r := range rows {
		row := r.(map[string]any)
		out[row["hostId"].(string)] = row
	}
	return out
}

// Every member is driven, and each is left with exactly one switch armed. A
// pool-wide call that only set the named flag would leave a host that had been
// armed both ways in a state the selector cannot name.
func TestApplyDrivesEveryMember(t *testing.T) {
	a, b := newCtlHost(t, ""), newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": a.srv.URL, "42bb": b.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa", "42bb"), agg.URL, testBearer)

	resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"pause-after-cycle"}`)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("apply: %d %v", resp.StatusCode, m)
	}
	if applied, _ := m["applied"].(float64); applied != 2 {
		t.Fatalf("applied = %v, want 2 (%v)", m["applied"], m)
	}
	for name, h := range map[string]*ctlHost{"42aa": a, "42bb": b} {
		if got := strings.Join(h.recorded(), ","); got != "cycle-pause,step-resume" {
			t.Errorf("%s driven on %q, want cycle-pause,step-resume", name, got)
		}
	}
}

// The proof presented to a host is the one this service's own internal authentication key
// mints. Sending anything else is a 403 per member, which reads like a lab of
// unenrolled hosts rather than one misconfigured service.
func TestApplyPresentsAProofFromTheServiceToken(t *testing.T) {
	h := newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)

	if _, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`); m["ok"] != true {
		t.Fatalf("apply: %v", m)
	}
	wire := h.lastProof()
	expiry, _, found := strings.Cut(wire, ".")
	if !found {
		t.Fatalf("proof %q is not <expiry>.<host>.<hmac>", wire)
	}
	exp, err := strconv.ParseInt(expiry, 10, 64)
	if err != nil {
		t.Fatalf("proof expiry %q: %v", expiry, err)
	}
	if want := controlproof.ProofForScope(testBearer, "42aa", hostctl.ScopePause, exp); wire != want {
		t.Errorf("proof = %q, want one signed by this service's token for this host's pause routes (%q)", wire, want)
	}
	if exp <= time.Now().Unix() {
		t.Errorf("proof expiry %d is already past", exp)
	}
}

// One member refusing must not cost the others their change: a pool always has
// the host that was never enrolled, and pausing the rest of the lab is still
// the right outcome.
func TestApplyReportsEachMemberSeparately(t *testing.T) {
	ok, refusing := newCtlHost(t, ""), newCtlHost(t, "")
	refusing.status = http.StatusForbidden
	refusing.body = `{"ok":false,"reason":"host-token-missing","error":"follow guidance at https://yuruna.link/42185271-0007"}`
	// 42cc is a member the aggregator has no address for at all.
	agg := ctlAggregator(t, map[string]string{"42aa": ok.srv.URL, "42bb": refusing.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa", "42bb", "42cc"), agg.URL, testBearer)

	resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"pause-after-step"}`)
	if resp.StatusCode != 200 {
		t.Fatalf("a partial fan-out must still be 200; got %d %v", resp.StatusCode, m)
	}
	if applied, _ := m["applied"].(float64); applied != 1 {
		t.Errorf("applied = %v, want 1", m["applied"])
	}
	if failed, _ := m["failed"].(float64); failed != 2 {
		t.Errorf("failed = %v, want 2", m["failed"])
	}
	rows := hostRows(t, m)
	if rows["42aa"]["ok"] != true {
		t.Errorf("the reachable host was not applied: %v", rows["42aa"])
	}
	if detail, _ := rows["42bb"]["error"].(string); !strings.Contains(detail, "Set-LabToken") {
		t.Errorf("the refusing host does not name its fix: %v", rows["42bb"])
	}
	if detail, _ := rows["42cc"]["error"].(string); !strings.Contains(detail, "no address") {
		t.Errorf("the unlocatable host does not say so: %v", rows["42cc"])
	}
	if got := strings.Join(ok.recorded(), ","); got != "step-pause,cycle-resume" {
		t.Errorf("healthy host driven on %q", got)
	}
}

// Membership comes from the configuration store, never from the aggregator: its notion
// of a pool is a label a host self-advertises, so driving by that would reach
// machines that merely claim the name.
func TestApplyDrivesMembersNotAdvertisers(t *testing.T) {
	member, stranger := newCtlHost(t, ""), newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": member.srv.URL, "42no": stranger.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)

	if _, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`); m["ok"] != true {
		t.Fatalf("apply: %v", m)
	}
	if got := stranger.recorded(); len(got) != 0 {
		t.Fatalf("a non-member was driven: %v", got)
	}
	if got := member.recorded(); len(got) == 0 {
		t.Fatal("the member was not driven")
	}
}

// A service with no internal authentication key of its own asks the aggregator for the same
// proof a browser gets from a dashboard host link. Nothing bakes that token
// file into a service VM, so without this the feature would be unusable on a
// lab that never placed one by hand.
func TestApplyFallsBackToTheAggregatorForAProof(t *testing.T) {
	h := newCtlHost(t, "")
	const minted = "1900000000.aggregator-minted="
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, minted)
	// No AuthToken: the bearer route into the gate is closed too, so this call
	// arrives on a lab-token session instead.
	srv := httptest.NewServer(New(ctlConfiguration("42aa"), Options{AggregatorURL: agg.URL}).Handler())
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/api/pool/host-control", strings.NewReader(`{"poolId":"lab","action":"continue"}`))
	req.AddCookie(sessionCookieFor(t, srv.URL))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	defer resp.Body.Close()
	var m map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&m)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("apply: %d %v", resp.StatusCode, m)
	}
	if got := h.lastProof(); got != minted {
		t.Errorf("proof = %q, want the aggregator's %q", got, minted)
	}
}

// With neither a token nor an aggregator that mints one, the call is refused
// once with the file to go and look at -- not sent to every member to collect
// one 403 each.
func TestApplyWithoutAnyProofRefusesOnce(t *testing.T) {
	h := newCtlHost(t, "")
	// No token here and none at the aggregator either: its /go/host redirect
	// carries no fragment, which is what a lab with no internal authentication key looks like.
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := httptest.NewServer(New(ctlConfiguration("42aa"), Options{AggregatorURL: agg.URL}).Handler())
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/api/pool/host-control", strings.NewReader(`{"poolId":"lab","action":"continue"}`))
	req.AddCookie(sessionCookieFor(t, srv.URL))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	defer resp.Body.Close()
	var m map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&m)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 (%v)", resp.StatusCode, m)
	}
	if msg, _ := m["error"].(string); !strings.Contains(msg, "/etc/yuruna/internal-auth.key") {
		t.Errorf("error %q does not name the token file", msg)
	}
	if got := h.recorded(); len(got) != 0 {
		t.Errorf("hosts were driven with no proof: %v", got)
	}
}

// Bad requests are refused before anything is driven.
func TestApplyValidatesItsRequest(t *testing.T) {
	h := newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)

	cases := []struct {
		body string
		want int
	}{
		{`{"action":"continue"}`, http.StatusBadRequest},
		{`{"poolId":"lab"}`, http.StatusBadRequest},
		// The configuration store's vocabulary is a different mechanism, and silently
		// accepting it would look like it had done something.
		{`{"poolId":"lab","action":"paused"}`, http.StatusBadRequest},
		{`{"poolId":"lab","action":"drain"}`, http.StatusBadRequest},
		{`{"poolId":"nope","action":"continue"}`, http.StatusNotFound},
	}
	for _, c := range cases {
		resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", c.body)
		if resp.StatusCode != c.want {
			t.Errorf("%s = %d, want %d (%v)", c.body, resp.StatusCode, c.want, m)
		}
	}
	if got := h.recorded(); len(got) != 0 {
		t.Errorf("a rejected request still drove hosts: %v", got)
	}
}

// A refresh belongs to a single explicitly authorized host, never to this
// pool-wide fan-out: it is the typed per-host hostctl.Refresh method behind
// its own credential gate, and never a hostctl.KnownAction. KnownAction
// ("refresh") is false, so this would 400 either way -- the point of asserting
// the SPECIFIC message is to fail this test if the independent check is ever
// deleted in favor of relying on that list, which a later action could change.
func TestApplyRefusesRefreshOverHTTPRegardlessOfKnownAction(t *testing.T) {
	h := newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)

	resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"refresh"}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d (%v)", resp.StatusCode, http.StatusBadRequest, m)
	}
	if !strings.Contains(fmt.Sprint(m["error"]), "not available through pool-wide control") {
		t.Errorf("error = %v, want it to name pool-wide refresh specifically", m["error"])
	}
	if got := h.recorded(); len(got) != 0 {
		t.Errorf("a refused refresh still drove hosts: %v", got)
	}
}

// The MCP pool_control_set_host_control tool dispatches to the exact same
// handler as the HTTP route (mcp.go wires both through
// mcp.FromRouteWithBody(s.handleHostControlApply, ...)), and the SDK does not
// validate a tool's InputSchema at call time -- so the refusal has to live in
// the handler itself to cover both entry points, and this test drives the MCP
// path directly rather than trusting that the HTTP-path test above implies it.
func TestApplyRefusesRefreshOverMCPRegardlessOfKnownAction(t *testing.T) {
	h := newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := New(ctlConfiguration("42aa"), Options{AggregatorURL: agg.URL, AuthToken: testBearer})

	tool, ok := srv.mcpRegistry().Get("pool_control_set_host_control")
	if !ok {
		t.Fatal("pool_control_set_host_control not registered")
	}
	_, err := tool.Handler(context.Background(), json.RawMessage(`{"poolId":"lab","action":"refresh"}`))
	if err == nil {
		t.Fatal("expected the MCP tool to refuse action=refresh, got no error")
	}
	if !strings.Contains(err.Error(), "not available through pool-wide control") {
		t.Errorf("error = %v, want it to name pool-wide refresh specifically", err)
	}
	if got := h.recorded(); len(got) != 0 {
		t.Errorf("a refused refresh still drove hosts: %v", got)
	}
}

// An empty pool without a configured hold accepts the call and changes nothing.
func TestApplyToAnEmptyPool(t *testing.T) {
	agg := ctlAggregator(t, map[string]string{}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)
	resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"empty","action":"continue"}`)
	if resp.StatusCode != 200 || m["ok"] != true {
		t.Fatalf("empty pool: %d %v", resp.StatusCode, m)
	}
	if applied, _ := m["applied"].(float64); applied != 0 {
		t.Errorf("applied = %v, want 0", m["applied"])
	}
}

func TestControlStateIncludesConfiguredPause(t *testing.T) {
	for _, tc := range []struct{ configured, host, want string }{
		{"paused", `{"cyclePaused":false,"stepPaused":false}`, hostctl.ActionPauseAfterCycle},
		{"paused", `{"cyclePaused":false,"stepPaused":true}`, hostctl.StateBoth},
		{"run", `{"cyclePaused":false,"stepPaused":false}`, hostctl.ActionContinue},
	} {
		t.Run(tc.configured+tc.want, func(t *testing.T) {
			h := newCtlHost(t, tc.host)
			agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
			f := ctlConfiguration("42aa")
			f.stateRes.Stdout = strings.Replace(f.stateRes.Stdout, `"poolId":"lab"`, `"configuredState":"`+tc.configured+`","poolId":"lab"`, 1)
			srv := ctlServer(t, f, agg.URL, testBearer)
			resp, m := do(t, "GET", srv.URL+"/api/pool/host-control", "")
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("read: %d %v", resp.StatusCode, m)
			}
			view := m["pools"].(map[string]any)["lab"].(map[string]any)
			if view["state"] != tc.want || view["configuredState"] != tc.configured {
				t.Fatalf("view = %v, want state %s and configuredState %s", view, tc.want, tc.configured)
			}
		})
	}
}

func TestContinueReleasesConfiguredPause(t *testing.T) {
	for _, empty := range []bool{false, true} {
		t.Run(fmt.Sprint("empty=", empty), func(t *testing.T) {
			h := newCtlHost(t, "")
			agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
			f := ctlConfiguration("42aa")
			id := "lab"
			if empty {
				id = "empty"
			}
			f.stateRes.Stdout = strings.Replace(f.stateRes.Stdout, `"poolId":"`+id+`"`, `"configuredState":"paused","poolId":"`+id+`"`, 1)
			f.ret = configuration.Result{OK: true}
			srv := ctlServer(t, f, agg.URL, testBearer)
			resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"`+id+`","action":"continue"}`)
			if resp.StatusCode != http.StatusOK || m["ok"] != true {
				t.Fatalf("continue: %d %v", resp.StatusCode, m)
			}
			if f.lastCall != "SetConfiguredState" || strings.Join(f.lastArgs, " ") != id+" run" {
				t.Fatalf("stored hold not released: %s %v", f.lastCall, f.lastArgs)
			}
			if !empty && strings.Join(h.recorded(), ",") != "cycle-resume,step-resume" {
				t.Fatalf("host switches not cleared: %v", h.recorded())
			}
		})
	}
}

func TestContinueRefusesWhenConfiguredPauseCannotBeReleased(t *testing.T) {
	h := newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	f := ctlConfiguration("42aa")
	f.stateRes.Stdout = strings.Replace(f.stateRes.Stdout, `"poolId":"lab"`, `"configuredState":"paused","poolId":"lab"`, 1)
	f.ret = configuration.Result{OK: false, Error: "configuration push refused"}
	srv := ctlServer(t, f, agg.URL, testBearer)
	resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`)
	if resp.StatusCode != http.StatusInternalServerError || !strings.Contains(fmt.Sprint(m["error"]), "configuration push refused") {
		t.Fatalf("failed publication reported as success: %d %v", resp.StatusCode, m)
	}
	if len(h.recorded()) != 0 {
		t.Fatalf("host switches changed despite failed configuration publication: %v", h.recorded())
	}
}

func TestPauseActionsPreserveConfiguredHold(t *testing.T) {
	for _, action := range []string{hostctl.ActionPauseAfterCycle, hostctl.ActionPauseAfterStep} {
		t.Run(action, func(t *testing.T) {
			h := newCtlHost(t, "")
			agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
			f := ctlConfiguration("42aa")
			f.stateRes.Stdout = strings.Replace(f.stateRes.Stdout, `"poolId":"lab"`, `"configuredState":"paused","poolId":"lab"`, 1)
			srv := ctlServer(t, f, agg.URL, testBearer)
			resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"`+action+`"}`)
			if resp.StatusCode != http.StatusOK || m["ok"] != true || f.lastCall != "State" {
				t.Fatalf("pause changed configured state: %d %v %s", resp.StatusCode, m, f.lastCall)
			}
		})
	}
}

func TestContinuePreservesOtherConfiguredStates(t *testing.T) {
	for _, configured := range []string{"run", "drain", ""} {
		t.Run(configured, func(t *testing.T) {
			h := newCtlHost(t, "")
			agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
			f := ctlConfiguration("42aa")
			f.stateRes.Stdout = strings.Replace(f.stateRes.Stdout, `"poolId":"lab"`, `"configuredState":"`+configured+`","poolId":"lab"`, 1)
			srv := ctlServer(t, f, agg.URL, testBearer)
			resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`)
			if resp.StatusCode != http.StatusOK || m["ok"] != true || f.lastCall != "State" {
				t.Fatalf("continue rewrote unrelated configuration: %d %v %s", resp.StatusCode, m, f.lastCall)
			}
		})
	}
}

func TestConfiguredPauseReleaseIsAudited(t *testing.T) {
	f := ctlConfiguration()
	f.stateRes.Stdout = strings.Replace(f.stateRes.Stdout, `"poolId":"lab"`, `"configuredState":"paused","poolId":"lab"`, 1)
	f.ret = configuration.Result{OK: true}
	store := state.New(filepath.Join(t.TempDir(), "pc"), time.Now())
	srv := httptest.NewServer(New(f, Options{AuthToken: testBearer, Store: store}).Handler())
	defer srv.Close()
	resp, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`)
	if resp.StatusCode != http.StatusOK || m["ok"] != true {
		t.Fatalf("continue: %d %v", resp.StatusCode, m)
	}
	status := store.Health()
	if status.Writes != 1 || !status.LastPublishOK {
		t.Fatalf("configuration publication was not recorded: %+v", status)
	}
}

// The fan-out changes other machines, so it is audited like every pool
// mutation -- including how much of it landed.
func TestApplyIsAudited(t *testing.T) {
	ok, refusing := newCtlHost(t, ""), newCtlHost(t, "")
	refusing.status = http.StatusForbidden
	refusing.body = `{"ok":false,"reason":"proof-invalid"}`
	agg := ctlAggregator(t, map[string]string{"42aa": ok.srv.URL, "42bb": refusing.srv.URL}, "")
	dir := filepath.Join(t.TempDir(), "pc")
	store := state.New(dir, time.Now())
	publishedAt := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	store.Record(time.Now(), state.AuditEntry{
		Publish: true, TimeUTC: publishedAt, Action: "new-pool", Target: "lab", OK: true,
	})
	srv := httptest.NewServer(New(ctlConfiguration("42aa", "42bb"), Options{AggregatorURL: agg.URL, AuthToken: testBearer, Store: store}).Handler())
	defer srv.Close()

	resp, result := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"pause-after-cycle"}`)
	if resp.StatusCode != http.StatusOK || result["ok"] != true || result["applied"] != float64(1) || result["failed"] != float64(1) {
		t.Fatalf("apply: HTTP %d %v", resp.StatusCode, result)
	}
	audit, err := os.ReadFile(filepath.Join(dir, "audit.jsonl"))
	if err != nil {
		t.Fatalf("read audit: %v", err)
	}
	rows := strings.Split(strings.TrimSpace(string(audit)), "\n")
	if len(rows) != 2 {
		t.Fatalf("audit rows = %d, want publish and host-control: %s", len(rows), audit)
	}
	var entry state.AuditEntry
	if err := json.Unmarshal([]byte(rows[1]), &entry); err != nil {
		t.Fatalf("decode host-control audit: %v", err)
	}
	if entry.Action != "host-control" || entry.Target != "lab" || entry.OK || entry.Detail != "pause-after-cycle: 1 applied, 1 failed" {
		t.Fatalf("host-control audit = %+v", entry)
	}
	if _, err := time.Parse(time.RFC3339, entry.TimeUTC); err != nil {
		t.Fatalf("audit timestamp = %q: %v", entry.TimeUTC, err)
	}
	resp, health := do(t, "GET", srv.URL+"/healthz", "")
	if resp.StatusCode != http.StatusOK || health["lastAction"] != "new-pool" || health["lastWriteUtc"] != publishedAt ||
		health["lastPublishOk"] != true || health["writes"] != float64(1) {
		t.Fatalf("host-control changed configuration-publish health: HTTP %d %v", resp.StatusCode, health)
	}
}

// The read collapses members into one state only when they all answered and
// all agreed. Everything else is "mixed": a selector that showed one host's
// state for a pool would have the operator act on a reading nobody took.
func TestPoolStateAggregation(t *testing.T) {
	const running = `{"stepPaused":false,"cyclePaused":false}`
	const cycle = `{"stepPaused":false,"cyclePaused":true}`

	cases := []struct {
		name  string
		docs  []string
		want  string
		known int
	}{
		{"all agree", []string{running, running}, hostctl.ActionContinue, 2},
		{"disagree", []string{running, cycle}, hostctl.StateMixed, 2},
		{"one silent", []string{cycle, ""}, hostctl.StateMixed, 1},
		{"none answer", []string{"", ""}, hostctl.StateUnknown, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			addr := map[string]string{}
			members := []string{}
			for i, doc := range c.docs {
				h := newCtlHost(t, doc)
				id := []string{"42aa", "42bb"}[i]
				addr[id] = h.srv.URL
				members = append(members, id)
			}
			agg := ctlAggregator(t, addr, "")
			srv := ctlServer(t, ctlConfiguration(members...), agg.URL, testBearer)

			resp, m := do(t, "GET", srv.URL+"/api/pool/host-control", "")
			if resp.StatusCode != 200 {
				t.Fatalf("read: %d %v", resp.StatusCode, m)
			}
			pools, _ := m["pools"].(map[string]any)
			lab, _ := pools["lab"].(map[string]any)
			if lab["state"] != c.want {
				t.Errorf("state = %v, want %v", lab["state"], c.want)
			}
			rows, _ := lab["hosts"].([]any)
			if len(rows) != len(c.docs) {
				t.Fatalf("hosts = %d rows, want %d", len(rows), len(c.docs))
			}
			answered := 0
			for _, r := range rows {
				if r.(map[string]any)["ok"] == true {
					answered++
				}
			}
			if answered != c.known {
				t.Errorf("%d hosts answered, want %d", answered, c.known)
			}
		})
	}
}

// A host with both switches armed -- reachable only from its own status page,
// which has one button each -- is reported as such rather than as one of the
// three states, so the selector never claims a value that would not reproduce
// what the host is actually doing.
func TestBothSwitchesArmedIsReported(t *testing.T) {
	h := newCtlHost(t, `{"stepPaused":true,"cyclePaused":true}`)
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)

	_, m := do(t, "GET", srv.URL+"/api/pool/host-control", "")
	pools, _ := m["pools"].(map[string]any)
	lab, _ := pools["lab"].(map[string]any)
	if lab["state"] != hostctl.StateBoth {
		t.Fatalf("state = %v, want %v", lab["state"], hostctl.StateBoth)
	}
}

// The read is open (it exposes no more than each host already serves to the
// LAN) and the write is gated, like every other change this service makes.
func TestHostControlGating(t *testing.T) {
	h := newCtlHost(t, `{"stepPaused":false,"cyclePaused":false}`)
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)

	resp, err := http.Get(srv.URL + "/api/pool/host-control")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("uncredentialed read = %d, want 200", resp.StatusCode)
	}

	resp, err = http.Post(srv.URL+"/api/pool/host-control", "application/json", strings.NewReader(`{"poolId":"lab","action":"continue"}`))
	if err != nil {
		t.Fatalf("write: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("uncredentialed write = %d, want 401", resp.StatusCode)
	}
	if got := h.recorded(); len(got) != 0 {
		t.Errorf("an uncredentialed write drove hosts: %v", got)
	}
}

// A proof names the host it opens, so the fan-out sends each member its own.
func TestApplyBindsEachMembersProofToThatMember(t *testing.T) {
	a, b := newCtlHost(t, ""), newCtlHost(t, "")
	agg := ctlAggregator(t, map[string]string{"42aa": a.srv.URL, "42bb": b.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa", "42bb"), agg.URL, testBearer)
	if _, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`); m["ok"] != true {
		t.Fatalf("apply: %v", m)
	}
	for id, h := range map[string]*ctlHost{"42aa": a, "42bb": b} {
		wire := h.lastProof()
		expiry, _, _ := strings.Cut(wire, ".")
		exp, err := strconv.ParseInt(expiry, 10, 64)
		if err != nil || wire != controlproof.ProofForScope(testBearer, id, hostctl.ScopePause, exp) {
			t.Errorf("%s received %q, want a pause proof bound to %s", id, wire, id)
		}
	}
	if a.lastProof() == b.lastProof() {
		t.Error("two members received the same proof")
	}
}

// bindingAggregator mints the way an aggregator with audiences does: one proof
// per /go/host call, bound to the host asked about, and narrowed to the scope
// asked for when scopes is set. bound=false answers the way an aggregator that
// predates audiences does, with one unbound proof; scopes=false the way one
// that predates scopes does, ignoring the parameter.
func bindingAggregator(t *testing.T, addr map[string]string, bound, scopes bool) (*httptest.Server, *int) {
	t.Helper()
	asked := new(int)
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pool-status"):
			hosts := make([]map[string]any, 0, len(addr))
			for id, base := range addr {
				hosts = append(hosts, map[string]any{"hostId": id, "baseUrl": base, "control": "ready"})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"hosts": hosts})
		case r.URL.Path == "/go/host":
			mu.Lock()
			*asked++
			mu.Unlock()
			proof := hostctl.Mint("aggregator-token", time.Minute)
			if bound {
				proof = hostctl.MintFor("aggregator-token", r.URL.Query().Get("host"), time.Minute)
				if scope := r.URL.Query().Get("scope"); scope != "" && scopes {
					proof = controlproof.MintForScope("aggregator-token", r.URL.Query().Get("host"), scope, time.Minute)
				}
			}
			http.Redirect(w, r, "http://192.0.2.9:8080#yctl="+proof, http.StatusFound)
		case r.URL.Path == "/api/v1/lab-token":
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, asked
}

func TestApplyAsksTheAggregatorPerMemberAndReusesAnUnboundProof(t *testing.T) {
	for _, tc := range []struct {
		name          string
		bound, scopes bool
		wantAsked     int
	}{
		{"an aggregator that scopes proofs is asked once per member", true, true, 2},
		{"an aggregator that binds but predates scopes is asked once per member", true, false, 2},
		{"an unbound proof from an older aggregator serves the whole fan-out", false, false, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, b := newCtlHost(t, ""), newCtlHost(t, "")
			agg, asked := bindingAggregator(t, map[string]string{"42aa": a.srv.URL, "42bb": b.srv.URL}, tc.bound, tc.scopes)
			srv := httptest.NewServer(New(ctlConfiguration("42aa", "42bb"), Options{AggregatorURL: agg.URL}).Handler())
			defer srv.Close()
			req, _ := http.NewRequest("POST", srv.URL+"/api/pool/host-control", strings.NewReader(`{"poolId":"lab","action":"continue"}`))
			req.AddCookie(sessionCookieFor(t, srv.URL))
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("apply: %v", err)
			}
			resp.Body.Close()
			if *asked != tc.wantAsked {
				t.Fatalf("aggregator asked %d times, want %d", *asked, tc.wantAsked)
			}
			for id, h := range map[string]*ctlHost{"42aa": a, "42bb": b} {
				if hostctl.Bound(h.lastProof()) != tc.bound || (tc.bound && !strings.Contains(h.lastProof(), "."+id+".")) ||
					hostctl.Scoped(h.lastProof()) != tc.scopes {
					t.Errorf("%s received %q", id, h.lastProof())
				}
			}
		})
	}
}

// A host that predates scoped proofs answers proof-invalid to the pause-scoped
// one; the fan-out then sends that host its full proof once, so mixing old and
// new hosts in a pool keeps pool-wide pause working.
func TestApplyRetriesAHostThatPredatesScopedProofsWithItsFullProof(t *testing.T) {
	var mu sync.Mutex
	var seen []string
	old := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proof := r.Header.Get("X-Yuruna-Control")
		mu.Lock()
		seen = append(seen, proof)
		mu.Unlock()
		if hostctl.Scoped(proof) {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"ok":false,"reason":"proof-invalid"}`))
			return
		}
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer old.Close()
	agg := ctlAggregator(t, map[string]string{"42aa": old.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)
	if _, m := do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`); m["ok"] != true || m["applied"] != float64(1) {
		t.Fatalf("apply: %v", m)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 3 || !hostctl.Scoped(seen[0]) || hostctl.Scoped(seen[1]) || !hostctl.Bound(seen[1]) || seen[1] != seen[2] {
		t.Fatalf("proofs presented = %q, want the pause proof once, then the host's full proof for both routes", seen)
	}
}

// A refusal for any other reason is the host's answer, not a version gap:
// nothing is retried.
func TestApplyDoesNotRetryAnotherRefusal(t *testing.T) {
	h := newCtlHost(t, "")
	h.status = http.StatusForbidden
	h.body = `{"ok":false,"reason":"proof-expired"}`
	agg := ctlAggregator(t, map[string]string{"42aa": h.srv.URL}, "")
	srv := ctlServer(t, ctlConfiguration("42aa"), agg.URL, testBearer)
	_, _ = do(t, "POST", srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"continue"}`)
	if calls := h.recorded(); len(calls) != 1 {
		t.Fatalf("calls = %q, want the one refused call", calls)
	}
}
