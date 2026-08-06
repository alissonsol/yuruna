// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

// handleHostInfo returns the lightweight host facts the shared UI chrome
// renders: this host's id, the daemon version, and the server's own LAN IP
// addresses. It is page-agnostic on purpose — every page of this service drives
// the same header and footer module (assets/common.js initChrome) from this one
// endpoint, so the chrome needs no page-specific data shape — and it is
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
		"serverIps":   serverIPLines(),
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
// clear — while putting a proxy-CA interstitial in front of every host link,
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

// serverIPLines returns this host's non-loopback, non-link-local unicast IPs as
// up to two newline-separated lines: IPv4 (comma-joined) then IPv6, each sorted
// and de-duplicated. The two-line shape mirrors the status pages' footer (whose
// ipaddresses.txt carries one address family per line, so the IP textarea
// renders at most two rows). Link-local addresses (169.254/16, fe80::/10) are
// dropped as noise — they are never how a peer reaches the daemon. Returns ""
// when no usable address is found, so the footer shows its em-dash placeholder.
// Best-effort: an enumeration error yields "".
func serverIPLines() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var v4, v6 []string
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, aerr := ifc.Addrs()
		if aerr != nil {
			continue
		}
		for _, a := range addrs {
			var ip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
				continue
			}
			if v4ip := ip.To4(); v4ip != nil {
				v4 = append(v4, v4ip.String())
			} else {
				v6 = append(v6, ip.String())
			}
		}
	}
	lines := make([]string, 0, 2)
	if joined := commaJoinUnique(v4); joined != "" {
		lines = append(lines, joined)
	}
	if joined := commaJoinUnique(v6); joined != "" {
		lines = append(lines, joined)
	}
	return strings.Join(lines, "\n")
}

// commaJoinUnique sorts, de-duplicates, and comma-joins addrs (empty -> "").
func commaJoinUnique(addrs []string) string {
	if len(addrs) == 0 {
		return ""
	}
	sort.Strings(addrs)
	uniq := make([]string, 0, len(addrs))
	for i, a := range addrs {
		if i == 0 || a != addrs[i-1] {
			uniq = append(uniq, a)
		}
	}
	return strings.Join(uniq, ",")
}
