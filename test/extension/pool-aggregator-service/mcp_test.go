// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func mcpPost(t *testing.T, h http.Handler, body string) map[string]any {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body)))
	raw, _ := io.ReadAll(rec.Body)
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("/mcp body is not JSON: %v (%s)", err, raw)
	}
	return out
}

func TestMcpToolsArePinnedAndReadOnly(t *testing.T) {
	s := newPoolState("default", 8080)
	h := s.mcpServer("2026.08.21").Handler()
	got := mcpPost(t, h, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	tools := got["result"].(map[string]any)["tools"].([]any)
	want := []string{"pool_extension_hosts", "pool_stats", "pool_status"}
	if len(tools) != len(want) {
		t.Fatalf("tools/list returned %d tools, want %d", len(tools), len(want))
	}
	for i, raw := range tools {
		m := raw.(map[string]any)
		if m["name"] != want[i] {
			t.Fatalf("tool %d = %v, want %s", i, m["name"], want[i])
		}
		if m["annotations"].(map[string]any)["readOnlyHint"] != true {
			t.Errorf("%v must be read-only: /ingest is a firehose and forget-host deletes evidence", m["name"])
		}
	}
}

func TestMcpExtensionHostsToolIsTheRouteItself(t *testing.T) {
	// FromRoute invokes the handler, so tool and route come from one function.
	s := newPoolState("default", 8080)
	h := s.mcpServer("2026.08.21").Handler()

	rec := httptest.NewRecorder()
	s.handleExtensionHosts(rec, httptest.NewRequest(http.MethodGet, routeExtensionHosts, nil))
	var viaRoute map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &viaRoute); err != nil {
		t.Fatalf("route body is not JSON: %v (%s)", err, rec.Body.String())
	}

	got := mcpPost(t, h, `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pool_extension_hosts"}}`)
	res := got["result"].(map[string]any)
	if res["isError"] != false {
		t.Fatalf("extension-hosts tool errored: %v", res)
	}
	var viaTool map[string]any
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if err := json.Unmarshal([]byte(text), &viaTool); err != nil {
		t.Fatalf("tool text is not JSON: %v (%s)", err, text)
	}
	for key := range viaRoute {
		if _, present := viaTool[key]; !present {
			t.Errorf("the tool dropped %q, which the route carries", key)
		}
	}
}

func TestMcpServerInfoCarriesTheStampedVersion(t *testing.T) {
	// The aggregator gained a stamped version with this mount; before it, the
	// one daemon in the fleet that could not say what it was built from.
	s := newPoolState("default", 8080)
	got := mcpPost(t, s.mcpServer("2026.08.21").Handler(), `{"jsonrpc":"2.0","id":3,"method":"initialize"}`)
	info := got["result"].(map[string]any)["serverInfo"].(map[string]any)
	if info["name"] != "pool-aggregator-service" || info["version"] != "2026.08.21" {
		t.Errorf("serverInfo = %v", info)
	}
}
