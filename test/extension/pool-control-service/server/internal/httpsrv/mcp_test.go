// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func mcpPost(t *testing.T, base, body string) map[string]any {
	t.Helper()
	resp, err := http.Post(base+"/mcp", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST /mcp: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("/mcp body is not JSON: %v (%s)", err, raw)
	}
	return out
}

func TestMcpToolsArePinnedAndReadOnly(t *testing.T) {
	srv := newTestServer(&fakeIntent{})
	defer srv.Close()
	got := mcpPost(t, srv.URL, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	tools := got["result"].(map[string]any)["tools"].([]any)
	// Read tools and control tools, in the order tools/list sorts them. Every
	// tool declares which it is here, and the assertion below keeps the
	// declarations honest.
	readOnly := map[string]bool{
		"pool_control_board":              true,
		"pool_control_diagnostics":        true,
		"pool_control_host_control_state": true,
		"pool_control_host_facts":         true,
		"pool_control_hostinfo":           true,
		"pool_control_hosts":              true,
		"pool_control_scan_status":        true,
		"pool_control_state":              true,
		"pool_control_add_host":           false,
		"pool_control_assign_testset":     false,
		"pool_control_move_host":          false,
		"pool_control_remove_host":        false,
		"pool_control_set_host_control":   false,
	}
	want := []string{
		"pool_control_add_host",
		"pool_control_assign_testset",
		"pool_control_board",
		"pool_control_diagnostics",
		"pool_control_host_control_state",
		"pool_control_host_facts",
		"pool_control_hostinfo",
		"pool_control_hosts",
		"pool_control_move_host",
		"pool_control_remove_host",
		"pool_control_scan_status",
		"pool_control_set_host_control",
		"pool_control_state",
	}
	if len(tools) != len(want) {
		t.Fatalf("tools/list returned %d tools, want %d", len(tools), len(want))
	}
	for i, raw := range tools {
		m := raw.(map[string]any)
		if m["name"] != want[i] {
			t.Fatalf("tool %d = %v, want %s", i, m["name"], want[i])
		}
		name := m["name"].(string)
		ro, known := readOnly[name]
		if !known {
			t.Fatalf("%s is not in the read-only/mutating table; a new tool must declare which it is", name)
		}
		if m["annotations"].(map[string]any)["readOnlyHint"] != ro {
			t.Errorf("%s: readOnlyHint is %v, want %v", name, m["annotations"].(map[string]any)["readOnlyHint"], ro)
		}
	}
}

func TestEveryMutatingToolPassesTheGate(t *testing.T) {
	// The invariant that makes the control tools safe to ship: a ReadOnly:false
	// tool is checked against the daemon's OWN gate on the incoming request
	// before its handler runs, so "may an agent do this" and "may a curl do
	// this" cannot drift apart. Enumerated from the registry rather than
	// eyeballed, so a tool added later cannot quietly skip it.
	srv := newTestServer(&fakeIntent{})
	defer srv.Close()
	got := mcpPost(t, srv.URL, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	tools := got["result"].(map[string]any)["tools"].([]any)
	mutating := 0
	for _, raw := range tools {
		m := raw.(map[string]any)
		if m["annotations"].(map[string]any)["readOnlyHint"] == true {
			continue
		}
		mutating++
		name := m["name"].(string)
		// An ungated daemon refuses every mutating tool with a NAMED reason.
		// newTestServer wires no internal authentication key, so this is the refusal path.
		call := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"` + name + `","arguments":{}}}`
		res := mcpPost(t, srv.URL, call)
		errObj, ok := res["error"].(map[string]any)
		if !ok {
			t.Errorf("%s answered without passing the gate: %v", name, res)
			continue
		}
		data, _ := errObj["data"].(map[string]any)
		if data == nil || data["reason"] == "" {
			t.Errorf("%s refused without a machine-readable reason: %v", name, errObj)
		}
	}
	if mutating == 0 {
		t.Fatal("no mutating tool found; this test would pass vacuously")
	}
}

func TestMcpToolAnswersExactlyWhatTheRouteAnswers(t *testing.T) {
	// FromRoute invokes the handler, so tool and route come from one function.
	// hostinfo is the pairing that proves it without a fixture: it touches no
	// intent store, so it answers the same either way. The routes that DO need
	// one are covered by the failure test below.
	srv := newTestServer(&fakeIntent{})
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/hostinfo")
	if err != nil {
		t.Fatalf("GET /api/hostinfo: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	routeBody, _ := io.ReadAll(resp.Body)
	var viaRoute map[string]any
	if err := json.Unmarshal(routeBody, &viaRoute); err != nil {
		t.Fatalf("route body is not JSON: %v (%s)", err, routeBody)
	}

	got := mcpPost(t, srv.URL, `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pool_control_hostinfo"}}`)
	res := got["result"].(map[string]any)
	if res["isError"] != false {
		t.Fatalf("hostinfo tool errored where the route did not: %v", res)
	}
	var viaTool map[string]any
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if err := json.Unmarshal([]byte(text), &viaTool); err != nil {
		t.Fatalf("tool text is not JSON: %v (%s)", err, text)
	}
	for key := range viaRoute {
		// heartbeatUtc and the like move between the two calls; the shape is
		// what must match, not a timestamp.
		if _, present := viaTool[key]; !present {
			t.Errorf("the tool dropped %q, which the route carries", key)
		}
	}
}

// A route that fails must fail THROUGH the tool, carrying its own body -- not
// be smoothed into an empty success.
func TestMcpToolSurfacesARouteFailure(t *testing.T) {
	srv := newTestServer(&fakeIntent{})
	defer srv.Close()
	got := mcpPost(t, srv.URL, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"pool_control_board"}}`)
	res := got["result"].(map[string]any)
	if res["isError"] != true {
		t.Fatalf("a failing route must reach the agent as isError: %v", res)
	}
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "pool intent read failed") {
		t.Errorf("the route's own message must survive: %q", text)
	}
}
