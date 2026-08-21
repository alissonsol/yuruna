// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// The daemon runs on the caching-proxy-service VM, which is Linux; this entry
// point exists so the package still BUILDS on a harness host that is not.
// Without it every non-Linux `go vet` and `go test` in this module exits 1 on
// "matched no packages" -- the parser's tests would then run on exactly one
// operating system while reporting nothing on the others.
//go:build !linux

package main

import "log"

func main() {
	log.Fatal("caching-proxy-parser-service runs on Linux only: detecting a logrotate needs the inode from syscall.Stat_t")
}
