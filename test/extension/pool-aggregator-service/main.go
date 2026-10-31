// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428f33a8-3f41-4398-a845-e3d0d598baf0

// pool-aggregator-service: read-only multi-host pool view for the Yuruna test harness.
// See ../../../docs/pool-admin.md#architecture for the auto-discovery and
// identification design, and README.md in this directory for the full detail.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"yuruna.com/test/extension/extension-sdk/servicecfg"

	"yuruna.com/test/extension/extension-sdk/controlproof"
	sdkpool "yuruna.com/test/extension/extension-sdk/pool"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/httpserve"
	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

const (
	defaultListenAddr  = ":9400"
	defaultSquidLog    = "/var/log/squid/yuruna_access.log"
	defaultLokiURL     = "http://127.0.0.1:3100/loki/api/v1/push"
	defaultPool        = "default"
	defaultStatusPort  = 8080
	defaultInterval    = 30 * time.Second
	defaultDiscoverWin = 35 * time.Minute   // just over a 30-min DHCP lease
	defaultHostTtl     = 24 * time.Hour     // keep a hostId in the view this long after last contact
	defaultRehydrate   = 7 * 24 * time.Hour // restore cycle counts from Loki on startup over this trailing window
	probeTimeout       = hostpoll.ProbeTimeout
	pushTimeout        = 10 * time.Second
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
	maxProbe          = 8          // bounded concurrent probes per tick
	logTailBytes      = 512 * 1024 // bytes scanned from EOF for recent client IPs
	// The lab-wide address scan reads a day of log rather than a fixed tail, so
	// it is far more expensive than discovery's and must not run every poll.
	// Five minutes is well inside any useful reaction time for a pool that
	// takes hours to drain, and the answer barely moves between scans.
	addrScanWindow   = 24 * time.Hour
	addrScanInterval = 5 * time.Minute
	addrScanMaxBytes = 64 << 20 // 64 MiB: a day of lab squid traffic with headroom
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
	eventsFile          = "cycle.events.ndjson" // per-cycle NDJSON event log on each host
	maxEventFetch       = 4 << 20               // bytes read from a host's events file per poll
	maxEventPush        = 1000                  // NDJSON lines shipped per host per poll (catch-up is bounded)
	defaultIncidentN    = 3                     // failed cycles within the window to open an incident
	defaultIncidentWin  = 2 * time.Hour         // trailing window for the N-failures-in-M-minutes rule
	defaultCrossN       = 3                     // distinct hosts failing within crossWin to open a pool-wide incident
	defaultCrossWin     = 15 * time.Minute      // window for cross-host "failing together" correlation
	// Extension-presence announce (POST /announce): a service VM (e.g. the
	// stash service) self-reports the extension it runs, independent of the
	// owning host's status service.
	//
	// The TTL is a reaping horizon, deliberately many beacon periods long
	// rather than a tight multiple of one. Refusal, not reaping, is what stops
	// an unreachable address being handed out (see extensionHealthGrace); the
	// row that outlives the failure is what still names the address that
	// stopped answering, so reaping it promptly would replace "advertised at X,
	// which does not answer" with silence.
	defaultAnnounceTtl = 45 * time.Minute
	maxAnnounce        = 512     // distinct (hostId,area) announce entries kept in memory
	maxAnnounceBody    = 4 << 10 // bytes read from one announce POST
	// --- REGION: https://yuruna.link/42fffc2c-0016
	// A confirmed target that goes quiet is kept for extensionHealthGrace -- a
	// service restart, a lost packet or a DHCP renewal must not empty the panel
	// -- and is then refused for resolution: the address stops being published,
	// whichever source named it.
	//
	// The entry itself SURVIVES the refusal, suppressed rather than removed. A
	// service whose address died is nearly always a service that renumbered, and
	// it re-announces from the new address within a beacon period; deleting the
	// entry in the meantime leaves the area with no record at all, so an
	// operator asking why a cycle cannot find the stash sees "this pool has no
	// stash" instead of "the stash is advertised at X and X does not answer".
	// Suppressed, it answers nothing and links nowhere, while
	// yuruna_pool_extension_unreachable and the services list keep naming the
	// refused address for as long as the announce TTL carries it.
	//
	// This is why a beacon period must stay SHORTER than this grace: recovery
	// that is slower than refusal opens a window in which the pool has neither
	// the old address nor the new one. See the presence-interval constant each
	// extension service defines.
	//
	// Code-only knobs by design: where a lab's services answer is not an
	// operator preference, and a per-pool override would let one host's
	// misconfiguration be configured away instead of fixed.
	extensionHealthPath  = "/healthz"
	extensionHealthGrace = 5 * time.Minute
	maxExtensionProbe    = 8 // bounded concurrent health probes per poll
	// stashArea is the extension area of the stash service -- the default for
	// /go/stash and the area whose target rides as pool-status stashBaseUrl.
	stashArea = "stash-service"
	// poolControlServiceArea is the extension area of the pool-control service. Named
	// alongside stashArea because both are answered by /api/v1/extension-hosts,
	// the coordinate lookup a host uses to find a service it does not run
	// itself.
	poolControlServiceArea = "pool-control-service"
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
	defaultLabRotate = 60 * time.Second
	labTokenLen      = 6
	// The dashboard shows the code through a Prometheus scrape (15s) plus a
	// panel refresh (30s), so the displayed value can trail a rotation by
	// ~45s, and the operator still has to read it and type it on the joining
	// host. Verifying against the current code plus its two predecessors keeps
	// a just-read code redeemable for at least one full rotation period,
	// while a leaked code still dies within ~3 rotations.
	labKeepCodes    = 3
	maxLabTokenBody = 1 << 10 // bytes read from one exchange POST
	// Per-IP failed-exchange throttle. With 36^6 codes valid for <= 3
	// rotations an online guess is already hopeless; the throttle keeps a
	// misconfigured retry loop from spamming the audit trail and turns the
	// brute-force math from infeasible into absurd.
	labFailLimit  = 10
	labFailWindow = 10 * time.Minute
	// Cap on distinct throttle keys held in memory, so an anonymous caller
	// spraying addresses cannot grow the map without bound. At the cap,
	// expired entries are pruned and further unknown keys simply go
	// unrecorded -- codes are still verified and refused, so overflow costs
	// throttling for new addresses, never admission.
	maxLabFailKeys = 4096
	// The exchange seals the shared token under a key derived from the
	// redeemed code, so only a caller holding the code can open it: an
	// enrolling host has no way to authenticate the aggregator's TLS leaf
	// (it is signed by the proxy's own CA, which that host does not trust
	// yet), and the code is the one secret both ends already share. The
	// iteration count is set for a 6-character secret, which is weak enough
	// that a captured envelope must stay expensive to attack offline.
	labEnvelopeLabel = "yuruna-lab-token|v1"
	labEnvelopeIters = 600000
	// Control-proof lifetime, and the ceiling the host-side verifier
	// (Test.ConfigServiceSync\Test-YurunaControlProof -MaxTtlSeconds) accepts.
	// 15 min, not 5: the proof is minted once on arrival and never refreshed, so
	// a config edit that takes longer than the window would fail at Save with
	// the typing already done. The verifier's ceiling is held strictly ABOVE the
	// mint so a host whose clock trails the proxy still accepts a freshly minted
	// proof; that surplus is the whole skew tolerance, which is what
	// classifyControl measures a host's clock against.
	controlProofTTL         = 15 * time.Minute
	controlProofMaxTTL      = 20 * time.Minute
	refreshObservationFloor = poolstate.RefreshObservationFloor
	maxControlStatusBytes   = hostpoll.MaxControlStatusBytes
	// Port a Windows pool host publishes machine metrics on: the Windows
	// exporter's registered default. One number for the whole pool, because the
	// collector and the hosts share no channel to negotiate it on;
	// -host-metrics-port moves it when a pool has to use another.
	defaultHostMetricsPort = 9182
	// Host types that run that exporter. Every other type is simply absent from
	// the scrape document: listing a host nothing answers on would mark a target
	// down for as long as the host exists.
	windowsHostTypePrefix = "host.windows."
)

// squid yuruna logformat: field 1 = %ts.%03tu (epoch.ms), field 3 = %>a (client
// IP). Capture both; the response-time field (%6tr) sits between them.
var clientIPRE = regexp.MustCompile(`^(\d+\.\d+)\s+\S+\s+(\S+)`)

// The host wire types and reads live in internal/hostpoll; these names keep the
// pool-state code that merges them readable.
type (
	hostStatus    = hostpoll.HostStatus
	gitCommitRef  = hostpoll.GitCommitRef
	gitCommitRefs = hostpoll.GitCommitRefs
	runnerFault   = hostpoll.RunnerFault
	cycleVerdict  = hostpoll.CycleVerdict
	controlStatus = hostpoll.ControlStatus
)

const stepPauseCode = hostpoll.StepPauseCode

var errControlStatusOversize = hostpoll.ErrControlStatusOversize

// The incident rules and their records live in internal/incident; these names
// keep the pool-state code that owns the records readable.
type (
	failRec           = incident.FailRec
	incidentState     = incident.HostIncident
	poolIncidentState = incident.PoolIncident
	gatingPolicy      = incident.GatingPolicy
	poolGateState     = incident.Gate
	incidentEvent     = incident.Event
)

// shaCommitRE gates a git SHA into a commit deep-link: hex-ish (alphanumeric)
// only, mirroring the status page's renderCommitLinks (yuruna.common.js) so the
// pool table links a commit exactly when that page would.
var shaCommitRE = regexp.MustCompile(`^[A-Za-z0-9]+$`)

// commitURL builds a repoUrl/commit/<sha> deep-link, or "" when the inputs can't
// form a safe link. Mirrors yuruna.common.js renderCommitLinks: link only when
// repoUrl is http(s) and the sha is hex-ish, so an "unknown" SHA or a non-URL
// repo renders as plain text rather than a broken anchor.
func commitURL(repoURL, sha string) string {
	repoURL, sha = strings.TrimSpace(repoURL), strings.TrimSpace(sha)
	if repoURL == "" || sha == "" {
		return ""
	}
	if !strings.HasPrefix(repoURL, "http://") && !strings.HasPrefix(repoURL, "https://") {
		return ""
	}
	if !shaCommitRE.MatchString(sha) {
		return ""
	}
	return strings.TrimRight(repoURL, "/") + "/commit/" + sha
}

// commitCells derives the pool table's Commit column from a host's status.json
// gitCommits (framework first, project second by the runner's convention).
// Returns the display string (8-char short SHAs, comma-joined, both repos) plus
// the framework and project commit deep-link URLs the table's two data-links
// resolve; any return is "" when the host has not reported that piece. The
// short-SHA + link policy mirrors the host status page's Commit block
// (renderCommitLinks in yuruna.common.js) so the pool view and the host page
// agree on what a commit looks like and when it is clickable.
func commitCells(st *hostStatus) (display, frameworkURL, projectURL string) {
	if st == nil {
		return "", "", ""
	}
	shorts := make([]string, 0, len(st.GitCommits))
	for i, c := range st.GitCommits {
		sha := strings.TrimSpace(c.Sha)
		if sha == "" {
			continue
		}
		short := sha
		if len(short) > 8 {
			short = short[:8]
		}
		// Keep persisted verification codes compatible with older hosts while
		// presenting the same concise labels as the host status page.
		label := ""
		switch c.Verification {
		case "origin-direct":
			label = "remote.origin"
		case "mirror-confirmed":
			label = "mirror.origin"
		case "mirror-stale":
			label = "mirror.stale"
		case "mirror-fresh":
			label = "mirror.fresh"
		case "not-applicable":
			label = "not.applicable"
		}
		if label != "" {
			short += " [" + label + "]"
		}
		shorts = append(shorts, short)
		u := commitURL(c.RepoURL, sha)
		if i == 0 {
			frameworkURL = u
		} else if projectURL == "" && u != "" {
			projectURL = u // first non-framework repo that yields a linkable commit
		}
	}
	return strings.Join(shorts, ", "), frameworkURL, projectURL
}

// The pool view's types live in internal/poolstate; these names keep the code
// that reads and changes the view readable.
type (
	hostView             = poolstate.HostView
	announceView         = poolstate.AnnounceView
	extHealthView        = poolstate.ExtHealthView
	addressFootprintView = poolstate.AddressFootprintView
)

// mergeRefresh folds one poll's reading into what the host view holds. A host
// that answered replaces the reading outright -- with unavailable,
// not_advertised when it no longer carries the field. A host that did not
// answer keeps the previous detail for display but is demoted to unavailable:
// the legacy Control verdict's indefinite last-known value must not be copied
// onto a capability that authorizes a disruptive action.
func mergeRefresh(prev sdkpool.HostRefresh, obs *sdkpool.HostRefresh, answered bool, now time.Time) sdkpool.HostRefresh {
	if !answered {
		return demoteRefresh(prev, sdkpool.RefreshReasonControlStatusUnreadable)
	}
	if obs == nil {
		return sdkpool.HostRefresh{Availability: sdkpool.RefreshUnavailable, Reason: sdkpool.RefreshReasonNotAdvertised,
			Remote: sdkpool.RefreshRemoteUnknown, State: sdkpool.RefreshStateUnknown, ObservedUnixMs: now.UnixMilli()}
	}
	out := *obs
	out.ObservedUnixMs, out.AgeSeconds = now.UnixMilli(), 0
	return out
}

// demoteRefresh marks a reading unavailable for reason while keeping the rest
// of its detail, which is display-only once the reading is not current.
func demoteRefresh(prev sdkpool.HostRefresh, reason string) sdkpool.HostRefresh {
	out := prev
	out.Availability, out.Reason = sdkpool.RefreshUnavailable, reason
	if out.Remote == "" {
		out.Remote = sdkpool.RefreshRemoteUnknown
	}
	if out.State == "" {
		out.State = sdkpool.RefreshStateUnknown
	}
	return out
}

// announceKey is the view's Announce map key: one entry per (hostId, area).
func announceKey(hostID, area string) string { return hostID + "|" + area }

// poolStatusEntry is one host in the /api/v1/pool-status snapshot: the
// hostView plus stashBaseUrl, the resolved stash-UI base the stash UI's
// hostId->URL lookup reads. Resolved at serialization time through
// extensionCandidatesLocked -- the same merge the dashboard cell and /go/stash
// read, so the three cannot disagree -- which prefers the service's own live
// announce and falls back to the host's registration.
type poolStatusEntry struct {
	*hostView
	StashBaseURL    string   `json:"stashBaseUrl,omitempty"`
	PreviousHostIDs []string `json:"previousHostIds,omitempty"`
	// Refresh is HostView.RefreshView at serialization time, so pool-status
	// never publishes a capability past its observation window.
	Refresh sdkpool.HostRefresh `json:"refresh"`
}

// announceHostIDRE / announceAreaRE gate what an unauthenticated announce may
// inject into metric labels and Loki lines: an opaque host identifier
// (existing hostIds are 32 hex chars; dashes tolerate GUID formatting) and a
// lowercase extension-area slug.
var (
	announceHostIDRE = regexp.MustCompile(`^[A-Za-z0-9-]{8,64}$`)
	announceAreaRE   = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
)

// eventCursor tracks how far a host's current-cycle NDJSON event file has been
// shipped to Loki, so a poll only forwards new lines. Reset when the cycleStartUtc
// changes (a new cycle = a new file).
type eventCursor struct {
	cycleStartUtc string
	offset        int64 // bytes of the events file already shipped
}

// cycleTransition is one cycle status change captured under the lock: the seen
// key, what seen held before (known=false when nothing), the new status, and the
// Loki line that records it.
type cycleTransition struct {
	key, prev, status string
	known             bool
	payload           map[string]any
}

// presenceTarget is one host whose last-known address pollOnce beacons to Loki
// (src=presence) this tick because it was newly discovered or changed IP. Captured
// under the view's lock (with its pool label) and pushed after the unlock, so a slow Loki
// never stalls the handlers -- the same snapshot-then-push shape as evTarget.
type presenceTarget struct{ hostID, baseURL, pool string }

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
	// eventCur is touched ONLY by the single poll goroutine (in tailEvents and
	// the post-unlock prune in pollOnce), never by the HTTP handlers, so it
	// needs no lock -- unlike the pool view, which st guards against handler reads.
	eventCur map[string]*eventCursor // keyed by hostId
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
		eventCur:    map[string]*eventCursor{},

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

// poolFor returns the host's advertised poolId (derived by the runner from
// pools.yml members[]) when known, else the aggregator's -pool flag default. This
// is the per-host telemetry label, so each host's data accumulates under its real
// pool from first probe. view is the locked pool view.
func (s *poolState) poolFor(view *poolstate.View, hostID string) string {
	if hv := view.Hosts[hostID]; hv != nil && hv.PoolId != "" {
		return hv.PoolId
	}
	return s.pool
}

// evaluateIncidents applies the incident rules to this view's fail windows and
// open incidents, under the view's lock; the returned events are pushed to Loki
// after it is released.
func (s *poolState) evaluateIncidents(view *poolstate.View, now time.Time) []incidentEvent {
	events, pool := incident.EvaluateHosts(incident.Rules{HostN: s.incidentN, HostWindow: s.incidentWin,
		CrossN: s.crossN, CrossWindow: s.crossWin, PoolLabel: s.pool}, view.FailWindow, view.Incident, view.PoolIncident,
		func(hostID string) string { return s.poolFor(view, hostID) }, now)
	view.PoolIncident = pool
	return events
}

// evaluatePoolGate applies each pool's health gate to this view's hosts, under
// the view's lock (reads Hosts/Incident/Gating, mutates PoolGate); the returned
// alert events are pushed to Loki after it is released.
func (s *poolState) evaluatePoolGate(view *poolstate.View, now time.Time) []incidentEvent {
	members := make([]incident.Member, 0, len(view.Hosts))
	for hid, hv := range view.Hosts {
		healthy := false
		if hv.Reachable {
			switch hv.StatusCode() {
			// running, pass, idle, pause-armed but still running, runner stopped.
			// A stale fail behind a stopped runner is no longer counted against the
			// pool; a host that is genuinely failing is excluded by its open
			// incident, which does not care what its current status reads.
			case 1, 2, 4, 6, 7, 8:
				healthy = true
			}
		}
		members = append(members, incident.Member{HostID: hv.HostId, Pool: s.poolFor(view, hid), Healthy: healthy})
	}
	return incident.EvaluateGate(members, view.Incident, view.Gating, view.PoolGate, now)
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// recentClientIPs reads the tail of the squid access log and returns the
// distinct, valid client IPs whose log timestamp is within `window`. Bounded to
// the last logTailBytes so it stays cheap regardless of log size.
func recentClientIPs(logPath string, window time.Duration, now time.Time) []string {
	f, err := os.Open(logPath)
	if err != nil {
		log.Print(operatorMessage("aggregator.log_squid_log_value1_value2_792a142a", map[string]any{"value1": fmt.Sprintf("%s", logPath), "value2": fmt.Sprintf("%v", err)}))
		return nil
	}
	defer f.Close()
	skipPartial := false
	if fi, statErr := f.Stat(); statErr == nil && fi.Size() > logTailBytes {
		if _, err := f.Seek(fi.Size()-logTailBytes, io.SeekStart); err == nil {
			skipPartial = true // first line after a mid-file seek may be truncated
		}
	}
	cutoff := float64(now.Add(-window).Unix())
	set := map[string]bool{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if skipPartial {
			skipPartial = false
			continue
		}
		m := clientIPRE.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		if ts, _ := strconv.ParseFloat(m[1], 64); ts < cutoff {
			continue
		}
		if net.ParseIP(m[2]) != nil {
			set[m[2]] = true
		}
	}
	return sortedKeys(set)
}

// distinctClientIPs returns the DIFFERENT addresses seen over a window, and
// reports whether the whole window was covered: false means the count is a
// floor. It counts observations only and returns the set so callers can union
// it without double-counting. See https://yuruna.link/42c29d04-0002.
func distinctClientIPs(logPath string, window time.Duration, now time.Time, maxBytes int64) (map[string]bool, bool) {
	f, err := os.Open(logPath)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	skipPartial := false
	truncated := false
	if fi, statErr := f.Stat(); statErr == nil && fi.Size() > maxBytes {
		if _, err := f.Seek(fi.Size()-maxBytes, io.SeekStart); err == nil {
			skipPartial = true
			truncated = true
		}
	}
	cutoff := float64(now.Add(-window).Unix())
	set := map[string]bool{}
	reachedCutoff := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if skipPartial {
			skipPartial = false
			continue
		}
		m := clientIPRE.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		ts, tsErr := strconv.ParseFloat(m[1], 64)
		if tsErr != nil {
			continue
		}
		if ts < cutoff {
			// A line older than the window proves the scan spans it. Keep
			// going: squid appends in rough time order but not strictly, and
			// stopping on the first old line would drop the rest.
			reachedCutoff = true
			continue
		}
		if net.ParseIP(m[2]) != nil {
			set[m[2]] = true
		}
	}
	return set, reachedCutoff || !truncated
}

// pollOnce discovers + refreshes the pool. Candidate IPs = recent squid-log
// client IPs UNION the last-known IP of every host already in the view (so an
// idle host stays live). Each candidate is probed for /runtime/status.json;
// responders are keyed by their stable hostId. Hosts not refreshed this tick are
// marked unreachable but kept until hostTtl.
func (s *poolState) pollOnce(client *http.Client, squidLog, lokiURL string, now time.Time) {
	cand := map[string]bool{}
	for _, ip := range recentClientIPs(squidLog, defaultDiscoverWin, now) {
		cand[ip] = true
	}
	// Throttled here rather than in the metrics handler: a Prometheus scrape
	// must never be the thing that reads a day of log off disk, and the poll
	// goroutine is already the one that owns squid-log reads.
	var dueForScan bool
	s.st.Do(func(view *poolstate.View) {
		dueForScan = view.AddressScanDue(now, addrScanInterval)
	})
	if dueForScan {
		seen, complete := distinctClientIPs(squidLog, addrScanWindow, now, addrScanMaxBytes)
		s.st.Do(func(view *poolstate.View) { view.RecordAddressScan(seen, complete, now) })
	}
	s.st.Do(func(view *poolstate.View) {
		for _, h := range view.Hosts {
			if h.CurrentIP != "" {
				cand[h.CurrentIP] = true
			}
		}
	})

	type probeResult struct {
		ip         string
		st         *hostStatus
		ring       []ringRow            // completed cycles the framework canary ring counts, parsed from the same body
		errMsg     string               // non-empty when the probe failed: the reason, keyed onto the unreachable host's LastError
		version    string               // framework VERSION ("" = not fetched this poll; caller keeps prior)
		regOK      bool                 // host.registration.json was fetched + parsed this poll
		poolID     string               // poolId from the registration record ("" = unpooled/not-yet-derived)
		poolGuid   string               // poolGuid from the registration record ("" = unpooled/not-yet-derived)
		gating     *gatingPolicy        // authored gating policy from the record (nil = pool did not author one)
		activeExt  []string             // extension areas the host is actively running (registration activeExtensions)
		extTargets map[string]string    // per-area deep-link URLs the host advertises (registration extensionTargets)
		control    string               // classified control state ("" = not fetched this poll; caller keeps prior)
		refresh    *sdkpool.HostRefresh // refresh capability from control-status (nil = the host answered without one)
		refreshOK  bool                 // control-status answered this poll (false = transport, oversize or parse failure)
		stepParked bool                 // current-action sidecar says the runner is sitting at a step boundary
		parkedOK   bool                 // the sidecar was read this poll (false = keep the prior reading)
		runnerDead bool                 // runner-status says the outer runner is verifiably not alive
		runnerOK   bool                 // runner-status answered this poll (false = keep the prior reading)
	}
	// This proxy's own token tag, computed once per poll: the value every host's
	// published tag is compared against. "" when no internal authentication key is configured,
	// which classifyControl reads as "nothing to compare".
	proxyTag := controlTagFor(s.authToken)
	ips := sortedKeys(cand)
	results := make([]*probeResult, len(ips))
	sem := make(chan struct{}, maxProbe)
	var wg sync.WaitGroup
	for i, ip := range ips {
		wg.Add(1)
		go func(i int, ip string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			base := fmt.Sprintf("http://%s:%d", ip, s.statusPort)
			if st, body, err := hostpoll.FetchStatus(client, base); err == nil && st != nil && st.HostId != "" {
				pr := &probeResult{ip: ip, st: st, ring: parseRingRows(body)}
				// Best-effort: learn the host's pool + gating policy from its
				// registration record. A transient miss keeps the prior poolId +
				// gating (handled at apply time).
				if pid, pguid, g, ext, tgt, rerr := fetchRegistration(client, base); rerr == nil {
					pr.regOK, pr.poolID, pr.poolGuid, pr.gating, pr.activeExt, pr.extTargets = true, pid, pguid, g, ext, tgt
				}
				// Best-effort: learn the host's framework version from VERSION. A
				// transient miss leaves pr.version "" and keeps the prior value.
				if v, verr := hostpoll.FetchVersion(client, base); verr == nil {
					pr.version = v
				}
				// Best-effort: can this host be driven from the dashboard? A
				// transport failure leaves pr.control "" and keeps the prior
				// verdict; a host that ANSWERS -- including an older build with no
				// such route -- replaces it, so "unknown" is reported rather than
				// a stale "ready" inherited forever. Classified here (in the
				// probe goroutine) against the poll's clock so the skew reading
				// is not skewed by the poll's own duration.
				//
				// The refresh capability rides the same answer, with the
				// opposite stickiness: a host that answered replaces it, and a
				// failed or oversize read demotes it rather than keeping it.
				if cs, cerr := hostpoll.FetchControlStatus(client, base); cerr == nil {
					pr.control = classifyControl(proxyTag, cs, now)
					pr.refresh, pr.refreshOK = cs.Refresh, true
				}
				// Best-effort: is anything still driving this host? status.json
				// alone cannot say -- it is a record of what ran, and it reads
				// exactly the same an hour after the runner went away. This is the
				// one probe that cannot be skipped on a hint from status.json,
				// since a stopped runner is precisely the case where status.json
				// has stopped changing.
				if dead, rerr := hostpoll.FetchRunnerStopped(client, base); rerr == nil {
					pr.runnerDead, pr.runnerOK = dead, true
				}
				// Only while the step-pause flag is armed: the sidecar is the one
				// thing that separates "parked at the boundary" from "still running
				// the step it will stop after", and it is read nowhere else
				// (StatusLabel gates on StepPaused), so the overwhelmingly common
				// unarmed host costs no extra request per poll.
				if st.StepPaused {
					if parked, aerr := hostpoll.FetchCurrentAction(client, base); aerr == nil {
						pr.stepParked, pr.parkedOK = parked, true
					}
				}
				results[i] = pr
			} else {
				// Probe did not yield a usable status (st stays nil): record WHY so the
				// unreachable pass can surface it on the host whose last-known IP this
				// was. A 200 with no hostId is a probe failure too (not a pool member).
				msg := "status probe returned no hostId"
				if err != nil {
					msg = err.Error()
				}
				results[i] = &probeResult{ip: ip, errMsg: msg}
			}
		}(i, ip)
	}
	wg.Wait()

	// Hosts newly discovered or whose IP changed this tick: their address is
	// beaconed to Loki (src=presence) after the unlock so the collector can
	// re-seed its volatile view from Loki on a restart (rehydrateHostPresenceFromLoki).
	var presence []presenceTarget
	var cycleTransitions []cycleTransition
	var deleted []string
	// Snapshot the event-tail targets while holding the lock; the fetch+push
	// itself runs unlocked below so a slow host can't stall the handlers.
	type evTarget struct{ hostID, baseURL, cycleID, cycleFolderURL, poolLabel string }
	var targets []evTarget
	var incEvents, gateEvents []incidentEvent
	var ringSnapshot []byte
	s.st.Do(func(view *poolstate.View) {
		refreshed := map[string]bool{}
		// A failed probe records its reason keyed by the candidate IP, so the
		// unreachable pass below can surface WHY (proxy/timeout/refused) on the host
		// whose last-known IP that was -- instead of a blind Reachable=false.
		ipErr := map[string]string{}
		ringChanged := false
		for _, r := range results {
			if r == nil {
				continue // slot never filled (should not happen: every candidate writes one)
			}
			if r.st == nil {
				// Probe failed (or a 200 without a hostId): not a live member this tick.
				// Remember the reason for the unreachable pass; do not refresh.
				if r.errMsg != "" {
					ipErr[r.ip] = r.errMsg
				}
				continue
			}
			hid := r.st.HostId
			// A retired identity may still occur in a stale presence feed or an
			// in-flight probe. It must never regain a live row after handover.
			if view.ReplacedBy(hid) != "" {
				continue
			}
			base := fmt.Sprintf("http://%s:%d", r.ip, s.statusPort)
			hv := view.Hosts[hid]
			prevBase := ""
			if hv == nil {
				hv = &hostView{HostId: hid}
				view.Hosts[hid] = hv
			} else {
				prevBase = hv.BaseURL
			}
			hv.CurrentIP, hv.BaseURL, hv.Reachable, hv.LastError = r.ip, base, true, ""
			// New host (prevBase "") or an IP change -> re-beacon its address. A
			// re-probe of a Loki-seeded stub at the SAME IP leaves base == prevBase, so
			// it does NOT churn a presence line every restart. Streamed under s.pool (the
			// aggregator's -pool default) so rehydrateHostPresenceFromLoki, which queries
			// that same pool label, finds it on restart; pushed after the unlock.
			if base != prevBase {
				presence = append(presence, presenceTarget{hostID: hid, baseURL: base, pool: s.pool})
			}
			hv.LastSeenUnixMs = now.UnixMilli()
			hv.Status = r.st
			if s.recordRingRows(view, hid, r.ring) {
				ringChanged = true
			}
			// Keep the prior version on a transient VERSION miss (it is stable; a blank
			// must not wipe a known value, the same shape as the poolId guard below).
			if r.version != "" {
				hv.Version = r.version
			}
			// Same guard for the control verdict: "" means the probe did not answer
			// this tick, not that control was lost.
			if r.control != "" {
				hv.Control = r.control
			}
			hv.Refresh = mergeRefresh(hv.Refresh, r.refresh, r.refreshOK, now)
			// Keep the prior runner verdict when the route did not answer this tick, the
			// same guard as Control: a missed probe is not a runner that started.
			if r.runnerOK {
				hv.RunnerStopped = r.runnerDead
			}
			// An unarmed host has no boundary to be parked at, so the reading is cleared
			// rather than kept -- otherwise a stale true would resurface the moment the
			// flag is armed again and report a still-running host as already stopped.
			// While armed, a sidecar miss keeps the prior reading, which on a freshly
			// armed flag is the "pausing" it should be.
			if !r.st.StepPaused {
				hv.StepPauseReached = false
			} else if r.parkedOK {
				hv.StepPauseReached = r.stepParked
			}
			// Update the advertised poolId only when the registration probe succeeded,
			// so a transient registration miss never wipes a known pool (and a host that
			// genuinely left a pool clears it: its record now carries poolId="").
			if r.regOK {
				hv.PoolId = r.poolID
				hv.PoolGuid = r.poolGuid
				// Active extension areas this host runs (e.g. stash-service) -> the
				// Extension hosts table. Refreshed from registration each successful poll;
				// a transient registration miss keeps the prior set (handled by the regOK
				// gate, same as poolId).
				hv.ActiveExtensions = r.activeExt
				// Per-area deep-link URLs (e.g. the stash-service VM UI) the host advertises ->
				// the Extension cell's /go/stash. Same regOK gate as ActiveExtensions, so a
				// transient registration miss keeps the prior set rather than blanking it.
				hv.ExtensionTargets = r.extTargets
				// Gating is a pool-level property all members advertise identically;
				// record it whenever a member carries one (last-writer-wins, they agree).
				// A member that omits it does NOT delete a peer's authored gating -- so an
				// older/lagging runner can't silently disable a pool's alerting. Removing
				// gating from pools.yml therefore takes effect on the aggregator's next
				// restart (the gauges still observe; only the page is suppressed).
				if r.poolID != "" && r.gating != nil {
					view.Gating[r.poolID] = *r.gating
				}
			}
			refreshed[hid] = true
			cycleStatus := r.st.CycleStatus()
			if cycleStatus.CycleStartUtc != "" {
				key := poolstate.CycleKey(hid, cycleStatus.CycleStartUtc)
				if prev, known, changed := view.ObserveCycle(key, cycleStatus.OverallStatus, now); changed {
					// Capture only immutable values while state is locked. A slow
					// log store must not hold up pool status, metrics or announces.
					cycleTransitions = append(cycleTransitions, cycleTransition{
						key: key, prev: prev, known: known, status: cycleStatus.OverallStatus,
						payload: cycleTransitionPayload(s.poolFor(view, hid), cycleStatus, base, now),
					})
				}
				passed := cycleStatus.OverallStatus == "pass"
				if hostpoll.IsTerminal(cycleStatus.OverallStatus) && view.CountTerminal(key, hid, passed) && !passed {
					// status.json carries lastFailure (failureClass) in the same doc that
					// flipped overallStatus to "fail" (Complete-Run flushes both), so the
					// class is available at count time; "unknown" when unclassified.
					view.FailWindow[hid] = append(view.FailWindow[hid], failRec{At: now, Class: cycleStatus.FailClassOf()}) // ascending: polls are chronological
				}
			}
		}
		for hid, hv := range view.Hosts {
			if !refreshed[hid] {
				hv.Reachable = false
				hv.Refresh = demoteRefresh(hv.Refresh, sdkpool.RefreshReasonHostUnreachable)
				// Surface WHY this tick's probe of the host's last-known IP failed, so
				// /api/v1/pool-status is no longer blind about an unreachable host. Left
				// as-is when the IP was not a candidate this tick (no fresh reason).
				if msg, ok := ipErr[hv.CurrentIP]; ok {
					hv.LastError = msg
				}
				if now.UnixMilli()-hv.LastSeenUnixMs > s.hostTtl.Milliseconds() {
					delete(view.Hosts, hid)
					view.DropFootprint(hid)
					deleted = append(deleted, hid)
				}
			}
		}
		view.ReapCycles(now, s.seenTtl())
		// Reap self-announced extensions whose beacon stopped refreshing (the
		// service died without a goodbye); a live service re-announces well inside
		// the TTL, so a reaped entry is genuinely gone, not merely between beacons.
		for k, av := range view.Announce {
			if s.announceTtl > 0 && now.UnixMilli()-av.LastSeenUnixMs > s.announceTtl.Milliseconds() {
				delete(view.Announce, k)
			}
		}
		for hid, hv := range view.Hosts {
			if hv.Reachable && hv.Status != nil && hv.Status.CycleStartUtc != "" && hv.Status.CycleFolderUrl != "" {
				// Capture the pool label here under the lock; tailEvents runs unlocked.
				targets = append(targets, evTarget{hid, hv.BaseURL, hv.Status.CycleStartUtc, hv.Status.CycleFolderUrl, s.poolFor(view, hid)})
			}
		}
		// Incident correlation: prune fail windows and open/resolve per-host
		// incidents; the Loki open/resolve events are pushed after the unlock.
		incEvents = s.evaluateIncidents(view, now)
		// Pool gating: compute each pool's advisory degraded/alert latch (read-side;
		// drives alerting + dashboard de-noise, never a cycle). Runs AFTER incidents so
		// "healthy" can exclude a host currently in an open incident.
		gateEvents = s.evaluatePoolGate(view, now)
		if ringChanged {
			ringSnapshot = s.ringStateSnapshot(view)
		}
		view.MarkPolled(now)
	})
	s.persistRingState(ringSnapshot)

	// seen records a transition as delivered. One that could not be queued is
	// put back as unseen, so the next poll builds and sends it again instead of
	// losing it.
	for _, tr := range cycleTransitions {
		if err := s.queueLoki(client, lokiURL, tr.payload, "loki push"); err != nil {
			s.st.Do(func(view *poolstate.View) { view.RevertCycle(tr.key, tr.status, tr.prev, tr.known) })
		}
	}

	// Confirm every advertised extension address from the POOL's vantage point,
	// and drop the ones that have stayed silent past the grace. Runs after the
	// unlock and takes the lock itself: each probe costs up to probeTimeout
	// against an address that may be black-holed, which is exactly the case this
	// exists to catch, and the handlers must stay answerable meanwhile.
	s.refreshExtensionHealth(client, now)

	// Tail each reachable host's current-cycle NDJSON events into Loki.
	// eventCur is only touched here (single poll goroutine), so no lock needed.
	for _, hid := range deleted {
		delete(s.eventCur, hid)
	}
	for _, ev := range incEvents {
		s.pushIncident(client, lokiURL, ev.PoolLabel, ev)
	}
	for _, ev := range gateEvents {
		s.pushIncident(client, lokiURL, ev.PoolLabel, ev)
	}
	// Beacon each newly-discovered / IP-changed host's address to Loki so a restart
	// can re-seed the volatile view (rehydrateHostPresenceFromLoki). On-change only,
	// so this is a low-volume feed -- a steady pool pushes nothing here per poll.
	for _, p := range presence {
		s.pushPresence(client, lokiURL, p.pool, p.hostID, p.baseURL, now)
	}
	for _, t := range targets {
		s.tailEvents(client, lokiURL, t.poolLabel, t.hostID, t.baseURL, t.cycleID, t.cycleFolderURL, now)
	}
}

// newInternalHTTPClient builds the HTTP client the aggregator uses for ALL of
// its traffic: host status probes (http://<lan-ip>:8080) and Loki push/query on
// 127.0.0.1. Every target is on the LAN or loopback, so the client MUST NOT use
// a proxy. This process runs ON the caching-proxy-service host, whose environment may
// export a system-wide http_proxy; http.DefaultTransport's ProxyFromEnvironment
// would then route these LAN/loopback requests THROUGH squid, and a host squid
// is not actively serving right then reads back as unreachable even though its
// :8080 answers a direct request. Proxy:nil pins direct connections;
// DisableKeepAlives makes each poll a fresh one-shot so a pooled connection
// cannot silently go stale between polls and fail a live host's probe.
func newInternalHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			Proxy:             nil,
			DisableKeepAlives: true,
			DialContext:       (&net.Dialer{Timeout: timeout}).DialContext,
		},
	}
}

// pollWithFreshConnections runs one poll on connections of its own and closes
// them when it ends.
func (s *poolState) pollWithFreshConnections(squidLog, lokiURL string, now time.Time) {
	client := hostpoll.NewPollHTTPClient(probeTimeout)
	defer client.CloseIdleConnections()
	s.pollOnce(client, squidLog, lokiURL, now)
}

// fetchRegistration reads poolId, the optional gating policy, the active extension
// areas, and the per-area extension deep-links (extensionTargets) from
// /runtime/host.registration.json (the runner derives poolId/gating from pools.yml,
// the single source of truth; the host advertises extensionTargets for the service it
// runs, e.g. the stash-service VM UI base URL). Returns ("", nil, nil, nil, err) on any
// failure; the caller keeps the prior poolId/gating on a transient miss and falls back
// to the -pool flag when never learned. poolId may be "" for an unpooled host -- that is a successful read,
// not an error. The returned gating is nil when the pool authored none (so the pool
// is observed via gauges but never paged); a partial block is completed with the
// schema defaults.
func fetchRegistration(client *http.Client, base string) (string, string, *gatingPolicy, []string, map[string]string, error) {
	reg, err := hostpoll.FetchRegistration(client, base)
	if err != nil {
		return "", "", nil, nil, nil, err
	}
	if reg.Gating == nil {
		return reg.PoolID, reg.PoolGuid, nil, reg.ActiveExtensions, reg.ExtensionTargets, nil
	}
	g := incident.DefaultGatingPolicy()
	if reg.Gating.FailuresBeforeAlert != nil && *reg.Gating.FailuresBeforeAlert > 0 {
		g.FailuresBeforeAlert = *reg.Gating.FailuresBeforeAlert
	}
	if reg.Gating.SuccessesBeforeRearm != nil && *reg.Gating.SuccessesBeforeRearm > 0 {
		g.SuccessesBeforeRearm = *reg.Gating.SuccessesBeforeRearm
	}
	if reg.Gating.HealthyThreshold != nil && *reg.Gating.HealthyThreshold >= 0 && *reg.Gating.HealthyThreshold <= 1 {
		g.HealthyThreshold = *reg.Gating.HealthyThreshold
	}
	if reg.Gating.DegradedAfterSeconds != nil && *reg.Gating.DegradedAfterSeconds >= 0 {
		g.DegradedAfter = time.Duration(*reg.Gating.DegradedAfterSeconds) * time.Second
	}
	return reg.PoolID, reg.PoolGuid, &g, reg.ActiveExtensions, reg.ExtensionTargets, nil
}

// postToLoki marshals payload, POSTs it to lokiURL under the shared pushTimeout,
// drains + closes the body, and logs (prefixed by logPrefix) on a build error, a
// transport error, or a non-2xx status. The cycle / single-line beacon / events /
// incident push paths share this tail; only the payload and logPrefix differ.
//
// Returns nil once Loki has ACCEPTED the line, else why it did not. Most callers
// are best-effort and ignore it -- their data is re-pushed on the next poll or
// discovery. It exists for the callers whose own reply has to state whether the
// line will survive a restart; see pushAnnounce.
func postToLoki(client *http.Client, lokiURL string, payload map[string]any, logPrefix string) error {
	buf, _ := json.Marshal(payload)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	err := loki.Push(ctx, client, lokiURL, buf)
	var status *loki.PushError
	switch {
	case errors.As(err, &status):
		log.Print(operatorMessage("aggregator.log_value1_http_value2_eb0cd24f", map[string]any{"value1": fmt.Sprintf("%s", logPrefix), "value2": fmt.Sprintf("%d", status.Status)}))
		return fmt.Errorf("%s: HTTP %d", logPrefix, status.Status)
	case err != nil:
		log.Print(operatorMessage("aggregator.log_value1_value2_efae3eb9", map[string]any{"value1": fmt.Sprintf("%s", logPrefix), "value2": fmt.Sprintf("%v", err)}))
	}
	return err
}

// queueLoki hands one best-effort line to the outbox, which sends it once Loki
// is ready to take it, and returns nil once the line is held; with no outbox it
// sends the line directly. No Loki endpoint is nothing to deliver. A caller that
// keeps its own record of what it sent (seen, an event file's cursor) advances
// it only on nil, so a line that could not be held is built and sent again.
func (s *poolState) queueLoki(client *http.Client, lokiURL string, payload map[string]any, what string) error {
	if lokiURL == "" {
		return nil
	}
	if s.outbox == nil {
		if client == nil {
			return nil
		}
		return postToLoki(client, lokiURL, payload, what)
	}
	buf, _ := json.Marshal(payload)
	if err := s.outbox.Enqueue(buf); err != nil {
		if !errors.Is(err, loki.ErrFull) {
			log.Print(operatorMessage("aggregator.log_loki_outbox_enqueue_failed", map[string]any{"what": what, "reason": err.Error()}))
		}
		return err
	}
	return nil
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

// lokiStream is one stream of a query_range answer: its labels and its
// [timestamp, line] value pairs.
type lokiStream struct {
	Stream map[string]string `json:"stream"`
	Values [][2]string       `json:"values"`
}

// lokiStreamsResult is the query_range response envelope every Loki reader
// decodes. Declared once instead of re-inlining the identical anonymous struct in
// each reader.
type lokiStreamsResult struct {
	Data struct {
		Result []lokiStream `json:"result"`
	} `json:"data"`
}

// queryRangeURL derives the Loki query_range endpoint from the push endpoint
// (the readers query the same base the pushes write to), replacing the identical
// strings.TrimSuffix build inline in each reader.
func queryRangeURL(pushURL string) string {
	return strings.TrimSuffix(pushURL, "push") + "query_range"
}

// instantQueryURL derives the Loki INSTANT query endpoint from the push
// endpoint. Distinct from queryRangeURL because a metric query like
// `sum by (hostId) (count_over_time(...))` evaluated once over a window is an
// instant query returning a VECTOR, not a stream of log lines -- the same shape
// the Grafana tiles use (their targets carry "instant": true).
func instantQueryURL(pushURL string) string {
	return strings.TrimSuffix(pushURL, "push") + "query"
}

// lokiVectorResult is the instant-query response envelope: one entry per label
// combination, each with a single [unixSeconds, "value"] sample. Only the labels
// the caller groups by are present in Metric.
type lokiVectorResult struct {
	Data struct {
		Result []struct {
			Metric map[string]string `json:"metric"`
			Value  [2]any            `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

// poolStatsRanges is the CLOSED set of windows /api/v1/pool-stats accepts.
// The value is interpolated into LogQL, so it is never free-form input; and every
// window must stay inside Loki's retention_period (2160h on the proxy) -- a longer
// one would silently return a partial answer that reads as a real number.
var poolStatsRanges = map[string]bool{"1h": true, "24h": true, "7d": true, "30d": true}

// countCyclesByHost runs one instant LogQL count for a terminal overallStatus
// over the window, grouped by hostId, and returns hostId -> count.
//
// Deliberately LAB-WIDE ({pool=~".+"}) and grouped by HOST, not by pool: the
// `pool` stream label is stamped at push time and falls back to the literal
// "default" for a host the aggregator has not yet identified, so summing by that
// label would silently fold unpooled hosts into the target pool's numbers. The
// caller (the pool-control service) joins these per-host rows onto pools.yml
// members[], which is the only authoritative statement of who is in which pool.
func (s *poolState) countCyclesByHost(status, window string) (map[string]int64, error) {
	out := map[string]int64{}
	if s.lokiURL == "" || s.httpClient == nil {
		return out, errors.New("loki-unconfigured")
	}
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`sum by (hostId) (count_over_time({pool=~".+"} | json | overallStatus=%q [%s]))`, status, window))
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, instantQueryURL(s.lokiURL)+"?"+params.Encode(), nil)
	if err != nil {
		return out, err
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return out, fmt.Errorf("loki status %d", resp.StatusCode)
	}
	var vr lokiVectorResult
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&vr); err != nil {
		return out, err
	}
	for _, r := range vr.Data.Result {
		hid := r.Metric["hostId"]
		if hid == "" {
			continue
		}
		// Loki renders the sample value as a string in the [ts, "value"] pair.
		if sv, ok := r.Value[1].(string); ok {
			if n, err := strconv.ParseInt(sv, 10, 64); err == nil {
				out[hid] = n
			}
		}
	}
	return out, nil
}

// handlePoolStats serves per-host terminal-cycle counts over a preset window.
//
// It returns ONLY what Loki can answer. Pool membership lives in the intent
// store, which this service has never read and deliberately does not: its sole
// notion of a pool is the poolId a host self-advertises. The pool-control
// service owns the join -- it reads members[] already -- so the board can render
// a card for a pool whose hosts are all silent (0 reporting) instead of that
// pool vanishing because no Loki stream mentioned it.
//
// Read-only and open, the same posture as /api/v1/pool-status.
func (s *poolState) handlePoolStats(w http.ResponseWriter, r *http.Request) {
	window := r.URL.Query().Get("range")
	if window == "" {
		window = "24h"
	}
	if !poolStatsRanges[window] {
		localizedJSONError(w, r, "aggregator.unsupported_range_use_1h_24h_7d_or_30d", http.StatusBadRequest)
		return
	}

	s.statsMu.Lock()
	epoch := s.statsEpoch
	if e := s.statsCache[window]; e != nil && time.Since(e.at) < poolStatsCacheTTL {
		payload := e.payload
		s.statsMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(payload)
		return
	}
	s.statsMu.Unlock()

	passed, errPass := s.countCyclesByHost("pass", window)
	failed, errFail := s.countCyclesByHost("fail", window)
	if errPass != nil || errFail != nil {
		// An unavailable leg is not a real zero: say so rather than serve zeros, which the board
		// would render as a real "0 cycles" and an operator would read as
		// "nothing ran" instead of "we could not tell".
		localizedJSONError(w, r, "aggregator.loki_query_failed", http.StatusBadGateway)
		return
	}
	// Loki retains the original hostId label. Project its counts through the
	// durable alias ledger so pool membership on the live ID sees all cycles.
	canonicalPassed, canonicalFailed := map[string]int64{}, map[string]int64{}
	s.st.Do(func(view *poolstate.View) {
		for id, n := range passed {
			canonicalPassed[view.CanonicalHostID(id)] += n
		}
		for id, n := range failed {
			canonicalFailed[view.CanonicalHostID(id)] += n
		}
	})
	passed, failed = canonicalPassed, canonicalFailed

	type hostRow struct {
		HostID string `json:"hostId"`
		Passed int64  `json:"passed"`
		Failed int64  `json:"failed"`
	}
	ids := map[string]bool{}
	for id := range passed {
		ids[id] = true
	}
	for id := range failed {
		ids[id] = true
	}
	sorted := make([]string, 0, len(ids))
	for id := range ids {
		sorted = append(sorted, id)
	}
	sort.Strings(sorted)
	rows := make([]hostRow, 0, len(sorted))
	for _, id := range sorted {
		rows = append(rows, hostRow{HostID: id, Passed: passed[id], Failed: failed[id]})
	}

	out := struct {
		Range      string    `json:"range"`
		ComputedAt string    `json:"computedAt"`
		Hosts      []hostRow `json:"hosts"`
	}{Range: window, ComputedAt: time.Now().UTC().Format(time.RFC3339), Hosts: rows}

	payload, err := json.Marshal(out)
	if err != nil {
		localizedJSONError(w, r, "aggregator.encode_failed", http.StatusInternalServerError)
		return
	}
	s.statsMu.Lock()
	if epoch == s.statsEpoch {
		if s.statsCache == nil {
			s.statsCache = map[string]*poolStatsCacheEntry{}
		}
		s.statsCache[window] = &poolStatsCacheEntry{at: time.Now(), payload: payload}
	}
	s.statsMu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(payload)
}

// cycleTransitionPayload snapshots one cycle-status transition for Loki. Labels are strictly
// {pool,hostId,cycleStartUtc} (low cardinality); the variable fields -- including the
// CURRENT baseURL for the dashboard's drill-down deep-link -- live in the line.
// The value timestamp is the proxy-side INGEST clock, not the host cycleStartUtc.
func cycleTransitionPayload(pool string, st *hostStatus, baseURL string, ingest time.Time) map[string]any {
	// hostname is omitted (pool view is hostname-free). cycleFolderUrl IS carried:
	// the /go/cycle redirect resolves a PAST cycle's results folder by time off this
	// line (the in-memory view only knows the current cycle). The folder name is the
	// opaque hostId (Format-CycleFolderBaseName), so the line stays hostname-free;
	// baseUrl is the host IP at transition time (the drill-down fallback for a host
	// that has since aged out of the live view).
	m := map[string]string{
		"hostId": st.HostId, "hostType": st.Host,
		"cycleStartUtc": st.CycleStartUtc, "overallStatus": st.OverallStatus,
		"startedAt": st.StartedAt, "finishedAt": st.FinishedAt,
		"baseUrl": baseURL, "cycleFolderUrl": st.CycleFolderUrl,
	}
	if st.OverallStatus == "fail" {
		// failureClass is carried on the fail transition so a restart's
		// rehydrateFromLoki can restore each fail's class into the fail window.
		m["failureClass"] = st.FailClassOf()
	}
	line, _ := json.Marshal(m)
	return map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": pool, "hostId": st.HostId, "cycleStartUtc": st.CycleStartUtc, "src": "cycle"},
		"values": [][]string{{fmt.Sprintf("%d", ingest.UnixNano()), string(line)}},
	}}}
}

// pushLokiStream POSTs one line to Loki under the given stream labels --
// the shared body of the single-line beacon pushes (presence, announce).
// Any error is logged under `what` and also returned, for the callers that
// have to answer for durability rather than drop it.
//
// No Loki endpoint (or no client) is NOT an error: a pool can legitimately run
// without one, and reporting that as a push failure would turn "this lab keeps
// no log store" into a permanent fault in every caller that checks.
func pushLokiStream(client *http.Client, lokiURL, what string, stream map[string]string, line []byte, now time.Time) error {
	if client == nil || lokiURL == "" {
		return nil
	}
	return postToLoki(client, lokiURL, lokiLinePayload(stream, line, now), what+" push")
}

// lokiLinePayload is the push payload of one line on one stream.
func lokiLinePayload(stream map[string]string, line []byte, now time.Time) map[string]any {
	return map[string]any{"streams": []map[string]any{{
		"stream": stream,
		"values": [][]string{{fmt.Sprintf("%d", now.UnixNano()), string(line)}},
	}}}
}

// pushPresence records a host's last-known address in Loki under {pool,hostId,
// src=presence} when it is first discovered or its IP changes -- a low-volume,
// on-change beacon (NOT per-poll) so the collector can re-seed its VOLATILE host
// view from Loki on restart (rehydrateHostPresenceFromLoki). This is what keeps a
// host that runs NO test cycles (a stash-only host) -- and so pushes no {src=cycle}
// transition -- discoverable across a restart: without it, such a host drops off the
// dashboard until it next pulls through the proxy, even though it is up + reachable +
// advertising its extension. Hostname-free (hostId + baseUrl IP only), matching
// pushLoki's posture. Best-effort; a Loki error is logged + dropped (the next
// discovery re-pushes).
func (s *poolState) pushPresence(client *http.Client, lokiURL, pool, hostID, baseURL string, now time.Time) {
	if lokiURL == "" || hostID == "" || baseURL == "" {
		return
	}
	line, _ := json.Marshal(map[string]string{"hostId": hostID, "baseUrl": baseURL})
	_ = s.queueLoki(client, lokiURL, lokiLinePayload(map[string]string{"pool": pool, "hostId": hostID, "src": "presence"}, line, now), "presence push")
}

// pushAnnounce records one accepted extension-presence announce in Loki under
// {pool,hostId,src=announce} -- EVERY accepted hello (not on-change), so the
// freshest line's age is the entry's age and a restart can restore exactly the
// entries still inside announceTtl (rehydrateAnnouncesFromLoki). Volume is one
// tiny line per service per beacon period. Streamed under s.pool (the
// aggregator's -pool default) so the rehydrate, which queries that same pool
// label, finds it -- the same label coupling pushPresence documents. Goodbyes
// (active=false) are pushed too so the latest line decides restart state.
//
// UNLIKE the other push paths this one is not best-effort, and the error is the
// point. This line is the ONLY record of the announce that outlives the process:
// the entry itself is in-memory, and nothing but the announcer ever re-sends it.
// So a dropped push is a silently lost registration, recoverable only by the
// announcer's next beacon -- a whole re-announce period later. handleAnnounce
// turns this error into a non-2xx so the announcer keeps trying instead.
func pushAnnounce(client *http.Client, lokiURL, pool, hostID, area, target string, active bool, now time.Time) error {
	if lokiURL == "" || hostID == "" {
		return nil
	}
	line, _ := json.Marshal(map[string]any{"hostId": hostID, "area": area, "target": target, "active": active})
	return pushLokiStream(client, lokiURL, "announce",
		map[string]string{"pool": pool, "hostId": hostID, "src": "announce"}, line, now)
}

// hostIPFromBaseURL extracts the bare host (IP) from a status base URL like
// "http://192.168.7.13:8080" -> "192.168.7.13". Returns "" for an unparseable /
// host-less URL, so a malformed Loki-recorded baseUrl can't seed a garbage probe
// candidate. The scheme + port are dropped on purpose: pollOnce rebuilds the probe
// URL from the IP + the configured -status-port.
func hostIPFromBaseURL(baseURL string) string {
	baseURL = strings.TrimSpace(baseURL)
	if baseURL == "" {
		return ""
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

// seedHostStubLocked pre-populates the locked view's hosts with an UNREACHABLE
// stub for a hostId whose last-known IP was recovered from Loki on startup, so the
// first pollOnce probes that IP (its candidate set = squid-log IPs UNION every
// in-view host's CurrentIP). The stub carries NO status/extensions, so
// handleMetrics emits no extension row / pass-fail for it until a real probe
// confirms it -- the seed only makes the probe HAPPEN. This restores discovery for
// a host that is up + reachable but generating no fresh proxy traffic (a paused
// runner, or a stash-only host) after a restart wiped the volatile view. A stub
// NEVER clobbers an existing (possibly live) entry; LastSeenUnixMs is seeded to
// `now` so a transient first-probe miss does not evict it before a full hostTtl of
// retries.
func (s *poolState) seedHostStubLocked(view *poolstate.View, hostID, baseURL string, now time.Time) bool {
	if hostID == "" || view.ReplacedBy(hostID) != "" {
		return false
	}
	if _, ok := view.Hosts[hostID]; ok {
		return false
	}
	ip := hostIPFromBaseURL(baseURL)
	if ip == "" {
		return false
	}
	view.Hosts[hostID] = &hostView{
		HostId:         hostID,
		CurrentIP:      ip,
		BaseURL:        baseURL,
		Reachable:      false,
		LastSeenUnixMs: now.UnixMilli(),
	}
	return true
}

// rehydrateFromLoki seeds the in-memory cycle counters (and the seen/counted
// dedup maps) from Loki at startup so a collector restart RESUMES its pass/fail
// counts instead of resetting to zero. Loki is the durable record of terminal
// transitions (one pushed line per transition, retained ~7d), so this makes the
// Prometheus counters a Loki-backed projection: from Prometheus's view the
// counter resumes at its prior value (no reset), keeping BOTH the table's raw
// counts and the 24h increase() tile correct across a restart -- no dashboard
// change required. Querying terminal lines also restores `seen` for already-
// terminal cycles, so a host still reporting a finished cycle is not re-pushed
// or double-counted. Best-effort: on any Loki error the collector starts with
// empty counts and rebuilds as cycles complete.
func (s *poolState) rehydrateFromLoki(lokiPushURL, pool string, window time.Duration, now time.Time) {
	queryURL := queryRangeURL(lokiPushURL)
	params := url.Values{}
	// Hosts publish under their registered pool, which can differ from this
	// collector's default label. Restore every host stream the collector owns.
	params.Set("query", `{pool=~".+"} | json | overallStatus=~"pass|fail"`)
	params.Set("start", strconv.FormatInt(now.Add(-window).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "5000")
	params.Set("direction", "backward") // most-recent first: if capped, keep the freshest transitions

	client := newInternalHTTPClient(pushTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		log.Print(operatorMessage("aggregator.log_rehydrate_build_request_value1_11b6bf8a", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Print(operatorMessage("aggregator.log_rehydrate_loki_query_value1_starting_with_empty_counts_13e1deb7", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		log.Print(operatorMessage("aggregator.log_rehydrate_loki_http_value1_value2_starting_with_empty__4f5aa860", map[string]any{"value1": fmt.Sprintf("%d", resp.StatusCode), "value2": fmt.Sprintf("%s", strings.TrimSpace(string(body)))}))
		return
	}
	var lr lokiStreamsResult
	if err := json.NewDecoder(io.LimitReader(resp.Body, 32<<20)).Decode(&lr); err != nil {
		log.Print(operatorMessage("aggregator.log_rehydrate_parse_loki_response_value1_5d983c04", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}

	s.st.Do(func(view *poolstate.View) {
		restored, capped := 0, 0
		// Last-known baseUrl (host IP) per hostId, newest wins: every transition line
		// already carries baseUrl, so the same query that restores counts also recovers
		// where each host was, letting the first poll re-probe an idle host that is not
		// in the squid log. Seeded into view.Hosts after the loop.
		latestBase := map[string]string{}
		latestBaseAt := map[string]time.Time{}
		for _, st := range lr.Data.Result {
			capped += len(st.Values)
			for _, v := range st.Values {
				var e struct {
					HostId        string `json:"hostId"`
					CycleStartUtc string `json:"cycleStartUtc"`
					OverallStatus string `json:"overallStatus"`
					FailureClass  string `json:"failureClass"`
					BaseUrl       string `json:"baseUrl"`
				}
				if json.Unmarshal([]byte(v[1]), &e) != nil || e.HostId == "" || e.CycleStartUtc == "" {
					continue
				}
				key := poolstate.CycleKey(e.HostId, e.CycleStartUtc)
				evTime := now
				if ns, perr := strconv.ParseInt(v[0], 10, 64); perr == nil {
					evTime = time.Unix(0, ns)
				}
				view.ObserveCycle(key, e.OverallStatus, evTime)
				if e.BaseUrl != "" && (latestBaseAt[e.HostId].IsZero() || evTime.After(latestBaseAt[e.HostId])) {
					latestBase[e.HostId] = e.BaseUrl
					latestBaseAt[e.HostId] = evTime
				}
				if hostpoll.IsTerminal(e.OverallStatus) && view.CountTerminal(key, e.HostId, e.OverallStatus == "pass") {
					if e.OverallStatus != "pass" {
						// Seed the incident fail-window with recent fails so an
						// incident in progress at restart is reconstructed (with its class;
						// "unknown" for legacy lines that predate the failureClass field).
						if evTime.After(now.Add(-s.incidentWin)) {
							cls := e.FailureClass
							if cls == "" {
								cls = "unknown"
							}
							currentID := view.CanonicalHostID(e.HostId)
							view.FailWindow[currentID] = append(view.FailWindow[currentID], failRec{At: evTime, Class: cls})
						}
					}
					restored++
				}
			}
		}
		// Re-seed the volatile host view: each hostId with a recovered last-known IP
		// becomes a probe candidate for the first poll (skips any already in the view).
		seeded := 0
		for hid, base := range latestBase {
			if s.seedHostStubLocked(view, hid, base, now) {
				seeded++
			}
		}
		// The query returns newest-first; sort each seeded window ascending (the live
		// append path is already chronological) for correct pruning + peak math.
		// Open incidents are NOT reconstructed here -- they are restored from the
		// authoritative incident feed (rehydrateIncidentsFromLoki) so their original
		// id + startedAt survive, including incidents currently below the open
		// threshold whose hysteresis state the fail window alone can't recover.
		for _, fw := range view.FailWindow {
			sort.Slice(fw, func(i, j int) bool { return fw[i].At.Before(fw[j].At) })
		}
		if restored > 0 {
			log.Print(operatorMessage("aggregator.log_rehydrate_restored_value1_terminal_cycle_counts_from_l_de930fa3", map[string]any{"value1": fmt.Sprintf("%d", restored), "value2": fmt.Sprintf("%s", window)}))
		}
		if seeded > 0 {
			log.Print(operatorMessage("aggregator.log_rehydrate_re_seeded_value1_host_s_from_transition_base_4a5fd67e", map[string]any{"value1": fmt.Sprintf("%d", seeded), "value2": fmt.Sprintf("%s", window)}))
		}
		if capped >= 5000 {
			log.Print(operatorMessage("aggregator.log_rehydrate_warning_hit_the_5000_line_query_cap_counts_o_08375cc0", nil))
		}
	})
}

// rehydrateIncidentsFromLoki restores OPEN incidents from the authoritative
// incident lifecycle feed ({pool,src=incident}) on startup, so a restart keeps
// each incident's ORIGINAL id + startedAt -- the eventual incident_resolved then
// pairs with its open line and reports the true duration. An incident is
// restored whenever the LATEST lifecycle line for a host is incident_open
// (regardless of the current fail count, so a sub-threshold-but-still-open
// incident survives the restart). Best-effort: any Loki error leaves incidents
// empty and they simply re-open on the next qualifying fail burst.
func (s *poolState) rehydrateIncidentsFromLoki(lokiPushURL, pool string, window time.Duration, now time.Time) {
	queryURL := queryRangeURL(lokiPushURL)
	params := url.Values{}
	// Per-host incidents use the host's pool label; pool-wide events retain
	// the collector label. Both belong to the same restart projection.
	params.Set("query", `{pool=~".+", src="incident"} | json`)
	params.Set("start", strconv.FormatInt(now.Add(-window).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "5000")
	params.Set("direction", "backward") // newest-first: the first line per host stream is the latest

	client := newInternalHTTPClient(pushTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Print(operatorMessage("aggregator.log_rehydrate_incidents_loki_query_value1_62f316f1", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var lr lokiStreamsResult
	if err := json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&lr); err != nil {
		log.Print(operatorMessage("aggregator.log_rehydrate_incidents_parse_value1_6c2aee5f", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}

	streams := make([][][2]string, 0, len(lr.Data.Result))
	for _, st := range lr.Data.Result {
		streams = append(streams, st.Values)
	}
	if n := s.applyIncidentLines(streams, now); n > 0 {
		log.Print(operatorMessage("aggregator.log_rehydrate_restored_value1_open_incident_s_from_loki_9bcd828c", map[string]any{"value1": fmt.Sprintf("%d", n)}))
	}
	s.applyPoolAlertLines(lr.Data.Result)
}

// applyPoolAlertLines restores the pool alert latches that were firing when the
// collector stopped, from the kind=alert lines of the same incident feed. Without
// it a restart forgets a firing alert: a pool still degraded fires a second alert
// under a new id -- paging again -- and the first one's lifecycle never closes.
// The latest line per pool label decides: a pool_alert_fired restores the latch
// with its original id and start, so the eventual rearm pairs with it. Takes the view's lock.
func (s *poolState) applyPoolAlertLines(streams []lokiStream) int {
	type latest struct {
		ns    int64
		event string
		id    string
		start string
	}
	byPool := map[string]latest{}
	for _, st := range streams {
		if st.Stream["kind"] != "alert" || st.Stream["scope"] != "pool" || st.Stream["pool"] == "" {
			continue
		}
		pool := st.Stream["pool"]
		for _, v := range st.Values {
			ns, err := strconv.ParseInt(v[0], 10, 64)
			if err != nil || ns <= byPool[pool].ns {
				continue
			}
			var e struct {
				Event      string `json:"event"`
				IncidentId string `json:"incidentId"`
				StartedAt  string `json:"startedAt"`
			}
			if json.Unmarshal([]byte(v[1]), &e) != nil || (e.Event != "pool_alert_fired" && e.Event != "pool_alert_rearmed") {
				continue
			}
			byPool[pool] = latest{ns: ns, event: e.Event, id: e.IncidentId, start: e.StartedAt}
		}
	}
	restored := 0
	s.st.Do(func(view *poolstate.View) {
		for pool, l := range byPool {
			if l.event != "pool_alert_fired" || l.id == "" {
				continue
			}
			started, err := time.Parse(time.RFC3339, l.start)
			if err != nil {
				continue
			}
			gate := view.PoolGate[pool]
			if gate == nil {
				gate = &poolGateState{}
				view.PoolGate[pool] = gate
			}
			gate.Authored, gate.AlertFired, gate.AlertID, gate.AlertStartedAt = true, true, l.id, started
			restored++
		}
	})
	return restored
}

// applyIncidentLines restores open incidents (per-host and pool-wide) from the
// incident-feed streams -- each element is one Loki stream's [ts,line] values,
// newest-first. The most recent line per host, and the most recent pool-scoped
// line, decides current state (a trailing resolve means "not in incident").
// Split out from the HTTP fetch in rehydrateIncidentsFromLoki so it is
// unit-testable without a live Loki. Takes the view's lock.
//
// "Most recent" is decided across streams by timestamp, not by the order Loki
// lists the streams in: one host can own several incident streams -- the history
// backfill writes each replayed incident to a stream of its own, and a host that
// changed pools has one per pool -- and an old resolved incident listed first
// must not hide the open one that is newer.
func (s *poolState) applyIncidentLines(streams [][][2]string, now time.Time) int {
	type stampedLine struct {
		ns   int64
		line string
	}
	var lines []stampedLine
	for _, values := range streams {
		for _, v := range values {
			ns, _ := strconv.ParseInt(v[0], 10, 64)
			lines = append(lines, stampedLine{ns: ns, line: v[1]})
		}
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].ns > lines[j].ns })

	restored := 0
	s.st.Do(func(view *poolstate.View) {
		decided := map[string]bool{} // hostId -> latest lifecycle line already applied
		poolDecided := false         // the latest pool-scoped line already applied
		for _, ln := range lines {
			var e struct {
				Event             string         `json:"event"`
				IncidentId        string         `json:"incidentId"`
				HostId            string         `json:"hostId"`
				StartedAt         string         `json:"startedAt"`
				FailCount         int            `json:"failCount"`
				AffectedHostCount int            `json:"affectedHostCount"`
				Class             string         `json:"class"`          // pool-wide triggering class
				DominantClass     string         `json:"dominantClass"`  // per-host dominant class
				ClassHistogram    map[string]int `json:"classHistogram"` // per-host class breakdown
			}
			if json.Unmarshal([]byte(ln.line), &e) != nil {
				continue
			}
			parseStarted := func() time.Time {
				if t, perr := time.Parse(time.RFC3339, e.StartedAt); perr == nil {
					return t
				}
				return now
			}
			// Pool-wide lifecycle lines (one stream, scope=pool, no hostId).
			if e.Event == "pool_incident_open" || e.Event == "pool_incident_resolved" {
				if poolDecided {
					continue
				}
				poolDecided = true
				if e.Event == "pool_incident_open" {
					started := parseStarted()
					id := e.IncidentId
					if id == "" {
						id = incident.PoolID(started)
					}
					cls := e.Class
					if cls == "" {
						cls = "unknown" // legacy open line predating same-class cross-host
					}
					view.PoolIncident = &poolIncidentState{ID: id, StartedAt: started, PeakHosts: e.AffectedHostCount, Class: cls}
					restored++
				}
				continue
			}
			// Per-host lifecycle lines.
			if e.HostId == "" || view.ReplacedBy(e.HostId) != "" || decided[e.HostId] {
				continue // only the most recent line per host decides current state
			}
			decided[e.HostId] = true
			if e.Event != "incident_open" {
				continue // latest line is a resolve (or unknown) -> host not in incident
			}
			started := parseStarted()
			id := e.IncidentId
			if id == "" {
				id = incident.ID(e.HostId, started)
			}
			peak := e.FailCount
			hist := e.ClassHistogram
			dom := e.DominantClass
			if n := len(view.FailWindow[e.HostId]); n > peak {
				// The live window is larger than the restored snapshot -> recompute
				// BOTH the histogram AND its dominant from the live window so they
				// agree (mirrors evaluateIncidents). Recomputing only the histogram
				// would leave dominantClass stale vs peakClassHist after a post-open
				// class shift, misclassifying the metric/Loki/dashboard.
				peak = n
				hist = incident.ClassHistogram(view.FailWindow[e.HostId])
				dom = incident.DominantClass(hist)
			}
			if len(hist) == 0 {
				hist = map[string]int{}
			}
			if dom == "" {
				dom = incident.DominantClass(hist) // legacy open line predating the class histogram
			}
			if dom == "" {
				dom = "unknown"
			}
			view.Incident[e.HostId] = &incidentState{ID: id, StartedAt: started, Peak: peak, PeakClassHist: hist, DominantClass: dom}
			restored++
		}
	})
	return restored
}

// rehydrateHostPresenceFromLoki re-seeds the collector's VOLATILE in-memory host
// view from the {src=presence} beacon feed on startup, so a host discovered before
// a restart is re-probed at its last-known IP even when it is generating no fresh
// proxy traffic (a paused runner, or a stash-only host that runs no test cycles and
// so emits no {src=cycle} transition for rehydrateFromLoki to seed from). Without
// this a restart drops such a host from the dashboard until it next pulls through
// the proxy -- the discovery-liveness gap. Best-effort: any Loki error leaves the
// view to rebuild from the squid log.
func (s *poolState) rehydrateHostPresenceFromLoki(lokiPushURL, pool string, window time.Duration, now time.Time) {
	queryURL := queryRangeURL(lokiPushURL)
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q, src="presence"} | json`, pool))
	params.Set("start", strconv.FormatInt(now.Add(-window).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "5000")
	params.Set("direction", "backward") // newest-first: the first line per host stream is the latest

	client := newInternalHTTPClient(pushTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Print(operatorMessage("aggregator.log_rehydrate_presence_loki_query_value1_5ba034a0", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var lr lokiStreamsResult
	if json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&lr) != nil {
		return
	}
	streams := make([][][2]string, 0, len(lr.Data.Result))
	for _, st := range lr.Data.Result {
		streams = append(streams, st.Values)
	}
	if n := s.applyPresenceLines(streams, now); n > 0 {
		log.Print(operatorMessage("aggregator.log_rehydrate_re_seeded_value1_host_s_from_the_presence_fe_b6c9e59f", map[string]any{"value1": fmt.Sprintf("%d", n)}))
	}
}

// applyPresenceLines seeds unreachable host stubs from the presence-beacon streams
// -- each element is one Loki stream's [ts,line] values, newest-first. A host has a
// single presence stream, so the FIRST line seen per hostId is its newest address.
// Split from the HTTP fetch (like applyIncidentLines) so it is unit-testable without
// a live Loki. Takes the view's lock.
func (s *poolState) applyPresenceLines(streams [][][2]string, now time.Time) int {
	seeded := 0
	s.st.Do(func(view *poolstate.View) {
		decided := map[string]bool{} // hostId -> newest presence line already applied
		for _, values := range streams {
			for _, v := range values { // newest-first within a stream
				var e struct {
					HostId  string `json:"hostId"`
					BaseUrl string `json:"baseUrl"`
				}
				if json.Unmarshal([]byte(v[1]), &e) != nil || e.HostId == "" || e.BaseUrl == "" {
					continue
				}
				if decided[e.HostId] {
					continue // only the newest line per host decides the seed IP
				}
				decided[e.HostId] = true
				if s.seedHostStubLocked(view, e.HostId, e.BaseUrl, now) {
					seeded++
				}
			}
		}
	})
	return seeded
}

// rehydrateAnnouncesFromLoki restores self-announced extensions from the
// {src=announce} feed on startup, so a collector restart keeps the Extension
// hosts rows of services whose beacons are alive -- WITHOUT waiting up to one
// beacon period for the next hello. The query window is announceTtl, not the
// full rehydrate window: any line older than the TTL is stale by definition.
// Best-effort: on any Loki error the entries rebuild from live beacons.
func (s *poolState) rehydrateAnnouncesFromLoki(lokiPushURL, pool string, now time.Time) {
	if s.announceTtl <= 0 {
		return
	}
	queryURL := queryRangeURL(lokiPushURL)
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q, src="announce"} | json`, pool))
	params.Set("start", strconv.FormatInt(now.Add(-s.announceTtl).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "5000")
	params.Set("direction", "backward") // newest-first: the first line per (hostId,area) is the latest

	client := newInternalHTTPClient(pushTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Print(operatorMessage("aggregator.log_rehydrate_announces_loki_query_value1_99a0159c", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var lr lokiStreamsResult
	if json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&lr) != nil {
		return
	}
	streams := make([][][2]string, 0, len(lr.Data.Result))
	for _, st := range lr.Data.Result {
		streams = append(streams, st.Values)
	}
	if n := s.applyAnnounceLines(streams, now); n > 0 {
		log.Print(operatorMessage("aggregator.log_rehydrate_restored_value1_self_announced_extension_s_f_e79d2b5f", map[string]any{"value1": fmt.Sprintf("%d", n)}))
	}
}

// applyAnnounceLines restores announce entries from {src=announce} streams --
// each element one Loki stream's [ts,line] values, newest-first. The newest
// line per (hostId, area) decides: active restores the entry with the LINE's
// timestamp as its freshness (so the TTL reap stays truthful), a goodbye
// leaves it absent. Values are re-validated with the same gates as a live
// announce -- Loki retention is not a trust boundary. Split from the HTTP
// fetch so it is unit-testable without a live Loki. Takes the view's lock.
func (s *poolState) applyAnnounceLines(streams [][][2]string, now time.Time) int {
	restored := 0
	s.st.Do(func(view *poolstate.View) {
		decided := map[string]bool{}
		for _, values := range streams {
			for _, v := range values { // newest-first within a stream
				var e struct {
					HostId string `json:"hostId"`
					Area   string `json:"area"`
					Target string `json:"target"`
					Active bool   `json:"active"`
				}
				if json.Unmarshal([]byte(v[1]), &e) != nil ||
					!announceHostIDRE.MatchString(e.HostId) || !announceAreaRE.MatchString(e.Area) {
					continue
				}
				key := announceKey(e.HostId, e.Area)
				if decided[key] {
					continue
				}
				decided[key] = true
				if !e.Active || view.Announce[key] != nil || len(view.Announce) >= maxAnnounce {
					continue
				}
				// Only a parseable http(s) URL may ride into the /go/stash redirect;
				// anything else restores as presence-only (no link).
				target := strings.TrimRight(strings.TrimSpace(e.Target), "/")
				if u, perr := url.Parse(target); perr != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
					target = ""
				}
				ts := now
				if ns, perr := strconv.ParseInt(v[0], 10, 64); perr == nil {
					ts = time.Unix(0, ns)
				}
				view.Announce[key] = &announceView{
					HostId: e.HostId, Area: e.Area, Target: target,
					LastSeenUnixMs: ts.UnixMilli(),
					// Historical evidence has no live connection source. The next
					// beacon binds the current owner and raises its source rank.
					SourceIP: "",
				}
				restored++
			}
		}
	})
	return restored
}

// hostnameEventKeys are the NDJSON event fields scrubbed from each forwarded
// event line: the literal `hostname`, and `cycleFolder`. New cycle folders are
// named with the opaque hostId, so cycleFolder is hostname-free at the source;
// scrubbing it is defense-in-depth that also covers a legacy folder name (created
// before a host adopted hostId naming, which embedded the hostname). Keeps the
// unauthenticated pool dashboard's event drill-down hostname-free; the host's own
// status page keeps the full detail.
var hostnameEventKeys = []string{"hostname", "cycleFolder"}

// redactEventLine removes hostnameEventKeys from one NDJSON event line before it
// is shipped to Loki. It unmarshals, deletes the keys, and re-marshals; Go sorts
// map keys, so the output is deterministic and re-forwarding the same source line
// stays an exact Loki duplicate (idempotent dedup across collector restarts is
// preserved). A line that is not a JSON object -- or that carries none of the
// keys -- is forwarded byte-for-byte unchanged (host events are well-formed JSON;
// this only guards a truncated tail and avoids needless reformatting).
func redactEventLine(ln string) string {
	var m map[string]any
	if err := json.Unmarshal([]byte(ln), &m); err != nil {
		return ln
	}
	changed := false
	for _, k := range hostnameEventKeys {
		if _, ok := m[k]; ok {
			delete(m, k)
			changed = true
		}
	}
	if !changed {
		return ln
	}
	b, err := json.Marshal(m)
	if err != nil {
		return ln
	}
	return string(b)
}

// tailEvents pulls a host's current-cycle NDJSON event file
// (<baseUrl>/<cycleFolderUrl>cycle.events.ndjson) and ships any lines beyond the
// per-host byte cursor to Loki under {pool,hostId,src=event}. This is the
// incident drill-down feed: step_failure/step_end and the typed sub-events
// become queryable cross-host. The Loki entry timestamp is the event's
// OWN `timestamp`, so a collector restart that re-pushes the in-flight cycle is
// idempotent (Loki drops exact (ts,line) duplicates). The cursor avoids
// re-pushing within a running instance and resets when the cycleStartUtc changes.
// Best-effort + bounded: a missing/oversized file or a Loki error is logged
// and skipped; it never blocks the poll.
func (s *poolState) tailEvents(client *http.Client, lokiURL, poolLabel, hostID, baseURL, cycleID, cycleFolderURL string, now time.Time) {
	u := strings.TrimRight(baseURL, "/") + "/" + strings.TrimLeft(cycleFolderURL, "/")
	if !strings.HasSuffix(u, "/") {
		u += "/"
	}
	u += eventsFile

	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return
	}
	cur := s.eventCur[hostID]
	if cur == nil || cur.cycleStartUtc != cycleID {
		cur = &eventCursor{cycleStartUtc: cycleID}
		s.eventCur[hostID] = cur
	}
	if cur.offset > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", cur.offset))
	}
	resp, err := client.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusRequestedRangeNotSatisfiable {
		cur.offset = 0 // the same-cycle file shrank; retry from its current beginning
		return
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		return
	}
	if resp.StatusCode == http.StatusPartialContent {
		if !strings.HasPrefix(resp.Header.Get("Content-Range"), fmt.Sprintf("bytes %d-", cur.offset)) {
			return
		}
	} else if cur.offset > 0 {
		// The host may not support Range. Discard the old prefix without retaining
		// it, so the bounded fetch still reaches events past the first 4 MiB.
		if _, err := io.CopyN(io.Discard, resp.Body, cur.offset); err != nil {
			if err == io.EOF {
				cur.offset = 0
			}
			return
		}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxEventFetch))
	if err != nil {
		return
	}

	if len(body) == 0 {
		return
	}
	chunk := body
	// Ship only COMPLETE lines (ending in \n); keep any trailing partial for the
	// next poll by advancing the cursor exactly past the bytes we forward.
	var lines []string
	consumed := 0
	for consumed < len(chunk) {
		nl := bytes.IndexByte(chunk[consumed:], '\n')
		if nl < 0 {
			break
		}
		ln := strings.TrimRight(string(chunk[consumed:consumed+nl]), "\r")
		consumed += nl + 1
		if ln != "" {
			lines = append(lines, redactEventLine(ln))
		}
		if len(lines) >= maxEventPush {
			break
		}
	}
	if len(lines) == 0 {
		cur.offset += int64(consumed)
		return
	}
	s.applyFootprintLines(hostID, lines, now)
	// The cursor moves past these bytes only once their lines are held for Loki;
	// otherwise the next poll reads and sends them again (Loki drops the exact
	// duplicates a partial earlier attempt may have delivered).
	if err := s.pushEvents(client, lokiURL, poolLabel, hostID, lines, now); err != nil {
		return
	}
	cur.offset += int64(consumed)
}

// applyFootprintLines picks this host's address-footprint verdict out of the
// event lines already being forwarded, so the reading costs one extra pass over
// bytes that were fetched anyway rather than a second request per host.
//
// Last line wins: the cycle emits one of these at close, so within a chunk the
// newest is the current answer. Takes the view's lock.
func (s *poolState) applyFootprintLines(hostID string, lines []string, now time.Time) {
	var latest *addressFootprintView
	for _, ln := range lines {
		var e struct {
			Event    string `json:"event"`
			Verdict  string `json:"verdict"`
			Severity string `json:"severity"`
			Changes  *int   `json:"changes"`
			Distinct *int   `json:"distinctAddresses"`
			Backend  string `json:"identityBackend"`
			// Pointer, so the tri-state survives the wire: absent/null is "the
			// bridge could not be read", which is a different fact from false
			// and picks a different remedy. A plain bool would silently fold
			// the unreadable case onto "not pinned" and send an operator to fix
			// something that may already be correct.
			Pinned *bool `json:"identityPinned"`
		}
		if json.Unmarshal([]byte(ln), &e) != nil || e.Event != "host_address_footprint" {
			continue
		}
		v := &addressFootprintView{
			Verdict: e.Verdict, Severity: e.Severity, Backend: e.Backend,
			Changes: -1, Distinct: 0, Pinned: -1, Observed: now,
		}
		if e.Changes != nil {
			v.Changes = *e.Changes
		}
		if e.Distinct != nil {
			v.Distinct = *e.Distinct
		}
		if e.Pinned != nil {
			if *e.Pinned {
				v.Pinned = 1
			} else {
				v.Pinned = 0
			}
		}
		latest = v
	}
	if latest == nil {
		return
	}
	s.st.Do(func(view *poolstate.View) { view.SetFootprint(hostID, *latest) })
}

// pushEvents ships NDJSON event lines for one host to Loki under
// {pool,hostId,src=event}. Each Loki entry timestamp is the event's own
// `timestamp` field, so re-pushing an identical line is an exact-duplicate no-op
// (idempotent across collector restarts). Within-second events share a Loki
// timestamp (distinct lines, both retained) -- second resolution is fine for
// drill-down, and the precise time stays in the line. Falls back to the ingest
// clock for any line whose timestamp won't parse.
func (s *poolState) pushEvents(client *http.Client, lokiURL, pool, hostID string, lines []string, ingest time.Time) error {
	if len(lines) == 0 {
		return nil
	}
	values := make([][]string, 0, len(lines))
	for _, ln := range lines {
		values = append(values, []string{strconv.FormatInt(eventNano(ln, ingest), 10), ln})
	}
	payload := map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": pool, "hostId": hostID, "src": "event"},
		"values": values,
	}}}
	return s.queueLoki(client, lokiURL, payload, "event push")
}

// eventNano returns the event's own timestamp in unix-nanoseconds, or the
// fallback (ingest clock) when the line has no parseable RFC3339 `timestamp`.
func eventNano(line string, fallback time.Time) int64 {
	var e struct {
		Timestamp string `json:"timestamp"`
	}
	if json.Unmarshal([]byte(line), &e) == nil && e.Timestamp != "" {
		if t, perr := time.Parse(time.RFC3339, e.Timestamp); perr == nil {
			return t.UnixNano()
		}
	}
	return fallback.UnixNano()
}

// pushIncident ships one incident lifecycle line to Loki under
// {pool,hostId,src=incident} -- the feed behind the dashboard incident strip.
func (s *poolState) pushIncident(client *http.Client, lokiURL, pool string, ev incidentEvent) {
	stream, line := incident.StreamLine(pool, ev)
	payload := map[string]any{"streams": []map[string]any{{
		"stream": stream,
		"values": [][]string{{strconv.FormatInt(ev.Now.UnixNano(), 10), string(line)}},
	}}}
	_ = s.queueLoki(client, lokiURL, payload, "incident push")
}

func (s *poolState) handleHealth(w http.ResponseWriter, _ *http.Request) {
	_, _ = io.WriteString(w, "ok\n")
}

func (s *poolState) handlePoolStatus(w http.ResponseWriter, r *http.Request) {
	var body []byte
	var err error
	s.st.Do(func(view *poolstate.View) {
		out := struct {
			Pool        string            `json:"pool"`
			LastPollUTC string            `json:"lastPollUtc"`
			Hosts       []poolStatusEntry `json:"hosts"`
			// AnnouncedExtensions lists every live self-announce (POST /announce),
			// including ones whose hostId is not in the host view at all -- the
			// observable a service-only signal leaves when its host is dark.
			AnnouncedExtensions []*announceView `json:"announcedExtensions,omitempty"`
		}{Pool: s.pool}
		if !view.LastPoll().IsZero() {
			out.LastPollUTC = view.LastPoll().UTC().Format(time.RFC3339)
		}
		ids := make([]string, 0, len(view.Hosts))
		for id := range view.Hosts {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		// Merge once for the whole snapshot, not once per host: the resolution is
		// pool-wide, and rebuilding it inside the loop would be quadratic in hosts.
		now := time.Now()
		cands := s.extensionCandidatesLocked(view, now)
		for _, id := range ids {
			if view.ReplacedBy(id) != "" {
				continue
			}
			hv := view.Hosts[id]
			// stashBaseUrl: the stash UI's hostId->URL lookup key, resolved through
			// the same merge the dashboard cell and /go/stash use so the three
			// cannot disagree.
			stash := cands[announceKey(id, stashArea)].Target
			previous := view.RetiredIDs(id)
			sort.Strings(previous)
			out.Hosts = append(out.Hosts, poolStatusEntry{hostView: hv, StashBaseURL: stash, PreviousHostIDs: previous, Refresh: hv.RefreshView(now, s.refreshTTL)})
		}
		annKeys := make([]string, 0, len(view.Announce))
		for k := range view.Announce {
			annKeys = append(annKeys, k)
		}
		sort.Strings(annKeys)
		for _, k := range annKeys {
			out.AnnouncedExtensions = append(out.AnnouncedExtensions, view.Announce[k])
		}
		// Marshal while still holding the lock: out.Hosts holds *hostView/*hostStatus pointers that
		// the poll goroutine mutates, so encoding them after Unlock is a data race (torn JSON / crash
		// under -race). Serialize to bytes under the lock, then release and write.
		body, err = json.Marshal(out)
	})
	if err != nil {
		localizedHTTPError(w, r, "aggregator.failed_to_encode_pool_status", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

// promTargetGroup is one entry of the Prometheus scrape document: the addresses
// to scrape, plus the labels every series read from them carries.
type promTargetGroup struct {
	Targets []string          `json:"targets"`
	Labels  map[string]string `json:"labels"`
}

// handlePrometheusTargets serves the pool's reachable supported hosts as a
// Prometheus HTTP service-discovery document, labeled like the pool exposition
// so machine series join pool series on hostId. Open, like
// /api/v1/pool-status. See https://yuruna.link/42c29d04-0009.
func (s *poolState) handlePrometheusTargets(w http.ResponseWriter, r *http.Request) {
	var groups []promTargetGroup
	s.st.Do(func(view *poolstate.View) {
		ids := make([]string, 0, len(view.Hosts))
		for id := range view.Hosts {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		// Every value is copied out under the lock: the poll goroutine mutates the
		// hostView/hostStatus these read, so nothing may hold a pointer past Unlock.
		groups = make([]promTargetGroup, 0, len(ids))
		for _, id := range ids {
			hv := view.Hosts[id]
			if hv == nil || !hv.Reachable || hv.CurrentIP == "" || hv.Status == nil {
				continue
			}
			var target string
			switch {
			case strings.HasPrefix(hv.Status.Host, windowsHostTypePrefix):
				target = net.JoinHostPort(hv.CurrentIP, strconv.Itoa(s.hostMetricsPort))
			case strings.HasPrefix(hv.Status.Host, "host.ubuntu."), strings.HasPrefix(hv.Status.Host, "host.macos."):
				// Unix memory metrics share the confirmed status listener. Its
				// announced port can differ from the pool-wide probe port.
				statusURL, err := url.Parse(hv.BaseURL)
				if err != nil || statusURL.Host == "" || statusURL.Scheme != "http" {
					continue
				}
				target = statusURL.Host
			default:
				continue
			}
			groups = append(groups, promTargetGroup{
				Targets: []string{target},
				Labels: map[string]string{
					"pool":         s.poolFor(view, id),
					"hostId":       id,
					"hostIdDashed": dashedHostID(id),
					"hostType":     hv.Status.Host,
				},
			})
		}
	})

	body, err := json.Marshal(groups)
	if err != nil {
		localizedHTTPError(w, r, "aggregator.failed_to_encode_scrape_targets", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

// The two ways an area's address reaches the aggregator, as they appear in
// extensionHostEntry.Source and in /api/v1/extension-hosts.
const (
	extSourceRegistration = "registration"
	extSourceAnnounce     = "announce"
)

// extensionHostEntry is one resolved extension service in the
// /api/v1/extension-hosts answer: where the pool currently believes an area is
// served, and on whose word. Host is the bare address a consumer builds its own
// URLs from ("192.168.7.227"); Target is the advertised base URL verbatim.
type extensionHostEntry struct {
	Area           string `json:"area"`
	Host           string `json:"host"`
	Target         string `json:"target"`
	HostId         string `json:"hostId,omitempty"`
	Source         string `json:"source"` // "registration" | "announce"
	LastSeenUnixMs int64  `json:"lastSeenUnixMs,omitempty"`
	// SupersededTarget is the address the OTHER source claimed for the same
	// (hostId, area) when the two disagreed. Present only on a disagreement, so
	// an operator looking at a link that works can still see what the losing
	// source was advertising -- the whole diagnosis, without correlating two
	// files across two machines.
	SupersededTarget string `json:"supersededTarget,omitempty"`
	// Suppressed marks an entry the pool KNOWS ABOUT but refuses to hand out:
	// the address it advertises is one this aggregator has never reached, or one
	// it has stopped reaching for longer than extensionHealthGrace. Target and
	// Host are blank on a suppressed entry -- nothing may resolve through it --
	// while SuppressedTarget keeps the refused address and SuppressReason says
	// why, because an operator staring at a host that "runs a stash service" the
	// pool will not use needs the address and the reason in the same place.
	Suppressed       bool   `json:"suppressed,omitempty"`
	SuppressedTarget string `json:"suppressedTarget,omitempty"`
	SuppressReason   string `json:"suppressReason,omitempty"`
	// Healthy is whether the LAST probe of this address succeeded, and
	// LastOkUnixMs when one last did. A published entry with Healthy false is
	// inside its grace: confirmed once, currently not answering -- and LastError
	// is what the current failure streak reports.
	Healthy      bool   `json:"healthy,omitempty"`
	LastOkUnixMs int64  `json:"lastOkUnixMs,omitempty"`
	LastError    string `json:"lastError,omitempty"`
	// confirmed marks an announce this aggregator received itself, whose target
	// was derived from the sender's own source address. False for a
	// registration (a value the owning host computed and wrote to a file we
	// read) and for an announce rehydrated out of Loki (history, not a live
	// sender). Ranking, not serialization -- it is a property of how we learned
	// the address, not of the service.
	confirmed bool
}

// advertised is the address this entry's source named, suppressed or not: what
// to probe, and what to report as refused.
func (e extensionHostEntry) advertised() string {
	if e.Suppressed {
		return e.SuppressedTarget
	}
	return e.Target
}

// extensionTargetProblem reports why an advertised extension address can never
// be a pool service address, or "" when it is at least plausible. The cheap half
// of the registration check -- the reachability probe is the other half -- and it
// catches the values that are wrong on their face: anything that is not an
// http(s) URL, and any address no other machine could route to. A host that
// resolved 127.0.0.1 for its service is advertising, to every consumer, that
// consumer's own machine.
//
// A name is not judged here: the probe is the only thing that can say whether it
// resolves to something the pool can reach.
func extensionTargetProblem(target string) string {
	t := strings.TrimSpace(target)
	if t == "" {
		return "" // presence without an address -- nothing to check
	}
	u, err := url.Parse(t)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
		return "not an http(s) URL"
	}
	ip := net.ParseIP(u.Hostname())
	if ip == nil {
		return ""
	}
	switch {
	case ip.IsUnspecified():
		return "unspecified address"
	case ip.IsLoopback():
		return "loopback address (reachable only from the host that advertised it)"
	case ip.IsLinkLocalUnicast(), ip.IsLinkLocalMulticast():
		return "link-local address"
	case ip.IsMulticast():
		return "multicast address"
	case ip.Equal(net.IPv4bcast):
		return "broadcast address"
	}
	return ""
}

// probeExtensionTarget confirms an advertised address answers as a service: GET
// <target>/healthz, 200. The same gate the host-side pre-flight
// (Test-StashServiceHost) and the guest workloads apply, asked from the POOL's
// vantage point -- which is the whole point, since a host confirming its own VM
// proves only that the host can reach it.
func probeExtensionTarget(client *http.Client, target string) error {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(target, "/")+extensionHealthPath, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s answered HTTP %d", extensionHealthPath, resp.StatusCode)
	}
	return nil
}

// applyExtensionProbeLocked records one probe verdict against (key, target). A verdict
// for a DIFFERENT address than the one now recorded starts a fresh record: an
// address that changed has to earn its own confirmation. view is the locked pool
// view.
func (s *poolState) applyExtensionProbeLocked(view *poolstate.View, key, target string, probeErr error, now time.Time) {
	h := view.ExtHealth[key]
	if h == nil || h.Target != target {
		h = &extHealthView{Target: target}
		view.ExtHealth[key] = h
	}
	if probeErr == nil {
		h.Confirmed, h.LastOkUnixMs, h.FirstFailUnixMs, h.LastError = true, now.UnixMilli(), 0, ""
		h.RefusedLogged = false
		return
	}
	if h.FirstFailUnixMs == 0 {
		h.FirstFailUnixMs = now.UnixMilli()
	}
	h.LastError = probeErr.Error()
}

// confirmExtensionTarget probes one address and records the verdict, unless the
// pool already has a verdict for that exact address. Called from the announce
// handler so a service that just came up is resolvable immediately instead of
// after the next poll -- and, for the same reason, is NOT re-run on the steady
// re-announces of an address already confirmed. Takes the view's lock itself;
// the probe runs unlocked.
func (s *poolState) confirmExtensionTarget(client *http.Client, key, target string, now time.Time) {
	if client == nil || target == "" || extensionTargetProblem(target) != "" {
		return
	}
	known := false
	s.st.Do(func(view *poolstate.View) {
		h := view.ExtHealth[key]
		known = h != nil && h.Target == target
	})
	if known {
		return
	}
	err := probeExtensionTarget(client, target)
	s.st.Do(func(view *poolstate.View) {
		s.applyExtensionProbeLocked(view, key, target, err, now)
	})
}

// refreshExtensionHealth re-confirms every advertised extension address and
// refuses the ones that have stayed silent past extensionHealthGrace. Runs once
// per poll: the address list is snapshotted under the lock, the probes run
// unlocked and concurrently (a black-holed address costs probeTimeout each), and
// the verdicts are applied under the lock again.
//
// Neither source is removed here. Suppression (see extensionCandidatesLocked)
// is what stops an unreachable address being handed out, and it applies to both:
// a registration-sourced address is re-asserted by its owning host on every poll
// so removing it would achieve nothing, and an announce-sourced one belongs to a
// service that is most likely still up at an address it has yet to re-announce.
// Removal is left to the announce TTL, a goodbye, or the owning host retracting
// its marker -- which Stop-StashServiceVM does.
func (s *poolState) refreshExtensionHealth(client *http.Client, now time.Time) {
	if client == nil {
		return
	}
	type probeTarget struct {
		key, target string
		health      *extHealthView
	}
	var targets []probeTarget
	s.st.Do(func(view *poolstate.View) {
		live := map[string]bool{}
		for key, cand := range s.extensionCandidatesLocked(view, now) {
			live[key] = true
			raw := cand.advertised()
			if raw == "" || extensionTargetProblem(raw) != "" {
				continue
			}
			targets = append(targets, probeTarget{key: key, target: raw, health: view.ExtHealth[key]})
		}
		// Forget verdicts about services the pool no longer lists at all, so the map
		// tracks the live set rather than growing with every service that ever ran.
		for key := range view.ExtHealth {
			if !live[key] {
				delete(view.ExtHealth, key)
			}
		}
	})

	errs := make([]error, len(targets))
	sem := make(chan struct{}, maxExtensionProbe)
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func(i int, t probeTarget) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			errs[i] = probeExtensionTarget(client, t.target)
		}(i, t)
	}
	wg.Wait()

	s.st.Do(func(view *poolstate.View) {
		for i, t := range targets {
			// An announce may confirm a new address while this old probe is out.
			if h := view.ExtHealth[t.key]; h != nil && h != t.health && h.Target != t.target && h.Confirmed {
				continue
			}
			s.applyExtensionProbeLocked(view, t.key, t.target, errs[i], now)
		}
		for key, h := range view.ExtHealth {
			if h.FirstFailUnixMs == 0 || now.UnixMilli()-h.FirstFailUnixMs <= extensionHealthGrace.Milliseconds() {
				continue
			}
			if h.RefusedLogged {
				continue
			}
			h.RefusedLogged = true
			log.Print(operatorMessage("aggregator.log_extension_value1_refusing_value2_for_resolution_unansw_14b41da9", map[string]any{"value1": fmt.Sprintf("%s", key), "value2": fmt.Sprintf("%s", h.Target), "value3": fmt.Sprintf("%s", extensionHealthGrace), "value4": fmt.Sprintf("%s", h.LastError)}))
		}
	})
}

// extensionSourceRank orders the ways an area's address reaches the
// aggregator by the strength of the evidence behind it: 0 a live announce, 1 a
// registration, 2 a rehydrated announce. See https://yuruna.link/42c29d04-0006.
func extensionSourceRank(e extensionHostEntry) int {
	switch {
	case e.Source == extSourceAnnounce && e.confirmed:
		return 0
	case e.Source == extSourceRegistration:
		return 1
	default:
		return 2
	}
}

// betterExtensionCandidate reports whether a should replace b as an area's
// answer: usable (reached, and carrying an address) first, then source rank,
// recency and hostId, so the choice is deterministic. See https://yuruna.link/42c29d04-0006.
func betterExtensionCandidate(a, b extensionHostEntry) bool {
	if a.Suppressed != b.Suppressed {
		return !a.Suppressed
	}
	// Only ever compares two UNSUPPRESSED candidates: a suppressed one already
	// lost above, and two suppressed ones both carry a blank Target (suppression
	// moves it to SuppressedTarget), so this is a no-op for them.
	if (a.Target == "") != (b.Target == "") {
		return a.Target != ""
	}
	if ra, rb := extensionSourceRank(a), extensionSourceRank(b); ra != rb {
		return ra < rb
	}
	if a.LastSeenUnixMs != b.LastSeenUnixMs {
		return a.LastSeenUnixMs > b.LastSeenUnixMs
	}
	return a.HostId < b.HostId
}

// applyExtensionHealthLocked decides whether one candidate's address may be
// handed out, and records why when it may not, in the locked view.
//
// The rule is the same for both sources and has no exceptions: the pool
// advertises an address only after THIS aggregator has reached it. A structural
// impossibility (loopback, link-local, not a URL) is refused outright; anything
// else waits for its first successful probe, which lands within one poll of the
// address being learned -- or immediately, for an announce, since the handler
// confirms a newly announced address before it answers.
//
// Once confirmed, an address survives extensionHealthGrace of silence before it
// is refused again, so a service restart or a dropped packet does not empty the
// panel and stall every cycle that needs the service.
func (s *poolState) applyExtensionHealthLocked(view *poolstate.View, e *extensionHostEntry, now time.Time) {
	if e.Target == "" {
		return // presence without an address: nothing to judge, nothing to hand out
	}
	suppress := func(reason string) {
		e.Suppressed, e.SuppressedTarget, e.SuppressReason, e.Target = true, e.Target, reason, ""
	}
	if why := extensionTargetProblem(e.Target); why != "" {
		suppress(why)
		return
	}
	h := view.ExtHealth[announceKey(e.HostId, e.Area)]
	switch {
	case h == nil || h.Target != e.Target:
		suppress("not yet confirmed by the pool")
	case !h.Confirmed:
		suppress("never answered " + extensionHealthPath + " from the pool: " + h.LastError)
	case h.FirstFailUnixMs != 0 && now.UnixMilli()-h.FirstFailUnixMs > extensionHealthGrace.Milliseconds():
		e.LastOkUnixMs = h.LastOkUnixMs
		suppress("unanswered for more than " + extensionHealthGrace.String() + ": " + h.LastError)
	default:
		e.Healthy, e.LastOkUnixMs, e.LastError = h.FirstFailUnixMs == 0, h.LastOkUnixMs, h.LastError
	}
}

// extensionCandidatesLocked returns the pool's answer for each (hostId, area)
// it knows about, keyed by announceKey, from the locked view. It is the one merge
// of the registration and announce sources that every consumer reads; entries
// with no target, and suppressed entries the pool cannot reach, are kept.
// See https://yuruna.link/42c29d04-0006.
func (s *poolState) extensionCandidatesLocked(view *poolstate.View, now time.Time) map[string]extensionHostEntry {
	best := map[string]extensionHostEntry{}
	consider := func(cand extensionHostEntry) {
		if cand.Area == "" || cand.HostId == "" {
			return
		}
		s.applyExtensionHealthLocked(view, &cand, now)
		cand.Host = hostIPFromBaseURL(cand.Target)
		key := announceKey(cand.HostId, cand.Area)
		cur, ok := best[key]
		if !ok {
			best[key] = cand
			return
		}
		winner, loser := cur, cand
		if betterExtensionCandidate(cand, cur) {
			winner, loser = cand, cur
		}
		// Record the disagreement on the winner. Two sources naming different
		// addresses for one service is the signature of a host whose
		// registration has fallen behind its service, and it is invisible
		// otherwise -- the losing value simply vanishes and the dashboard shows
		// a link that either works or does not, with nothing to say why. Compared
		// on the ADVERTISED addresses so a suppressed loser is still named.
		if la, wa := loser.advertised(), winner.advertised(); la != "" && la != wa {
			winner.SupersededTarget = la
		}
		best[key] = winner
	}
	for hostID, hv := range view.Hosts {
		if hv == nil {
			continue
		}
		// ActiveExtensions is the presence list and ExtensionTargets the address
		// map; they are written together but are separate fields, so take the
		// union rather than assuming one implies the other.
		seen := map[string]bool{}
		for _, area := range hv.ActiveExtensions {
			seen[area] = true
		}
		for area := range hv.ExtensionTargets {
			seen[area] = true
		}
		for area := range seen {
			consider(extensionHostEntry{
				Area: area, Target: hv.ExtensionTargets[area], HostId: hostID,
				Source: extSourceRegistration, LastSeenUnixMs: hv.LastSeenUnixMs,
			})
		}
	}
	for _, av := range view.Announce {
		if av == nil {
			continue
		}
		if s.announceTtl > 0 && now.UnixMilli()-av.LastSeenUnixMs > s.announceTtl.Milliseconds() {
			continue
		}
		consider(extensionHostEntry{
			Area: av.Area, Target: av.Target, HostId: av.HostId,
			Source: extSourceAnnounce, LastSeenUnixMs: av.LastSeenUnixMs,
			// A rehydrated entry carries no source address: it came out of Loki,
			// not off a live connection, so it is not first-hand evidence yet.
			confirmed: av.SourceIP != "",
		})
	}
	return best
}

// resolveExtensionHostsLocked returns the pool's current best address per
// extension area, from the locked view.
//
// This is the read side of the presence data the pool already collects. A host
// that needs the stash service (or pool-control service) but does not run it has no way
// to find it otherwise: the address is not in its config, the service may live
// on another host entirely, and on another subnet -- so the alternative is a
// hard-coded literal that goes stale the first time the service moves. Knowing
// the caching-proxy-service address, which every host already needs, becomes enough to
// find every other service the pool offers.
//
// An area is an ADDRESS question, so a candidate whose target does not yield a
// host is dropped here -- presence without an address answers nothing.
func (s *poolState) resolveExtensionHostsLocked(view *poolstate.View, now time.Time) map[string]extensionHostEntry {
	best := map[string]extensionHostEntry{}
	for _, cand := range s.extensionCandidatesLocked(view, now) {
		if cand.Host == "" {
			continue
		}
		if cur, ok := best[cand.Area]; !ok || betterExtensionCandidate(cand, cur) {
			best[cand.Area] = cand
		}
	}
	return best
}

// extensionTargetForLocked is the address the pool would send a consumer to for
// one host's area, or "" when it knows none, from the locked view. The single
// lookup behind /go/stash and pool-status's stashBaseUrl, so a redirect and the
// stash UI's own hostId->URL map cannot disagree with each other or with the
// dashboard cell.
func (s *poolState) extensionTargetForLocked(view *poolstate.View, hostID, area string, now time.Time) string {
	return s.extensionCandidatesLocked(view, now)[announceKey(hostID, area)].Target
}

// handleExtensionHosts answers "where is area X served in this pool?".
//
// With ?area=<slug> it returns that one area and 404s when the pool knows no
// live host for it -- a consumer must be able to tell "not there" from "here it
// is", because falling back to a guess is what the hard-coded literal already
// did. Without ?area it returns every area the pool knows, so an operator can
// see the whole coordinate set in one call.
//
// Unauthenticated and read-only, like /api/v1/pool-status: it discloses service
// addresses to a caller that is already on the LAN those services listen on.
func (s *poolState) handleExtensionHosts(w http.ResponseWriter, r *http.Request) {
	area := strings.TrimSpace(r.URL.Query().Get("area"))
	now := time.Now()
	pool := s.pool
	var entries, cands map[string]extensionHostEntry
	s.st.Do(func(view *poolstate.View) {
		entries = s.resolveExtensionHostsLocked(view, now)
		cands = s.extensionCandidatesLocked(view, now)
	})

	var payload any
	if area != "" {
		entry, ok := entries[area]
		if !ok {
			localizedHTTPError(w, r, "aggregator.no_live_host_for_that_extension_area", http.StatusNotFound)
			return
		}
		payload = entry
	} else {
		// services lists EVERY (hostId, area) the pool knows, including the
		// suppressed ones areas cannot show -- one area has one answer, and a
		// second host advertising the same area at an address nobody can reach
		// would otherwise be invisible right up until a cycle needs it. This is
		// what Test-Config reads to report "two stash services registered, one
		// unreachable" before a cycle starts rather than after it fails.
		keys := make([]string, 0, len(cands))
		for k := range cands {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		services := make([]extensionHostEntry, 0, len(keys))
		for _, k := range keys {
			services = append(services, cands[k])
		}
		payload = struct {
			Pool     string                        `json:"pool"`
			Areas    map[string]extensionHostEntry `json:"areas"`
			Services []extensionHostEntry          `json:"services"`
		}{Pool: pool, Areas: entries, Services: services}
	}
	body, err := json.Marshal(payload)
	if err != nil {
		localizedHTTPError(w, r, "aggregator.failed_to_encode_extension_hosts", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

// validForgetHostID mirrors the runner-side 42-prefixed 32-hex host.uuid shape
// (test/pool/Remove-PoolHost.ps1, Remove-HostFromPool.ps1) so the forget endpoint
// rejects a typo instead of scanning the maps for a key that cannot exist.
func validForgetHostID(id string) bool {
	if len(id) != 32 || id[0] != '4' || id[1] != '2' {
		return false
	}
	for i := 2; i < len(id); i++ {
		c := id[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

// forgetHost removes every trace of one hostId from the mutex-guarded state that
// drives the per-host metrics (host_info / host_status / host_last_seen_seconds,
// cycles_pass/fail_total, recent_fail_count, host_incident, host_extension). It
// mirrors + extends the poll-loop reaper's per-host cleanup so a forgotten host
// stops appearing on the very next /metrics scrape (then Prometheus staleness
// drops it from the dashboard within a scrape interval). Returns whether the host
// was present in the primary view. eventCur is intentionally left alone -- it is
// owned by the single poll goroutine (touching it here would race), and a leftover
// cursor is harmless (it only ever resumes event tailing if the same hostId
// re-appears). Callers hold NO lock; this takes the view's lock itself.
func (s *poolState) forgetHost(hid string) bool {
	present := false
	s.st.Do(func(view *poolstate.View) {
		_, present = view.Hosts[hid]
		delete(view.Hosts, hid)
		view.DropFootprint(hid)
		delete(view.FailWindow, hid)
		delete(view.Incident, hid)
		// The cycle records are keyed hostId|cycleStartUtc; announce is keyed
		// hostId|area -- drop every composite key belonging to this host.
		view.ForgetCycles(hid)
		prefix := hid + "|"
		for k := range view.Announce {
			if strings.HasPrefix(k, prefix) {
				delete(view.Announce, k)
			}
		}
		// extHealth is keyed the same way; a forgotten host's service must not leave
		// a verdict behind that would pre-confirm an address if the host returns.
		for k := range view.ExtHealth {
			if strings.HasPrefix(k, prefix) {
				delete(view.ExtHealth, k)
			}
		}
	})
	return present
}

// handleForgetHost (POST /api/v1/forget-host?hostId=<42-hex>) manually evicts a
// host from the aggregator's view NOW, instead of waiting out the host TTL --
// e.g. a disposable nested-host cycle or a decommissioned box whose row lingers as
// "unreachable". Bearer-gated with the SAME token as /ingest (a mutating control
// op) and self-disabling (503) when no token is configured. NOTE: a host that is
// still reachable (recent squid traffic, or a live announce inside its window) is
// re-discovered on the next poll, so stop/drain it first -- forget is for a host
// that is genuinely gone.
func (s *poolState) handleForgetHost(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.forget_host_disabled_no_auth_token_configured", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.requireInternalBearer(w, r) {
		return
	}
	hid := strings.TrimSpace(r.URL.Query().Get("hostId"))
	if !validForgetHostID(hid) {
		localizedHTTPError(w, r, "aggregator.hostid_must_be_a_42_prefixed_32_hex_id", http.StatusBadRequest)
		return
	}
	present := s.forgetHost(hid)
	body, err := json.Marshal(struct {
		Forgotten  bool   `json:"forgotten"`
		HostId     string `json:"hostId"`
		WasPresent bool   `json:"wasPresent"`
	}{Forgotten: true, HostId: hid, WasPresent: present})
	if err != nil {
		localizedHTTPError(w, r, "aggregator.failed_to_encode_result", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

// cycleCand is one Loki transition line parsed for /go/cycle's time->cycle match.
type cycleCand struct {
	started, finished, ingest   time.Time
	folderURL, baseURL, cycleID string
}

// pickCycleForTime chooses the cycle whose [started,finished] window contains t;
// failing that (a still-running cycle with no finishedAt, or a gap between cycles)
// it returns the candidate whose timestamp is nearest t. Pure + table-testable;
// ok=false only for empty input. MUST stay free of I/O so the resolver's matching
// is unit-tested without a live Loki.
func pickCycleForTime(cands []cycleCand, t time.Time) (cycleCand, bool) {
	for _, c := range cands {
		if !c.started.IsZero() && !c.finished.IsZero() && !t.Before(c.started) && !t.After(c.finished) {
			return c, true
		}
	}
	best, found := cycleCand{}, false
	var bestDelta time.Duration
	for _, c := range cands {
		ref := c.ingest
		if ref.IsZero() {
			ref = c.started
		}
		if ref.IsZero() {
			continue
		}
		d := ref.Sub(t)
		if d < 0 {
			d = -d
		}
		if !found || d < bestDelta {
			best, bestDelta, found = c, d, true
		}
	}
	return best, found
}

// lookupCycleAt queries the Loki transition feed ({pool,hostId,src=cycle}) for the
// cycle a host was running at time t and returns its results-folder URL + the
// baseURL recorded then. Best-effort + bounded (a 6h window each side, line cap):
// any Loki error or no usable match returns ok=false, and the caller degrades to
// the host's current status root.
func (s *poolState) lookupCycleAt(pool, hostID string, t time.Time) (folderURL, baseURL string, ok bool) {
	if t.IsZero() || s.lokiURL == "" || s.httpClient == nil {
		return "", "", false
	}
	queryURL := queryRangeURL(s.lokiURL)
	const win = 6 * time.Hour
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q, hostId=%q, src="cycle"} | json`, pool, hostID))
	params.Set("start", strconv.FormatInt(t.Add(-win).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(t.Add(win).UnixNano(), 10))
	params.Set("limit", "200")
	params.Set("direction", "backward")

	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		return "", "", false
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", false
	}
	var lr lokiStreamsResult
	if json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&lr) != nil {
		return "", "", false
	}
	var cands []cycleCand
	for _, st := range lr.Data.Result {
		for _, v := range st.Values {
			var e struct {
				StartedAt      string `json:"startedAt"`
				FinishedAt     string `json:"finishedAt"`
				CycleFolderUrl string `json:"cycleFolderUrl"`
				BaseUrl        string `json:"baseUrl"`
				CycleStartUtc  string `json:"cycleStartUtc"`
			}
			if json.Unmarshal([]byte(v[1]), &e) != nil {
				continue
			}
			c := cycleCand{folderURL: e.CycleFolderUrl, baseURL: e.BaseUrl, cycleID: e.CycleStartUtc}
			if ns, perr := strconv.ParseInt(v[0], 10, 64); perr == nil {
				c.ingest = time.Unix(0, ns)
			}
			if tt, perr := time.Parse(time.RFC3339, e.StartedAt); perr == nil {
				c.started = tt
			}
			if tt, perr := time.Parse(time.RFC3339, e.FinishedAt); perr == nil {
				c.finished = tt
			}
			cands = append(cands, c)
		}
	}
	c, found := pickCycleForTime(cands, t)
	if !found || c.folderURL == "" {
		return "", "", false
	}
	return c.folderURL, c.baseURL, true
}

// lastKnownBaseURL returns the most recent baseUrl (host IP) the transition feed
// recorded for a host -- the fallback for resolving a host's address when it is not
// in the live in-memory view (just after a collector restart, or an idle host that
// hasn't been re-discovered yet). Best-effort + bounded -> "".
func (s *poolState) lastKnownBaseURL(pool, hostID string) string {
	if s.lokiURL == "" || s.httpClient == nil {
		return ""
	}
	now := time.Now().UTC()
	queryURL := queryRangeURL(s.lokiURL)
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q, hostId=%q, src="cycle"} | json`, pool, hostID))
	params.Set("start", strconv.FormatInt(now.Add(-s.deepLinkLookback()).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "1")
	params.Set("direction", "backward")

	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		return ""
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var lr lokiStreamsResult
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&lr) != nil {
		return ""
	}
	for _, st := range lr.Data.Result {
		for _, v := range st.Values {
			var e struct {
				BaseUrl string `json:"baseUrl"`
			}
			if json.Unmarshal([]byte(v[1]), &e) == nil && e.BaseUrl != "" {
				return e.BaseUrl
			}
		}
	}
	return ""
}

// resolveHostBase resolves a hostId to the host's CURRENT status-page base URL -- the
// uuid->IP step shared by the dashboard deep-links (/go/cycle and /go/host). Prefers
// the live in-memory IP (freshest -- survives an IP change), else the last IP the Loki
// transition feed recorded (host not in the live view, e.g. just after a collector
// restart, before re-discovery). Returns "" when the host is unknown to the pool. An
// empty pool is normalized to the host's pool so the Loki fallback can scope its query;
// the normalized pool is returned for callers that need it downstream.
func (s *poolState) resolveHostBase(hostID, pool string) (base, resolvedPool string) {
	var currentID string
	s.st.Do(func(view *poolstate.View) {
		currentID = view.CanonicalHostID(hostID)
		if hv := view.Hosts[currentID]; hv != nil {
			base = hv.BaseURL
		}
		if pool == "" {
			pool = s.poolFor(view, currentID)
		}
	})
	if base == "" {
		base = s.lastKnownBaseURL(pool, currentID)
		if base == "" && currentID != hostID {
			base = s.lastKnownBaseURL(pool, hostID)
		}
	}
	return base, pool
}

// controlProofFor is the deterministic core of the host-control proof: the exact wire
// string "<expiry>.<base64 HMAC>" the host status service accepts on its mutating
// /control/* routes, where HMAC = HMAC-SHA256(internal authentication key, "yuruna-control|proof|
// <expiry>"). It is byte-for-byte identical to Test.ConfigServiceSync\Get-YurunaControlProof
// (PowerShell) -- same HMAC-SHA256, same std base64, same data string -- so a proof minted
// here on the caching-proxy service validates on any pool host (the internal authentication key is pool-wide).
// Verified by TestMintControlProofGolden against the shared golden vector.
func controlProofFor(token string, expiry int64) string {
	return controlproof.Proof(token, expiry)
}

// mintControlProof mints a control proof bound to audience and valid for ttl from now,
// or "" when no internal authentication key is configured (the host then only accepts
// loopback control). The operator reaches the host through Grafana -> /go/host, so this
// rides the proof to the browser in the redirect fragment; the host revalidates it
// (audience, expiry window, HMAC). The audience is the host id for /go/host and
// "svc-<area>" for /go/stash: the key is pool-wide, and the binding is what keeps a
// proof lifted from one address bar from unlocking every host and service.
func mintControlProof(token, audience string, ttl time.Duration) string {
	return controlproof.MintFor(token, audience, ttl)
}

// verifyControlProof is the Go twin of Test.ConfigServiceSync\Test-YurunaControlProof:
// it decides whether a wire proof was minted from token and is still inside its window.
// Parses "<expiry>.<base64 HMAC>", requires now <= expiry <= now+maxTTL (a far-future
// expiry is refused, so a captured token cannot mint an eternal pass), recomputes the
// HMAC over that same expiry and compares in constant time. Any malformed, expired or
// mismatched input is false -- never an error a caller could mistake for a verdict.
//
// audience is the target the caller is: a bound proof must name it, and an empty
// audience (a service that predates audiences) accepts a bound proof for any target.
// An unbound proof is accepted while minters that predate audiences remain.
func verifyControlProof(token, wire, audience string, now time.Time, maxTTL time.Duration) bool {
	return controlproof.VerifyFor(token, wire, audience, now, maxTTL)
}

// handleControlProof answers one question for an extension service: was this proof
// minted from the pool's internal authentication key, and is it still live?
//
// An extension service VM is not given the internal authentication key -- nothing bakes that file
// into its seed -- so it holds no key to check an arriving proof against, and a
// service that cannot check one has no way to honor the dashboard's "open this UI
// with actions unlocked" hop. It asks here instead, exactly as it already asks
// /api/v1/lab-token to judge a 6-character code: validation stays with the daemon
// that owns the token, and no service keeps a copy to go stale.
//
// Open, like the exchange next to it, and for a stronger reason: this is a verifier,
// not a mint. It discloses one bit about a string the caller already holds, and a
// caller who could produce a proof that verifies here could have used it directly.
// Self-gates on a configured token (503), because "no token" is not "not valid".
func (s *poolState) handleControlProof(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.control_proof_verification_disabled_this_aggregator_holds_no_inte", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxLabTokenBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var req struct {
		Proof    string `json:"proof"`
		Audience string `json:"audience"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_request", http.StatusBadRequest)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if !verifyControlProof(s.authToken, strings.TrimSpace(req.Proof), strings.TrimSpace(req.Audience), time.Now(), controlProofMaxTTL) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"ok":false}`+"\n")
		return
	}
	_, _ = io.WriteString(w, `{"ok":true}`+"\n")
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

// Control states for the dashboard's Control column (and /api/v1/pool-status).
// Only controlReady means the Host link will actually grant control; the rest
// name WHY it will not, which is the difference the 403 troubleshooting table in
// docs/control-routes.md otherwise makes an operator discover by clicking.
const (
	controlReady    = poolstate.ControlReady
	controlNone     = poolstate.ControlNone
	controlMismatch = poolstate.ControlMismatch
	controlSkew     = poolstate.ControlSkew
	controlUnknown  = poolstate.ControlUnknown
)

// classifyControl decides one host's control state from its control-status
// answer. The skew band is not a guess: handleGoHost mints at controlProofTTL
// and Test-YurunaControlProof accepts up to controlProofMaxTTL, so a host clock
// reading H against proxy time P is accepted exactly while
// H-P is within [-(MaxTTL-TTL), +TTL] -- it may run ahead by the full mint, but
// may trail by only the surplus the verifier holds above it.
func classifyControl(proxyTag string, cs controlStatus, now time.Time) string {
	// Nothing to compare against: this proxy mints no proofs at all (the Lab
	// token tile reads "off"), so whether the host is enrolled is genuinely
	// unknown from here -- and is not this column's story to tell.
	if proxyTag == "" || !cs.Present {
		return controlUnknown
	}
	if !cs.TokenConfigured || cs.TokenTag == "" {
		return controlNone
	}
	if !hmac.Equal([]byte(cs.TokenTag), []byte(proxyTag)) {
		return controlMismatch
	}
	if !cs.UtcNow.IsZero() {
		d := cs.UtcNow.Sub(now)
		if d < -(controlProofMaxTTL-controlProofTTL) || d > controlProofTTL {
			return controlSkew
		}
	}
	return controlReady
}

var labTokenRE = regexp.MustCompile(`^[a-z0-9]{6}$`)

// newLabCode mints one 6-char lab connection token.
//
// The charset deliberately omits i, l, o, 0 and 1. This code is READ off a
// dashboard tile and retyped by hand, and those five are the pairs that get
// read wrong -- which costs everyone, and costs most whoever is reading them
// through a magnifier or hearing them spelled out. Dropping them leaves 31
// characters and 31^6 = 887,503,681 codes, against a per-IP throttle of 10
// attempts per 10 minutes: the guessing math is untouched and the reading is
// materially easier.
//
// Unbiased: the rejection threshold is derived from the charset length rather
// than hardcoded. The previous form (len*7) happened to be the right multiple
// for 36 and would have silently skewed the distribution for any other size.
func newLabCode() (string, error) {
	const charset = "abcdefghjkmnpqrstuvwxyz23456789"
	// Largest multiple of len(charset) that fits in a byte; candidates at or
	// above it are discarded rather than folded, so no code is likelier than
	// another.
	limit := byte(256 - (256 % len(charset)))
	out := make([]byte, 0, labTokenLen)
	buf := make([]byte, 1)
	for len(out) < labTokenLen {
		if _, err := rand.Read(buf); err != nil {
			return "", err
		}
		if buf[0] >= limit {
			continue
		}
		out = append(out, charset[buf[0]%byte(len(charset))])
	}
	return string(out), nil
}

// rotateLabToken mints the next lab connection token (retaining labKeepCodes of
// history for the exchange's grace window) and prunes expired throttle records.
// A crypto/rand failure keeps the previous codes live and logs -- enrollment
// degrades to "retry after the next rotation", never to a predictable code.
func (s *poolState) rotateLabToken(now time.Time) {
	code, err := newLabCode()
	if err != nil {
		log.Print(operatorMessage("aggregator.log_lab_token_rotation_failed_value1_keeping_previous_code_e2670350", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}
	cut := now.Add(-labFailWindow)
	s.st.Do(func(view *poolstate.View) { view.RotateLabCode(code, labKeepCodes, cut) })
}

// sealLabToken wraps the shared token for one redeemer: AES-256-GCM under a key
// PBKDF2-derived from the redeemed code plus a fresh salt. The wire shape mirrors
// Protect-ConfigSyncCredential (v/salt/nonce/ciphertext/tag, all base64), and
// Test.ConfigServiceSync\Unprotect-LabTokenEnvelope is the twin that opens it.
//
// This is what authenticates the ANSWER. The enrolling host cannot verify the
// aggregator's TLS leaf, so without binding, anything on the path could answer
// the exchange and hand the host a token of its own choosing -- which the host
// would then honor for control proofs, handing that attacker the host. Sealing
// under the code means only the party that knows the displayed code can produce
// a payload the host will accept.
func sealLabToken(code, token string) (map[string]string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	key, err := pbkdf2.Key(sha256.New, code, salt, labEnvelopeIters, 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	// Seal appends the tag to the ciphertext; split it out so the envelope
	// carries the same named fields the PowerShell side already speaks.
	sealed := gcm.Seal(nil, nonce, []byte(token), []byte(labEnvelopeLabel))
	cut := len(sealed) - gcm.Overhead()
	return map[string]string{
		"salt":       base64.StdEncoding.EncodeToString(salt),
		"nonce":      base64.StdEncoding.EncodeToString(nonce),
		"ciphertext": base64.StdEncoding.EncodeToString(sealed[:cut]),
		"tag":        base64.StdEncoding.EncodeToString(sealed[cut:]),
	}, nil
}

// handleLabToken (POST /api/v1/lab-token) exchanges the dashboard-displayed lab
// connection token for the internal authentication key, so enrolling a host is "read
// the 6-char code off the Yuruna hosts dashboard, run test/lab/Set-LabToken.ps1"
// instead of SSHing into the proxy for the secret. Posture: the route is open
// -- the code IS the credential; whoever can view the dashboard may enroll a
// host -- verified constant-time against the retained codes (current + recent
// predecessors, so a code read from a panel about to refresh still redeems),
// per-IP throttled, and every attempt is audited to the log + Loki with the
// caller's address. The answer is sealed under the redeemed code (sealLabToken),
// so the shared token is never in the clear on the wire and only the redeemer
// can open it -- the listener is plain HTTP whenever the proxy has no TLS leaf.
// Self-disables (503) when rotation is off or no internal authentication key is configured,
// mirroring /ingest.
func (s *poolState) handleLabToken(w http.ResponseWriter, r *http.Request) {
	if s.labRotate <= 0 || s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.lab_token_exchange_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxLabTokenBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var req struct {
		LabToken string `json:"labToken"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_request", http.StatusBadRequest)
		return
	}
	code := strings.ToLower(strings.TrimSpace(req.LabToken))
	if !labTokenRE.MatchString(code) {
		localizedHTTPError(w, r, "aggregator.labtoken_must_be_6_lowercase_letters_digits", http.StatusBadRequest)
		return
	}
	now := time.Now().UTC()
	cut := now.Add(-labFailWindow)
	// Throttle by the /64 for IPv6: a single delegated prefix hands one
	// attacker more addresses than the map could ever hold, so per-address
	// buckets there would throttle nothing while growing without bound.
	throttleKey := labThrottleKey(srcIP)
	poolLabel := s.pool
	token := s.authToken
	var attempt poolstate.LabAttempt
	s.st.Do(func(view *poolstate.View) {
		attempt = view.RedeemLabCode(throttleKey, code, now, cut, labFailLimit, maxLabFailKeys)
	})
	recent, throttled, match, outcome := attempt.Recent, attempt.Throttled, attempt.Matched, attempt.Outcome
	// audit is false for a repeat throttled attempt: once an address is
	// locked out, auditing every retry would let an anonymous caller amplify
	// one request into one log line and one Loki write apiece. The crossing
	// into throttled IS recorded, so the operator still sees the burst.
	audit := !throttled
	// Audit after the unlock (a slow Loki must not stall the handler);
	// refusals are audited too -- a burst of them is the operator's signal
	// that someone is poking the enrollment surface. The code itself is
	// never logged: a refused one is a guess worth nothing, and an accepted
	// one would put a live credential in the log.
	if audit {
		auditOutcome := outcome
		if !match && recent+1 == labFailLimit {
			auditOutcome = "refused (now throttled)"
		}
		log.Print(operatorMessage("aggregator.log_lab_token_exchange_value1_from_value2_3d2e9e4a", map[string]any{"value1": fmt.Sprintf("%s", auditOutcome), "value2": fmt.Sprintf("%s", srcIP)}))
		line, _ := json.Marshal(map[string]string{"sourceIp": srcIP, "outcome": auditOutcome})
		_ = s.queueLoki(s.httpClient, s.lokiURL, lokiLinePayload(map[string]string{"pool": poolLabel, "src": "lab-token"}, line, now), "lab-token exchange push")
	}
	switch {
	case throttled:
		w.Header().Set("Retry-After", strconv.Itoa(int(labFailWindow/time.Second)))
		localizedHTTPError(w, r, "aggregator.too_many_failed_attempts_retry_later", http.StatusTooManyRequests)
	case !match:
		localizedHTTPError(w, r, "aggregator.unknown_or_expired_lab_token", http.StatusForbidden)
	default:
		envelope, err := sealLabToken(code, token)
		if err != nil {
			log.Print(operatorMessage("aggregator.log_lab_token_exchange_sealing_failed_value1_8aceabc2", map[string]any{"value1": fmt.Sprintf("%v", err)}))
			localizedHTTPError(w, r, "aggregator.failed_to_seal_the_token", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		resp, _ := json.Marshal(struct {
			Ok bool `json:"ok"`
			V  int  `json:"v"`
			// Inline so the envelope fields sit at the top level, matching
			// the config-sync credential envelope the client already parses.
			Salt       string `json:"salt"`
			Nonce      string `json:"nonce"`
			Ciphertext string `json:"ciphertext"`
			Tag        string `json:"tag"`
		}{Ok: true, V: 1, Salt: envelope["salt"], Nonce: envelope["nonce"],
			Ciphertext: envelope["ciphertext"], Tag: envelope["tag"]})
		_, _ = w.Write(resp)
	}
}

// labThrottleKey collapses an address to its throttle bucket: the /64 for IPv6
// (the smallest routinely-delegated prefix), the address itself for IPv4 and
// for anything unparseable.
func labThrottleKey(ip string) string {
	addr := net.ParseIP(ip)
	if addr == nil || addr.To4() != nil {
		return ip
	}
	return addr.Mask(net.CIDRMask(64, 128)).String() + "/64"
}

// dashedHostIDRE / plainHostIDRE are the two spellings of one hostId: the
// GUID-formatted rendering (8-4-4-4-12) every operator-facing surface shows a
// FULL id in, and the undashed 32-hex form the pool keys hosts on everywhere
// else. dashedHostID renders one, normalizeHostID folds the other back, and a
// link built from a rendered value therefore resolves either way.
//
// plainHostIDRE deliberately does NOT reuse hostIDRe, which spells the same shape:
// that one is the /archive/ route's authorization gate, and tightening a gate must
// not silently change how an id is printed.
var (
	dashedHostIDRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	plainHostIDRE  = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)
)

// normalizeHostID folds the GUID-formatted spelling of a hostId back to the
// undashed form the pool is keyed on, so the /go/* deep-links resolve whichever
// spelling a dashboard panel interpolated. Anything not shaped like a dashed
// 32-hex id passes through untouched (hostIds are opaque by contract).
func normalizeHostID(hostID string) string {
	if dashedHostIDRE.MatchString(hostID) {
		return strings.ReplaceAll(hostID, "-", "")
	}
	return hostID
}

// dashedHostID renders a hostId 8-4-4-4-12, the spelling a full id is shown in
// wherever an operator has to check one against another screen or paste it into
// a command -- 32 undifferentiated hex characters are not checkable by eye.
//
// It rides as a SEPARATE label beside hostId rather than replacing it: hostId is
// the join key the dashboard's Loki frames and every /go/* link are keyed on, and
// re-spelling it would fork those series and break the join. That makes this the
// same kind of precomputed display value the goPath, commitUrl and cycleFolderUrl
// labels already are -- a Grafana data link interpolates a field's DISPLAYED
// value, so a panel that shows the short id cannot recover the full one from the
// cell it is showing.
//
// An id that is not 32 hex passes through untouched: an announce may carry any
// opaque 8-64 character identifier, and hostIds are opaque by contract.
func dashedHostID(hostID string) string {
	if !plainHostIDRE.MatchString(hostID) {
		return hostID
	}
	return hostID[0:8] + "-" + hostID[8:12] + "-" + hostID[12:16] + "-" + hostID[16:20] + "-" + hostID[20:32]
}

// handleGoHost bridges a dashboard click -> the host's OWN status-page root, resolving
// the host's CURRENT IP server-side (the same uuid->IP resolution as /go/cycle, so the
// link survives a host IP change). Distinct from /go/cycle, which targets a specific
// cycle-results folder; this always lands on the status root. The state-timeline series
// is intentionally IP-free (keyed on hostId so a host's row doesn't split on an IP
// change), so the link can't carry the IP and must resolve it here. Host unknown -> 404.
func (s *poolState) handleGoHost(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return
	}
	// pool-control asks with scope=pause for the pool-wide pause and continue: that
	// proof opens the host's pause and resume routes and nothing else on it.
	scope := strings.TrimSpace(q.Get("scope"))
	if scope != "" && !controlproof.ValidScope(scope) {
		localizedHTTPError(w, r, "aggregator.invalid_control_scope", http.StatusBadRequest)
		return
	}
	base, _ := s.resolveHostBase(hostID, strings.TrimSpace(q.Get("pool")))
	if base == "" {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	// Carry a short-lived control proof to the host UI in the URL FRAGMENT (never sent to
	// a server or written to an access log; the status page JS reads location.hash). This
	// lets the operator drive the host's mutating /control/* routes after arriving through
	// the (to-be-authenticated) Grafana dashboard, without the host trusting the whole LAN.
	// No token configured -> no fragment -> the host accepts only loopback control.
	dest := strings.TrimRight(base, "/")
	proof := mintControlProof(s.authToken, hostID, controlProofTTL)
	if scope != "" {
		proof = controlproof.MintForScope(s.authToken, hostID, scope, controlProofTTL)
	}
	if proof != "" {
		dest += "#yctl=" + proof
	}
	http.Redirect(w, r, dest, http.StatusFound)
}

// handleGoStash bridges a dashboard Extension-cell click -> an extension's service
// UI (today the stash-service VM), 302ing to the URL the owning host advertised in its
// registration (extensionTargets[area], default area "stash-service"). Unlike
// /go/host -- which re-resolves a host's CURRENT :8080 IP live -- the aggregator does
// not probe the stash-service VM, so this redirect is only as fresh as the host's advertised
// stashBaseUrl; the host re-resolves that each cycle (and on Start-StashServiceVM) via
// Get-VMIp, so it self-heals after a DHCP change. Host/target unknown -> 404, matching
// the best-effort resolver contract.
//
// Like /go/host it hands the browser a short-lived control proof in the fragment, so a
// service UI reached this way can act on its gated routes without the operator going
// back to the dashboard to read the rotating lab code.
func (s *poolState) handleGoStash(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return
	}
	area := strings.TrimSpace(q.Get("area"))
	if area == "" {
		area = stashArea
	}
	// One merged view for both sources: a live announce (first-hand -- the
	// service reached us from that address) outranks the owning host's
	// registration, which lags a cycle behind its own service; the registration
	// answers whenever nothing is announcing, including when the service's
	// status service is down and the announce is all there is.
	var target string
	s.st.Do(func(view *poolstate.View) { target = s.extensionTargetForLocked(view, hostID, area, time.Now()) })
	if target == "" {
		localizedHTTPError(w, r, "aggregator.stash_target_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	// Carry a short-lived control proof in the URL FRAGMENT, the same handoff /go/host
	// makes to a host's status page: a fragment never reaches a server and never lands
	// in an access log, and the service UI reads it off location.hash. It is what lets
	// an operator who arrived through the (to-be-authenticated) dashboard act on the
	// service's gated routes without retyping the rotating lab code -- the service
	// revalidates it, here if it holds no token of its own. No token configured -> no
	// fragment -> the UI prompts for the lab token exactly as before.
	dest := strings.TrimRight(target, "/")
	if proof := mintControlProof(s.authToken, "svc-"+area, controlProofTTL); proof != "" {
		dest += "#yctl=" + proof
	}
	http.Redirect(w, r, dest, http.StatusFound)
}

// resolveClickedCycle answers "which host, and which cycle folder, is under that
// point on the timeline?" -- the question both cycle deep-links ask. The
// state-timeline series is intentionally IP-free (keyed on hostId so a host's row
// doesn't split when its IP changes), so the link cannot carry the IP; this
// resolves it LIVE from the in-memory view (the host's CURRENT IP -- the whole
// point: the link survives an IP change). The cycle folder for the clicked time is
// the current cycle (fast path, no fetch) when t falls in it, else the cycle active
// at t resolved from the host's /log/ listing (works for any retained cycle, old or
// new), else the Loki transition feed (a host that has aged out of the live view).
//
// Returns ok=false having already written the response: no host id -> 400, host
// not in the pool -> 404. A resolved host with an UNRESOLVED folder is ok=true
// with folder "", because that is still an answer for /go/cycle (the host's status
// root) even though /go/cycle-share has nothing to archive and must say so itself.
func (s *poolState) resolveClickedCycle(w http.ResponseWriter, r *http.Request) (base, folder string, ok bool) {
	q := r.URL.Query()
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return "", "", false
	}
	var clickT time.Time
	if ms, err := strconv.ParseInt(strings.TrimSpace(q.Get("t")), 10, 64); err == nil && ms > 0 {
		clickT = time.Unix(0, ms*int64(time.Millisecond)).UTC()
	}
	pool := strings.TrimSpace(q.Get("pool"))

	var curFolder string
	var curStart time.Time
	s.st.Do(func(view *poolstate.View) {
		if hv := view.Hosts[hostID]; hv != nil && hv.Status != nil {
			curFolder = hv.Status.CycleFolderUrl
			if tt, perr := time.Parse(time.RFC3339, hv.Status.StartedAt); perr == nil {
				curStart = tt
			}
		}
	})

	// Resolve the host's current base URL (live IP, else the last IP Loki recorded);
	// also normalizes an empty pool so the per-cycle folder lookups below can scope.
	base, pool = s.resolveHostBase(hostID, pool)
	if base == "" {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return "", "", false
	}

	switch {
	case curFolder != "" && (clickT.IsZero() || (!curStart.IsZero() && !clickT.Before(curStart))):
		folder = curFolder // current cycle (in-memory, no fetch)
	case !clickT.IsZero():
		// Resolve the cycle active at the clicked time: the backfill's cycle index,
		// then the archive, then the host's /log/ listing, then Loki's recorded
		// folder. See https://yuruna.link/42c29d04-0008.
		folder = s.resolveFolderByIndex(hostID, clickT)
		if folder == "" {
			folder = s.resolveFolderByArchive(hostID, clickT)
		}
		if folder == "" {
			folder = s.resolveFolderByListing(base, hostID, clickT)
		}
		if folder == "" {
			if fu, _, found := s.lookupCycleAt(pool, hostID, clickT); found {
				folder = fu
			}
		}
	}
	return base, folder, true
}

// hostIDRe and archiveCycleRe validate an /archive/ request BEFORE any filesystem
// call. The shape check IS the authorization here, exactly as it is for the host's
// own /archive/<cycle>.zip route: nothing that is not a 32-hex host id followed by
// the literal "test-cycles" and a well-formed cycle leaf reaches the disk.
//
// The cycle grammar is deliberately stricter than the host-side ones: on-share
// leaves are ALWAYS the stable stripped identity, because the archiver keys its
// map, destination and ledger on Get-PoolStorageCycleIdentity. A ".incomplete" or
// ".aborted.<UTC>" suffix in a URL therefore cannot name anything that exists here
// -- it can only be a probe, and rejecting it costs nothing.
var (
	hostIDRe       = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)
	archiveCycleRe = regexp.MustCompile(`^\d{6}\.\d{4}-\d{2}-\d{2}\.\d{2}-\d{2}-\d{2}\.[0-9a-fA-F]{32}$`)
)

// archiveCommitted reports whether an archived cycle folder carries the
// .yuruna-complete sentinel. A destination exists sentinel-less for the whole
// duration of its copy (up to ten minutes for a large cycle) and after a failed
// verification until its cleanup lands, and a reader cannot tell a half-copied tree
// from a finished one by looking at it. Every resolution path checks this, so a
// dashboard click can never land inside a copy that is still running.
func (s *poolState) archiveCommitted(hostID, cycle string) bool {
	if s.archiveRoot == "" || !hostIDRe.MatchString(hostID) || !archiveCycleRe.MatchString(cycle) {
		return false
	}
	root, err := os.OpenRoot(s.archiveRoot)
	if err != nil {
		return false
	}
	defer root.Close()
	st, err := root.Stat(path.Join(hostID, "test-cycles", cycle, ".yuruna-complete"))
	return err == nil && !st.IsDir()
}

// resolveFolderByArchive returns the archived cycle folder covering time t for a
// host, as "<cycle>/" -- or "" when the archive cannot answer. The folder name
// carries the cycle's UTC start, so the same "latest start at or before t" rule the
// host-listing resolver uses applies unchanged; this one reads local disk on the
// proxy instead of fetching over HTTP from a host that may be switched off, which
// is the entire point of a durable tier.
func (s *poolState) resolveFolderByArchive(hostID string, t time.Time) string {
	if s.archiveRoot == "" || !hostIDRe.MatchString(hostID) || t.IsZero() {
		return ""
	}
	root, err := os.OpenRoot(s.archiveRoot)
	if err != nil {
		return ""
	}
	defer root.Close()
	dir, err := root.Open(path.Join(hostID, "test-cycles"))
	if err != nil {
		return ""
	}
	defer dir.Close()
	names, err := dir.Readdirnames(-1)
	if err != nil {
		return ""
	}
	best := ""
	var bestStart time.Time
	for _, name := range names {
		if !archiveCycleRe.MatchString(name) {
			continue
		}
		start, ok := cycleStartFromFolder(name)
		if !ok || start.After(t) {
			continue
		}
		if best == "" || start.After(bestStart) {
			best, bestStart = name, start
		}
	}
	if best == "" || !s.archiveCommitted(hostID, best) {
		return ""
	}
	return best + "/"
}

// handleArchive serves archived cycle results straight off the pool share:
// GET /archive/<hostId>/test-cycles/<cycle>/... . Read-only, GET/HEAD only, and
// contained by os.Root so no "..", symlink or case trick can escape the archive
// root -- the kernel enforces it rather than a string comparison.
//
// The root is re-opened PER REQUEST rather than once at startup. The proxy's NAS
// mount arrives asynchronously after boot (the config-service fetch owns it, and the
// unit orders on nothing that waits for it), so a root captured at startup would
// pin the route to whatever the mount looked like before it existed -- 404 forever
// until someone restarted the service.
func (s *poolState) handleArchive(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	rel := strings.TrimPrefix(r.URL.Path, "/archive/")
	segs := strings.Split(strings.Trim(rel, "/"), "/")
	if len(segs) < 2 || !hostIDRe.MatchString(segs[0]) || segs[1] != "test-cycles" {
		http.NotFound(w, r)
		return
	}
	if len(segs) >= 3 && segs[2] != "" && !archiveCycleRe.MatchString(segs[2]) {
		http.NotFound(w, r)
		return
	}
	root, err := os.OpenRoot(s.archiveRoot)
	if err != nil {
		// The mount is away (or was never there). Say so plainly rather than
		// serving a 500 that reads like a bug in the service.
		localizedHTTPError(w, r, "aggregator.the_pool_share_is_not_mounted_on_this_machine", http.StatusNotFound)
		return
	}
	defer root.Close()
	w.Header().Set("Cache-Control", "no-store")
	// FileServerFS, not ServeContent: this route has to answer folder URLs with a
	// listing (that is what a dashboard click lands on) as well as files with Range
	// support for large screenshots and transcripts. ServeContent does the second
	// and none of the first.
	http.StripPrefix("/archive/", http.FileServerFS(root.FS())).ServeHTTP(w, r)
}

// handleGoCycle bridges a dashboard timeline click -> that cycle's results.
// Archive-first: once a cycle is committed on the share, the redirect goes to this
// service's own /archive/ copy, which answers from local disk and keeps working when
// the host is switched off or reimaged -- the durable tier's whole promise. Only a
// cycle that is not (yet) archived sends the operator to the host. Degrades
// gracefully: missing/zero time -> current cycle; folder unresolved -> the host's
// status root (still the right host at its current IP); host unknown -> 404.
func (s *poolState) handleGoCycle(w http.ResponseWriter, r *http.Request) {
	base, folder, ok := s.resolveClickedCycle(w, r)
	if !ok {
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	hostID := normalizeHostID(strings.TrimSpace(r.URL.Query().Get("host")))
	http.Redirect(w, r, s.cycleResultsTarget(hostID, base, folder), http.StatusFound)
}

// A runner attempt can fail before creating a cycle. Resolve those host-state
// intervals separately so opening a yellow block cannot show the previous pass.
// Completed attempts remain available after recovery, until host retention removes
// them. The dashboard sends the observed state to distinguish expired preflight
// evidence from a cycle result without changing the existing cycle-link contract.
func (s *poolState) handleGoHostEvent(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	status := q.Get("status")
	if status != "" && status != "3" && status != "9" {
		s.handleGoCycle(w, r)
		return
	}
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return
	}
	base, _ := s.resolveHostBase(hostID, strings.TrimSpace(q.Get("pool")))
	if base == "" {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	var target string
	if ms, err := strconv.ParseInt(strings.TrimSpace(q.Get("t")), 10, 64); err == nil && ms > 0 {
		target = s.runnerAttemptTarget(base, time.UnixMilli(ms), status == "9")
	}
	if target == "" && status == "9" {
		target = strings.TrimRight(base, "/") + "/#runner-attempts"
	}
	if target == "" {
		s.handleGoCycle(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, target, http.StatusFound)
}

// The index includes successful attempts so a failure's interval ends when the
// next preflight completes, rather than following the host into a recovered cycle.
// Diagnostic text is deliberately not parsed or exported by the pool service.
func (s *poolState) runnerAttemptTarget(base string, click time.Time, preflightOnly bool) string {
	if s.httpClient == nil {
		return ""
	}
	type attempt struct {
		Generation   string `json:"attemptGeneration"`
		StartedAt    string `json:"startedAtUtc"`
		FinishedAt   string `json:"finishedAtUtc"`
		Passed       bool   `json:"passed"`
		Skipped      bool   `json:"skipped"`
		FailureClass string `json:"failureClass"`
		RecordPath   string `json:"recordPath"`
	}
	var index struct {
		SchemaVersion int       `json:"schemaVersion"`
		Attempts      []attempt `json:"attempts"`
	}
	body := s.fetchListing(strings.TrimRight(base, "/") + "/runtime/runner-attempts/index.json")
	if json.Unmarshal([]byte(body), &index) != nil || index.SchemaVersion != 1 || len(index.Attempts) > 20 {
		return ""
	}
	var latest *attempt
	var latestTime time.Time
	for i := range index.Attempts {
		row := &index.Attempts[i]
		finished, err := time.Parse(time.RFC3339Nano, row.FinishedAt)
		started, startErr := time.Parse(time.RFC3339Nano, row.StartedAt)
		if err != nil || startErr != nil || finished.Before(started) || finished.After(click) {
			continue
		}
		if latest == nil || finished.After(latestTime) {
			latest, latestTime = row, finished
		}
	}
	if latest == nil || latest.Passed || latest.Skipped || latest.FailureClass == "" ||
		(preflightOnly && latest.FailureClass != "config_gate_failed") || latest.Generation == "" {
		return ""
	}
	// The directory identity is the same SHA256 prefix the runner uses; its
	// original generation may include a process ID or other non-path characters.
	digest := sha256.Sum256([]byte(latest.Generation))
	directory := fmt.Sprintf("runner-attempts/%x/", digest[:12])
	if latest.RecordPath != directory+"config-gate.json" && latest.RecordPath != directory+"runner-fault.json" {
		return ""
	}
	return strings.TrimRight(base, "/") + "/runtime/" + latest.RecordPath
}

// cycleResultsTarget is where a timeline click on this host at this cycle lands.
// Factored out because the JSON route hands the same URL to a caller that cannot
// see the timeline at all; sharing the body is what stops the link a tool
// returns and the link a click follows from ever being different places.
//
// A leading "/" is deliberate and means the archive on this service.
func (s *poolState) cycleResultsTarget(hostID, base, folder string) string {
	if leaf := strings.Trim(folder, "/"); leaf != "" {
		leaf = path.Base(leaf)
		if s.archiveCommitted(hostID, leaf) {
			return "/archive/" + hostID + "/test-cycles/" + leaf + "/"
		}
	}
	target := strings.TrimRight(base, "/")
	if folder != "" {
		target += "/" + strings.TrimLeft(folder, "/")
	}
	return target
}

// cycleShareTarget is the host's share page for one cycle, or "" when the folder
// cannot name one -- the caller decides whether that is a 404 or an omitted field.
func cycleShareTarget(base, folder string) string {
	leaf := path.Base(strings.Trim(folder, "/"))
	if leaf == "" || leaf == "." || leaf == "/" {
		return ""
	}
	return strings.TrimRight(base, "/") + "/share-cycle.html?cycle=" + url.QueryEscape(leaf)
}

// handleGoCycleShare bridges a dashboard timeline click -> the host's own share
// page for that cycle, which packs the folder into one archive and hands it to the
// operator's mail client. Same host and same folder as /go/cycle: one resolver, so
// "share this" can never archive a different cycle than "open this" would show.
//
// The page lives on the HOST rather than here because the artifacts do: it is
// same-origin with the files it archives, needs no CORS, and the archive is built
// from local disk instead of crawling a directory listing over HTTP.
//
// An unresolved folder is a 404 here where /go/cycle falls back to the status root.
// Landing on a share page that does not know which cycle it is sharing would only
// move the failure to a button.
func (s *poolState) handleGoCycleShare(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("status") == "9" {
		s.handleGoHostEvent(w, r)
		return
	}
	base, folder, ok := s.resolveClickedCycle(w, r)
	if !ok {
		return
	}
	if folder == "" {
		localizedHTTPError(w, r, "aggregator.no_cycle_results_folder_for_that_host_at_that_time", http.StatusNotFound)
		return
	}
	// The share page and the host's archive route both name a results folder by
	// its LEAF -- the folder sits directly under the host's log dir, and the leaf
	// is what carries the cycle number, the UTC start and the host id that the
	// archive is named from. Every producer here spells it "log/<leaf>/"
	// (Set-CycleFolderUrl, the listing parser, and the Loki copy of the same
	// value), so hand on the last segment rather than the path.
	target := cycleShareTarget(base, folder)
	if target == "" {
		localizedHTTPError(w, r, "aggregator.unusable_cycle_results_folder_for_that_host_at_that_time", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, target, http.StatusFound)
}

// resolveFolderByListing fetches the host's /log/ index and returns the results
// folder ("log/<n>.<date>.<time>.<hostId>/") of the cycle that was active at time
// t. Works for any cycle still on disk regardless of what Loki recorded -- the
// folder name itself encodes the start time. Best-effort: unreachable / non-200 /
// unparseable -> "".
func (s *poolState) resolveFolderByListing(baseURL, hostID string, t time.Time) string {
	if s.httpClient == nil {
		return ""
	}
	body := s.fetchListing(strings.TrimRight(baseURL, "/") + "/log/")
	if body == "" {
		return ""
	}
	// An exact hit in the live index is the common case and costs one request.
	if best, _ := scanListingForHost(body, hostID, t); best != "" {
		return "log/" + strings.TrimSuffix(best, "/") + "/"
	}
	// A cycle older than the retention window is not gone: it moves into a
	// history.<YYYY-MM-DD>/ bucket that the index LINKS but does not inline.
	// Without following those links the click falls through to the
	// oldest-retained fallback below and silently lands on a cycle nobody asked
	// for -- the failure being investigated reads as "the evidence was pruned"
	// when it is still on disk one directory away. A bucket is named for the
	// host-local day rotation ran, not for the day its cycles did, so the date of
	// t cannot pick one. Rotation always moves the oldest cycles, so the buckets
	// hold consecutive stretches of history in date order, and read newest first
	// the first one holding a cycle that started at or before t holds the cycle
	// active at t.
	for _, bucket := range historyBucketsNewestFirst(body, maxHistoryBucketsScanned) {
		hb := s.fetchListing(strings.TrimRight(baseURL, "/") + "/log/" + bucket + "/")
		if hb == "" {
			continue
		}
		if best, _ := scanListingForHost(hb, hostID, t); best != "" {
			return "log/" + bucket + "/" + strings.TrimSuffix(best, "/") + "/"
		}
	}
	return pickFolderFromListing(body, hostID, t)
}

// maxHistoryBucketsScanned bounds the bucket reads one click can cost. Rotation
// moves about ninety cycles at a time, so this reaches weeks back; older clicks
// are answered from the history backfill's cycle index, which has every bucket
// already read.
const maxHistoryBucketsScanned = 16

// historyBucketsNewestFirst returns the history buckets a /log/ index links,
// newest first, at most limit of them.
func historyBucketsNewestFirst(body string, limit int) []string {
	_, buckets := parseListing(body)
	sort.Sort(sort.Reverse(sort.StringSlice(buckets)))
	if len(buckets) > limit {
		buckets = buckets[:limit]
	}
	return buckets
}

// fetchListing GETs one directory index and returns its body, "" on any failure.
func (s *poolState) fetchListing(u string) string {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return ""
	}
	return string(body)
}

// scanListingForHost finds this host's cycle folders in one directory index and
// returns two answers: the leaf whose encoded start is the latest at/before t (the
// cycle active at that moment, "" when the listing holds none that old) and the
// earliest leaf present. Separating them lets a caller tell a real hit from the
// oldest-retained consolation prize, which reads identically once returned.
func scanListingForHost(body, hostID string, t time.Time) (best, earliest string) {
	re := regexp.MustCompile(`\d{6}\.(\d{4}-\d{2}-\d{2})\.(\d{2}-\d{2}-\d{2})\.` + regexp.QuoteMeta(hostID) + `(?:\.incomplete)?/`)
	var bestStart, earliestStart time.Time
	for _, m := range re.FindAllStringSubmatch(body, -1) {
		st, perr := time.Parse("2006-01-02 15-04-05", m[1]+" "+m[2])
		if perr != nil {
			continue
		}
		st = st.UTC()
		if earliest == "" || st.Before(earliestStart) {
			earliest, earliestStart = m[0], st
		}
		if st.After(t) {
			continue
		}
		if best == "" || st.After(bestStart) {
			best, bestStart = m[0], st
		}
	}
	return best, earliest
}

// pickFolderFromListing scans a /log/ index page for this host's cycle folders
// (`<6-digit cycle number>.<YYYY-MM-DD>.<HH-mm-ss>.<hostId>[.incomplete]/`, the
// Format-CycleFolderBaseName shape) and returns the one whose encoded start time is
// the latest at/before t -- the cycle active at the clicked moment. When t predates
// every retained folder it returns the earliest, so the link still lands on a real
// cycle. Pure + table-testable; "" when nothing matches.
// cycleStartFromFolder parses the UTC start encoded in a cycle folder leaf
// ("NNNNNN.YYYY-MM-DD.HH-MM-SS.<hostId>"). One parser for both resolvers, so the
// archive and the host listing can never disagree about which cycle covers a click.
func cycleStartFromFolder(name string) (time.Time, bool) {
	m := cycleStartRe.FindStringSubmatch(name)
	if m == nil {
		return time.Time{}, false
	}
	st, err := time.Parse("2006-01-02 15-04-05", m[1]+" "+m[2])
	if err != nil {
		return time.Time{}, false
	}
	return st.UTC(), true
}

var cycleStartRe = regexp.MustCompile(`^\d{6}\.(\d{4}-\d{2}-\d{2})\.(\d{2}-\d{2}-\d{2})\.`)

func pickFolderFromListing(body, hostID string, t time.Time) string {
	best, earliest := scanListingForHost(body, hostID, t)
	if best == "" {
		best = earliest
	}
	if best == "" {
		return ""
	}
	return "log/" + strings.TrimSuffix(best, "/") + "/"
}

// handleMetrics serves the Prometheus exposition, to this machine only.
//
// The exposition includes yuruna_pool_lab_token{token="..."} -- the current
// enrollment credential in plain text -- so serving it to the LAN handed the
// credential to anyone who asked. Prometheus scrapes this daemon at
// localhost:9400 (see the scrape config in the proxy VM's seed), so a loopback
// bound is the whole of what the collector needs and none of what a LAN client
// was getting. A remote caller is refused rather than served a redacted body:
// a partial exposition would look like a working scrape and hide the refusal
// from whoever set it up.
func (s *poolState) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if !httpserve.IsLoopbackSource(r) {
		localizedHTTPError(w, r, "aggregator.metrics_are_served_to_this_host_only", http.StatusForbidden)
		return
	}
	s.handleMetricsBody(w)
}

func (s *poolState) handleMetricsBody(w http.ResponseWriter) {
	s.handleMetricsWithArchiveProbe(w, func(path string) bool {
		root, err := os.OpenRoot(path)
		if err != nil {
			return false
		}
		_ = root.Close()
		return true
	})
}

func (s *poolState) handleMetricsWithArchiveProbe(w http.ResponseWriter, readable func(string) bool) {
	// The share may stall during reconnect. Probe the fixed startup path before
	// locking live state so discovery and control remain usable during outages.
	archiveAvailable := 0
	if s.archiveRoot != "" && readable(s.archiveRoot) {
		archiveAvailable = 1
	}
	var out string
	s.st.Do(func(view *poolstate.View) {
		total := len(view.Hosts)
		reachable := 0
		for _, h := range view.Hosts {
			if h.Reachable {
				reachable++
			}
		}
		// Union of every hostId across the live view + the cycle counters, so each
		// per-host series set is complete (a host with no terminal cycles yet still
		// gets pass/fail=0). A reaped host keeps reporting its totals: pass/fail are
		// cumulative and are NOT time-expired -- only forgetHost clears them, so they
		// otherwise survive until the process restarts. The TTL'd state is the
		// per-cycle dedup set below, not these counters.
		hostIDs := map[string]bool{}
		for h := range view.Hosts {
			hostIDs[h] = true
		}
		passTotals, failTotals := view.CycleTotals()
		for h := range passTotals {
			hostIDs[view.CanonicalHostID(h)] = true
		}
		for h := range failTotals {
			hostIDs[view.CanonicalHostID(h)] = true
		}
		ids := sortedKeys(hostIDs)

		var b strings.Builder
		fmt.Fprintf(&b, "# HELP yuruna_pool_collector_up pool-aggregator service is serving.\n# TYPE yuruna_pool_collector_up gauge\nyuruna_pool_collector_up 1\n")
		fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_total Pool hosts discovered (within hostTtl).\n# TYPE yuruna_pool_hosts_total gauge\nyuruna_pool_hosts_total %d\n", total)
		// Archive availability, exported only when an archive root is configured. This is
		// how "the dashboard's cycle links stopped working" becomes visible without a
		// human noticing dead links: the CIFS mount is nofail, so when it goes away every
		// archived cycle silently stops resolving and nothing else says so.
		if s.archiveRoot != "" {
			fmt.Fprintf(&b, "# HELP yuruna_pool_archive_available The pool share's archive root is readable on the collector (0 = the NAS mount is away; archived cycle links fall back to the hosts).\n# TYPE yuruna_pool_archive_available gauge\nyuruna_pool_archive_available %d\n", archiveAvailable)
		}
		fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_reachable Pool hosts answering status.json on the last poll.\n# TYPE yuruna_pool_hosts_reachable gauge\nyuruna_pool_hosts_reachable %d\n", reachable)
		if !view.LastPoll().IsZero() {
			fmt.Fprintf(&b, "# HELP yuruna_pool_last_poll_timestamp_seconds Unix time of the last completed poll.\n# TYPE yuruna_pool_last_poll_timestamp_seconds gauge\nyuruna_pool_last_poll_timestamp_seconds %d\n", view.LastPoll().Unix())
		}

		// Per-host descriptive series that drive the dashboard's pool table.
		// host_info carries the table's label cells (name, type, framework version,
		// commit + its deep-link URLs, other deep-link URLs, current cycle, derived
		// status). The series churns when cycleStartUtc/status/IP change, and that is
		// why status/cycle are NOT labels on the timeline series.
		//
		// The churn is also why the value is the host's last-seen time rather than a
		// constant. A replaced label-set does NOT leave the instant query at once: it
		// keeps its final sample and stays inside the staleness window a table reads,
		// so for about five minutes both the old and the new series answer and the host
		// occupies two rows. Exporting last-seen makes the two comparable, so a reader
		// can take the newest with `topk(1, ...) by (hostId)` -- which is what the Pool
		// hosts panel does. A constant cannot be ranked, and ties resolve arbitrarily,
		// so the panel would be as likely to show the stale row as the current one.
		b.WriteString("# HELP yuruna_pool_host_info Per-host descriptive labels for the pool table; the value is the host's last-seen Unix time, so a reader can select the newest series per host while the labels churn.\n# TYPE yuruna_pool_host_info gauge\n")
		for _, h := range ids {
			hv := view.Hosts[h]
			if hv == nil {
				continue
			}
			hostType, cycleStartUtc, cfu := "", "", ""
			commitDisplay, commitURLVal, projectCommitURL := "", "", ""
			if hv.Status != nil {
				hostType, cycleStartUtc, cfu = hv.Status.Host, hv.Status.CycleStartUtc, hv.Status.CycleFolderUrl
				// commit is the current cycle's short SHAs (framework, project); the two
				// URL labels are the per-repo deep-links the table's Commit cell resolves.
				commitDisplay, commitURLVal, projectCommitURL = commitCells(hv.Status)
			}
			// No hostname label (pool view is hostname-free). cycleFolderUrl stays --
			// the table's cycle-folder deep-link needs it; the folder name is the opaque
			// hostId (Format-CycleFolderBaseName), so this value is hostname-free too. (A
			// legacy pre-hostId folder name still embeds the hostname until that host's
			// next cycle re-names under hostId.) commit/commitUrl/projectCommitUrl are a
			// commit id + repo URLs -- hostname-free, so they stay safe here too.
			// control is the STATE NAME only (ready/none/mismatch/skew/unknown): the token
			// tag it was derived from is compared inside this process and never exported,
			// because /metrics is served without a credential (to loopback only).
			// hostIdDashed is the same id rendered 8-4-4-4-12: the table shows the short
			// id and reveals the full one from this label, which it cannot derive from the
			// shortened cell it displays.
			fmt.Fprintf(&b, "yuruna_pool_host_info{pool=%q,poolGuid=%q,hostId=%q,hostIdDashed=%q,hostType=%q,version=%q,commit=%q,commitUrl=%q,projectCommitUrl=%q,baseUrl=%q,cycleStartUtc=%q,cycleFolderUrl=%q,status=%q,control=%q} %d\n",
				s.poolFor(view, h), hv.PoolGuid, h, dashedHostID(h), hostType, hv.Version, commitDisplay, commitURLVal, projectCommitURL, hv.BaseURL, cycleStartUtc, cfu, hv.StatusLabel(), hv.ControlLabel(), hv.LastSeenUnixMs/1000)
		}
		// Grafana joins the original Loki hostId on this mapping, then groups the
		// cycle counts by canonicalHostId. Include the identity row for every live
		// host so unaliased hosts take the same path. A timestamp value makes the
		// newest mapping win while Prometheus still retains a stale prior series.
		b.WriteString("# HELP yuruna_pool_host_canonical_info Maps a current or retired host ID to its live identity for dashboard history grouping.\n# TYPE yuruna_pool_host_canonical_info gauge\n")
		canonicalAt := time.Now().Unix()
		for _, h := range ids {
			if view.Hosts[h] != nil {
				fmt.Fprintf(&b, "yuruna_pool_host_canonical_info{hostId=%q,canonicalHostId=%q} %d\n", h, h, canonicalAt)
			}
		}
		for old := range view.Aliases() {
			canonical := view.CanonicalHostID(old)
			if view.Hosts[canonical] != nil {
				fmt.Fprintf(&b, "yuruna_pool_host_canonical_info{hostId=%q,canonicalHostId=%q} %d\n", old, canonical, canonicalAt)
			}
		}
		// Suppress the retired host_info series during Prometheus's staleness
		// window; its identity mapping above remains so older Loki counts join.
		b.WriteString("# HELP yuruna_pool_host_retired A host ID transferred to another live identity.\n# TYPE yuruna_pool_host_retired gauge\n")
		for old := range view.Aliases() {
			fmt.Fprintf(&b, "yuruna_pool_host_retired{hostId=%q} 1\n", old)
		}
		// host_status: the numeric twin of host_info's status, keyed on hostId so it
		// forms one continuous series per host -- the input the state-timeline panel
		// needs. No hostname label (pool view is hostname-free). 0=unreachable
		// 1=running 2=pass 3=fail 4=idle 5=paused 6=pausing-cycle 7=pausing-step
		// 8=stopped 9=preflight-failed.
		b.WriteString("# HELP yuruna_pool_host_status Per-host state code (0=unreachable 1=running 2=pass 3=fail 4=idle 5=paused 6=pausing-cycle 7=pausing-step 8=stopped 9=preflight-failed).\n# TYPE yuruna_pool_host_status gauge\n")
		for _, h := range ids {
			hv := view.Hosts[h]
			if hv == nil {
				continue
			}
			fmt.Fprintf(&b, "yuruna_pool_host_status{pool=%q,hostId=%q,hostIdDashed=%q} %d\n", s.poolFor(view, h), h, dashedHostID(h), hv.StatusCode())
		}
		// host_refresh_available: whether each host currently advertises a
		// refresh it could run, under the single expiry rule. A gauge of its own
		// rather than a host_info label, because every host_info label becomes a
		// dashboard column. Its labels are bounded enums only -- never a request
		// id, a reason string or a rung list.
		b.WriteString("# HELP yuruna_pool_host_refresh_available Whether the host currently advertises a refresh capability (1 = available, 0 = unavailable), with its request state.\n# TYPE yuruna_pool_host_refresh_available gauge\n")
		refreshNow := time.Now()
		for _, h := range ids {
			hv := view.Hosts[h]
			if hv == nil {
				continue
			}
			availability, state := hv.RefreshLabels(refreshNow, s.refreshTTL)
			value := 0
			if availability == sdkpool.RefreshAvailable {
				value = 1
			}
			fmt.Fprintf(&b, "yuruna_pool_host_refresh_available{pool=%q,hostId=%q,hostIdDashed=%q,state=%q} %d\n", s.poolFor(view, h), h, dashedHostID(h), state, value)
		}
		// host_last_seen: unix seconds of last successful probe; the table shows age
		// as `time() - this`. Keeps climbing for an unreachable-but-not-yet-evicted
		// host, which is exactly the "last seen 5m ago" signal an operator wants.
		b.WriteString("# HELP yuruna_pool_host_last_seen_seconds Unix time of the last successful status probe for this host.\n# TYPE yuruna_pool_host_last_seen_seconds gauge\n")
		for _, h := range ids {
			hv := view.Hosts[h]
			if hv == nil {
				continue
			}
			fmt.Fprintf(&b, "yuruna_pool_host_last_seen_seconds{pool=%q,hostId=%q} %d\n", s.poolFor(view, h), h, hv.LastSeenUnixMs/1000)
		}

		// Address footprint: how fast the lab is spending the LAN's DHCP pool, and
		// whether each host's identity is pinned. Exported as numbers rather than
		// left to the log because exhaustion is a threshold event -- everything
		// works until nothing does -- so the only useful time to read this is while
		// the pool still has room, which means it has to be graphable.
		//
		// -1 is preserved rather than folded to 0 on both gauges below. Zero
		// changes is a MEANINGFUL answer here (this host is bounded), so a host
		// nothing is watching must not be able to report it.
		b.WriteString("# HELP yuruna_pool_host_address_changes Address changes this host recorded in its beacon lookback window (-1 = no record; the beacon is not running there).\n# TYPE yuruna_pool_host_address_changes gauge\n")
		for _, h := range ids {
			if fp, ok := view.Footprint(h); ok && view.Hosts[h] != nil {
				fmt.Fprintf(&b, "yuruna_pool_host_address_changes{pool=%q,hostId=%q,hostIdDashed=%q} %d\n", s.poolFor(view, h), h, dashedHostID(h), fp.Changes)
			}
		}
		b.WriteString("# HELP yuruna_pool_host_address_distinct Distinct addresses this host held in its beacon lookback window; 1 is a bounded host.\n# TYPE yuruna_pool_host_address_distinct gauge\n")
		for _, h := range ids {
			if fp, ok := view.Footprint(h); ok && view.Hosts[h] != nil {
				fmt.Fprintf(&b, "yuruna_pool_host_address_distinct{pool=%q,hostId=%q,hostIdDashed=%q} %d\n", s.poolFor(view, h), h, dashedHostID(h), fp.Distinct)
			}
		}
		// The verdict rides as a LABEL rather than an encoded number: its four
		// values name four different faults, and an operator reading a panel should
		// not have to hold a code table to tell "renewal-churn" from "stable".
		b.WriteString("# HELP yuruna_pool_host_address_footprint Per-host address-footprint verdict and DHCP identity pin (value always 1).\n# TYPE yuruna_pool_host_address_footprint gauge\n")
		for _, h := range ids {
			fp, ok := view.Footprint(h)
			if !ok || view.Hosts[h] == nil {
				continue
			}
			pinned := "unknown"
			switch fp.Pinned {
			case 1:
				pinned = "yes"
			case 0:
				pinned = "no"
			}
			fmt.Fprintf(&b, "yuruna_pool_host_address_footprint{pool=%q,hostId=%q,hostIdDashed=%q,verdict=%q,severity=%q,pinned=%q,backend=%q} 1\n",
				s.poolFor(view, h), h, dashedHostID(h), fp.Verdict, fp.Severity, pinned, fp.Backend)
		}
		// The lab-wide number, and the one that actually predicts exhaustion: a
		// per-host count can look healthy on every host while the fleet still
		// drains the pool, because what runs out is shared. Summed over the hosts
		// that HAVE a reading -- a host with none is unmeasured, and adding a zero
		// for it would understate the total in the one direction that matters.
		labDistinct, measured := 0, 0
		for _, h := range ids {
			if fp, ok := view.Footprint(h); ok && view.Hosts[h] != nil {
				labDistinct += fp.Distinct
				measured++
			}
		}
		fmt.Fprintf(&b, "# HELP yuruna_pool_address_distinct_total Distinct addresses held across all reporting hosts in their beacon lookback windows.\n# TYPE yuruna_pool_address_distinct_total gauge\nyuruna_pool_address_distinct_total %d\n", labDistinct)
		fmt.Fprintf(&b, "# HELP yuruna_pool_address_hosts_measured Hosts reporting an address footprint; below hosts_total, the lab-wide figure understates the truth.\n# TYPE yuruna_pool_address_hosts_measured gauge\nyuruna_pool_address_hosts_measured %d\n", measured)
		// The one that predicts exhaustion. Every guest reaches the internet through
		// this proxy, so its client addresses ARE the lab's address consumption --
		// hosts, service VMs and the guest fleet together, which no host-reported
		// figure covers. Multiply by the lease in days to get the pool size this
		// lab needs; if that exceeds the scope, it runs dry on a schedule.
		addr := view.AddressCounts()
		scanComplete := 0
		if addr.Complete {
			scanComplete = 1
		}
		fmt.Fprintf(&b, "# HELP yuruna_pool_lab_addresses_in_use Measured count of addresses the lab is holding: caching-proxy clients seen in the scan window UNION every known host's current address (deduplicated). A floor, not a ceiling -- anything that neither proxies nor registers as a host is invisible here. Says nothing about the DHCP pool: free leases and scope size live on the server.\n# TYPE yuruna_pool_lab_addresses_in_use gauge\nyuruna_pool_lab_addresses_in_use %d\n", addr.InUse)
		fmt.Fprintf(&b, "# HELP yuruna_pool_lab_addresses_in_use_hosts The host-record half of yuruna_pool_lab_addresses_in_use -- addresses known from host registrations rather than from the proxy log, so this half survives the proxy being down and covers statically-addressed hosts that hold no lease at all.\n# TYPE yuruna_pool_lab_addresses_in_use_hosts gauge\nyuruna_pool_lab_addresses_in_use_hosts %d\n", addr.InUseHosts)
		fmt.Fprintf(&b, "# HELP yuruna_pool_lab_distinct_addresses_24h Distinct client addresses seen by the caching proxy in the scan window. A rate of address use, NOT a pool forecast: converting it into one needs the lease period and scope size, which this service is not given.\n# TYPE yuruna_pool_lab_distinct_addresses_24h gauge\nyuruna_pool_lab_distinct_addresses_24h %d\n", addr.Distinct)
		fmt.Fprintf(&b, "# HELP yuruna_pool_lab_distinct_addresses_complete 1 when the 24h scan reached the far end of its window; 0 means the count above is a floor, not a measurement.\n# TYPE yuruna_pool_lab_distinct_addresses_complete gauge\nyuruna_pool_lab_distinct_addresses_complete %d\n", scanComplete)

		// Extension hosts: one row per (hostId, area) actively running an extension
		// function, from host registrations and service announces. target rides as
		// a label (a hidden URL column the dashboard links); baseUrl rides unlinked.
		// See https://yuruna.link/42c29d04-0007.
		type extRow struct {
			host    string
			area    string
			baseURL string
			target  string
			// lastSeen is the row's own freshness in unix seconds: the host's last
			// successful probe for a registration-sourced row, the last accepted
			// hello for an announce-sourced one.
			lastSeen int64
			// superseded is the address the losing source claimed, "" when the two
			// agreed or only one spoke. Drives the disagreement gauge.
			superseded string
			// suppressed rows carry an address the pool could not reach. They are
			// kept OUT of host_extension -- the panel lists services a member can
			// actually use, and a row the pool refuses to resolve is not one -- and
			// exported as extension_unreachable instead, with the refused address
			// and the reason, so the misconfiguration is visible rather than merely
			// absent.
			suppressed bool
			refused    string
			reason     string
		}
		// Both sources merge in extensionCandidatesLocked, which every other
		// consumer of this data reads too. When they cover the same (hostId, area)
		// and disagree, a live announce wins: its target came off the source
		// address of a request this process received, while the registration is a
		// value the owning host wrote into a file a cycle ago. An announce-only row
		// still resolves baseUrl from the view when the host is at least known (a
		// stub or an unreachable entry); "" otherwise -- a host can run an extension
		// service WITHOUT running cycles, and such a host has no status page at all,
		// so /go/host would answer "host not known to the pool". That is why this
		// table's Host ID cell never offers that hop -- its menu names the row's id
		// and opens the extension UI -- and the Pool hosts table (whose rows all have
		// a status page) is where a host is opened, with the control token. baseUrl
		// stays exported as the answer to
		// "does this extension host have a status page".
		extRows := []extRow{}
		cands := s.extensionCandidatesLocked(view, time.Now())
		candKeys := make([]string, 0, len(cands))
		for k := range cands {
			candKeys = append(candKeys, k)
		}
		// Sorted so a scrape is byte-stable across polls holding the same facts.
		sort.Strings(candKeys)
		for _, k := range candKeys {
			c := cands[k]
			baseURL := ""
			if hv := view.Hosts[c.HostId]; hv != nil {
				baseURL = hv.BaseURL
			}
			extRows = append(extRows, extRow{
				host: c.HostId, area: c.Area, baseURL: baseURL, target: c.Target,
				lastSeen: c.LastSeenUnixMs / 1000, superseded: c.SupersededTarget,
				suppressed: c.Suppressed, refused: c.SuppressedTarget, reason: c.SuppressReason,
			})
		}
		// The unreachable rows are exported even when every usable row is gone: a
		// pool whose only advertised stash cannot be reached must not scrape as a
		// pool with no stash at all.
		unreachable := make([]extRow, 0, len(extRows))
		for _, e := range extRows {
			if e.suppressed {
				unreachable = append(unreachable, e)
			}
		}
		if len(unreachable) > 0 {
			b.WriteString("# HELP yuruna_pool_extension_unreachable An advertised extension address the pool could not reach; it is refused for resolution (value always 1).\n# TYPE yuruna_pool_extension_unreachable gauge\n")
			for _, e := range unreachable {
				fmt.Fprintf(&b, "yuruna_pool_extension_unreachable{pool=%q,hostId=%q,area=%q,target=%q,reason=%q} 1\n", s.poolFor(view, e.host), e.host, e.area, e.refused, e.reason)
			}
		}
		usable := make([]extRow, 0, len(extRows))
		for _, e := range extRows {
			if !e.suppressed {
				usable = append(usable, e)
			}
		}
		extRows = usable
		if len(extRows) > 0 {
			b.WriteString("# HELP yuruna_pool_host_extension Per-host actively-running extension area (value always 1).\n# TYPE yuruna_pool_host_extension gauge\n")
			for _, e := range extRows {
				// goPath is the dashboard's link for this row, ready-made. The Extension
				// cell cannot build it from the columns beside it: a Grafana data link
				// interpolates a field's DISPLAYED value, and that column is value-mapped
				// to prose ("Download-agent service"), so ${__data.fields.Extension} would
				// put the label where the area slug belongs. Precomputing it here is the
				// same answer the hidden baseUrl and target columns already are.
				goPath := "/go/stash?host=" + url.QueryEscape(e.host) + "&area=" + url.QueryEscape(e.area)
				fmt.Fprintf(&b, "yuruna_pool_host_extension{pool=%q,hostId=%q,hostIdDashed=%q,area=%q,baseUrl=%q,target=%q,goPath=%q} 1\n", s.poolFor(view, e.host), e.host, dashedHostID(e.host), e.area, e.baseURL, e.target, goPath)
			}
			b.WriteString("# HELP yuruna_pool_host_extension_last_seen_seconds Unix time this extension host was last confirmed (host probe or service announce).\n# TYPE yuruna_pool_host_extension_last_seen_seconds gauge\n")
			for _, e := range extRows {
				fmt.Fprintf(&b, "yuruna_pool_host_extension_last_seen_seconds{pool=%q,hostId=%q,area=%q} %d\n", s.poolFor(view, e.host), e.host, e.area, e.lastSeen)
			}
			// Disagreement: the two sources named different addresses for one
			// service and the weaker one was dropped. Normally absent. Present
			// means the owning host is advertising an address its own service is
			// not using -- the link works (the stronger source won) but the host's
			// registration is behind, which is worth seeing before it is the only
			// source left. superseded rides as a label so the losing value is
			// readable without correlating two files across two machines; it
			// changes at most once per cycle and only while the two disagree.
			stale := make([]extRow, 0, len(extRows))
			for _, e := range extRows {
				if e.superseded != "" {
					stale = append(stale, e)
				}
			}
			if len(stale) > 0 {
				b.WriteString("# HELP yuruna_pool_extension_target_disagreement The registration and the service's announce name different addresses for this area; the weaker source was dropped (value always 1).\n# TYPE yuruna_pool_extension_target_disagreement gauge\n")
				for _, e := range stale {
					fmt.Fprintf(&b, "yuruna_pool_extension_target_disagreement{pool=%q,hostId=%q,area=%q,target=%q,superseded=%q} 1\n", s.poolFor(view, e.host), e.host, e.area, e.target, e.superseded)
				}
			}
		}

		// Lab connection token: the dashboard's "Lab token" tile reads the CURRENT
		// code as a label (the info-metric pattern host_extension uses -- the only
		// channel the provisioned Prometheus/Loki datasources offer for a string).
		// How many lines wait for Loki: zero in a steady pool, climbing while Loki is
		// away. durable says whether they survive a restart of this daemon.
		if s.outbox != nil {
			durable := 0
			if s.outbox.Durable() {
				durable = 1
			}
			fmt.Fprintf(&b, "# HELP yuruna_pool_loki_outbox_pending Lines the collector holds until Loki accepts them.\n# TYPE yuruna_pool_loki_outbox_pending gauge\nyuruna_pool_loki_outbox_pending{pool=%q,durable=\"%d\"} %d\n", s.pool, durable, s.outbox.Pending())
		}
		// Exported only while the exchange is live, so a disabled feature shows
		// "No data" rather than a stale, unredeemable code. Label churn is one tiny
		// series per rotation.
		if labCodes := view.LabCodes(); s.labRotate > 0 && s.authToken != "" && len(labCodes) > 0 {
			fmt.Fprintf(&b, "# HELP yuruna_pool_lab_token Current lab connection token for enrolling a host (value always 1).\n# TYPE yuruna_pool_lab_token gauge\nyuruna_pool_lab_token{pool=%q,token=%q} 1\n", s.pool, labCodes[0])
			b.WriteString("# HELP yuruna_pool_lab_token_exchanges_total Lab-token exchange attempts by outcome.\n# TYPE yuruna_pool_lab_token_exchanges_total counter\n")
			for _, oc := range []string{"ok", "refused", "throttled"} {
				fmt.Fprintf(&b, "yuruna_pool_lab_token_exchanges_total{pool=%q,outcome=%q} %d\n", s.pool, oc, view.LabExchangeCount(oc))
			}
		}

		// Incident correlation signals (N-failures-in-M-minutes).
		fmt.Fprintf(&b, "# HELP yuruna_pool_incidents_active Hosts currently in an incident (>= incidentN fails within the window).\n# TYPE yuruna_pool_incidents_active gauge\nyuruna_pool_incidents_active %d\n", len(view.Incident))
		b.WriteString("# HELP yuruna_pool_host_incident 1 if the host is currently in an incident, else 0.\n# TYPE yuruna_pool_host_incident gauge\n")
		for _, h := range ids {
			v := 0
			if view.Incident[h] != nil {
				v = 1
			}
			fmt.Fprintf(&b, "yuruna_pool_host_incident{pool=%q,hostId=%q} %d\n", s.poolFor(view, h), h, v)
		}
		// host_incident_info carries the dominant failure class of an active incident as a
		// label (the 0/1 gauge above stays class-free so its sum() tile is unaffected);
		// emitted only for hosts currently in an incident. Mirrors host_info.
		b.WriteString("# HELP yuruna_pool_host_incident_info Dominant failure class of a host's active incident (value always 1).\n# TYPE yuruna_pool_host_incident_info gauge\n")
		for _, h := range ids {
			if inc := view.Incident[h]; inc != nil {
				cls := inc.DominantClass
				if cls == "" {
					cls = "unknown"
				}
				fmt.Fprintf(&b, "yuruna_pool_host_incident_info{pool=%q,hostId=%q,class=%q} 1\n", s.poolFor(view, h), h, cls)
			}
		}
		b.WriteString("# HELP yuruna_pool_host_recent_fail_count Failed cycles for this host within the incident window.\n# TYPE yuruna_pool_host_recent_fail_count gauge\n")
		for _, h := range ids {
			fmt.Fprintf(&b, "yuruna_pool_host_recent_fail_count{pool=%q,hostId=%q} %d\n", s.poolFor(view, h), h, len(view.FailWindow[h]))
		}
		// Cross-host (pool-wide) incident: _wide_incident is the hysteresis state set
		// by evaluateIncidents; _wide_incident_hosts is the instantaneous count of
		// distinct hosts that failed within crossWin.
		poolInc := 0
		if view.PoolIncident != nil {
			poolInc = 1
		}
		// Window this count against the last completed poll's clock (not scrape
		// time) so it stays consistent with the latched yuruna_pool_wide_incident
		// above: evaluateIncidents decides that flag at the poll using the same
		// window, so a scrape-time cut would let hosts age out and disagree with a
		// still-set flag between polls. Before the first poll LastPoll is zero, but a
		// Loki rehydrate can already have seeded failWindow and restored the
		// incident, so fall back to scrape time there to report the true recent
		// count rather than a forced zero that would disagree with the restored flag.
		ref := view.LastPoll()
		if ref.IsZero() {
			ref = time.Now().UTC()
		}
		crossCut := ref.Add(-s.crossWin)
		recentHosts := 0
		for _, fw := range view.FailWindow {
			if len(fw) > 0 && fw[len(fw)-1].At.After(crossCut) {
				recentHosts++
			}
		}
		fmt.Fprintf(&b, "# HELP yuruna_pool_wide_incident 1 if a pool-wide (cross-host) incident is active.\n# TYPE yuruna_pool_wide_incident gauge\nyuruna_pool_wide_incident %d\n", poolInc)
		fmt.Fprintf(&b, "# HELP yuruna_pool_wide_incident_hosts Distinct hosts that failed within the cross-host window.\n# TYPE yuruna_pool_wide_incident_hosts gauge\nyuruna_pool_wide_incident_hosts %d\n", recentHosts)
		// wide_incident_info carries the pinned same-class of an active pool-wide incident
		// as a label (the 0/1 gauge above stays class-free); emitted only when active.
		b.WriteString("# HELP yuruna_pool_wide_incident_info Pinned failure class of the active pool-wide incident (value always 1).\n# TYPE yuruna_pool_wide_incident_info gauge\n")
		if view.PoolIncident != nil {
			cls := view.PoolIncident.Class
			if cls == "" {
				cls = "unknown"
			}
			fmt.Fprintf(&b, "yuruna_pool_wide_incident_info{pool=%q,class=%q} 1\n", s.pool, cls)
		}
		// Pool gating: advisory degraded/alert latch + the quorum inputs (keyed by pool
		// only -- low cardinality). _members_*/_healthy_fraction/_healthy_threshold/
		// _degraded are emitted for every pool with a member (observability); _alert_active
		// only for pools that authored a gating block (the host-side notifier reads ==1 to
		// deliver), so an un-configured pool is observed but never paged.
		gatePools := make([]string, 0, len(view.PoolGate))
		for p := range view.PoolGate {
			gatePools = append(gatePools, p)
		}
		sort.Strings(gatePools)
		b.WriteString("# HELP yuruna_pool_members_total Pool members currently in the view (within hostTtl).\n# TYPE yuruna_pool_members_total gauge\n")
		for _, p := range gatePools {
			fmt.Fprintf(&b, "yuruna_pool_members_total{pool=%q} %d\n", p, view.PoolGate[p].LastTotal)
		}
		b.WriteString("# HELP yuruna_pool_members_healthy Pool members counted healthy (reachable, running/pass/idle, not in an incident).\n# TYPE yuruna_pool_members_healthy gauge\n")
		for _, p := range gatePools {
			fmt.Fprintf(&b, "yuruna_pool_members_healthy{pool=%q} %d\n", p, view.PoolGate[p].LastHealthy)
		}
		b.WriteString("# HELP yuruna_pool_healthy_fraction Fraction of pool members counted healthy on the last poll.\n# TYPE yuruna_pool_healthy_fraction gauge\n")
		for _, p := range gatePools {
			fmt.Fprintf(&b, "yuruna_pool_healthy_fraction{pool=%q} %g\n", p, view.PoolGate[p].LastFraction)
		}
		b.WriteString("# HELP yuruna_pool_healthy_threshold Configured healthy-fraction threshold (default 0.5); a Grafana rule needs no hardcode.\n# TYPE yuruna_pool_healthy_threshold gauge\n")
		for _, p := range gatePools {
			fmt.Fprintf(&b, "yuruna_pool_healthy_threshold{pool=%q} %g\n", p, view.PoolGate[p].LastThreshold)
		}
		b.WriteString("# HELP yuruna_pool_degraded 1 if the healthy fraction stayed below the threshold for >= degradedAfterSeconds (advisory).\n# TYPE yuruna_pool_degraded gauge\n")
		for _, p := range gatePools {
			v := 0
			if view.PoolGate[p].Degraded {
				v = 1
			}
			fmt.Fprintf(&b, "yuruna_pool_degraded{pool=%q} %d\n", p, v)
		}
		b.WriteString("# HELP yuruna_pool_alert_active 1 if the pool's degraded alert is latched (authored-gating pools only).\n# TYPE yuruna_pool_alert_active gauge\n")
		for _, p := range gatePools {
			if !view.PoolGate[p].Authored {
				continue
			}
			v := 0
			if view.PoolGate[p].AlertFired {
				v = 1
			}
			fmt.Fprintf(&b, "yuruna_pool_alert_active{pool=%q} %d\n", p, v)
		}

		b.WriteString("# HELP yuruna_pool_cycles_pass_total Terminal passing cycles observed.\n# TYPE yuruna_pool_cycles_pass_total counter\n")
		for _, h := range ids {
			var total int64
			for source, n := range passTotals {
				if view.CanonicalHostID(source) == h {
					total += n
				}
			}
			fmt.Fprintf(&b, "yuruna_pool_cycles_pass_total{pool=%q,hostId=%q} %d\n", s.poolFor(view, h), h, total)
		}
		b.WriteString("# HELP yuruna_pool_cycles_fail_total Terminal failing cycles observed.\n# TYPE yuruna_pool_cycles_fail_total counter\n")
		for _, h := range ids {
			var total int64
			for source, n := range failTotals {
				if view.CanonicalHostID(source) == h {
					total += n
				}
			}
			fmt.Fprintf(&b, "yuruna_pool_cycles_fail_total{pool=%q,hostId=%q} %d\n", s.poolFor(view, h), h, total)
		}
		// Materialize the metrics text and release the lock before writing to the client, so a slow
		// scraper connection cannot hold the view's lock across the network write and stall the
		// poll goroutine (mirrors handlePoolStatus).
		out = b.String()
	})
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = io.WriteString(w, out)
}

// --- REGION: Incident and health as JSON
// Both of these existed only as Prometheus exposition. A dashboard could show
// them and an operator could read them off a panel; nothing could ASK for them.
// That is the gap the MCP surface exists to close, and it is closed with routes
// rather than with tools reading state directly, so the tool and the metric are
// one body produced once -- the rule every mcp.go in this tree states.
//
// Read-only and ungated, matching /api/v1/pool-status: this is the same view
// the dashboard already renders to anyone who can load it.

// handlePoolIncidents answers which hosts are currently in an incident, what
// class of failure opened it, and whether a pool-wide incident is running.
func (s *poolState) handlePoolIncidents(w http.ResponseWriter, _ *http.Request) {
	now := time.Now()
	pool := s.pool
	win := s.incidentWin
	threshold := s.incidentN
	var hosts []map[string]any
	var poolWide map[string]any
	s.st.Do(func(view *poolstate.View) {
		hosts = make([]map[string]any, 0, len(view.Incident))
		for hostID, inc := range view.Incident {
			if inc == nil {
				continue
			}
			// Recount the window here rather than trusting a stored total: the
			// window ages continuously and a count captured at open would be stale
			// the moment it was read.
			recent := 0
			for _, fr := range view.FailWindow[hostID] {
				if now.Sub(fr.At) <= win {
					recent++
				}
			}
			hosts = append(hosts, map[string]any{
				"hostId":          hostID,
				"incidentId":      inc.ID,
				"startedUtc":      inc.StartedAt.UTC().Format(time.RFC3339),
				"dominantClass":   inc.DominantClass,
				"peakFailCount":   inc.Peak,
				"recentFailCount": recent,
			})
		}
		if view.PoolIncident != nil {
			poolWide = map[string]any{
				"active":        true,
				"incidentId":    view.PoolIncident.ID,
				"startedUtc":    view.PoolIncident.StartedAt.UTC().Format(time.RFC3339),
				"class":         view.PoolIncident.Class,
				"peakHostCount": view.PoolIncident.PeakHosts,
			}
		} else {
			poolWide = map[string]any{"active": false}
		}
	})

	sort.Slice(hosts, func(i, j int) bool {
		return hosts[i]["hostId"].(string) < hosts[j]["hostId"].(string)
	})
	httpserve.WriteJSON(w, map[string]any{
		"ok":              true,
		"pool":            pool,
		"windowMinutes":   int(win.Minutes()),
		"failsToOpen":     threshold,
		"activeHostCount": len(hosts),
		"hosts":           hosts,
		"poolWide":        poolWide,
		"asOfUtc":         now.UTC().Format(time.RFC3339),
	})
}

// handlePoolHealth answers the pool health gate: what fraction of members are
// healthy, the threshold that fraction is judged against, and whether the
// advisory degraded/alert latch has fired.
// handleCycleLinks answers the three navigating destinations the state-timeline
// panel offers on a click, for a caller that cannot click.
//
// The timeline is a canvas: its blocks, its colors and its context menu reach a
// screen reader as nothing at all, and two of its actions -- open the cycle
// results, share them -- exist nowhere else in the UI. This route is their text
// equivalent, and it resolves through resolveClickedCycle, the same body the
// redirects use, so a link handed out here cannot point somewhere a click would
// not go.
//
// hostStatusUrl deliberately carries NO control proof, unlike /go/host. That
// fragment is a short-lived credential minted for a browser navigation; putting
// one in a JSON body would move a credential onto an enumerable read surface to
// no benefit, since a caller reading this cannot act on the host UI anyway.
func (s *poolState) handleCycleLinks(w http.ResponseWriter, r *http.Request) {
	base, folder, ok := s.resolveClickedCycle(w, r)
	if !ok {
		return
	}
	hostID := normalizeHostID(strings.TrimSpace(r.URL.Query().Get("host")))

	// resolveClickedCycle answers the folder; the cycle's own start time comes
	// from the in-memory view when the caller asked for the current cycle.
	cycleStart := ""
	s.st.Do(func(view *poolstate.View) {
		if hv := view.Hosts[hostID]; hv != nil && hv.Status != nil {
			if path.Base(strings.Trim(hv.Status.CycleFolderUrl, "/")) == path.Base(strings.Trim(folder, "/")) {
				cycleStart = hv.Status.StartedAt
			}
		}
	})

	results := s.cycleResultsTarget(hostID, base, folder)
	// The archive target is a path on this service. A caller that cannot see the
	// address bar has nothing to resolve it against, so make it whole here.
	if strings.HasPrefix(results, "/") {
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		results = scheme + "://" + r.Host + results
	}

	payload := map[string]any{
		"ok":            true,
		"hostId":        hostID,
		"resultsUrl":    results,
		"hostStatusUrl": strings.TrimRight(base, "/"),
	}
	if cycleStart != "" {
		payload["cycleStartUtc"] = cycleStart
	}
	if share := cycleShareTarget(base, folder); share != "" {
		payload["shareUrl"] = share
	}
	httpserve.WriteJSON(w, payload)
}

func (s *poolState) handlePoolHealth(w http.ResponseWriter, _ *http.Request) {
	now := time.Now()
	pool := s.pool
	var lastPoll time.Time
	var payload map[string]any
	s.st.Do(func(view *poolstate.View) {
		lastPoll = view.LastPoll()
		gate := view.PoolGate[s.pool]
		if gate == nil {
			// No poll has computed the latch yet. Say so rather than reporting a
			// healthy pool nobody has looked at.
			payload = map[string]any{"evaluated": false}
		} else {
			payload = map[string]any{
				"evaluated":           true,
				"membersHealthy":      gate.LastHealthy,
				"membersTotal":        gate.LastTotal,
				"healthyFraction":     gate.LastFraction,
				"healthyThreshold":    gate.LastThreshold,
				"degraded":            gate.Degraded,
				"alertActive":         gate.AlertFired,
				"authoredGating":      gate.Authored,
				"consecutiveDegraded": gate.ConsecDegraded,
				"consecutiveHealthy":  gate.ConsecHealthy,
			}
			if !gate.BelowSince.IsZero() {
				payload["belowThresholdSinceUtc"] = gate.BelowSince.UTC().Format(time.RFC3339)
			}
			if gate.AlertFired && !gate.AlertStartedAt.IsZero() {
				payload["alertStartedUtc"] = gate.AlertStartedAt.UTC().Format(time.RFC3339)
				payload["alertId"] = gate.AlertID
			}
		}
	})

	payload["ok"] = true
	payload["pool"] = pool
	payload["asOfUtc"] = now.UTC().Format(time.RFC3339)
	if !lastPoll.IsZero() {
		payload["lastPollUtc"] = lastPoll.UTC().Format(time.RFC3339)
	}
	httpserve.WriteJSON(w, payload)
}

// ingestLineHostID extracts the hostId field from one pushed NDJSON event line, or
// "" when absent/unparseable. Used to reject a line whose claimed hostId disagrees
// with the IP-resolved sender identity (a member may push only its own events).
func ingestLineHostID(ln string) string {
	var e struct {
		HostId string `json:"hostId"`
	}
	if json.Unmarshal([]byte(ln), &e) == nil {
		return e.HostId
	}
	return ""
}

// fileReadable reports whether path is a readable, non-empty regular file -- the
// gate for activating TLS / auth, so a missing or empty cert/token file gracefully
// degrades to plain HTTP / ingest-disabled rather than failing to start.
func fileReadable(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular() && fi.Size() > 0
}

// requireInternalBearer checks the internal token and localizes a refusal.
func (s *poolState) requireInternalBearer(w http.ResponseWriter, r *http.Request) bool {
	const prefix = "Bearer "
	auth := r.Header.Get("Authorization")
	if s.authToken == "" || !strings.HasPrefix(auth, prefix) || subtle.ConstantTimeCompare([]byte(auth[len(prefix):]), []byte(s.authToken)) != 1 {
		localizedHTTPError(w, r, "aggregator.unauthorized", http.StatusUnauthorized)
		return false
	}
	return true
}

// handleIngest is the push surface: a runner-side forwarder POSTs its cycle's
// NDJSON event lines here so they reach Loki without waiting for the next pull
// (closing the between-poll trailing-event gap). It SUPPLEMENTS pull, never replaces
// it -- a pushed line and the later-pulled copy carry the event's own timestamp
// (eventNano), so Loki drops the exact (ts,line) duplicate and the overlap is harmless.
//
// Security of the new inbound write route: (1) gated on a configured shared bearer
// token -- with none the route is DISABLED (503), never exposed unauthenticated; (2)
// Bearer checked constant-time BEFORE the body is read; (3) IDENTITY BINDING -- the
// {pool,hostId} Loki labels come from resolving the sender's SOURCE IP against the
// pull-discovered view, NOT the body, so a shared-token holder can push only as the
// host currently at its own IP (a compromised member cannot forge another host's
// telemetry; an undiscovered IP is rejected -- push never bypasses discovery); (4)
// each line runs through redactEventLine (identical to the pull path) and a body
// hostId disagreeing with the bound identity is rejected; (5) size + line caps mirror
// the pull side. Telemetry-only: it ships to Loki and reaches no control plane.
func (s *poolState) handleIngest(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.ingest_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.requireInternalBearer(w, r) {
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxEventFetch))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	// Scan the body incrementally (NOT strings.Split, which would materialize every line
	// before the cap can fire): stop the moment the running line count would exceed
	// maxEventPush, so a million-tiny-line body can't burn parse/alloc work past the cap
	// (mirrors the pull-side tailEvents scan). Collect the batch's body hostId for identity
	// binding; a batch that mixes hostIds is rejected.
	var lines []string
	bodyHostID := ""
	mixed := false
	consumed := 0
	for consumed < len(body) {
		var ln string
		if nl := bytes.IndexByte(body[consumed:], '\n'); nl < 0 {
			ln = strings.TrimRight(string(body[consumed:]), "\r")
			consumed = len(body)
		} else {
			ln = strings.TrimRight(string(body[consumed:consumed+nl]), "\r")
			consumed += nl + 1
		}
		if ln == "" {
			continue
		}
		if len(lines) >= maxEventPush {
			localizedHTTPError(w, r, "aggregator.too_many_lines", http.StatusRequestEntityTooLarge)
			return
		}
		if bid := ingestLineHostID(ln); bid != "" {
			if bodyHostID == "" {
				bodyHostID = bid
			} else if bodyHostID != bid {
				mixed = true
			}
		}
		lines = append(lines, redactEventLine(ln))
	}
	if mixed {
		localizedHTTPError(w, r, "aggregator.batch_mixes_multiple_hostids", http.StatusForbidden)
		return
	}
	if len(lines) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// Identity binding (the anti-forgery control): resolve {pool,hostId} from the SOURCE IP
	// against the pull-discovered view, NOT the body. Hosts currently at this IP:
	//   * a body hostId MUST be one of them (else the IP doesn't own that hostId -> reject);
	//   * with no body hostId, bind only when exactly one host sits at this IP (a shared IP
	//     without a hostId is ambiguous -> reject). Empty CurrentIP never matches.
	hostID := ""
	poolLabel := ""
	s.st.Do(func(view *poolstate.View) {
		var atIP []string
		for hid, hv := range view.Hosts {
			if hv.CurrentIP != "" && hv.CurrentIP == srcIP {
				atIP = append(atIP, hid)
			}
		}
		if bodyHostID != "" {
			for _, hid := range atIP {
				if hid == bodyHostID {
					hostID = hid
					break
				}
			}
		} else if len(atIP) == 1 {
			hostID = atIP[0]
		}
		if hostID != "" {
			poolLabel = s.poolFor(view, hostID)
		}
	})
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.sender_identity_could_not_be_bound_undiscovered_ip_hostid_not_own", http.StatusForbidden)
		return
	}
	if err := s.pushEvents(s.httpClient, s.lokiURL, poolLabel, hostID, lines, time.Now().UTC()); err != nil && s.outbox != nil {
		localizedHTTPError(w, r, "aggregator.ingest_queue_full", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// pushHostAnnounce records a host self-announce in Loki so a collector restart
// restores the host's address immediately instead of waiting for it to show up
// in the squid log again. Use the presence stream that startup already reads.
func pushHostAnnounce(client *http.Client, lokiURL, pool, hostID, baseURL string, now time.Time) error {
	if lokiURL == "" || hostID == "" {
		return nil
	}
	line, _ := json.Marshal(map[string]any{"hostId": hostID, "baseUrl": baseURL})
	return pushLokiStream(client, lokiURL, "presence",
		map[string]string{"pool": pool, "hostId": hostID, "src": "presence"}, line, now)
}

// handleHostAnnounce is the host-presence write surface: a host POSTs its own
// hostId when its address changes, on service start and on a periodic beacon,
// so the pool view follows it across a DHCP renumber. The address comes from
// the connection and the claim is confirmed against that address's
// /runtime/status.json before any host row moves. See https://yuruna.link/42c29d04-0003.
func (s *poolState) handleHostAnnounce(w http.ResponseWriter, r *http.Request) {
	if s.announceTtl <= 0 {
		localizedHTTPError(w, r, "aggregator.announce_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAnnounceBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var a struct {
		HostId     string `json:"hostId"`
		StatusPort int    `json:"statusPort"`
	}
	if err := json.Unmarshal(body, &a); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_announce", http.StatusBadRequest)
		return
	}
	if !announceHostIDRE.MatchString(a.HostId) {
		localizedHTTPError(w, r, "aggregator.invalid_hostid", http.StatusBadRequest)
		return
	}
	if a.StatusPort <= 0 || a.StatusPort > 65535 {
		localizedHTTPError(w, r, "aggregator.invalid_statusport", http.StatusBadRequest)
		return
	}
	baseURL := fmt.Sprintf("http://%s:%d", srcIP, a.StatusPort)
	if problem := extensionTargetProblem(baseURL); problem != "" {
		http.Error(w, problem, http.StatusBadRequest)
		return
	}

	// The confirm. Reuses the poll's own fetch so an announced host is admitted
	// on exactly the evidence a discovered one is, and refuses the announce
	// when the identity does not match what that address actually serves.
	st, _, err := hostpoll.FetchStatus(s.httpClient, baseURL)
	if err != nil {
		localizedHTTPError(w, r, "aggregator.announced_address_did_not_serve_status_json", http.StatusBadRequest)
		return
	}
	if st == nil || !strings.EqualFold(st.HostId, a.HostId) {
		localizedHTTPError(w, r, "aggregator.announced_address_serves_a_different_hostid", http.StatusBadRequest)
		return
	}

	now := time.Now().UTC()
	// Startup rehydrates the presence stream using the collector pool label.
	poolLabel := s.pool
	s.st.Do(func(view *poolstate.View) {
		if hv := view.Hosts[a.HostId]; hv != nil {
			hv.CurrentIP = srcIP
			hv.BaseURL = baseURL
			hv.LastSeenUnixMs = now.UnixMilli()
			hv.LastError = ""
		} else {
			s.seedHostStubLocked(view, a.HostId, baseURL, now)
		}
	})

	// 2xx means recorded, not merely received -- the same contract /announce
	// keeps, and for the same reason: a beacon told 2xx waits a whole period
	// before it announces again, so a 2xx for a line that never reached Loki
	// costs the pool up to a beacon period of a host it cannot resolve after
	// the next restart.
	if err := pushHostAnnounce(s.httpClient, s.lokiURL, poolLabel, a.HostId, baseURL, now); err != nil {
		localizedHTTPError(w, r, "aggregator.announce_accepted_but_not_recorded", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":        true,
		"hostId":    a.HostId,
		"currentIp": srcIP,
		"baseUrl":   baseURL,
	})
}

// handleHostAddress answers "where is this hostId now" for one host.
//
// The guest resolver's route. It exists as a narrow alternative to pool-status
// because a guest parses this during bootstrap, before anything is installed --
// no jq, no JSON library, just sed over the body -- and a single flat object is
// something a line-oriented parser can read with certainty where a whole pool
// view is not.
//
// Deliberately NOT /go/host, which answers the same question for a browser: that
// route mints a short-lived control proof into its redirect, and a guest holding
// a control proof for its own host is the capability the status service's
// control-route authentication exists to deny. This route mints nothing and
// redirects nowhere.
//
// 404 rather than an empty 200 for an unknown host: the guest must be able to
// tell "the pool does not know this host" from "the pool says it is nowhere",
// and only the first is worth falling back to the older pool-status route for.
func (s *poolState) handleHostAddress(w http.ResponseWriter, r *http.Request) {
	hostID := strings.TrimSpace(r.URL.Query().Get("hostId"))
	if !announceHostIDRE.MatchString(hostID) {
		localizedHTTPError(w, r, "aggregator.invalid_hostid", http.StatusBadRequest)
		return
	}
	var out struct {
		HostId    string `json:"hostId"`
		BaseURL   string `json:"baseUrl"`
		CurrentIP string `json:"currentIp"`
		Reachable bool   `json:"reachable"`
	}
	found := false
	s.st.Do(func(view *poolstate.View) {
		hv := view.Hosts[hostID]
		found = hv != nil && hv.BaseURL != ""
		if found {
			// Field order is not cosmetic: hostId and baseUrl stay adjacent and
			// ahead of anything nested, because the guest resolver's fallback leg
			// splits pool-status on '{' and requires both keys on one fragment.
			// Reordering hostView's first fields silently breaks that parser.
			out.HostId = hv.HostId
			out.BaseURL = hv.BaseURL
			out.CurrentIP = hv.CurrentIP
			out.Reachable = hv.Reachable
		}
	})
	if !found {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	// An address lookup is the one answer in this framework that must never be
	// served from a cache: the whole point is that it changes.
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(out)
}

// handleAnnounce is the extension-presence write surface: service VMs POST
// {hostId, area, targetPort, active} beacons so the dashboard's Extension
// hosts row survives the owning host's status service being down. Open by
// design but contained (self-identity binding; goodbyes also match an
// address-less rehydrated entry). See docs/extensions-api.md (POST /announce).
func (s *poolState) handleAnnounce(w http.ResponseWriter, r *http.Request) {
	if s.announceTtl <= 0 {
		localizedHTTPError(w, r, "aggregator.announce_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAnnounceBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var a struct {
		HostId     string `json:"hostId"`
		Area       string `json:"area"`
		Target     string `json:"target"`
		TargetPort int    `json:"targetPort"`
		Active     *bool  `json:"active"`
	}
	if err := json.Unmarshal(body, &a); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_announce", http.StatusBadRequest)
		return
	}
	if a.Area == "" {
		a.Area = stashArea
	}
	if !announceHostIDRE.MatchString(a.HostId) || !announceAreaRE.MatchString(a.Area) {
		localizedHTTPError(w, r, "aggregator.invalid_hostid_or_area", http.StatusBadRequest)
		return
	}
	// Resolve the advertised service URL. An explicit target must point at the
	// SENDER (URL host == source IP) -- the announcer advertises itself, never a
	// third party; otherwise the URL is derived from the source IP + the
	// announced UI port (no port advertised -> presence only, no link).
	target := ""
	switch {
	case strings.TrimSpace(a.Target) != "":
		target = strings.TrimRight(strings.TrimSpace(a.Target), "/")
		u, perr := url.Parse(target)
		if perr != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
			localizedHTTPError(w, r, "aggregator.invalid_target_url", http.StatusBadRequest)
			return
		}
		if u.Hostname() != srcIP {
			localizedHTTPError(w, r, "aggregator.target_host_must_be_the_announcing_address", http.StatusForbidden)
			return
		}
	case a.TargetPort == 80:
		target = "http://" + srcIP
	case a.TargetPort > 0 && a.TargetPort < 65536:
		target = "http://" + net.JoinHostPort(srcIP, strconv.Itoa(a.TargetPort))
	}
	// The address still has to be one the pool could route to. A sender behind a
	// NAT that rewrites the source address, or a proxy header this handler ever
	// learns to trust, is how a loopback or link-local value would arrive here.
	if why := extensionTargetProblem(target); why != "" {
		localizedHTTPErrorArgs(w, r, "aggregator.invalid_target_address_detail", http.StatusBadRequest, map[string]any{"detail": why})
		return
	}
	active := a.Active == nil || *a.Active
	key := announceKey(a.HostId, a.Area)
	poolLabel := s.pool
	accepted := true
	ignoredGoodbye := false
	s.st.Do(func(view *poolstate.View) {
		if !active {
			// Only the entry's own source (or an address-less rehydrated entry)
			// may remove it; anyone else's goodbye is a silent no-op.
			if av := view.Announce[key]; av != nil && (av.SourceIP == "" || av.SourceIP == srcIP) {
				delete(view.Announce, key)
			} else if av != nil {
				ignoredGoodbye = true
			}
		} else {
			av := view.Announce[key]
			if av == nil {
				if len(view.Announce) >= maxAnnounce {
					accepted = false
				} else {
					av = &announceView{HostId: a.HostId, Area: a.Area}
					view.Announce[key] = av
				}
			}
			if av != nil {
				av.Target, av.SourceIP, av.LastSeenUnixMs = target, srcIP, time.Now().UTC().UnixMilli()
			}
		}
	})
	if ignoredGoodbye {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if !accepted {
		localizedHTTPError(w, r, "aggregator.too_many_announced_extensions", http.StatusTooManyRequests)
		return
	}
	// Confirm a NEWLY announced address right here rather than at the next poll:
	// a service that just came up is then resolvable immediately, which is what
	// a lab bringing up its stash and its cycles together depends on. Costs one
	// bounded probe, and only on an address this aggregator has no verdict for --
	// the steady re-announces of a known address skip it. The address
	// is the sender's own (bound above), so this can only ever probe back at the
	// caller: an open route cannot be turned into a scan of the LAN.
	if active {
		s.confirmExtensionTarget(s.httpClient, key, target, time.Now().UTC())
	}
	// Push after the unlock so a slow Loki never stalls the state above;
	// goodbyes are pushed too so the latest line decides restart state.
	//
	// The push OUTCOME is the reply, because 2xx is what stops the announcer:
	// its beacon retries a non-2xx on its catch-up cadence and sleeps a full
	// re-announce period after a 2xx. Answering 2xx for a line that never reached Loki
	// therefore trades a retry the announcer would have made in seconds for an
	// entry that exists only in this process's memory -- and the window where
	// that matters is precisely a restart, which is also when an aggregator is
	// most likely to be restarted by whatever brought it up. The entry is KEPT
	// either way: it is live and serving right now, and the retry is what makes
	// it durable. Where no Loki is configured there is nothing to lose, and the
	// push reports success (pushLokiStream), so those pools still get 2xx.
	if err := pushAnnounce(s.httpClient, s.lokiURL, poolLabel, a.HostId, a.Area, target, active, time.Now().UTC()); err != nil {
		localizedHTTPError(w, r, "aggregator.announce_accepted_but_not_durably_recorded_retry", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// readAuthTokenFile loads the internal authentication key this proxy mints control
// proofs with, gates /ingest on, and hands out through the lab-token exchange. An
// empty return leaves every one of those disabled rather than open.
//
// Surrounding whitespace is trimmed because the key reaches the file through
// cloud-init, which is free to terminate it with a newline; the PowerShell side
// that computes the matching control tag trims at its own read, and a key that
// differed by one byte between the two would report the whole pool as onsite-only.
// defaultPath and legacyPath are parameters rather than reads of the constants so a
// test can exercise the fallback without writing under /etc.
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
			// through the proxy. Runs before the first pollOnce so its seeds are
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
		// With the leaf present, :9400 answers BOTH protocols on the one port
		// (dualProtocolListener): TLS for the token-bearing clients (the ingest
		// forwarder's Authorization bearer, Set-LabToken's exchange, the
		// Prometheus scrape), plain HTTP for the browser-facing /go/* deep-links.
		// The deep-link hop only redirects the operator's browser to a plain-http
		// host status page, so TLS there would add a proxy-CA interstitial
		// (operator browsers do not trust the proxy CA) while protecting nothing
		// the very next hop does not already carry in clear -- the minted control
		// proof travels on to the host in a cleartext header either way.
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
