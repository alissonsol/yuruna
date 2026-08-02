// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// pool-aggregator-service: read-only multi-host pool view for the Yuruna test harness.
//
// Runs on the caching-proxy-service machine (the pool services host). Auto-discovers
// pool members from the squid access log (no host list), identifies them by
// the stable hostId (DHCP-resilient, no DNS), and ships cycle transitions +
// per-step events to Loki/Prometheus for the Grafana pool dashboard.
// Read-only: killing it leaves every runner testing unaffected.
//
// Full design and operator guide: https://yuruna.link/pool-aggregator-service (README.md).
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
	defaultHostTtl     = 24 * time.Hour     // keep a hostId in the view this long after last contact
	defaultRehydrate   = 7 * 24 * time.Hour // restore cycle counts from Loki on startup over this trailing window
	probeTimeout       = 3 * time.Second    // LAN status probe (refused is instant; filtered times out)
	pushTimeout        = 10 * time.Second
	// poolStatsCacheTTL bounds how often /api/v1/pool-stats actually hits Loki.
	// Sized against the board's 30s auto-refresh: several phones refreshing
	// together collapse onto one query, and terminal cycle counts move far more
	// slowly than this anyway.
	poolStatsCacheTTL = 30 * time.Second
	maxProbe           = 8          // bounded concurrent probes per tick
	logTailBytes       = 512 * 1024 // bytes scanned from EOF for recent client IPs
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
	// owning host's status service. The TTL tolerates two missed beacons of the
	// stash service's default 15-minute period before the row is reaped.
	defaultAnnounceTtl = 45 * time.Minute
	maxAnnounce        = 512     // distinct (hostId,area) announce entries kept in memory
	maxAnnounceBody    = 4 << 10 // bytes read from one announce POST
	// Extension-target health. NO address is advertised to the pool until this
	// aggregator has itself reached it at <target>/healthz, and every advertised
	// address is re-confirmed each poll.
	//
	// The registration path carries an address the OWNING host resolved, and a
	// host can only see its own machine: a service VM that came up on a
	// hypervisor-private network (the macOS shared vmnet, a Hyper-V Default
	// Switch, libvirt's virbr0) answers its host and nothing else, so the host
	// confirms it in good faith and every other member of the pool then spends
	// its timeout budget on an address that cannot be routed to. The aggregator
	// sits where the consumers sit, so its own probe is the only check that
	// speaks for the pool rather than for one host.
	//
	// A confirmed target that goes quiet is kept for extensionHealthGrace -- a
	// service restart, a lost packet or a DHCP renewal must not empty the panel
	// -- and is then dropped: the announce entry is deleted (a service that
	// stopped answering has gone away as far as the pool can tell, the same
	// conclusion its goodbye carries) and a registration-sourced address stops
	// being published.
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
	// Pool gating defaults (mirror test/schemas/pools.schema.yml gating.*): the
	// advisory degraded/alert policy a pool inherits when it authors a partial (or
	// no) gating block. degradedAfter is the sustained-below-threshold window;
	// failures/successes are the poll-count alert hysteresis.
	defaultFailuresBeforeAlert  = 3
	defaultSuccessesBeforeRearm = 2
	defaultHealthyThreshold     = 0.5
	defaultDegradedAfter        = 1800 * time.Second
	// Lab connection token: the 6-char enrollment code the dashboard's "Lab
	// token" tile displays and POST /api/v1/lab-token exchanges for the shared
	// lab-auth-token (so enrolling a host never needs SSH into the proxy).
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
	controlProofTTL    = 15 * time.Minute
	controlProofMaxTTL = 20 * time.Minute
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
	CycleStartUtc        string `json:"cycleStartUtc"`
	OverallStatus  string `json:"overallStatus"`
	StartedAt      string `json:"startedAt"`
	FinishedAt     string `json:"finishedAt"`
	CycleFolderUrl string `json:"cycleFolderUrl"`
	// CyclePaused mirrors the host's control.cycle-pause flag (status.json sets it on
	// every write + the status service flips it on the pause toggle). Surfaces a paused
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
	// now (e.g. "stash-service" when it hosts a stash-service VM) -- distinct from
	// capabilities.extensions (what it COULD run). Read from the host's
	// registration record each poll; drives the dashboard's Extension hosts table.
	// Registration-sourced, so the aggregator never mounts ystash-nas to discover
	// stash services (no cross-host config service / NAS-credential dependency).
	ActiveExtensions []string `json:"activeExtensions,omitempty"`
	// ExtensionTargets maps an active extension area to the deep-link URL the host
	// advertises for it (e.g. "stash-service" -> the stash-service VM's UI base URL the host
	// resolved into its marker via Get-VMIp). Lets the dashboard's Extension cell
	// /go/stash to the stash-service VM without the aggregator keeping an address store of its
	// own. Registration-sourced like ActiveExtensions; empty until the host advertises
	// one. Also exposed in /api/v1/pool-status for the stash UI's hostId->stashBaseUrl
	// resolution.
	ExtensionTargets map[string]string `json:"extensionTargets,omitempty"`
	// Control is whether the dashboard's Host link can actually DRIVE this host:
	// one of the control* constants, from comparing the host's published
	// lab-auth-token tag (/control/control-status) with this proxy's. "" until
	// first learned; kept across a transient probe miss like Version, since the
	// answer changes only on enrollment. Drives host_info's control label -> the
	// dashboard's Control column.
	Control string `json:"control,omitempty"`
}

// controlLabel is Control with the never-learned case folded onto the state that
// says so, so the metric always carries a value the dashboard can map.
func (hv *hostView) controlLabel() string {
	if hv.Control == "" {
		return controlUnknown
	}
	return hv.Control
}

// announceView is one extension service's SELF-ANNOUNCED presence (POST
// /announce): the service VM itself reports "hostId X actively runs area Y at
// target Z", refreshed every beacon period. Its target is derived from the
// SOURCE address of the request, which makes it the strongest evidence the
// aggregator has -- first-hand, and about the address the service is actually
// reachable at. It therefore outranks the registration path (activeExtensions,
// read through the owning host's status service) when the two disagree, and
// carries the row on its own when that status server is down -- the state a
// host reboot routinely leaves behind. See extensionSourceRank. Entries are reaped
// after announceTtl without a refresh, or immediately on an active=false
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

// extHealthView is this aggregator's own verdict on one advertised extension
// address: has THIS process reached <target>/healthz, and when did that last
// work. Keyed by announceKey(hostId, area) in s.extHealth, and reset whenever
// the advertised address changes -- a verdict belongs to an address, not to a
// service.
//
// Confirmed separates "never reached" from "reached, then lost", which are
// opposite situations: a never-confirmed address is refused outright (this is
// what keeps a host-private address out of the pool), while a confirmed one is
// carried through extensionHealthGrace of failures before it is dropped.
type extHealthView struct {
	Target          string
	Confirmed       bool  // /healthz answered for this exact target at least once
	LastOkUnixMs    int64 // last successful probe (0 = never)
	FirstFailUnixMs int64 // start of the current failure streak (0 = not failing)
	LastError       string
}

// poolStatusEntry is one host in the /api/v1/pool-status snapshot: the
// hostView plus stashBaseUrl, the resolved stash-UI base the stash UI's
// hostId->URL lookup reads. Resolved at serialization time through
// extensionCandidatesLocked -- the same merge the dashboard cell and /go/stash
// read, so the three cannot disagree -- which prefers the service's own live
// announce and falls back to the host's registration.
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
// shipped to Loki, so a poll only forwards new lines. Reset when the cycleStartUtc
// changes (a new cycle = a new file).
type eventCursor struct {
	cycleStartUtc string
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
	seen         map[string]string    // hostId|cycleStartUtc -> last overallStatus pushed
	seenAt       map[string]time.Time
	counted      map[string]bool // hostId|cycleStartUtc counted as terminal
	pass         map[string]int64
	fail         map[string]int64
	failWindow   map[string][]failRec      // hostId -> in-window fails (ascending by .t), for incident correlation
	incident     map[string]*incidentState // hostId -> active incident (absent = none)
	poolIncident *poolIncidentState        // single active pool-wide incident (nil = none)
	gating       map[string]gatingPolicy   // pool -> authored gating policy (key present = authored)
	poolGate     map[string]*poolGateState // pool -> advisory degraded/alert latch
	announce     map[string]*announceView  // hostId|area -> self-announced extension presence
	announceTtl  time.Duration             // reap an announce entry not refreshed within this window (0 disables /announce)
	extHealth    map[string]*extHealthView // hostId|area -> this aggregator's own reachability verdict on the advertised address
	hostTtl      time.Duration             // drop a hostId from the view this long after last contact
	last         time.Time
	// Push-ingest: the shared bearer token gating POST /ingest (empty ->
	// ingest disabled, never an unauthenticated write route), plus the Loki push URL
	// + client the handler needs (set once in main before the server starts; not
	// mutated under mu).
	authToken  string
	lokiURL    string
	httpClient *http.Client
	// Lab connection token (dashboard enrollment code). labRotate is set once
	// in main before the server starts (not mutated under mu, like authToken);
	// 0 keeps the tile and POST /api/v1/lab-token disabled. labCodes /
	// labFails / labExchange are mu-guarded -- the rotation goroutine and the
	// HTTP handlers both touch them.
	labRotate   time.Duration
	labCodes    []string               // newest first: the current code, then up to labKeepCodes-1 predecessors
	labFails    map[string][]time.Time // source IP -> recent failed exchange attempts (throttle input)
	labExchange map[string]int64       // exchange outcome ("ok"/"refused"/"throttled") -> count
	// eventCur is touched ONLY by the single poll goroutine (in tailEvents and
	// the post-unlock prune below), never by the HTTP handlers, so it needs no
	// lock -- unlike the fields above, which mu guards against handler reads.
	eventCur map[string]*eventCursor // keyed by hostId
	// statsCache memoizes /api/v1/pool-stats per range. Several operators
	// pull-to-refreshing the board on phones must not turn into a Loki query
	// storm: each entry is two range queries, and the underlying counts move
	// only as fast as cycles finish. Guarded by its own mutex rather than mu so
	// a slow Loki read never blocks the poll loop or /api/v1/pool-status.
	statsMu    sync.Mutex
	statsCache map[string]*poolStatsCacheEntry // range token -> memoized answer
}

// poolStatsCacheEntry is one memoized /api/v1/pool-stats answer.
type poolStatsCacheEntry struct {
	at      time.Time
	payload []byte
}

func newPoolState(pool string, statusPort int) *poolState {
	return &poolState{
		pool: pool, statusPort: statusPort, incidentN: defaultIncidentN, incidentWin: defaultIncidentWin,
		crossN: defaultCrossN, crossWin: defaultCrossWin,
		hosts: map[string]*hostView{}, seen: map[string]string{}, seenAt: map[string]time.Time{},
		counted: map[string]bool{}, pass: map[string]int64{}, fail: map[string]int64{},
		failWindow: map[string][]failRec{}, incident: map[string]*incidentState{},
		gating: map[string]gatingPolicy{}, poolGate: map[string]*poolGateState{},
		announce: map[string]*announceView{}, announceTtl: defaultAnnounceTtl,
		extHealth: map[string]*extHealthView{},
		hostTtl:   defaultHostTtl,
		labFails:  map[string][]time.Time{}, labExchange: map[string]int64{},
		eventCur: map[string]*eventCursor{},
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
// marked unreachable but kept until hostTtl.
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
		control    string            // classified control state ("" = not fetched this poll; caller keeps prior)
	}
	// This proxy's own token tag, computed once per poll: the value every host's
	// published tag is compared against. "" when no lab-auth-token is configured,
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
				// Best-effort: can this host be driven from the dashboard? A
				// transport failure leaves pr.control "" and keeps the prior
				// verdict; a host that ANSWERS -- including an older build with no
				// such route -- replaces it, so "unknown" is reported rather than
				// a stale "ready" inherited forever. Classified here (in the
				// probe goroutine) against the poll's clock so the skew reading
				// is not skewed by the poll's own duration.
				if cs, cerr := fetchControlStatus(client, base); cerr == nil {
					pr.control = classifyControl(proxyTag, cs, now)
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
		// Same guard for the control verdict: "" means the probe did not answer
		// this tick, not that control was lost.
		if r.control != "" {
			hv.Control = r.control
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
				s.gating[r.poolID] = *r.gating
			}
		}
		refreshed[hid] = true
		if r.st.CycleStartUtc != "" {
			key := hid + "|" + r.st.CycleStartUtc
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
			if now.UnixMilli()-hv.LastSeenUnixMs > s.hostTtl.Milliseconds() {
				delete(s.hosts, hid)
				deleted = append(deleted, hid)
			}
		}
	}
	for k, t := range s.seenAt {
		if now.Sub(t) > s.seenTtl() {
			delete(s.seenAt, k)
			delete(s.seen, k)
			delete(s.counted, k)
		}
	}
	// Reap self-announced extensions whose beacon stopped refreshing (the
	// service died without a goodbye); a live service re-announces well inside
	// the TTL, so a reaped entry is genuinely gone, not merely between beacons.
	for k, av := range s.announce {
		if s.announceTtl > 0 && now.UnixMilli()-av.LastSeenUnixMs > s.announceTtl.Milliseconds() {
			delete(s.announce, k)
		}
	}
	// Snapshot the event-tail targets while holding the lock; the fetch+push
	// itself runs unlocked below so a slow host can't stall the handlers.
	type evTarget struct{ hostID, baseURL, cycleID, cycleFolderURL, poolLabel string }
	var targets []evTarget
	for hid, hv := range s.hosts {
		if hv.Reachable && hv.Status != nil && hv.Status.CycleStartUtc != "" && hv.Status.CycleFolderUrl != "" {
			// Capture the pool label here under the lock; tailEvents runs unlocked.
			targets = append(targets, evTarget{hid, hv.BaseURL, hv.Status.CycleStartUtc, hv.Status.CycleFolderUrl, s.poolFor(hid)})
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
// served by the status service at /yuruna-repo/VERSION -- the SAME source the
// host's own status pages read for their header (their getHostInfo() fetches
// yuruna-repo/VERSION via JS, so the version is not embedded in the HTML). A tiny
// plain-text file (one CalVer line, e.g. "2026.08.02"), so it is lighter than any
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

// controlStatus is one host's answer to GET /control/control-status: whether it
// can be driven remotely at all, and by WHICH lab-auth-token. TokenTag is
// base64(HMAC-SHA256(token,"yuruna-control|tag|v1")) -- a non-secret name for
// the token, never the token itself. Present is false when the route did not
// answer usably, which is NOT the same as "no token": an older framework build
// has no such route, and reporting that host as uncontrollable would be a
// guess. UtcNow is the host's clock, so the caller can catch the skew that
// expires a freshly minted proof.
type controlStatus struct {
	Present         bool
	TokenConfigured bool
	TokenTag        string
	UtcNow          time.Time
}

// fetchControlStatus reads /control/control-status. The route is open and
// read-only, so this needs no credential -- which is the point: the aggregator
// must be able to ask a host it may share nothing with. A 404 is reported as a
// definite absence (Present=false, err=nil) rather than an error: the host
// answered, it simply predates the route, and the caller must show "unknown"
// instead of inheriting a stale verdict forever. A transport failure returns the
// error so the caller can keep what it last knew.
func fetchControlStatus(client *http.Client, base string) (controlStatus, error) {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/control/control-status", nil)
	if err != nil {
		return controlStatus{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return controlStatus{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return controlStatus{}, nil // route absent: answered, but has nothing to say
	}
	if resp.StatusCode != http.StatusOK {
		return controlStatus{}, fmt.Errorf("control-status HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return controlStatus{}, err
	}
	var cs struct {
		TokenConfigured bool   `json:"tokenConfigured"`
		TokenTag        string `json:"tokenTag"`
		UtcNow          string `json:"utcNow"`
	}
	if err := json.Unmarshal(body, &cs); err != nil {
		return controlStatus{}, fmt.Errorf("control-status parse: %w", err)
	}
	out := controlStatus{Present: true, TokenConfigured: cs.TokenConfigured, TokenTag: cs.TokenTag}
	// An unparseable clock leaves UtcNow zero, which the classifier reads as
	// "no skew evidence" rather than as an enormous skew.
	if t, perr := time.Parse(time.RFC3339, cs.UtcNow); perr == nil {
		out.UtcNow = t.UTC()
	}
	return out, nil
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
				DegradedAfterSeconds *int     `json:"degradedAfterSeconds"`
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
		if reg.Gating.Quorum.DegradedAfterSeconds != nil && *reg.Gating.Quorum.DegradedAfterSeconds >= 0 {
			g.DegradedAfter = time.Duration(*reg.Gating.Quorum.DegradedAfterSeconds) * time.Second
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
// The value is interpolated into LogQL, so it is never free-form input; and the
// ceiling is 30d because Loki's retention_period is 720h -- a longer window
// would silently return a partial answer that reads as a real number.
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
		return out, fmt.Errorf("loki not configured")
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
		http.Error(w, `{"error":"unsupported range; use 1h, 24h, 7d or 30d"}`, http.StatusBadRequest)
		return
	}

	s.statsMu.Lock()
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
	if errPass != nil && errFail != nil {
		// Both legs failed: say so rather than serve zeros, which the board
		// would render as a real "0 cycles" and an operator would read as
		// "nothing ran" instead of "we could not tell".
		http.Error(w, `{"error":"loki query failed"}`, http.StatusBadGateway)
		return
	}

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
		http.Error(w, `{"error":"encode failed"}`, http.StatusInternalServerError)
		return
	}
	s.statsMu.Lock()
	if s.statsCache == nil {
		s.statsCache = map[string]*poolStatsCacheEntry{}
	}
	s.statsCache[window] = &poolStatsCacheEntry{at: time.Now(), payload: payload}
	s.statsMu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(payload)
}

// pushLoki POSTs one cycle-status transition to Loki. Labels are strictly
// {pool,hostId,cycleStartUtc} (low cardinality); the variable fields -- including the
// CURRENT baseURL for the dashboard's drill-down deep-link -- live in the line.
// The value timestamp is the proxy-side INGEST clock, not the host cycleStartUtc.
func pushLoki(client *http.Client, lokiURL, pool string, st *hostStatus, baseURL string, ingest time.Time) {
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
		m["failureClass"] = st.failClassOf()
	}
	line, _ := json.Marshal(m)
	payload := map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": pool, "hostId": st.HostId, "cycleStartUtc": st.CycleStartUtc, "src": "cycle"},
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
// entries still inside announceTtl (rehydrateAnnouncesFromLoki). Volume is one
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
// first-probe miss does not evict it before a full hostTtl of retries.
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
				CycleStartUtc       string `json:"cycleStartUtc"`
				OverallStatus string `json:"overallStatus"`
				FailureClass  string `json:"failureClass"`
				BaseUrl       string `json:"baseUrl"`
			}
			if json.Unmarshal([]byte(v[1]), &e) != nil || e.HostId == "" || e.CycleStartUtc == "" {
				continue
			}
			key := e.HostId + "|" + e.CycleStartUtc
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
// re-pushing within a running instance and resets when the cycleStartUtc changes.
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
	if cur == nil || cur.cycleStartUtc != cycleID {
		cur = &eventCursor{cycleStartUtc: cycleID}
		s.eventCur[hostID] = cur
	}
	if int64(len(body)) <= cur.offset {
		return // nothing new (or the file rotated/shrank under the same cycleStartUtc)
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
			rec["durationSeconds"] = int64(ev.now.Sub(ev.startedAt) / time.Second)
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
			rec["durationSeconds"] = int64(ev.now.Sub(ev.startedAt) / time.Second)
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
			rec["durationSeconds"] = int64(ev.now.Sub(ev.startedAt) / time.Second)
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
	// Merge once for the whole snapshot, not once per host: the resolution is
	// pool-wide, and rebuilding it inside the loop would be quadratic in hosts.
	cands := s.extensionCandidatesLocked(time.Now())
	for _, id := range ids {
		hv := s.hosts[id]
		// stashBaseUrl: the stash UI's hostId->URL lookup key, resolved through
		// the same merge the dashboard cell and /go/stash use so the three
		// cannot disagree.
		stash := cands[announceKey(id, stashArea)].Target
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
// address that changed has to earn its own confirmation. Caller holds s.mu.
func (s *poolState) applyExtensionProbeLocked(key, target string, probeErr error, now time.Time) {
	h := s.extHealth[key]
	if h == nil || h.Target != target {
		h = &extHealthView{Target: target}
		s.extHealth[key] = h
	}
	if probeErr == nil {
		h.Confirmed, h.LastOkUnixMs, h.FirstFailUnixMs, h.LastError = true, now.UnixMilli(), 0, ""
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
// re-announces of an address already confirmed. Takes s.mu itself; the probe
// runs unlocked.
func (s *poolState) confirmExtensionTarget(client *http.Client, key, target string, now time.Time) {
	if client == nil || target == "" || extensionTargetProblem(target) != "" {
		return
	}
	s.mu.Lock()
	h := s.extHealth[key]
	known := h != nil && h.Target == target
	s.mu.Unlock()
	if known {
		return
	}
	err := probeExtensionTarget(client, target)
	s.mu.Lock()
	s.applyExtensionProbeLocked(key, target, err, now)
	s.mu.Unlock()
}

// refreshExtensionHealth re-confirms every advertised extension address and
// drops the ones that have stayed silent past extensionHealthGrace. Runs once
// per poll: the address list is snapshotted under the lock, the probes run
// unlocked and concurrently (a black-holed address costs probeTimeout each), and
// the verdicts are applied under the lock again.
//
// Only the ANNOUNCE side can be deleted here. A registration-sourced address is
// re-asserted by its owning host on every poll, so deleting it would achieve
// nothing; it is suppressed instead (see extensionCandidatesLocked) until that
// host retracts it -- which Stop-StashServiceVM does by clearing the marker.
func (s *poolState) refreshExtensionHealth(client *http.Client, now time.Time) {
	if client == nil {
		return
	}
	type probeTarget struct{ key, target string }
	var targets []probeTarget
	s.mu.Lock()
	live := map[string]bool{}
	for key, cand := range s.extensionCandidatesLocked(now) {
		live[key] = true
		raw := cand.advertised()
		if raw == "" || extensionTargetProblem(raw) != "" {
			continue
		}
		targets = append(targets, probeTarget{key: key, target: raw})
	}
	// Forget verdicts about services the pool no longer lists at all, so the map
	// tracks the live set rather than growing with every service that ever ran.
	for key := range s.extHealth {
		if !live[key] {
			delete(s.extHealth, key)
		}
	}
	s.mu.Unlock()

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

	s.mu.Lock()
	defer s.mu.Unlock()
	for i, t := range targets {
		s.applyExtensionProbeLocked(t.key, t.target, errs[i], now)
	}
	for key, h := range s.extHealth {
		if h.FirstFailUnixMs == 0 || now.UnixMilli()-h.FirstFailUnixMs <= extensionHealthGrace.Milliseconds() {
			continue
		}
		if av := s.announce[key]; av != nil && av.Target == h.Target {
			log.Printf("extension %s: dropping the self-announced address %s -- unanswered for %s (%s)", key, h.Target, extensionHealthGrace, h.LastError)
			delete(s.announce, key)
		}
	}
}

// extensionSourceRank orders the ways an area's address reaches the aggregator,
// by the strength of the evidence behind it rather than by who sent it.
//
//	0  a live announce -- the service POSTed to us and the target was taken from
//	   the source address of that request, so the aggregator has first-hand
//	   evidence the service answers there
//	1  a registration -- the owning host resolved an address and wrote it into a
//	   file we read. Correct whenever nobody announces, but it is hearsay, and
//	   it lags: the runner writes host.registration.json BEFORE it refreshes the
//	   stash marker (the refresh needs Get-VMIp, wired later in startup), so
//	   extensionTargets always carries the value from the previous refresh. A
//	   service VM that is rebuilt onto a new DHCP address is therefore advertised
//	   at its predecessor's address for a whole cycle.
//	2  a rehydrated announce -- restored from the Loki feed after a collector
//	   restart. It is a real observation, but a historical one, and until a live
//	   beacon re-binds it the owning host's current word is worth more.
//
// A live announce is bounded by its beacon period (minutes) and reaped at TTL;
// a lagging registration is bounded by the cycle, which can be hours.
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
// answer. Deterministic all the way down -- usable, then source, then recency,
// then hostId -- so two aggregator instances holding the same facts answer
// identically and a consumer that re-asks gets a stable address rather than one
// that flaps between equally valid hosts.
//
// Usability comes FIRST, ahead of the source ranking: an address this aggregator
// has reached beats one it has not, whoever named it. Ranking evidence is how to
// choose between two addresses that could both work; it is not a reason to
// prefer a better-sourced address that demonstrably does not.
func betterExtensionCandidate(a, b extensionHostEntry) bool {
	if a.Suppressed != b.Suppressed {
		return !a.Suppressed
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
// handed out, and records why when it may not. Caller holds s.mu.
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
func (s *poolState) applyExtensionHealthLocked(e *extensionHostEntry, now time.Time) {
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
	h := s.extHealth[announceKey(e.HostId, e.Area)]
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
// it knows about, keyed by announceKey. Caller holds s.mu.
//
// This is the ONE place the registration and announce sources are merged. Every
// consumer -- the /metrics rows behind the dashboard's Extension hosts table,
// /api/v1/extension-hosts, pool-status's stashBaseUrl, and the /go/stash
// redirect -- reads it, because four hand-written copies of a precedence rule is
// how a correction lands in one of them and not the others.
//
// Entries with no target are kept: a host that advertises an area with no
// address still RUNS it, and the Extension hosts table says so with an
// unlinked cell. Callers that need an address (area resolution, a redirect)
// filter on Target themselves.
//
// Entries whose address the pool cannot reach are kept too, but SUPPRESSED --
// Target blanked, the refused address and the reason carried alongside. They
// answer nothing and link nowhere, while an operator can still see that a host
// claims a service the pool will not use, which is the one thing a silent drop
// would hide.
//
// A TTL-expired announce is skipped here rather than trusted until the next
// poll reaps it: a consumer asking between polls must not be handed the address
// of a service that stopped beaconing two TTLs ago.
func (s *poolState) extensionCandidatesLocked(now time.Time) map[string]extensionHostEntry {
	best := map[string]extensionHostEntry{}
	consider := func(cand extensionHostEntry) {
		if cand.Area == "" || cand.HostId == "" {
			return
		}
		s.applyExtensionHealthLocked(&cand, now)
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
	for hostID, hv := range s.hosts {
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
	for _, av := range s.announce {
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
			confirmed: av.sourceIP != "",
		})
	}
	return best
}

// resolveExtensionHostsLocked returns the pool's current best address per
// extension area. Caller holds s.mu.
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
func (s *poolState) resolveExtensionHostsLocked(now time.Time) map[string]extensionHostEntry {
	best := map[string]extensionHostEntry{}
	for _, cand := range s.extensionCandidatesLocked(now) {
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
// one host's area, or "" when it knows none. Caller holds s.mu. The single
// lookup behind /go/stash and pool-status's stashBaseUrl, so a redirect and the
// stash UI's own hostId->URL map cannot disagree with each other or with the
// dashboard cell.
func (s *poolState) extensionTargetForLocked(hostID, area string, now time.Time) string {
	return s.extensionCandidatesLocked(now)[announceKey(hostID, area)].Target
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
	s.mu.Lock()
	entries := s.resolveExtensionHostsLocked(now)
	cands := s.extensionCandidatesLocked(now)
	pool := s.pool
	s.mu.Unlock()

	var payload any
	if area != "" {
		entry, ok := entries[area]
		if !ok {
			http.Error(w, "no live host for that extension area", http.StatusNotFound)
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
		http.Error(w, "failed to encode extension hosts", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

// validForgetHostID mirrors the runner-side 42-prefixed 32-hex host.uuid shape
// (test/Remove-PoolHost.ps1, Remove-HostFromPool.ps1) so the forget endpoint
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
// re-appears). Callers hold NO lock; this takes s.mu itself.
func (s *poolState) forgetHost(hid string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, present := s.hosts[hid]
	delete(s.hosts, hid)
	delete(s.pass, hid)
	delete(s.fail, hid)
	delete(s.failWindow, hid)
	delete(s.incident, hid)
	// seen / seenAt / counted are keyed hostId|cycleStartUtc; announce is keyed
	// hostId|area -- drop every composite key belonging to this host.
	prefix := hid + "|"
	for k := range s.seen {
		if strings.HasPrefix(k, prefix) {
			delete(s.seen, k)
			delete(s.seenAt, k)
			delete(s.counted, k)
		}
	}
	for k := range s.announce {
		if strings.HasPrefix(k, prefix) {
			delete(s.announce, k)
		}
	}
	// extHealth is keyed the same way; a forgotten host's service must not leave
	// a verdict behind that would pre-confirm an address if the host returns.
	for k := range s.extHealth {
		if strings.HasPrefix(k, prefix) {
			delete(s.extHealth, k)
		}
	}
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
		http.Error(w, "forget-host disabled (no auth token configured)", http.StatusServiceUnavailable)
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
	hid := strings.TrimSpace(r.URL.Query().Get("hostId"))
	if !validForgetHostID(hid) {
		http.Error(w, "hostId must be a 42-prefixed 32-hex id", http.StatusBadRequest)
		return
	}
	present := s.forgetHost(hid)
	body, err := json.Marshal(struct {
		Forgotten  bool   `json:"forgotten"`
		HostId     string `json:"hostId"`
		WasPresent bool   `json:"wasPresent"`
	}{Forgotten: true, HostId: hid, WasPresent: present})
	if err != nil {
		http.Error(w, "failed to encode result", http.StatusInternalServerError)
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
				CycleStartUtc        string `json:"cycleStartUtc"`
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
// string "<expiry>.<base64 HMAC>" the host status service accepts on its mutating
// /control/* routes, where HMAC = HMAC-SHA256(lab-auth-token, "yuruna-control|proof|
// <expiry>"). It is byte-for-byte identical to Test.ConfigServiceSync\Get-YurunaControlProof
// (PowerShell) -- same HMAC-SHA256, same std base64, same data string -- so a proof minted
// here on the caching-proxy service validates on any pool host (the lab-auth-token is pool-wide).
// Verified by TestMintControlProofGolden against the shared golden vector.
func controlProofFor(token string, expiry int64) string {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|" + strconv.FormatInt(expiry, 10)))
	return strconv.FormatInt(expiry, 10) + "." + base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// mintControlProof mints a control proof valid for ttl from now, or "" when no
// lab-auth-token is configured (the host then only accepts loopback control). The
// operator reaches the host through Grafana -> /go/host, so this rides the proof to the
// browser in the redirect fragment; the host revalidates it (expiry window + HMAC).
func mintControlProof(token string, ttl time.Duration) string {
	if token == "" {
		return ""
	}
	return controlProofFor(token, time.Now().Add(ttl).Unix())
}

// controlTagFor is the Go twin of Test.ConfigServiceSync\Get-YurunaControlTag: a
// non-secret name for a lab-auth-token, base64(HMAC-SHA256(token,
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
	controlReady    = "ready"    // host holds the same token this proxy mints with
	controlNone     = "none"     // host holds no lab-auth-token: loopback control only
	controlMismatch = "mismatch" // host holds a DIFFERENT token (enrolled against a rebuilt proxy)
	controlSkew     = "skew"     // tokens agree but the clocks do not, so a fresh proof reads as expired
	controlUnknown  = "unknown"  // not determinable: route absent (older build), never probed, or this proxy holds no token to compare
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

// newLabCode mints one 6-char lowercase [a-z0-9] lab connection token. Unbiased:
// candidate bytes >= 252 (the largest multiple of 36 below 256) are discarded
// rather than folded, so no code is likelier than another.
func newLabCode() (string, error) {
	const charset = "abcdefghijklmnopqrstuvwxyz0123456789"
	out := make([]byte, 0, labTokenLen)
	buf := make([]byte, 1)
	for len(out) < labTokenLen {
		if _, err := rand.Read(buf); err != nil {
			return "", err
		}
		if buf[0] >= byte(len(charset))*7 {
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
		log.Printf("lab-token rotation failed (%v); keeping previous codes", err)
		return
	}
	cut := now.Add(-labFailWindow)
	s.mu.Lock()
	s.labCodes = append([]string{code}, s.labCodes...)
	if len(s.labCodes) > labKeepCodes {
		s.labCodes = s.labCodes[:labKeepCodes]
	}
	s.pruneLabFailsLocked(cut)
	s.mu.Unlock()
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
// connection token for the shared lab-auth-token, so enrolling a host is "read
// the 6-char code off the Yuruna hosts dashboard, run test/Set-LabToken.ps1"
// instead of SSHing into the proxy for the secret. Posture: the route is open
// -- the code IS the credential; whoever can view the dashboard may enroll a
// host -- verified constant-time against the retained codes (current + recent
// predecessors, so a code read from a panel about to refresh still redeems),
// per-IP throttled, and every attempt is audited to the log + Loki with the
// caller's address. The answer is sealed under the redeemed code (sealLabToken),
// so the shared token is never in the clear on the wire and only the redeemer
// can open it -- the listener is plain HTTP whenever the proxy has no TLS leaf.
// Self-disables (503) when rotation is off or no lab-auth-token is configured,
// mirroring /ingest.
func (s *poolState) handleLabToken(w http.ResponseWriter, r *http.Request) {
	if s.labRotate <= 0 || s.authToken == "" {
		http.Error(w, "lab-token exchange disabled", http.StatusServiceUnavailable)
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
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxLabTokenBody))
	if err != nil {
		http.Error(w, "payload too large or unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var req struct {
		LabToken string `json:"labToken"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "malformed request", http.StatusBadRequest)
		return
	}
	code := strings.ToLower(strings.TrimSpace(req.LabToken))
	if !labTokenRE.MatchString(code) {
		http.Error(w, "labToken must be 6 lowercase letters/digits", http.StatusBadRequest)
		return
	}
	now := time.Now().UTC()
	cut := now.Add(-labFailWindow)
	// Throttle by the /64 for IPv6: a single delegated prefix hands one
	// attacker more addresses than the map could ever hold, so per-address
	// buckets there would throttle nothing while growing without bound.
	throttleKey := labThrottleKey(srcIP)
	s.mu.Lock()
	recent := 0
	for _, t := range s.labFails[throttleKey] {
		if t.After(cut) {
			recent++
		}
	}
	throttled := recent >= labFailLimit
	match := false
	// audit is false for a repeat throttled attempt: once an address is
	// locked out, auditing every retry would let an anonymous caller amplify
	// one request into one log line and one Loki write apiece. The crossing
	// into throttled IS recorded, so the operator still sees the burst.
	audit := true
	if !throttled {
		// No early break: every retained code is compared so the timing does
		// not reveal WHICH slot (if any) matched.
		for _, c := range s.labCodes {
			if subtle.ConstantTimeCompare([]byte(code), []byte(c)) == 1 {
				match = true
			}
		}
		if !match {
			if len(s.labFails) >= maxLabFailKeys {
				s.pruneLabFailsLocked(cut)
			}
			if _, known := s.labFails[throttleKey]; known || len(s.labFails) < maxLabFailKeys {
				s.labFails[throttleKey] = append(s.labFails[throttleKey], now)
			}
		}
	} else {
		audit = recent == labFailLimit
	}
	outcome := "ok"
	if throttled {
		outcome = "throttled"
	} else if !match {
		outcome = "refused"
	}
	s.labExchange[outcome]++
	poolLabel := s.pool
	token := s.authToken
	s.mu.Unlock()
	// Audit after the unlock (a slow Loki must not stall the handler);
	// refusals are audited too -- a burst of them is the operator's signal
	// that someone is poking the enrollment surface. The code itself is
	// never logged: a refused one is a guess worth nothing, and an accepted
	// one would put a live credential in the log.
	if audit {
		log.Printf("lab-token exchange %s from %s", outcome, srcIP)
		line, _ := json.Marshal(map[string]string{"sourceIp": srcIP, "outcome": outcome})
		pushLokiStream(s.httpClient, s.lokiURL, "lab-token exchange",
			map[string]string{"pool": poolLabel, "src": "lab-token"}, line, now)
	}
	switch {
	case throttled:
		w.Header().Set("Retry-After", strconv.Itoa(int(labFailWindow/time.Second)))
		http.Error(w, "too many failed attempts; retry later", http.StatusTooManyRequests)
	case !match:
		http.Error(w, "unknown or expired lab token", http.StatusForbidden)
	default:
		envelope, err := sealLabToken(code, token)
		if err != nil {
			log.Printf("lab-token exchange: sealing failed (%v)", err)
			http.Error(w, "failed to seal the token", http.StatusInternalServerError)
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

// pruneLabFailsLocked drops throttle records that have aged out. Called from
// the rotation tick and, when the map hits its cap, from the handler.
// MUST be called with s.mu held.
func (s *poolState) pruneLabFailsLocked(cut time.Time) {
	for ip, times := range s.labFails {
		kept := times[:0]
		for _, t := range times {
			if t.After(cut) {
				kept = append(kept, t)
			}
		}
		if len(kept) == 0 {
			delete(s.labFails, ip)
		} else {
			s.labFails[ip] = kept
		}
	}
}

// dashedHostIDRE matches the GUID-formatted rendering of a 32-hex hostId
// (8-4-4-4-12). The dashboard tables display hostIds in that form, and a data
// link built from the rendered cell value carries it verbatim; the pool keys
// hosts on the undashed form everywhere else.
var dashedHostIDRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

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
	if proof := mintControlProof(s.authToken, controlProofTTL); proof != "" {
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
func (s *poolState) handleGoStash(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		http.Error(w, "missing host", http.StatusBadRequest)
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
	// status server is down and the announce is all there is.
	s.mu.Lock()
	target := s.extensionTargetForLocked(hostID, area, time.Now())
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
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
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
	// gets pass/fail=0). A reaped host keeps reporting its totals: pass/fail are
	// cumulative and are NOT time-expired -- only forgetHost clears them, so they
	// otherwise survive until the process restarts. The TTL'd state is the
	// per-cycle dedup set below, not these counters.
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
	fmt.Fprintf(&b, "# HELP yuruna_pool_collector_up pool-aggregator service is serving.\n# TYPE yuruna_pool_collector_up gauge\nyuruna_pool_collector_up 1\n")
	fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_total Pool hosts discovered (within hostTtl).\n# TYPE yuruna_pool_hosts_total gauge\nyuruna_pool_hosts_total %d\n", total)
	fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_reachable Pool hosts answering status.json on the last poll.\n# TYPE yuruna_pool_hosts_reachable gauge\nyuruna_pool_hosts_reachable %d\n", reachable)
	if !s.last.IsZero() {
		fmt.Fprintf(&b, "# HELP yuruna_pool_last_poll_timestamp_seconds Unix time of the last completed poll.\n# TYPE yuruna_pool_last_poll_timestamp_seconds gauge\nyuruna_pool_last_poll_timestamp_seconds %d\n", s.last.Unix())
	}

	// Per-host descriptive series that drive the dashboard's pool table.
	// host_info carries the table's label cells (name, type, framework version,
	// commit + its deep-link URLs, other deep-link URLs, current cycle, derived
	// status); the value is a constant 1. The series churns when
	// cycleStartUtc/status/IP change -- fine for an INSTANT table query (old label-sets
	// go stale immediately since only the current set is exported), but is why
	// status/cycle are NOT labels on the timeline series.
	b.WriteString("# HELP yuruna_pool_host_info Per-host descriptive labels for the pool table (value always 1).\n# TYPE yuruna_pool_host_info gauge\n")
	for _, h := range ids {
		hv := s.hosts[h]
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
		// because /metrics is unauthenticated by design.
		fmt.Fprintf(&b, "yuruna_pool_host_info{pool=%q,poolGuid=%q,hostId=%q,hostType=%q,version=%q,commit=%q,commitUrl=%q,projectCommitUrl=%q,baseUrl=%q,cycleStartUtc=%q,cycleFolderUrl=%q,status=%q,control=%q} 1\n",
			s.poolFor(h), hv.PoolGuid, h, hostType, hv.Version, commitDisplay, commitURLVal, projectCommitURL, hv.BaseURL, cycleStartUtc, cfu, hv.statusLabel(), hv.controlLabel())
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
	// stash-service VM), learned from TWO sources sharing the pool table's hostId
	// namespace: each host's registration record (activeExtensions, read through
	// that host's status service) and the service's own presence announce (POST
	// /announce, sent by the service VM itself) -- so the row survives the owning
	// host's status service being down. No ystash-nas mount / config service:
	// a host (or its service) self-reports what runs, and the aggregator already
	// polls registrations. area maps to a friendly label ("stash-service" ->
	// "Stash service") in the dashboard. One row per (hostId, area).
	//
	// target (the service UI the host advertised in extensionTargets, e.g. the stash-service VM)
	// rides as a label so the dashboard can deep-link the Extension cell DIRECTLY; baseUrl
	// (the host's status page, "" when the pool does not know the host) rides alongside it
	// but is NOT linked -- see the announce block below.
	// A Grafana table built from an instant query turns labels
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
	// so /go/host would answer "host not known to the pool". That is why the
	// dashboard leaves this table's Host ID cell as plain text and the Pool
	// hosts table (whose rows all have a status page) is where a host is
	// opened, with the control token. baseUrl stays exported as the answer to
	// "does this extension host have a status page".
	extRows := []extRow{}
	cands := s.extensionCandidatesLocked(time.Now())
	candKeys := make([]string, 0, len(cands))
	for k := range cands {
		candKeys = append(candKeys, k)
	}
	// Sorted so a scrape is byte-stable across polls holding the same facts.
	sort.Strings(candKeys)
	for _, k := range candKeys {
		c := cands[k]
		baseURL := ""
		if hv := s.hosts[c.HostId]; hv != nil {
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
			fmt.Fprintf(&b, "yuruna_pool_extension_unreachable{pool=%q,hostId=%q,area=%q,target=%q,reason=%q} 1\n", s.poolFor(e.host), e.host, e.area, e.refused, e.reason)
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
			fmt.Fprintf(&b, "yuruna_pool_host_extension{pool=%q,hostId=%q,area=%q,baseUrl=%q,target=%q} 1\n", s.poolFor(e.host), e.host, e.area, e.baseURL, e.target)
		}
		b.WriteString("# HELP yuruna_pool_host_extension_last_seen_seconds Unix time this extension host was last confirmed (host probe or service announce).\n# TYPE yuruna_pool_host_extension_last_seen_seconds gauge\n")
		for _, e := range extRows {
			fmt.Fprintf(&b, "yuruna_pool_host_extension_last_seen_seconds{pool=%q,hostId=%q,area=%q} %d\n", s.poolFor(e.host), e.host, e.area, e.lastSeen)
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
				fmt.Fprintf(&b, "yuruna_pool_extension_target_disagreement{pool=%q,hostId=%q,area=%q,target=%q,superseded=%q} 1\n", s.poolFor(e.host), e.host, e.area, e.target, e.superseded)
			}
		}
	}

	// Lab connection token: the dashboard's "Lab token" tile reads the CURRENT
	// code as a label (the info-metric pattern host_extension uses -- the only
	// channel the provisioned Prometheus/Loki datasources offer for a string).
	// Exported only while the exchange is live, so a disabled feature shows
	// "No data" rather than a stale, unredeemable code. Label churn is one tiny
	// series per rotation.
	if s.labRotate > 0 && s.authToken != "" && len(s.labCodes) > 0 {
		fmt.Fprintf(&b, "# HELP yuruna_pool_lab_token Current lab connection token for enrolling a host (value always 1).\n# TYPE yuruna_pool_lab_token gauge\nyuruna_pool_lab_token{pool=%q,token=%q} 1\n", s.pool, s.labCodes[0])
		b.WriteString("# HELP yuruna_pool_lab_token_exchanges_total Lab-token exchange attempts by outcome.\n# TYPE yuruna_pool_lab_token_exchanges_total counter\n")
		for _, oc := range []string{"ok", "refused", "throttled"} {
			fmt.Fprintf(&b, "yuruna_pool_lab_token_exchanges_total{pool=%q,outcome=%q} %d\n", s.pool, oc, s.labExchange[oc])
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
	b.WriteString("# HELP yuruna_pool_members_total Pool members currently in the view (within hostTtl).\n# TYPE yuruna_pool_members_total gauge\n")
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
	b.WriteString("# HELP yuruna_pool_degraded 1 if the healthy fraction stayed below the threshold for >= degradedAfterSeconds (advisory).\n# TYPE yuruna_pool_degraded gauge\n")
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

// handleAnnounce is the extension-presence write surface: service VMs POST
// {hostId, area, targetPort, active} beacons so the dashboard's Extension
// hosts row survives the owning host's status service being down. Open by
// design but contained (self-identity binding; goodbyes also match an
// address-less rehydrated entry). See docs/extensions-api.md (POST /announce).
func (s *poolState) handleAnnounce(w http.ResponseWriter, r *http.Request) {
	if s.announceTtl <= 0 {
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
	// The address still has to be one the pool could route to. A sender behind a
	// NAT that rewrites the source address, or a proxy header this handler ever
	// learns to trust, is how a loopback or link-local value would arrive here.
	if why := extensionTargetProblem(target); why != "" {
		http.Error(w, "invalid target address: "+why, http.StatusBadRequest)
		return
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
	// Confirm a NEWLY announced address right here rather than at the next poll:
	// a service that just came up is then resolvable immediately, which is what
	// a lab bringing up its stash and its cycles together depends on. Costs one
	// bounded probe, and only on an address this aggregator has no verdict for --
	// the steady 15-minute re-announces of a known address skip it. The address
	// is the sender's own (bound above), so this can only ever probe back at the
	// caller: an open route cannot be turned into a scan of the LAN.
	if active {
		s.confirmExtensionTarget(s.httpClient, key, target, time.Now().UTC())
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
	statusPort := flag.Int("status-port", defaultStatusPort, "status-service port to probe on each discovered IP")
	interval := flag.Duration("interval", defaultInterval, "poll/discover interval")
	rehydrateWin := flag.Duration("rehydrate-window", defaultRehydrate, "on startup, restore cycle counts from Loki over this trailing window (0 to disable)")
	incidentN := flag.Int("incident-fails", defaultIncidentN, "open an incident after this many failed cycles within -incident-window")
	incidentWin := flag.Duration("incident-window", defaultIncidentWin, "trailing window for the N-failures-in-M-minutes incident rule")
	crossN := flag.Int("cross-host-fails", defaultCrossN, "distinct hosts that must fail within -cross-host-window to open a pool-wide incident")
	crossWin := flag.Duration("cross-host-window", defaultCrossWin, "window for cross-host (pool-wide) incident correlation")
	announceTtl := flag.Duration("announce-ttl", defaultAnnounceTtl, "reap a self-announced extension (POST /announce) not refreshed within this window; 0 disables the announce route")
	hostTtl := flag.Duration("host-ttl", defaultHostTtl, "drop a host from the pool view this long after last contact; its per-cycle dedup state is kept an hour longer so a re-appearing host cannot double-count, and dashboard deep links resolve over at least 24h regardless. Cumulative pass/fail counters are not expired by this -- use POST /api/v1/forget-host")
	tlsCert := flag.String("tls-cert", "", "TLS certificate file (PEM); when both -tls-cert and -tls-key name readable files the listener is HTTPS, else plain HTTP")
	tlsKey := flag.String("tls-key", "", "TLS private-key file (PEM); see -tls-cert")
	authTokenFile := flag.String("auth-token-file", "", "file holding the shared bearer token that gates POST /ingest; empty/absent/empty-file -> /ingest disabled (never an unauthenticated write route)")
	labRotate := flag.Duration("lab-token-rotate", defaultLabRotate, "rotate the dashboard lab connection token this often; 0 disables the Lab token tile and the POST /api/v1/lab-token exchange")
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
	state.announceTtl = *announceTtl
	// A non-positive TTL would reap every host on the first tick, emptying the
	// dashboard; fall back to the default rather than start in that state.
	if *hostTtl > 0 {
		state.hostTtl = *hostTtl
	} else {
		log.Printf("host-ttl %v is not positive; keeping the default %v", *hostTtl, defaultHostTtl)
	}
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
		log.Printf("lab-token exchange disabled: no auth token configured")
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
	// /api/v1/extension-hosts: "where is area X served in this pool?" -- the
	// coordinate lookup that lets a host find the stash / pool-control service
	// knowing only the caching-proxy-service address it already has. Read-only and open,
	// the same posture as /api/v1/pool-status.
	mux.HandleFunc("/api/v1/extension-hosts", state.handleExtensionHosts)
	// /api/v1/pool-stats: per-HOST terminal-cycle counts over a preset window,
	// the numbers behind the pool-control board's cards. Per-host, not per-pool,
	// because membership lives in the intent store this service never reads --
	// the control service does the join. Read-only and open, like pool-status.
	mux.HandleFunc("/api/v1/pool-stats", state.handlePoolStats)
	// /go/cycle: dashboard timeline click -> 302 to the host's cycle-results folder,
	// resolving the host's CURRENT IP live (so the link survives an IP change). Open
	// (no auth): it only redirects to a host's already-open status service.
	mux.HandleFunc("/go/cycle", state.handleGoCycle)
	// /go/host: same uuid->current-IP resolution as /go/cycle, but 302s to the host's
	// status-page ROOT (not a cycle folder) -- the timeline's "open host status page"
	// link, so the IP-free state-timeline rows reach the per-host status page too.
	mux.HandleFunc("/go/host", state.handleGoHost)
	// /go/stash: dashboard Extension-cell click -> 302 to the host's stash-service VM UI, from
	// the URL that host advertised (extensionTargets). Open (no auth): it only redirects
	// to a host's already-open stash UI, the same posture as /go/host.
	mux.HandleFunc("/go/stash", state.handleGoStash)
	// /ingest stays registered always; it self-gates on the auth token (503 when
	// unconfigured). /metrics, /healthz, /api/v1/pool-status remain OPEN + plaintext-
	// parseable so Prometheus, the host-side pool notifier, and the hostname-free
	// dashboard keep working without credentials.
	mux.HandleFunc("/ingest", state.handleIngest)
	// /api/v1/forget-host: operator-driven manual eviction of a hostId from the view
	// (POST, bearer-gated like /ingest, 503 when no token) -- drops it from /metrics
	// + the dashboard NOW instead of after the host TTL. Called by
	// test/Remove-PoolHost.ps1.
	mux.HandleFunc("/api/v1/forget-host", state.handleForgetHost)
	// /announce: extension-presence beacon target (stash service et al). Open by
	// design with self-identity binding -- see handleAnnounce; self-gates on
	// -announce-ttl (503 when 0).
	mux.HandleFunc("/announce", state.handleAnnounce)
	// /api/v1/lab-token: exchanges the dashboard-displayed 6-char lab
	// connection token for the shared lab-auth-token (the Set-LabToken.ps1
	// enrollment call). Open with knowledge-of-the-code as the credential,
	// per-IP throttled + audited -- see handleLabToken; self-gates on
	// -lab-token-rotate and on a configured token (503 otherwise).
	mux.HandleFunc("/api/v1/lab-token", state.handleLabToken)

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
	if state.labRotate > 0 {
		authState += fmt.Sprintf(", lab-token exchange on (rotate %s)", state.labRotate)
	} else {
		authState += ", lab-token exchange off"
	}
	scheme := "http"
	if useTLS {
		scheme = "https+http"
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	log.Printf("pool-aggregator-service listening on %s (%s), pool=%q, discover-from=%s, status-port=%d, loki=%s, interval=%s, %s",
		*addr, scheme, *pool, *squidLog, *statusPort, *lokiURL, *interval, authState)
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
		serveErr = srv.Serve(newDualProtocolListener(inner, srv.TLSConfig))
	} else {
		serveErr = srv.ListenAndServe()
	}
	if serveErr != nil && serveErr != http.ErrServerClosed {
		log.Fatal(serveErr)
	}
}

// --- dual-protocol listener: TLS + plain HTTP on one port ---

// sniffTimeout bounds how long a fresh connection may sit silent before its
// first byte. Without it an idle TCP connect would pin a sniff goroutine
// forever: the http.Server's ReadTimeout only starts once the connection is
// handed over, and the hand-over is what the sniff gates.
const sniffTimeout = 10 * time.Second

// dualProtocolListener accepts on one port and hands the http.Server either a
// *tls.Conn or the raw connection, decided by the first byte (0x16 is the TLS
// handshake record type; no HTTP method starts with it). http.Server.Serve
// detects *tls.Conn, runs the handshake, and populates Request.TLS, so both
// protocols share the one mux and port. The plain path (and the TLS path via
// per-conn tls.Server, which negotiates no ALPN) speaks HTTP/1.1 only; every
// consumer of this service does.
type dualProtocolListener struct {
	inner     net.Listener
	tlsCfg    *tls.Config
	conns     chan net.Conn
	errs      chan error
	done      chan struct{}
	closeOnce sync.Once
}

func newDualProtocolListener(inner net.Listener, tlsCfg *tls.Config) *dualProtocolListener {
	l := &dualProtocolListener{
		inner:  inner,
		tlsCfg: tlsCfg,
		conns:  make(chan net.Conn),
		// Buffered so acceptLoop can park a fatal error and exit even when no
		// Accept is pending; Accept drains it later.
		errs: make(chan error, 1),
		done: make(chan struct{}),
	}
	go l.acceptLoop()
	return l
}

// acceptLoop accepts raw connections and sniffs each in its own goroutine, so
// one client that connects and then stalls before its first byte cannot block
// the accept path for everyone else.
func (l *dualProtocolListener) acceptLoop() {
	for {
		c, err := l.inner.Accept()
		if err != nil {
			select {
			case l.errs <- err:
			default: // an earlier error is already parked; drop this one
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			// Transient accept failure (e.g. EMFILE): keep accepting; the
			// parked error still surfaces through Accept so http.Server can
			// apply its own temporary-error backoff.
			continue
		}
		go l.sniff(c)
	}
}

func (l *dualProtocolListener) sniff(c net.Conn) {
	if err := c.SetReadDeadline(time.Now().Add(sniffTimeout)); err != nil {
		_ = c.Close()
		return
	}
	var first [1]byte
	if _, err := io.ReadFull(c, first[:]); err != nil {
		_ = c.Close()
		return
	}
	if err := c.SetReadDeadline(time.Time{}); err != nil {
		_ = c.Close()
		return
	}
	var out net.Conn = &replayConn{Conn: c, head: first[:]}
	if first[0] == 0x16 {
		out = tls.Server(out, l.tlsCfg)
	}
	select {
	case l.conns <- out:
	case <-l.done:
		_ = c.Close()
	}
}

func (l *dualProtocolListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case err := <-l.errs:
		return nil, err
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *dualProtocolListener) Close() error {
	var err error
	l.closeOnce.Do(func() {
		close(l.done)
		err = l.inner.Close()
	})
	return err
}

func (l *dualProtocolListener) Addr() net.Addr { return l.inner.Addr() }

// replayConn replays the sniffed first byte ahead of the wrapped connection's
// stream, so the protocol detection consumes nothing from the peer's view.
type replayConn struct {
	net.Conn
	head []byte
}

func (c *replayConn) Read(p []byte) (int, error) {
	if len(c.head) > 0 {
		n := copy(p, c.head)
		c.head = c.head[n:]
		return n, nil
	}
	return c.Conn.Read(p)
}
