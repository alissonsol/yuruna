// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Command download-agent-service is the Yuruna download-agent daemon: it holds
// guest images in a shared Download pool on the pool share, serves them to every
// host's Get-Image.ps1 over HTTP, deduplicates concurrent requests, re-verifies
// entries against their origin before they go stale, and ships a web UI for
// inspecting and managing the pool. It self-announces to the pool-aggregator
// service (beacon) so it shows up in the Extension hosts table, exactly like the
// stash and pool-control services.
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

	"download-agent-service/internal/config"
	"download-agent-service/internal/httpsrv"
	"download-agent-service/internal/imagestore"
	"download-agent-service/internal/state"
	"download-agent-service/internal/yex/beacon"
)

var version = "dev"

func main() {
	httpAddr := flag.String("http-addr", config.DefaultHTTPAddress, "UI/API listen address (empty disables the server)")
	aggregatorURL := flag.String("aggregator-url", "", "pool-aggregator service base URL for the presence beacon, the auto-seed roster and the UI's lab-token unlock (empty disables all three)")
	hostID := flag.String("host-id", "", "this host's stable id for the beacon and the pool lease (empty disables the beacon)")
	presenceInterval := flag.Duration("presence-interval", config.DefaultPresenceInterval, "beacon re-announce cadence")
	authTokenFile := flag.String("auth-token-file", config.DefaultAuthTokenFile, "file holding the lab auth token accepted as a bearer on the gated routes (empty or missing disables bearer auth)")
	poolDir := flag.String("pool-dir", config.DefaultPoolDir, "pool share mount point; the Download pool lives under <pool-dir>/images")
	stateDir := flag.String("state-dir", "", "directory (under the pool share) for audit.jsonl + status.json; empty disables persistence")
	scanInterval := flag.Duration("scan-interval", config.DefaultScanInterval, "background pool scan cadence")
	freshness := flag.Duration("freshness", config.DefaultFreshness, "how long an image stays fresh after its last origin verification")
	prefetchLead := flag.Duration("prefetch-lead", config.DefaultPrefetchLead, "act on images expiring within this window")
	autoSeed := flag.Bool("auto-seed", true, "pre-download the stable families for the host types the aggregator reports")
	proxyHTTP := flag.String("proxy-http", "", "caching proxy for plain-HTTP byte downloads, e.g. http://<cache>:3128 (empty fetches direct)")
	proxyHTTPS := flag.String("proxy-https", "", "caching proxy ssl-bump port for HTTPS byte downloads, e.g. http://<cache>:3129 (empty fetches direct)")
	proxyCA := flag.String("proxy-ca", "", "PEM file holding the caching proxy's CA, required to trust its ssl-bump port")
	fidoScript := flag.String("fido-script", "", "path to the vendored, hash-pinned Fido.ps1 that mints the Windows 11 download URL (empty searches the standard install locations; nothing found leaves that family unavailable)")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC | log.Lmicroseconds)

	// An unreadable token file is not a startup failure: it only means the
	// bearer route into the gate is unavailable, and an operator can still
	// unlock with the dashboard's lab token. Every empty flag self-disables its
	// feature.
	authToken := readTokenFile(*authTokenFile)

	store := state.New(*stateDir, time.Now())

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	agent, err := imagestore.NewAgent(ctx, imagestore.Options{
		PoolDir:       *poolDir,
		ScanInterval:  *scanInterval,
		Freshness:     *freshness,
		PrefetchLead:  *prefetchLead,
		AutoSeed:      *autoSeed,
		AggregatorURL: *aggregatorURL,
		HostID:        *hostID,
		VMName:        "yuruna-" + config.PresenceArea,
		AgentVersion:  version,
		ProxyHTTP:     *proxyHTTP,
		ProxyHTTPS:    *proxyHTTPS,
		ProxyCA:       *proxyCA,
		Fido:          imagestore.FidoConfig{Script: *fidoScript},
		Audit: func(e imagestore.AuditEvent) {
			store.Record(time.Now(), state.AuditEntry{
				AtUTC: e.AtUTC, Action: e.Action,
				HostType: e.HostType, ImageKey: e.ImageKey, Arch: e.Arch, Variant: e.Variant,
				Outcome: e.Outcome, Detail: e.Detail,
			})
		},
		Logf: log.Printf,
	})
	if err != nil {
		log.Fatalf("download-agent-service: image store: %v", err)
	}

	ui := httpsrv.New(httpsrv.Options{
		Addr: *httpAddr, Version: version, Store: store, Images: agent,
		AuthToken:     authToken,
		AggregatorURL: *aggregatorURL, HostID: *hostID,
		PoolDir: *poolDir, StateDir: *stateDir,
	})

	errCh := make(chan error, 1)
	go func() { errCh <- ui.ListenAndServe(ctx) }()

	// The scanner owns staging hygiene, the lease, auto-seed and the freshness
	// pass. It runs unconditionally: unlike the state store it has no --state-dir
	// gate, because a pool with no persistence still needs its images kept fresh.
	// Its done channel is load-bearing: Run releases the single-writer lease on
	// its way out, and exiting without waiting for it leaves a stale lease that
	// holds every other agent read-only for three scan intervals.
	agentDone := make(chan struct{})
	go func() { agent.Run(ctx); close(agentDone) }()

	if store.Enabled() {
		go func() {
			tick := time.NewTicker(time.Minute)
			defer tick.Stop()
			beat := func() { store.Beat(time.Now(), agent.PoolAvailable()) }
			beat()
			for {
				select {
				case <-ctx.Done():
					return
				case <-tick.C:
					beat()
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

	log.Printf("download-agent-service %s: http=%q pool=%q aggregator=%q area=%s scan=%s freshness=%s lead=%s autoSeed=%t",
		version, *httpAddr, *poolDir, *aggregatorURL, config.PresenceArea, *scanInterval, *freshness, *prefetchLead, *autoSeed)
	select {
	case <-ctx.Done():
	case err := <-errCh:
		if err != nil {
			log.Printf("download-agent-service: http server error: %v", err)
		}
	}
	stop() // trigger the beacon goodbye and the lease release
	waitBounded(shutdownGrace, agentDone, beaconDone)
}

// shutdownGrace bounds the whole shutdown wait. A hung NAS must not keep the
// process alive indefinitely, but a lease release worth having needs more than
// an instant.
const shutdownGrace = 8 * time.Second

// waitBounded waits for every channel, sharing one deadline across all of them
// so a slow first waiter cannot grant the rest a fresh budget each.
func waitBounded(grace time.Duration, chans ...chan struct{}) {
	deadline := time.Now().Add(grace)
	for _, ch := range chans {
		timer := time.NewTimer(time.Until(deadline))
		select {
		case <-ch:
		case <-timer.C:
		}
		timer.Stop()
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
		log.Printf("download-agent-service: auth token file %s unreadable (%v); bearer auth disabled", path, err)
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
