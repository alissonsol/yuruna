// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net"
	"net/http"
	"sort"
	"strings"
)

// handleHostInfo returns the lightweight host facts the shared UI footer
// renders: this host's id, the daemon version, and the server's own LAN IP
// addresses. It is page-agnostic on purpose — any UI page drives the same
// footer module (assets/common.js initFooter) from this one endpoint, so the
// footer needs no page-specific data shape — and it is intentionally cheap so
// the footer's periodic poll stays trivial.
//
// canDelete/clientIp answer, for THIS caller, the source gate the delete
// handler applies (deleteauth.go). Without them a page can only offer a Delete
// button and let the operator discover the refusal by pressing it — the daemon
// knows the answer while it is rendering the list, so it says so. Telling a
// caller its own source address discloses nothing it could not learn by other
// means; the set that WOULD be allowed stays in the daemon's log.
func (s *Server) handleHostInfo(w http.ResponseWriter, r *http.Request) {
	src := clientIP(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"localHostId": s.localHostID,
		"version":     s.version,
		"serverIps":   serverIPLines(),
		"clientIp":    src,
		"canDelete":   s.deleteAllowed(src),
	})
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
