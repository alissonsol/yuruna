// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package servicecfg holds the shared daemon configuration readers.
package servicecfg

import (
	"net"
	"os"
	"strconv"
	"strings"
)

// UIPort returns an advertisable port, or zero for an invalid listen address.
func UIPort(address string) int {
	_, value, err := net.SplitHostPort(address)
	if err != nil {
		return 0
	}
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return 0
	}
	return port
}

// ReadAuthToken reads the explicit path, permitting legacy fallback only for the default.
// The returned source and error let each daemon retain its localized diagnostics.
func ReadAuthToken(path, defaultPath, legacyPath string) (token, source string, err error) {
	if strings.TrimSpace(path) == "" {
		return "", "", nil
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		if path == defaultPath {
			if legacy, legacyErr := os.ReadFile(legacyPath); legacyErr == nil {
				return strings.TrimSpace(string(legacy)), legacyPath, nil
			}
		}
		return "", path, err
	}
	return strings.TrimSpace(string(bytes)), path, nil
}
