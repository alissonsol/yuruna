// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package httpsrv serves the pool-control UI (3 static pages) and the JSON API
// that drives it. It mirrors the stash-service httpsrv: static pages + a strict
// CSP, all dynamic data over /api/*, and mutating endpoints that relay the
// pool-admin CLIs' outcome (a failed push surfaces as a UI error, C4 discipline).
package httpsrv

import (
	"context"
	"net"
	"net/http"
	"time"

	"pool-control/internal/intent"
	"pool-control/internal/state"
)

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
}

// Server is the pool-control UI/API HTTP server.
type Server struct {
	intent  IntentAPI
	state   *state.Store
	opts    Options
	httpSrv *http.Server
}

// New builds a Server over the given intent API.
func New(api IntentAPI, opts Options) *Server {
	s := &Server{intent: api, state: opts.Store, opts: opts}
	s.httpSrv = &http.Server{
		Addr:              opts.Addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	return s
}

// ListenAndServe runs until ctx is cancelled, then shuts down gracefully.
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
