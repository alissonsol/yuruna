// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"log"
	"net/http"

	"download-agent-service/internal/imagestore"
)

// The write gate. Deleting a generation or forcing a re-download changes what
// every host in the pool receives, so those routes carry the lab-token gate
// every extension service shares: a session an operator unlocks with the
// dashboard's rotating code, or the lab auth token as a bearer for automation.
//
// Reads are deliberately outside it. The catalog, the metadata and the bytes
// are open on the trusted LAN, matching the pool-status and stash artifact
// posture; gating them would make a credential a prerequisite for a host
// fetching an image.

// sessionCookie is this service's own cookie name, so a session here is not a
// session anywhere else.
const sessionCookie = "yuruna_download_agent"

// auditUnlock records an unlock attempt with the address that made it. The
// aggregator's own audit cannot do this job: every operator reaches it through
// this daemon, so from there the whole lab is one source address.
func (s *Server) auditUnlock(ip, outcome, detail string) {
	if detail != "" {
		log.Printf("download-agent-service: unlock %s from %s: %s", outcome, ip, detail)
	} else {
		log.Printf("download-agent-service: unlock %s from %s", outcome, ip)
	}
	s.record("unlock", imagestore.ImageID{}, outcome, "from "+ip)
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
