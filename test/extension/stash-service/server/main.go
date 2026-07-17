// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Yuruna Stash Service daemon. Spec: https://yuruna.link/stash-service.
//
// Single binary, single listener on TCP/22. In production the daemon is
// supervised by a systemd unit (Restart=on-failure) installed during
// bring-up (§4.6); it can also be launched directly for local runs.
// Operational logs go to stderr, which journald captures under systemd.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"stash-server/internal/beacon"
	"stash-server/internal/config"
	"stash-server/internal/httpsrv"
	"stash-server/internal/id"
	"stash-server/internal/meta"
	"stash-server/internal/sshsrv"
	"stash-server/internal/store"
)

// version is the framework version shown in the UI header. The bring-up
// build stamps it from the repo VERSION file via
// -ldflags "-X main.version=<v>"; ad-hoc dev builds keep "dev".
var version = "dev"

func main() {
	shareFolder := flag.String("share-folder", "", "share-side StashFolder on the mounted stash share, e.g. <localPath>/stash/<hostId> (holds hostkey/ + files/) (§6.1) — required")
	metadataDir := flag.String("metadata-dir", config.DefaultMetadataDir, "VM-local metadata index directory (§8)")
	bufferDir := flag.String("buffer-dir", config.DefaultBufferDir, "VM-local NAS-offline buffer directory (§8.4)")
	listenAddr := flag.String("listen-addr", config.ListenAddress, "SCP/SFTP sink listen address (§4.2); override only for dev when :22 is taken by the OS sshd")
	httpAddr := flag.String("http-addr", config.DefaultHTTPAddress, "UI/API HTTP listen address (stash-service-ui.md §2); empty disables the UI")
	poolWindowDays := flag.Int("pool-window-days", config.DefaultPoolWindowDays, "days of cross-host sidecars the pool index holds in memory (stash-service-ui.md §3.2)")
	poolRefreshSecs := flag.Int("pool-refresh-secs", 60, "pool-index rescan interval in seconds (stash-service-ui.md §11)")
	listLimit := flag.Int("list-default-limit", config.DefaultListLimit, "default page size for the recent-stash list (stash-service-ui.md §11)")
	aggregatorURL := flag.String("aggregator-url", "", "pool-aggregator base URL for hostId→stash-UI resolution (stash-service-ui.md §3.4) and the presence beacon (§4.7); empty disables both (best-effort)")
	hostID := flag.String("host-id", "", "owning HOST's hostId (the pool-table identity) the presence beacon announces under (§4.7); empty disables the beacon")
	hostIP := flag.String("host-ip", "", "the deploying host's IP address: the one non-VM source permitted to DELETE stashes. Reads and writes stay open to any host. Comma-separated list accepted; empty = only this VM may delete")
	presenceInterval := flag.Duration("presence-interval", config.DefaultPresenceInterval, "presence re-announce period to the pool-aggregator (§4.7); 0 disables the beacon")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC | log.Lmicroseconds)

	if *shareFolder == "" {
		log.Fatalf("--share-folder is required (the daemon writes to the mounted stash share; see https://yuruna.link/stash-service §6.1)")
	}
	log.Printf("stash-server starting; share=%s metadata=%s buffer=%s", *shareFolder, *metadataDir, *bufferDir)

	st, err := store.New(*shareFolder)
	if err != nil {
		log.Fatalf("store.New: %v", err)
	}
	// The share may be offline at startup (e.g. the cifs mount failed). That
	// is NOT fatal — the daemon buffers locally and flushes when the share
	// returns (§8.4). Surface it loudly so an operator isn't left guessing
	// when uploads are buffering instead of landing on the NAS.
	if !store.ShareOnline(*shareFolder) {
		log.Printf("WARNING: share %s is not a writable network mount; buffering locally until it returns (§8.4)", *shareFolder)
	}

	// VM-local dirs: the metadata index and the offline buffer never live
	// on the share (§6.1, §8). The buffer mirrors the share's files/ layout
	// (NewFilesOnly) so a flush is a same-relative-path copy (§8.4).
	if err := os.MkdirAll(*metadataDir, 0o700); err != nil {
		log.Fatalf("metadata dir: %v", err)
	}
	buf, err := store.NewFilesOnly(*bufferDir)
	if err != nil {
		log.Fatalf("buffer store: %v", err)
	}

	m, err := meta.Open(filepath.Join(*metadataDir, config.DatabaseFileName))
	if err != nil {
		log.Fatalf("meta.Open: %v", err)
	}
	defer m.Close()

	// §8.5: on a fresh VM (e.g. after a reimage) the VM-local index is
	// empty — rebuild it from the durable on-share sidecars so prior
	// uploads remain searchable. A normal restart finds a populated index
	// and skips the (potentially large) share scan.
	if n, cerr := m.Count(); cerr != nil {
		log.Printf("index count: %v", cerr)
	} else if n == 0 {
		if rebuilt, rerr := m.RebuildFromSidecars(st.FilesRoot()); rerr != nil {
			log.Printf("rebuild from sidecars: %v", rerr)
		} else if rebuilt > 0 {
			log.Printf("rebuilt %d metadata record(s) from on-share sidecars", rebuilt)
		}
	}

	// Seed the allocator from BOTH the share and the buffer so a restart
	// mid-outage cannot reissue an ID a not-yet-flushed buffered artifact
	// already claims (§7, §8.4).
	ids := id.New(st.FilesRoot(), buf.FilesRoot())

	srv, err := sshsrv.New(st, buf, m, ids)
	if err != nil {
		log.Fatalf("sshsrv.New: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// Drain the offline buffer in the background (and on startup, covering
	// a restart after the outage ended) (§8.4).
	go srv.RunFlushWorker(ctx)

	// Two listeners in one process (stash-service-ui.md §2.1): the SCP/SFTP
	// sink on :22 and the UI/API HTTP server (default :80). Both stop on ctx
	// cancel and return nil; a real bind/serve failure on either is fatal.
	// Each goroutine sends exactly one result to errCh when its
	// ListenAndServe returns; listeners counts how many were started so the
	// shutdown drain below reads every pending send.
	listeners := 1
	errCh := make(chan error, 2)
	go func() { errCh <- srv.ListenAndServe(ctx, *listenAddr) }()
	if *httpAddr != "" {
		ui := httpsrv.New(srv, httpsrv.Options{
			Addr:           *httpAddr,
			AggregatorURL:  *aggregatorURL,
			PoolWindowDays: *poolWindowDays,
			PoolRefresh:    time.Duration(*poolRefreshSecs) * time.Second,
			DefaultLimit:   *listLimit,
			Version:        version,
			HostIP:         *hostIP,
		})
		log.Printf("stash-server UI on %s (pool window %dd, refresh %ds, aggregator=%q)", *httpAddr, *poolWindowDays, *poolRefreshSecs, *aggregatorURL)
		if *hostIP != "" {
			log.Printf("stash-server delete authz: VM-local + host IP(s) %q may DELETE; reads/writes stay open", *hostIP)
		} else {
			log.Printf("stash-server delete authz: VM-local only may DELETE (no --host-ip); reads/writes stay open")
		}
		listeners++
		go func() { errCh <- ui.ListenAndServe(ctx) }()
	} else {
		log.Printf("stash-server UI disabled (--http-addr empty)")
	}

	// Presence beacon (§4.7): self-announce to the pool-aggregator on boot,
	// every --presence-interval, and (best-effort) at shutdown, so the
	// dashboard's Extension hosts row exists WITHOUT the owning host's status
	// server. The announce carries only the UI PORT; the aggregator derives the
	// service URL from the connection's source address, so the daemon never has
	// to know its own IP.
	bcn := beacon.New(*aggregatorURL, *hostID, config.PresenceArea, uiPort(*httpAddr), *presenceInterval)
	beaconDone := make(chan struct{})
	if bcn.Enabled() {
		log.Printf("presence beacon: %s/%s -> %s every %s", bcn.HostID, bcn.Area, bcn.AggregatorURL, bcn.Interval)
		go func() { bcn.Run(ctx); close(beaconDone) }()
	} else {
		log.Printf("presence beacon disabled (needs --aggregator-url, --host-id, and --presence-interval > 0)")
		close(beaconDone)
	}

	// Block until the OS signals shutdown (ctx.Done) or a listener returns
	// early. pending tracks how many listener results still owe a send to
	// errCh so the drain below can surface every one; the select consumes at
	// most one, so decrement only in the errCh case.
	pending := listeners
	select {
	case <-ctx.Done():
	case err := <-errCh:
		pending--
		if err != nil {
			log.Fatalf("listen: %v", err)
		}
	}
	// Either a listener returned nil on its own or the signal fired: cancel so
	// every remaining listener observes it and returns (idempotent when the
	// signal already cancelled ctx), which guarantees the drain below cannot
	// block waiting on a still-serving listener.
	cancel()

	// Graceful shutdown: drain in-flight SCP/SFTP handlers -- an active
	// finalize/commit -- before the deferred m.Close() tears down the meta DB
	// the commit path writes to. Explicit (not deferred) so it runs before
	// that already-registered defer.
	if cerr := srv.Close(); cerr != nil {
		log.Printf("sshsrv close: %v", cerr)
	}

	// Drain the remaining listener results before exit. A non-nil error here
	// is a bind/serve failure that surfaced as the listeners wound down; log
	// it so it reaches journald instead of being dropped. It is not fatal:
	// this is an intentional, signal-initiated teardown, so completing the
	// graceful close (including the deferred m.Close) beats aborting via
	// log.Fatalf, which the errCh channel buffer (cap 2) lets us do without
	// the senders having blocked.
	for i := 0; i < pending; i++ {
		if err := <-errCh; err != nil {
			log.Printf("listen (shutdown): %v", err)
		}
	}
	// Give the beacon's bounded goodbye announce its window so a deliberate
	// stop drops the dashboard row immediately instead of aging out; the
	// timeout backstops a hung network (the goodbye itself is best-effort).
	select {
	case <-beaconDone:
	case <-time.After(8 * time.Second):
	}
	log.Printf("stash-server stopped")
}

// uiPort extracts the port from an --http-addr value like "0.0.0.0:80" for
// the presence announce's targetPort. 0 (no port to advertise) for an empty
// or unparseable address -- the beacon still announces presence; the row just
// carries no service link.
func uiPort(httpAddr string) int {
	if httpAddr == "" {
		return 0
	}
	_, portStr, err := net.SplitHostPort(httpAddr)
	if err != nil {
		return 0
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		return 0
	}
	return port
}
