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

// parseSourceIP parses a request's source address for the gate below. The zone
// suffix an IPv6 source carries (fe80::1%eth0 -- what a browser that reached the
// daemon over a link-local address produces) is stripped first: net.ParseIP
// rejects a zoned literal outright, and the nil would fail the gate closed for a
// caller that may well be this very VM. An IPv4-mapped v6 form (::ffff:10.0.0.1)
// needs no such handling -- net.IP.Equal already matches it against its IPv4 twin.
func parseSourceIP(addr string) net.IP {
	if i := strings.IndexByte(addr, '%'); i >= 0 {
		addr = addr[:i]
	}
	return net.ParseIP(addr)
}

// deleteAllowed reports whether a DELETE from clientIP (the request's source
// address, as clientIP(r) extracts it) may proceed: true for the VM itself
// (loopback or a local interface address) or a configured host IP; false for
// every other LAN peer and for an unparseable address (fail closed).
func (s *Server) deleteAllowed(clientIP string) bool {
	ip := parseSourceIP(clientIP)
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

// allowedDeleteSources renders the permitted set as one phrase for the daemon's
// log. Log-only on purpose: an operator diagnosing a refusal needs to see the
// address the daemon was launched to trust next to the one it actually saw,
// while the HTTP refusal tells a caller nothing but its own address -- a LAN
// peer must not be able to read the lab's addressing out of a 403.
func (s *Server) allowedDeleteSources() string {
	parts := []string{"loopback", "this VM's own interface addresses"}
	if len(s.deleteHostIPs) == 0 {
		parts = append(parts, "no host IP configured (--host-ip empty)")
	}
	for _, h := range s.deleteHostIPs {
		parts = append(parts, h.String())
	}
	return strings.Join(parts, ", ")
}

// sourceLabel renders a source address for a human. A connection whose
// RemoteAddr carried no usable address still has to read as something in a
// sentence, and the empty string would leave the message dangling.
func sourceLabel(clientIP string) string {
	if strings.TrimSpace(clientIP) == "" {
		return "an unknown address"
	}
	return clientIP
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
