// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"yuruna.com/test/extension/extension-sdk/labgate"
)

const (
	testVersion = "2026.09.01"
	testBearer  = "test-internal-auth-key"
)

// newDaemon builds a daemon whose every outside edge is faked: no squid, no
// registry, no exec. What is covered here is the WIRING -- which routes exist,
// which are gated, and what a refusal looks like. What the gate itself does is
// covered where it lives, in the SDK's labgate suite.
func newDaemon(t *testing.T, mode runMode) (*httptest.Server, *fakeExec) {
	return newDaemonWithGate(t, mode, "")
}

// newDaemonWithGate builds a daemon whose gate is either unconfigured (bearer
// "") or open to testBearer. Both states are load-bearing: unconfigured must
// refuse every mutation, configured must let an authorized one through to the
// mode check underneath.
func newDaemonWithGate(t *testing.T, mode runMode, bearer string) (*httptest.Server, *fakeExec) {
	t.Helper()
	version = testVersion
	fx := &fakeExec{}
	d := newTestDaemon(t, mode, t.TempDir(), fx, bearer)
	d.readSwitches = func() SwitchState { return SwitchState{Source: "test"} }
	srv := httptest.NewServer(d.routes())
	t.Cleanup(srv.Close)
	return srv, fx
}

// newTestDaemon wires every outside edge to something inert: no squid, no
// registry, no exec, and switch drop-ins under a temp dir so nothing here can
// write into a real /etc/squid.
func newTestDaemon(t *testing.T, mode runMode, dir string, fx *fakeExec, bearer string) *daemon {
	t.Helper()
	d := &daemon{
		mode:             mode,
		hostID:           "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		squidBinary:      "squid",
		noUpstreamHelper: filepath.Join(dir, "yuruna-no-upstream"),
		offlinePath:      filepath.Join(dir, "yuruna-offline.conf"),
		noUpstreamPath:   filepath.Join(dir, "yuruna-no-upstream.conf"),
		run:              fx.run,
		squid:            newSquidClient("", "", time.Second),
		registry:         newRegistryReader("", "", "", time.Second),
		gate:             labgate.New(labgate.Options{BearerToken: bearer}),
	}
	d.readSwitches = d.switchState
	return d
}

type fakeExec struct {
	calls [][]string
	err   error
}

func (f *fakeExec) run(name string, args ...string) (string, error) {
	f.calls = append(f.calls, append([]string{name}, args...))
	return "", f.err
}

func get(t *testing.T, srv *httptest.Server, path string) *http.Response {
	t.Helper()
	resp, err := srv.Client().Get(srv.URL + path)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func postJSON(t *testing.T, srv *httptest.Server, path, body string) *http.Response {
	return postJSONAs(t, srv, path, body, "")
}

// postJSONAs sends the internal authentication key as a bearer when one is given,
// which is the automation path through the gate.
func postJSONAs(t *testing.T, srv *httptest.Server, path, body, bearer string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatalf("build POST %s: %v", path, err)
	}
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func decode(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	var m map[string]any
	body, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("body is not JSON: %v (%s)", err, body)
	}
	return m
}

func TestHealthzIsOpenAndCheap(t *testing.T) {
	// The launcher polls it to decide the daemon is up and the aggregator
	// probes it before publishing this area's address, so it must answer
	// without waiting on squid.
	srv, _ := newDaemon(t, modeLocal)
	resp := get(t, srv, "/healthz")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz: %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if strings.TrimSpace(string(body)) != "ok" {
		t.Errorf("healthz body %q, want ok", body)
	}
}

func TestReadsAreOpen(t *testing.T) {
	srv, _ := newDaemon(t, modeLocal)
	for _, path := range []string{"/healthz", "/api/session", "/api/hostinfo", "/api/status", "/api/switches"} {
		resp := get(t, srv, path)
		if resp.StatusCode != http.StatusOK {
			t.Errorf("GET %s = %d, want 200 (reads are unconditionally open)", path, resp.StatusCode)
		}
	}
}

func TestHostInfoCarriesTheStampedVersion(t *testing.T) {
	// A build that loses -ldflags still runs and reports "dev". Nothing else
	// would notice, which is why this asserts the value.
	srv, _ := newDaemon(t, modeLocal)
	info := decode(t, get(t, srv, "/api/hostinfo"))
	if info["version"] != testVersion {
		t.Errorf("hostinfo version = %v, want %s", info["version"], testVersion)
	}
	if info["localHostId"] != "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Errorf("hostinfo hostId = %v", info["localHostId"])
	}
	if info["mode"] != string(modeLocal) {
		t.Errorf("hostinfo mode = %v", info["mode"])
	}
}

func TestStatusReportsEachPartSeparately(t *testing.T) {
	// Neither squid nor the registry is configured here, which is the case
	// this asserts: the composite still answers 200 and each part carries its
	// own failure, because "squid is not answering" is the thing an operator
	// opened this endpoint to learn.
	srv, _ := newDaemon(t, modeLocal)
	resp := get(t, srv, "/api/status")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status: %d", resp.StatusCode)
	}
	body := decode(t, resp)
	squid, ok := body["squid"].(map[string]any)
	if !ok {
		t.Fatalf("status carries no squid object: %v", body)
	}
	if squid["reachable"] != false {
		t.Errorf("an unconfigured squid must report reachable=false, got %v", squid["reachable"])
	}
	if squid["error"] == nil || squid["error"] == "" {
		t.Error("an unreachable squid must say why")
	}
	if _, ok := body["switches"].(map[string]any); !ok {
		t.Error("status must carry the switch state even when squid is down")
	}
	if _, ok := body["registry"].(map[string]any); !ok {
		t.Error("status must carry the registry state even when squid is down")
	}
}

func TestMutationsAreGated(t *testing.T) {
	// The gate here is unconfigured -- no aggregator, no bearer -- which must
	// refuse with 503 auth-unconfigured rather than running the write ungated.
	srv, fx := newDaemon(t, modeLocal)
	for _, path := range []string{"/api/switches/offline", "/api/switches/no-upstream"} {
		resp := postJSON(t, srv, path, `{"on":true}`)
		if resp.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("POST %s = %d, want 503 from an unconfigured gate", path, resp.StatusCode)
		}
		if reason := decode(t, resp)["reason"]; reason != "auth-unconfigured" {
			t.Errorf("POST %s reason = %v, want auth-unconfigured", path, reason)
		}
	}
	if len(fx.calls) != 0 {
		t.Fatalf("an unconfigured gate must never let a mutation through; ran %v", fx.calls)
	}
}

func TestRemoteModeRefusesMutationsWithItsOwnReason(t *testing.T) {
	// 501 and not 403: the operator is permitted, the capability does not
	// exist off the box. The reason string is what a client branches on.
	srv, fx := newDaemonWithGate(t, modeRemote, testBearer)
	for _, path := range []string{"/api/switches/offline", "/api/switches/no-upstream"} {
		resp := postJSONAs(t, srv, path, `{"on":true}`, testBearer)
		if resp.StatusCode != http.StatusNotImplemented {
			t.Fatalf("POST %s in remote mode = %d, want 501", path, resp.StatusCode)
		}
		body := decode(t, resp)
		if body["reason"] != "caching-proxy-remote-readonly" {
			t.Errorf("POST %s reason = %v, want caching-proxy-remote-readonly", path, body["reason"])
		}
		if msg, _ := body["error"].(string); !strings.Contains(msg, "remote mode") {
			t.Errorf("the refusal must say which mode refused: %q", msg)
		}
	}
	if len(fx.calls) != 0 {
		t.Fatalf("remote mode must run no command; ran %v", fx.calls)
	}
}

func TestLocalModeAppliesOfflineThroughReconfigure(t *testing.T) {
	// The switch is the drop-in; the reconfigure is what applies it. A daemon
	// that wrote the file and skipped the reload would report a change squid
	// had not made.
	fx := &fakeExec{}
	d := newTestDaemon(t, modeLocal, t.TempDir(), fx, testBearer)
	if err := d.applyOffline(true); err != nil {
		t.Fatalf("applyOffline: %v", err)
	}
	if got := d.readSwitches(); !got.Offline {
		t.Errorf("after applying, offline reads %+v", got)
	}
	if len(fx.calls) != 1 || fx.calls[0][0] != "squid" || fx.calls[0][1] != "-k" || fx.calls[0][2] != "reconfigure" {
		t.Fatalf("expected one `squid -k reconfigure`, got %v", fx.calls)
	}
	if err := d.applyOffline(false); err != nil {
		t.Fatalf("applyOffline(false): %v", err)
	}
	if got := d.readSwitches(); got.Offline {
		t.Errorf("after clearing, offline still reads %+v", got)
	}
}

func TestSwitchBodyMustNameOn(t *testing.T) {
	srv, _ := newDaemonWithGate(t, modeLocal, testBearer)
	for _, body := range []string{`{}`, `{"on":"yes"}`, `not json`} {
		resp := postJSONAs(t, srv, "/api/switches/offline", body, testBearer)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("POST body %q = %d, want 400", body, resp.StatusCode)
		}
	}
}

func TestUiPortReadsTheListenAddress(t *testing.T) {
	// The beacon advertises this; 0 means "no deep-link", which is the right
	// answer for anything unparseable rather than a guess.
	for addr, want := range map[string]int{
		"0.0.0.0:9310": 9310,
		"127.0.0.1:80": 80,
		"[::]:9310":    9310,
		"":             0,
		"9310":         0,
	} {
		if got := uiPort(addr); got != want {
			t.Errorf("uiPort(%q) = %d, want %d", addr, got, want)
		}
	}
}

// --- MCP ---------------------------------------------------------------

func mcpCall(t *testing.T, srv *httptest.Server, body, bearer string) map[string]any {
	t.Helper()
	resp := postJSONAs(t, srv, "/mcp", body, bearer)
	if resp.StatusCode == http.StatusAccepted {
		return nil
	}
	return decode(t, resp)
}

func TestMcpListsExactlyTheToolsThisDaemonOffers(t *testing.T) {
	// Pinned by name, not just by count: a tool renamed on one side of an
	// agent's config is a tool that silently stops being callable.
	srv, _ := newDaemonWithGate(t, modeLocal, testBearer)
	got := mcpCall(t, srv, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`, "")
	tools := got["result"].(map[string]any)["tools"].([]any)
	var names []string
	readOnly := map[string]bool{}
	for _, raw := range tools {
		m := raw.(map[string]any)
		name := m["name"].(string)
		names = append(names, name)
		readOnly[name] = m["annotations"].(map[string]any)["readOnlyHint"].(bool)
	}
	want := []string{
		"caching_proxy_hostinfo",
		"caching_proxy_recent_requests",
		"caching_proxy_set_no_upstream",
		"caching_proxy_set_offline",
		"caching_proxy_status",
		"caching_proxy_switches",
	}
	if len(names) != len(want) {
		t.Fatalf("tools = %v, want %v", names, want)
	}
	for i, w := range want {
		if names[i] != w {
			t.Fatalf("tools = %v, want %v", names, want)
		}
	}
	// The annotation is what an agent reads before deciding to ask permission.
	for name, ro := range readOnly {
		wantRO := !strings.HasPrefix(name, "caching_proxy_set_")
		if ro != wantRO {
			t.Errorf("%s readOnlyHint = %v, want %v", name, ro, wantRO)
		}
	}
}

func TestMcpReadToolAnswersThroughTheSameInternals(t *testing.T) {
	srv, _ := newDaemonWithGate(t, modeLocal, testBearer)
	got := mcpCall(t, srv, `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"caching_proxy_status"}}`, "")
	res, ok := got["result"].(map[string]any)
	if !ok {
		t.Fatalf("status tool: %v", got)
	}
	if res["isError"] != false {
		t.Fatalf("status tool errored: %v", res)
	}
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	// Same three parts /api/status carries, from the same functions.
	for _, part := range []string{`"squid"`, `"switches"`, `"registry"`, `"mode"`} {
		if !strings.Contains(text, part) {
			t.Errorf("status tool omitted %s: %s", part, text)
		}
	}
}

func TestMcpReadToolsStayOpenWhileMutationsAreGated(t *testing.T) {
	// The gate is unconfigured here. Reads must still answer -- they carry the
	// exposure of the routes they wrap, which are open -- and writes must not.
	srv, fx := newDaemon(t, modeLocal)

	got := mcpCall(t, srv, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"caching_proxy_switches"}}`, "")
	if _, ok := got["result"]; !ok {
		t.Fatalf("a read-only tool was refused by an unconfigured gate: %v", got)
	}

	got = mcpCall(t, srv, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"caching_proxy_set_offline","arguments":{"on":true}}}`, "")
	errObj, ok := got["error"].(map[string]any)
	if !ok {
		t.Fatalf("an unconfigured gate must refuse a mutating tool: %v", got)
	}
	if errObj["data"].(map[string]any)["reason"] != "auth-unconfigured" {
		t.Errorf("reason = %v, want the gate's own token", errObj["data"])
	}
	if len(fx.calls) != 0 {
		t.Fatalf("a refused tool must run no command; ran %v", fx.calls)
	}
}

func TestMcpRemoteModeRefusalCarriesTheSameTokenAsTheRoute(t *testing.T) {
	// An operator who knows what caching-proxy-remote-readonly means from the
	// 501 body must not have to learn a second vocabulary for MCP.
	srv, fx := newDaemonWithGate(t, modeRemote, testBearer)
	got := mcpCall(t, srv,
		`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"caching_proxy_set_offline","arguments":{"on":true}}}`,
		testBearer)
	errObj, ok := got["error"].(map[string]any)
	if !ok {
		t.Fatalf("remote mode must refuse: %v", got)
	}
	if errObj["data"].(map[string]any)["reason"] != "caching-proxy-remote-readonly" {
		t.Errorf("reason = %v", errObj["data"])
	}
	if len(fx.calls) != 0 {
		t.Fatalf("remote mode must run no command; ran %v", fx.calls)
	}
}

func TestMcpMutatingToolRunsForAnAuthorisedCaller(t *testing.T) {
	srv, fx := newDaemonWithGate(t, modeLocal, testBearer)
	got := mcpCall(t, srv,
		`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"caching_proxy_set_offline","arguments":{"on":true}}}`,
		testBearer)
	res, ok := got["result"].(map[string]any)
	if !ok {
		t.Fatalf("an authorized mutation was refused: %v", got)
	}
	if res["isError"] != false {
		t.Fatalf("mutation errored: %v", res)
	}
	// The same `squid -k reconfigure` the HTTP route runs.
	if len(fx.calls) != 1 || fx.calls[0][1] != "-k" || fx.calls[0][2] != "reconfigure" {
		t.Fatalf("expected one reconfigure, got %v", fx.calls)
	}
}

func TestMcpInitializeNamesThisService(t *testing.T) {
	srv, _ := newDaemonWithGate(t, modeLocal, testBearer)
	got := mcpCall(t, srv, `{"jsonrpc":"2.0","id":7,"method":"initialize"}`, "")
	info := got["result"].(map[string]any)["serverInfo"].(map[string]any)
	if info["name"] != "caching-proxy-service" || info["version"] != testVersion {
		t.Errorf("serverInfo = %v", info)
	}
}

// --- the dashboard's landing page -----------------------------------------

func TestIndexIsServedWhereTheDashboardLinks(t *testing.T) {
	// The Extension hosts cell deep-links to the address this daemon
	// announces. Before this page that link answered 404, which reads as "the
	// service is broken" -- the opposite of what it meant.
	srv, _ := newDaemon(t, modeLocal)
	for _, path := range []string{"/", "/index.html"} {
		resp := get(t, srv, path)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s = %d, want 200", path, resp.StatusCode)
		}
		if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
			t.Errorf("GET %s Content-Type = %q", path, ct)
		}
	}
}

func TestIndexIsSelfContainedAndDoesNotBuildRowsWithInnerHtml(t *testing.T) {
	// The proxy VM serves this to a browser that may have no route off the lab
	// network, so an external asset would render a broken page on exactly the
	// machine whose job is to make the network unnecessary. And everything
	// shown comes from squid, zot and an operator-influenced switch source.
	srv, _ := newDaemon(t, modeLocal)
	resp := get(t, srv, "/")
	body, _ := io.ReadAll(resp.Body)
	page := string(body)

	for _, external := range []string{"src=\"http", "href=\"http", "@import", "//fonts."} {
		if strings.Contains(page, external) {
			t.Errorf("the page references an external asset (%s)", external)
		}
	}
	if strings.Contains(page, "innerHTML") {
		t.Error("rows must be built with textContent; squid and zot fields are not this daemon's to trust")
	}
	// It renders the read surface, so it must not offer a write it cannot gate.
	for _, mutating := range []string{"/api/switches/offline\"", "/api/switches/no-upstream\""} {
		if strings.Contains(page, "fetch('"+mutating) {
			t.Errorf("the page posts to %s; it is read-only by design", mutating)
		}
	}
}

func TestIndexCarriesItsOwnContentSecurityPolicy(t *testing.T) {
	srv, _ := newDaemon(t, modeLocal)
	resp := get(t, srv, "/")
	csp := resp.Header.Get("Content-Security-Policy")
	if csp == "" {
		t.Fatal("the page must ship a CSP")
	}
	for _, directive := range []string{"default-src 'none'", "connect-src 'self'", "frame-ancestors 'none'"} {
		if !strings.Contains(csp, directive) {
			t.Errorf("CSP is missing %q: %s", directive, csp)
		}
	}
	if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Error("the page must be served nosniff")
	}
}

func TestUnknownPathsStill404(t *testing.T) {
	// The root pattern is anchored, so a stray path must not reach the page.
	srv, _ := newDaemon(t, modeLocal)
	if resp := get(t, srv, "/not-a-page"); resp.StatusCode != http.StatusNotFound {
		t.Errorf("GET /not-a-page = %d, want 404", resp.StatusCode)
	}
}

// TestRecentRequestsRepublishesTheParserTail covers the hop this service makes
// on behalf of a daemon that deliberately has no agent surface of its own.
func TestRecentRequestsRepublishesTheParserTail(t *testing.T) {
	rows := `[{"ts_iso":"2026-08-22T09:14:02.511Z","client_ip":"192.168.7.61","status":"TCP_HIT/200",` +
		`"bytes":91234,"method":"GET","url":"http://archive.ubuntu.com/x.deb","ua":"curl/8.5.0"},` +
		`{"ts_iso":"2026-08-22T09:14:03.002Z","client_ip":"192.168.7.62","status":"TCP_MISS/404",` +
		`"bytes":512,"method":"GET","url":"http://example.invalid/missing","ua":"-"}]`
	parser := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/recent-requests" {
			t.Errorf("parser asked for %q, want /recent-requests", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(rows))
	}))
	defer parser.Close()

	version = testVersion
	d := newTestDaemon(t, modeLocal, t.TempDir(), &fakeExec{}, "")
	d.readSwitches = func() SwitchState { return SwitchState{Source: "test"} }
	d.parserURL = parser.URL
	srv := httptest.NewServer(d.routes())
	defer srv.Close()

	got := callRecentRequests(t, srv, `{}`)
	if got["count"] != float64(2) {
		t.Fatalf("count = %v, want 2", got["count"])
	}
	list, _ := got["requests"].([]any)
	if len(list) != 2 {
		t.Fatalf("requests = %v, want 2 rows", got["requests"])
	}
	first, _ := list[0].(map[string]any)
	if first["client_ip"] != "192.168.7.61" || first["status"] != "TCP_HIT/200" {
		t.Errorf("first row = %v; the tail must be republished verbatim", first)
	}

	// limit is what makes this usable for a caller that wants a glance rather
	// than the whole ring.
	got = callRecentRequests(t, srv, `{"limit":1}`)
	if got["count"] != float64(1) || got["limit"] != float64(1) {
		t.Errorf("limited call = %v, want one row and limit 1", got)
	}
}

// TestRecentRequestsSaysWhenTheParserIsSilent guards the difference between "the
// proxy served nothing" and "nothing answered". Reporting the second as an empty
// list would turn an operational fault into a quiet, plausible zero.
func TestRecentRequestsSaysWhenTheParserIsSilent(t *testing.T) {
	version = testVersion
	d := newTestDaemon(t, modeLocal, t.TempDir(), &fakeExec{}, "")
	d.readSwitches = func() SwitchState { return SwitchState{Source: "test"} }
	d.parserURL = "http://127.0.0.1:1" // nothing listens here
	srv := httptest.NewServer(d.routes())
	defer srv.Close()

	resp, err := http.Get(srv.URL + routeRecentRequests)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503 naming the parser", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "caching-proxy-parser-service") {
		t.Errorf("body = %q; it must name what did not answer", body)
	}
}

// callRecentRequests drives the tool the way an agent would and returns the
// object it answers with.
func callRecentRequests(t *testing.T, srv *httptest.Server, args string) map[string]any {
	t.Helper()
	body := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"caching_proxy_recent_requests","arguments":` + args + `}}`
	got := mcpCall(t, srv, body, "")
	res, ok := got["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result in %v", got)
	}
	if res["isError"] == true {
		t.Fatalf("tool call failed: %v", res)
	}
	if sc, ok := res["structuredContent"].(map[string]any); ok {
		return sc
	}
	content, _ := res["content"].([]any)
	if len(content) == 0 {
		t.Fatalf("no content in %v", res)
	}
	text, _ := content[0].(map[string]any)["text"].(string)
	var out map[string]any
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("unreadable tool text %q: %v", text, err)
	}
	return out
}
