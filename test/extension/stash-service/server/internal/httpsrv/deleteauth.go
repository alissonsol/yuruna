// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net"
	"strings"
)

// Delete authorization. The stash is an open drop box on a trusted LAN:
// reads (list/get/raw/download) and writes (create) stay open to any host so a
// guest can push and anyone can browse. DELETE is the one destructive verb, so
// it is restricted to requests that originate from the VM itself (loopback or
// any of the VM's own interface addresses) or from the deploying host IP passed
// at launch via --host-ip. A LAN peer can therefore browse and create but can
// never destroy the corpus over HTTP. This gate is the HTTP-side counterpart to
// the existing §8.3 ownership rule (which restricts WHICH stash a delete may
// touch); together they bound both the caller and the target.

// parseHostIPs turns the --host-ip value (a comma/space/semicolon-separated
// list, usually a single address) into net.IPs, silently dropping blanks and
// unparseable tokens. An empty or malformed value therefore yields "no host IP
// is allowed" -- VM-local deletes still work -- rather than a launch failure.
func parseHostIPs(s string) []net.IP {
	var out []net.IP
	for _, tok := range strings.FieldsFunc(s, func(r rune) bool {
		return r == ',' || r == ';' || r == ' ' || r == '\t' || r == '\n'
	}) {
		if ip := net.ParseIP(tok); ip != nil {
			out = append(out, ip)
		}
	}
	return out
}

// deleteAllowed reports whether a DELETE from clientIP (the request's source
// address, as clientIP(r) extracts it) may proceed: true for the VM itself
// (loopback or a local interface address) or a configured host IP; false for
// every other LAN peer and for an unparseable address (fail closed).
func (s *Server) deleteAllowed(clientIP string) bool {
	ip := net.ParseIP(clientIP)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	for _, h := range s.deleteHostIPs {
		if h.Equal(ip) {
			return true
		}
	}
	return isLocalInterfaceIP(ip)
}

// isLocalInterfaceIP reports whether ip is one of this VM's own interface
// addresses. Enumerated per call (delete is a rare operation) so a DHCP lease
// change is honored without a daemon restart. Best-effort: an enumeration error
// reports false, leaving loopback + the configured host IP as the allowed set.
func isLocalInterfaceIP(ip net.IP) bool {
	ifaces, err := net.Interfaces()
	if err != nil {
		return false
	}
	for _, ifc := range ifaces {
		addrs, aerr := ifc.Addrs()
		if aerr != nil {
			continue
		}
		for _, a := range addrs {
			var aip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				aip = v.IP
			case *net.IPAddr:
				aip = v.IP
			}
			if aip != nil && aip.Equal(ip) {
				return true
			}
		}
	}
	return false
}
