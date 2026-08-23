// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"net/http"
	"net/url"

	"yuruna.com/test/extension/extension-sdk/mcp"
)

// mcpRegistry is this daemon's MCP surface.
//
// Every tool is mcp.FromRoute over the handler its HTTP route already uses, so
// a tool cannot answer differently from the route -- one body, produced once.
//
// Read-only. The mutating routes here rewrite the pool intent store by shelling
// out to the pool-admin CLIs, and each one commits and pushes; giving an agent
// those before an operator has watched the read tools in use would be adding a
// second way to change pool membership before the first is understood. They are
// a register item, and the gate is wired anyway so adding one cannot
// accidentally add an ungated one.
func (s *Server) mcpRegistry() *mcp.Registry {
	reg := mcp.NewRegistry()
	noArgs := json.RawMessage(`{"type":"object","properties":{}}`)

	for _, t := range []struct {
		name, desc, route string
		h                 http.HandlerFunc
	}{
		{"pool_control_board", "Read the operator board as of this instant: every pool, its hosts, and the test set each one runs. The pool membership comes from the intent store this daemon last pulled, so it is as fresh as the last sync rather than live.", "/api/board", s.handleBoard},
		{"pool_control_hosts", "Read every host the pool control service knows, with its current state.", "/api/hosts", s.handleHosts},
		{"pool_control_host_facts", "Read the per-host facts behind the board's cards.", "/api/hosts/facts", s.handleHostFacts},
		{"pool_control_state", "Read the daemon's own state: last write, last action, whether the intent store is readable.", "/api/state", s.handleState},
		{"pool_control_diagnostics", "Read the diagnostic report: what this service can reach, what it cannot, and why. Probes run when the route is called, so this is a live check and can take a few seconds. Use it when a read above answers but looks wrong.", "/api/diagnostics", s.handleDiagnostics},
		{"pool_control_hostinfo", "Read this daemon's host id, stamped version and own addresses.", "/api/hostinfo", s.handleHostInfo},
		// Two reads the UI shows and no tool reached. The deferral recorded
		// above is about the MUTATING routes and says nothing about a read.
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
	// --- Mutating tools -------------------------------------------------------
	//
	// The deferral this file used to record -- that these routes shell out to
	// the pool-admin CLIs, that each one commits and pushes, and that an agent
	// should not reach them before an operator has watched the read tools in
	// use -- was sound and is now discharged rather than ignored. The read
	// tools above shipped first and are in use; the register the comment
	// deferred to never held the item; and the operator asked for the controls.
	//
	// Every one of these is ReadOnly:false, which is what makes the MCP server
	// run s.gate.Allow on the INCOMING request before the handler is reached --
	// the daemon's own Authed, so an agent and a curl face the same check. The
	// handler is wrapped raw on purpose: wrapping the GATED handler would test
	// a synthesized request that carries no credential and refuse everything.
	//
	// Still deliberately absent: new-pool and remove-pool (a second pass --
	// remove-pool commits and pushes a deletion), and the scan verbs (they aim
	// a burst of connection attempts at a network the caller names).
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
			name:   "pool_control_assign_testset",
			desc:   "Assign a test set to a pool. Every host in the pool picks it up on its next cycle.",
			method: http.MethodPost, target: "/api/pool/testset", idempotent: true,
			schema: `{"type":"object","properties":{"poolId":{"type":"string","description":"pool id as listed by pool_control_state"},"name":{"type":"string","description":"test-set name to assign"},"frameworkUrl":{"type":"string","description":"git URL the hosts clone the framework from"},"projectUrl":{"type":"string","description":"git URL the hosts clone the project from"}},"required":["poolId","name","frameworkUrl","projectUrl"],"additionalProperties":false}`,
			h:      s.handleAssign,
			build: func(a json.RawMessage) (string, []byte, error) {
				in, err := str(a, "poolId", "name", "frameworkUrl", "projectUrl")
				if err != nil {
					return "", nil, err
				}
				b, err := obj(map[string]any{"poolId": in["poolId"], "name": in["name"],
					"frameworkURL": in["frameworkUrl"], "projectURL": in["projectUrl"]})
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

	return reg
}

func (s *Server) mcpServer() *mcp.Server {
	return mcp.NewServer("pool-control-service", s.opts.Version, s.mcpRegistry(),
		mcp.ConfiguredGate(s.gate.Configured, s.gate.Authed))
}
