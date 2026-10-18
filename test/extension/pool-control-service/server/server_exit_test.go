// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"flag"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestHTTPBindFailureExitsUnsuccessfully(t *testing.T) {
	if os.Getenv("YURUNA_DAEMON_TEST_CHILD") == "1" {
		flag.CommandLine = flag.NewFlagSet("fixture-daemon", flag.ExitOnError)
		os.Args = []string{"fixture-daemon", "--http-addr=" + os.Getenv("YURUNA_DAEMON_TEST_ADDR"), "--repo-dir", os.Getenv("YURUNA_DAEMON_TEST_DIR"), "--scan-interval=0", "--auth-token-file=", "--refresh-authority-file=", "--refresh-credential-file="}
		main()
		os.Exit(0)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestHTTPBindFailureExitsUnsuccessfully$")
	cmd.Env = append(os.Environ(), "YURUNA_DAEMON_TEST_CHILD=1", "YURUNA_DAEMON_TEST_ADDR="+listener.Addr().String(), "YURUNA_DAEMON_TEST_DIR="+t.TempDir())
	output, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("shutdown exceeded its bound: %s", output)
	}
	failure, ok := err.(*exec.ExitError)
	if !ok || failure.ExitCode() != 1 || !strings.Contains(string(output), "http server error:") {
		t.Fatalf("exit=%v output=%s", err, output)
	}
}
