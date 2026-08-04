// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package httpsrv serves the pool-control-service UI (3 static pages) and the JSON API
// that drives it. It mirrors the stash-service httpsrv: static pages + a strict
// CSP, all dynamic data over /api/*, and mutating endpoints that relay the
// pool-admin CLIs' outcome (a failed push surfaces as a UI error, never a
// silent success).
package httpsrv

import (
	"context"
	"net"
	"net/http"
	"time"

	"pool-control-service/internal/intent"
	"pool-control-service/internal/state"
	"pool-control-service/internal/yex/labgate"
	"pool-control-service/internal/yex/pool"
)

// aggregatorTimeout bounds one aggregator read. The board holds a browser
// connection while it waits, so a collector that has stopped answering must grey
// the numbers out rather than hang the page.
const aggregatorTimeout = 15 * time.Second

// IntentAPI is the write/read surface the handlers call; intent.Runner
// satisfies it, and tests inject a fake.
type IntentAPI interface {
	State(ctx context.Context) intent.Result
	NewPool(ctx context.Context, poolID, displayName, desiredState string) intent.Result
	RemovePool(ctx context.Context, poolID string, force bool) intent.Result
	SetDesiredState(ctx context.Context, poolID, state string) intent.Result
	AddHost(ctx context.Context, poolID, hostID string) intent.Result
	RemoveHost(ctx context.Context, poolID, hostID string) intent.Result
	AssignTestSet(ctx context.Context, poolID, name, frameworkURL, projectURL string) intent.Result
	SetTestSetDef(ctx context.Context, name, frameworkURL, projectURL string) intent.Result
	DeleteTestSetDef(ctx context.Context, name string) intent.Result
}

// Options configures the server.
type Options struct {
	Addr    string
	Version string
	// Store persists the audit log + status under the pool NAS; nil disables it
	// (host-side launcher / tests run without a NAS).
	Store *state.Store
	// The launch values below are carried purely so /diagnostics can report the
	// daemon's own view of its dependencies. The intent layer holds its own
	// copies; these are for the report, which is why they are plain strings
	// rather than a second source of truth.
	PwshPath      string
	RepoDir       string
	StateDir      string
	AggregatorURL string
	HostID        string
	IntentGitURL  string
	// AuthToken is the shared lab auth token accepted as a bearer on the routes
	// that change pool configuration. Empty leaves the dashboard's lab token as
	// the only way in; it never leaves those routes open.
	AuthToken string
}

// Server is the pool-control-service UI/API HTTP server.
type Server struct {
	intent IntentAPI
	state  *state.Store
	opts   Options
	gate   *labgate.Gate
	// pool reads the aggregator for the board's cycle counts and the
	// auto-enrolment sweep's candidate list.
	pool    *pool.Client
	httpSrv *http.Server
	started time.Time
}

// New builds a Server over the given intent API.
func New(api IntentAPI, opts Options) *Server {
	s := &Server{intent: api, state: opts.Store, opts: opts, started: time.Now()}
	s.gate = labgate.New(labgate.Options{
		AggregatorURL: opts.AggregatorURL,
		BearerToken:   opts.AuthToken,
		CookieName:    sessionCookie,
		Audit:         s.auditUnlock,
	})
	// NoCache: the board is the operator's live view of the lab, and a cached
	// snapshot would hold a just-enrolled host off the page for the window.
	s.pool = pool.New(pool.Options{BaseURL: opts.AggregatorURL, Timeout: aggregatorTimeout, CacheTTL: pool.NoCache})
	s.httpSrv = &http.Server{
		Addr:              opts.Addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	return s
}

// ListenAndServe runs until ctx is canceled, then shuts down gracefully.
func (s *Server) ListenAndServe(ctx context.Context) error {
	if s.opts.Addr == "" {
		<-ctx.Done()
		return nil
	}
	ln, err := net.Listen("tcp", s.opts.Addr)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.httpSrv.Shutdown(sctx)
	}()
	if err := s.httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// Handler exposes the mux for tests (httptest.NewServer(s.Handler())).
func (s *Server) Handler() http.Handler { return s.routes() }
