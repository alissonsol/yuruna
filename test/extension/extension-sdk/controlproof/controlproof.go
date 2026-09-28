// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package controlproof verifies the shared host-control credential wire format.
package controlproof

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strconv"
	"strings"
	"time"
)

// Verify accepts a proof "<expiry>.<base64 HMAC>" only inside the inclusive
// window now <= expiry <= now+maxTTL. The MAC covers the canonical decimal
// expiry, using the token's exact bytes, and is compared in constant time.
// Malformed, expired or mismatched input is false.
func Verify(token, wire string, now time.Time, maxTTL time.Duration) bool {
	if strings.TrimSpace(token) == "" || strings.TrimSpace(wire) == "" {
		return false
	}
	dot := strings.IndexByte(wire, '.')
	if dot <= 0 || dot >= len(wire)-1 {
		return false
	}
	expiry, err := strconv.ParseInt(wire[:dot], 10, 64)
	if err != nil {
		return false
	}
	unix := now.Unix()
	if expiry < unix || expiry > unix+int64(maxTTL/time.Second) {
		return false
	}
	given, err := base64.StdEncoding.DecodeString(wire[dot+1:])
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|" + strconv.FormatInt(expiry, 10)))
	return hmac.Equal(mac.Sum(nil), given)
}
