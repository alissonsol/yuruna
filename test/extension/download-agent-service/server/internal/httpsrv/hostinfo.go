// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http"

	"yuruna.com/test/extension/extension-sdk/hostinfo"
)

// handleHostInfo returns the lightweight host facts the shared UI chrome
// renders: this host's id, the daemon version, and the server's own LAN IP
// addresses. It is page-agnostic on purpose -- every page drives the same header
// and footer module (assets/common.js initChrome) from this one endpoint, so the
// chrome needs no page-specific data shape -- and it is intentionally cheap so
// the footer's periodic poll stays trivial.
//
// The version is also on /api/v1/status, but that route describes the POOL and
// answers with the whole catalog summary. A header that only needs a version
// string must not depend on the pool being mounted.
func (s *Server) handleHostInfo(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"localHostId": s.opts.HostID,
		"version":     s.opts.Version,
		"serverIps":   hostinfo.IPLines(),
	})
}
