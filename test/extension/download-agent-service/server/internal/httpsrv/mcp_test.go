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

func mcpPost(t *testing.T, srv interface{ URL() string }, body string) map[string]any {
	t.Helper()
	resp, err := http.Post(srv.URL()+"/mcp", "application/json", strings.NewReader(body))
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

type urlHolder struct{ u string }

func (h urlHolder) URL() string { return h.u }

func TestMcpToolsArePinnedAndReadOnly(t *testing.T) {
	// The count and the names are the contract an agent's config is written
	// against; the annotation is what it reads before deciding to ask.
	srv, _ := newServer(t, Options{})
	got := mcpPost(t, urlHolder{srv.URL}, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	tools := got["result"].(map[string]any)["tools"].([]any)
	want := []string{
		"download_agent_diagnostics",
		"download_agent_hostinfo",
		"download_agent_images",
		"download_agent_status",
	}
	if len(tools) != len(want) {
		t.Fatalf("tools/list returned %d tools, want %d", len(tools), len(want))
	}
	for i, raw := range tools {
		m := raw.(map[string]any)
		if m["name"] != want[i] {
			t.Fatalf("tool %d = %v, want %s", i, m["name"], want[i])
		}
		if m["annotations"].(map[string]any)["readOnlyHint"] != true {
			t.Errorf("%v must be annotated read-only; this daemon mounts no mutating tool", m["name"])
		}
	}
}

func TestMcpStatusToolIsTheRouteItself(t *testing.T) {
	// FromRoute invokes the handler, so the tool body and the route body come
	// from one function. Comparing them is what pins that.
	srv, _ := newServer(t, Options{})

	resp := get(t, srv, "/api/v1/status")
	routeBody, _ := io.ReadAll(resp.Body)
	var viaRoute map[string]any
	if err := json.Unmarshal(routeBody, &viaRoute); err != nil {
		t.Fatalf("route body: %v", err)
	}

	got := mcpPost(t, urlHolder{srv.URL}, `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"download_agent_status"}}`)
	res := got["result"].(map[string]any)
	if res["isError"] != false {
		t.Fatalf("status tool errored: %v", res)
	}
	var viaTool map[string]any
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if err := json.Unmarshal([]byte(text), &viaTool); err != nil {
		t.Fatalf("tool text is not JSON: %v (%s)", err, text)
	}
	for _, key := range []string{"version", "area", "hostId", "ok"} {
		if viaTool[key] != viaRoute[key] {
			t.Errorf("%s differs between tool (%v) and route (%v)", key, viaTool[key], viaRoute[key])
		}
	}
}

func TestMcpInitializeNamesThisDaemon(t *testing.T) {
	srv, _ := newServer(t, Options{})
	got := mcpPost(t, urlHolder{srv.URL}, `{"jsonrpc":"2.0","id":3,"method":"initialize"}`)
	info := got["result"].(map[string]any)["serverInfo"].(map[string]any)
	if info["name"] != "download-agent-service" {
		t.Errorf("serverInfo name = %v", info["name"])
	}
}
