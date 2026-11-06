// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428f33a8-3f41-4398-a845-e3d0d598baf0

// pool-aggregator-service: read-only multi-host pool view for the Yuruna test harness.
// See ../../../docs/pool-admin.md#architecture for the auto-discovery and
// identification design, and README.md in this directory for the full detail.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"yuruna.com/test/extension/extension-sdk/servicecfg"

	"yuruna.com/test/extension/extension-sdk/controlproof"
	"yuruna.com/test/extension/pool-aggregator-service/internal/feed"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/httpserve"
	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
	"yuruna.com/test/extension/pool-aggregator-service/internal/localization"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
	"yuruna.com/test/extension/pool-aggregator-service/internal/rehydrate"
	"yuruna.com/test/extension/pool-aggregator-service/internal/routes"
)

const (
	defaultListenAddr = ":9400"
	defaultSquidLog   = "/var/log/squid/yuruna_access.log"
	defaultLokiURL    = "http://127.0.0.1:3100/loki/api/v1/push"
	defaultPool       = "default"
	defaultStatusPort = 8080
	defaultInterval   = 30 * time.Second
	defaultHostTtl    = 24 * time.Hour     // keep a hostId in the view this long after last contact
	defaultRehydrate  = 7 * 24 * time.Hour // restore cycle counts from Loki on startup over this trailing window
	probeTimeout      = hostpoll.ProbeTimeout
	pushTimeout       = loki.RequestTimeout
	// lokiReadyWait bounds the startup wait for Loki's /ready, and then the
	// delivery of what an earlier run left queued, before the startup reads run
	// regardless.
	lokiReadyWait = 2 * time.Minute
	// defaultLokiOutboxDir lies in the unit's StateDirectory, the one writable
	// path the hardened unit leaves this daemon.
	defaultLokiOutboxDir = "/var/lib/pool-aggregator-service/loki-outbox"
	// poolStatsCacheTTL bounds how often /api/v1/pool-stats actually hits Loki.
	// Sized against the board's 30s auto-refresh: several phones refreshing
	// together collapse onto one query, and terminal cycle counts move far more
	// slowly than this anyway.
	poolStatsCacheTTL = 30 * time.Second
	// How long the per-cycle dedup set (seen/seenAt/counted, keyed hostId|cycleStartUtc)
	// is kept past the host row it belongs to. A host that is reaped and then
	// re-appears -- a reboot, a flapping probe -- would otherwise re-report a
	// terminal cycle it was already counted for. Derived from the configured host
	// TTL rather than set independently: two free-standing knobs can be ordered
	// the wrong way round, and dedup state expiring FIRST is what allows the
	// double count. This does not bound the cumulative pass/fail counters; those
	// are cleared only by forgetHost.
	seenTtlGrace = 1 * time.Hour
	// Floor for the deep-link lookback below. The host TTL doubles as the Loki
	// window that resolves a dashboard link for a host no longer in the live
	// view; letting a short TTL shorten that too would 404 links the dashboard
	// still shows in its own default range, including the /go/host redirect
	// that mints a control proof.
	minDeepLinkLookback = 24 * time.Hour
	defaultIncidentN    = 3                // failed cycles within the window to open an incident
	defaultIncidentWin  = 2 * time.Hour    // trailing window for the N-failures-in-M-minutes rule
	defaultCrossN       = 3                // distinct hosts failing within crossWin to open a pool-wide incident
	defaultCrossWin     = 15 * time.Minute // window for cross-host "failing together" correlation
	// Extension-presence announce (POST /announce): a service VM self-reports the
	// extension it runs. The TTL is a reaping horizon many beacon periods long:
	// refusal after extensions.HealthGrace, not reaping, stops an unreachable
	// address being handed out.
	// See https://yuruna.link/42c29d04-0010.
	defaultAnnounceTtl = 45 * time.Minute
	// Routes the PowerShell side of this area calls by name. Its client
	// (default.psm1, Get-PoolAggregatorServiceManifest's Endpoints map) carries
	// the same five literals, and the two sides are wired independently: a
	// rename here answers 404 to a host that is asking the right question, and
	// nothing fails until a cycle cannot find the service it needs. Named
	// constants so the rename has one place to start, pinned on both sides --
	// the shape the control-proof vectors already use. Change one and
	// route_names_test.go plus Test.ExtensionArea.Tests.ps1 both fail.
	routeHealth         = "/healthz"
	routeMetrics        = "/metrics"
	routePoolStatus     = "/api/v1/pool-status"
	routePoolIncidents  = "/api/v1/pool-incidents"
	routePoolHealth     = "/api/v1/pool-health"
	routePoolCycleLinks = "/api/v1/cycle-links"
	routeExtensionHosts = "/api/v1/extension-hosts"
	routeLabToken       = "/api/v1/lab-token"
	routeFrameworkRing  = "/api/v1/framework-ring"
	// The Prometheus scrape document for the pool's machine-metrics exporters.
	// Deliberately absent from default.psm1's Endpoints map: no PowerShell
	// caller asks for it, and the cross-language route test pins that map
	// one-for-one against the constants listed there.
	routePromTargets = "/api/v1/prometheus-targets"
	// The key file the provisioned unit names on -auth-token-file. Matching this
	// path exactly is what licenses the legacy fallback: an operator who named some
	// other path meant that path, and quietly reading a different file would hand
	// this proxy a token they never pointed it at.
	defaultAuthTokenFile = "/etc/yuruna/internal-auth.key"
	// The key file path a proxy built under the older layout still carries. Read
	// only when the default path is absent, so such a VM keeps minting control
	// proofs, serving /ingest and displaying a Lab token until it is rebuilt --
	// the same fallback the download-agent and pool-control services apply.
	legacyAuthTokenFile = "/etc/yuruna/lab-auth.token"
	// Lab connection token: the 6-char enrollment code the dashboard's "Lab
	// token" tile displays and POST /api/v1/lab-token exchanges for the shared
	// internal authentication key (so enrolling a host never needs SSH into the proxy).
	defaultLabRotate        = 60 * time.Second
	refreshObservationFloor = poolstate.RefreshObservationFloor
	// Port a Windows pool host publishes machine metrics on: the Windows
	// exporter's registered default. One number for the whole pool, because the
	// collector and the hosts share no channel to negotiate it on;
	// -host-metrics-port moves it when a pool has to use another.
	defaultHostMetricsPort = 9182
)

// The host wire types and reads live in internal/hostpoll; these names keep the
// pool-state code that merges them readable.
type (
	hostStatus    = hostpoll.HostStatus
	gitCommitRef  = hostpoll.GitCommitRef
	gitCommitRefs = hostpoll.GitCommitRefs
	cycleVerdict  = hostpoll.CycleVerdict
)

// The incident rules and their records live in internal/incident; these names
// keep the pool-state code that owns the records readable.
type (
	failRec       = incident.FailRec
	incidentState = incident.HostIncident
	incidentEvent = incident.Event
)

// The collector's packages hold the poll, the routes, the restore, the Loki
// lines and the extension merge; these names keep the code that stays in this
// package readable.
type (
	lokiStreamsResult = loki.Streams
	lokiVectorResult  = loki.Vector
)

const eventsFile = feed.EventsFile

var (
	operatorMessage        = localization.OperatorMessage
	localizedHTTPError     = localization.HTTPError
	newInternalHTTPClient  = hostpoll.NewInternalHTTPClient
	queryRangeURL          = loki.QueryRangeURL
	cycleTransitionPayload = feed.CycleTransitionPayload
	redactEventLine        = feed.RedactEventLine
	validForgetHostID      = routes.ValidForgetHostID
	poolStatsRanges        = routes.PoolStatsRanges
	cycleStartFromFolder   = routes.CycleStartFromFolder
	hostIDRe               = routes.HostIDRe
	archiveCycleRe         = routes.ArchiveCycleRe
	dashedHostID           = poolstate.DashedHostID
)

// poolState is the collector: its configuration, set once in main before the
// server starts, the pool view it keeps under one lock (st), and the state only
// the poll goroutine touches.
type poolState struct {
	// st owns the pool view and its lock: hosts, cycle counters, incidents,
	// announces, lab codes, address counts, aliases and the canary ring.
	st          *poolstate.State
	pool        string
	statusPort  int
	incidentN   int           // open an incident at >= this many fails within incidentWin
	incidentWin time.Duration // trailing window for the fail-burst rule
	crossN      int           // distinct hosts failing within crossWin to open a pool-wide incident
	crossWin    time.Duration // window for cross-host "failing together"
	announceTtl time.Duration // reap an announce entry not refreshed within this window (0 disables /announce)
	hostTtl     time.Duration // drop a hostId from the view this long after last contact
	refreshTTL  time.Duration // how long a refresh capability reading stays current (RefreshView)
	// Push-ingest: the shared bearer token gating POST /ingest (empty ->
	// ingest disabled, never an unauthenticated write route), plus the Loki push URL
	// + client the handler needs.
	authToken  string
	lokiURL    string
	httpClient *http.Client
	// labRotate is the lab connection token's rotation period; 0 keeps the tile
	// and POST /api/v1/lab-token disabled.
	labRotate time.Duration
	// eventCur is touched ONLY by the single poll goroutine (in Poller.TailEvents
	// and the post-unlock prune in Poller.Once), never by the HTTP handlers, so it
	// needs no lock -- unlike the pool view, which st guards against handler reads.
	eventCur map[string]*poll.EventCursor // keyed by hostId
	// outbox holds the best-effort Loki lines until Loki accepts them (nil sends
	// each line directly, as a poolState built by a test does).
	outbox *loki.Outbox
	// statsCache memoizes /api/v1/pool-stats per range. Several operators
	// pull-to-refreshing the board on phones must not turn into a Loki query
	// storm: each entry is two range queries, and the underlying counts move
	// only as fast as cycles finish. Guarded by its own mutex rather than the
	// view's so a slow Loki read never blocks the poll loop or /api/v1/pool-status.
	statsMu    sync.Mutex
	statsCache map[string]*poolStatsCacheEntry // range token -> memoized answer
	statsEpoch uint64                          // invalidates an in-flight pre-handover Loki projection
	// archiveRoot is the pool share's hosts/ directory as this machine sees it
	// (the proxy CIFS-mounts the share). Empty disables the /archive/ route and
	// every archive-aware resolution, which is what a proxy with no pool storage
	// has.
	archiveRoot string
	// handoverFile is the durable identity ledger behind the view's aliases.
	handoverFile string
	// hostMetricsPort is the port the scrape document points at on each Windows
	// host. Configurable because the exporter's port is a decision made on the
	// hosts, and a pool that moved it would otherwise have to rebuild this VM to
	// be scraped at all.
	hostMetricsPort int
	// backfillStateDir is where the history backfill keeps its per-host cycle
	// indexes, which /go/cycle reads to place a click on a cycle weeks old without
	// asking the host. Empty disables that lookup.
	backfillStateDir string
	// ringStateFile keeps the canary ring's facts across a restart (empty keeps
	// them in memory). ringWriteFailed is touched only by the poll goroutine,
	// so a failing disk is logged once rather than every poll.
	ringStateFile   string
	ringWriteFailed bool
}

// poolStatsCacheEntry is one memoized /api/v1/pool-stats answer.
type poolStatsCacheEntry struct {
	at      time.Time
	payload []byte
}

func newPoolState(pool string, statusPort int) *poolState {
	return &poolState{
		st:   poolstate.New(),
		pool: pool, statusPort: statusPort, incidentN: defaultIncidentN, incidentWin: defaultIncidentWin,
		crossN: defaultCrossN, crossWin: defaultCrossWin,
		announceTtl: defaultAnnounceTtl,
		hostTtl:     defaultHostTtl,
		refreshTTL:  refreshObservationFloor,
		eventCur:    map[string]*poll.EventCursor{},

		hostMetricsPort: defaultHostMetricsPort,
	}
}

// seenTtl is deliberately derived, never configured: the per-cycle dedup set
// must outlive the host row it belongs to, or a reaped-then-returning host
// re-counts a terminal cycle. Two independent knobs could be set the other way
// round.
func (s *poolState) seenTtl() time.Duration {
	return s.hostTtl + seenTtlGrace
}

// deepLinkLookback is how far back a dashboard link may resolve a host that has
// left the live view. It follows the host TTL upward but never below the floor,
// so shortening the TTL cannot silently break links the dashboard still shows.
func (s *poolState) deepLinkLookback() time.Duration {
	if s.hostTtl > minDeepLinkLookback {
		return s.hostTtl
	}
	return minDeepLinkLookback
}

// poller builds the poll over the collector's settings as they are now. The
// event cursors are the collector's own map, so the event tail resumes where
// the last poll left it, and the canary ring's rows are read and recorded by
// the collector's own ring code.
func (s *poolState) poller() *poll.Poller {
	return poll.New(poll.Config{
		State: s.st, Pool: s.pool, StatusPort: s.statusPort, HostTTL: s.hostTtl, SeenTTL: s.seenTtl(),
		AnnounceTTL: s.announceTtl, IncidentN: s.incidentN, IncidentWindow: s.incidentWin,
		CrossN: s.crossN, CrossWindow: s.crossWin, EventCursors: s.eventCur,
		ProxyTag: controlTagFor(s.authToken), Outbox: s.outbox,
		Ring: poll.Ring{
			ReadRows: func(hostID string, body []byte) poll.RingRows {
				rows := parseRingRows(body)
				return func(view *poolstate.View) bool { return s.recordRingRows(view, hostID, rows) }
			},
			Snapshot: s.ringStateSnapshot,
			Persist:  s.persistRingState,
		},
	})
}

// rehydrator builds the startup restore over the collector's view and its
// incident and announce windows.
func (s *poolState) rehydrator() *rehydrate.Reader {
	return rehydrate.New(rehydrate.Config{State: s.st, IncidentWindow: s.incidentWin, AnnounceTTL: s.announceTtl})
}

// routeServer builds the routes over the collector's settings as they are now;
// each request builds its own, so a handler never reads a stale setting.
func (s *poolState) routeServer() *routes.Server {
	return routes.New(routes.Config{
		State: s.st, Pool: s.pool, AuthToken: s.authToken, LokiURL: s.lokiURL, HTTPClient: s.httpClient,
		LabRotate: s.labRotate, Outbox: s.outbox, RefreshTTL: s.refreshTTL, AnnounceTTL: s.announceTtl,
		IncidentN: s.incidentN, IncidentWindow: s.incidentWin, CrossWindow: s.crossWin,
		ArchiveRoot: s.archiveRoot, HostMetricsPort: s.hostMetricsPort, DeepLinkLookback: s.deepLinkLookback(),
		FolderByIndex: s.resolveFolderByIndex, ParseListing: parseListing,
		CachedPoolStats: s.cachedPoolStats, CachePoolStats: s.cachePoolStats,
	})
}

// cachedPoolStats returns the memoized /api/v1/pool-stats answer for window
// while it is younger than poolStatsCacheTTL, with the cache epoch a fresh
// answer is to be stored under.
func (s *poolState) cachedPoolStats(window string) (epoch uint64, payload []byte, hit bool) {
	s.statsMu.Lock()
	defer s.statsMu.Unlock()
	if e := s.statsCache[window]; e != nil && time.Since(e.at) < poolStatsCacheTTL {
		return s.statsEpoch, e.payload, true
	}
	return s.statsEpoch, nil, false
}

// cachePoolStats memoizes payload for window unless a handover has moved the
// epoch since cachedPoolStats handed it out.
func (s *poolState) cachePoolStats(window string, epoch uint64, payload []byte) {
	s.statsMu.Lock()
	defer s.statsMu.Unlock()
	if epoch == s.statsEpoch {
		if s.statsCache == nil {
			s.statsCache = map[string]*poolStatsCacheEntry{}
		}
		s.statsCache[window] = &poolStatsCacheEntry{at: time.Now(), payload: payload}
	}
}

// pollWithFreshConnections runs one poll on connections of its own and closes
// them when it ends.
func (s *poolState) pollWithFreshConnections(squidLog, lokiURL string, now time.Time) {
	s.poller().WithFreshConnections(squidLog, lokiURL, now)
}

// The startup restore main() runs before the first poll; see internal/rehydrate.
func (s *poolState) rehydrateFromLoki(lokiPushURL, pool string, window time.Duration, now time.Time) {
	s.rehydrator().Cycles(lokiPushURL, pool, window, now)
}

func (s *poolState) rehydrateIncidentsFromLoki(lokiPushURL, pool string, window time.Duration, now time.Time) {
	s.rehydrator().Incidents(lokiPushURL, pool, window, now)
}

func (s *poolState) rehydrateHostPresenceFromLoki(lokiPushURL, pool string, window time.Duration, now time.Time) {
	s.rehydrator().Presence(lokiPushURL, pool, window, now)
}

func (s *poolState) rehydrateAnnouncesFromLoki(lokiPushURL, pool string, now time.Time) {
	s.rehydrator().Announces(lokiPushURL, pool, now)
}

// rotateLabToken mints the next lab connection token and prunes the expired
// throttle records. It reads only the pool view: main() starts the rotation
// before it has assigned every setting a route reads.
func (s *poolState) rotateLabToken(now time.Time) { routes.RotateLabToken(s.st, now) }

// requireInternalBearer checks the internal token and localizes a refusal.
func (s *poolState) requireInternalBearer(w http.ResponseWriter, r *http.Request) bool {
	return s.routeServer().RequireInternalBearer(w, r)
}

// The routes main() registers and mcp.go serves, each answered by a Server
// built from the current settings.
func (s *poolState) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleHealth(w, r)
}

func (s *poolState) handleMetrics(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleMetrics(w, r)
}

func (s *poolState) handlePoolStatus(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandlePoolStatus(w, r)
}

func (s *poolState) handlePrometheusTargets(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandlePrometheusTargets(w, r)
}

func (s *poolState) handleExtensionHosts(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleExtensionHosts(w, r)
}

func (s *poolState) handlePoolStats(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandlePoolStats(w, r)
}

func (s *poolState) handlePoolIncidents(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandlePoolIncidents(w, r)
}

func (s *poolState) handleCycleLinks(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleCycleLinks(w, r)
}

func (s *poolState) handlePoolHealth(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandlePoolHealth(w, r)
}

func (s *poolState) handleArchive(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleArchive(w, r)
}

func (s *poolState) handleGoCycle(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleGoCycle(w, r)
}

func (s *poolState) handleGoHostEvent(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleGoHostEvent(w, r)
}

func (s *poolState) handleGoCycleShare(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleGoCycleShare(w, r)
}

func (s *poolState) handleGoHost(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleGoHost(w, r)
}

func (s *poolState) handleGoStash(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleGoStash(w, r)
}

func (s *poolState) handleIngest(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleIngest(w, r)
}

func (s *poolState) handleForgetHost(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleForgetHost(w, r)
}

func (s *poolState) handleAnnounce(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleAnnounce(w, r)
}

func (s *poolState) handleHostAnnounce(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleHostAnnounce(w, r)
}

func (s *poolState) handleHostAddress(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleHostAddress(w, r)
}

func (s *poolState) handleLabToken(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleLabToken(w, r)
}

func (s *poolState) handleControlProof(w http.ResponseWriter, r *http.Request) {
	s.routeServer().HandleControlProof(w, r)
}

// newLokiOutbox opens the collector's outbox in dir (in memory when dir is empty
// or unusable) over a client of its own, logging its events through the catalog.
func newLokiOutbox(dir, lokiURL string) *loki.Outbox {
	client := newInternalHTTPClient(pushTimeout)
	push := func(ctx context.Context, payload []byte) error {
		pctx, cancel := context.WithTimeout(ctx, pushTimeout)
		defer cancel()
		return loki.Push(pctx, client, lokiURL, payload)
	}
	logf := func(event string, args map[string]any) {
		key := map[string]string{
			"outbox_memory_only": "aggregator.log_loki_outbox_memory_only",
			"outbox_full":        "aggregator.log_loki_outbox_full",
			"outbox_refused":     "aggregator.log_loki_outbox_refused",
			"outbox_unreadable":  "aggregator.log_loki_outbox_unreadable",
		}[event]
		if key == "" {
			return
		}
		text := map[string]any{}
		for k, v := range args {
			text[k] = fmt.Sprint(v)
		}
		log.Print(operatorMessage(key, text))
	}
	return loki.NewOutbox(dir, push, logf)
}

// controlProofFor mints the retired unbound control proof "<expiry>.<base64 HMAC>",
// HMAC = HMAC-SHA256(internal authentication key, "yuruna-control|proof|<expiry>"),
// byte-for-byte what Test.ConfigServiceSync\Get-YurunaControlProof mints without
// -Audience. No verifier accepts it: it names no target, so it would open every host
// that shares the key. TestMintControlProofGolden keeps it pinned to the shared golden
// vector.
func controlProofFor(token string, expiry int64) string {
	return controlproof.Proof(token, expiry)
}

// controlTagFor is the Go twin of Test.ConfigServiceSync\Get-YurunaControlTag: a
// non-secret name for an internal authentication key, base64(HMAC-SHA256(token,
// "yuruna-control|tag|v1")). Comparing this host's tag with the proxy's answers
// "would a proof minted here verify there?" without either end disclosing the
// token. The data string is FIXED and its label segment is "tag", never "proof",
// so no expiry can produce this message and a captured tag is useless for
// forging a proof. Verified against the shared golden vector by
// TestControlTagGolden.
func controlTagFor(token string) string {
	if token == "" {
		return ""
	}
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|tag|v1"))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// fileReadable reports whether path is a readable, non-empty regular file -- the
// gate for activating TLS / auth, so a missing or empty cert/token file gracefully
// degrades to plain HTTP / ingest-disabled rather than failing to start.
func fileReadable(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular() && fi.Size() > 0
}

// readAuthTokenFile loads the internal authentication key this proxy mints control
// proofs with, gates /ingest on, and hands out through the lab-token exchange. An
// empty return leaves every one of those disabled rather than open. Surrounding
// whitespace is trimmed; defaultPath and legacyPath are parameters so a test can
// exercise the fallback.
// See https://yuruna.link/42c29d04-0023.
func readAuthTokenFile(path, defaultPath, legacyPath string) string {
	token, source, err := servicecfg.ReadAuthToken(path, defaultPath, legacyPath)
	if err != nil {
		log.Print(operatorMessage("aggregator.log_auth_token_file_value1_unreadable_value2_ingest_contro_d458a79c", map[string]any{"value1": fmt.Sprintf("%q", path), "value2": fmt.Sprintf("%v", err)}))
	}
	if source == legacyPath {
		log.Print(operatorMessage("aggregator.log_internal_auth_key_read_from_value1_rebuild_this_proxy__c326800d", map[string]any{"value1": source, "value2": defaultPath}))
	}
	return token
}

// version is overwritten at link time with -X main.version=<framework version>,
// the same way every other extension daemon is stamped. A build that loses the
// flag still runs and reports "dev", which is what the hostinfo assertions in
// the sibling suites exist to catch.
var version = "dev"

func main() {
	// The history backfill is this same binary in a second mode, so the two can
	// never disagree about what a cycle line or an incident line looks like.
	if len(os.Args) > 1 && os.Args[1] == "backfill" {
		os.Exit(runBackfill(os.Args[2:]))
	}
	flag.Lookup("language").Usage = operatorMessage("aggregator.help_display_language", nil)
	flag.Lookup("allow-pseudo-locale").Usage = operatorMessage("aggregator.help_allow_pseudo", nil)
	addr := flag.String("listen", defaultListenAddr, operatorMessage("aggregator.help_address_to_listen_on_59add3f5", nil))
	squidLog := flag.String("squid-log", defaultSquidLog, operatorMessage("aggregator.help_squid_access_log_to_discover_pool_client_ips_from_93473aba", nil))
	lokiURL := flag.String("loki", defaultLokiURL, operatorMessage("aggregator.help_loki_push_api_url_c89d9321", nil))
	pool := flag.String("pool", defaultPool, operatorMessage("aggregator.help_pool_name_label_31358a97", nil))
	statusPort := flag.Int("status-port", defaultStatusPort, operatorMessage("aggregator.help_status_service_port_to_probe_on_each_discovered_ip_e5073cc7", nil))
	hostMetricsPort := flag.Int("host-metrics-port", defaultHostMetricsPort, operatorMessage("aggregator.help_port_the_machine_metrics_exporter_listens_on_for_each__0ae78ba6", nil))
	interval := flag.Duration("interval", defaultInterval, operatorMessage("aggregator.help_poll_discover_interval_a9ec46cd", nil))
	rehydrateWin := flag.Duration("rehydrate-window", defaultRehydrate, operatorMessage("aggregator.help_on_startup_restore_cycle_counts_from_loki_over_this_tr_36b6bc4f", nil))
	incidentN := flag.Int("incident-fails", defaultIncidentN, operatorMessage("aggregator.help_open_an_incident_after_this_many_failed_cycles_within__fb192ccc", nil))
	incidentWin := flag.Duration("incident-window", defaultIncidentWin, operatorMessage("aggregator.help_trailing_window_for_the_n_failures_in_m_minutes_incide_60aa9aa2", nil))
	crossN := flag.Int("cross-host-fails", defaultCrossN, operatorMessage("aggregator.help_distinct_hosts_that_must_fail_within_cross_host_window_5475f083", nil))
	crossWin := flag.Duration("cross-host-window", defaultCrossWin, operatorMessage("aggregator.help_window_for_cross_host_pool_wide_incident_correlation_b4663557", nil))
	announceTtl := flag.Duration("announce-ttl", defaultAnnounceTtl, operatorMessage("aggregator.help_reap_a_self_announced_extension_post_announce_not_refr_56b49fce", nil))
	hostTtl := flag.Duration("host-ttl", defaultHostTtl, operatorMessage("aggregator.help_drop_a_host_from_the_pool_view_this_long_after_last_co_58ed8eb1", nil))
	poolArchiveRoot := flag.String("pool-archive-root", "", operatorMessage("aggregator.help_the_pool_share_s_hosts_directory_on_this_machine_e_g_m_bd4bd40e", nil))
	handoverStateFile := flag.String("handover-state-file", "", "")
	backfillStateDir := flag.String("backfill-state-dir", defaultBackfillStateDir, "")
	lokiOutboxDir := flag.String("loki-outbox-dir", defaultLokiOutboxDir, operatorMessage("aggregator.help_loki_outbox_dir", nil))
	frameworkRingStateFile := flag.String("framework-ring-state-file", defaultFrameworkRingStateFile, operatorMessage("aggregator.help_framework_ring_state_file", nil))
	tlsCert := flag.String("tls-cert", "", operatorMessage("aggregator.help_tls_certificate_file_pem_when_both_tls_cert_and_tls_ke_643d7a8e", nil))
	tlsKey := flag.String("tls-key", "", operatorMessage("aggregator.help_tls_private_key_file_pem_see_tls_cert_28be9018", nil))
	authTokenFile := flag.String("auth-token-file", "", operatorMessage("aggregator.help_file_holding_the_shared_bearer_token_that_gates_post_i_bd4b1952", nil))
	labRotate := flag.Duration("lab-token-rotate", defaultLabRotate, operatorMessage("aggregator.help_rotate_the_dashboard_lab_connection_token_this_often_0_f9f6d959", nil))
	flag.Parse()

	ctx, cancel := context.WithCancel(context.Background())
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; cancel() }()

	state := newPoolState(*pool, *statusPort)
	state.handoverFile = strings.TrimSpace(*handoverStateFile)
	if err := state.loadHandovers(); err != nil {
		log.Fatal(err)
	}
	state.ringStateFile = strings.TrimSpace(*frameworkRingStateFile)
	state.loadRingState()
	// A port outside the valid range would publish a document Prometheus rejects
	// whole, taking every host's machine metrics with it; keep the default and
	// say what was ignored.
	if *hostMetricsPort > 0 && *hostMetricsPort <= 65535 {
		state.hostMetricsPort = *hostMetricsPort
	} else {
		log.Print(operatorMessage("aggregator.log_host_metrics_port_value1_is_not_a_valid_port_keeping_t_e686d724", map[string]any{"value1": fmt.Sprintf("%d", *hostMetricsPort), "value2": fmt.Sprintf("%d", defaultHostMetricsPort)}))
	}
	state.incidentN = *incidentN
	state.incidentWin = *incidentWin
	state.crossN = *crossN
	state.crossWin = *crossWin
	state.announceTtl = *announceTtl
	// Three polls without a fresh capability reading is the window; the floor
	// keeps a short -interval from expiring a reading between two polls.
	state.refreshTTL = max(refreshObservationFloor, 3**interval)
	// A non-positive TTL would reap every host on the first tick, emptying the
	// dashboard; fall back to the default rather than start in that state.
	if *hostTtl > 0 {
		state.hostTtl = *hostTtl
	} else {
		log.Print(operatorMessage("aggregator.log_host_ttl_value1_is_not_positive_keeping_the_default_va_7ade3d03", map[string]any{"value1": fmt.Sprintf("%v", *hostTtl), "value2": fmt.Sprintf("%v", defaultHostTtl)}))
	}
	client := newInternalHTTPClient(probeTimeout)
	state.lokiURL = *lokiURL
	state.httpClient = client
	// Load the shared bearer token that GATES /ingest. Absent / empty file -> token
	// stays "" -> the route is disabled (503), so it is never exposed unauthenticated.
	state.authToken = readAuthTokenFile(*authTokenFile, defaultAuthTokenFile, legacyAuthTokenFile)
	// Archive root: the pool share's hosts/ directory as this machine sees it. Only
	// the path is captured here; the directory itself is opened per request, because
	// the CIFS mount arrives asynchronously after boot and may also go away and come
	// back without this process noticing.
	state.archiveRoot = strings.TrimSpace(*poolArchiveRoot)
	state.backfillStateDir = strings.TrimSpace(*backfillStateDir)
	if state.archiveRoot != "" {
		log.Print(operatorMessage("aggregator.log_archive_route_enabled_at_archive_from_value1_7b032a09", map[string]any{"value1": fmt.Sprintf("%q", state.archiveRoot)}))
	}
	// Lab connection token rotation: seeded before the server starts so the
	// first /metrics scrape already carries a redeemable code. Requires the
	// shared token -- with none there is nothing the exchange could hand out.
	if *labRotate > 0 && state.authToken != "" {
		state.labRotate = *labRotate
		state.rotateLabToken(time.Now().UTC())
		go func() {
			t := time.NewTicker(state.labRotate)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					state.rotateLabToken(time.Now().UTC())
				}
			}
		}()
	} else if *labRotate > 0 {
		log.Print(operatorMessage("aggregator.log_lab_token_exchange_disabled_no_auth_token_configured_a47d49b1", nil))
	}

	if *lokiURL != "" {
		state.outbox = newLokiOutbox(strings.TrimSpace(*lokiOutboxDir), *lokiURL)
	}
	go func() {
		if state.outbox != nil {
			// Loki starts beside this daemon and answers 503 while its ingester
			// warms up; a startup read then comes back empty and every restored
			// count, incident and presence starts from nothing. Wait for it
			// (bounded), deliver what an earlier run queued so the read below
			// sees it, then let the worker take over.
			if !loki.WaitReady(ctx, newInternalHTTPClient(probeTimeout), *lokiURL, lokiReadyWait, time.Second, 15*time.Second) {
				log.Print(operatorMessage("aggregator.log_loki_not_ready", map[string]any{"duration": lokiReadyWait.String()}))
			}
			fctx, fcancel := context.WithTimeout(ctx, lokiReadyWait)
			state.outbox.Flush(fctx)
			fcancel()
			go state.outbox.Run(ctx)
		}
		now := time.Now().UTC()
		if *rehydrateWin > 0 {
			state.rehydrateFromLoki(*lokiURL, *pool, *rehydrateWin, now)
			state.rehydrateIncidentsFromLoki(*lokiURL, *pool, *rehydrateWin, now)
			// Re-seed the volatile host view (last-known IPs) from the presence
			// beacon feed so an idle/stash-only host discovered before the restart is
			// re-probed on the first poll instead of vanishing until it next pulls
			// through the proxy. Runs before the first Poller.Once so its seeds are
			// candidates immediately.
			state.rehydrateHostPresenceFromLoki(*lokiURL, *pool, *rehydrateWin, now)
			// Restore live self-announced extensions so their dashboard rows do
			// not wait up to one beacon period after a restart.
			state.rehydrateAnnouncesFromLoki(*lokiURL, *pool, now)
		}
		state.pollWithFreshConnections(*squidLog, *lokiURL, now)
		t := time.NewTicker(*interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				state.pollWithFreshConnections(*squidLog, *lokiURL, time.Now().UTC())
			}
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc(routeHealth, state.handleHealth)
	mux.HandleFunc(routeMetrics, state.handleMetrics)
	mux.HandleFunc(routePoolStatus, state.handlePoolStatus)
	// /api/v1/prometheus-targets: the pool's Windows hosts as a Prometheus HTTP
	// service-discovery document, read by the collector on this same machine.
	mux.HandleFunc(routePromTargets, state.handlePrometheusTargets)
	// /api/v1/extension-hosts: "where is area X served in this pool?" -- the
	// coordinate lookup that lets a host find the stash / pool-control service
	// knowing only the caching-proxy-service address it already has. Read-only and open,
	// the same posture as /api/v1/pool-status.
	mux.HandleFunc(routeExtensionHosts, state.handleExtensionHosts)
	// /api/v1/pool-stats: per-HOST terminal-cycle counts over a preset window,
	// the numbers behind the pool-control board's cards. Per-host, not per-pool,
	// because membership lives in the configuration store this service never reads --
	// the control service does the join. Read-only and open, like pool-status.
	mux.HandleFunc("/api/v1/pool-stats", state.handlePoolStats)
	mux.HandleFunc(routePoolIncidents, state.handlePoolIncidents)
	mux.HandleFunc(routePoolCycleLinks, state.handleCycleLinks)
	mux.HandleFunc(routePoolHealth, state.handlePoolHealth)
	mux.HandleFunc(routeFrameworkRing, state.handleFrameworkRing)
	// /archive/: archived cycle results served straight off the pool share. Registered
	// only when a root is configured -- a proxy with no pool storage has nothing to
	// serve, and an unregistered route is a cleaner 404 than a handler that always
	// fails. Whether the mount is actually THERE is a per-request question (it comes
	// up asynchronously after boot), answered inside the handler.
	if state.archiveRoot != "" {
		mux.HandleFunc("/archive/", state.handleArchive)
	}
	// /go/cycle: dashboard timeline click -> 302 to the host's cycle-results folder,
	// resolving the host's CURRENT IP live (so the link survives an IP change). Open
	// (no auth): it only redirects to a host's already-open status service.
	mux.HandleFunc("/go/cycle", state.handleGoCycle)
	mux.HandleFunc("/go/host-event", state.handleGoHostEvent)
	// /go/cycle-share: the same click, resolved the same way, but landing on the
	// host's share page for that cycle -- one archive of the whole results folder,
	// handed to the operator's mail client. Open, like the two redirects around it.
	mux.HandleFunc("/go/cycle-share", state.handleGoCycleShare)
	// /go/host: same uuid->current-IP resolution as /go/cycle, but 302s to the host's
	// status-page ROOT (not a cycle folder) -- the timeline's "open host status page"
	// link, so the IP-free state-timeline rows reach the per-host status page too.
	mux.HandleFunc("/go/host", state.handleGoHost)
	// /go/stash: dashboard Extension-cell click -> 302 to the host's extension-service VM
	// UI, from the URL that host advertised (extensionTargets), carrying a short-lived
	// control proof in the fragment so the UI arrives with its actions unlocked. Open (no
	// auth) to reach: the same posture as /go/host, and for the same reason -- what it
	// redirects to is already open, and only the fragment grants anything.
	mux.HandleFunc("/go/stash", state.handleGoStash)
	// /ingest stays registered always; it self-gates on the auth token (503 when
	// unconfigured). /metrics, /healthz, /api/v1/pool-status remain OPEN + plaintext-
	// parseable so Prometheus, the host-side pool notifier, and the hostname-free
	// dashboard keep working without credentials.
	mux.HandleFunc("/ingest", state.handleIngest)
	// /api/v1/forget-host: operator-driven manual eviction of a hostId from the view
	// (POST, bearer-gated like /ingest, 503 when no token) -- drops it from /metrics
	// + the dashboard NOW instead of after the host TTL. Called by
	// test/pool/Remove-PoolHost.ps1.
	mux.HandleFunc("/api/v1/forget-host", state.handleForgetHost)
	mux.HandleFunc("POST /api/v1/handover-host", state.handleHandoverHost)
	mux.HandleFunc("GET /api/v1/host-aliases", state.handleHostAliases)
	// Raw historical events can contain sensitive diagnostics; require the
	// internal bearer even though alias metadata itself is public.
	mux.HandleFunc("GET /api/v1/host-history", state.handleHostHistory)
	// /announce: extension-presence beacon target (stash service et al). Open by
	// design with self-identity binding -- see handleAnnounce; self-gates on
	// -announce-ttl (503 when 0).
	mux.HandleFunc("/announce", state.handleAnnounce)
	// /api/v1/host-announce: host-presence beacon target. Same open,
	// self-identity-bound posture as /announce, but the confirm is an identity
	// check against the announced address's own status.json -- see
	// handleHostAnnounce; self-gates on -announce-ttl (503 when 0).
	mux.HandleFunc("/api/v1/host-announce", state.handleHostAnnounce)
	// /api/v1/host-address: one host's current base URL, for the guest-side
	// resolver. Read-only and proof-free, unlike /go/host -- see
	// handleHostAddress.
	mux.HandleFunc("/api/v1/host-address", state.handleHostAddress)
	// /api/v1/lab-token: exchanges the dashboard-displayed 6-char lab
	// connection token for the internal authentication key (the Set-LabToken.ps1
	// enrollment call). Open with knowledge-of-the-code as the credential,
	// per-IP throttled + audited -- see handleLabToken; self-gates on
	// -lab-token-rotate and on a configured token (503 otherwise).
	// MCP over the read surface above. Not gated: every tool it serves is
	// read-only and carries exactly the exposure of the open route it wraps.
	mux.HandleFunc("POST /mcp", state.mcpServer(version).Handler())
	mux.HandleFunc(routeLabToken, state.handleLabToken)
	// /api/v1/control-proof: "was this proof minted from the pool's internal authentication key,
	// and is it still live?" -- asked by an extension service that holds no token of
	// its own and so cannot check the proof the /go/stash redirect handed its UI.
	// Open like the exchange above, and a verifier rather than a mint -- see
	// handleControlProof; self-gates on a configured token (503 otherwise).
	mux.HandleFunc("/api/v1/control-proof", state.handleControlProof)

	srv := &http.Server{Addr: *addr, Handler: mux, ReadTimeout: 5 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 30 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, scancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer scancel()
		_ = srv.Shutdown(sctx)
	}()

	// TLS activates only when both cert + key name readable, non-empty files; a
	// missing/empty pair degrades gracefully to plain HTTP,
	// so a proxy provisioned without the leaf still runs. crypto/tls is stdlib -> the
	// Windows toolchain still cross-builds this.
	useTLS := fileReadable(*tlsCert) && fileReadable(*tlsKey)
	if (*tlsCert != "" || *tlsKey != "") && !useTLS {
		log.Print(operatorMessage("aggregator.log_tls_cert_tls_key_set_but_not_both_readable_non_empty_s_f5dfa9e3", nil))
	}
	authState := operatorMessage("aggregator.log_ingest_disabled_no_token_3a819fb4", nil)
	if state.authToken != "" {
		authState = operatorMessage("aggregator.log_ingest_enabled_bearer_89578b00", nil)
	}
	if state.labRotate > 0 {
		authState += operatorMessage("aggregator.log_lab_token_exchange_on_rotate_duration_5ce442f0", map[string]any{"duration": state.labRotate.String()})
	} else {
		authState += operatorMessage("aggregator.log_lab_token_exchange_off_4bdcc105", nil)
	}
	scheme := "http"
	if useTLS {
		scheme = "https+http"
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	log.Print(operatorMessage("aggregator.log_pool_aggregator_service_listening_on_value1_value2_poo_b30f8764", map[string]any{"value1": fmt.Sprintf("%s", *addr), "value2": fmt.Sprintf("%s", scheme), "value3": fmt.Sprintf("%q", *pool), "value4": fmt.Sprintf("%s", *squidLog), "value5": fmt.Sprintf("%d", *statusPort), "value6": fmt.Sprintf("%s", *lokiURL), "value7": fmt.Sprintf("%s", *interval), "value8": fmt.Sprintf("%s", authState)}))
	var serveErr error
	if useTLS {
		// With the leaf present, :9400 answers both protocols on one port: TLS for the
		// token-bearing clients (the ingest forwarder, Set-LabToken's exchange, the
		// Prometheus scrape) and plain HTTP for the browser-facing /go/* deep links.
		// See https://yuruna.link/42c29d04-0024.
		cert, err := tls.LoadX509KeyPair(*tlsCert, *tlsKey)
		if err != nil {
			log.Fatal(err)
		}
		srv.TLSConfig.Certificates = []tls.Certificate{cert}
		inner, err := net.Listen("tcp", *addr)
		if err != nil {
			log.Fatal(err)
		}
		serveErr = srv.Serve(httpserve.NewDualProtocolListener(inner, srv.TLSConfig))
	} else {
		serveErr = srv.ListenAndServe()
	}
	if serveErr != nil && serveErr != http.ErrServerClosed {
		log.Fatal(serveErr)
	}
}
