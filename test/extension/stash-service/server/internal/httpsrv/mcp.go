// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
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
		Description: "Read which ways through the delete gate exist on this service, and whether this caller is through one. Answer it before a delete to know whether one would be refused.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleSession, http.MethodGet, "/api/session"),
	})
	// Two reads the UI makes and no tool reached. The deferral recorded above
	// is about DELETE and says nothing about a read.
	reg.MustAdd(mcp.Tool{
		Name: "stash_get",
		Description: "Read ONE stash's metadata -- its size, content class, original filename, owning host and status -- without pulling the whole catalog. " +
			"The five path parts come straight from a stash_list entry.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{` +
			`"hostId":{"type":"string","description":"owning host id, as listed by stash_list"},` +
			`"year":{"type":"string","description":"four-digit year, e.g. 2026"},` +
			`"month":{"type":"string","description":"two-digit month, e.g. 08"},` +
			`"day":{"type":"string","description":"two-digit day, e.g. 21"},` +
			`"id":{"type":"string","description":"stash id"}},` +
			`"required":["hostId","year","month","day","id"],"additionalProperties":false}`),
		ReadOnly: true,
		// FromPattern, not FromRouteWithArgs: handleGetMeta reads r.PathValue,
		// which resolves only for a ROUTED request -- called directly it saw
		// five empty placeholders.
		Handler: mcp.FromPattern("GET /api/stashes/{hostId}/{year}/{month}/{day}/{id}", s.handleGetMeta, http.MethodGet,
			func(args json.RawMessage) (string, []byte, error) {
				var in struct {
					HostID, Year, Month, Day, ID string
				}
				var raw map[string]string
				if len(args) > 0 {
					if err := json.Unmarshal(args, &raw); err != nil {
						return "", nil, &mcp.ReasonError{Reason: "invalid-arguments", Message: "arguments must be an object of strings"}
					}
				}
				in.HostID, in.Year, in.Month, in.Day, in.ID = raw["hostId"], raw["year"], raw["month"], raw["day"], raw["id"]
				if in.HostID == "" || in.Year == "" || in.Month == "" || in.Day == "" || in.ID == "" {
					return "", nil, &mcp.ReasonError{Reason: "invalid-arguments",
						Message: "hostId, year, month, day and id are all required"}
				}
				return "/api/stashes/" + url.PathEscape(in.HostID) + "/" + url.PathEscape(in.Year) + "/" +
					url.PathEscape(in.Month) + "/" + url.PathEscape(in.Day) + "/" + url.PathEscape(in.ID), nil, nil
			}),
	})
	reg.MustAdd(mcp.Tool{
		Name:        "stash_host",
		Description: "Resolve one host id to the stash UI that serves it, so a stash owned by a peer can be opened where it actually lives.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{"host":{"type":"string","description":"host id to resolve"}},"required":["host"],"additionalProperties":false}`),
		ReadOnly:    true,
		Handler: mcp.FromRouteWithArgs(s.handleHostResolve, http.MethodGet, "/api/host",
			func(args json.RawMessage) (string, error) {
				var in struct {
					Host string `json:"host"`
				}
				if len(args) > 0 {
					if err := json.Unmarshal(args, &in); err != nil {
						return "", &mcp.ReasonError{Reason: "invalid-arguments", Message: "arguments must be an object"}
					}
				}
				if in.Host == "" {
					return "", &mcp.ReasonError{Reason: "invalid-arguments", Message: "host is required"}
				}
				return "/api/host?host=" + url.QueryEscape(in.Host), nil
			}),
	})

	// --- Mutating -------------------------------------------------------------
	// Only the refresh. DELETE stays off deliberately, and for a reason that is
	// about the ROUTE rather than about agents being new: it reaches ANY host's
	// stash on the shared mount, not only this one's, and that asymmetry is
	// what has to be reconciled before it gets a tool.
	//
	// ReadOnly:false, so the MCP server runs the daemon's own gate on the
	// incoming request before this handler is reached.
	reg.MustAdd(mcp.Tool{
		Name: "stash_refresh",
		Description: "Re-read the shared stash mount and rebuild the pool index, then report how many entries it now holds. " +
			"Use it when a stash written by a peer has not appeared yet. It uploads nothing and deletes nothing.",
		InputSchema:  json.RawMessage(`{"type":"object","properties":{},"additionalProperties":false}`),
		OutputSchema: json.RawMessage(`{"type":"object","properties":{"ok":{"type":"boolean"},"entries":{"type":"integer","description":"stash records the pool index holds after the refresh"}}}`),
		ReadOnly:     false,
		Idempotent:   true,
		Handler: func(ctx context.Context, _ json.RawMessage) (any, error) {
			// Chained rather than wrapped: the route answers {"ok":true} and
			// says nothing about what changed, so the count that makes the call
			// worth making comes from the list route immediately afterwards.
			if _, err := mcp.FromRoute(s.handleRefresh, http.MethodPost, "/api/refresh")(ctx, nil); err != nil {
				return nil, err
			}
			listed, err := mcp.FromRoute(s.handleList, http.MethodGet, "/api/stashes")(ctx, nil)
			if err != nil {
				return map[string]any{"ok": true}, nil
			}
			n := 0
			if m, ok := listed.(map[string]any); ok {
				if arr, ok := m["stashes"].([]any); ok {
					n = len(arr)
				}
			}
			return map[string]any{"ok": true, "entries": n}, nil
		},
	})

	return reg
}

func (s *Server) mcpServer() *mcp.Server {
	return mcp.NewServer("stash-service", s.version, s.mcpRegistry(),
		mcp.ConfiguredGate(s.gate.Configured, s.gate.Authed))
}
