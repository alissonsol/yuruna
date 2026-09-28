// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http"
	"net/url"
	"strings"

	"yuruna.com/test/extension/extension-sdk/hostinfo"
)

// handleHostInfo returns the lightweight host facts the shared UI chrome
// renders: this host's id, the daemon version, and the server's own LAN IP
// addresses. It is page-agnostic on purpose -- every page of this service drives
// the same header and footer module (assets/common.js initChrome) from this one
// endpoint, so the chrome needs no page-specific data shape -- and it is
// intentionally cheap so the footer's periodic poll stays trivial.
//
// goBaseUrl rides along because the tables turn every host id into a link to
// that host's own status page, and the only durable way there is the
// aggregator's /go/host redirect (it resolves the host's CURRENT IP server-side
// and hands the browser a short-lived control proof). Empty when this daemon was
// launched without an aggregator, which the UI reads as "render the id
// unlinked".
//
// The version is also on /api/session and /api/diagnostics, but neither is the
// right dependency for page furniture: one describes the write gate and the
// other runs a full dependency probe.
func (s *Server) handleHostInfo(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"localHostId": s.opts.HostID,
		"version":     s.opts.Version,
		"serverIps":   hostinfo.IPLines(),
		"goBaseUrl":   goBaseURL(s.opts.AggregatorURL),
	})
}

// goBaseURL turns the configured aggregator URL into the base a BROWSER follows
// to reach its /go/* redirects, which means forcing the scheme back to http.
//
// The configured URL is https by design: a provisioned proxy mints the
// aggregator a TLS leaf, and this daemon's own server-to-server calls (the
// presence beacon, the lab-token and control-proof checks, the pool read) should
// use it. A browser must not. Those redirects land on a host's plain-http status
// page, so the https hop protects nothing the next hop does not already carry in
// clear -- while putting a proxy-CA interstitial in front of every host link,
// because an operator's browser has no reason to trust that CA. The aggregator
// answers both protocols on the same port, so downgrading here costs nothing.
// Same rule the Grafana dashboard's links follow, where cloud-init substitutes a
// plain-http base for exactly this reason.
//
// A non-http(s) or unparseable value yields "": it can only have come from a
// mistyped flag, and an unlinked host id reads better than a dead link.
func goBaseURL(configured string) string {
	trimmed := strings.TrimRight(strings.TrimSpace(configured), "/")
	if trimmed == "" {
		return ""
	}
	u, err := url.Parse(trimmed)
	if err != nil || u.Host == "" {
		return ""
	}
	switch u.Scheme {
	case "http", "https":
		u.Scheme = "http"
	default:
		return ""
	}
	return strings.TrimRight(u.String(), "/")
}
