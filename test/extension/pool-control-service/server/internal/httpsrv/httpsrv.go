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

	"pool-control-service/internal/discovery"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/intent"
	"pool-control-service/internal/state"
	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/labgate"
	"yuruna.com/test/extension/extension-sdk/pool"
)

// aggregatorTimeout bounds one aggregator read. The board holds a browser
// connection while it waits, so a collector that has stopped answering must gray
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
	// AuthToken is the internal authentication key accepted as a bearer on
	// the routes that change pool configuration. Empty leaves the dashboard's
	// lab token as the only way in; it never leaves those routes open.
	AuthToken string
	// AuthTokenFile is where AuthToken was read from. Carried so the one error
	// an operator can act on -- "this service can prove control to no host" --
	// names the file THIS daemon was launched with rather than the default.
	AuthTokenFile string
	// Language is the operator's lab-wide lock on the reader's language, from
	// test.config.yml. Empty or "auto" means no lock, and a browser's own
	// Accept-Language decides. A tag this binary did not compile in is refused
	// rather than obeyed: a typo must not select a catalog that is not here.
	Language string
	// AllowPseudoLocale opens the pseudo locales to negotiation. Off in a
	// release launch. A reference run turns it on so expanded and mirrored
	// text can be exercised against this service rather than against a fixture.
	AllowPseudoLocale bool
	// ScanCIDR is the network the discovery sweep walks. Empty means the /24
	// around this service's own address, which is the network an operator means
	// when they have not said otherwise.
	ScanCIDR string
	// ScanPort is the host status-service port probed on each address.
	ScanPort int
	// ScanInterval is the sweep cadence. Zero stops the timer and leaves the
	// Scan page's manual run as the only way discovery happens.
	ScanInterval time.Duration
	// ScanTTL is how long a discovered host stays on the list after its last
	// sighting. Zero takes discovery.DefaultTTL; negative keeps every host
	// forever, which is the escape hatch for a lab that would rather read past
	// stale rows than lose one.
	ScanTTL time.Duration
}

// Server is the pool-control-service UI/API HTTP server.
type Server struct {
	// assets is built once during New and read-only thereafter: a handler
	// never rereads embed.FS, recompresses a body, or rebuilds a map.
	assets assetStore
	intent IntentAPI
	state  *state.Store
	opts   Options
	gate   *labgate.Gate
	// localeNegotiator is narrowed to this binary's embedded catalogs once in
	// New. Request handlers read it but never rebuild or mutate its maps.
	localeNegotiator *i18n.Negotiator
	// pool reads the aggregator for the board's cycle counts and the
	// auto-enrollment sweep's candidate list.
	pool *pool.Client
	// hostctl drives the pause switches on the hosts themselves, for the
	// pool-wide selector on the Pools page.
	hostctl *hostctl.Client
	// discovered is this daemon's own list of Yuruna hosts found by scanning,
	// and scan is what fills it. Local by design: the list has to survive an
	// aggregator outage, since a host nobody registered is exactly the case it
	// exists to cover.
	discovered *discovery.Store
	scan       *discovery.Engine
	httpSrv    *http.Server
	started    time.Time
}

// New builds a Server over the given intent API.
func New(api IntentAPI, opts Options) *Server {
	s := &Server{intent: api, state: opts.Store, opts: opts, started: time.Now()}
	s.localeNegotiator = newServiceNegotiator(opts.Language, opts.AllowPseudoLocale)
	s.assets.preparePages(s.localeNegotiator)
	s.gate = labgate.New(labgate.Options{
		AggregatorURL: opts.AggregatorURL,
		BearerToken:   opts.AuthToken,
		CookieName:    sessionCookie,
		Audit:         s.auditUnlock,
	})
	// NoCache: the board is the operator's live view of the lab, and a cached
	// snapshot would hold a just-enrolled host off the page for the window.
	s.pool = pool.New(pool.Options{BaseURL: opts.AggregatorURL, Timeout: aggregatorTimeout, CacheTTL: pool.NoCache})
	s.hostctl = hostctl.New(hostctl.Options{})
	// The discovered list lives beside the audit log, under the same state dir,
	// and falls back to memory when there is none: a host-side launcher with no
	// NAS still scans, it just re-discovers after a restart instead of reading
	// the last answer back.
	port := opts.ScanPort
	if port <= 0 {
		port = discovery.DefaultPort
	}
	s.opts.ScanPort = port
	if s.opts.ScanTTL == 0 {
		s.opts.ScanTTL = discovery.DefaultTTL
	}
	s.discovered = discovery.NewStore(discoveredHostsPath(opts.StateDir))
	s.scan = discovery.NewEngine(s.discovered, discovery.NewHTTPProber(port), s.knownElsewhere)
	s.scan.OnRunComplete(s.tidyDiscovered)
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
