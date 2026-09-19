// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// newTestServer builds a server with one read-only and one mutating tool, and
// a gate that answers however the test needs. That pair is the whole surface
// worth covering here: what a tool DOES belongs to the daemon that owns it.
func newTestServer(t *testing.T, gate Gate) *httptest.Server {
	t.Helper()
	reg := NewRegistry()
	reg.MustAdd(Tool{
		Name:        "read_status",
		Description: "read something",
		ReadOnly:    true,
		InputSchema: json.RawMessage(`{"type":"object","properties":{}}`),
		Handler: func(_ context.Context, _ json.RawMessage) (any, error) {
			return map[string]any{"ok": true, "value": 42}, nil
		},
	})
	reg.MustAdd(Tool{
		Name:        "set_switch",
		Description: "change something",
		Idempotent:  true,
		InputSchema: json.RawMessage(`{"type":"object","properties":{"on":{"type":"boolean"}},"required":["on"]}`),
		Handler: func(_ context.Context, args json.RawMessage) (any, error) {
			var in struct {
				On bool `json:"on"`
			}
			if err := json.Unmarshal(args, &in); err != nil {
				return nil, err
			}
			return map[string]any{"ok": true, "on": in.On}, nil
		},
	})
	srv := httptest.NewServer(NewServer("test-service", "2026.09.18", reg, gate).Handler())
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, body string) map[string]any {
	t.Helper()
	resp, err := srv.Client().Post(srv.URL, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusAccepted {
		return nil
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want 200 (a JSON-RPC error is still a 200)", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	return out
}

func openGate() Gate { return OpenGate }
func shutGate(reason, msg string) Gate {
	return GateFunc(func(*http.Request) (bool, string, string) { return false, reason, msg })
}

func TestInitializeAnswersThePinnedProtocol(t *testing.T) {
	srv := newTestServer(t, openGate())
	got := call(t, srv, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	res, ok := got["result"].(map[string]any)
	if !ok {
		t.Fatalf("initialize: %v", got)
	}
	if res["protocolVersion"] != ProtocolVersion {
		t.Errorf("protocolVersion = %v, want %s", res["protocolVersion"], ProtocolVersion)
	}
	caps, _ := res["capabilities"].(map[string]any)
	if _, hasTools := caps["tools"]; !hasTools {
		t.Errorf("capabilities must advertise tools: %v", caps)
	}
	// Resources and prompts are deliberately absent; advertising them would
	// promise methods this package does not serve.
	for _, unsupported := range []string{"resources", "prompts", "sampling"} {
		if _, present := caps[unsupported]; present {
			t.Errorf("capabilities advertise %q, which is not served", unsupported)
		}
	}
	info, _ := res["serverInfo"].(map[string]any)
	if info["name"] != "test-service" || info["version"] != "2026.09.18" {
		t.Errorf("serverInfo = %v", info)
	}
}

func TestToolsListIsSortedAndCarriesAnnotations(t *testing.T) {
	srv := newTestServer(t, openGate())
	got := call(t, srv, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	res := got["result"].(map[string]any)
	tools := res["tools"].([]any)
	if len(tools) != 2 {
		t.Fatalf("tools/list returned %d tools, want 2", len(tools))
	}
	first := tools[0].(map[string]any)
	second := tools[1].(map[string]any)
	// Sorted, so a pinned count and a pinned order both mean something.
	if first["name"] != "read_status" || second["name"] != "set_switch" {
		t.Fatalf("tools are not sorted by name: %v, %v", first["name"], second["name"])
	}
	ann := first["annotations"].(map[string]any)
	if ann["readOnlyHint"] != true {
		t.Errorf("read_status must be annotated read-only: %v", ann)
	}
	if second["annotations"].(map[string]any)["readOnlyHint"] != false {
		t.Errorf("set_switch must not be annotated read-only")
	}
	if _, ok := first["inputSchema"].(map[string]any); !ok {
		t.Errorf("inputSchema must be an object, got %T", first["inputSchema"])
	}
}

func TestReadOnlyToolSkipsTheGate(t *testing.T) {
	// The gate here refuses everything. A read-only tool must still answer:
	// it carries the exposure of the route it wraps, and those routes are open.
	srv := newTestServer(t, shutGate("auth-unconfigured", "no"))
	got := call(t, srv, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_status"}}`)
	res, ok := got["result"].(map[string]any)
	if !ok {
		t.Fatalf("a read-only tool was refused: %v", got)
	}
	if res["isError"] != false {
		t.Errorf("isError = %v", res["isError"])
	}
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, `"value": 42`) {
		t.Errorf("handler result did not reach the content: %q", text)
	}
}

func TestMutatingToolCarriesTheGatesOwnReason(t *testing.T) {
	// The reason token is the point: an operator who knows what
	// lab-token-unavailable means over HTTP must not have to learn a second
	// vocabulary for MCP.
	srv := newTestServer(t, shutGate("lab-token-unavailable", "the pool aggregator could not check the lab token"))
	got := call(t, srv, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_switch","arguments":{"on":true}}}`)
	errObj, ok := got["error"].(map[string]any)
	if !ok {
		t.Fatalf("a refused mutation must be a JSON-RPC error: %v", got)
	}
	if int(errObj["code"].(float64)) != CodeRefused {
		t.Errorf("code = %v, want %d", errObj["code"], CodeRefused)
	}
	data := errObj["data"].(map[string]any)
	if data["reason"] != "lab-token-unavailable" {
		t.Errorf("reason = %v, want the gate's own token", data["reason"])
	}
	if !strings.Contains(errObj["message"].(string), "could not check") {
		t.Errorf("message = %v", errObj["message"])
	}
}

func TestMutatingToolRunsWhenTheGateAllows(t *testing.T) {
	srv := newTestServer(t, openGate())
	got := call(t, srv, `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"set_switch","arguments":{"on":true}}}`)
	res, ok := got["result"].(map[string]any)
	if !ok {
		t.Fatalf("allowed mutation: %v", got)
	}
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, `"on": true`) {
		t.Errorf("arguments did not reach the handler: %q", text)
	}
}

func TestNilGateFailsClosed(t *testing.T) {
	// A daemon that forgot to wire its gate must refuse, not admit.
	reg := NewRegistry()
	reg.MustAdd(Tool{Name: "mutate", Handler: func(context.Context, json.RawMessage) (any, error) { return "done", nil }})
	srv := httptest.NewServer(NewServer("x", "1", reg, nil).Handler())
	defer srv.Close()
	got := call(t, srv, `{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"mutate"}}`)
	errObj, ok := got["error"].(map[string]any)
	if !ok {
		t.Fatalf("a nil gate must refuse mutations, got %v", got)
	}
	if errObj["data"].(map[string]any)["reason"] != "auth-unconfigured" {
		t.Errorf("reason = %v", errObj["data"])
	}
}

func TestDomainRefusalKeepsItsReason(t *testing.T) {
	// A handler that refuses for its own reasons -- remote mode, say -- reports
	// the same token its HTTP route reports, not a generic failure.
	reg := NewRegistry()
	reg.MustAdd(Tool{
		Name: "set_offline",
		Handler: func(context.Context, json.RawMessage) (any, error) {
			return nil, &ReasonError{Reason: "caching-proxy-remote-readonly", Message: "this daemon is in remote mode"}
		},
	})
	srv := httptest.NewServer(NewServer("x", "1", reg, OpenGate).Handler())
	defer srv.Close()
	got := call(t, srv, `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"set_offline"}}`)
	errObj := got["error"].(map[string]any)
	if errObj["data"].(map[string]any)["reason"] != "caching-proxy-remote-readonly" {
		t.Errorf("domain reason lost: %v", errObj)
	}
}

func TestHandlerFailureIsAResultNotATransportError(t *testing.T) {
	// The agent asked a legitimate question; the answer is that it did not
	// work. Reporting that as a JSON-RPC error would hide it from a client
	// that only surfaces results.
	reg := NewRegistry()
	reg.MustAdd(Tool{
		Name:     "boom",
		ReadOnly: true,
		Handler: func(context.Context, json.RawMessage) (any, error) {
			return nil, errAnyFailure
		},
	})
	srv := httptest.NewServer(NewServer("x", "1", reg, OpenGate).Handler())
	defer srv.Close()
	got := call(t, srv, `{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"boom"}}`)
	if _, isErr := got["error"]; isErr {
		t.Fatalf("a handler failure must be a result with isError, got %v", got)
	}
	res := got["result"].(map[string]any)
	if res["isError"] != true {
		t.Errorf("isError = %v", res["isError"])
	}
}

var errAnyFailure = errors.New("the share is not mounted")

func TestUnknownMethodAndUnknownTool(t *testing.T) {
	srv := newTestServer(t, openGate())
	for _, tc := range []struct {
		body string
		code int
	}{
		{`{"jsonrpc":"2.0","id":9,"method":"resources/list"}`, CodeMethodNotFound},
		{`{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nope"}}`, CodeInvalidParams},
	} {
		got := call(t, srv, tc.body)
		errObj, ok := got["error"].(map[string]any)
		if !ok {
			t.Fatalf("%s: expected an error, got %v", tc.body, got)
		}
		if int(errObj["code"].(float64)) != tc.code {
			t.Errorf("%s: code = %v, want %d", tc.body, errObj["code"], tc.code)
		}
	}
}

func TestMalformedInputIsRejectedPolitely(t *testing.T) {
	srv := newTestServer(t, openGate())
	for _, tc := range []struct {
		name, body string
		code       int
	}{
		{"not json", `{nope`, CodeParse},
		{"wrong version", `{"jsonrpc":"1.0","id":1,"method":"initialize"}`, CodeInvalidRequest},
		{"params not an object", `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"hello"}`, CodeInvalidParams},
	} {
		got := call(t, srv, tc.body)
		errObj, ok := got["error"].(map[string]any)
		if !ok {
			t.Fatalf("%s: expected an error, got %v", tc.name, got)
		}
		if int(errObj["code"].(float64)) != tc.code {
			t.Errorf("%s: code = %v, want %d", tc.name, errObj["code"], tc.code)
		}
	}
}

func TestNotificationGetsNoBody(t *testing.T) {
	// A notification has no id and takes no response AT ALL -- not an empty
	// one. Answering it puts a message on the wire the client has no slot for.
	srv := newTestServer(t, openGate())
	resp, err := srv.Client().Post(srv.URL, "application/json",
		strings.NewReader(`{"jsonrpc":"2.0","method":"notifications/initialized"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusAccepted {
		t.Errorf("notification got %d, want 202", resp.StatusCode)
	}
}

func TestIdIsEchoedVerbatim(t *testing.T) {
	// JSON-RPC ids may be numbers or strings, and a client matches responses by
	// exact value. Re-encoding a string id as a number loses the match.
	srv := newTestServer(t, openGate())
	got := call(t, srv, `{"jsonrpc":"2.0","id":"abc-123","method":"initialize"}`)
	if got["id"] != "abc-123" {
		t.Errorf("id = %v, want the string it was sent as", got["id"])
	}
}

func TestGetIsRefusedWithAllow(t *testing.T) {
	srv := newTestServer(t, openGate())
	resp, err := srv.Client().Get(srv.URL)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET /mcp = %d, want 405", resp.StatusCode)
	}
	if resp.Header.Get("Allow") != http.MethodPost {
		t.Errorf("405 must name the method that works, got %q", resp.Header.Get("Allow"))
	}
}

func TestRegistryRejectsUnusableTools(t *testing.T) {
	reg := NewRegistry()
	if err := reg.Add(Tool{Name: "", Handler: func(context.Context, json.RawMessage) (any, error) { return nil, nil }}); err == nil {
		t.Error("a tool with no name must be rejected")
	}
	if err := reg.Add(Tool{Name: "x"}); err == nil {
		t.Error("a tool with no handler must be rejected")
	}
}

func TestRegistryIsSafeForConcurrentUse(t *testing.T) {
	// A daemon registers at startup and serves from many goroutines. Run with
	// -race.
	reg := NewRegistry()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 200; i++ {
			_ = reg.Add(Tool{Name: "t", Handler: func(context.Context, json.RawMessage) (any, error) { return nil, nil }})
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 200; i++ {
			_ = reg.List()
			_, _ = reg.Get("t")
		}
	}()
	wg.Wait()
}

func TestArgumentsNormalisesAbsence(t *testing.T) {
	var tool Tool
	for _, raw := range []json.RawMessage{nil, json.RawMessage(""), json.RawMessage("null")} {
		if got := string(tool.Arguments(raw)); got != "{}" {
			t.Errorf("Arguments(%q) = %s, want {}", raw, got)
		}
	}
	if got := string(tool.Arguments(json.RawMessage(`{"a":1}`))); got != `{"a":1}` {
		t.Errorf("Arguments passed through wrong: %s", got)
	}
}

func TestConfiguredGateMirrorsTheRequireWrapper(t *testing.T) {
	// The three answers a labgate gives, in the order it gives them. If this
	// drifts, an agent and a curl get different verdicts on the same service.
	unconfigured := ConfiguredGate(func() bool { return false }, func(*http.Request) bool { return true })
	ok, reason, _ := unconfigured.Allow(nil)
	if ok || reason != "auth-unconfigured" {
		t.Errorf("unconfigured gate: ok=%v reason=%q", ok, reason)
	}
	locked := ConfiguredGate(func() bool { return true }, func(*http.Request) bool { return false })
	if ok, reason, _ := locked.Allow(nil); ok || reason != "unauthorized" {
		t.Errorf("locked gate: ok=%v reason=%q", ok, reason)
	}
	open := ConfiguredGate(func() bool { return true }, func(*http.Request) bool { return true })
	if ok, _, _ := open.Allow(nil); !ok {
		t.Error("an authed caller through a configured gate must pass")
	}
}

func TestFromRouteReturnsWhatTheRouteWrote(t *testing.T) {
	// The point of FromRoute is that a tool cannot answer differently from the
	// route, because it IS the route.
	route := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"who":"` + r.URL.Path + `"}`))
	}
	got, err := FromRoute(route, http.MethodGet, "/api/status")(context.Background(), nil)
	if err != nil {
		t.Fatalf("FromRoute: %v", err)
	}
	m := got.(map[string]any)
	if m["ok"] != true || m["who"] != "/api/status" {
		t.Errorf("route result = %v", m)
	}
}

func TestFromRoutePassesPlainTextThrough(t *testing.T) {
	route := func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) }
	got, err := FromRoute(route, http.MethodGet, "/healthz")(context.Background(), nil)
	if err != nil {
		t.Fatalf("FromRoute: %v", err)
	}
	if got != "ok\n" {
		t.Errorf("plain text result = %q", got)
	}
}

func TestFromRouteSurfacesARouteRefusal(t *testing.T) {
	// A route that refuses must refuse through the tool too, carrying its body.
	route := func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"ok":false,"reason":"auth-unconfigured"}`))
	}
	_, err := FromRoute(route, http.MethodGet, "/api/thing")(context.Background(), nil)
	if err == nil || !strings.Contains(err.Error(), "auth-unconfigured") {
		t.Errorf("a refusing route must surface its body, got %v", err)
	}
}
