// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Command pool-control-service is the Yuruna pool-control service daemon: a small HTTP service
// that serves the operator UI (board, hosts, pools, scan, diagnostics) and drives
// the pool-intent git store by shelling out to the PowerShell pool-admin CLIs. It
// self-announces to the pool-aggregator service (beacon) so it shows up in the
// Extension hosts table, exactly like the stash service.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
	"yuruna.com/test/extension/extension-sdk/servicecfg"

	"pool-control-service/internal/config"
	"pool-control-service/internal/discovery"
	"pool-control-service/internal/httpsrv"
	"pool-control-service/internal/intent"
	"pool-control-service/internal/state"
	"yuruna.com/test/extension/extension-sdk/beacon"
	"yuruna.com/test/extension/extension-sdk/hostrefresh"
)

var version = "dev"

func main() {
	if err := run(); err != nil {
		os.Exit(1)
	}
}

func run() error {
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
	authTokenFile := flag.String("auth-token-file", config.DefaultAuthTokenFile, "file holding the internal authentication key accepted as a bearer on the mutating routes (empty or missing leaves the dashboard's lab token as the only way in)")
	refreshAuthorityFile := flag.String("refresh-authority-file", config.DefaultRefreshAuthorityFile, "file holding the host refresh signing authority (one yhra1 line, owner-only); missing, malformed or group/world-readable disables remote host refresh")
	refreshCredentialFile := flag.String("refresh-credential-file", config.DefaultRefreshCredentialFile, "file holding the operator refresh credential (one yhrc1 line, owner-only) required in X-Yuruna-Refresh-Credential; missing, malformed or group/world-readable disables remote host refresh")
	autoEnroll := flag.Bool("auto-enroll", false, "enable the auto-enrollment sweep (adds lab-token-ready hosts to the target pool); OFF by default")
	autoEnrollInterval := flag.Duration("auto-enroll-interval", 60*time.Second, "how often the auto-enrollment sweep runs when --auto-enroll is set")
	scanCIDR := flag.String("scan-cidr", "", "network to sweep for Yuruna hosts, in CIDR notation (empty = the /24 around this service's own address)")
	scanPort := flag.Int("scan-port", discovery.DefaultPort, "host status-service port probed on each address during a scan")
	language := flag.String("language", "", "lab-wide lock on the reader's language (a BCP 47 tag); empty or \"auto\" lets each browser's Accept-Language decide")
	allowPseudoLocale := flag.Bool("allow-pseudo-locale", false, "let a request select a pseudo locale (expanded or mirrored text). For a reference run only: a reader who received one would read the page as broken")
	scanInterval := flag.Duration("scan-interval", discovery.DefaultInterval, "how often the discovery sweep runs (0 disables the timer; the Scan page still scans on demand)")
	scanTTL := flag.Duration("scan-ttl", discovery.DefaultTTL, "drop a discovered host from the monitored list this long after its last sighting (negative keeps every host forever); duplicate rows for one address are collapsed after every scan regardless")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC | log.Lmicroseconds)
	if *repoDir == "" {
		log.Fatalf("pool-control-service: --repo-dir is required (the yuruna framework checkout with test/*.ps1)")
	}

	// An unreadable token file is not a startup failure: it only means the bearer
	// route into the gate is unavailable, and an operator can still unlock with
	// the dashboard's lab token.
	authToken := readTokenFile(*authTokenFile)
	refreshAuthority, refreshCredential := readRefreshSecrets(*refreshAuthorityFile, *refreshCredentialFile, authToken)

	runner := &intent.Runner{Pwsh: *pwshPath, RepoDir: *repoDir, IntentGitUrl: *intentGitURL, ConfigPath: *configPath}
	store := state.New(*stateDir, time.Now())
	ui := httpsrv.New(runner, httpsrv.Options{
		Addr: *httpAddr, Version: version, Store: store,
		PwshPath: *pwshPath, RepoDir: *repoDir, StateDir: *stateDir,
		AggregatorURL: *aggregatorURL, HostID: *hostID, IntentGitURL: *intentGitURL,
		AuthToken: authToken, AuthTokenFile: *authTokenFile,
		RefreshAuthority: refreshAuthority, RefreshCredential: refreshCredential, RefreshAuthorityFile: *refreshAuthorityFile,
		ScanCIDR: *scanCIDR, ScanPort: *scanPort, ScanInterval: *scanInterval, ScanTTL: *scanTTL,
		Language: *language, AllowPseudoLocale: *allowPseudoLocale,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() { errCh <- ui.ListenAndServe(ctx) }()

	// Auto-enrollment runs on its OWN ticker, started unconditionally here --
	// deliberately NOT inside the store.Enabled() block below. That block is
	// gated on --state-dir, which the host-side launcher never passes, so a
	// sweep riding it would silently not exist on that deployment.
	go ui.RunAutoEnrollment(ctx, httpsrv.AutoEnrollOptions{
		Enabled:  *autoEnroll,
		Interval: *autoEnrollInterval,
	})

	// Network discovery, on its own ticker for the same reason: the sweep is how
	// a host that registered with nobody becomes visible, and gating it on a NAS
	// would mean the deployment least likely to have one also never looks.
	if *scanInterval > 0 {
		where := *scanCIDR
		if where == "" {
			where = discovery.DefaultCIDR() + " (this service's own network)"
		}
		log.Printf("pool-control-service discovery: sweeping %s every %s, probing port %d", where, *scanInterval, *scanPort)
	} else {
		log.Printf("pool-control-service discovery: sweep disabled (--scan-interval 0); the Scan page still scans on demand")
	}
	go ui.RunDiscovery(ctx, *scanInterval)

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
	var serverErr error
	select {
	case <-ctx.Done():
	case err := <-errCh:
		serverErr = err
		if err != nil {
			log.Printf("pool-control-service: http server error: %v", err)
		}
	}
	stop() // trigger beacon goodbye
	select {
	case <-beaconDone:
	case <-time.After(8 * time.Second):
	}
	return serverErr
}

// readTokenFile loads the internal authentication key; an absent or unreadable
// file leaves bearer auth simply unconfigured rather than failing startup.
func readTokenFile(path string) string {
	token, source, err := servicecfg.ReadAuthToken(path, config.DefaultAuthTokenFile, config.LegacyAuthTokenFile)
	if err != nil {
		log.Printf("pool-control-service: internal auth key file %s unreadable (%v); bearer auth disabled", path, err)
	}
	if source == config.LegacyAuthTokenFile {
		log.Printf("pool-control-service: internal auth key read from %s; rebuild this VM to move it to %s", source, config.DefaultAuthTokenFile)
	}
	return token
}

// readRefreshSecrets loads the refresh signing authority and the operator
// refresh credential, and logs whether remote host refresh is enabled. The
// rules live in httpsrv.LoadRefreshSecrets; the log line names files and tags,
// never secret material.
func readRefreshSecrets(authorityFile, credentialFile, legacyToken string) ([]byte, string) {
	authority, credential, err := httpsrv.LoadRefreshSecrets(authorityFile, credentialFile, legacyToken)
	if err != nil {
		log.Printf("pool-control-service: remote host refresh disabled: %v", err)
		return nil, ""
	}
	log.Printf("pool-control-service: remote host refresh enabled (authority tag %s)", hostrefresh.AuthorityTag(authority))
	return authority, credential
}

// uiPort extracts the port from an addr like "0.0.0.0:80" for the beacon's
// targetPort (0 = no deep-link). The aggregator derives the host from the
// announce source address.
func uiPort(addr string) int { return servicecfg.UIPort(addr) }
