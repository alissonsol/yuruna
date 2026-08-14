// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"log"
	"net/http"
)

// The delete gate.
//
// DELETE is the stash's one destructive verb, so it carries the lab-token gate
// every extension service shares: a session an operator unlocks with the
// dashboard's rotating code, or the short-lived control proof a browser is
// handed when it arrives from the dashboard's Extension hosts table. Reads and
// creates stay outside it -- browsing and dropping a file in are what the stash
// is for on a trusted LAN, and a credential in front of them would make one a
// prerequisite for a guest pushing a diagnostic over scp.
//
// The daemon holds no lab auth token of its own (nothing writes that file into
// this VM's seed), so every unlock is judged by the pool aggregator. With no
// --aggregator-url, or with the aggregator unreachable, the gate refuses rather
// than opening: an operator who cannot delete for a minute is a smaller problem
// than a corpus anyone on the LAN can erase.

// sessionCookie is this service's own cookie name, so a session here is not a
// session anywhere else.
const sessionCookie = "yuruna_stash"

// auditUnlock records an unlock attempt with the address that made it. The
// aggregator's own audit cannot do this job: every operator reaches it through
// this daemon, so from there the whole lab is one source address. Log-only --
// this daemon keeps no state store, and journald already holds its operational
// record.
func (s *Server) auditUnlock(ip, outcome, detail string) {
	if detail != "" {
		log.Printf("stash-service: unlock %s from %s: %s", outcome, ip, detail)
	} else {
		log.Printf("stash-service: unlock %s from %s", outcome, ip)
	}
}

// handleSession reports which ways through the gate exist right now and whether
// this device is already through one, so the UI knows whether to show the lab
// token prompt, withhold the delete controls, or explain that nothing is
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
		"version":       s.version,
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
