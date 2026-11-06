// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42f7f1f9-ddfe-4379-ad29-81a71a302ede

// Package routes answers the aggregator's HTTP routes from the pool view: the
// read surfaces (pool status, extension hosts, statistics, incidents, health,
// metrics and the dashboard deep links) and the write surfaces (ingest, the
// announces, forget-host and the lab-token exchange). A handler reads the view
// under its lock and writes the answer after the lock is released.
package routes

import (
	"crypto/subtle"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	sdkpool "yuruna.com/test/extension/extension-sdk/pool"
	"yuruna.com/test/extension/pool-aggregator-service/internal/extensions"
	"yuruna.com/test/extension/pool-aggregator-service/internal/feed"
	"yuruna.com/test/extension/pool-aggregator-service/internal/httpserve"
	"yuruna.com/test/extension/pool-aggregator-service/internal/localization"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/metrics"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// Names from the packages the handlers read and answer through; they keep the
// handlers readable.
type (
	hostView           = poolstate.HostView
	announceView       = poolstate.AnnounceView
	extensionHostEntry = extensions.Entry
)

var (
	localizedHTTPError     = localization.HTTPError
	localizedHTTPErrorArgs = localization.HTTPErrorArgs
	localizedJSONError     = localization.JSONError
	operatorMessage        = localization.OperatorMessage
	announceKey            = poolstate.AnnounceKey
	extensionTargetProblem = extensions.TargetProblem
)

const (
	// StashArea is the extension area of the stash service -- the default for
	// /go/stash and the area whose target rides as pool-status stashBaseUrl.
	StashArea = "stash-service"
	// PoolControlServiceArea is the extension area of the pool-control service. Named
	// alongside StashArea because both are answered by /api/v1/extension-hosts,
	// the coordinate lookup a host uses to find a service it does not run
	// itself.
	PoolControlServiceArea = "pool-control-service"
	// Host types that run the Windows exporter. Every other type is simply absent from
	// the scrape document: listing a host nothing answers on would mark a target
	// down for as long as the host exists.
	windowsHostTypePrefix = "host.windows."
)

// Config is what the routes read from the collector's settings, plus the
// collector's own hooks: the history backfill's cycle index and listing parser,
// and the pool-stats cache that the identity handover invalidates.
type Config struct {
	State            *poolstate.State
	Pool             string
	AuthToken        string // the internal authentication key; empty disables every route it gates
	LokiURL          string
	HTTPClient       *http.Client
	LabRotate        time.Duration
	Outbox           *loki.Outbox
	RefreshTTL       time.Duration
	AnnounceTTL      time.Duration
	IncidentN        int
	IncidentWindow   time.Duration
	CrossWindow      time.Duration
	ArchiveRoot      string
	HostMetricsPort  int
	DeepLinkLookback time.Duration
	FolderByIndex    func(hostID string, t time.Time) string
	ParseListing     func(body string) (leaves, buckets []string)
	CachedPoolStats  func(window string) (epoch uint64, payload []byte, hit bool)
	CachePoolStats   func(window string, epoch uint64, payload []byte)
}

// Server answers the routes for one Config.
type Server struct {
	feed.Sender
	st                   *poolstate.State
	pool                 string
	authToken            string
	lokiURL              string
	httpClient           *http.Client
	labRotate            time.Duration
	outbox               *loki.Outbox
	refreshTTL           time.Duration
	announceTtl          time.Duration
	incidentN            int
	incidentWin          time.Duration
	crossWin             time.Duration
	archiveRoot          string
	hostMetricsPort      int
	deepLinkLookback     time.Duration
	resolveFolderByIndex func(hostID string, t time.Time) string
	parseListing         func(body string) (leaves, buckets []string)
	cachedPoolStats      func(window string) (epoch uint64, payload []byte, hit bool)
	cachePoolStats       func(window string, epoch uint64, payload []byte)
}

// New returns a Server over cfg.
func New(cfg Config) *Server {
	return &Server{
		Sender: feed.Sender{Outbox: cfg.Outbox},
		st:     cfg.State, pool: cfg.Pool, authToken: cfg.AuthToken, lokiURL: cfg.LokiURL, httpClient: cfg.HTTPClient,
		labRotate: cfg.LabRotate, outbox: cfg.Outbox, refreshTTL: cfg.RefreshTTL, announceTtl: cfg.AnnounceTTL,
		incidentN: cfg.IncidentN, incidentWin: cfg.IncidentWindow, crossWin: cfg.CrossWindow,
		archiveRoot: cfg.ArchiveRoot, hostMetricsPort: cfg.HostMetricsPort, deepLinkLookback: cfg.DeepLinkLookback,
		resolveFolderByIndex: cfg.FolderByIndex, parseListing: cfg.ParseListing,
		cachedPoolStats: cfg.CachedPoolStats, cachePoolStats: cfg.CachePoolStats,
	}
}

// poolFor returns the host's advertised poolId when known, else the
// collector's default pool. view is the locked pool view.
func (s *Server) poolFor(view *poolstate.View, hostID string) string {
	return view.PoolLabel(hostID, s.pool)
}

// poolStatusEntry is one host in the /api/v1/pool-status snapshot: the
// hostView plus stashBaseUrl, the resolved stash-UI base the stash UI's
// hostId->URL lookup reads. Resolved at serialization time through
// extensions.Candidates -- the same merge the dashboard cell and /go/stash
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

func (s *Server) HandleHealth(w http.ResponseWriter, _ *http.Request) {
	_, _ = io.WriteString(w, "ok\n")
}

func (s *Server) HandlePoolStatus(w http.ResponseWriter, r *http.Request) {
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
		cands := extensions.Candidates(view, s.announceTtl, now)
		for _, id := range ids {
			if view.ReplacedBy(id) != "" {
				continue
			}
			hv := view.Hosts[id]
			// stashBaseUrl: the stash UI's hostId->URL lookup key, resolved through
			// the same merge the dashboard cell and /go/stash use so the three
			// cannot disagree.
			stash := cands[announceKey(id, StashArea)].Target
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

// PromTargetGroup is one entry of the Prometheus scrape document: the addresses
// to scrape, plus the labels every series read from them carries.
type PromTargetGroup struct {
	Targets []string          `json:"targets"`
	Labels  map[string]string `json:"labels"`
}

// HandlePrometheusTargets serves the pool's reachable supported hosts as a
// Prometheus HTTP service-discovery document, labeled like the pool exposition
// so machine series join pool series on hostId. Open, like
// /api/v1/pool-status. See https://yuruna.link/42c29d04-0009.
func (s *Server) HandlePrometheusTargets(w http.ResponseWriter, r *http.Request) {
	var groups []PromTargetGroup
	s.st.Do(func(view *poolstate.View) {
		ids := make([]string, 0, len(view.Hosts))
		for id := range view.Hosts {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		// Every value is copied out under the lock: the poll goroutine mutates the
		// hostView/hostStatus these read, so nothing may hold a pointer past Unlock.
		groups = make([]PromTargetGroup, 0, len(ids))
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
			groups = append(groups, PromTargetGroup{
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

// HandleExtensionHosts answers "where is area X served in this pool?". With
// ?area=<slug> it returns that one area, or 404 when the pool knows no live host
// for it; without ?area it returns every area and the services list.
// Unauthenticated and read-only, like /api/v1/pool-status: it discloses service
// addresses to a caller already on the LAN they listen on.
// See https://yuruna.link/42c29d04-0006.
func (s *Server) HandleExtensionHosts(w http.ResponseWriter, r *http.Request) {
	area := strings.TrimSpace(r.URL.Query().Get("area"))
	now := time.Now()
	pool := s.pool
	var entries, cands map[string]extensionHostEntry
	s.st.Do(func(view *poolstate.View) {
		entries = extensions.ResolveHosts(view, s.announceTtl, now)
		cands = extensions.Candidates(view, s.announceTtl, now)
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

// ValidForgetHostID mirrors the runner-side 42-prefixed 32-hex host.uuid shape
// (test/pool/Remove-PoolHost.ps1, Remove-HostFromPool.ps1) so the forget endpoint
// rejects a typo instead of scanning the maps for a key that cannot exist.
func ValidForgetHostID(id string) bool {
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

// ForgetHost removes every trace of one hostId from the view, so a forgotten
// host stops appearing on the very next /metrics scrape, and returns whether
// the host was present. eventCur is left alone: it is owned by the single poll
// goroutine, and a leftover cursor only ever resumes event tailing if the same
// hostId re-appears. Callers hold no lock; this takes the view's lock itself.
func (s *Server) ForgetHost(hid string) bool {
	present := false
	s.st.Do(func(view *poolstate.View) { present = view.ForgetHost(hid) })
	return present
}

// HandleForgetHost (POST /api/v1/forget-host?hostId=<42-hex>) manually evicts a
// host from the aggregator's view NOW, instead of waiting out the host TTL --
// e.g. a disposable nested-host cycle or a decommissioned box whose row lingers as
// "unreachable". Bearer-gated with the SAME token as /ingest (a mutating control
// op) and self-disabling (503) when no token is configured. NOTE: a host that is
// still reachable (recent squid traffic, or a live announce inside its window) is
// re-discovered on the next poll, so stop/drain it first -- forget is for a host
// that is genuinely gone.
func (s *Server) HandleForgetHost(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.forget_host_disabled_no_auth_token_configured", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.RequireInternalBearer(w, r) {
		return
	}
	hid := strings.TrimSpace(r.URL.Query().Get("hostId"))
	if !ValidForgetHostID(hid) {
		localizedHTTPError(w, r, "aggregator.hostid_must_be_a_42_prefixed_32_hex_id", http.StatusBadRequest)
		return
	}
	present := s.ForgetHost(hid)
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

// RequireInternalBearer checks the internal token and localizes a refusal.
func (s *Server) RequireInternalBearer(w http.ResponseWriter, r *http.Request) bool {
	const prefix = "Bearer "
	auth := r.Header.Get("Authorization")
	if s.authToken == "" || !strings.HasPrefix(auth, prefix) || subtle.ConstantTimeCompare([]byte(auth[len(prefix):]), []byte(s.authToken)) != 1 {
		localizedHTTPError(w, r, "aggregator.unauthorized", http.StatusUnauthorized)
		return false
	}
	return true
}

// HandleMetrics serves the Prometheus exposition to this machine only: it
// carries the current lab connection token in plain text, and Prometheus scrapes
// it over loopback. A remote caller is refused with 403 rather than served a
// redacted body.
// See https://yuruna.link/42c29d04-001f.
func (s *Server) HandleMetrics(w http.ResponseWriter, r *http.Request) {
	if !httpserve.IsLoopbackSource(r) {
		localizedHTTPError(w, r, "aggregator.metrics_are_served_to_this_host_only", http.StatusForbidden)
		return
	}
	s.MetricsBody(w)
}

func (s *Server) MetricsBody(w http.ResponseWriter) {
	s.MetricsWithArchiveProbe(w, func(path string) bool {
		root, err := os.OpenRoot(path)
		if err != nil {
			return false
		}
		_ = root.Close()
		return true
	})
}

func (s *Server) MetricsWithArchiveProbe(w http.ResponseWriter, readable func(string) bool) {
	// The share may stall during reconnect. Probe the fixed startup path before
	// locking live state so discovery and control remain usable during outages.
	in := metrics.Inputs{
		Pool: s.pool, Now: time.Now(), RefreshTTL: s.refreshTTL, CrossWindow: s.crossWin,
		ArchiveConfigured: s.archiveRoot != "",
		LabTokenLive:      s.labRotate > 0 && s.authToken != "",
	}
	in.ArchiveAvailable = in.ArchiveConfigured && readable(s.archiveRoot)
	if s.outbox != nil {
		in.Outbox = &metrics.OutboxState{Pending: s.outbox.Pending(), Durable: s.outbox.Durable()}
	}
	var out string
	s.st.Do(func(view *poolstate.View) {
		in.Extensions = extensionRows(extensions.Candidates(view, s.announceTtl, in.Now))
		// Materialize the metrics text and release the lock before writing to the client, so a slow
		// scraper connection cannot hold the view's lock across the network write and stall the
		// poll goroutine (mirrors HandlePoolStatus).
		out = metrics.Render(view, in)
	})
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = io.WriteString(w, out)
}

// extensionRows is the exposition's reading of the extension merge, sorted by
// (hostId, area) so a scrape is byte-stable across polls holding the same facts.
func extensionRows(cands map[string]extensionHostEntry) []metrics.ExtensionRow {
	keys := make([]string, 0, len(cands))
	for k := range cands {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	rows := make([]metrics.ExtensionRow, 0, len(keys))
	for _, k := range keys {
		c := cands[k]
		rows = append(rows, metrics.ExtensionRow{
			HostID: c.HostId, Area: c.Area, Target: c.Target, LastSeenUnixMs: c.LastSeenUnixMs,
			SupersededTarget: c.SupersededTarget,
			Suppressed:       c.Suppressed, SuppressedTarget: c.SuppressedTarget, SuppressReason: c.SuppressReason,
		})
	}
	return rows
}

// --- REGION: Incident and health as JSON
// The incident and pool-health views as JSON, for a caller that cannot read a
// panel: routes rather than tools reading state, so the tool and the metric are
// one body produced once. Read-only and ungated, like /api/v1/pool-status.
// See https://yuruna.link/42c29d04-0020.

// HandlePoolIncidents answers which hosts are currently in an incident, what
// class of failure opened it, and whether a pool-wide incident is running.
func (s *Server) HandlePoolIncidents(w http.ResponseWriter, _ *http.Request) {
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

// HandlePoolHealth answers the pool health gate: what fraction of members are
// healthy, the threshold that fraction is judged against, and whether the
// advisory degraded/alert latch has fired.
func (s *Server) HandlePoolHealth(w http.ResponseWriter, _ *http.Request) {
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
