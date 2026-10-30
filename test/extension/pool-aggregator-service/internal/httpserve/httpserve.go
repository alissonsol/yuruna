// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42f8d7f8-9e29-4579-8b8c-878000bbc1da

// Package httpserve holds the collector's HTTP transport: the listener that
// serves plain HTTP and TLS on one port, and the request and response helpers
// the route handlers share. The handlers themselves stay beside the pool state
// they read, under its one lock.
package httpserve

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"time"
)

// --- REGION: Request and response helpers
// SourceIP returns the connection's source IP (no port). RemoteAddr is the
// real peer on the trusted LAN; X-Forwarded-For is deliberately NOT consulted (it is
// client-settable and would let a member spoof another host's identity binding).
func SourceIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// IsLoopbackSource reports whether a request came from this machine. Used to
// scope /metrics: the exposition carries the live lab token as a label, and
// anything that reads it holds the credential that unlocks every gated control
// in the pool.
func IsLoopbackSource(r *http.Request) bool {
	ip := net.ParseIP(SourceIP(r))
	return ip != nil && ip.IsLoopback()
}

// WriteJSON sets the content type and encodes one map. Older routes inline the
// pair, and changing those is churn without a reason.
func WriteJSON(w http.ResponseWriter, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(payload)
}

// sniffTimeout bounds how long a fresh connection may sit silent before its
// first byte. Without it an idle TCP connect would pin a sniff goroutine
// forever: the http.Server's ReadTimeout only starts once the connection is
// handed over, and the hand-over is what the sniff gates.
const sniffTimeout = 10 * time.Second

// dualProtocolListener accepts on one port and hands the http.Server either a
// *tls.Conn or the raw connection, decided by the first byte (0x16 is the TLS
// handshake record type; no HTTP method starts with it). http.Server.Serve
// detects *tls.Conn, runs the handshake, and populates Request.TLS, so both
// protocols share the one mux and port. The plain path (and the TLS path via
// per-conn tls.Server, which negotiates no ALPN) speaks HTTP/1.1 only; every
// consumer of this service does.
type dualProtocolListener struct {
	inner     net.Listener
	tlsCfg    *tls.Config
	conns     chan net.Conn
	errs      chan error
	done      chan struct{}
	closeOnce sync.Once
}

// NewDualProtocolListener wraps inner so one port serves both plain HTTP and TLS.
func NewDualProtocolListener(inner net.Listener, tlsCfg *tls.Config) net.Listener {
	l := &dualProtocolListener{
		inner:  inner,
		tlsCfg: tlsCfg,
		conns:  make(chan net.Conn),
		// Buffered so acceptLoop can park a fatal error and exit even when no
		// Accept is pending; Accept drains it later.
		errs: make(chan error, 1),
		done: make(chan struct{}),
	}
	go l.acceptLoop()
	return l
}

// acceptLoop accepts raw connections and sniffs each in its own goroutine, so
// one client that connects and then stalls before its first byte cannot block
// the accept path for everyone else.
func (l *dualProtocolListener) acceptLoop() {
	var delay time.Duration
	for {
		c, err := l.inner.Accept()
		if err != nil {
			select {
			case l.errs <- err:
			default: // an earlier error is already parked; drop this one
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			// Transient accept failure (e.g. EMFILE): keep accepting, after the
			// capped delay net/http.Server.Serve applies to its own Accept.
			// That backoff paces only the wrapper's Accept; without one here
			// this loop retries the inner listener at full speed and pins a core
			// until descriptors free up. The parked error still surfaces through
			// Accept.
			delay = nextAcceptDelay(delay)
			select {
			case <-l.done:
				return
			case <-time.After(delay):
			}
			continue
		}
		delay = 0
		go l.sniff(c)
	}
}

// nextAcceptDelay doubles the wait after a failed accept, from 5ms up to 1s.
func nextAcceptDelay(d time.Duration) time.Duration {
	if d == 0 {
		return 5 * time.Millisecond
	}
	if d *= 2; d > time.Second {
		return time.Second
	}
	return d
}

func (l *dualProtocolListener) sniff(c net.Conn) {
	if err := c.SetReadDeadline(time.Now().Add(sniffTimeout)); err != nil {
		_ = c.Close()
		return
	}
	var first [1]byte
	if _, err := io.ReadFull(c, first[:]); err != nil {
		_ = c.Close()
		return
	}
	if err := c.SetReadDeadline(time.Time{}); err != nil {
		_ = c.Close()
		return
	}
	var out net.Conn = &replayConn{Conn: c, head: first[:]}
	if first[0] == 0x16 {
		out = tls.Server(out, l.tlsCfg)
	}
	select {
	case l.conns <- out:
	case <-l.done:
		_ = c.Close()
	}
}

func (l *dualProtocolListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case err := <-l.errs:
		return nil, err
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *dualProtocolListener) Close() error {
	var err error
	l.closeOnce.Do(func() {
		close(l.done)
		err = l.inner.Close()
	})
	return err
}

func (l *dualProtocolListener) Addr() net.Addr { return l.inner.Addr() }

// replayConn replays the sniffed first byte ahead of the wrapped connection's
// stream, so the protocol detection consumes nothing from the peer's view.
type replayConn struct {
	net.Conn
	head []byte
}

func (c *replayConn) Read(p []byte) (int, error) {
	if len(c.head) > 0 {
		n := copy(p, c.head)
		c.head = c.head[n:]
		return n, nil
	}
	return c.Conn.Read(p)
}
