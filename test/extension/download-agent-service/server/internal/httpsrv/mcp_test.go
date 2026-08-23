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
		"download_agent_image",
		"download_agent_images",
		"download_agent_prune_image",
		"download_agent_refresh_image",
		"download_agent_session",
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
		name := m["name"].(string)
		if name == "download_agent_refresh_image" || name == "download_agent_prune_image" {
			if m["annotations"].(map[string]any)["readOnlyHint"] != false {
				t.Errorf("%s must NOT be read-only: it changes what the pool holds and passes the gate", name)
			}
			continue
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

func TestPerImageToolReachesItsRoute(t *testing.T) {
	// Two bugs shipped here, and neither was loud. The handler reads
	// r.PathValue, which resolves only for a ROUTED request, so a directly
	// called handler saw empty placeholders; and the schema did not declare
	// arch, which imageID() requires, so every caller landed in the route's
	// own 400. Both produced a plausible "you did not supply X" for an X the
	// caller had supplied.
	//
	// Asserted by CALLING the tool with everything its schema demands: whatever
	// comes back must not be a complaint about a missing argument.
	srv, _ := newServer(t, Options{})
	call := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"download_agent_image",` +
		`"arguments":{"hostType":"ubuntu.server.26","imageKey":"guest.ubuntu.server.26","arch":"amd64"}}}`
	got := mcpPost(t, urlHolder{srv.URL}, call)
	res, ok := got["result"].(map[string]any)
	if !ok {
		t.Fatalf("tools/call did not return a result: %v", got)
	}
	text := ""
	if c, ok := res["content"].([]any); ok && len(c) > 0 {
		if m, ok := c[0].(map[string]any); ok {
			text, _ = m["text"].(string)
		}
	}
	for _, bad := range []string{"is required", "are required", "are both required"} {
		if strings.Contains(text, bad) {
			t.Fatalf("the tool supplied every declared argument and the route still asked for one: %s", text)
		}
	}
}

// TestMcpEveryParameterIsSelfDescribing guards the failure class that shipped
// twice on this daemon: a schema an agent can read and still get wrong.
//
// The first was a MISSING parameter (arch), the second a WRONG one -- hostType
// was described as "guest host type, e.g. ubuntu.server.26", which is a guest
// name and never a valid value, so a caller following the description landed in
// the route's "unknown hostType". Both produced the same shape of wrongness: a
// plausible refusal of an argument the caller believed it had supplied
// correctly. A description is not decoration here; it is the whole interface.
//
// Where the accepted set is closed, an enum beats prose -- prose can be read
// two ways, an enum cannot.
func TestMcpEveryParameterIsSelfDescribing(t *testing.T) {
	srv, _ := newServer(t, Options{})
	got := mcpPost(t, urlHolder{srv.URL}, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)

	closedSets := map[string][]string{
		"hostType": {"windows.hyper-v", "ubuntu.kvm", "macos.utm"},
	}

	for _, raw := range got["result"].(map[string]any)["tools"].([]any) {
		m := raw.(map[string]any)
		name := m["name"].(string)
		schema, ok := m["inputSchema"].(map[string]any)
		if !ok {
			continue
		}
		props, ok := schema["properties"].(map[string]any)
		if !ok {
			continue
		}
		for param, rawSpec := range props {
			spec, ok := rawSpec.(map[string]any)
			if !ok {
				t.Errorf("%s.%s: schema property is not an object", name, param)
				continue
			}
			if desc, _ := spec["description"].(string); desc == "" {
				t.Errorf("%s.%s has no description; an agent has nothing to go on", name, param)
			}
			want, closed := closedSets[param]
			if !closed {
				continue
			}
			enum, ok := spec["enum"].([]any)
			if !ok {
				t.Errorf("%s.%s accepts a closed set; declare it as an enum rather than describing it", name, param)
				continue
			}
			if len(enum) != len(want) {
				t.Errorf("%s.%s enum has %d values, want %d", name, param, len(enum), len(want))
				continue
			}
			for i, v := range want {
				if enum[i] != v {
					t.Errorf("%s.%s enum[%d] = %v, want %s", name, param, i, enum[i], v)
				}
			}
		}
	}
}
