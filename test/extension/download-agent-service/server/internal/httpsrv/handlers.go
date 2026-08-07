// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"download-agent-service/internal/config"
	"download-agent-service/internal/imagestore"
	"download-agent-service/internal/state"
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

	// Reads: unconditionally open on the trusted LAN.
	mux.HandleFunc("GET /api/hostinfo", s.handleHostInfo)
	mux.HandleFunc("GET /api/v1/status", s.handleStatus)
	mux.HandleFunc("GET /api/v1/images", s.handleImages)
	mux.HandleFunc("GET /api/v1/images/{hostType}/{imageKey}", s.handleImage)
	mux.HandleFunc("GET /api/v1/images/{hostType}/{imageKey}/file/{generation}", s.handleFile)
	// ensure is a POST because it may start work, but it is the host's read
	// path: gating it would make every image fetch need a credential.
	mux.HandleFunc("POST /api/v1/images/{hostType}/{imageKey}/ensure", s.handleEnsure)
	// Diagnostics is a read: environment facts and the last resolver run, the
	// evidence behind a "family unavailable" answer. What it must NOT do is
	// start a resolver child -- that is the gated test route below.
	mux.HandleFunc("GET /api/v1/diagnostics", s.handleDiagnostics)

	// Mutations: lab-token session or lab-auth-token bearer.
	mux.HandleFunc("POST /api/v1/images/{hostType}/{imageKey}/refresh", s.gate.Require(s.handleRefresh))
	mux.HandleFunc("POST /api/v1/images/{hostType}/{imageKey}/delete", s.gate.Require(s.handleDelete))
	mux.HandleFunc("POST /api/v1/images/{hostType}/{imageKey}/prune", s.gate.Require(s.handlePrune))
	// The pool-wide re-verify takes the bearer ALONE: it is an automation route,
	// and one unlocked phone should not be able to start a download for every
	// entry in the pool at once.
	mux.HandleFunc("POST /api/v1/refresh", s.gate.RequireBearer(s.handleRefreshAll))
	// The resolver test starts a real Fido run against Microsoft's pages. It
	// downloads nothing, but each run spends a Microsoft session (their servers
	// rate-ban chatty addresses), so it is gated like the other actions rather
	// than left open for anything on the LAN to poll.
	mux.HandleFunc("POST /api/v1/diagnostics/fido-test", s.gate.Require(s.handleFidoTest))

	mux.HandleFunc("GET /assets/", s.handleAsset)
	// The page is served open; its DATA comes from the routes above and it
	// renders its own lab-token prompt from /api/session. Gating the HTML would
	// mean serving a 401 body a browser cannot act on.
	mux.HandleFunc("GET /{$}", s.servePage("index.html"))
	mux.HandleFunc("GET /diagnostics", s.servePage("diagnostics.html"))
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

func writeReason(w http.ResponseWriter, status int, reason, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "reason": reason, "error": msg})
}

// decodeOptional accepts an absent or empty body, which is how a client that
// holds nothing locally sends ensure.
func decodeOptional(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, config.MaxRequestBytes)
	err := json.NewDecoder(r.Body).Decode(dst)
	if err == nil || errors.Is(err, io.EOF) {
		return true
	}
	writeErr(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
	return false
}

// imageID builds the identity from the path and the query, refusing anything
// outside the known host types, arches and variants.
func (s *Server) imageID(w http.ResponseWriter, r *http.Request) (imagestore.ImageID, bool) {
	q := r.URL.Query()
	variant := q.Get("variant")
	if variant == "" {
		// Everything except the Ubuntu ISOs is stable-only, and a host that does
		// not care about the preference should not have to say so.
		variant = imagestore.VariantStable
	}
	id := imagestore.ImageID{
		HostType: r.PathValue("hostType"),
		ImageKey: r.PathValue("imageKey"),
		Arch:     q.Get("arch"),
		Variant:  variant,
	}
	if id.Arch == "" {
		writeErr(w, http.StatusBadRequest, "arch query parameter is required (amd64 or arm64)")
		return id, false
	}
	if err := id.Validate(); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return id, false
	}
	return id, true
}

// available answers 503 when no pool engine is wired up at all.
func (s *Server) available(w http.ResponseWriter) bool {
	if s.images == nil {
		writeReason(w, http.StatusServiceUnavailable, imagestore.ReasonPoolUnavailable, "no image store configured")
		return false
	}
	return true
}

// record appends an audit entry for a mutation. Best effort by contract: the
// mutation has already happened when this runs.
func (s *Server) record(action string, id imagestore.ImageID, outcome, detail string) {
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		AtUTC:    now.UTC().Format(time.RFC3339),
		Action:   action,
		HostType: id.HostType, ImageKey: id.ImageKey, Arch: id.Arch, Variant: id.Variant,
		Outcome: outcome, Detail: detail,
	})
}

// --- read routes ------------------------------------------------------------

// handleHealth serves the persisted status when a state store is configured,
// else a plain "ok". Never gated.
func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	if s.state == nil {
		_, _ = io.WriteString(w, "ok\n")
		return
	}
	writeJSON(w, http.StatusOK, s.state.Health())
}

func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	out := map[string]any{
		"ok":            true,
		"version":       s.opts.Version,
		"area":          config.PresenceArea,
		"aggregatorUrl": s.opts.AggregatorURL,
		"hostId":        s.opts.HostID,
		"stateDir":      s.opts.StateDir,
		"startedAtUtc":  s.started.UTC().Format(time.RFC3339),
		"uptimeSeconds": int64(time.Since(s.started).Seconds()),
		"gate": map[string]any{
			"labToken":   s.gate.LabTokenEnabled(),
			"bearer":     s.gate.BearerEnabled(),
			"configured": s.gate.Configured(),
		},
	}
	if s.images != nil {
		out["agent"] = s.images.Status(time.Now())
	} else {
		out["agent"] = map[string]any{"poolAvailable": false, "poolDir": s.opts.PoolDir}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleImages(w http.ResponseWriter, _ *http.Request) {
	if !s.available(w) {
		return
	}
	now := time.Now()
	images, totals := s.images.Catalog(now)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"poolAvailable": s.images.PoolAvailable(),
		"images":        images,
		"totals":        totals,
		"asOfUtc":       now.UTC().Format(time.RFC3339),
	})
}

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	id, ok := s.imageID(w, r)
	if !ok {
		return
	}
	entry, found := s.images.Entry(time.Now(), id)
	if !found {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "no pool entry for " + id.String(), "image": entry})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "image": entry})
}

// handleFile streams one generation. http.ServeContent gives Range and resume,
// which is what lets a host recover a half-transferred multi-GB artifact without
// starting over.
//
// It deliberately does NOT go through imageID: the identity that names bytes is
// (hostType, imageKey, generation). Every arch/variant of a key shares one
// directory and the artifact is content-named, so demanding an arch here would
// 400 every fetch of the query-less fileUrl the catalog and ensure hand out.
func (s *Server) handleFile(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	id := imagestore.ImageID{HostType: r.PathValue("hostType"), ImageKey: r.PathValue("imageKey")}
	if err := imagestore.ValidateLocation(id.HostType, id.ImageKey); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	generation := r.PathValue("generation")
	if !imagestore.ValidGenerationName(generation) {
		writeErr(w, http.StatusBadRequest, "invalid generation name")
		return
	}
	f, fi, err := s.images.OpenGeneration(id, generation)
	if err != nil {
		writeErr(w, http.StatusNotFound, "generation not found")
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Disposition", "attachment; filename=\""+sanitizeFilename(generation)+"\"")
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

// sanitizeFilename keeps a Content-Disposition value free of quoting hazards.
func sanitizeFilename(name string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r == '"' || r == '\\' || r < 0x20:
			return '_'
		default:
			return r
		}
	}, name)
}

func (s *Server) handleEnsure(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	id, ok := s.imageID(w, r)
	if !ok {
		return
	}
	var fp imagestore.Fingerprint
	if !decodeOptional(w, r, &fp) {
		return
	}
	res := s.images.Ensure(time.Now(), id, fp)
	body := map[string]any{
		"ok":              res.HTTPStatus < 400,
		"state":           res.State,
		"localCurrent":    res.LocalCurrent,
		"stale":           res.Stale,
		"refreshInFlight": res.RefreshInFlight,
		"bytesDone":       res.BytesDone,
		"bytesTotal":      res.BytesTotal,
		"image":           res.Image,
	}
	if res.Reason != "" {
		body["reason"] = res.Reason
	}
	if res.Error != "" {
		body["error"] = res.Error
	}
	writeJSON(w, res.HTTPStatus, body)
}

// --- diagnostics ------------------------------------------------------------

func (s *Server) handleDiagnostics(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"version":       s.opts.Version,
		"aggregatorUrl": s.opts.AggregatorURL,
		"diagnostics":   s.images.Diagnostics(r.Context()),
	})
}

// handleFidoTest runs one resolver attempt and returns the full capture. A
// failed attempt is still HTTP 200 with ok:false -- the test itself ran, and
// its outcome is the data the caller asked for; error statuses are kept for
// requests the route refused to run.
func (s *Server) handleFidoTest(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	arch := r.URL.Query().Get("arch")
	if arch == "" {
		writeErr(w, http.StatusBadRequest, "arch query parameter is required (amd64 or arm64)")
		return
	}
	id := imagestore.ImageID{ImageKey: imagestore.KeyWindows11, Arch: arch}
	attempt, err := s.images.FidoTest(r.Context(), arch)
	if err != nil {
		s.record("fido-test", id, "refused", err.Error())
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	// The minted URL itself stays out of the audit line: it is hundreds of
	// signature bytes that expire within hours, and the attempt JSON already
	// went to the caller who asked.
	outcome, detail := "ok", "url minted"
	if attempt.Error != "" {
		outcome, detail = "failed", attempt.Error
	}
	s.record("fido-test", id, outcome, detail)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      attempt.Error == "",
		"attempt": attempt,
	})
}

// --- refusal mapping --------------------------------------------------------

// refusalReason maps a refusal onto the fixed machine-readable token the control
// route contract promises. Anything the pool engine did not name -- a raw
// filesystem error from walking the share, say -- collapses to one constant:
// relaying it verbatim would break the contract and echo the pool path on a
// route that answers before any credential is checked.
func refusalReason(err error) string {
	switch msg := err.Error(); msg {
	case imagestore.ReasonPoolUnavailable, imagestore.ReasonLeaseReadOnly, imagestore.ReasonUnsupported:
		return msg
	default:
		return imagestore.ReasonPoolWalkFailed
	}
}

// refusalStatus keeps one condition to one status code across routes: ensure
// answers 404 for a family the agent has no resolver for, so the mutating routes
// must not answer 503 for the same thing.
func refusalStatus(reason string) int {
	if reason == imagestore.ReasonUnsupported {
		return http.StatusNotFound
	}
	return http.StatusServiceUnavailable
}

// --- mutating routes --------------------------------------------------------

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	id, ok := s.imageID(w, r)
	if !ok {
		return
	}
	started, err := s.images.ForceRefresh(id)
	if err != nil {
		s.record("refresh", id, "failed", err.Error())
		reason := refusalReason(err)
		log.Printf("download-agent-service: refresh %s refused (%s): %v", id, reason, err)
		writeReason(w, refusalStatus(reason), reason, "refresh refused: "+reason)
		return
	}
	s.record("refresh", id, "started", "")
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true, "started": started, "joined": !started})
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	id, ok := s.imageID(w, r)
	if !ok {
		return
	}
	if err := s.images.Delete(id); err != nil {
		s.record("delete", id, "failed", err.Error())
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.record("delete", id, "ok", "")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handlePrune(w http.ResponseWriter, r *http.Request) {
	if !s.available(w) {
		return
	}
	id, ok := s.imageID(w, r)
	if !ok {
		return
	}
	n, err := s.images.PrunePrevious(id)
	if err != nil {
		s.record("prune", id, "failed", err.Error())
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.record("prune", id, "ok", "")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "pruned": n})
}

func (s *Server) handleRefreshAll(w http.ResponseWriter, _ *http.Request) {
	if !s.available(w) {
		return
	}
	n, err := s.images.RefreshAll()
	if err != nil {
		s.record("refresh-all", imagestore.ImageID{}, "failed", err.Error())
		reason := refusalReason(err)
		log.Printf("download-agent-service: pool-wide refresh refused (%s): %v", reason, err)
		writeReason(w, refusalStatus(reason), reason, "pool refresh refused: "+reason)
		return
	}
	s.record("refresh-all", imagestore.ImageID{}, "ok", "")
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true, "started": n})
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
		// No 'unsafe-inline' anywhere: the page carries no inline <style> and the
		// script sets the one dynamic dimension (the progress fill) through the
		// CSSOM, which CSP does not govern -- unlike a style="" attribute, which
		// this policy blocks.
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'")
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
