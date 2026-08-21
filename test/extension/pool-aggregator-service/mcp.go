// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net/http"

	"yuruna.com/test/extension/extension-sdk/mcp"
)

// mcpRegistry is the aggregator's MCP surface: the three read routes that
// answer "what does this pool look like right now".
//
// Every tool is mcp.FromRoute over the handler its HTTP route already uses, so
// a tool cannot answer differently from the route -- one body, produced once.
//
// Read-only, and this one is not a deferral. The aggregator's two mutating
// routes are /ingest, which accepts telemetry from runners, and
// /api/v1/forget-host, which evicts a host from the view. Neither is a thing an
// agent should reach for: the first is a firehose with a bearer, and the second
// deletes evidence an operator may be in the middle of reading.
func (s *poolState) mcpRegistry() *mcp.Registry {
	reg := mcp.NewRegistry()
	noArgs := json.RawMessage(`{"type":"object","properties":{}}`)

	reg.MustAdd(mcp.Tool{
		Name:        "pool_status",
		Description: "Read the pool view: every host this aggregator has discovered, with its last poll, current address and cycle state.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handlePoolStatus, http.MethodGet, routePoolStatus),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "pool_extension_hosts",
		Description: "Read where each extension area is served in this pool, including the registrations the pool refuses and why.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleExtensionHosts, http.MethodGet, routeExtensionHosts),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "pool_stats",
		Description: "Read per-host terminal-cycle counts over the preset window -- the numbers behind the pool-control board's cards.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handlePoolStats, http.MethodGet, "/api/v1/pool-stats"),
	})

	return reg
}

// mcpServer serves the registry. The gate refuses everything: this daemon
// mounts no mutating tool, and a gate that would admit one is a gate nobody
// checked. Adding a mutating tool here means choosing a real gate first.
func (s *poolState) mcpServer(version string) *mcp.Server {
	return mcp.NewServer("pool-aggregator-service", version, s.mcpRegistry(),
		mcp.ConfiguredGate(func() bool { return false }, nil))
}
