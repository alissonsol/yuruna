// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package httpsrv serves the browser UI and JSON API for the Stash Service
// (stash-service-ui.md). It runs as a second listener inside the same Go
// daemon as the SCP/SFTP sink (§2.1), sharing the ID allocator, storage
// pipeline, and local index. It presents a POOL-WIDE view (§3): this host's
// live local index merged with every other host's on-share sidecars. Writes
// (create) go through the shared ingest pipeline; delete is local-host-only
// and enforced server-side (§8).
package httpsrv

import (
	"context"
	"errors"
	"net"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"stash-server/internal/config"
	"stash-server/internal/detect"
	"stash-server/internal/meta"
	"stash-server/internal/sshsrv"
	"stash-server/internal/store"
)

// Server is the UI/API HTTP server.
type Server struct {
	ssh           *sshsrv.Server
	stashRoot     string // parent of the share folder = <mount>/stash
	localHostID   string // base of the share folder = this host's hostId
	pool          *PoolIndex
	aggregatorURL string
	httpClient    *http.Client
	resolver      *hostResolver
	defaultLimit  int
	version       string
	listener      *http.Server
	deleteHostIPs []net.IP // host IPs permitted to DELETE; nil = VM-only
}

// Options carries the VM-side configurable knobs (stash-service-ui.md §11).
// Zero values fall back to the spec defaults.
type Options struct {
	Addr           string
	AggregatorURL  string
	PoolWindowDays int
	PoolRefresh    time.Duration
	DefaultLimit   int
	Version        string
	// HostIP is the deploying host's IP address (the --host-ip launch flag):
	// the one non-VM source permitted to DELETE stashes. Reads and
	// writes stay open to any host. A comma-separated list is accepted; empty
	// means only the VM itself may delete.
	HostIP string
}

// New builds the UI server. stashRoot and localHostID are derived from the
// daemon's share folder (<mount>/stash/<hostId>): the parent holds every
// host's stash, the base is this host's id. aggregatorURL is the optional
// pool-aggregator base for hostId→stash-URL resolution (§3.4); empty
// disables it (best-effort, never a hard dependency).
func New(sshServer *sshsrv.Server, opts Options) *Server {
	shareFolder := sshServer.Store.Folder
	stashRoot := filepath.Dir(shareFolder)
	localHostID := filepath.Base(shareFolder)
	defaultLimit := opts.DefaultLimit
	if defaultLimit <= 0 {
		defaultLimit = config.DefaultListLimit
	}
	s := &Server{
		ssh:           sshServer,
		stashRoot:     stashRoot,
		localHostID:   localHostID,
		pool:          NewPoolIndex(stashRoot, localHostID, opts.PoolWindowDays, opts.PoolRefresh),
		aggregatorURL: strings.TrimRight(opts.AggregatorURL, "/"),
		httpClient:    &http.Client{Timeout: 4 * time.Second},
		resolver:      newHostResolver(),
		defaultLimit:  defaultLimit,
		version:       opts.Version,
		deleteHostIPs: parseHostIPs(opts.HostIP),
	}
	s.listener = &http.Server{
		Addr:    opts.Addr,
		Handler: s.routes(),
		// Slowloris / header-dribble defense. ReadTimeout and WriteTimeout
		// are deliberately left unset so large artifact up/downloads (up to
		// the 100 MB per-file cap) are not severed mid-stream on a slow LAN;
		// the body size is bounded separately by MaxBytesReader + the per-
		// file cap (handlers.go / ingest.go).
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	return s
}

func (s *Server) meta() *meta.Store         { return s.ssh.Meta }
func (s *Server) store() *store.Store       { return s.ssh.Store }
func (s *Server) buffer() *store.Store      { return s.ssh.Buffer }
func (s *Server) detector() detect.Detector { return s.ssh.Detector }

// ListenAndServe runs the HTTP server until ctx is cancelled, and kicks off
// the pool-index background refresher (§3.2). Returns nil on graceful
// shutdown.
func (s *Server) ListenAndServe(ctx context.Context) error {
	go s.pool.RunRefresher(ctx)
	go func() {
		<-ctx.Done()
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.listener.Shutdown(shutCtx)
	}()
	if err := s.listener.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// StashView is the JSON shape the UI consumes for a list row or the detail
// view. It is built from a local meta.Record or a remote sidecar; hostId
// and Local distinguish the two (§3.3).
type StashView struct {
	ID               string     `json:"id"`
	HostID           string     `json:"hostId"`
	Local            bool       `json:"local"`
	OriginalFilename string     `json:"originalFilename"`
	IsArchive        bool       `json:"isArchive"`
	Username         string     `json:"username"`
	PathMetadata     string     `json:"pathMetadata"`
	ClientAddress    string     `json:"clientAddress"`
	CreatedAt        time.Time  `json:"createdAt"`
	ReceivedAt       *time.Time `json:"receivedAt,omitempty"`
	Status           string     `json:"status"`
	SizeBytes        int64      `json:"sizeBytes"`
	LocallyBuffered  bool       `json:"locallyBuffered"`
	MimeType         string     `json:"mimeType"`
	ContentClass     string     `json:"contentClass"`
	IsText           bool       `json:"isText"`
	TypeLabel        string     `json:"typeLabel,omitempty"`
	TypeScore        float64    `json:"typeScore,omitempty"`
	Source           string     `json:"source"`
	Permalink        string     `json:"permalink"`
	// RemoteStashURL is the absolute deep-link to the OWNING host's stash UI
	// for a remote stash (§8.3), resolved best-effort via the pool-aggregator
	// (§3.4). Empty for local stashes or when resolution is unavailable. Set
	// only on the single-stash detail response, not in list rows (which would
	// fan out one aggregator call per row).
	RemoteStashURL string `json:"remoteStashUrl,omitempty"`
}

// viewFromRecord builds a StashView from a record owned by hostID.
func (s *Server) viewFromRecord(r *meta.Record, hostID string) StashView {
	y, mo, d := r.CreatedAt.UTC().Date()
	return StashView{
		ID:               r.ID,
		HostID:           hostID,
		Local:            hostID == s.localHostID,
		OriginalFilename: r.OriginalFilename,
		IsArchive:        r.IsArchive,
		Username:         r.Username,
		PathMetadata:     r.PathMetadata,
		ClientAddress:    r.ClientAddress,
		CreatedAt:        r.CreatedAt.UTC(),
		ReceivedAt:       r.ReceivedAt,
		Status:           r.Status,
		SizeBytes:        r.SizeBytes,
		LocallyBuffered:  r.LocallyBuffered,
		MimeType:         r.MimeType,
		ContentClass:     r.ContentClass,
		IsText:           r.IsText,
		TypeLabel:        r.TypeLabel,
		TypeScore:        r.TypeScore,
		Source:           r.Source,
		Permalink:        permalink(hostID, y, int(mo), d, r.ID),
	}
}

func permalink(hostID string, y, m, d int, id string) string {
	return "/s/" + hostID + "/" + pad4(y) + "/" + pad2(m) + "/" + pad2(d) + "/" + id
}

func pad2(n int) string {
	if n < 10 {
		return "0" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

func pad4(n int) string {
	s := strconv.Itoa(n)
	for len(s) < 4 {
		s = "0" + s
	}
	return s
}
