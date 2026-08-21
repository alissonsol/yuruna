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
// Every tool is built with mcp.FromRoute over the handler the HTTP route
// already uses, so a tool cannot answer differently from the route it wraps --
// there is one body, produced once, by one function.
//
// Read-only, deliberately. The mutating routes here are per-image refresh,
// delete and prune, and the pool-wide refresh; wrapping those is a register
// item rather than an oversight, because the one route an agent would most
// want -- POST .../ensure -- is DELIBERATELY ungated on the HTTP side (it is
// the call a host makes for itself on the read path), and a tool for it could
// not both mirror its route's gate and honour the rule that a mutating tool
// takes the lab token. That contradiction is reconciled before it gets a tool,
// not by quietly picking one side.
func (s *Server) mcpRegistry() *mcp.Registry {
	reg := mcp.NewRegistry()
	noArgs := json.RawMessage(`{"type":"object","properties":{}}`)

	reg.MustAdd(mcp.Tool{
		Name:        "download_agent_status",
		Description: "Read the download agent's own state: version, host id, pool availability, lease holder, scanner cadence, and the gate posture.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleStatus, http.MethodGet, "/api/v1/status"),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "download_agent_images",
		Description: "List every guest image the pool holds, with its generations, freshness and current verdict.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleImages, http.MethodGet, "/api/v1/images"),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "download_agent_diagnostics",
		Description: "Read the agent's diagnostic report: what it can reach, what it cannot, and why.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleDiagnostics, http.MethodGet, "/api/v1/diagnostics"),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "download_agent_hostinfo",
		Description: "Read this daemon's host id, stamped version and own addresses.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleHostInfo, http.MethodGet, "/api/hostinfo"),
	})

	return reg
}

// mcpServer wires the registry to the daemon's own gate. Every tool here is
// read-only today, so the gate is never consulted -- it is passed anyway, so
// that adding a mutating tool cannot accidentally add an ungated one.
func (s *Server) mcpServer() *mcp.Server {
	return mcp.NewServer("download-agent-service", s.opts.Version, s.mcpRegistry(),
		mcp.ConfiguredGate(s.gate.Configured, s.gate.Authed))
}
