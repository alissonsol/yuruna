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
// Read-only. The one mutating thing here is DELETE, and it reaches ANY host's
// stash on the shared mount rather than only this one's; that asymmetry is
// exactly why it is not an agent's to call yet. A register item.
func (s *Server) mcpRegistry() *mcp.Registry {
	reg := mcp.NewRegistry()
	noArgs := json.RawMessage(`{"type":"object","properties":{}}`)

	reg.MustAdd(mcp.Tool{
		Name:        "stash_list",
		Description: "List the pool-wide stash catalog: what has been uploaded, by which host, when, and how large.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleList, http.MethodGet, "/api/stashes"),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "stash_hostinfo",
		Description: "Read this daemon's host id, stamped version and own addresses.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleHostInfo, http.MethodGet, "/api/hostinfo"),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "stash_session",
		Description: "Read which ways through the delete gate exist on this service, and whether this caller is through one.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleSession, http.MethodGet, "/api/session"),
	})

	return reg
}

func (s *Server) mcpServer() *mcp.Server {
	return mcp.NewServer("stash-service", s.version, s.mcpRegistry(),
		mcp.ConfiguredGate(s.gate.Configured, s.gate.Authed))
}
