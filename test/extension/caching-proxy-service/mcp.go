// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"

	"yuruna.com/test/extension/extension-sdk/mcp"
)

// mcpTools builds this daemon's MCP surface.
//
// Every tool calls the SAME internal function its HTTP route calls. That is the
// whole rule: MCP is a second way in, never a second implementation, so there
// is one answer to "what does this proxy report" and one answer to "who may
// flip a switch" rather than one per protocol.
//
// The mutating pair inherits both refusals it already has over HTTP: the
// lab-token gate in front, and the remote-mode 501 underneath, which arrives
// as a ReasonError carrying the same caching-proxy-remote-readonly token.
func (d *daemon) mcpTools() *mcp.Registry {
	reg := mcp.NewRegistry()
	noArgs := json.RawMessage(`{"type":"object","properties":{}}`)
	onArg := json.RawMessage(`{"type":"object","properties":{"on":{"type":"boolean","description":"true turns the switch on"}},"required":["on"]}`)

	reg.MustAdd(mcp.Tool{
		Name:        "caching_proxy_status",
		Description: "Read the caching proxy's state: squid's runtime summary, both operator switches, and the zot registry's catalog, canary and prewarm records.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler: func(context.Context, json.RawMessage) (any, error) {
			return map[string]any{
				"mode":     string(d.mode),
				"version":  version,
				"squid":    d.squid.summary(),
				"switches": d.readSwitches(),
				"registry": d.registry.state(),
			}, nil
		},
	})

	reg.MustAdd(mcp.Tool{
		Name:        "caching_proxy_switches",
		Description: "Read just the two operator switches: offline mode and no-upstream, plus how the answer was obtained.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler: func(context.Context, json.RawMessage) (any, error) {
			return d.readSwitches(), nil
		},
	})

	reg.MustAdd(mcp.Tool{
		Name:        "caching_proxy_hostinfo",
		Description: "Read this daemon's host id, stamped version, run mode and own addresses.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler: func(context.Context, json.RawMessage) (any, error) {
			return map[string]any{
				"localHostId": d.hostID,
				"version":     version,
				"mode":        string(d.mode),
				"serverIps":   serverIPLines(),
			}, nil
		},
	})

	// Idempotent, not destructive: setting a switch to the state it is already
	// in changes nothing, and either switch can be set back. Nothing here
	// discards data, which is what destructiveHint is for.
	reg.MustAdd(mcp.Tool{
		Name:        "caching_proxy_set_offline",
		Description: "Turn squid's offline mode on or off. Offline mode suppresses REVALIDATION, not fetching: a cache miss still reaches the origin. Local mode only.",
		InputSchema: onArg,
		Idempotent:  true,
		Handler:     d.mcpSwitchHandler(d.applyOffline),
	})

	reg.MustAdd(mcp.Tool{
		Name:        "caching_proxy_set_no_upstream",
		Description: "Turn the no-upstream switch on or off. This refuses cache misses outright, making the cache's content the whole of what the lab can see. Local mode only.",
		InputSchema: onArg,
		Idempotent:  true,
		Handler:     d.mcpSwitchHandler(d.applyNoUpstream),
	})

	return reg
}

// mcpSwitchHandler is the tool half of applySwitch, and it refuses the same way
// for the same reasons -- including translating the remote-mode error into the
// reason token an operator already knows from the 501 body.
func (d *daemon) mcpSwitchHandler(apply func(bool) error) func(context.Context, json.RawMessage) (any, error) {
	return func(_ context.Context, args json.RawMessage) (any, error) {
		var in struct {
			On *bool `json:"on"`
		}
		if err := json.Unmarshal(args, &in); err != nil || in.On == nil {
			return nil, &mcp.ReasonError{
				Reason:  "invalid-arguments",
				Message: `arguments must name "on": true or false`,
			}
		}
		if err := apply(*in.On); err != nil {
			if err == errRemoteReadOnly {
				return nil, &mcp.ReasonError{
					Reason:  "caching-proxy-remote-readonly",
					Message: "this daemon is in remote mode and cannot apply the switch: squid has no remote reconfigure, so the change would be written and never loaded",
				}
			}
			return nil, err
		}
		return d.readSwitches(), nil
	}
}

// mcpServer wires the registry to the daemon's own gate, so a tool and a route
// give the same verdict to the same caller.
func (d *daemon) mcpServer() *mcp.Server {
	return mcp.NewServer("caching-proxy-service", version, d.mcpTools(),
		mcp.ConfiguredGate(d.gate.Configured, d.gate.Authed))
}
