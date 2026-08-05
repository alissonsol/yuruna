// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Command pool-control-service is the Yuruna pool-control service daemon: a small HTTP service
// that serves a 3-page UI (assign test-sets to pools; pools CRUD; test-sets
// CRUD) and drives the pool-intent git store by shelling out to the PowerShell
// pool-admin CLIs. It self-announces to the pool-aggregator service (beacon) so it shows
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
	"strings"
	"syscall"
	"time"

	"pool-control-service/internal/config"
	"pool-control-service/internal/httpsrv"
	"pool-control-service/internal/intent"
	"pool-control-service/internal/state"
	"pool-control-service/internal/yex/beacon"
)

var version = "dev"

func main() {
	httpAddr := flag.String("http-addr", config.DefaultHTTPAddress, "UI/API listen address (empty disables the server)")
	aggregatorURL := flag.String("aggregator-url", "", "pool-aggregator service base URL for the presence beacon (empty disables it)")
	hostID := flag.String("host-id", "", "this host's stable id for the beacon (empty disables it)")
	presenceInterval := flag.Duration("presence-interval", config.DefaultPresenceInterval, "beacon re-announce cadence")
	pwshPath := flag.String("pwsh", "pwsh", "path to the pwsh executable")
	repoDir := flag.String("repo-dir", "", "path to the yuruna framework checkout (the pool-admin CLIs live at <repo-dir>/test/*.ps1) [required]")
	intentGitURL := flag.String("intent-git-url", "", "writable pool-intent git URL forwarded to the CLIs (defaults to test.config.yml's pool.intentGitUrl when empty)")
	stateDir := flag.String("state-dir", "", "directory (under poolStorageNetworkPath/pool-control-service/) for the audit log + status.json; empty disables persistence")
	monitorInterval := flag.Duration("monitor-interval", 60*time.Second, "how often to probe the intent + refresh status.json")
	configPath := flag.String("config-file", "/etc/yuruna/pool-control-service.env", "env file re-read before each intent operation for POOL_CONTROL_INTENT_GIT_URL (empty pins the launch flag)")
	authTokenFile := flag.String("auth-token-file", config.DefaultAuthTokenFile, "file holding the lab auth token accepted as a bearer on the mutating routes (empty or missing leaves the dashboard's lab token as the only way in)")
	autoEnrol := flag.Bool("auto-enrol", false, "enable the auto-enrolment sweep (adds lab-token-ready hosts to the target pool); OFF by default")
	autoEnrolInterval := flag.Duration("auto-enrol-interval", 60*time.Second, "how often the auto-enrolment sweep runs when --auto-enrol is set")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC | log.Lmicroseconds)
	if *repoDir == "" {
		log.Fatalf("pool-control-service: --repo-dir is required (the yuruna framework checkout with test/*.ps1)")
	}

	// An unreadable token file is not a startup failure: it only means the bearer
	// route into the gate is unavailable, and an operator can still unlock with
	// the dashboard's lab token.
	authToken := readTokenFile(*authTokenFile)

	runner := &intent.Runner{Pwsh: *pwshPath, RepoDir: *repoDir, IntentGitUrl: *intentGitURL, ConfigPath: *configPath}
	store := state.New(*stateDir, time.Now())
	ui := httpsrv.New(runner, httpsrv.Options{
		Addr: *httpAddr, Version: version, Store: store,
		PwshPath: *pwshPath, RepoDir: *repoDir, StateDir: *stateDir,
		AggregatorURL: *aggregatorURL, HostID: *hostID, IntentGitURL: *intentGitURL,
		AuthToken: authToken, AuthTokenFile: *authTokenFile,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() { errCh <- ui.ListenAndServe(ctx) }()

	// Auto-enrolment runs on its OWN ticker, started unconditionally here --
	// deliberately NOT inside the store.Enabled() block below. That block is
	// gated on --state-dir, which the host-side launcher never passes, so a
	// sweep riding it would silently not exist on that deployment.
	go ui.RunAutoEnrolment(ctx, httpsrv.AutoEnrolOptions{
		Enabled:  *autoEnrol,
		Interval: *autoEnrolInterval,
	})

	// Continuous monitor: probe the intent store and refresh status.json (the
	// heartbeat + intent-readable flag) under poolStorageNetworkPath so an operator (or a
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

	log.Printf("pool-control-service %s: http=%q aggregator=%q area=%s", version, *httpAddr, *aggregatorURL, config.PresenceArea)
	select {
	case <-ctx.Done():
	case err := <-errCh:
		if err != nil {
			log.Printf("pool-control-service: http server error: %v", err)
		}
	}
	stop() // trigger beacon goodbye
	select {
	case <-beaconDone:
	case <-time.After(8 * time.Second):
	}
}

// readTokenFile loads the lab auth token; an absent or unreadable file leaves
// bearer auth simply unconfigured rather than failing startup.
func readTokenFile(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		log.Printf("pool-control-service: auth token file %s unreadable (%v); bearer auth disabled", path, err)
		return ""
	}
	return strings.TrimSpace(string(b))
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
