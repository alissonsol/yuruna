// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42abb655-c5bc-4e66-89bc-14a855a0cc73

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
