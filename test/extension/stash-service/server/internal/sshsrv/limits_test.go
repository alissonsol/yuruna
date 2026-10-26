// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428d5a19-dfca-4c2c-a586-47fa76e21d6b

package sshsrv

import (
	"crypto/ed25519"
	"crypto/rand"
	"net"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// newServingServer is newTestServer with what serving a connection also needs:
// the connection table and an SSH configuration with a host key.
func newServingServer(t *testing.T) *Server {
	t.Helper()
	s := newTestServer(t, true)
	s.conns = make(map[net.Conn]struct{})
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{NoClientAuth: true}
	cfg.AddHostKey(signer)
	s.sshCfg = cfg
	return s
}

// A connection that never completes its handshake is closed at the handshake
// timeout instead of holding a goroutine and a descriptor until the process ends.
func TestASilentConnectionIsClosedAtTheHandshakeTimeout(t *testing.T) {
	saved := handshakeTimeout
	handshakeTimeout = 200 * time.Millisecond
	t.Cleanup(func() { handshakeTimeout = saved })
	s := newServingServer(t)
	server, client := net.Pipe()
	t.Cleanup(func() { _ = client.Close() })
	if !s.trackConn(server) {
		t.Fatal("the first connection was refused")
	}
	done := make(chan struct{})
	go func() { s.handle(server); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a connection that sent nothing was still being served")
	}
}

// Past the connection cap a new connection is refused at once, and a slot that
// comes free is taken again.
func TestConnectionsPastTheCapAreRefused(t *testing.T) {
	saved := maxConnections
	maxConnections = 2
	t.Cleanup(func() { maxConnections = saved })
	s := newServingServer(t)
	pipe := func() net.Conn {
		a, b := net.Pipe()
		t.Cleanup(func() { _ = a.Close(); _ = b.Close() })
		return a
	}
	release := func(c net.Conn) { s.untrackConn(c); s.wg.Done() }
	first, second := pipe(), pipe()
	for _, c := range []net.Conn{first, second} {
		if !s.trackConn(c) {
			t.Fatal("a connection under the cap was refused")
		}
	}
	extra := pipe()
	if s.trackConn(extra) {
		release(extra)
		t.Fatal("a connection past the cap was accepted")
	}
	release(first)
	if !s.trackConn(extra) {
		t.Fatal("the slot a closed connection left was not taken again")
	}
	release(second)
	release(extra)
}
