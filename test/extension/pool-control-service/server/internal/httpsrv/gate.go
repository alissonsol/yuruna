// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"log"
	"net/http"
	"time"

	"pool-control-service/internal/state"
)

// The write gate in front of the operator board.
//
// --- REGION: https://yuruna.link/extensions-api#the-lab-token-rule
//
// Deliberately NOT per-user auth. It stops a stranger on the LAN and an
// accidental visitor; it does not tell you WHO assigned something, which is why
// every mutation is still audited. If that traceability ever matters, this is
// the piece to replace.
//
// Reads stay open, matching every other extension service and the aggregator's
// own pool-status: the board renders on a wall display with no credential, and
// nothing it renders is a secret the LAN cannot already read from the pool.

// sessionCookie is this service's own cookie name, so a session here is not a
// session anywhere else.
const sessionCookie = "yuruna_board"

// auditUnlock records an unlock attempt with the address that made it. The
// aggregator's own audit cannot do this job: every operator reaches it through
// this daemon, so from there the whole lab is one source address.
func (s *Server) auditUnlock(ip, outcome, detail string) {
	if detail != "" {
		log.Printf("pool-control-service: unlock %s from %s: %s", outcome, ip, detail)
	} else {
		log.Printf("pool-control-service: unlock %s from %s", outcome, ip)
	}
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		TimeUTC: now.UTC().Format(time.RFC3339),
		Action:  "unlock", Target: outcome, OK: outcome == "ok", Detail: "from " + ip,
	})
}

// handleSession reports which ways through the gate exist right now and whether
// this device is already through one, so the UI knows whether to show the lab
// token prompt, say that only automation can mutate, or explain that nothing is
// configured at all.
func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	sess := s.gate.Session(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            sess.OK,
		"labToken":      sess.LabToken,
		"bearer":        sess.Bearer,
		"authed":        sess.Authed,
		"configured":    sess.Configured,
		"mutationsOpen": sess.MutationsOpen,
		"version":       s.opts.Version,
	})
}

// handleLogin exchanges the dashboard's lab token for a session cookie.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	s.gate.HandleLogin(w, r)
}

// handleUnlockProof exchanges the short-lived control proof the aggregator's
// /go/stash redirect leaves in the URL fragment for a session cookie, so an
// operator who arrived by clicking this service out of the Yuruna hosts
// dashboard is not sent back to it to copy a code off a tile.
func (s *Server) handleUnlockProof(w http.ResponseWriter, r *http.Request) {
	s.gate.HandleProofUnlock(w, r)
}
