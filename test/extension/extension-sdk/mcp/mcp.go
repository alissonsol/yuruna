// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package mcp serves the Model Context Protocol over HTTP, so a Yuruna
// extension service can be driven by an agent the same way an operator drives
// it with curl.
//
// The design rule this package exists to enforce is that MCP adds a PROTOCOL,
// never a second truth. A tool is a thin wrapper over a route's own internal
// function -- never a re-implementation of it -- and a tool that changes
// anything passes the same gate that route passes, so "what may an agent do
// here" has exactly one answer per service and it is the answer already
// written down.
//
// # Why stdlib rather than the official SDK
//
// Four of the five daemons that mount this are stdlib-only by deliberate
// posture: they are compiled inside their own VM at bring-up, from sources
// fetched file by file, with no module cache and often no route to a registry.
// Adding the official MCP SDK would make this the first third-party dependency
// in every one of them, and it would arrive through the very caching proxy one
// of them manages. The protocol subset a read-mostly service needs -- tools
// over HTTP, no resources, no prompts, no sampling -- is small enough that
// carrying it is cheaper than carrying the dependency.
//
// # What is deliberately not here
//
// No resources, no prompts, no sampling, no server-initiated requests, and no
// SSE stream: every method is a single request and a single response. A
// notification gets 202 and no body. Those are register items, not oversights;
// adding them means adding a session model this package does not have.
package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"sync"
)

// ProtocolVersion is the MCP revision this package speaks. It is pinned rather
// than negotiated down: a client asking for something else is told what it is
// talking to and decides for itself, which is a clearer failure than silently
// serving a shape neither side agreed on.
const ProtocolVersion = "2025-06-18"

// MaxRequestBytes caps a request body. Every method here takes a small JSON
// object; anything larger is a client bug or an attack, and neither deserves
// an allocation.
const MaxRequestBytes = 1 << 20

// JSON-RPC 2.0 error codes. The first five are the spec's; CodeRefused is in
// the implementation-defined range and is what a gate or a domain refusal
// becomes -- see ReasonError.
const (
	CodeParse          = -32700
	CodeInvalidRequest = -32600
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternal       = -32603
	CodeRefused        = -32000
)

// Tool is one callable. Handler is expected to call the same internal function
// the service's HTTP route calls: the point of a tool is a second way IN, not a
// second implementation.
type Tool struct {
	Name        string
	Description string

	// InputSchema is JSON Schema for the arguments object. Hand-written and
	// minimal -- it is what an agent reads to decide how to call, so a wrong
	// one is worse than a sparse one.
	InputSchema json.RawMessage

	// ReadOnly tools skip the gate. It is a claim about the handler, not a
	// convenience: set it only when calling the tool changes nothing an
	// operator could observe later.
	ReadOnly bool

	// Destructive marks a mutating tool whose effect cannot be undone by
	// calling it again with different arguments. Surfaced as destructiveHint
	// so a client can ask before it acts.
	Destructive bool

	// Idempotent marks a mutating tool that can be repeated with the same
	// arguments to no additional effect.
	Idempotent bool

	Handler func(ctx context.Context, args json.RawMessage) (any, error)
}

// ReasonError is a refusal a caller can branch on: the machine-readable token
// the service's HTTP routes already use, carried through unchanged rather than
// flattened into prose. A caching-proxy daemon in remote mode refuses with
// "caching-proxy-remote-readonly" over HTTP and over MCP, and an operator who
// knows one knows the other.
type ReasonError struct {
	Reason  string
	Message string
}

func (e *ReasonError) Error() string {
	if e == nil {
		return ""
	}
	if e.Message == "" {
		return e.Reason
	}
	return e.Reason + ": " + e.Message
}

// Gate decides whether a mutating tool may run. It is an interface so this
// package depends on nothing: each daemon passes an adapter over the labgate
// it already uses for its HTTP routes, which is what keeps the two answers
// from drifting apart.
//
// Allow returns ok, plus the reason token and message to report when it is
// false -- the same pair the daemon's own 401/503 bodies carry.
type Gate interface {
	Allow(r *http.Request) (ok bool, reason string, message string)
}

// GateFunc adapts a function to Gate.
type GateFunc func(r *http.Request) (bool, string, string)

// Allow implements Gate.
func (f GateFunc) Allow(r *http.Request) (bool, string, string) { return f(r) }

// OpenGate admits every mutation. It exists for the stdio case, where the
// transport itself is the boundary: a process reading one operator's stdin has
// already been trusted by that operator. Never mount it on a listener.
var OpenGate Gate = GateFunc(func(*http.Request) (bool, string, string) { return true, "", "" })

// ConfiguredGate builds a Gate from the two questions a labgate-style gate
// answers, without this package importing one. It reproduces exactly what the
// daemons' own Require wrapper does, in the same order and with the same
// tokens: an unconfigured service refuses with auth-unconfigured rather than
// running the write ungated, and a configured one that this caller has not
// passed refuses as unauthorized.
//
// Passing the daemon's real gate methods here is what stops "may an agent do
// this" and "may a curl do this" from drifting apart.
func ConfiguredGate(configured func() bool, authed func(*http.Request) bool) Gate {
	return GateFunc(func(r *http.Request) (bool, string, string) {
		if configured == nil || !configured() {
			return false, "auth-unconfigured", "no aggregator URL and no lab auth token configured; changes are disabled"
		}
		if authed != nil && authed(r) {
			return true, "", ""
		}
		return false, "unauthorized", "lab token session or lab auth token required"
	})
}

// Registry holds the tools a server offers. Safe for concurrent use: a daemon
// may register at startup and serve from many goroutines afterwards.
type Registry struct {
	mu    sync.RWMutex
	tools map[string]Tool
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry { return &Registry{tools: map[string]Tool{}} }

// Add registers a tool, replacing any tool of the same name. It returns an
// error rather than panicking on an unusable tool: a daemon that mounts a
// broken tool should fail its own startup check with a message, not die inside
// a mux.
func (r *Registry) Add(t Tool) error {
	if t.Name == "" {
		return errors.New("a tool needs a name")
	}
	if t.Handler == nil {
		return fmt.Errorf("tool %q has no handler", t.Name)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.tools[t.Name] = t
	return nil
}

// MustAdd is Add for a static tool list assembled at startup, where a failure
// is a programming error the daemon should not start with.
func (r *Registry) MustAdd(t Tool) {
	if err := r.Add(t); err != nil {
		panic(err)
	}
}

// List returns the tools sorted by name, so tools/list is stable across calls
// and a pinned count in a test means something.
func (r *Registry) List() []Tool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Tool, 0, len(r.tools))
	for _, t := range r.tools {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Get returns one tool by name.
func (r *Registry) Get(name string) (Tool, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	t, ok := r.tools[name]
	return t, ok
}

// Server serves one registry over HTTP.
type Server struct {
	Name     string
	Version  string
	Registry *Registry
	Gate     Gate
}

// NewServer builds a server. A nil gate refuses every mutating tool rather
// than admitting it: a daemon that forgot to wire its gate must fail closed.
func NewServer(name, version string, reg *Registry, gate Gate) *Server {
	if reg == nil {
		reg = NewRegistry()
	}
	if gate == nil {
		gate = GateFunc(func(*http.Request) (bool, string, string) {
			return false, "auth-unconfigured", "no gate is configured, so tools that change anything are disabled"
		})
	}
	return &Server{Name: name, Version: version, Registry: reg, Gate: gate}
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// Handler serves POST /mcp.
func (s *Server) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "MCP is served over POST", http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, MaxRequestBytes))
		if err != nil {
			writeRPC(w, rpcResponse{JSONRPC: "2.0", Error: &rpcError{Code: CodeParse, Message: "could not read the request body"}})
			return
		}
		var req rpcRequest
		if err := json.Unmarshal(body, &req); err != nil {
			writeRPC(w, rpcResponse{JSONRPC: "2.0", Error: &rpcError{Code: CodeParse, Message: "request is not JSON"}})
			return
		}
		if req.JSONRPC != "2.0" {
			writeRPC(w, rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{
				Code: CodeInvalidRequest, Message: `every message must carry "jsonrpc":"2.0"`}})
			return
		}

		// A notification has no id and takes no response at all -- not an empty
		// one. Answering it would put a message on the wire the client has no
		// slot for.
		if len(req.ID) == 0 {
			s.dispatchNotification(req)
			w.WriteHeader(http.StatusAccepted)
			return
		}
		writeRPC(w, s.dispatch(r, req))
	}
}

func (s *Server) dispatchNotification(req rpcRequest) {
	// notifications/initialized is the only one expected. Anything else is
	// ignored on purpose: a notification the server does not know is not an
	// error the client can act on, and the spec has no way to report it.
	_ = req
}

func (s *Server) dispatch(r *http.Request, req rpcRequest) rpcResponse {
	switch req.Method {
	case "initialize":
		return rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
			"protocolVersion": ProtocolVersion,
			// Tools only, and listChanged false: the registry is filled at
			// startup and never changes, so promising notifications would be a
			// promise nothing here can keep.
			"capabilities": map[string]any{
				"tools": map[string]any{"listChanged": false},
			},
			"serverInfo": map[string]any{"name": s.Name, "version": s.Version},
		}}

	case "tools/list":
		tools := s.Registry.List()
		out := make([]map[string]any, 0, len(tools))
		for _, t := range tools {
			schema := t.InputSchema
			if len(schema) == 0 {
				schema = json.RawMessage(`{"type":"object","properties":{}}`)
			}
			out = append(out, map[string]any{
				"name":        t.Name,
				"description": t.Description,
				"inputSchema": schema,
				"annotations": map[string]any{
					"readOnlyHint":    t.ReadOnly,
					"destructiveHint": t.Destructive,
					"idempotentHint":  t.Idempotent,
				},
			})
		}
		return rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{"tools": out}}

	case "tools/call":
		return s.callTool(r, req)

	case "ping":
		return rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}
	}
	return rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{
		Code: CodeMethodNotFound, Message: "unknown method " + req.Method}}
}

func (s *Server) callTool(r *http.Request, req rpcRequest) rpcResponse {
	var params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &params); err != nil {
			return rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{
				Code: CodeInvalidParams, Message: "params must be an object with name and arguments"}}
		}
	}
	tool, ok := s.Registry.Get(params.Name)
	if !ok {
		return rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{
			Code: CodeInvalidParams, Message: "unknown tool " + params.Name}}
	}

	// The gate, in the one place every mutating tool passes through. A
	// read-only tool skips it and carries exactly the exposure of the route it
	// wraps -- which on these services is open on the trusted LAN.
	if !tool.ReadOnly {
		allowed, reason, message := s.Gate.Allow(r)
		if !allowed {
			return rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{
				Code: CodeRefused, Message: message, Data: map[string]any{"reason": reason}}}
		}
	}

	args := tool.Arguments(params.Arguments)
	result, err := tool.Handler(r.Context(), args)
	if err != nil {
		// Only a NAMED reason takes the refusal path. A ReasonError with an
		// empty token carries nothing a client can branch on, and reporting it
		// as a refusal would hide an ordinary failure behind a protocol error.
		var reasonErr *ReasonError
		if errors.As(err, &reasonErr) && reasonErr.Reason != "" {
			return rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{
				Code: CodeRefused, Message: reasonErr.Message, Data: map[string]any{"reason": reasonErr.Reason}}}
		}
		// A handler that simply failed is reported INSIDE the result, not as a
		// transport error: the agent asked a legitimate question and the answer
		// is that it did not work, which it can read and act on.
		return rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
			"isError": true,
			"content": []map[string]any{{"type": "text", "text": err.Error()}},
		}}
	}
	return rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
		"isError": false,
		"content": []map[string]any{{"type": "text", "text": encodeResult(result)}},
	}}
}

// Arguments normalises a missing or null arguments member to an empty object,
// so every handler can unmarshal without first checking for absence.
func (t Tool) Arguments(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" {
		return json.RawMessage(`{}`)
	}
	return raw
}

// encodeResult renders a handler's return as the text an agent reads. JSON,
// because everything these tools return is already a JSON shape the service's
// own routes serve, and re-rendering it as prose would invent a second format.
func encodeResult(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	body, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(body)
}

func writeRPC(w http.ResponseWriter, resp rpcResponse) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	// 200 even for a JSON-RPC error: the RPC layer answered. An HTTP status
	// other than 200 says the transport failed, which is a different fact and
	// sends a client looking in the wrong place.
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(resp)
}

// recorder is a minimal http.ResponseWriter. net/http/httptest would do the
// same job, but it is a testing package and this runs in shipped daemons.
type recorder struct {
	status int
	header http.Header
	body   []byte
}

func (rec *recorder) Header() http.Header {
	if rec.header == nil {
		rec.header = http.Header{}
	}
	return rec.header
}
func (rec *recorder) Write(p []byte) (int, error) {
	rec.body = append(rec.body, p...)
	return len(p), nil
}
func (rec *recorder) WriteHeader(code int) { rec.status = code }

// FromRoute builds a tool handler that INVOKES an existing route handler
// in-process and returns what it wrote.
//
// This is how a tool is kept from becoming a second implementation. These
// daemons build their read payloads inside the handler rather than in a
// function a tool could share, so wrapping one by hand would mean writing the
// same shape twice and maintaining both. Calling the handler means the tool
// cannot answer differently from the route: there is one body, produced once.
//
// The cost is a JSON round-trip in the same process, which is nothing next to
// the reads themselves. A non-2xx from the handler becomes an error carrying
// the body, so a route that refuses still refuses through the tool.
func FromRoute(h http.HandlerFunc, method, target string) func(context.Context, json.RawMessage) (any, error) {
	return func(ctx context.Context, _ json.RawMessage) (any, error) {
		req, err := http.NewRequestWithContext(ctx, method, target, nil)
		if err != nil {
			return nil, err
		}
		rec := &recorder{status: http.StatusOK}
		h(rec, req)
		if rec.status < 200 || rec.status > 299 {
			return nil, fmt.Errorf("%s %s answered %d: %s", method, target, rec.status, string(rec.body))
		}
		var out any
		if err := json.Unmarshal(rec.body, &out); err != nil {
			// Not every route answers JSON -- /healthz writes plain text -- and
			// the text is still the answer.
			return string(rec.body), nil
		}
		return out, nil
	}
}
