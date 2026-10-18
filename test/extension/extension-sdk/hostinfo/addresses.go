// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package hostinfo supplies the host facts shared by extension-service UIs.
package hostinfo

import (
	"net"
	"sort"
	"strings"
)

// IPLines lists active non-loopback, non-link-local addresses as up to two
// lines: sorted unique IPv4 addresses, then sorted unique IPv6 addresses.
// Interface errors are best-effort: failed enumerations contribute no addresses.
// Addresses are read on every call so DHCP and interface changes remain visible.
func IPLines() string {
	return ipLines(net.Interfaces, func(iface net.Interface) ([]net.Addr, error) {
		return iface.Addrs()
	})
}

func ipLines(interfaces func() ([]net.Interface, error), addresses func(net.Interface) ([]net.Addr, error)) string {
	ifaces, err := interfaces()
	if err != nil {
		return ""
	}
	var v4, v6 []string
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := addresses(ifc)
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch value := addr.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
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

func commaJoinUnique(addrs []string) string {
	if len(addrs) == 0 {
		return ""
	}
	sort.Strings(addrs)
	uniq := make([]string, 0, len(addrs))
	for i, addr := range addrs {
		if i == 0 || addr != addrs[i-1] {
			uniq = append(uniq, addr)
		}
	}
	return strings.Join(uniq, ",")
}
