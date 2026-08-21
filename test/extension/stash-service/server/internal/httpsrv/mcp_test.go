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
	ts, _, _ := newTestUI(t)
	got := mcpPost(t, ts.URL, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	tools := got["result"].(map[string]any)["tools"].([]any)
	want := []string{"stash_hostinfo", "stash_list", "stash_session"}
	if len(tools) != len(want) {
		t.Fatalf("tools/list returned %d tools, want %d", len(tools), len(want))
	}
	for i, raw := range tools {
		m := raw.(map[string]any)
		if m["name"] != want[i] {
			t.Fatalf("tool %d = %v, want %s", i, m["name"], want[i])
		}
		if m["annotations"].(map[string]any)["readOnlyHint"] != true {
			t.Errorf("%v must be read-only; deleting reaches every host's stash and is not an agent's to call", m["name"])
		}
	}
}

// The mount sits beside a catch-all `GET /{id}` short-redirect. A literal
// pattern beats a wildcard on specificity, so /mcp is served and the short
// URLs are untouched -- but only a test says so when the wildcard changes.
func TestMcpMountDoesNotDisturbTheShortRedirects(t *testing.T) {
	ts, _, _ := newTestUI(t)

	got := mcpPost(t, ts.URL, `{"jsonrpc":"2.0","id":2,"method":"initialize"}`)
	info, ok := got["result"].(map[string]any)["serverInfo"].(map[string]any)
	if !ok || info["name"] != "stash-service" {
		t.Fatalf("POST /mcp did not reach the MCP server: %v", got)
	}

	// A bare id still reaches the short-redirect rather than the MCP mount.
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Get(ts.URL + "/h775")
	if err != nil {
		t.Fatalf("GET /h775: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusMethodNotAllowed {
		t.Error("the MCP mount swallowed the short-redirect route")
	}
}
