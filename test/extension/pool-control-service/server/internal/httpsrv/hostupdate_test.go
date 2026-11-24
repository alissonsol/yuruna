// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428a4a29-46bb-4dbf-bb6b-726db5f1b4f3

package httpsrv

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pool-control-service/internal/state"
	"yuruna.com/test/extension/extension-sdk/hostrepair"
	"yuruna.com/test/extension/extension-sdk/hostupdate"
)

// Per-host remote update: the route, its read half, the confirmation page and
// the MCP tool. What a wrong implementation gets wrong here is what reaches a
// host: an update signed for another request, a drain riding in under some
// spelling, or a request sent to a host that said it cannot take one.

var (
	upKeyOnce sync.Once
	upKey     *rsa.PrivateKey
)

func upSigningKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	upKeyOnce.Do(func() {
		k, err := rsa.GenerateKey(rand.Reader, hostupdate.MinKeyBits)
		if err != nil {
			panic(err)
		}
		upKey = k
	})
	return upKey
}

const upUsable = `{"protocol":1,"availability":"available","scopes":"restart,full","reason":"","remote":"provisioned","state":"idle","caller":"remote","poolControl":"http://pool-control.example"}`

// upHost is a host status service: control-status with the update object the
// test supplies, and the host-update route answering with what the test
// supplies. It records every update call.
type upHost struct {
	mu      sync.Mutex
	update  string
	status  int
	body    string
	headers []http.Header
	bodies  []string
	srv     *httptest.Server
}

func newUPHost(t *testing.T) *upHost {
	t.Helper()
	h := &upHost{update: upUsable, status: http.StatusAccepted,
		body: `{"ok":true,"requestId":"` + rpRequest + `","action":"queued","scope":"restart","stateUrl":"/runtime/host-update.state.json"}`}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		update, status, body := h.update, h.status, h.body
		h.mu.Unlock()
		switch r.URL.Path {
		case "/control/control-status":
			doc := `{"ok":true,"hostId":"` + rpHost + `"`
			if update != "" {
				doc += `,"update":` + update
			}
			_, _ = w.Write([]byte(doc + "}"))
		case "/control/host-update":
			b, _ := io.ReadAll(r.Body)
			h.mu.Lock()
			h.headers = append(h.headers, r.Header.Clone())
			h.bodies = append(h.bodies, string(b))
			h.mu.Unlock()
			w.WriteHeader(status)
			_, _ = w.Write([]byte(body))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *upHost) calls() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.bodies)
}

type upOpts struct {
	key        *rsa.PrivateKey
	credential string
	store      *state.Store
}

func upServer(t *testing.T, host *upHost, o upOpts) (*Server, *httptest.Server) {
	t.Helper()
	agg := rpAggregator(t, map[string]string{rpHost: host.srv.URL, rpOtherHost: ""}, "")
	s := New(ctlConfiguration(rpHost), Options{AggregatorURL: agg.URL, AuthToken: testBearer, Store: o.store,
		OperatorCredential: o.credential, UpdateSigningKey: o.key, UpdateSigningKeyFile: "/etc/yuruna/host-repair/update-signing.key"})
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	return s, srv
}

func upConfigured(t *testing.T) upOpts {
	return upOpts{key: upSigningKey(t), credential: rpCredential}
}

func upBody(extra string) string {
	return `{"hostId":"` + rpHost + `","requestId":"` + rpRequest + `"` + extra + `}`
}

func upGet(t *testing.T, url string) (*http.Response, map[string]any, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	return resp, m, string(raw)
}

func TestUpdateRouteIsDisabledWithoutEitherSecret(t *testing.T) {
	host := newUPHost(t)
	_, noKey := upServer(t, host, upOpts{credential: rpCredential})
	resp, m, _ := rpPost(t, noKey.URL+"/api/host/update", upBody(""), bothCredentials())
	if resp.StatusCode != http.StatusServiceUnavailable || m["code"] != "pool.host_update_signing_unconfigured" {
		t.Fatalf("no key: %d %v", resp.StatusCode, m)
	}
	_, noCredential := upServer(t, host, upOpts{key: upSigningKey(t)})
	resp, m, _ = rpPost(t, noCredential.URL+"/api/host/update", upBody(""), bothCredentials())
	if resp.StatusCode != http.StatusServiceUnavailable || m["reason"] != hostrepair.ReasonGateUnconfigured {
		t.Fatalf("no credential: %d %v", resp.StatusCode, m)
	}
	if resp, m, _ = upGet(t, noKey.URL+"/api/host/update?host="+rpHost); resp.StatusCode != http.StatusServiceUnavailable || m["reason"] != "update_disabled" {
		t.Fatalf("prepare without a key: %d %v", resp.StatusCode, m)
	}
	if host.calls() != 0 {
		t.Fatalf("a disabled route reached the host %d times", host.calls())
	}
}

func TestUpdateNeedsTheOperatorCredential(t *testing.T) {
	host := newUPHost(t)
	_, srv := upServer(t, host, upConfigured(t))
	for name, headers := range map[string]map[string]string{
		"bearer only":           {"Authorization": "Bearer " + testBearer},
		"lab key as credential": {"Authorization": "Bearer " + testBearer, hostrepair.CredentialHeader: testBearer},
		"credential only":       {hostrepair.CredentialHeader: rpCredential},
	} {
		if resp, m, _ := rpPost(t, srv.URL+"/api/host/update", upBody(""), headers); resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
	}
	if host.calls() != 0 {
		t.Fatalf("an unauthorized caller reached the host %d times", host.calls())
	}
}

// The body is closed, and no spelling of drain gets through: drainSeconds is
// the one name that contains it and passes.
func TestUpdateBodyIsStrictAndRefusesDrain(t *testing.T) {
	host := newUPHost(t)
	_, srv := upServer(t, host, upConfigured(t))
	cases := map[string]struct {
		body, code string
		status     int
	}{
		"drain":            {upBody(`,"drain":"now"`), "pool.host_update_field_forbidden", 400},
		"Drain":            {upBody(`,"Drain":"after-cycle"`), "pool.host_update_field_forbidden", 400},
		"drain_mode":       {upBody(`,"drain_mode":"now"`), "pool.host_update_field_forbidden", 400},
		"drainNow":         {upBody(`,"drainNow":true`), "pool.host_update_field_forbidden", 400},
		"other key":        {upBody(`,"force":"true"`), "pool.host_update_field_unsupported", 400},
		"duplicate drain":  {upBody(`,"drainSeconds":60,"drain_seconds":61`), "pool.host_update_body_invalid", 400},
		"drain as text":    {upBody(`,"drainSeconds":"3600"`), "pool.host_update_drain_invalid", 400},
		"drain fraction":   {upBody(`,"drainSeconds":3600.5`), "pool.host_update_drain_invalid", 400},
		"drain below":      {upBody(`,"drainSeconds":59`), "pool.host_update_drain_invalid", 400},
		"drain above":      {upBody(`,"drainSeconds":21601`), "pool.host_update_drain_invalid", 400},
		"scope":            {upBody(`,"scope":"reboot"`), "pool.host_update_scope_invalid", 400},
		"scope as number":  {upBody(`,"scope":1`), "pool.host_update_scope_invalid", 400},
		"uppercase commit": {upBody(`,"expectCommit":"ABCDEF1"`), "pool.host_update_commit_invalid", 400},
		"short commit":     {upBody(`,"expectCommit":"abc"`), "pool.host_update_commit_invalid", 400},
		"bad host id":      {`{"hostId":"42","requestId":"` + rpRequest + `"}`, "pool.host_repair_host_id_invalid", 400},
		"no request id":    {`{"hostId":"` + rpHost + `"}`, "pool.host_repair_request_id_invalid", 400},
		"trailing garbage": {upBody("") + "x", "pool.host_update_body_invalid", 400},
		"boolean":          {`{"hostId":true}`, "pool.host_update_body_invalid", 400},
		"too large":        {`{"hostId":"` + strings.Repeat("a", 4100) + `"}`, "pool.host_update_body_invalid", 413},
	}
	for name, c := range cases {
		resp, m, _ := rpPost(t, srv.URL+"/api/host/update", c.body, bothCredentials())
		if resp.StatusCode != c.status || m["code"] != c.code {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
		if c.code == "pool.host_update_field_forbidden" && m["reason"] != "forbidden_field" {
			t.Errorf("%s: reason %v", name, m["reason"])
		}
	}
	if host.calls() != 0 {
		t.Fatalf("refused bodies reached the host: %d calls", host.calls())
	}
}

// What the host says about itself decides whether anything is sent: an old
// host, one with no controller, one that cannot verify the proof and one that
// does not list the scope are refused here.
func TestUpdateFollowsTheHostsOwnCapability(t *testing.T) {
	cases := map[string]struct{ update, body, reason string }{
		"no update object":   {"", upBody(""), "update_unsupported"},
		"no controller":      {`{"protocol":1,"availability":"unavailable","scopes":"","reason":"controller_absent","remote":"provisioned","state":"idle"}`, upBody(""), "controller_absent"},
		"record missing":     {`{"protocol":1,"availability":"available","scopes":"restart","reason":"","remote":"missing","state":"idle"}`, upBody(""), hostupdate.ReasonRemoteUnprovisioned},
		"record invalid":     {`{"protocol":1,"availability":"available","scopes":"restart","reason":"","remote":"invalid","state":"idle"}`, upBody(""), hostupdate.ReasonRemoteInvalid},
		"scope not listed":   {`{"protocol":1,"availability":"available","scopes":"restart","reason":"","remote":"provisioned","state":"idle"}`, upBody(`,"scope":"full"`), "scope_unavailable"},
		"reason not a token": {`{"protocol":1,"availability":"unavailable","scopes":"","reason":"<b>x</b>","remote":"provisioned","state":"idle"}`, upBody(""), "unrecognized"},
	}
	for name, c := range cases {
		host := newUPHost(t)
		host.update = c.update
		_, srv := upServer(t, host, upConfigured(t))
		resp, m, _ := rpPost(t, srv.URL+"/api/host/update", c.body, bothCredentials())
		if resp.StatusCode != http.StatusConflict || m["code"] != "pool.host_update_unavailable" || m["hostReason"] != c.reason {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
		if host.calls() != 0 {
			t.Errorf("%s: the update was sent anyway", name)
		}
	}
}

// The host receives both proofs, and the yup1 proof verifies with the public
// key against exactly the request the host is sent, defaults applied.
func TestUpdateSendsAProofTheHostCanVerify(t *testing.T) {
	host := newUPHost(t)
	dir := t.TempDir()
	store := state.New(dir, time.Now())
	o := upConfigured(t)
	o.store = store
	_, srv := upServer(t, host, o)
	resp, m, _ := rpPost(t, srv.URL+"/api/host/update", upBody(`,"expectCommit":"3efe0768a"`), bothCredentials())
	if resp.StatusCode != http.StatusAccepted || m["action"] != "queued" || m["scope"] != "restart" {
		t.Fatalf("accepted: %d %v", resp.StatusCode, m)
	}
	if m["diagnosticsUrl"] != host.srv.URL+"/diagnostics.html#yhu="+rpRequest {
		t.Fatalf("diagnosticsUrl %v", m["diagnosticsUrl"])
	}
	if host.calls() != 1 {
		t.Fatalf("host calls %d", host.calls())
	}
	h := host.headers[0]
	if h.Get("X-Yuruna") != "1" || h.Get("X-Yuruna-Control") == "" || h.Get("Content-Type") != "application/json" {
		t.Fatalf("transport headers %v", h)
	}
	var sent struct {
		RequestID    string `json:"requestId"`
		Scope        string `json:"scope"`
		DrainSeconds int    `json:"drainSeconds"`
		ExpectCommit string `json:"expectCommit"`
	}
	if err := json.Unmarshal([]byte(host.bodies[0]), &sent); err != nil {
		t.Fatal(err)
	}
	if sent.RequestID != rpRequest || sent.Scope != "restart" || sent.DrainSeconds != hostupdate.DefaultDrainSeconds || sent.ExpectCommit != "3efe0768a" {
		t.Fatalf("body %s", host.bodies[0])
	}
	want := hostupdate.Claims{HostID: rpHost, RequestID: sent.RequestID, Scope: sent.Scope, DrainSeconds: sent.DrainSeconds, ExpectCommit: sent.ExpectCommit}
	if _, reason := hostupdate.Verify(&upSigningKey(t).PublicKey, h.Get(hostupdate.ProofHeader), want, time.Now(), hostupdate.MaxLifetime, hostupdate.Skew); reason != hostupdate.ReasonOK {
		t.Fatalf("the host cannot verify what it was sent: %s", reason)
	}
	if h.Get(hostrepair.ProofHeader) != "" {
		t.Fatal("a repair proof rode along")
	}
	raw, err := os.ReadFile(filepath.Join(dir, "audit.jsonl"))
	if err != nil {
		t.Fatalf("no audit log: %v", err)
	}
	audit := string(raw)
	if !strings.Contains(audit, `"action":"host-update"`) || !strings.Contains(audit, "outcome=queued") || strings.Contains(audit, rpCredential) {
		t.Fatalf("audit %s", audit)
	}
}

func TestUpdateRelaysTheHostsRefusal(t *testing.T) {
	cases := map[string]struct {
		status        int
		body, code    string
		want          int
		retryable     bool
		hostReasonOut string
	}{
		"busy":           {409, `{"ok":false,"reason":"busy","activeKind":"host_repair","activeRequestId":"4242aaaa-0000-4000-8000-000000000009"}`, "pool.host_update_busy", 409, false, "busy"},
		"conflict":       {409, `{"ok":false,"reason":"request_conflict","requestId":"` + rpRequest + `"}`, "pool.host_update_request_conflict", 409, false, "request_conflict"},
		"proof expired":  {403, `{"ok":false,"reason":"update_proof_expired"}`, "pool.host_update_host_refused", 502, false, "update_proof_expired"},
		"no controller":  {503, `{"ok":false,"reason":"controller_absent"}`, "pool.host_update_host_unavailable", 503, true, "controller_absent"},
		"wrong id reply": {202, `{"ok":true,"requestId":"4242aaaa-0000-4000-8000-000000000009","action":"queued"}`, "pool.host_repair_reply_invalid", 502, false, ""},
	}
	for name, c := range cases {
		host := newUPHost(t)
		host.status, host.body = c.status, c.body
		_, srv := upServer(t, host, upConfigured(t))
		resp, m, _ := rpPost(t, srv.URL+"/api/host/update", upBody(""), bothCredentials())
		if resp.StatusCode != c.want || m["code"] != c.code || m["retryable"] != c.retryable {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
		if c.hostReasonOut != "" && m["hostReason"] != c.hostReasonOut {
			t.Errorf("%s: hostReason %v", name, m["hostReason"])
		}
		if m["diagnosticsUrl"] != nil {
			t.Errorf("%s: a refusal carried a page to go to", name)
		}
	}
}

func TestUpdatePrepareMintsAnIdAndSendsNothing(t *testing.T) {
	host := newUPHost(t)
	_, srv := upServer(t, host, upConfigured(t))
	resp, first, _ := upGet(t, srv.URL+"/api/host/update?host="+strings.ToUpper(rpHost)+"&scope=full")
	if resp.StatusCode != http.StatusOK || first["offer"] != true || first["hostId"] != rpHost || first["scope"] != "full" ||
		first["address"] != host.srv.URL || first["drainSeconds"] != float64(hostupdate.DefaultDrainSeconds) {
		t.Fatalf("prepare: %d %v", resp.StatusCode, first)
	}
	_, second, _ := upGet(t, srv.URL+"/api/host/update?host="+rpHost)
	id1, _ := first["requestId"].(string)
	id2, _ := second["requestId"].(string)
	if !hostrepair.ValidRequestID(id1) || !hostrepair.ValidRequestID(id2) || id1 == id2 {
		t.Fatalf("request ids %q %q", id1, id2)
	}
	if second["scope"] != "restart" {
		t.Fatalf("default scope %v", second["scope"])
	}
	_, ignored, _ := upGet(t, srv.URL+"/api/host/update?host="+rpHost+"&requestId=4242aaaa-0000-4000-8000-000000000009")
	if ignored["requestId"] == "4242aaaa-0000-4000-8000-000000000009" {
		t.Fatal("the request id was taken from the URL")
	}
	host.update = `{"protocol":1,"availability":"available","scopes":"restart","reason":"","remote":"missing","state":"idle"}`
	_, refused, _ := upGet(t, srv.URL+"/api/host/update?host="+rpHost)
	if refused["offer"] != false || refused["reason"] != hostupdate.ReasonRemoteUnprovisioned {
		t.Fatalf("not offered: %v", refused)
	}
	for _, q := range []string{"?host=42", "?host=" + rpHost + "&scope=reboot"} {
		if resp, _, _ := upGet(t, srv.URL+"/api/host/update"+q); resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: %d", q, resp.StatusCode)
		}
	}
	if host.calls() != 0 {
		t.Fatalf("the read half sent %d updates", host.calls())
	}
}

func TestUpdatePageRefusesFraming(t *testing.T) {
	_, srv := upServer(t, newUPHost(t), upConfigured(t))
	resp, _, body := upGet(t, srv.URL+"/host/update?host="+rpHost)
	if resp.StatusCode != http.StatusOK || resp.Header.Get("X-Frame-Options") != "DENY" || resp.Header.Get("Content-Security-Policy") == "" {
		t.Fatalf("page: %d %v", resp.StatusCode, resp.Header)
	}
	if !strings.Contains(body, `/assets/hostupdate.js`) {
		t.Fatal("the page does not load its script")
	}
}

func TestUpdateToolIsGatedAndHasNoDrain(t *testing.T) {
	host := newUPHost(t)
	_, off := upServer(t, host, upOpts{credential: rpCredential})
	if updateTool(t, off.URL) != nil {
		t.Fatal("an unprovisioned server lists the update tool")
	}
	_, srv := upServer(t, host, upConfigured(t))
	tool := updateTool(t, srv.URL)
	if tool == nil {
		t.Fatal("a configured server does not list the update tool")
	}
	if ann, _ := tool["annotations"].(map[string]any); ann["destructiveHint"] != true {
		t.Fatalf("annotations %v", tool["annotations"])
	}
	props := tool["inputSchema"].(map[string]any)["properties"].(map[string]any)
	for name := range props {
		if name != "drainSeconds" && strings.Contains(strings.ToLower(name), "drain") {
			t.Fatalf("the tool takes %s", name)
		}
	}
	call := func(args string, headers map[string]string) map[string]any {
		body := `{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"pool_control_update_host","arguments":` + args + `}}`
		_, m, _ := rpPost(t, srv.URL+"/mcp", body, headers)
		return m
	}
	if res := call(upBody(""), map[string]string{"Authorization": "Bearer " + testBearer}); refusalReason(res) != hostrepair.ReasonCredentialRequired {
		t.Fatalf("lab key only: %v", res)
	}
	if res := call(upBody(`,"drain":"now"`), bothCredentials()); res["error"] == nil && !toolIsError(res) {
		t.Fatalf("a drain argument was accepted: %v", res)
	}
	if host.calls() != 0 {
		t.Fatalf("a refused tool call reached the host")
	}
	if res := call(upBody(""), bothCredentials()); res["error"] != nil || toolIsError(res) {
		t.Fatalf("both credentials: %v", res)
	}
	if host.calls() != 1 {
		t.Fatalf("host calls %d", host.calls())
	}
}

func TestHostInfoSaysWhetherUpdatesCanBeSigned(t *testing.T) {
	_, off := upServer(t, newUPHost(t), upOpts{credential: rpCredential})
	_, on := upServer(t, newUPHost(t), upConfigured(t))
	if _, m, _ := upGet(t, off.URL+"/api/hostinfo"); m["hostUpdate"] != false {
		t.Fatalf("off: %v", m)
	}
	if _, m, _ := upGet(t, on.URL+"/api/hostinfo"); m["hostUpdate"] != true {
		t.Fatalf("on: %v", m)
	}
}

func updateTool(t *testing.T, base string) map[string]any {
	t.Helper()
	got := mcpPost(t, base, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	for _, raw := range got["result"].(map[string]any)["tools"].([]any) {
		if m := raw.(map[string]any); m["name"] == "pool_control_update_host" {
			return m
		}
	}
	return nil
}

func toolIsError(res map[string]any) bool {
	r, _ := res["result"].(map[string]any)
	return r["isError"] == true
}
