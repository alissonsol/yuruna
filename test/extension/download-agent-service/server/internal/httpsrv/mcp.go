// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"net/http"
	"net/url"

	"yuruna.com/test/extension/extension-sdk/mcp"
)

// mcpRegistry is this daemon's MCP surface. See
// ../../../../../../docs/extensions-api.md#mcp-endpoints and
// ../../../../../../docs/extensions-api.md#what-a-tool-may-do-and-who-decides
// for the mcp.FromRoute pattern and why this surface stays read-only. -- mcp.go
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
		Name: "download_agent_images",
		Description: "List every guest image the pool holds, with its generations, sizes in BYTES, freshness and current verdict. " +
			"Use download_agent_image for one image without the whole catalog, and download_agent_diagnostics when the question " +
			"is why something is unreachable rather than what is held.",
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
	// Two reads the UI makes and no tool reached. The deferral recorded above
	// is about the MUTATING routes and says nothing about a read.
	reg.MustAdd(mcp.Tool{
		Name:        "download_agent_session",
		Description: "Read which ways through the action gate exist on this service, and whether this caller is through one. Answer it before a mutating call to know whether one would be refused.",
		InputSchema: noArgs,
		ReadOnly:    true,
		Handler:     mcp.FromRoute(s.handleSession, http.MethodGet, "/api/session"),
	})
	reg.MustAdd(mcp.Tool{
		Name: "download_agent_image",
		Description: "Read ONE image's record -- its generations, sizes, freshness and verdict -- without pulling the whole catalog. " +
			"Use download_agent_images to discover the hostType and imageKey pairs that exist.",
		// arch is REQUIRED because imageID() requires it: the route answers 400
		// without it, and a schema that did not declare it sent every caller
		// into that 400. variant defaults to stable, matching the route.
		//
		// hostType carries an enum rather than an example. ValidateLocation
		// accepts exactly these three, and they name the HOST that pulled the
		// image -- a caller who reads "host type" as the guest inside it picks a
		// value that can never validate, and the route's own message ("unknown
		// hostType") reads like the value was mistyped rather than the wrong
		// KIND of name. An enum removes the guess.
		InputSchema: json.RawMessage(`{"type":"object","properties":{` +
			`"hostType":{"type":"string","enum":["windows.hyper-v","ubuntu.kvm","macos.utm"],` +
			`"description":"the HOST platform that pulled the image, not the guest inside it"},` +
			`"imageKey":{"type":"string","description":"image key as listed by download_agent_images"},` +
			`"arch":{"type":"string","description":"amd64 or arm64"},` +
			`"variant":{"type":"string","description":"stable (default) or daily"}},` +
			`"required":["hostType","imageKey","arch"],"additionalProperties":false}`),
		ReadOnly: true,
		// FromPattern, not FromRouteWithArgs: this route's handler reads
		// r.PathValue, which resolves only for a ROUTED request. Called
		// directly it saw empty placeholders and refused arguments the caller
		// had supplied.
		Handler: mcp.FromPattern("GET /api/v1/images/{hostType}/{imageKey}", s.handleImage, http.MethodGet,
			func(args json.RawMessage) (string, []byte, error) {
				var in struct {
					HostType, ImageKey, Arch, Variant string
				}
				if len(args) > 0 {
					if err := json.Unmarshal(args, &in); err != nil {
						return "", nil, &mcp.ReasonError{Reason: "invalid-arguments", Message: "arguments must be an object"}
					}
				}
				if in.HostType == "" || in.ImageKey == "" || in.Arch == "" {
					return "", nil, &mcp.ReasonError{Reason: "invalid-arguments", Message: "hostType, imageKey and arch are required"}
				}
				// PathEscape for the segments, QueryEscape for the query: a
				// space has to become %20 in one and may become a plus in the
				// other.
				q := "?arch=" + url.QueryEscape(in.Arch)
				if in.Variant != "" {
					q += "&variant=" + url.QueryEscape(in.Variant)
				}
				return "/api/v1/images/" + url.PathEscape(in.HostType) + "/" + url.PathEscape(in.ImageKey) + q, nil, nil
			}),
	})

	// --- REGION: Mutating tools
	// Both wrap a route that reads r.PathValue, so both go through FromPattern:
	// a directly-called handler sees empty placeholders and refuses arguments
	// the caller supplied.
	//
	// ReadOnly:false, so the MCP server runs the daemon's own gate on the
	// incoming request before the handler is reached.
	//
	// Still off, deliberately: delete (the destructive twin of prune, a second
	// pass) and the pool-wide refresh, which sits behind gate.RequireBearer --
	// STRICTER than the ConfiguredGate this registry wires, so a tool for it
	// would quietly widen who may start a download for every entry at once.
	imageArgs := json.RawMessage(`{"type":"object","properties":{` +
		`"hostType":{"type":"string","enum":["windows.hyper-v","ubuntu.kvm","macos.utm"],` +
		`"description":"the HOST platform that pulled the image, not the guest inside it"},` +
		`"imageKey":{"type":"string","description":"image key as listed by download_agent_images"},` +
		`"arch":{"type":"string","description":"amd64 or arm64"},` +
		`"variant":{"type":"string","description":"stable (default) or daily"}},` +
		`"required":["hostType","imageKey","arch"],"additionalProperties":false}`)
	imageTarget := func(verb string) func(json.RawMessage) (string, []byte, error) {
		return func(args json.RawMessage) (string, []byte, error) {
			var in struct {
				HostType, ImageKey, Arch, Variant string
			}
			if len(args) > 0 {
				if err := json.Unmarshal(args, &in); err != nil {
					return "", nil, &mcp.ReasonError{Reason: "invalid-arguments", Message: "arguments must be an object"}
				}
			}
			if in.HostType == "" || in.ImageKey == "" || in.Arch == "" {
				return "", nil, &mcp.ReasonError{Reason: "invalid-arguments", Message: "hostType, imageKey and arch are required"}
			}
			q := "?arch=" + url.QueryEscape(in.Arch)
			if in.Variant != "" {
				q += "&variant=" + url.QueryEscape(in.Variant)
			}
			return "/api/v1/images/" + url.PathEscape(in.HostType) + "/" + url.PathEscape(in.ImageKey) + "/" + verb + q, nil, nil
		}
	}
	reg.MustAdd(mcp.Tool{
		Name: "download_agent_refresh_image",
		Description: "Start a re-download of one image from origin. Returns once the refresh is STARTED, not once it finishes -- " +
			"poll download_agent_image to watch it complete. Repeating it while one is in flight is a no-op.",
		InputSchema: imageArgs,
		ReadOnly:    false,
		Idempotent:  true,
		Handler:     mcp.FromPattern("POST /api/v1/images/{hostType}/{imageKey}/refresh", s.handleRefresh, http.MethodPost, imageTarget("refresh")),
	})
	reg.MustAdd(mcp.Tool{
		Name: "download_agent_prune_image",
		Description: "Discard the PREVIOUS generations of one image, keeping the current one. Nothing re-creates a discarded " +
			"generation, so the result names what went and what stayed -- that list is the part that cannot be called back.",
		InputSchema: imageArgs,
		ReadOnly:    false,
		Destructive: true,
		Idempotent:  true,
		Handler:     mcp.FromPattern("POST /api/v1/images/{hostType}/{imageKey}/prune", s.handlePrune, http.MethodPost, imageTarget("prune")),
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
