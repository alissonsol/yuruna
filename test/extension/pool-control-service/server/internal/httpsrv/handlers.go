// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"pool-control-service/internal/config"
	"pool-control-service/internal/intent"
	"pool-control-service/internal/state"

	"yuruna.com/test/extension/extension-sdk/i18n"
)

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	// /healthz stays OPEN and never gated: the launcher polls it to decide the
	// daemon is up, so gating it would make a credential a bring-up dependency.
	mux.HandleFunc("GET /healthz", s.handleHealth)
	// The session route must be open, or the login prompt could not render.
	mux.HandleFunc("GET /api/session", s.handleSession)
	mux.HandleFunc("POST /api/login", s.handleLogin)
	// Open for the same reason as /api/login: it is how a credential is
	// presented, this one carried in from the dashboard's own redirect.
	mux.HandleFunc("POST /api/unlock-proof", s.handleUnlockProof)

	// Reads: unconditionally open on the trusted LAN, the same posture as the
	// aggregator's pool-status and every other extension service. The board
	// renders on a wall display with no credential, and nothing it shows is a
	// secret the LAN cannot already read from the pool.
	mux.HandleFunc("GET /api/hostinfo", s.handleHostInfo)
	mux.HandleFunc("GET /api/board", s.handleBoard)
	mux.HandleFunc("GET /api/hosts", s.handleHosts)
	// Hardware facts fanned out from each host's status service; separate from
	// /api/hosts so the page's periodic host-list reload does not pay (or
	// trigger) the pool-wide fan-out.
	mux.HandleFunc("GET /api/hosts/facts", s.handleHostFacts)
	mux.HandleFunc("GET /api/scan", s.handleScanStatus)
	mux.HandleFunc("GET /api/state", s.handleState)
	mux.HandleFunc("GET /api/diagnostics", s.handleDiagnostics)
	// What each pool's members are currently doing. A read of the same
	// status.json every host already serves openly to the LAN.
	mux.HandleFunc("GET /api/pool/host-control", s.handleHostControlState)

	// Mutations: lab-token session or internal-auth-key bearer. Every one of these
	// rewrites pool configuration.
	mux.HandleFunc("POST /api/pool", s.gate.Require(s.handleNewPool))
	mux.HandleFunc("DELETE /api/pool", s.gate.Require(s.handleRemovePool))
	mux.HandleFunc("POST /api/pool/desired-state", s.gate.Require(s.handleDesiredState))
	// Pool-wide host control drives other machines rather than this service's
	// own configuration, but it takes the same gate as the rest: it only ever
	// pauses or continues work that is already running, and an operator holding
	// the dashboard's rotating code is exactly who needs it mid-cycle.
	mux.HandleFunc("POST /api/pool/host-control", s.gate.Require(s.handleHostControlApply))
	mux.HandleFunc("POST /api/pool/host", s.gate.Require(s.handleAddHost))
	mux.HandleFunc("DELETE /api/pool/host", s.gate.Require(s.handleRemoveHost))
	mux.HandleFunc("POST /api/pool/move-host", s.gate.Require(s.handleMoveHost))
	mux.HandleFunc("POST /api/pool/testset", s.gate.Require(s.handleAssign))
	// Scanning is gated with the changes, not with the reads: it adds hosts to
	// what this daemon monitors, and it aims a burst of connection attempts at
	// a network the caller names.
	mux.HandleFunc("POST /api/scan", s.gate.Require(s.handleScanStart))
	mux.HandleFunc("POST /api/scan/forget", s.gate.Require(s.handleScanForget))
	mux.HandleFunc("POST /api/testset", s.gate.Require(s.handleSetTestSet))
	mux.HandleFunc("DELETE /api/testset", s.gate.Require(s.handleDeleteTestSet))

	// MCP over the same surface. Not wrapped in gate.Require: the protocol
	// decides per TOOL, so read-only tools keep the exposure of the open
	// routes they wrap.
	mux.HandleFunc("POST /mcp", s.mcpServer().Handler())

	mux.HandleFunc("GET /assets/", s.handleAsset)
	// Pages are served open; each mutation is gated above, and the board renders
	// its own lab-token prompt from /api/session. Gating the HTML too would mean
	// serving a 401 body a browser cannot act on.
	mux.HandleFunc("GET /pools", s.servePage("pools.html"))
	mux.HandleFunc("GET /test-sets", s.servePage("test-sets.html"))
	mux.HandleFunc("GET /scan", s.servePage("scan.html"))
	mux.HandleFunc("GET /diagnostics", s.servePage("diagnostics.html"))
	mux.HandleFunc("GET /hosts", s.servePage("hosts.html"))
	// Assign lives at /assign, not "/": the root slot serves the board.
	mux.HandleFunc("GET /assign", s.servePage("index.html"))
	mux.HandleFunc("GET /{$}", s.servePage("board.html"))
	// Negotiation wraps everything so one request resolves its language once.
	// A page and the API calls it then makes must not each decide separately:
	// a board rendered in one language listing states named in another is a
	// difference no reader can attribute to anything real.
	return s.negotiator().Middleware(mux)
}

// --- JSON helpers -----------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "error": msg})
}

// relayResult maps a CLI Result to the HTTP response: 200 {ok:true,...} on
// success, 500 {ok:false,error,stderr} on failure (a failed push is a failure).
func relayResult(w http.ResponseWriter, res intent.Result) {
	if res.OK {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": strings.TrimSpace(res.Stdout)})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": firstNonEmpty(res.Error, res.Stderr, "operation failed"), "stderr": strings.TrimSpace(res.Stderr)})
}

// relay records an audit entry (when a state store is configured) and relays the
// result to the client. Every intent mutation flows through here.
func (s *Server) relay(w http.ResponseWriter, action, target string, res intent.Result) {
	if s.state != nil {
		detail := ""
		if !res.OK {
			detail = firstNonEmpty(res.Error, res.Stderr, "")
		}
		s.state.Record(time.Now(), state.AuditEntry{
			TimeUTC: time.Now().UTC().Format(time.RFC3339),
			Action:  action, Target: target, OK: res.OK, Detail: detail,
		})
	}
	relayResult(w, res)
}

// handleHealth serves the persisted status (last write, last-publish, heartbeat,
// intent readability) when a state store is configured, else a plain "ok".
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if s.state == nil {
		_, _ = io.WriteString(w, "ok\n")
		return
	}
	writeJSON(w, http.StatusOK, s.state.Health())
}

// handleDiagnostics reports every dependency a UI request touches. It answers
// 200 even when checks fail: collecting the report succeeded, and the failing
// checks ARE the payload. Anything else would leave the one page meant to
// explain an outage unable to render during that outage.
func (s *Server) handleDiagnostics(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.collectDiagnostics(r.Context()))
}

// --- page + asset serving ---------------------------------------------------

// servePage serves one embedded document in the reader's language.
//
// The language is decided here, at the boundary, and written into the markup
// before it leaves: the document arrives already correct rather than being
// corrected by script after first paint. The representation is negotiated, so
// it carries Content-Language and varies on Accept-Language -- without that, a
// shared cache hands whichever language was asked for first to everyone.
func (s *Server) servePage(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		locale := i18n.FromRequest(r)
		if locale.ResolvedTag == "" {
			locale = s.negotiator().Resolve(r)
		}
		page, ok := s.assets.page(name, locale)
		if !ok {
			http.Error(w, "prepared page representation unavailable", http.StatusInternalServerError)
			return
		}

		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'")
		i18n.Apply(h, locale)
		serveAsset(w, r, page)
	}
}

// handleAsset serves a prepared static file. An asset is the same bytes in
// every language, so it is not negotiated and does not vary on the language
// header -- claiming it did would split every cache entry on a header that
// changes nothing about the response.
func (s *Server) handleAsset(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/assets/")
	clean := strings.TrimPrefix(filepath.ToSlash(filepath.Clean("/"+name)), "/")
	a, ok := s.assets.asset(clean)
	if !ok {
		http.NotFound(w, r)
		return
	}
	serveAsset(w, r, a)
}

// --- request decoding -------------------------------------------------------

func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, config.MaxRequestBytes)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	return true
}

// --- handlers ---------------------------------------------------------------

func (s *Server) handleState(w http.ResponseWriter, r *http.Request) {
	res := s.intent.State(r.Context())
	if !res.OK {
		writeErr(w, http.StatusInternalServerError, firstNonEmpty(res.Error, res.Stderr, "pool intent read failed"))
		return
	}
	// Get-PoolIntent.ps1 already emits a {ok,pools,testSets} JSON object; relay it.
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.WriteString(w, strings.TrimSpace(res.Stdout))
}

func (s *Server) handleNewPool(w http.ResponseWriter, r *http.Request) {
	var body struct{ PoolID, DisplayName, DesiredState string }
	if !decode(w, r, &body) {
		return
	}
	if body.PoolID == "" {
		writeErr(w, http.StatusBadRequest, "poolId is required")
		return
	}
	s.relay(w, "new-pool", body.PoolID, s.intent.NewPool(r.Context(), body.PoolID, body.DisplayName, body.DesiredState))
}

func (s *Server) handleRemovePool(w http.ResponseWriter, r *http.Request) {
	poolID := r.URL.Query().Get("poolId")
	if poolID == "" {
		writeErr(w, http.StatusBadRequest, "poolId is required")
		return
	}
	force := r.URL.Query().Get("force") == "true"
	s.relay(w, "remove-pool", poolID, s.intent.RemovePool(r.Context(), poolID, force))
}

func (s *Server) handleDesiredState(w http.ResponseWriter, r *http.Request) {
	var body struct{ PoolID, DesiredState string }
	if !decode(w, r, &body) {
		return
	}
	if body.PoolID == "" || body.DesiredState == "" {
		writeErr(w, http.StatusBadRequest, "poolId and desiredState are required")
		return
	}
	s.relay(w, "desired-state", body.PoolID, s.intent.SetDesiredState(r.Context(), body.PoolID, body.DesiredState))
}

func (s *Server) handleAddHost(w http.ResponseWriter, r *http.Request) {
	var body struct{ PoolID, HostID string }
	if !decode(w, r, &body) {
		return
	}
	if body.PoolID == "" || body.HostID == "" {
		writeErr(w, http.StatusBadRequest, "poolId and hostId are required")
		return
	}
	s.relay(w, "add-host", body.PoolID, s.intent.AddHost(r.Context(), body.PoolID, body.HostID))
}

func (s *Server) handleRemoveHost(w http.ResponseWriter, r *http.Request) {
	poolID := r.URL.Query().Get("poolId")
	hostID := r.URL.Query().Get("hostId")
	if poolID == "" || hostID == "" {
		writeErr(w, http.StatusBadRequest, "poolId and hostId are required")
		return
	}
	s.relay(w, "remove-host", poolID, s.intent.RemoveHost(r.Context(), poolID, hostID))
}

func (s *Server) handleAssign(w http.ResponseWriter, r *http.Request) {
	var body struct{ PoolID, Name, FrameworkURL, ProjectURL string }
	if !decode(w, r, &body) {
		return
	}
	if body.PoolID == "" || body.Name == "" || body.FrameworkURL == "" || body.ProjectURL == "" {
		writeErr(w, http.StatusBadRequest, "poolId, name, frameworkURL and projectURL are required")
		return
	}
	s.relay(w, "assign-testset", body.PoolID, s.intent.AssignTestSet(r.Context(), body.PoolID, body.Name, body.FrameworkURL, body.ProjectURL))
}

func (s *Server) handleSetTestSet(w http.ResponseWriter, r *http.Request) {
	var body struct{ Name, FrameworkURL, ProjectURL string }
	if !decode(w, r, &body) {
		return
	}
	if body.Name == "" || body.FrameworkURL == "" || body.ProjectURL == "" {
		writeErr(w, http.StatusBadRequest, "name, frameworkURL and projectURL are required")
		return
	}
	s.relay(w, "set-testset", body.Name, s.intent.SetTestSetDef(r.Context(), body.Name, body.FrameworkURL, body.ProjectURL))
}

func (s *Server) handleDeleteTestSet(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	s.relay(w, "delete-testset", name, s.intent.DeleteTestSetDef(r.Context(), name))
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
