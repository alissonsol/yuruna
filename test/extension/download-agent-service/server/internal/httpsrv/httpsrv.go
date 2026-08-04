// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package httpsrv serves the download-agent service UI and the JSON API behind
// it. It mirrors the pool-control-service httpsrv (static page + strict CSP, all
// dynamic data over /api/*) and the stash-service large-artifact idiom: no
// Read/Write timeout, because a generation is routinely multiple gigabytes and a
// write deadline would guillotine a legitimate stream.
package httpsrv

import (
	"context"
	"net"
	"net/http"
	"os"
	"time"

	"download-agent-service/internal/imagestore"
	"download-agent-service/internal/state"
	"download-agent-service/internal/yex/labgate"
)

// ImageAPI is the pool surface the handlers call; imagestore.Agent satisfies it
// and tests inject a fake.
type ImageAPI interface {
	PoolAvailable() bool
	Status(now time.Time) imagestore.Status
	Catalog(now time.Time) ([]imagestore.CatalogEntry, imagestore.Totals)
	Entry(now time.Time, id imagestore.ImageID) (imagestore.CatalogEntry, bool)
	Ensure(now time.Time, id imagestore.ImageID, fp imagestore.Fingerprint) imagestore.EnsureResult
	OpenGeneration(id imagestore.ImageID, generation string) (*os.File, os.FileInfo, error)
	ForceRefresh(id imagestore.ImageID) (bool, error)
	RefreshAll() (int, error)
	Delete(id imagestore.ImageID) error
	PrunePrevious(id imagestore.ImageID) (int, error)
}

// Options configures the server.
type Options struct {
	Addr    string
	Version string
	// Store persists the audit log + status under the pool share; nil disables it.
	Store *state.Store
	// Images is the pool engine; nil leaves every image route answering 503.
	Images ImageAPI

	// AuthToken is the lab auth token the mutating routes accept as a bearer for
	// automation. The interactive way through the same gate is the dashboard's
	// rotating lab token, which AggregatorURL validates. Neither configured
	// means no mutation can be authorized, and the routes answer 503 rather than
	// running ungated.
	AuthToken string

	// AggregatorURL validates a submitted lab token (and is reported by the
	// status route). Empty leaves the bearer as the only way through the gate.
	AggregatorURL string

	// Carried for the status report only; the engine holds its own copies.
	HostID   string
	PoolDir  string
	StateDir string
}

// Server is the download-agent-service UI/API HTTP server.
type Server struct {
	opts    Options
	state   *state.Store
	images  ImageAPI
	gate    *labgate.Gate
	httpSrv *http.Server
	started time.Time
}

// New builds a Server.
func New(opts Options) *Server {
	s := &Server{opts: opts, state: opts.Store, images: opts.Images, started: time.Now()}
	s.gate = labgate.New(labgate.Options{
		AggregatorURL: opts.AggregatorURL,
		BearerToken:   opts.AuthToken,
		CookieName:    sessionCookie,
		Audit:         s.auditUnlock,
	})
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
