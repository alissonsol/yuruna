// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import "net"

// hostOnly returns the host portion of a host:port remote address, or the raw
// string when it has no parseable port. Shared by the SCP (runCommand) and SFTP
// (serveSFTP) ingest paths, which both derive clientIP from the SSH remote addr.
func hostOnly(remote string) string {
	if h, _, err := net.SplitHostPort(remote); err == nil {
		return h
	}
	return remote
}
