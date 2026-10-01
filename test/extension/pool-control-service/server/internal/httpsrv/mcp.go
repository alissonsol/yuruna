// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"net/http"
	"net/url"
	"yuruna.com/test/extension/extension-sdk/strictjson"

	"yuruna.com/test/extension/extension-sdk/mcp"
)

// mcpRegistry is this daemon's MCP surface.
//
// Every tool is mcp.FromRoute over the handler its HTTP route already uses, so
// a tool cannot answer differently from the route -- one body, produced once.
//
// The read tools wrap open routes and carry exactly their exposure. The
// mutating tools rewrite the pool intent store by shelling out to the
// pool-admin CLIs -- each one commits and pushes -- so they sit behind the
// daemon's own write gate; see the mutating block below.
func (s *Server) mcpRegistry() *mcp.Registry {
	reg := mcp.NewRegistry()
	noArgs := json.RawMessage(`{"type":"object","properties":{}}`)

	for _, t := range []struct {
		name, desc, route string
		h                 http.HandlerFunc
	}{
		{"pool_control_board", "Read the operator board as of this instant: every pool, its hosts, and the framework and project repositories each one runs. The pool membership comes from the intent store this daemon last pulled, so it is as fresh as the last sync rather than live.", "/api/board", s.handleBoard},
		{"pool_control_hosts", "Read every host the pool control service knows, with its current state.", "/api/hosts", s.handleHosts},
		{"pool_control_host_facts", "Read the per-host facts behind the board's cards.", "/api/hosts/facts", s.handleHostFacts},
		{"pool_control_state", "Read the daemon's own state: last write, last action, whether the intent store is readable.", "/api/state", s.handleState},
		{"pool_control_diagnostics", "Read the diagnostic report: what this service can reach, what it cannot, and why. Probes run when the route is called, so this is a live check and can take a few seconds. Use it when a read above answers but looks wrong.", "/api/diagnostics", s.handleDiagnostics},
		{"pool_control_hostinfo", "Read this daemon's host id, stamped version and own addresses.", "/api/hostinfo", s.handleHostInfo},
		{"pool_control_scan_status", "Read the network scan: whether one is running, the CIDR it covers, how far it has got, and every host it has found so far. This is what the Scan page shows.", "/api/scan", s.handleScanStatus},
		{"pool_control_host_control_state", "Read the per-pool control state (continue, pause-after-cycle, pause-after-step) and which members disagree with it -- the answer behind the board's \"Mixed\" cell.", "/api/pool/host-control", s.handleHostControlState},
	} {
		reg.MustAdd(mcp.Tool{
			Name:        t.name,
			Description: t.desc,
			InputSchema: noArgs,
			ReadOnly:    true,
			Handler:     mcp.FromRoute(t.h, http.MethodGet, t.route),
		})
	}
	// --- REGION: Mutating tools
	//
	// Every one of these is ReadOnly:false, which is what makes the MCP server
	// run s.gate.Allow on the INCOMING request before the handler is reached --
	// the daemon's own Authed, so an agent and a curl face the same check. The
	// handler is wrapped raw on purpose: wrapping the GATED handler would test
	// a synthesized request that carries no credential and refuse everything.
	//
	// Deliberately absent: new-pool and remove-pool (remove-pool commits and
	// pushes a deletion), and the scan verbs (they aim a burst of connection
	// attempts at a network the caller names).
	type mut struct {
		name, desc, method, target string
		destructive, idempotent    bool
		schema                     string
		h                          http.HandlerFunc
		build                      func(json.RawMessage) (string, []byte, error)
	}
	obj := func(m map[string]any) ([]byte, error) { return json.Marshal(m) }
	str := func(args json.RawMessage, keys ...string) (map[string]string, error) {
		var in map[string]string
		if len(args) > 0 {
			if err := json.Unmarshal(args, &in); err != nil {
				return nil, &mcp.ReasonError{Reason: "invalid-arguments", Message: "arguments must be an object of strings"}
			}
		}
		if in == nil {
			in = map[string]string{}
		}
		for _, k := range keys {
			if in[k] == "" {
				return nil, &mcp.ReasonError{Reason: "invalid-arguments", Message: k + " is required"}
			}
		}
		return in, nil
	}

	for _, t := range []mut{
		{
			name: "pool_control_set_host_control",
			desc: "Pause or continue every host in a pool. `action` is continue, pause-after-cycle or pause-after-step. " +
				"Returns the per-member result: which hosts took the change and which refused, with the reason -- that list is the answer, not the overall ok.",
			method: http.MethodPost, target: "/api/pool/host-control", idempotent: true,
			schema: `{"type":"object","properties":{"poolId":{"type":"string","description":"pool id as listed by pool_control_state"},"action":{"type":"string","enum":["continue","pause-after-cycle","pause-after-step"],"description":"where the pool is allowed to stop; continue clears a pending pause"}},"required":["poolId","action"],"additionalProperties":false}`,
			h:      s.handleHostControlApply,
			build: func(a json.RawMessage) (string, []byte, error) {
				in, err := str(a, "poolId", "action")
				if err != nil {
					return "", nil, err
				}
				b, err := obj(map[string]any{"poolId": in["poolId"], "action": in["action"]})
				return "", b, err
			},
		},
		{
			name: "pool_control_set_pool_repositories",
			desc: "Set the framework and project repositories every host in a pool runs, from its next cycle. " +
				"Pass both URLs to set them, or pass both empty (or omit both) to clear them so each host goes back to its own configured repositories. " +
				"The auto-enrollment target pool cannot carry repositories.",
			method: http.MethodPost, target: "/api/pool/repositories", idempotent: true,
			schema: `{"type":"object","properties":{"poolId":{"type":"string","description":"pool id as listed by pool_control_state"},"frameworkUrl":{"type":"string","description":"git URL the hosts clone the framework from; empty together with projectUrl clears both"},"projectUrl":{"type":"string","description":"git URL the hosts clone the project from; empty together with frameworkUrl clears both"}},"required":["poolId"],"additionalProperties":false}`,
			h:      s.handleSetPoolRepositories,
			build: func(a json.RawMessage) (string, []byte, error) {
				// strictStringArgs rather than str: str refuses an empty required
				// value, and both URLs empty is how this tool clears a pool.
				in, err := strictStringArgs(a, []string{"poolId"}, []string{"frameworkUrl", "projectUrl"})
				if err != nil {
					return "", nil, err
				}
				b, err := obj(map[string]any{"poolId": in["poolId"], "frameworkUrl": in["frameworkUrl"], "projectUrl": in["projectUrl"]})
				return "", b, err
			},
		},
		{
			name: "pool_control_move_host",
			desc: "Move one host into a pool. An empty toPoolId removes it from every pool AND records an exclusion, " +
				"so the auto-enrollment sweep does not put it back within the minute.",
			method: http.MethodPost, target: "/api/pool/move-host", idempotent: true,
			schema: `{"type":"object","properties":{"hostId":{"type":"string","description":"host id as listed by pool_control_hosts"},"toPoolId":{"type":"string","description":"target pool; empty means remove and exclude"}},"required":["hostId"],"additionalProperties":false}`,
			h:      s.handleMoveHost,
			build: func(a json.RawMessage) (string, []byte, error) {
				in, err := str(a, "hostId")
				if err != nil {
					return "", nil, err
				}
				b, err := obj(map[string]any{"hostId": in["hostId"], "poolId": in["toPoolId"]})
				return "", b, err
			},
		},
		{
			name:   "pool_control_add_host",
			desc:   "Add one host to a pool. Membership is re-addable, so this is safe to repeat.",
			method: http.MethodPost, target: "/api/pool/host", idempotent: true,
			schema: `{"type":"object","properties":{"poolId":{"type":"string","description":"pool id as listed by pool_control_state"},"hostId":{"type":"string","description":"host id as listed by pool_control_hosts"}},"required":["poolId","hostId"],"additionalProperties":false}`,
			h:      s.handleAddHost,
			build: func(a json.RawMessage) (string, []byte, error) {
				in, err := str(a, "poolId", "hostId")
				if err != nil {
					return "", nil, err
				}
				b, err := obj(map[string]any{"poolId": in["poolId"], "hostId": in["hostId"]})
				return "", b, err
			},
		},
		{
			name: "pool_control_remove_host",
			desc: "Remove one host from a pool. Not destructive in the undo sense -- the host can be added back with " +
				"pool_control_add_host -- but the auto-enrollment sweep may re-add it on its own; use pool_control_move_host with an empty toPoolId to exclude it instead.",
			method: http.MethodDelete, target: "/api/pool/host", idempotent: true,
			schema: `{"type":"object","properties":{"poolId":{"type":"string","description":"pool id as listed by pool_control_state"},"hostId":{"type":"string","description":"host id as listed by pool_control_hosts"}},"required":["poolId","hostId"],"additionalProperties":false}`,
			h:      s.handleRemoveHost,
			build: func(a json.RawMessage) (string, []byte, error) {
				in, err := str(a, "poolId", "hostId")
				if err != nil {
					return "", nil, err
				}
				return "/api/pool/host?poolId=" + url.QueryEscape(in["poolId"]) + "&hostId=" + url.QueryEscape(in["hostId"]), nil, nil
			},
		},
	} {
		reg.MustAdd(mcp.Tool{
			Name:        t.name,
			Description: t.desc,
			InputSchema: json.RawMessage(t.schema),
			ReadOnly:    false,
			Destructive: t.destructive,
			Idempotent:  t.idempotent,
			Handler:     mcp.FromRouteWithBody(t.h, t.method, t.target, t.build),
		})
	}

	// Per-host refresh, advertised only when this service holds both refresh
	// secrets: an agent is never shown a tool that could only refuse. The tool
	// gate is the refresh credential gate, run on the INCOMING request after
	// the server's write gate, so an agent needs exactly what a curl needs --
	// the ordinary write credential AND the refresh credential header.
	if s.refreshEnabled() {
		reg.MustAdd(mcp.Tool{
			Name: "pool_control_refresh_host",
			Description: "Ask ONE host to repair its hypervisor and test runner (the restart tier: reclaim a stalled runner, " +
				"start a stopped hypervisor service, restart a hung one where that host supports it). Generate requestId once " +
				"(a lowercase UUID) and reuse it on every retry, so a retry is never a second repair. Returns the host's " +
				"acceptance and a stateUrl to poll; a busy host names the request it is currently handling. Requires the refresh " +
				"credential header in addition to the ordinary write credential.",
			InputSchema: json.RawMessage(`{"type":"object","properties":{` +
				`"hostId":{"type":"string","description":"host id as listed by pool_control_hosts"},` +
				`"requestId":{"type":"string","description":"lowercase 8-4-4-4-12 UUID the caller generates once and reuses on retry"},` +
				`"tier":{"type":"string","enum":["restart"],"description":"only the restart tier is accepted remotely"},` +
				`"maxRung":{"type":"string","enum":["probe","reclaim","start-if-stopped","restart-if-hung","restart-broker"],"description":"highest repair rung allowed; defaults to restart-broker, and the host lowers it to what it supports"}},` +
				`"required":["hostId","requestId","tier"],"additionalProperties":false}`),
			ReadOnly:    false,
			Destructive: true,
			Idempotent:  true,
			Gate:        s.refreshGate,
			Handler: mcp.FromRouteWithBody(s.handleHostRefresh, http.MethodPost, "/api/host/refresh", func(a json.RawMessage) (string, []byte, error) {
				in, err := strictStringArgs(a, []string{"hostId", "requestId", "tier"}, []string{"maxRung"})
				if err != nil {
					return "", nil, err
				}
				b, err := json.Marshal(in)
				return "", b, err
			}),
		})
	}

	return reg
}

// strictStringArgs reads a tool's arguments as one object of strings holding
// only the named keys, each at most once: an unknown key (force, hard-stop,
// anything), a repeated key or a non-string value is a named refusal rather
// than a value silently dropped or overwritten, because the SDK does not
// enforce a tool's input schema at call time. The object is walked token by
// token because decoding into a map keeps the last of two equal keys without
// a trace. A refused key name is echoed only when it has the shape of a field
// name, so a caller cannot put arbitrary text into the refusal.
func strictStringArgs(args json.RawMessage, required, optional []string) (map[string]string, error) {
	refuse := func(msg string) error { return &mcp.ReasonError{Reason: "invalid-arguments", Message: msg} }
	notAnObject := refuse("arguments must be an object of strings")
	known := map[string]bool{}
	for _, k := range append(append([]string{}, required...), optional...) {
		known[k] = true
	}
	out := map[string]string{}
	if len(args) > 0 {
		values, refusal := strictjson.Strings(args, known, nil)
		if refusal != nil {
			shown := refusal.Field
			if !fieldNameRE.MatchString(shown) {
				shown = refreshFieldNamePlaceholder
			}
			switch refusal.Detail {
			case "unsupported_field":
				return nil, refuse("unsupported argument " + shown)
			case "duplicate_key":
				return nil, refuse(shown + " is given more than once")
			case "value_not_a_string":
				return nil, refuse(shown + " must be a string")
			default:
				return nil, notAnObject
			}
		}
		out = values
	}
	for _, k := range required {
		if out[k] == "" {
			return nil, refuse(k + " is required")
		}
	}
	return out, nil
}

func (s *Server) mcpServer() *mcp.Server {
	return mcp.NewServer("pool-control-service", s.opts.Version, s.mcpRegistry(),
		mcp.ConfiguredGate(s.gate.Configured, s.gate.Authed))
}
