// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// pool-aggregator: read-only multi-host pool view for the Yuruna test harness.
//
// Runs on the caching-proxy machine (the pool services host). Auto-discovers
// pool members from the squid access log (no host list), identifies them by
// the stable hostId (DHCP-resilient, no DNS), and ships cycle transitions +
// per-step events to Loki/Prometheus for the Grafana pool dashboard.
// Read-only: killing it leaves every runner testing unaffected.
//
// Full design and operator guide: https://yuruna.link/pool-aggregator (README.md).
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultListenAddr  = ":9400"
	defaultSquidLog    = "/var/log/squid/yuruna_access.log"
	defaultLokiURL     = "http://127.0.0.1:3100/loki/api/v1/push"
	defaultPool        = "default"
	defaultStatusPort  = 8080
	defaultInterval    = 30 * time.Second
	defaultDiscoverWin = 35 * time.Minute   // just over a 30-min DHCP lease
	defaultHostTTL     = 24 * time.Hour     // keep a hostId in the view this long after last contact
	defaultRehydrate   = 7 * 24 * time.Hour // restore cycle counts from Loki on startup over this trailing window
	probeTimeout       = 3 * time.Second    // LAN status probe (refused is instant; filtered times out)
	pushTimeout        = 10 * time.Second
	maxProbe           = 8          // bounded concurrent probes per tick
	logTailBytes       = 512 * 1024 // bytes scanned from EOF for recent client IPs
	seenTTL            = 25 * time.Hour
	eventsFile         = "cycle.events.ndjson" // per-cycle NDJSON event log on each host
	maxEventFetch      = 4 << 20               // bytes read from a host's events file per poll
	maxEventPush       = 1000                  // NDJSON lines shipped per host per poll (catch-up is bounded)
	defaultIncidentN   = 3                     // failed cycles within the window to open an incident
	defaultIncidentWin = 2 * time.Hour         // trailing window for the N-failures-in-M-minutes rule
	defaultCrossN      = 3                     // distinct hosts failing within crossWin to open a pool-wide incident
	defaultCrossWin    = 15 * time.Minute      // window for cross-host "failing together" correlation
	// Extension-presence announce (POST /announce): a service VM (e.g. the
	// stash server) self-reports the extension it runs, independent of the
	// owning host's status server. The TTL tolerates two missed beacons of the
	// stash server's default 15-minute period before the row is reaped.
	defaultAnnounceTTL = 45 * time.Minute
	maxAnnounce        = 512     // distinct (hostId,area) announce entries kept in memory
	maxAnnounceBody    = 4 << 10 // bytes read from one announce POST
	// stashArea is the extension area of the stash service -- the default for
	// /go/stash and the area whose target rides as pool-status stashBaseUrl.
	stashArea = "stash-service"
	// Pool gating defaults (mirror test/schemas/pools.schema.yml gating.*): the
	// advisory degraded/alert policy a pool inherits when it authors a partial (or
	// no) gating block. degradedAfter is the sustained-below-threshold window;
	// failures/successes are the poll-count alert hysteresis.
	defaultFailuresBeforeAlert  = 3
	defaultSuccessesBeforeRearm = 2
	defaultHealthyThreshold     = 0.5
	defaultDegradedAfter        = 30 * time.Minute
)

// squid yuruna logformat: field 1 = %ts.%03tu (epoch.ms), field 3 = %>a (client
// IP). Capture both; the response-time field (%6tr) sits between them.
var clientIPRE = regexp.MustCompile(`^(\d+\.\d+)\s+\S+\s+(\S+)`)

// gitCommitRef is one status.json gitCommits entry: the machine-routable sha +
// repoUrl (hostname-free, so it stays safe on the unauthenticated pool surface).
type gitCommitRef struct {
	Sha     string `json:"sha"`
	RepoURL string `json:"repoUrl"`
}

// gitCommitRefs is the gitCommits array with a DEFENSIVE decoder. status.json's
// gitCommits is expected flat -- [{sha,repoUrl},...] -- but a host whose writer
// hits the PowerShell array-double-wrap trap emits it nested one level too deep
// ([[{sha,repoUrl},...]]). A strict []gitCommitRef decode of that nested shape
// fails the ENTIRE status.json parse, which would silently drop the host from
// the pool view over one optional display field. So: try the flat shape, then
// the double-wrapped shape (unwrap + flatten), and on any unrecognized shape
// yield an empty list rather than erroring -- the Commit column blanks but the
// host stays reachable. Guards the pool view against one host's malformed
// gitCommits (the host-side writer fix is the real correction).
type gitCommitRefs []gitCommitRef

func (g *gitCommitRefs) UnmarshalJSON(b []byte) error {
	var flat []gitCommitRef
	if err := json.Unmarshal(b, &flat); err == nil {
		*g = flat
		return nil
	}
	var nested [][]gitCommitRef
	if err := json.Unmarshal(b, &nested); err == nil {
		out := gitCommitRefs{}
		for _, inner := range nested {
			out = append(out, inner...)
		}
		*g = out
		return nil
	}
	*g = nil
	return nil
}

// hostStatus mirrors the subset of each host's /runtime/status.json the pool
// view needs. Unknown fields ignored; missing fields tolerated.
type hostStatus struct {
	HostId string `json:"hostId"`
	Host   string `json:"host"` // hostType, e.g. host.windows.hyper-v
	// Hostname is deliberately NOT parsed or emitted (json:"-"): the pool view --
	// including the unauthenticated /api/v1/pool-status JSON snapshot, which
	// serializes this struct -- is hostname-free, so it stays safe to expose
	// without auth. Hosts are identified by hostId; the hostname lives only on the
	// host's own (separately authenticated) status page. The field is retained
	// (not deleted) to document that status.json carries a hostname we drop.
	Hostname       string `json:"-"`
	CycleId        string `json:"cycleId"`
	OverallStatus  string `json:"overallStatus"`
	StartedAt      string `json:"startedAt"`
	FinishedAt     string `json:"finishedAt"`
	CycleFolderUrl string `json:"cycleFolderUrl"`
	// CyclePaused mirrors the host's control.cycle-pause flag (status.json sets it on
	// every write + the status server flips it on the pause toggle). Surfaces a paused
	// host as its own "paused" status, the same effective-pause signal the host status
	// page shows -- see statusLabel.
	CyclePaused bool `json:"cyclePaused"`
	// GitCommits mirrors status.json's gitCommits array (framework FIRST, project
	// SECOND by the runner's convention -- see Test.RunnerInnerLoop's
	// GitCommitsList): the source-tree commit(s) the current cycle ran. Drives the
	// pool table's Commit column -- short SHAs plus a per-repo deep-link. Only the
	// machine-routable sha + repoUrl are parsed; a commit id and a repo URL are
	// hostname-free, so they stay safe on the unauthenticated pool surface this
	// struct serializes.
	GitCommits gitCommitRefs `json:"gitCommits"`
	// LastFailure is parsed DELIBERATELY NARROW: only the machine-routable
	// failureClass + severity, never the host's richer lastFailure (errorMessage,
	// vmName, reproCommand, relPath) which would leak host detail onto the
	// unauthenticated /api/v1/pool-status this struct serializes. status.json sets
	// lastFailure at failure time (Test.Status Set-LastFailureSummary); null on pass.
	LastFailure struct {
		FailureClass string `json:"failureClass"`
		Severity     string `json:"severity"`
	} `json:"lastFailure"`
}

// failClassOf returns the (terminal-fail) cycle's failure class, defaulting to
// "unknown" when status.json carries no classified lastFailure.
func (s *hostStatus) failClassOf() string {
	if s == nil || s.LastFailure.FailureClass == "" {
		return "unknown"
	}
	return s.LastFailure.FailureClass
}

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

// hostView is a discovered pool member, keyed by the stable hostId.
type hostView struct {
	HostId         string      `json:"hostId"`
	CurrentIP      string      `json:"currentIp"`
	BaseURL        string      `json:"baseUrl"`
	Reachable      bool        `json:"reachable"`
	LastSeenUnixMs int64       `json:"lastSeenUnixMs"`
	LastError      string      `json:"lastError,omitempty"`
	Status         *hostStatus `json:"status,omitempty"`
	// Version is the host's framework version (the one CalVer line in the repo's
	// VERSION file, served at /yuruna-repo/VERSION -- the same source the host's
	// own status pages read for their header). Refreshed each poll; kept across a
	// transient fetch miss (it is stable). "" until first learned.
	Version string `json:"version,omitempty"`
	// PoolId is the pool this host advertises in its registration record, which
	// the runner derived from pools.yml members[] (the single source of truth).
	// Empty until learned; the aggregator then falls back to the -pool flag.
	PoolId string `json:"poolId,omitempty"`
	// PoolGuid is the pool stable 42-GUID (the dashboard "Pool ID"); empty until learned.
	PoolGuid string `json:"poolGuid,omitempty"`
	// ActiveExtensions are the extension areas this host is ACTIVELY running right
	// now (e.g. "stash-service" when it hosts a stash-server VM) -- distinct from
	// capabilities.extensions (what it COULD run). Read from the host's
	// registration record each poll; drives the dashboard's Extension hosts table.
	// Registration-sourced, so the aggregator never mounts ystash-nas to discover
	// stash servers (no cross-host Config Service / NAS-credential dependency).
	ActiveExtensions []string `json:"activeExtensions,omitempty"`
	// ExtensionTargets maps an active extension area to the deep-link URL the host
	// advertises for it (e.g. "stash-service" -> the stash VM's UI base URL the host
	// resolved into its marker via Get-VMIp). Lets the dashboard's Extension cell
	// /go/stash to the stash VM without the aggregator keeping an address store of its
	// own. Registration-sourced like ActiveExtensions; empty until the host advertises
	// one. Also exposed in /api/v1/pool-status for the stash UI's hostId->stashBaseUrl
	// resolution (docs/design/stash-service-ui.md 3.4).
	ExtensionTargets map[string]string `json:"extensionTargets,omitempty"`
}

// announceView is one extension service's SELF-ANNOUNCED presence (POST
// /announce): the service VM itself reports "hostId X actively runs area Y at
// target Z", refreshed every beacon period. It complements the registration
// path (activeExtensions, read through the owning host's status server): when
// that server is down -- the state a host reboot routinely leaves behind --
// the announce is the only live signal, and it keeps the dashboard's
// Extension hosts row (and the /go/stash redirect) alive. Entries are reaped
// after announceTTL without a refresh, or immediately on an active=false
// goodbye. Serialized into /api/v1/pool-status (announcedExtensions);
// sourceIP stays unexported so the snapshot exposes no requester address.
type announceView struct {
	HostId         string `json:"hostId"`
	Area           string `json:"area"`
	Target         string `json:"target,omitempty"`
	LastSeenUnixMs int64  `json:"lastSeenUnixMs"`
	// sourceIP is the announcing connection's address, kept so only the same
	// sender (the service's current IP) can goodbye the entry. "" when the
	// entry was rehydrated from a target-less Loki line, which then accepts
	// any goodbye rather than pinning a stale address.
	sourceIP string
}

// announceKey is the s.announce map key: one entry per (hostId, area).
func announceKey(hostID, area string) string { return hostID + "|" + area }

// poolStatusEntry is one host in the /api/v1/pool-status snapshot: the
// hostView plus stashBaseUrl, the resolved stash-UI base the stash UI's
// hostId->URL lookup reads (stash-service-ui.md §3.4). Resolved at
// serialization time from the host's registration-advertised extensionTargets,
// with the service's own announce as fallback, so the resolution survives a
// host whose status server is down.
type poolStatusEntry struct {
	*hostView
	StashBaseURL string `json:"stashBaseUrl,omitempty"`
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
// shipped to Loki, so a poll only forwards new lines. Reset when the cycleId
// changes (a new cycle = a new file).
type eventCursor struct {
	cycleId string
	offset  int64 // bytes of the events file already shipped
}

// presenceTarget is one host whose last-known address pollOnce beacons to Loki
// (src=presence) this tick because it was newly discovered or changed IP. Captured
// under s.mu (with its pool label) and pushed after the unlock, so a slow Loki
// never stalls the handlers -- the same snapshot-then-push shape as evTarget.
type presenceTarget struct{ hostID, baseURL, pool string }

// failRec is one in-window failed cycle: when it failed + its failure class.
// Replaces the bare fail-time slice so an incident can carry a class histogram.
type failRec struct {
	t     time.Time
	class string // failureClass; "unknown" when the cycle had no classified lastFailure
}

// incidentState is an open per-host incident: the host has had >= incidentN
// failed cycles within the trailing incidentWin. It resolves once that window
// empties of fails.
type incidentState struct {
	id        string
	startedAt time.Time // earliest fail in the window when the incident opened
	peak      int       // most concurrent in-window fails seen during the incident
	// peakClassHist is the failure-class histogram captured at the moment `peak`
	// was last (re)assigned -- so the resolve line (when the window has aged to ~0)
	// still reports the breakdown the incident peaked at. dominantClass = argmax
	// (lexical tiebreak), the headline class for metrics + display.
	peakClassHist map[string]int
	dominantClass string
}

// poolIncidentState is the single open pool-wide (cross-host) incident: >= crossN
// distinct hosts failed within crossWin WITH THE SAME failure class -- a systemic
// signal (shared cause), not unrelated single-host churn.
type poolIncidentState struct {
	id        string
	startedAt time.Time
	peakHosts int    // most distinct same-class affected hosts seen during the incident
	class     string // the triggering class, PINNED at open; resolve is evaluated against it
}

// gatingPolicy is a pool's authored alerting policy (from pools.yml `gating`,
// carried per-host in host.registration.json). Missing fields are filled from the
// schema defaults at parse time, so a partial block is always complete here.
type gatingPolicy struct {
	FailuresBeforeAlert  int           // consecutive degraded polls before the alert fires
	SuccessesBeforeRearm int           // consecutive non-degraded polls before it re-arms
	HealthyThreshold     float64       // fraction of members that must be healthy
	DegradedAfter        time.Duration // sustained below-threshold window before "degraded"
}

func defaultGatingPolicy() gatingPolicy {
	return gatingPolicy{
		FailuresBeforeAlert:  defaultFailuresBeforeAlert,
		SuccessesBeforeRearm: defaultSuccessesBeforeRearm,
		HealthyThreshold:     defaultHealthyThreshold,
		DegradedAfter:        defaultDegradedAfter,
	}
}

// poolGateState is the per-pool advisory degraded/alert latch. READ-SIDE ONLY: no
// runner consumes it (consensus-gated control is deferred) -- it drives alerting
// (the host-side notifier reads yuruna_pool_alert_active) + dashboard de-noise,
// never a cycle decision. degraded latches when the healthy fraction stays below
// the threshold for >= DegradedAfter (wall-clock); the alert fires/re-arms on a
// poll-count hysteresis so a single flapping poll neither pages nor clears.
type poolGateState struct {
	belowSince     time.Time // zero = currently at/above threshold
	degraded       bool
	authored       bool // the pool advertised a gating block -> eligible to ALERT (not just observe)
	alertFired     bool
	consecDegraded int
	consecHealthy  int
	alertID        string
	alertStartedAt time.Time
	// last* snapshot the most recent poll's computation so handleMetrics emits
	// gauges consistent with the latch decision (same poll), without recomputing.
	lastFraction  float64
	lastHealthy   int
	lastTotal     int
	lastThreshold float64
}

type poolState struct {
	mu           sync.Mutex
	pool         string
	statusPort   int
	incidentN    int                  // open an incident at >= this many fails within incidentWin
	incidentWin  time.Duration        // trailing window for the fail-burst rule
	crossN       int                  // distinct hosts failing within crossWin to open a pool-wide incident
	crossWin     time.Duration        // window for cross-host "failing together"
	hosts        map[string]*hostView // keyed by hostId
	seen         map[string]string    // hostId|cycleId -> last overallStatus pushed
	seenAt       map[string]time.Time
	counted      map[string]bool // hostId|cycleId counted as terminal
	pass         map[string]int64
	fail         map[string]int64
	failWindow   map[string][]failRec      // hostId -> in-window fails (ascending by .t), for incident correlation
	incident     map[string]*incidentState // hostId -> active incident (absent = none)
	poolIncident *poolIncidentState        // single active pool-wide incident (nil = none)
	gating       map[string]gatingPolicy   // pool -> authored gating policy (key present = authored)
	poolGate     map[string]*poolGateState // pool -> advisory degraded/alert latch
	announce     map[string]*announceView  // hostId|area -> self-announced extension presence
	announceTTL  time.Duration             // reap an announce entry not refreshed within this window (0 disables /announce)
	last         time.Time
	// Push-ingest: the shared bearer token gating POST /ingest (empty ->
	// ingest disabled, never an unauthenticated write route), plus the Loki push URL
	// + client the handler needs (set once in main before the server starts; not
	// mutated under mu).
	authToken  string
	lokiURL    string
	httpClient *http.Client
	// eventCur is touched ONLY by the single poll goroutine (in tailEvents and
	// the post-unlock prune below), never by the HTTP handlers, so it needs no
	// lock -- unlike the fields above, which mu guards against handler reads.
	eventCur map[string]*eventCursor // keyed by hostId
}

func newPoolState(pool string, statusPort int) *poolState {
	return &poolState{
		pool: pool, statusPort: statusPort, incidentN: defaultIncidentN, incidentWin: defaultIncidentWin,
		crossN: defaultCrossN, crossWin: defaultCrossWin,
		hosts: map[string]*hostView{}, seen: map[string]string{}, seenAt: map[string]time.Time{},
		counted: map[string]bool{}, pass: map[string]int64{}, fail: map[string]int64{},
		failWindow: map[string][]failRec{}, incident: map[string]*incidentState{},
		gating: map[string]gatingPolicy{}, poolGate: map[string]*poolGateState{},
		announce: map[string]*announceView{}, announceTTL: defaultAnnounceTTL,
		eventCur: map[string]*eventCursor{},
	}
}

// poolFor returns the host's advertised poolId (derived by the runner from
// pools.yml members[]) when known, else the aggregator's -pool flag default. This
// is the per-host telemetry label, so each host's data accumulates under its real
// pool from first probe. MUST be called with s.mu held (reads s.hosts).
func (s *poolState) poolFor(hostID string) string {
	if hv := s.hosts[hostID]; hv != nil && hv.PoolId != "" {
		return hv.PoolId
	}
	return s.pool
}

func isTerminal(status string) bool { return status == "pass" || status == "fail" }

// statusLabel folds reachability + overallStatus into one value for the
// dashboard's per-host table (a string cell); statusCode is the numeric twin
// for the state-timeline panel. Derived from the same source so they never
// disagree. Mapping: unreachable=0, running=1, pass=2, fail=3, idle=4 (reachable
// but no/other cycle status), paused=5.
func (hv *hostView) statusLabel() string {
	if hv == nil || !hv.Reachable {
		return "unreachable"
	}
	if hv.Status == nil {
		return "idle"
	}
	// A host whose cycle-pause flag is set and that is NOT mid-cycle is sitting
	// paused -- report that ABOVE the last cycle's pass/fail so it reads as paused,
	// not as a stale terminal result. Matches the host status page's effective-pause
	// badge (cyclePaused && overallStatus != "running"); a still-running cycle that is
	// only pause-PENDING stays "running" until it stops.
	if hv.Status.CyclePaused && hv.Status.OverallStatus != "running" {
		return "paused"
	}
	switch hv.Status.OverallStatus {
	case "running", "pass", "fail":
		return hv.Status.OverallStatus
	default:
		return "idle"
	}
}

func (hv *hostView) statusCode() int {
	switch hv.statusLabel() {
	case "running":
		return 1
	case "pass":
		return 2
	case "fail":
		return 3
	case "idle":
		return 4
	case "paused":
		return 5
	default: // unreachable
		return 0
	}
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
		log.Printf("squid log %s: %v", logPath, err)
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

// pollOnce discovers + refreshes the pool. Candidate IPs = recent squid-log
// client IPs UNION the last-known IP of every host already in the view (so an
// idle host stays live). Each candidate is probed for /runtime/status.json;
// responders are keyed by their stable hostId. Hosts not refreshed this tick are
// marked unreachable but kept until hostTTL.
func (s *poolState) pollOnce(client *http.Client, squidLog, lokiURL string, now time.Time) {
	cand := map[string]bool{}
	for _, ip := range recentClientIPs(squidLog, defaultDiscoverWin, now) {
		cand[ip] = true
	}
	s.mu.Lock()
	for _, h := range s.hosts {
		if h.CurrentIP != "" {
			cand[h.CurrentIP] = true
		}
	}
	s.mu.Unlock()

	type probeResult struct {
		ip         string
		st         *hostStatus
		errMsg     string            // non-empty when the probe failed: the reason, keyed onto the unreachable host's LastError
		version    string            // framework VERSION ("" = not fetched this poll; caller keeps prior)
		regOK      bool              // host.registration.json was fetched + parsed this poll
		poolID     string            // poolId from the registration record ("" = unpooled/not-yet-derived)
		poolGuid   string            // poolGuid from the registration record ("" = unpooled/not-yet-derived)
		gating     *gatingPolicy     // authored gating policy from the record (nil = pool did not author one)
		activeExt  []string          // extension areas the host is actively running (registration activeExtensions)
		extTargets map[string]string // per-area deep-link URLs the host advertises (registration extensionTargets)
	}
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
			if st, err := fetchStatus(client, base); err == nil && st != nil && st.HostId != "" {
				pr := &probeResult{ip: ip, st: st}
				// Best-effort: learn the host's pool + gating policy from its
				// registration record. A transient miss keeps the prior poolId +
				// gating (handled at apply time).
				if pid, pguid, g, ext, tgt, rerr := fetchRegistration(client, base); rerr == nil {
					pr.regOK, pr.poolID, pr.poolGuid, pr.gating, pr.activeExt, pr.extTargets = true, pid, pguid, g, ext, tgt
				}
				// Best-effort: learn the host's framework version from VERSION. A
				// transient miss leaves pr.version "" and keeps the prior value.
				if v, verr := fetchVersion(client, base); verr == nil {
					pr.version = v
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

	s.mu.Lock()
	refreshed := map[string]bool{}
	// A failed probe records its reason keyed by the candidate IP, so the
	// unreachable pass below can surface WHY (proxy/timeout/refused) on the host
	// whose last-known IP that was -- instead of a blind Reachable=false.
	ipErr := map[string]string{}
	// Hosts newly discovered or whose IP changed this tick: their address is
	// beaconed to Loki (src=presence) after the unlock so the collector can
	// re-seed its volatile view from Loki on a restart (rehydrateHostPresenceFromLoki).
	var presence []presenceTarget
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
		base := fmt.Sprintf("http://%s:%d", r.ip, s.statusPort)
		hv := s.hosts[hid]
		prevBase := ""
		if hv == nil {
			hv = &hostView{HostId: hid}
			s.hosts[hid] = hv
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
		// Keep the prior version on a transient VERSION miss (it is stable; a blank
		// must not wipe a known value, the same shape as the poolId guard below).
		if r.version != "" {
			hv.Version = r.version
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
			// Per-area deep-link URLs (e.g. the stash VM UI) the host advertises ->
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
				s.gating[r.poolID] = *r.gating
			}
		}
		refreshed[hid] = true
		if r.st.CycleId != "" {
			key := hid + "|" + r.st.CycleId
			s.seenAt[key] = now
			if s.seen[key] != r.st.OverallStatus {
				s.seen[key] = r.st.OverallStatus
				pushLoki(client, lokiURL, s.poolFor(hid), r.st, base, now)
			}
			if isTerminal(r.st.OverallStatus) && !s.counted[key] {
				s.counted[key] = true
				if r.st.OverallStatus == "pass" {
					s.pass[hid]++
				} else {
					s.fail[hid]++
					// status.json carries lastFailure (failureClass) in the same doc that
					// flipped overallStatus to "fail" (Complete-Run flushes both), so the
					// class is available at count time; "unknown" when unclassified.
					s.failWindow[hid] = append(s.failWindow[hid], failRec{t: now, class: r.st.failClassOf()}) // ascending: polls are chronological
				}
			}
		}
	}
	var deleted []string
	for hid, hv := range s.hosts {
		if !refreshed[hid] {
			hv.Reachable = false
			// Surface WHY this tick's probe of the host's last-known IP failed, so
			// /api/v1/pool-status is no longer blind about an unreachable host. Left
			// as-is when the IP was not a candidate this tick (no fresh reason).
			if msg, ok := ipErr[hv.CurrentIP]; ok {
				hv.LastError = msg
			}
			if now.UnixMilli()-hv.LastSeenUnixMs > defaultHostTTL.Milliseconds() {
				delete(s.hosts, hid)
				deleted = append(deleted, hid)
			}
		}
	}
	for k, t := range s.seenAt {
		if now.Sub(t) > seenTTL {
			delete(s.seenAt, k)
			delete(s.seen, k)
			delete(s.counted, k)
		}
	}
	// Reap self-announced extensions whose beacon stopped refreshing (the
	// service died without a goodbye); a live service re-announces well inside
	// the TTL, so a reaped entry is genuinely gone, not merely between beacons.
	for k, av := range s.announce {
		if s.announceTTL > 0 && now.UnixMilli()-av.LastSeenUnixMs > s.announceTTL.Milliseconds() {
			delete(s.announce, k)
		}
	}
	// Snapshot the event-tail targets while holding the lock; the fetch+push
	// itself runs unlocked below so a slow host can't stall the handlers.
	type evTarget struct{ hostID, baseURL, cycleID, cycleFolderURL, poolLabel string }
	var targets []evTarget
	for hid, hv := range s.hosts {
		if hv.Reachable && hv.Status != nil && hv.Status.CycleId != "" && hv.Status.CycleFolderUrl != "" {
			// Capture the pool label here under the lock; tailEvents runs unlocked.
			targets = append(targets, evTarget{hid, hv.BaseURL, hv.Status.CycleId, hv.Status.CycleFolderUrl, s.poolFor(hid)})
		}
	}
	// Incident correlation: prune fail windows and open/resolve per-host
	// incidents; the Loki open/resolve events are pushed after the unlock.
	incEvents := s.evaluateIncidents(now)
	// Pool gating: compute each pool's advisory degraded/alert latch (read-side;
	// drives alerting + dashboard de-noise, never a cycle). Runs AFTER incidents so
	// "healthy" can exclude a host currently in an open incident.
	gateEvents := s.evaluatePoolGate(now)
	s.last = now
	s.mu.Unlock()

	// Tail each reachable host's current-cycle NDJSON events into Loki.
	// eventCur is only touched here (single poll goroutine), so no lock needed.
	for _, hid := range deleted {
		delete(s.eventCur, hid)
	}
	for _, ev := range incEvents {
		pushIncident(client, lokiURL, ev.poolLabel, ev)
	}
	for _, ev := range gateEvents {
		pushIncident(client, lokiURL, ev.poolLabel, ev)
	}
	// Beacon each newly-discovered / IP-changed host's address to Loki so a restart
	// can re-seed the volatile view (rehydrateHostPresenceFromLoki). On-change only,
	// so this is a low-volume feed -- a steady pool pushes nothing here per poll.
	for _, p := range presence {
		pushPresence(client, lokiURL, p.pool, p.hostID, p.baseURL, now)
	}
	for _, t := range targets {
		s.tailEvents(client, lokiURL, t.poolLabel, t.hostID, t.baseURL, t.cycleID, t.cycleFolderURL, now)
	}
}

// newInternalHTTPClient builds the HTTP client the aggregator uses for ALL of
// its traffic: host status probes (http://<lan-ip>:8080) and Loki push/query on
// 127.0.0.1. Every target is on the LAN or loopback, so the client MUST NOT use
// a proxy. This process runs ON the caching-proxy host, whose environment may
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

func fetchStatus(client *http.Client, base string) (*hostStatus, error) {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/runtime/status.json", nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status.json HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	var st hostStatus
	if err := json.Unmarshal(body, &st); err != nil {
		return nil, fmt.Errorf("status.json parse: %w", err)
	}
	return &st, nil
}

// fetchVersion reads the host's framework version from VERSION at the repo root,
// served by the status server at /yuruna-repo/VERSION -- the SAME source the
// host's own status pages read for their header (their getHostInfo() fetches
// yuruna-repo/VERSION via JS, so the version is not embedded in the HTML). A tiny
// plain-text file (one CalVer line, e.g. "2026.07.22"), so it is lighter than any
// status HTML page and fetchable server-side without a JS engine. Returns
// ("", err) on any failure; the caller keeps the prior version on a transient
// miss (the version is stable across polls). The value is capped + first-line
// only so a garbage/oversized file can't bloat the metric label.
func fetchVersion(client *http.Client, base string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/yuruna-repo/VERSION", nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("VERSION HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(body))
	if i := strings.IndexAny(v, "\r\n"); i >= 0 { // first line only
		v = strings.TrimSpace(v[:i])
	}
	if len(v) > 64 {
		v = v[:64]
	}
	return v, nil
}

// fetchRegistration reads poolId, the optional gating policy, the active extension
// areas, and the per-area extension deep-links (extensionTargets) from
// /runtime/host.registration.json (the runner derives poolId/gating from pools.yml,
// the single source of truth; the host advertises extensionTargets for the service it
// runs, e.g. the stash VM UI base URL). Returns ("", nil, nil, nil, err) on any
// failure; the caller keeps the prior poolId/gating on a transient miss and falls back
// to the -pool flag when never learned. poolId may be "" for an unpooled host -- that is a successful read,
// not an error. The returned gating is nil when the pool authored none (so the pool
// is observed via gauges but never paged); a partial block is completed with the
// schema defaults.
func fetchRegistration(client *http.Client, base string) (string, string, *gatingPolicy, []string, map[string]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/runtime/host.registration.json", nil)
	if err != nil {
		return "", "", nil, nil, nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", nil, nil, nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", nil, nil, nil, fmt.Errorf("host.registration.json HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", "", nil, nil, nil, err
	}
	// Pointers distinguish "field absent" from "authored as zero" so a partial
	// gating block fills only the missing knobs from the defaults. activeExtensions
	// is the RUNTIME list of extension areas the host is actively running (e.g.
	// stash-service) -- the host sets it (Write-HostRegistrationRecord) only when
	// the corresponding service is up, distinct from the static capabilities list.
	var reg struct {
		PoolID           string            `json:"poolId"`
		PoolGuid         string            `json:"poolGuid"`
		ActiveExtensions []string          `json:"activeExtensions"`
		ExtensionTargets map[string]string `json:"extensionTargets"`
		Gating           *struct {
			FailuresBeforeAlert  *int `json:"failuresBeforeAlert"`
			SuccessesBeforeRearm *int `json:"successesBeforeRearm"`
			Quorum               *struct {
				HealthyThreshold     *float64 `json:"healthyThreshold"`
				DegradedAfterMinutes *int     `json:"degradedAfterMinutes"`
			} `json:"quorum"`
		} `json:"gating"`
	}
	if err := json.Unmarshal(body, &reg); err != nil {
		return "", "", nil, nil, nil, fmt.Errorf("host.registration.json parse: %w", err)
	}
	if reg.Gating == nil {
		return reg.PoolID, reg.PoolGuid, nil, reg.ActiveExtensions, reg.ExtensionTargets, nil
	}
	g := defaultGatingPolicy()
	if reg.Gating.FailuresBeforeAlert != nil && *reg.Gating.FailuresBeforeAlert > 0 {
		g.FailuresBeforeAlert = *reg.Gating.FailuresBeforeAlert
	}
	if reg.Gating.SuccessesBeforeRearm != nil && *reg.Gating.SuccessesBeforeRearm > 0 {
		g.SuccessesBeforeRearm = *reg.Gating.SuccessesBeforeRearm
	}
	if reg.Gating.Quorum != nil {
		if reg.Gating.Quorum.HealthyThreshold != nil && *reg.Gating.Quorum.HealthyThreshold >= 0 && *reg.Gating.Quorum.HealthyThreshold <= 1 {
			g.HealthyThreshold = *reg.Gating.Quorum.HealthyThreshold
		}
		if reg.Gating.Quorum.DegradedAfterMinutes != nil && *reg.Gating.Quorum.DegradedAfterMinutes >= 0 {
			g.DegradedAfter = time.Duration(*reg.Gating.Quorum.DegradedAfterMinutes) * time.Minute
		}
	}
	return reg.PoolID, reg.PoolGuid, &g, reg.ActiveExtensions, reg.ExtensionTargets, nil
}

// postToLoki marshals payload, POSTs it to lokiURL under the shared pushTimeout,
// drains + closes the body, and logs (prefixed by logPrefix) on a build error, a
// transport error, or a non-2xx status. The cycle / single-line beacon / events /
// incident push paths share this tail; only the payload and logPrefix differ.
func postToLoki(client *http.Client, lokiURL string, payload map[string]any, logPrefix string) {
	buf, _ := json.Marshal(payload)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, lokiURL, bytes.NewReader(buf))
	if err != nil {
		log.Printf("%s build: %v", logPrefix, err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("%s: %v", logPrefix, err)
		return
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode/100 != 2 {
		log.Printf("%s HTTP %d", logPrefix, resp.StatusCode)
	}
}

// lokiStreamsResult is the query_range response envelope every Loki reader
// decodes: for each returned stream, its [timestamp, line] value pairs. Declared
// once instead of re-inlining the identical anonymous struct in each reader.
type lokiStreamsResult struct {
	Data struct {
		Result []struct {
			Values [][2]string `json:"values"`
		} `json:"result"`
	} `json:"data"`
}

// queryRangeURL derives the Loki query_range endpoint from the push endpoint
// (the readers query the same base the pushes write to), replacing the identical
// strings.TrimSuffix build inline in each reader.
func queryRangeURL(pushURL string) string {
	return strings.TrimSuffix(pushURL, "push") + "query_range"
}

// pushLoki POSTs one cycle-status transition to Loki. Labels are strictly
// {pool,hostId,cycleId} (low cardinality); the variable fields -- including the
// CURRENT baseURL for the dashboard's drill-down deep-link -- live in the line.
// The value timestamp is the proxy-side INGEST clock, not the host cycleId.
func pushLoki(client *http.Client, lokiURL, pool string, st *hostStatus, baseURL string, ingest time.Time) {
	// hostname is omitted (pool view is hostname-free). cycleFolderUrl IS carried:
	// the /go/cycle redirect resolves a PAST cycle's results folder by time off this
	// line (the in-memory view only knows the current cycle). The folder name is the
	// opaque hostId (Format-CycleFolderBaseName), so the line stays hostname-free;
	// baseUrl is the host IP at transition time (the drill-down fallback for a host
	// that has since aged out of the live view).
	m := map[string]string{
		"hostId": st.HostId, "hostType": st.Host,
		"cycleId": st.CycleId, "overallStatus": st.OverallStatus,
		"startedAt": st.StartedAt, "finishedAt": st.FinishedAt,
		"baseUrl": baseURL, "cycleFolderUrl": st.CycleFolderUrl,
	}
	if st.OverallStatus == "fail" {
		// failureClass is carried on the fail transition so a restart's
		// rehydrateFromLoki can restore each fail's class into the fail window.
		m["failureClass"] = st.failClassOf()
	}
	line, _ := json.Marshal(m)
	payload := map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": pool, "hostId": st.HostId, "cycleId": st.CycleId, "src": "cycle"},
		"values": [][]string{{fmt.Sprintf("%d", ingest.UnixNano()), string(line)}},
	}}}
	postToLoki(client, lokiURL, payload, "loki push")
}

// pushLokiStream POSTs one line to Loki under the given stream labels --
// the shared body of the single-line beacon pushes (presence, announce).
// Best-effort: any error is logged under `what` and dropped.
func pushLokiStream(client *http.Client, lokiURL, what string, stream map[string]string, line []byte, now time.Time) {
	if client == nil || lokiURL == "" {
		return
	}
	payload := map[string]any{"streams": []map[string]any{{
		"stream": stream,
		"values": [][]string{{fmt.Sprintf("%d", now.UnixNano()), string(line)}},
	}}}
	postToLoki(client, lokiURL, payload, what+" push")
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
func pushPresence(client *http.Client, lokiURL, pool, hostID, baseURL string, now time.Time) {
	if lokiURL == "" || hostID == "" || baseURL == "" {
		return
	}
	line, _ := json.Marshal(map[string]string{"hostId": hostID, "baseUrl": baseURL})
	pushLokiStream(client, lokiURL, "presence",
		map[string]string{"pool": pool, "hostId": hostID, "src": "presence"}, line, now)
}

// pushAnnounce records one accepted extension-presence announce in Loki under
// {pool,hostId,src=announce} -- EVERY accepted hello (not on-change), so the
// freshest line's age is the entry's age and a restart can restore exactly the
// entries still inside announceTTL (rehydrateAnnouncesFromLoki). Volume is one
// tiny line per service per beacon period. Streamed under s.pool (the
// aggregator's -pool default) so the rehydrate, which queries that same pool
// label, finds it -- the same label coupling pushPresence documents. Goodbyes
// (active=false) are pushed too so the latest line decides restart state.
func pushAnnounce(client *http.Client, lokiURL, pool, hostID, area, target string, active bool, now time.Time) {
	if lokiURL == "" || hostID == "" {
		return
	}
	line, _ := json.Marshal(map[string]any{"hostId": hostID, "area": area, "target": target, "active": active})
	pushLokiStream(client, lokiURL, "announce",
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

// seedHostStubLocked pre-populates s.hosts with an UNREACHABLE stub for a hostId
// whose last-known IP was recovered from Loki on startup, so the first pollOnce
// probes that IP (its candidate set = squid-log IPs UNION every in-view host's
// CurrentIP). The stub carries NO status/extensions, so handleMetrics emits no
// extension row / pass-fail for it until a real probe confirms it -- the seed only
// makes the probe HAPPEN. This restores discovery for a host that is up + reachable
// but generating no fresh proxy traffic (a paused runner, or a stash-only host)
// after a restart wiped the volatile view. Caller holds s.mu. A stub NEVER clobbers
// an existing (possibly live) entry; LastSeenUnixMs is seeded to `now` so a transient
// first-probe miss does not evict it before a full hostTTL of retries.
func (s *poolState) seedHostStubLocked(hostID, baseURL string, now time.Time) bool {
	if hostID == "" {
		return false
	}
	if _, ok := s.hosts[hostID]; ok {
		return false
	}
	ip := hostIPFromBaseURL(baseURL)
	if ip == "" {
		return false
	}
	s.hosts[hostID] = &hostView{
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
// empty counts (prior behavior) and rebuilds as cycles complete.
func (s *poolState) rehydrateFromLoki(lokiPushURL, pool string, window time.Duration, now time.Time) {
	queryURL := queryRangeURL(lokiPushURL)
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q} | json | overallStatus=~"pass|fail"`, pool))
	params.Set("start", strconv.FormatInt(now.Add(-window).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "5000")
	params.Set("direction", "backward") // most-recent first: if capped, keep the freshest transitions

	client := newInternalHTTPClient(pushTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		log.Printf("rehydrate: build request: %v", err)
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("rehydrate: Loki query: %v (starting with empty counts)", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		log.Printf("rehydrate: Loki HTTP %d: %s (starting with empty counts)", resp.StatusCode, strings.TrimSpace(string(body)))
		return
	}
	var lr lokiStreamsResult
	if err := json.NewDecoder(io.LimitReader(resp.Body, 32<<20)).Decode(&lr); err != nil {
		log.Printf("rehydrate: parse Loki response: %v", err)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	restored, capped := 0, 0
	// Last-known baseUrl (host IP) per hostId, newest wins: every transition line
	// already carries baseUrl, so the same query that restores counts also recovers
	// where each host was, letting the first poll re-probe an idle host that is not
	// in the squid log. Seeded into s.hosts after the loop.
	latestBase := map[string]string{}
	latestBaseAt := map[string]time.Time{}
	for _, st := range lr.Data.Result {
		capped += len(st.Values)
		for _, v := range st.Values {
			var e struct {
				HostId        string `json:"hostId"`
				CycleId       string `json:"cycleId"`
				OverallStatus string `json:"overallStatus"`
				FailureClass  string `json:"failureClass"`
				BaseUrl       string `json:"baseUrl"`
			}
			if json.Unmarshal([]byte(v[1]), &e) != nil || e.HostId == "" || e.CycleId == "" {
				continue
			}
			key := e.HostId + "|" + e.CycleId
			s.seen[key] = e.OverallStatus
			evTime := now
			if ns, perr := strconv.ParseInt(v[0], 10, 64); perr == nil {
				evTime = time.Unix(0, ns)
			}
			s.seenAt[key] = evTime
			if e.BaseUrl != "" && (latestBaseAt[e.HostId].IsZero() || evTime.After(latestBaseAt[e.HostId])) {
				latestBase[e.HostId] = e.BaseUrl
				latestBaseAt[e.HostId] = evTime
			}
			if isTerminal(e.OverallStatus) && !s.counted[key] {
				s.counted[key] = true
				if e.OverallStatus == "pass" {
					s.pass[e.HostId]++
				} else {
					s.fail[e.HostId]++
					// Seed the incident fail-window with recent fails so an
					// incident in progress at restart is reconstructed (with its class;
					// "unknown" for legacy lines that predate the failureClass field).
					if evTime.After(now.Add(-s.incidentWin)) {
						cls := e.FailureClass
						if cls == "" {
							cls = "unknown"
						}
						s.failWindow[e.HostId] = append(s.failWindow[e.HostId], failRec{t: evTime, class: cls})
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
		if s.seedHostStubLocked(hid, base, now) {
			seeded++
		}
	}
	// The query returns newest-first; sort each seeded window ascending (the live
	// append path is already chronological) for correct pruning + peak math.
	// Open incidents are NOT reconstructed here -- they are restored from the
	// authoritative incident feed (rehydrateIncidentsFromLoki) so their original
	// id + startedAt survive, including incidents currently below the open
	// threshold whose hysteresis state the fail window alone can't recover.
	for _, fw := range s.failWindow {
		sort.Slice(fw, func(i, j int) bool { return fw[i].t.Before(fw[j].t) })
	}
	if restored > 0 {
		log.Printf("rehydrate: restored %d terminal cycle counts from Loki (window=%s)", restored, window)
	}
	if seeded > 0 {
		log.Printf("rehydrate: re-seeded %d host(s) from transition baseUrls (window=%s)", seeded, window)
	}
	if capped >= 5000 {
		log.Printf("rehydrate: WARNING hit the 5000-line query cap; counts older than the most recent 5000 transitions may be undercounted")
	}
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
	params.Set("query", fmt.Sprintf(`{pool=%q, src="incident"} | json`, pool))
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
		log.Printf("rehydrate incidents: Loki query: %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var lr lokiStreamsResult
	if err := json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&lr); err != nil {
		log.Printf("rehydrate incidents: parse: %v", err)
		return
	}

	streams := make([][][2]string, 0, len(lr.Data.Result))
	for _, st := range lr.Data.Result {
		streams = append(streams, st.Values)
	}
	if n := s.applyIncidentLines(streams, now); n > 0 {
		log.Printf("rehydrate: restored %d open incident(s) from Loki", n)
	}
}

// applyIncidentLines restores open incidents (per-host and pool-wide) from the
// incident-feed streams -- each element is one Loki stream's [ts,line] values,
// newest-first. The most recent line per host, and the most recent pool-scoped
// line, decides current state (a trailing resolve means "not in incident").
// Split out from the HTTP fetch in rehydrateIncidentsFromLoki so it is
// unit-testable without a live Loki. Takes s.mu.
func (s *poolState) applyIncidentLines(streams [][][2]string, now time.Time) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	decided := map[string]bool{} // hostId -> latest lifecycle line already applied
	poolDecided := false         // the latest pool-scoped line already applied
	restored := 0
	for _, values := range streams {
		for _, v := range values { // newest-first within a stream
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
			if json.Unmarshal([]byte(v[1]), &e) != nil {
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
						id = poolIncidentID(started)
					}
					cls := e.Class
					if cls == "" {
						cls = "unknown" // legacy open line predating same-class cross-host
					}
					s.poolIncident = &poolIncidentState{id: id, startedAt: started, peakHosts: e.AffectedHostCount, class: cls}
					restored++
				}
				continue
			}
			// Per-host lifecycle lines.
			if e.HostId == "" || decided[e.HostId] {
				continue // only the most recent line per host decides current state
			}
			decided[e.HostId] = true
			if e.Event != "incident_open" {
				continue // latest line is a resolve (or unknown) -> host not in incident
			}
			started := parseStarted()
			id := e.IncidentId
			if id == "" {
				id = incidentID(e.HostId, started)
			}
			peak := e.FailCount
			hist := e.ClassHistogram
			dom := e.DominantClass
			if n := len(s.failWindow[e.HostId]); n > peak {
				// The live window is larger than the restored snapshot -> recompute
				// BOTH the histogram AND its dominant from the live window so they
				// agree (mirrors evaluateIncidents). Recomputing only the histogram
				// would leave dominantClass stale vs peakClassHist after a post-open
				// class shift, misclassifying the metric/Loki/dashboard.
				peak = n
				hist = classHistogram(s.failWindow[e.HostId])
				dom = dominantClass(hist)
			}
			if len(hist) == 0 {
				hist = map[string]int{}
			}
			if dom == "" {
				dom = dominantClass(hist) // legacy open line predating the class histogram
			}
			if dom == "" {
				dom = "unknown"
			}
			s.incident[e.HostId] = &incidentState{id: id, startedAt: started, peak: peak, peakClassHist: hist, dominantClass: dom}
			restored++
		}
	}
	return restored
}

// rehydrateHostPresenceFromLoki re-seeds the collector's VOLATILE in-memory host
// view from the {src=presence} beacon feed on startup, so a host discovered before
// a restart is re-probed at its last-known IP even when it is generating no fresh
// proxy traffic (a paused runner, or a stash-only host that runs no test cycles and
// so emits no {src=cycle} transition for rehydrateFromLoki to seed from). Without
// this a restart drops such a host from the dashboard until it next pulls through
// the proxy -- the discovery-liveness gap. Best-effort: any Loki error leaves the
// view to rebuild from the squid log as before.
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
		log.Printf("rehydrate presence: Loki query: %v", err)
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
		log.Printf("rehydrate: re-seeded %d host(s) from the presence feed", n)
	}
}

// applyPresenceLines seeds unreachable host stubs from the presence-beacon streams
// -- each element is one Loki stream's [ts,line] values, newest-first. A host has a
// single presence stream, so the FIRST line seen per hostId is its newest address.
// Split from the HTTP fetch (like applyIncidentLines) so it is unit-testable without
// a live Loki. Takes s.mu.
func (s *poolState) applyPresenceLines(streams [][][2]string, now time.Time) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	seeded := 0
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
			if s.seedHostStubLocked(e.HostId, e.BaseUrl, now) {
				seeded++
			}
		}
	}
	return seeded
}

// rehydrateAnnouncesFromLoki restores self-announced extensions from the
// {src=announce} feed on startup, so a collector restart keeps the Extension
// hosts rows of services whose beacons are alive -- WITHOUT waiting up to one
// beacon period for the next hello. The query window is announceTTL, not the
// full rehydrate window: any line older than the TTL is stale by definition.
// Best-effort: on any Loki error the entries rebuild from live beacons.
func (s *poolState) rehydrateAnnouncesFromLoki(lokiPushURL, pool string, now time.Time) {
	if s.announceTTL <= 0 {
		return
	}
	queryURL := queryRangeURL(lokiPushURL)
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q, src="announce"} | json`, pool))
	params.Set("start", strconv.FormatInt(now.Add(-s.announceTTL).UnixNano(), 10))
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
		log.Printf("rehydrate announces: Loki query: %v", err)
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
		log.Printf("rehydrate: restored %d self-announced extension(s) from Loki", n)
	}
}

// applyAnnounceLines restores announce entries from {src=announce} streams --
// each element one Loki stream's [ts,line] values, newest-first. The newest
// line per (hostId, area) decides: active restores the entry with the LINE's
// timestamp as its freshness (so the TTL reap stays truthful), a goodbye
// leaves it absent. Values are re-validated with the same gates as a live
// announce -- Loki retention is not a trust boundary. Split from the HTTP
// fetch so it is unit-testable without a live Loki. Takes s.mu.
func (s *poolState) applyAnnounceLines(streams [][][2]string, now time.Time) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	restored := 0
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
			if !e.Active || s.announce[key] != nil || len(s.announce) >= maxAnnounce {
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
			s.announce[key] = &announceView{
				HostId: e.HostId, Area: e.Area, Target: target,
				LastSeenUnixMs: ts.UnixMilli(),
				// The next live announce (target host == its source) re-binds the
				// address; until then the target's own host is the best owner guess.
				sourceIP: hostIPFromBaseURL(target),
			}
			restored++
		}
	}
	return restored
}

// tailEvents pulls a host's current-cycle NDJSON event file
// (<baseUrl>/<cycleFolderUrl>cycle.events.ndjson) and ships any lines beyond the
// per-host byte cursor to Loki under {pool,hostId,src=event}. This is the
// incident drill-down feed: step_failure/step_end and the typed sub-
// events become queryable cross-host. The Loki entry timestamp is the event's
// OWN `timestamp`, so a collector restart that re-pushes the in-flight cycle is
// idempotent (Loki drops exact (ts,line) duplicates). The cursor avoids
// re-pushing within a running instance and resets when the cycleId changes.
// Best-effort + bounded: a missing/oversized file or a Loki error is logged
// and skipped; it never blocks the poll.
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
	resp, err := client.Do(req)
	if err != nil {
		return // host went away mid-poll; next tick retries
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return // events file not present yet (fresh cycle) -> nothing to tail
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxEventFetch))
	if err != nil {
		return
	}

	cur := s.eventCur[hostID]
	if cur == nil || cur.cycleId != cycleID {
		cur = &eventCursor{cycleId: cycleID}
		s.eventCur[hostID] = cur
	}
	if int64(len(body)) <= cur.offset {
		return // nothing new (or the file rotated/shrank under the same cycleId)
	}
	chunk := body[int(cur.offset):]
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
		return
	}
	pushEvents(client, lokiURL, poolLabel, hostID, lines, now)
	cur.offset += int64(consumed)
}

// pushEvents ships NDJSON event lines for one host to Loki under
// {pool,hostId,src=event}. Each Loki entry timestamp is the event's own
// `timestamp` field, so re-pushing an identical line is an exact-duplicate no-op
// (idempotent across collector restarts). Within-second events share a Loki
// timestamp (distinct lines, both retained) -- second resolution is fine for
// drill-down, and the precise time stays in the line. Falls back to the ingest
// clock for any line whose timestamp won't parse.
func pushEvents(client *http.Client, lokiURL, pool, hostID string, lines []string, ingest time.Time) {
	if len(lines) == 0 {
		return
	}
	values := make([][]string, 0, len(lines))
	for _, ln := range lines {
		values = append(values, []string{strconv.FormatInt(eventNano(ln, ingest), 10), ln})
	}
	payload := map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": pool, "hostId": hostID, "src": "event"},
		"values": values,
	}}}
	postToLoki(client, lokiURL, payload, "event push")
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

// incidentEvent is a pending incident lifecycle change to push to Loki.
type incidentEvent struct {
	open          bool
	pool          bool     // pool-wide (cross-host) incident vs per-host
	hostId        string   // per-host incidents
	hosts         []string // pool-wide: affected host IDs at open (hostname-free)
	id            string
	count         int            // per-host: in-window fails at open; pool: affected host count at open
	peak          int            // per-host: peak in-window fails; pool: peak affected hosts
	classHist     map[string]int // per-host: failure-class breakdown (live at open, peak at resolve)
	dominantClass string         // per-host: argmax class of classHist
	class         string         // pool-wide: the pinned triggering (same) failure class
	poolLabel     string         // pool label for the Loki stream (per-host: poolFor(hostId); pool-wide: the -pool flag)
	startedAt     time.Time
	now           time.Time
	// Pool gating ALERT lifecycle (distinct from the heuristic incidents above):
	// alert=true marks a quorum-degraded alert event; rearm distinguishes recovered
	// from fired. healthyFraction/membersHealthy/membersTotal carry the gate snapshot.
	alert           bool
	rearm           bool
	healthyFraction float64
	membersHealthy  int
	membersTotal    int
}

// classHistogram counts the failure classes in a fail window (empty -> empty map).
func classHistogram(fw []failRec) map[string]int {
	h := map[string]int{}
	for _, r := range fw {
		c := r.class
		if c == "" {
			c = "unknown"
		}
		h[c]++
	}
	return h
}

// dominantClass is the argmax class of a histogram, ties broken lexically (so the
// headline class is deterministic); "" for an empty histogram.
func dominantClass(h map[string]int) string {
	best, bestN := "", -1
	for c, n := range h {
		if n > bestN || (n == bestN && c < best) {
			best, bestN = c, n
		}
	}
	return best
}

func incidentID(hostID string, t time.Time) string {
	short := hostID
	if len(short) > 8 {
		short = short[:8]
	}
	return fmt.Sprintf("inc-%s-%d", short, t.Unix())
}

func poolIncidentID(t time.Time) string { return fmt.Sprintf("inc-pool-%d", t.Unix()) }

// evaluateIncidents prunes each host's in-window fail list, opens an incident
// when a host reaches incidentN fails within incidentWin, and resolves it once
// the window empties of fails. Hysteresis (open at >=N, resolve at 0) keeps a
// host that keeps failing in ONE incident instead of flapping. Returns the
// open/resolve events for the caller to push to Loki AFTER releasing s.mu.
// MUST be called with s.mu held.
func (s *poolState) evaluateIncidents(now time.Time) []incidentEvent {
	cutoff := now.Add(-s.incidentWin)
	ids := map[string]bool{}
	for h := range s.failWindow {
		ids[h] = true
	}
	for h := range s.incident {
		ids[h] = true
	}
	var events []incidentEvent
	for hid := range ids {
		kept := s.failWindow[hid][:0]
		for _, r := range s.failWindow[hid] {
			if r.t.After(cutoff) {
				kept = append(kept, r)
			}
		}
		if len(kept) == 0 {
			delete(s.failWindow, hid)
		} else {
			s.failWindow[hid] = kept
		}
		n := len(kept)
		inc := s.incident[hid]
		switch {
		case inc == nil && n >= s.incidentN:
			hist := classHistogram(kept)
			dom := dominantClass(hist)
			if dom == "" {
				dom = "unknown"
			}
			inc = &incidentState{id: incidentID(hid, kept[0].t), startedAt: kept[0].t, peak: n, peakClassHist: hist, dominantClass: dom}
			s.incident[hid] = inc
			events = append(events, incidentEvent{open: true, hostId: hid, id: inc.id, count: n, startedAt: kept[0].t, now: now, classHist: hist, dominantClass: dom, poolLabel: s.poolFor(hid)})
		case inc != nil:
			// Snapshot the class histogram whenever peak is (re)assigned so the
			// resolve line -- emitted when the window has aged to ~0 -- reports the
			// breakdown the incident PEAKED at, like peakFails.
			if n > inc.peak {
				inc.peak = n
				inc.peakClassHist = classHistogram(kept)
				inc.dominantClass = dominantClass(inc.peakClassHist)
				if inc.dominantClass == "" {
					inc.dominantClass = "unknown"
				}
			}
			if n == 0 {
				delete(s.incident, hid)
				events = append(events, incidentEvent{hostId: hid, id: inc.id, startedAt: inc.startedAt, peak: inc.peak, now: now, classHist: inc.peakClassHist, dominantClass: inc.dominantClass, poolLabel: s.poolFor(hid)})
			}
		}
	}

	// Cross-host SAME-CLASS correlation: a POOL-WIDE incident when >= crossN distinct
	// hosts each failed within the (shorter) crossWin WITH THE SAME failure class -- a
	// systemic shared cause (proxy/network/a bad commit hitting one class everywhere),
	// not unrelated single-host churn that merely coincides in time. For each class,
	// count distinct hosts with an in-crossWin fail of that class; the argmax class
	// (lexical tiebreak) is the open candidate. The triggering class is PINNED at open;
	// resolve evaluates ONLY that class's distinct-host count against crossFloor
	// (max(1,crossN-1)) -- never re-pinning -- so the incident can't class-hop and
	// inflate its duration (guards the sticky-resolve invariant). A genuinely
	// different class reaching crossN resolves the old incident and reopens a new one
	// (new id) in the same pass.
	crossCut := now.Add(-s.crossWin)
	hostsByClass := map[string]map[string]bool{} // class -> set of hostIds with an in-window fail of that class
	for hid, fw := range s.failWindow {
		for _, r := range fw {
			if r.t.After(crossCut) {
				c := r.class
				if c == "" {
					c = "unknown"
				}
				if hostsByClass[c] == nil {
					hostsByClass[c] = map[string]bool{}
				}
				hostsByClass[c][hid] = true
			}
		}
	}
	// affectedFor returns the sorted hostId list for a class (hostname-free: the pool
	// feed drives the unauthenticated dashboard).
	affectedFor := func(c string) []string {
		a := make([]string, 0, len(hostsByClass[c]))
		for hid := range hostsByClass[c] {
			a = append(a, hid)
		}
		sort.Strings(a)
		return a
	}
	// The class with the most distinct hosts (lexical tiebreak) is the open candidate.
	topClass, topN := "", 0
	for c, hs := range hostsByClass {
		nc := len(hs)
		if nc > topN || (nc == topN && (topClass == "" || c < topClass)) {
			topClass, topN = c, nc
		}
	}
	crossFloor := s.crossN - 1
	if crossFloor < 1 {
		crossFloor = 1
	}
	// Resolve first (against the pinned class), so a cleared incident can reopen for a
	// different systemic class in this same pass.
	if s.poolIncident != nil {
		pinnedN := len(hostsByClass[s.poolIncident.class])
		if pinnedN > s.poolIncident.peakHosts {
			s.poolIncident.peakHosts = pinnedN
		}
		if pinnedN < crossFloor {
			events = append(events, incidentEvent{pool: true, id: s.poolIncident.id, startedAt: s.poolIncident.startedAt, peak: s.poolIncident.peakHosts, now: now, class: s.poolIncident.class, poolLabel: s.pool})
			s.poolIncident = nil
		}
	}
	if s.poolIncident == nil && topN >= s.crossN {
		s.poolIncident = &poolIncidentState{id: poolIncidentID(now), startedAt: now, peakHosts: topN, class: topClass}
		events = append(events, incidentEvent{open: true, pool: true, id: s.poolIncident.id, count: topN, startedAt: now, now: now, hosts: affectedFor(topClass), class: topClass, poolLabel: s.pool})
	}
	return events
}

func poolAlertID(t time.Time) string { return fmt.Sprintf("alert-pool-%d", t.Unix()) }

// evaluatePoolGate computes each pool's advisory health gate from the gating quorum
// and runs the degraded/alert hysteresis. READ-SIDE ONLY: no runner consumes the
// result (consensus-gated control is deferred) -- it drives alerting (the host-side
// notifier reads yuruna_pool_alert_active) + dashboard de-noise, never a cycle/pause/
// break. MUST be called with s.mu held (reads s.hosts/s.incident/s.gating, mutates
// s.poolGate). Returns the alert lifecycle events to ship to Loki after the unlock.
//
// healthy(host)   := reachable AND status in {running,pass,idle} AND not in an open
//
//	incident; healthyFraction := healthy/known (known = pool members
//	in the view). degraded latches when the fraction stays below the
//	threshold for >= DegradedAfter (wall-clock), clears immediately on
//	recovery. The ALERT fires after FailuresBeforeAlert consecutive
//	degraded polls + re-arms after SuccessesBeforeRearm non-degraded
//	polls (poll-count hysteresis: deterministic + unit-testable).
//
// Gauges (_healthy_fraction/_degraded/_members_*) are computed for EVERY pool with a
// member (harmless observability); _alert_active + the fired/rearmed events fire ONLY
// for pools that authored a gating block (s.gating), so an un-configured pool is
// observed but never paged.
func (s *poolState) evaluatePoolGate(now time.Time) []incidentEvent {
	membersByPool := map[string][]*hostView{}
	for hid, hv := range s.hosts {
		p := s.poolFor(hid)
		membersByPool[p] = append(membersByPool[p], hv)
	}
	var events []incidentEvent
	// Drop gate state for pools that no longer have a member (their gauge series
	// vanish; the notifier preserves last-state on an absent gauge + a rearm cooldown,
	// so a pool that simply emptied does not page). If such a pool was still FIRING,
	// emit a rearm first so the kind=alert Loki lifecycle feed closes cleanly -- this is
	// otherwise the one path that could leave a dangling pool_alert_fired.
	for p, gate := range s.poolGate {
		if _, ok := membersByPool[p]; ok {
			continue
		}
		if gate.authored && gate.alertFired {
			events = append(events, incidentEvent{
				alert: true, rearm: true, pool: true, id: gate.alertID, poolLabel: p,
				startedAt: gate.alertStartedAt, now: now,
				healthyFraction: 0, membersHealthy: 0, membersTotal: 0,
			})
		}
		delete(s.poolGate, p)
	}
	for p, members := range membersByPool {
		total := len(members)
		healthy := 0
		for _, hv := range members {
			if hv.Reachable && s.incident[hv.HostId] == nil {
				switch hv.statusCode() {
				case 1, 2, 4: // running, pass, idle
					healthy++
				}
			}
		}
		policy, authored := s.gating[p]
		if !authored {
			policy = defaultGatingPolicy()
		}
		gate := s.poolGate[p]
		if gate == nil {
			gate = &poolGateState{}
			s.poolGate[p] = gate
		}
		gate.authored = authored
		frac := 1.0
		if total > 0 {
			frac = float64(healthy) / float64(total)
		}
		gate.lastFraction, gate.lastHealthy, gate.lastTotal, gate.lastThreshold = frac, healthy, total, policy.HealthyThreshold

		below := frac < policy.HealthyThreshold
		if below {
			if gate.belowSince.IsZero() {
				gate.belowSince = now
			}
		} else {
			gate.belowSince = time.Time{}
		}
		gate.degraded = below && !gate.belowSince.IsZero() && now.Sub(gate.belowSince) >= policy.DegradedAfter

		// Alert hysteresis runs only for authored pools; an un-configured pool keeps
		// its counters/latch reset (observed via gauges, never paged).
		if !authored {
			gate.consecDegraded, gate.consecHealthy, gate.alertFired = 0, 0, false
			continue
		}
		if gate.degraded {
			gate.consecDegraded++
			gate.consecHealthy = 0
		} else {
			gate.consecHealthy++
			gate.consecDegraded = 0
		}
		if !gate.alertFired && gate.consecDegraded >= policy.FailuresBeforeAlert {
			gate.alertFired = true
			gate.alertID = poolAlertID(now)
			gate.alertStartedAt = now
			events = append(events, incidentEvent{
				alert: true, pool: true, id: gate.alertID, poolLabel: p, startedAt: now, now: now,
				healthyFraction: frac, membersHealthy: healthy, membersTotal: total,
			})
		} else if gate.alertFired && gate.consecHealthy >= policy.SuccessesBeforeRearm {
			events = append(events, incidentEvent{
				alert: true, rearm: true, pool: true, id: gate.alertID, poolLabel: p, startedAt: gate.alertStartedAt, now: now,
				healthyFraction: frac, membersHealthy: healthy, membersTotal: total,
			})
			gate.alertFired, gate.alertID, gate.alertStartedAt = false, "", time.Time{}
		}
	}
	return events
}

// pushIncident ships one incident lifecycle line to Loki under
// {pool,hostId,src=incident} -- the feed behind the dashboard incident strip.
func pushIncident(client *http.Client, lokiURL, pool string, ev incidentEvent) {
	rec := map[string]any{
		"incidentId": ev.id,
		"startedAt":  ev.startedAt.UTC().Format(time.RFC3339),
		"timestamp":  ev.now.UTC().Format(time.RFC3339),
	}
	stream := map[string]string{"pool": pool, "src": "incident"}
	switch {
	case ev.alert:
		// Pool-level advisory ALERT (quorum-degraded). kind=alert distinguishes it
		// from pool_incident_* on the same pool-scoped stream; the host-side notifier
		// reads the yuruna_pool_alert_active gauge (not this line) to deliver, so this
		// is the audit trail + the rehydrate-free record of the latch transition.
		stream["scope"] = "pool"
		stream["kind"] = "alert"
		rec["scope"] = "pool"
		rec["healthyFraction"] = ev.healthyFraction
		rec["membersHealthy"] = ev.membersHealthy
		rec["membersTotal"] = ev.membersTotal
		if ev.rearm {
			rec["event"] = "pool_alert_rearmed"
			rec["durationSec"] = int64(ev.now.Sub(ev.startedAt) / time.Second)
		} else {
			rec["event"] = "pool_alert_fired"
		}
	case ev.pool:
		stream["scope"] = "pool"
		rec["scope"] = "pool"
		if ev.class != "" {
			rec["class"] = ev.class // the same-class that triggered the pool-wide incident
		}
		if ev.open {
			rec["event"] = "pool_incident_open"
			rec["affectedHostCount"] = ev.count
			rec["affectedHosts"] = ev.hosts
		} else {
			rec["event"] = "pool_incident_resolved"
			rec["peakHosts"] = ev.peak
			rec["durationSec"] = int64(ev.now.Sub(ev.startedAt) / time.Second)
		}
	default:
		stream["hostId"] = ev.hostId
		rec["hostId"] = ev.hostId
		// The failure-class breakdown on the incident OBJECT: dominantClass is the
		// headline; classHistogram is the full per-class count (live at open, peak at
		// resolve). Empty/unknown when the cycles carried no classified lastFailure.
		if ev.dominantClass != "" {
			rec["dominantClass"] = ev.dominantClass
		}
		if len(ev.classHist) > 0 {
			rec["classHistogram"] = ev.classHist
		}
		if ev.open {
			rec["event"] = "incident_open"
			rec["failCount"] = ev.count
		} else {
			rec["event"] = "incident_resolved"
			rec["peakFails"] = ev.peak
			rec["durationSec"] = int64(ev.now.Sub(ev.startedAt) / time.Second)
		}
	}
	line, _ := json.Marshal(rec)
	payload := map[string]any{"streams": []map[string]any{{
		"stream": stream,
		"values": [][]string{{strconv.FormatInt(ev.now.UnixNano(), 10), string(line)}},
	}}}
	postToLoki(client, lokiURL, payload, "incident push")
}

func (s *poolState) handleHealth(w http.ResponseWriter, _ *http.Request) {
	_, _ = io.WriteString(w, "ok\n")
}

func (s *poolState) handlePoolStatus(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	out := struct {
		Pool        string            `json:"pool"`
		LastPollUTC string            `json:"lastPollUtc"`
		Hosts       []poolStatusEntry `json:"hosts"`
		// AnnouncedExtensions lists every live self-announce (POST /announce),
		// including ones whose hostId is not in the host view at all -- the
		// observable a service-only signal leaves when its host is dark.
		AnnouncedExtensions []*announceView `json:"announcedExtensions,omitempty"`
	}{Pool: s.pool}
	if !s.last.IsZero() {
		out.LastPollUTC = s.last.UTC().Format(time.RFC3339)
	}
	ids := make([]string, 0, len(s.hosts))
	for id := range s.hosts {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		hv := s.hosts[id]
		// stashBaseUrl: the stash UI's hostId->URL lookup key
		// (stash-service-ui.md §3.4). Registration-advertised target first, the
		// service's own announce as the fallback that survives a down status
		// server on the owning host.
		stash := hv.ExtensionTargets[stashArea]
		if stash == "" {
			if av := s.announce[announceKey(id, stashArea)]; av != nil {
				stash = av.Target
			}
		}
		out.Hosts = append(out.Hosts, poolStatusEntry{hostView: hv, StashBaseURL: stash})
	}
	annKeys := make([]string, 0, len(s.announce))
	for k := range s.announce {
		annKeys = append(annKeys, k)
	}
	sort.Strings(annKeys)
	for _, k := range annKeys {
		out.AnnouncedExtensions = append(out.AnnouncedExtensions, s.announce[k])
	}
	// Marshal while still holding s.mu: out.Hosts holds *hostView/*hostStatus pointers that the
	// poll goroutine mutates, so encoding them after Unlock is a data race (torn JSON / crash
	// under -race). Serialize to bytes under the lock, then release and write.
	body, err := json.Marshal(out)
	s.mu.Unlock()
	if err != nil {
		http.Error(w, "failed to encode pool status", http.StatusInternalServerError)
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
				CycleId        string `json:"cycleId"`
			}
			if json.Unmarshal([]byte(v[1]), &e) != nil {
				continue
			}
			c := cycleCand{folderURL: e.CycleFolderUrl, baseURL: e.BaseUrl, cycleID: e.CycleId}
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
	params.Set("start", strconv.FormatInt(now.Add(-defaultHostTTL).UnixNano(), 10))
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
	s.mu.Lock()
	if hv := s.hosts[hostID]; hv != nil {
		base = hv.BaseURL
	}
	if pool == "" {
		pool = s.poolFor(hostID)
	}
	s.mu.Unlock()
	if base == "" {
		base = s.lastKnownBaseURL(pool, hostID)
	}
	return base, pool
}

// controlProofFor is the deterministic core of the host-control proof: the exact wire
// string "<expiry>.<base64 HMAC>" the host status server accepts on its mutating
// /control/* routes, where HMAC = HMAC-SHA256(pool-auth-token, "yuruna-control|proof|
// <expiry>"). It is byte-for-byte identical to Test.HostConfigSync\Get-YurunaControlProof
// (PowerShell) -- same HMAC-SHA256, same std base64, same data string -- so a proof minted
// here on the Caching Proxy validates on any pool host (the pool-auth-token is pool-wide).
// Verified by TestMintControlProofGolden against the shared golden vector.
func controlProofFor(token string, expiry int64) string {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|" + strconv.FormatInt(expiry, 10)))
	return strconv.FormatInt(expiry, 10) + "." + base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// mintControlProof mints a control proof valid for ttl from now, or "" when no
// pool-auth-token is configured (the host then only accepts loopback control). The
// operator reaches the host through Grafana -> /go/host, so this rides the proof to the
// browser in the redirect fragment; the host revalidates it (expiry window + HMAC).
func mintControlProof(token string, ttl time.Duration) string {
	if token == "" {
		return ""
	}
	return controlProofFor(token, time.Now().Add(ttl).Unix())
}

// handleGoHost bridges a dashboard click -> the host's OWN status-page root, resolving
// the host's CURRENT IP server-side (the same uuid->IP resolution as /go/cycle, so the
// link survives a host IP change). Distinct from /go/cycle, which targets a specific
// cycle-results folder; this always lands on the status root. The state-timeline series
// is intentionally IP-free (keyed on hostId so a host's row doesn't split on an IP
// change), so the link can't carry the IP and must resolve it here. Host unknown -> 404.
func (s *poolState) handleGoHost(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := strings.TrimSpace(q.Get("host"))
	if hostID == "" {
		http.Error(w, "missing host", http.StatusBadRequest)
		return
	}
	base, _ := s.resolveHostBase(hostID, strings.TrimSpace(q.Get("pool")))
	if base == "" {
		http.Error(w, "host not known to the pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	// Carry a short-lived control proof to the host UI in the URL FRAGMENT (never sent to
	// a server or written to an access log; the status page JS reads location.hash). This
	// lets the operator drive the host's mutating /control/* routes after arriving through
	// the (to-be-authenticated) Grafana dashboard, without the host trusting the whole LAN.
	// No token configured -> no fragment -> the host accepts only loopback control.
	dest := strings.TrimRight(base, "/")
	if proof := mintControlProof(s.authToken, 5*time.Minute); proof != "" {
		dest += "#yctl=" + proof
	}
	http.Redirect(w, r, dest, http.StatusFound)
}

// handleGoStash bridges a dashboard Extension-cell click -> an extension's service
// UI (today the stash VM), 302ing to the URL the owning host advertised in its
// registration (extensionTargets[area], default area "stash-service"). Unlike
// /go/host -- which re-resolves a host's CURRENT :8080 IP live -- the aggregator does
// not probe the stash VM, so this redirect is only as fresh as the host's advertised
// stashBaseUrl; the host re-resolves that each cycle (and on Start-StashServer) via
// Get-VMIp, so it self-heals after a DHCP change. Host/target unknown -> 404, matching
// the best-effort resolver contract in docs/design/stash-service-ui.md (3.4).
func (s *poolState) handleGoStash(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := strings.TrimSpace(q.Get("host"))
	if hostID == "" {
		http.Error(w, "missing host", http.StatusBadRequest)
		return
	}
	area := strings.TrimSpace(q.Get("area"))
	if area == "" {
		area = stashArea
	}
	s.mu.Lock()
	target := ""
	if hv := s.hosts[hostID]; hv != nil {
		target = hv.ExtensionTargets[area] // nil map indexes to "" -- no panic
	}
	// Registration silent (the owning host's status server is down, or the host
	// aged out of the view) -> the service's self-announced target still
	// resolves the redirect; the service keeps announcing as long as it lives.
	if target == "" {
		if av := s.announce[announceKey(hostID, area)]; av != nil {
			target = av.Target
		}
	}
	s.mu.Unlock()
	if target == "" {
		http.Error(w, "stash target not known to the pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, strings.TrimRight(target, "/"), http.StatusFound)
}

// handleGoCycle bridges a dashboard timeline click -> the host's own cycle-results
// folder. The state-timeline series is intentionally IP-free (keyed on hostId so a
// host's row doesn't split when its IP changes), so the link cannot carry the IP;
// this resolves it LIVE from the in-memory view (the host's CURRENT IP -- the whole
// point: the link survives an IP change). The cycle folder for the clicked time is
// the current cycle (fast path, no fetch) when t falls in it, else the cycle active
// at t resolved from the host's /log/ listing (works for any retained cycle, old or
// new), else the Loki transition feed (a host that has aged out of the live view).
// Degrades gracefully: missing/zero time -> current cycle; folder unresolved -> the
// host's status root (still the right host at its current IP); host unknown -> 404.
func (s *poolState) handleGoCycle(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := strings.TrimSpace(q.Get("host"))
	if hostID == "" {
		http.Error(w, "missing host", http.StatusBadRequest)
		return
	}
	var clickT time.Time
	if ms, err := strconv.ParseInt(strings.TrimSpace(q.Get("t")), 10, 64); err == nil && ms > 0 {
		clickT = time.Unix(0, ms*int64(time.Millisecond)).UTC()
	}
	pool := strings.TrimSpace(q.Get("pool"))

	s.mu.Lock()
	var curFolder string
	var curStart time.Time
	if hv := s.hosts[hostID]; hv != nil && hv.Status != nil {
		curFolder = hv.Status.CycleFolderUrl
		if tt, perr := time.Parse(time.RFC3339, hv.Status.StartedAt); perr == nil {
			curStart = tt
		}
	}
	s.mu.Unlock()

	// Resolve the host's current base URL (live IP, else the last IP Loki recorded);
	// also normalizes an empty pool so the per-cycle folder lookups below can scope.
	base, pool := s.resolveHostBase(hostID, pool)
	if base == "" {
		http.Error(w, "host not known to the pool", http.StatusNotFound)
		return
	}

	folder := ""
	switch {
	case curFolder != "" && (clickT.IsZero() || (!curStart.IsZero() && !clickT.Before(curStart))):
		folder = curFolder // current cycle (in-memory, no fetch)
	case !clickT.IsZero():
		// Resolve the cycle active at the clicked time from the host's /log/ listing:
		// the folder name encodes its start time + hostId, so this works for ANY
		// retained cycle (old + new) and supplies the cycle-number prefix that can't be
		// reconstructed from the transition line. Loki's cycleFolderUrl is the fallback
		// when the listing can't be fetched.
		folder = s.resolveFolderByListing(base, hostID, clickT)
		if folder == "" {
			if fu, _, found := s.lookupCycleAt(pool, hostID, clickT); found {
				folder = fu
			}
		}
	}

	target := strings.TrimRight(base, "/")
	if folder != "" {
		target += "/" + strings.TrimLeft(folder, "/")
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
	u := strings.TrimRight(baseURL, "/") + "/log/"
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
	return pickFolderFromListing(string(body), hostID, t)
}

// pickFolderFromListing scans a /log/ index page for this host's cycle folders
// (`<6-digit cycle number>.<YYYY-MM-DD>.<HH-mm-ss>.<hostId>[.incomplete]/`, the
// Format-CycleFolderBaseName shape) and returns the one whose encoded start time is
// the latest at/before t -- the cycle active at the clicked moment. When t predates
// every retained folder it returns the earliest, so the link still lands on a real
// cycle. Pure + table-testable; "" when nothing matches.
func pickFolderFromListing(body, hostID string, t time.Time) string {
	re := regexp.MustCompile(`\d{6}\.(\d{4}-\d{2}-\d{2})\.(\d{2}-\d{2}-\d{2})\.` + regexp.QuoteMeta(hostID) + `(?:\.incomplete)?/`)
	best, earliest := "", ""
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
	if best == "" {
		best = earliest
	}
	if best == "" {
		return ""
	}
	return "log/" + strings.TrimSuffix(best, "/") + "/"
}

func (s *poolState) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	total := len(s.hosts)
	reachable := 0
	for _, h := range s.hosts {
		if h.Reachable {
			reachable++
		}
	}
	// Union of every hostId across the live view + the cycle counters, so each
	// per-host series set is complete (a host with no terminal cycles yet still
	// gets pass/fail=0, and an evicted host's counters linger until seenTTL).
	hostIDs := map[string]bool{}
	for h := range s.hosts {
		hostIDs[h] = true
	}
	for h := range s.pass {
		hostIDs[h] = true
	}
	for h := range s.fail {
		hostIDs[h] = true
	}
	ids := sortedKeys(hostIDs)

	var b strings.Builder
	fmt.Fprintf(&b, "# HELP yuruna_pool_collector_up Pool aggregator is serving.\n# TYPE yuruna_pool_collector_up gauge\nyuruna_pool_collector_up 1\n")
	fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_total Pool hosts discovered (within hostTTL).\n# TYPE yuruna_pool_hosts_total gauge\nyuruna_pool_hosts_total %d\n", total)
	fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_reachable Pool hosts answering status.json on the last poll.\n# TYPE yuruna_pool_hosts_reachable gauge\nyuruna_pool_hosts_reachable %d\n", reachable)
	if !s.last.IsZero() {
		fmt.Fprintf(&b, "# HELP yuruna_pool_last_poll_timestamp_seconds Unix time of the last completed poll.\n# TYPE yuruna_pool_last_poll_timestamp_seconds gauge\nyuruna_pool_last_poll_timestamp_seconds %d\n", s.last.Unix())
	}

	// Per-host descriptive series that drive the dashboard's pool table.
	// host_info carries the table's label cells (name, type, framework version,
	// commit + its deep-link URLs, other deep-link URLs, current cycle, derived
	// status); the value is a constant 1. The series churns when
	// cycleId/status/IP change -- fine for an INSTANT table query (old label-sets
	// go stale immediately since only the current set is exported), but is why
	// status/cycle are NOT labels on the timeline series.
	b.WriteString("# HELP yuruna_pool_host_info Per-host descriptive labels for the pool table (value always 1).\n# TYPE yuruna_pool_host_info gauge\n")
	for _, h := range ids {
		hv := s.hosts[h]
		if hv == nil {
			continue
		}
		hostType, cycleId, cfu := "", "", ""
		commitDisplay, commitURLVal, projectCommitURL := "", "", ""
		if hv.Status != nil {
			hostType, cycleId, cfu = hv.Status.Host, hv.Status.CycleId, hv.Status.CycleFolderUrl
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
		fmt.Fprintf(&b, "yuruna_pool_host_info{pool=%q,poolGuid=%q,hostId=%q,hostType=%q,version=%q,commit=%q,commitUrl=%q,projectCommitUrl=%q,baseUrl=%q,cycleId=%q,cycleFolderUrl=%q,status=%q} 1\n",
			s.poolFor(h), hv.PoolGuid, h, hostType, hv.Version, commitDisplay, commitURLVal, projectCommitURL, hv.BaseURL, cycleId, cfu, hv.statusLabel())
	}
	// host_status: the numeric twin of host_info's status, keyed on hostId so it
	// forms one continuous series per host -- the input the state-timeline panel
	// needs. No hostname label (pool view is hostname-free). 0=unreachable
	// 1=running 2=pass 3=fail 4=idle 5=paused.
	b.WriteString("# HELP yuruna_pool_host_status Per-host cycle status code (0=unreachable 1=running 2=pass 3=fail 4=idle 5=paused).\n# TYPE yuruna_pool_host_status gauge\n")
	for _, h := range ids {
		hv := s.hosts[h]
		if hv == nil {
			continue
		}
		fmt.Fprintf(&b, "yuruna_pool_host_status{pool=%q,hostId=%q} %d\n", s.poolFor(h), h, hv.statusCode())
	}
	// host_last_seen: unix seconds of last successful probe; the table shows age
	// as `time() - this`. Keeps climbing for an unreachable-but-not-yet-evicted
	// host, which is exactly the "last seen 5m ago" signal an operator wants.
	b.WriteString("# HELP yuruna_pool_host_last_seen_seconds Unix time of the last successful status probe for this host.\n# TYPE yuruna_pool_host_last_seen_seconds gauge\n")
	for _, h := range ids {
		hv := s.hosts[h]
		if hv == nil {
			continue
		}
		fmt.Fprintf(&b, "yuruna_pool_host_last_seen_seconds{pool=%q,hostId=%q} %d\n", s.poolFor(h), h, hv.LastSeenUnixMs/1000)
	}

	// Extension hosts: hosts ACTIVELY running an extension function (e.g. a
	// stash-server VM), learned from TWO sources sharing the pool table's hostId
	// namespace: each host's registration record (activeExtensions, read through
	// that host's status server) and the service's own presence announce (POST
	// /announce, sent by the service VM itself) -- so the row survives the owning
	// host's status server being down. No ystash-nas mount / Config Service:
	// a host (or its service) self-reports what runs, and the aggregator already
	// polls registrations. area maps to a friendly label ("stash-service" ->
	// "Stash service") in the dashboard. One row per (hostId, area).
	//
	// baseUrl (the host's status page) and target (the service UI the host advertised
	// in extensionTargets, e.g. the stash VM) ride as labels so the dashboard can deep-
	// link each cell DIRECTLY. A Grafana table built from an instant query turns labels
	// into string COLUMNS that carry no field labels, so a `${__field.labels.hostId}`
	// redirect URL resolves to an empty host -- the working pattern (proven by
	// yuruna_pool_host_info's baseUrl, which the Pool hosts table links identically) is a
	// hidden URL column linked via `${__data.fields.<col>}`. Same instant-query label
	// churn tradeoff as host_info: a changed IP exports a fresh label-set and the stale
	// one drops. /go/stash stays for IP-free (hostId-only) consumers. target is "" until
	// the host resolves the service VM's address.
	type extRow struct {
		host    string
		area    string
		baseURL string
		target  string
		// lastSeen is the row's own freshness in unix seconds: the host's last
		// successful probe for a registration-sourced row, the last accepted
		// hello for an announce-sourced one.
		lastSeen int64
	}
	extRows := []extRow{}
	covered := map[string]bool{}
	for _, h := range ids {
		hv := s.hosts[h]
		if hv == nil {
			continue
		}
		for _, area := range hv.ActiveExtensions {
			if area == "" {
				continue
			}
			extRows = append(extRows, extRow{host: h, area: area, baseURL: hv.BaseURL, target: hv.ExtensionTargets[area], lastSeen: hv.LastSeenUnixMs / 1000})
			covered[announceKey(h, area)] = true
		}
	}
	// Self-announced services (POST /announce) fill the rows the registration
	// path cannot see right now -- e.g. the stash VM of a host whose status
	// server is down. When both sources cover one (hostId, area), the
	// registration row wins: it is the owning host's own advertisement and
	// carries the host's status baseUrl. An announce-only row still resolves
	// baseUrl from the view when the host is at least known (a stub or an
	// unreachable entry); "" otherwise, and the table's Host ID cell simply
	// carries no link until the host returns.
	annKeys := make([]string, 0, len(s.announce))
	for k := range s.announce {
		if !covered[k] {
			annKeys = append(annKeys, k)
		}
	}
	sort.Strings(annKeys)
	for _, k := range annKeys {
		av := s.announce[k]
		baseURL := ""
		if hv := s.hosts[av.HostId]; hv != nil {
			baseURL = hv.BaseURL
		}
		extRows = append(extRows, extRow{host: av.HostId, area: av.Area, baseURL: baseURL, target: av.Target, lastSeen: av.LastSeenUnixMs / 1000})
	}
	if len(extRows) > 0 {
		b.WriteString("# HELP yuruna_pool_host_extension Per-host actively-running extension area (value always 1).\n# TYPE yuruna_pool_host_extension gauge\n")
		for _, e := range extRows {
			fmt.Fprintf(&b, "yuruna_pool_host_extension{pool=%q,hostId=%q,area=%q,baseUrl=%q,target=%q} 1\n", s.poolFor(e.host), e.host, e.area, e.baseURL, e.target)
		}
		b.WriteString("# HELP yuruna_pool_host_extension_last_seen_seconds Unix time this extension host was last confirmed (host probe or service announce).\n# TYPE yuruna_pool_host_extension_last_seen_seconds gauge\n")
		for _, e := range extRows {
			fmt.Fprintf(&b, "yuruna_pool_host_extension_last_seen_seconds{pool=%q,hostId=%q,area=%q} %d\n", s.poolFor(e.host), e.host, e.area, e.lastSeen)
		}
	}

	// Incident correlation signals (N-failures-in-M-minutes).
	fmt.Fprintf(&b, "# HELP yuruna_pool_incidents_active Hosts currently in an incident (>= incidentN fails within the window).\n# TYPE yuruna_pool_incidents_active gauge\nyuruna_pool_incidents_active %d\n", len(s.incident))
	b.WriteString("# HELP yuruna_pool_host_incident 1 if the host is currently in an incident, else 0.\n# TYPE yuruna_pool_host_incident gauge\n")
	for _, h := range ids {
		v := 0
		if s.incident[h] != nil {
			v = 1
		}
		fmt.Fprintf(&b, "yuruna_pool_host_incident{pool=%q,hostId=%q} %d\n", s.poolFor(h), h, v)
	}
	// host_incident_info carries the dominant failure class of an active incident as a
	// label (the 0/1 gauge above stays class-free so its sum() tile is unaffected);
	// emitted only for hosts currently in an incident. Mirrors host_info.
	b.WriteString("# HELP yuruna_pool_host_incident_info Dominant failure class of a host's active incident (value always 1).\n# TYPE yuruna_pool_host_incident_info gauge\n")
	for _, h := range ids {
		if inc := s.incident[h]; inc != nil {
			cls := inc.dominantClass
			if cls == "" {
				cls = "unknown"
			}
			fmt.Fprintf(&b, "yuruna_pool_host_incident_info{pool=%q,hostId=%q,class=%q} 1\n", s.poolFor(h), h, cls)
		}
	}
	b.WriteString("# HELP yuruna_pool_host_recent_fail_count Failed cycles for this host within the incident window.\n# TYPE yuruna_pool_host_recent_fail_count gauge\n")
	for _, h := range ids {
		fmt.Fprintf(&b, "yuruna_pool_host_recent_fail_count{pool=%q,hostId=%q} %d\n", s.poolFor(h), h, len(s.failWindow[h]))
	}
	// Cross-host (pool-wide) incident: _wide_incident is the hysteresis state set
	// by evaluateIncidents; _wide_incident_hosts is the instantaneous count of
	// distinct hosts that failed within crossWin.
	poolInc := 0
	if s.poolIncident != nil {
		poolInc = 1
	}
	// Window this count against the last completed poll's clock (not scrape
	// time) so it stays consistent with the latched yuruna_pool_wide_incident
	// above: evaluateIncidents decides that flag at the poll using the same
	// window, so a scrape-time cut would let hosts age out and disagree with a
	// still-set flag between polls. Before the first poll s.last is zero, but a
	// Loki rehydrate can already have seeded failWindow and restored the
	// incident, so fall back to scrape time there to report the true recent
	// count rather than a forced zero that would disagree with the restored flag.
	ref := s.last
	if ref.IsZero() {
		ref = time.Now().UTC()
	}
	crossCut := ref.Add(-s.crossWin)
	recentHosts := 0
	for _, fw := range s.failWindow {
		if len(fw) > 0 && fw[len(fw)-1].t.After(crossCut) {
			recentHosts++
		}
	}
	fmt.Fprintf(&b, "# HELP yuruna_pool_wide_incident 1 if a pool-wide (cross-host) incident is active.\n# TYPE yuruna_pool_wide_incident gauge\nyuruna_pool_wide_incident %d\n", poolInc)
	fmt.Fprintf(&b, "# HELP yuruna_pool_wide_incident_hosts Distinct hosts that failed within the cross-host window.\n# TYPE yuruna_pool_wide_incident_hosts gauge\nyuruna_pool_wide_incident_hosts %d\n", recentHosts)
	// wide_incident_info carries the pinned same-class of an active pool-wide incident
	// as a label (the 0/1 gauge above stays class-free); emitted only when active.
	b.WriteString("# HELP yuruna_pool_wide_incident_info Pinned failure class of the active pool-wide incident (value always 1).\n# TYPE yuruna_pool_wide_incident_info gauge\n")
	if s.poolIncident != nil {
		cls := s.poolIncident.class
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
	gatePools := make([]string, 0, len(s.poolGate))
	for p := range s.poolGate {
		gatePools = append(gatePools, p)
	}
	sort.Strings(gatePools)
	b.WriteString("# HELP yuruna_pool_members_total Pool members currently in the view (within hostTTL).\n# TYPE yuruna_pool_members_total gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_members_total{pool=%q} %d\n", p, s.poolGate[p].lastTotal)
	}
	b.WriteString("# HELP yuruna_pool_members_healthy Pool members counted healthy (reachable, running/pass/idle, not in an incident).\n# TYPE yuruna_pool_members_healthy gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_members_healthy{pool=%q} %d\n", p, s.poolGate[p].lastHealthy)
	}
	b.WriteString("# HELP yuruna_pool_healthy_fraction Fraction of pool members counted healthy on the last poll.\n# TYPE yuruna_pool_healthy_fraction gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_healthy_fraction{pool=%q} %g\n", p, s.poolGate[p].lastFraction)
	}
	b.WriteString("# HELP yuruna_pool_healthy_threshold Configured healthy-fraction threshold (default 0.5); a Grafana rule needs no hardcode.\n# TYPE yuruna_pool_healthy_threshold gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_healthy_threshold{pool=%q} %g\n", p, s.poolGate[p].lastThreshold)
	}
	b.WriteString("# HELP yuruna_pool_degraded 1 if the healthy fraction stayed below the threshold for >= degradedAfterMinutes (advisory).\n# TYPE yuruna_pool_degraded gauge\n")
	for _, p := range gatePools {
		v := 0
		if s.poolGate[p].degraded {
			v = 1
		}
		fmt.Fprintf(&b, "yuruna_pool_degraded{pool=%q} %d\n", p, v)
	}
	b.WriteString("# HELP yuruna_pool_alert_active 1 if the pool's degraded alert is latched (authored-gating pools only).\n# TYPE yuruna_pool_alert_active gauge\n")
	for _, p := range gatePools {
		if !s.poolGate[p].authored {
			continue
		}
		v := 0
		if s.poolGate[p].alertFired {
			v = 1
		}
		fmt.Fprintf(&b, "yuruna_pool_alert_active{pool=%q} %d\n", p, v)
	}

	b.WriteString("# HELP yuruna_pool_cycles_pass_total Terminal passing cycles observed.\n# TYPE yuruna_pool_cycles_pass_total counter\n")
	for _, h := range ids {
		fmt.Fprintf(&b, "yuruna_pool_cycles_pass_total{pool=%q,hostId=%q} %d\n", s.poolFor(h), h, s.pass[h])
	}
	b.WriteString("# HELP yuruna_pool_cycles_fail_total Terminal failing cycles observed.\n# TYPE yuruna_pool_cycles_fail_total counter\n")
	for _, h := range ids {
		fmt.Fprintf(&b, "yuruna_pool_cycles_fail_total{pool=%q,hostId=%q} %d\n", s.poolFor(h), h, s.fail[h])
	}
	// Materialize the metrics text and release the lock before writing to the client, so a slow
	// scraper connection cannot hold s.mu across the network write and stall the poll goroutine
	// (mirrors handlePoolStatus).
	out := b.String()
	s.mu.Unlock()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = io.WriteString(w, out)
}

// requestSourceIP returns the connection's source IP (no port). RemoteAddr is the
// real peer on the trusted LAN; X-Forwarded-For is deliberately NOT consulted (it is
// client-settable and would let a member spoof another host's identity binding).
func requestSourceIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
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
		http.Error(w, "ingest disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	const bearer = "Bearer "
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, bearer) ||
		subtle.ConstantTimeCompare([]byte(auth[len(bearer):]), []byte(s.authToken)) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	srcIP := requestSourceIP(r)
	if srcIP == "" {
		http.Error(w, "no source address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxEventFetch))
	if err != nil {
		http.Error(w, "payload too large or unreadable", http.StatusRequestEntityTooLarge)
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
			http.Error(w, "too many lines", http.StatusRequestEntityTooLarge)
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
		http.Error(w, "batch mixes multiple hostIds", http.StatusForbidden)
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
	s.mu.Lock()
	var atIP []string
	for hid, hv := range s.hosts {
		if hv.CurrentIP != "" && hv.CurrentIP == srcIP {
			atIP = append(atIP, hid)
		}
	}
	hostID := ""
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
	poolLabel := ""
	if hostID != "" {
		poolLabel = s.poolFor(hostID)
	}
	s.mu.Unlock()
	if hostID == "" {
		http.Error(w, "sender identity could not be bound (undiscovered IP, hostId not owned by this IP, or ambiguous)", http.StatusForbidden)
		return
	}
	pushEvents(s.httpClient, s.lokiURL, poolLabel, hostID, lines, time.Now().UTC())
	w.WriteHeader(http.StatusAccepted)
}

// handleAnnounce is the extension-presence write surface: a service VM (e.g.
// the stash server's presence beacon) POSTs {hostId, area, targetPort, active}
// on boot, every beacon period, and (active=false) at shutdown, so the
// dashboard's Extension hosts row exists WITHOUT the owning host's status
// server -- the registration path goes silent the moment that server is down
// (the state a host reboot routinely leaves behind), while the service VM
// itself keeps running and announcing.
//
// Security posture -- deliberately OPEN (no bearer), unlike /ingest, because
// requiring the default-off shared token would leave the beacon dead exactly
// in the deployments it was built for. The write is contained instead:
// (1) SELF-IDENTITY BINDING -- the advertised service URL is DERIVED from the
// connection's source IP (or, when sent explicitly, must match it), so an
// announcer can only ever advertise itself, the same trust squid-log discovery
// already extends to any LAN client; (2) telemetry-only -- it paints a
// dashboard row and a redirect target, and reaches no control plane, host
// probing, or cycle accounting; (3) bounded -- tiny body cap, strict
// hostId/area charsets (they become metric labels), at most maxAnnounce
// entries, and a TTL reap; (4) goodbyes only remove an entry the same source
// (or an address-less rehydrated entry) owns. -announce-ttl 0 disables the
// route entirely.
func (s *poolState) handleAnnounce(w http.ResponseWriter, r *http.Request) {
	if s.announceTTL <= 0 {
		http.Error(w, "announce disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	srcIP := requestSourceIP(r)
	if srcIP == "" {
		http.Error(w, "no source address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAnnounceBody))
	if err != nil {
		http.Error(w, "payload too large or unreadable", http.StatusRequestEntityTooLarge)
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
		http.Error(w, "malformed announce", http.StatusBadRequest)
		return
	}
	if a.Area == "" {
		a.Area = stashArea
	}
	if !announceHostIDRE.MatchString(a.HostId) || !announceAreaRE.MatchString(a.Area) {
		http.Error(w, "invalid hostId or area", http.StatusBadRequest)
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
			http.Error(w, "invalid target URL", http.StatusBadRequest)
			return
		}
		if u.Hostname() != srcIP {
			http.Error(w, "target host must be the announcing address", http.StatusForbidden)
			return
		}
	case a.TargetPort == 80:
		target = "http://" + srcIP
	case a.TargetPort > 0 && a.TargetPort < 65536:
		target = "http://" + net.JoinHostPort(srcIP, strconv.Itoa(a.TargetPort))
	}
	active := a.Active == nil || *a.Active
	key := announceKey(a.HostId, a.Area)
	s.mu.Lock()
	poolLabel := s.pool
	accepted := true
	if !active {
		// Only the entry's own source (or an address-less rehydrated entry)
		// may remove it; anyone else's goodbye is a silent no-op.
		if av := s.announce[key]; av != nil && (av.sourceIP == "" || av.sourceIP == srcIP) {
			delete(s.announce, key)
		}
	} else {
		av := s.announce[key]
		if av == nil {
			if len(s.announce) >= maxAnnounce {
				accepted = false
			} else {
				av = &announceView{HostId: a.HostId, Area: a.Area}
				s.announce[key] = av
			}
		}
		if av != nil {
			av.Target, av.sourceIP, av.LastSeenUnixMs = target, srcIP, time.Now().UTC().UnixMilli()
		}
	}
	s.mu.Unlock()
	if !accepted {
		http.Error(w, "too many announced extensions", http.StatusTooManyRequests)
		return
	}
	// Push after the unlock so a slow Loki never stalls the handler; goodbyes
	// are pushed too so the latest line decides restart state.
	pushAnnounce(s.httpClient, s.lokiURL, poolLabel, a.HostId, a.Area, target, active, time.Now().UTC())
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	addr := flag.String("listen", defaultListenAddr, "address to listen on")
	squidLog := flag.String("squid-log", defaultSquidLog, "squid access log to discover pool client IPs from")
	lokiURL := flag.String("loki", defaultLokiURL, "Loki push API URL")
	pool := flag.String("pool", defaultPool, "pool name label")
	statusPort := flag.Int("status-port", defaultStatusPort, "status-server port to probe on each discovered IP")
	interval := flag.Duration("interval", defaultInterval, "poll/discover interval")
	rehydrateWin := flag.Duration("rehydrate-window", defaultRehydrate, "on startup, restore cycle counts from Loki over this trailing window (0 to disable)")
	incidentN := flag.Int("incident-fails", defaultIncidentN, "open an incident after this many failed cycles within -incident-window")
	incidentWin := flag.Duration("incident-window", defaultIncidentWin, "trailing window for the N-failures-in-M-minutes incident rule")
	crossN := flag.Int("cross-host-fails", defaultCrossN, "distinct hosts that must fail within -cross-host-window to open a pool-wide incident")
	crossWin := flag.Duration("cross-host-window", defaultCrossWin, "window for cross-host (pool-wide) incident correlation")
	announceTTL := flag.Duration("announce-ttl", defaultAnnounceTTL, "reap a self-announced extension (POST /announce) not refreshed within this window; 0 disables the announce route")
	tlsCert := flag.String("tls-cert", "", "TLS certificate file (PEM); when both -tls-cert and -tls-key name readable files the listener is HTTPS, else plain HTTP")
	tlsKey := flag.String("tls-key", "", "TLS private-key file (PEM); see -tls-cert")
	authTokenFile := flag.String("auth-token-file", "", "file holding the shared bearer token that gates POST /ingest; empty/absent/empty-file -> /ingest disabled (never an unauthenticated write route)")
	flag.Parse()

	ctx, cancel := context.WithCancel(context.Background())
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; cancel() }()

	state := newPoolState(*pool, *statusPort)
	state.incidentN = *incidentN
	state.incidentWin = *incidentWin
	state.crossN = *crossN
	state.crossWin = *crossWin
	state.announceTTL = *announceTTL
	client := newInternalHTTPClient(probeTimeout)
	state.lokiURL = *lokiURL
	state.httpClient = client
	// Load the shared bearer token that GATES /ingest. Absent / empty file -> token
	// stays "" -> the route is disabled (503), so it is never exposed unauthenticated.
	if *authTokenFile != "" {
		if b, rerr := os.ReadFile(*authTokenFile); rerr == nil {
			state.authToken = strings.TrimSpace(string(b))
		} else {
			log.Printf("auth-token-file %q unreadable (%v); /ingest disabled", *authTokenFile, rerr)
		}
	}

	go func() {
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
		state.pollOnce(client, *squidLog, *lokiURL, now)
		t := time.NewTicker(*interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				state.pollOnce(client, *squidLog, *lokiURL, time.Now().UTC())
			}
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", state.handleHealth)
	mux.HandleFunc("/metrics", state.handleMetrics)
	mux.HandleFunc("/api/v1/pool-status", state.handlePoolStatus)
	// /go/cycle: dashboard timeline click -> 302 to the host's cycle-results folder,
	// resolving the host's CURRENT IP live (so the link survives an IP change). Open
	// (no auth): it only redirects to a host's already-open status server.
	mux.HandleFunc("/go/cycle", state.handleGoCycle)
	// /go/host: same uuid->current-IP resolution as /go/cycle, but 302s to the host's
	// status-page ROOT (not a cycle folder) -- the timeline's "open host status page"
	// link, so the IP-free state-timeline rows reach the per-host status page too.
	mux.HandleFunc("/go/host", state.handleGoHost)
	// /go/stash: dashboard Extension-cell click -> 302 to the host's stash VM UI, from
	// the URL that host advertised (extensionTargets). Open (no auth): it only redirects
	// to a host's already-open stash UI, the same posture as /go/host.
	mux.HandleFunc("/go/stash", state.handleGoStash)
	// /ingest stays registered always; it self-gates on the auth token (503 when
	// unconfigured). /metrics, /healthz, /api/v1/pool-status remain OPEN + plaintext-
	// parseable so Prometheus, the host-side pool notifier, and the hostname-free
	// dashboard keep working without credentials.
	mux.HandleFunc("/ingest", state.handleIngest)
	// /announce: extension-presence beacon target (stash server et al). Open by
	// design with self-identity binding -- see handleAnnounce; self-gates on
	// -announce-ttl (503 when 0).
	mux.HandleFunc("/announce", state.handleAnnounce)

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
		log.Printf("tls-cert/tls-key set but not both readable+non-empty; serving plain HTTP")
	}
	authState := "ingest disabled (no token)"
	if state.authToken != "" {
		authState = "ingest enabled (bearer)"
	}
	scheme := "http"
	if useTLS {
		scheme = "https"
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	log.Printf("pool-aggregator listening on %s (%s), pool=%q, discover-from=%s, status-port=%d, loki=%s, interval=%s, %s",
		*addr, scheme, *pool, *squidLog, *statusPort, *lokiURL, *interval, authState)
	var serveErr error
	if useTLS {
		serveErr = srv.ListenAndServeTLS(*tlsCert, *tlsKey)
	} else {
		serveErr = srv.ListenAndServe()
	}
	if serveErr != nil && serveErr != http.ErrServerClosed {
		log.Fatal(serveErr)
	}
}
