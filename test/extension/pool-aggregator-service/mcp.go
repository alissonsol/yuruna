// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"yuruna.com/test/extension/extension-sdk/mcp"
)

// mcpRegistry is the aggregator's MCP surface: the read routes that answer
// "what does this pool look like right now", plus the one that answers "and
// where do I open it" for a caller who cannot click the timeline.
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
		Name: "pool_status",
		Description: "Read the pool view as of the last collector poll: every host this aggregator has discovered, with its address, " +
			"cycle state and lastSeenUnixMs (epoch MILLISECONDS, UTC). The view is rebuilt on the poll interval, so lastPollUtc " +
			"may be several minutes old -- read it before treating an absence as a host that has gone away.",
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
	// The route accepts four windows and this tool used to reach one of them:
	// built with FromRoute, the `range` argument was discarded and the caller
	// got a 24h payload stamped "24h" under a JSON-RPC success. A silently
	// wrong answer is worse than a refused one, so the window is now a real
	// argument and a bad value is a named refusal.
	reg.MustAdd(mcp.Tool{
		Name: "pool_stats",
		Description: "Read per-host counts of terminal cycles (passed and failed) over the window given by `range` -- " +
			"the numbers behind the pool-control board's cards. Defaults to the last 24 hours.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{"range":{"type":"string","enum":["1h","24h","7d","30d"],` +
			`"description":"lookback window; defaults to 24h"}},"additionalProperties":false}`),
		OutputSchema: json.RawMessage(`{"type":"object","properties":{` +
			`"range":{"type":"string","description":"the window these counts cover, echoed back"},` +
			`"hosts":{"type":"array","description":"one entry per host, with its passed and failed terminal-cycle counts"}}}`),
		ReadOnly: true,
		Handler: mcp.FromRouteWithArgs(s.handlePoolStats, http.MethodGet, "/api/v1/pool-stats",
			func(args json.RawMessage) (string, error) {
				var in struct {
					Range string `json:"range"`
				}
				if len(args) > 0 {
					if err := json.Unmarshal(args, &in); err != nil {
						return "", &mcp.ReasonError{Reason: "invalid-arguments", Message: "arguments must be an object"}
					}
				}
				if in.Range == "" {
					return "/api/v1/pool-stats", nil
				}
				// Refuse here rather than let the route answer 400: the caller
				// gets the accepted set back, which is what it needs to retry.
				if !poolStatsRanges[in.Range] {
					return "", &mcp.ReasonError{Reason: "invalid-arguments",
						Message: "unsupported range " + in.Range + "; use 1h, 24h, 7d or 30d"}
				}
				return "/api/v1/pool-stats?range=" + url.QueryEscape(in.Range), nil
			}),
	})

	// The two facts an operator triages with, which until now existed only as
	// Prometheus exposition -- a dashboard could SHOW them and nothing could
	// ASK for them. Sourced from the routes above, so the tool and the metric
	// are one body produced once.
	reg.MustAdd(mcp.Tool{
		Name: "pool_incidents",
		Description: "Read which hosts are currently in an incident, what class of failure opened it, and whether a pool-wide " +
			"incident is running. recentFailCount is recounted against the trailing window at read time, so it is current rather " +
			"than the count captured when the incident opened. Answer this first when a board looks wrong.",
		InputSchema: noArgs,
		OutputSchema: json.RawMessage(`{"type":"object","properties":{` +
			`"windowMinutes":{"type":"integer","description":"trailing window the fail burst is counted over, in MINUTES"},` +
			`"failsToOpen":{"type":"integer","description":"fails within the window that open an incident"},` +
			`"activeHostCount":{"type":"integer"},` +
			`"hosts":{"type":"array","description":"one entry per host in an incident"},` +
			`"poolWide":{"type":"object","description":"the single pool-wide incident, or {active:false}"}}}`),
		ReadOnly: true,
		Handler:  mcp.FromRoute(s.handlePoolIncidents, http.MethodGet, routePoolIncidents),
	})
	reg.MustAdd(mcp.Tool{
		Name: "pool_cycle_links",
		Description: "Resolve where a host's cycle results live: the results page, the host's status page, and the share page " +
			"that packs the whole results folder. These are the state-timeline panel's click destinations, and the panel is a " +
			"canvas -- its blocks reach a screen reader as nothing, and two of these three actions exist nowhere else in the UI. " +
			"Omit atUtcMillis for the current cycle; pass it to resolve the cycle that was running at that instant. The URLs are " +
			"resolved through the same body the click follows, against the host's CURRENT address, so one survives a host " +
			"address change exactly as the redirect does.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{` +
			`"hostId":{"type":"string","description":"host id as listed by pool_status"},` +
			`"atUtcMillis":{"type":"integer","description":"instant to resolve, in MILLISECONDS since the Unix epoch; omit for the current cycle"},` +
			`"pool":{"type":"string","description":"pool to scope the lookup to; omit for the default"}},` +
			`"required":["hostId"],"additionalProperties":false}`),
		OutputSchema: json.RawMessage(`{"type":"object","properties":{` +
			`"hostId":{"type":"string"},` +
			`"cycleStartUtc":{"type":"string","description":"RFC 3339 UTC start of the resolved cycle; absent when a past cycle was resolved from its folder alone"},` +
			`"resultsUrl":{"type":"string","description":"the cycle results, from the durable archive when one is committed and from the host otherwise"},` +
			`"hostStatusUrl":{"type":"string","description":"the host's status page root; carries NO control proof, unlike the dashboard link"},` +
			`"shareUrl":{"type":"string","description":"the host's share page for this cycle; absent when the folder cannot name one"}}}`),
		ReadOnly: true,
		Handler: mcp.FromRouteWithArgs(s.handleCycleLinks, http.MethodGet, routePoolCycleLinks,
			func(args json.RawMessage) (string, error) {
				var in struct {
					HostId      string `json:"hostId"`
					AtUtcMillis int64  `json:"atUtcMillis"`
					Pool        string `json:"pool"`
				}
				if len(args) > 0 {
					if err := json.Unmarshal(args, &in); err != nil {
						return "", &mcp.ReasonError{Reason: "invalid-arguments", Message: err.Error()}
					}
				}
				if strings.TrimSpace(in.HostId) == "" {
					return "", &mcp.ReasonError{Reason: "invalid-arguments", Message: "hostId is required"}
				}
				// The route names the click's own parameters; the tool spells them
				// out because "t" and "host" mean nothing to a caller who never saw
				// the dashboard that mints them.
				q := url.Values{}
				q.Set("host", in.HostId)
				if in.AtUtcMillis > 0 {
					q.Set("t", strconv.FormatInt(in.AtUtcMillis, 10))
				}
				if p := strings.TrimSpace(in.Pool); p != "" {
					q.Set("pool", p)
				}
				return routePoolCycleLinks + "?" + q.Encode(), nil
			}),
	})
	reg.MustAdd(mcp.Tool{
		Name: "pool_health",
		Description: "Read the pool health gate: how many members are healthy, the fraction that represents, the threshold it is " +
			"judged against, and whether the advisory degraded/alert latch has fired. `evaluated` is false when no poll has " +
			"computed the latch yet -- which is not the same as a healthy pool, and is worth checking before reporting one.",
		InputSchema: noArgs,
		OutputSchema: json.RawMessage(`{"type":"object","properties":{` +
			`"evaluated":{"type":"boolean","description":"false when no poll has computed the latch yet"},` +
			`"membersHealthy":{"type":"integer"},"membersTotal":{"type":"integer"},` +
			`"healthyFraction":{"type":"number","description":"0.0-1.0"},` +
			`"healthyThreshold":{"type":"number","description":"0.0-1.0; below this the pool is degraded"},` +
			`"degraded":{"type":"boolean"},"alertActive":{"type":"boolean"},` +
			`"lastPollUtc":{"type":"string","description":"RFC3339; the view is only as fresh as this"}}}`),
		ReadOnly: true,
		Handler:  mcp.FromRoute(s.handlePoolHealth, http.MethodGet, routePoolHealth),
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
