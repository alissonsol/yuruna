// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"net/http"

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
		{"pool_control_board", "Read the operator board: every pool, its hosts, and the test set each one runs.", "/api/board", s.handleBoard},
		{"pool_control_hosts", "Read every host the pool control service knows, with its current state.", "/api/hosts", s.handleHosts},
		{"pool_control_host_facts", "Read the per-host facts behind the board's cards.", "/api/hosts/facts", s.handleHostFacts},
		{"pool_control_state", "Read the daemon's own state: last write, last action, whether the intent store is readable.", "/api/state", s.handleState},
		{"pool_control_diagnostics", "Read the diagnostic report: what this service can reach, what it cannot, and why.", "/api/diagnostics", s.handleDiagnostics},
		{"pool_control_hostinfo", "Read this daemon's host id, stamped version and own addresses.", "/api/hostinfo", s.handleHostInfo},
	} {
		reg.MustAdd(mcp.Tool{
			Name:        t.name,
			Description: t.desc,
			InputSchema: noArgs,
			ReadOnly:    true,
			Handler:     mcp.FromRoute(t.h, http.MethodGet, t.route),
		})
	}
	return reg
}

func (s *Server) mcpServer() *mcp.Server {
	return mcp.NewServer("pool-control-service", s.opts.Version, s.mcpRegistry(),
		mcp.ConfiguredGate(s.gate.Configured, s.gate.Authed))
}
