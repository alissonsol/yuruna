// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http"

	"yuruna.com/test/extension/extension-sdk/hostinfo"
)

// handleHostInfo returns the lightweight host facts the shared UI footer
// renders: this host's id, the daemon version, and the server's own LAN IP
// addresses. It is page-agnostic on purpose -- any UI page drives the same
// footer module (assets/common.js initFooter) from this one endpoint, so the
// footer needs no page-specific data shape -- and it is intentionally cheap so
// the footer's periodic poll stays trivial.
//
// Whether the caller may delete is NOT here: that is a question about a
// credential this browser holds, not about the host, and it changes the moment
// a session is unlocked while these facts do not change at all. /api/session
// answers it, which is also what keeps the footer's poll from re-deciding the
// page's controls.
func (s *Server) handleHostInfo(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"localHostId": s.localHostID,
		"version":     s.version,
		"serverIps":   hostinfo.IPLines(),
	})
}
