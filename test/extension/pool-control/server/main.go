// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Command pool-control is the Yuruna Pool control daemon: a small HTTP service
// that serves a 3-page UI (assign test-sets to pools; pools CRUD; test-sets
// CRUD) and drives the pool-intent git store by shelling out to the PowerShell
// pool-admin CLIs. It self-announces to the pool aggregator (beacon) so it shows
// up in the Extension hosts table, exactly like the stash service.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"pool-control/internal/beacon"
	"pool-control/internal/config"
	"pool-control/internal/httpsrv"
	"pool-control/internal/intent"
	"pool-control/internal/state"
)

var version = "dev"

func main() {
	httpAddr := flag.String("http-addr", config.DefaultHTTPAddress, "UI/API listen address (empty disables the server)")
	aggregatorURL := flag.String("aggregator-url", "", "pool aggregator base URL for the presence beacon (empty disables it)")
	hostID := flag.String("host-id", "", "this host's stable id for the beacon (empty disables it)")
	presenceInterval := flag.Duration("presence-interval", config.DefaultPresenceInterval, "beacon re-announce cadence")
	pwshPath := flag.String("pwsh", "pwsh", "path to the pwsh executable")
	repoDir := flag.String("repo-dir", "", "path to the yuruna framework checkout (the pool-admin CLIs live at <repo-dir>/test/*.ps1) [required]")
	intentGitURL := flag.String("intent-git-url", "", "writable pool-intent git URL forwarded to the CLIs (defaults to test.config.yml's pool.intentGitUrl when empty)")
	stateDir := flag.String("state-dir", "", "directory (under poolNetworkPath/pool-control/) for the audit log + status.json; empty disables persistence")
	monitorInterval := flag.Duration("monitor-interval", 60*time.Second, "how often to probe the intent + refresh status.json")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC | log.Lmicroseconds)
	if *repoDir == "" {
		log.Fatalf("pool-control: --repo-dir is required (the yuruna framework checkout with test/*.ps1)")
	}

	runner := &intent.Runner{Pwsh: *pwshPath, RepoDir: *repoDir, IntentGitUrl: *intentGitURL}
	store := state.New(*stateDir, time.Now())
	ui := httpsrv.New(runner, httpsrv.Options{Addr: *httpAddr, Version: version, Store: store})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() { errCh <- ui.ListenAndServe(ctx) }()

	// Continuous monitor: probe the intent store and refresh status.json (the
	// heartbeat + intent-readable flag) under poolNetworkPath so an operator (or a
	// health check) can see the service is alive and the intent is reachable.
	if store.Enabled() {
		go func() {
			tick := time.NewTicker(*monitorInterval)
			defer tick.Stop()
			probe := func() { store.Beat(time.Now(), runner.State(ctx).OK) }
			probe()
			for {
				select {
				case <-ctx.Done():
					return
				case <-tick.C:
					probe()
				}
			}
		}()
	}

	bcn := beacon.New(*aggregatorURL, *hostID, config.PresenceArea, uiPort(*httpAddr), *presenceInterval)
	beaconDone := make(chan struct{})
	if bcn.Enabled() {
		go func() { bcn.Run(ctx); close(beaconDone) }()
	} else {
		close(beaconDone)
	}

	log.Printf("pool-control %s: http=%q aggregator=%q area=%s", version, *httpAddr, *aggregatorURL, config.PresenceArea)
	select {
	case <-ctx.Done():
	case err := <-errCh:
		if err != nil {
			log.Printf("pool-control: http server error: %v", err)
		}
	}
	stop() // trigger beacon goodbye
	select {
	case <-beaconDone:
	case <-time.After(8 * time.Second):
	}
}

// uiPort extracts the port from an addr like "0.0.0.0:80" for the beacon's
// targetPort (0 = no deep-link). The aggregator derives the host from the
// announce source address.
func uiPort(addr string) int {
	_, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return 0
	}
	p, err := strconv.Atoi(portStr)
	if err != nil {
		return 0
	}
	return p
}
