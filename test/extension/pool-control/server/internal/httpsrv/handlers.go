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

	"pool-control/internal/config"
	"pool-control/internal/intent"
	"pool-control/internal/state"
)

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /api/state", s.handleState)
	mux.HandleFunc("POST /api/pool", s.handleNewPool)
	mux.HandleFunc("DELETE /api/pool", s.handleRemovePool)
	mux.HandleFunc("POST /api/pool/desired-state", s.handleDesiredState)
	mux.HandleFunc("POST /api/pool/host", s.handleAddHost)
	mux.HandleFunc("DELETE /api/pool/host", s.handleRemoveHost)
	mux.HandleFunc("POST /api/pool/testset", s.handleAssign)
	mux.HandleFunc("POST /api/testset", s.handleSetTestSet)
	mux.HandleFunc("DELETE /api/testset", s.handleDeleteTestSet)
	mux.HandleFunc("GET /assets/", s.handleAsset)
	mux.HandleFunc("GET /pools", s.servePage("pools.html"))
	mux.HandleFunc("GET /test-sets", s.servePage("test-sets.html"))
	mux.HandleFunc("GET /{$}", s.servePage("index.html"))
	return mux
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

// --- page + asset serving ---------------------------------------------------

func (s *Server) servePage(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b, err := webFS.ReadFile("web/" + name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'")
		_, _ = w.Write(b)
	}
}

func (s *Server) handleAsset(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/assets/")
	clean := filepath.ToSlash(filepath.Clean("/" + name))
	b, err := webFS.ReadFile("web/assets/" + strings.TrimPrefix(clean, "/"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	ct := "application/octet-stream"
	switch {
	case strings.HasSuffix(name, ".js"):
		ct = "text/javascript; charset=utf-8"
	case strings.HasSuffix(name, ".css"):
		ct = "text/css; charset=utf-8"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(b)
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
