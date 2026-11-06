// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4276aec9-7e91-423e-b944-ed9d9f5e92ee

// Package rehydrate restores the collector's volatile pool view from Loki at
// startup: the cycle counters and fail windows, the open incidents and alert
// latches, the hosts' last-known addresses and the live self-announces. Each
// reader is best-effort; on a Loki error the view rebuilds from live traffic.
package rehydrate

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/extensions"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
	"yuruna.com/test/extension/pool-aggregator-service/internal/localization"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// Names from the packages the readers query and restore into; they keep the
// restore code readable.
type (
	failRec           = incident.FailRec
	lokiStream        = loki.Stream
	lokiStreamsResult = loki.Streams
)

var (
	newInternalHTTPClient = hostpoll.NewInternalHTTPClient
	hostIPFromBaseURL     = hostpoll.HostIPFromBaseURL
	queryRangeURL         = loki.QueryRangeURL
	operatorMessage       = localization.OperatorMessage
	announceKey           = poolstate.AnnounceKey
	announceHostIDRE      = extensions.AnnounceHostIDRE
	announceAreaRE        = extensions.AnnounceAreaRE
)

const (
	pushTimeout = loki.RequestTimeout
	maxAnnounce = extensions.MaxAnnounce
)

// Config is the view a restore writes into and the windows it is bounded by.
type Config struct {
	State          *poolstate.State
	IncidentWindow time.Duration // a restored fail joins the fail window only inside this
	AnnounceTTL    time.Duration // an announce older than this is not restored (0 restores none)
}

// Reader restores one pool view from Loki.
type Reader struct {
	st          *poolstate.State
	incidentWin time.Duration
	announceTtl time.Duration
}

// New returns a Reader over cfg.
func New(cfg Config) *Reader {
	return &Reader{st: cfg.State, incidentWin: cfg.IncidentWindow, announceTtl: cfg.AnnounceTTL}
}

// SeedHostStub seeds the locked view with an unreachable stub for a host
// whose last-known address was recovered from Loki, so the first poll probes it
// (the candidate set is the squid-log addresses plus every in-view host's). A
// malformed recorded baseUrl seeds nothing. See https://yuruna.link/42c29d04-0013.
func SeedHostStub(view *poolstate.View, hostID, baseURL string, now time.Time) bool {
	return view.SeedHostStub(hostID, hostIPFromBaseURL(baseURL), baseURL, now)
}

// Cycles seeds the cycle counters and their seen and counted dedup sets, the fail
// windows and the hosts' last-known addresses from Loki's terminal transition
// lines at startup, so a restart resumes its pass/fail counts instead of
// resetting them. Best-effort: on any Loki error the collector starts with empty
// counts and rebuilds as cycles complete.
// See https://yuruna.link/42c29d04-001a.
func (s *Reader) Cycles(lokiPushURL, pool string, window time.Duration, now time.Time) {
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
							view.RecordFail(view.CanonicalHostID(e.HostId), failRec{At: evTime, Class: cls})
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
			if SeedHostStub(view, hid, base, now) {
				seeded++
			}
		}
		// Open incidents are NOT reconstructed here -- they are restored from the
		// authoritative incident feed (Incidents) so their original
		// id + startedAt survive, including incidents currently below the open
		// threshold whose hysteresis state the fail window alone can't recover.
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

// Incidents restores OPEN incidents from the authoritative
// incident lifecycle feed ({pool,src=incident}) on startup, so a restart keeps
// each incident's ORIGINAL id + startedAt -- the eventual incident_resolved then
// pairs with its open line and reports the true duration. An incident is
// restored whenever the LATEST lifecycle line for a host is incident_open
// (regardless of the current fail count, so a sub-threshold-but-still-open
// incident survives the restart). Best-effort: any Loki error leaves incidents
// empty and they simply re-open on the next qualifying fail burst.
func (s *Reader) Incidents(lokiPushURL, pool string, window time.Duration, now time.Time) {
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
	if n := s.ApplyIncidentLines(streams, now); n > 0 {
		log.Print(operatorMessage("aggregator.log_rehydrate_restored_value1_open_incident_s_from_loki_9bcd828c", map[string]any{"value1": fmt.Sprintf("%d", n)}))
	}
	s.ApplyPoolAlertLines(lr.Data.Result)
}

// ApplyPoolAlertLines restores the pool alert latches that were firing when the
// collector stopped, from the kind=alert lines of the same incident feed. Without
// it a restart forgets a firing alert: a pool still degraded fires a second alert
// under a new id -- paging again -- and the first one's lifecycle never closes.
// The latest line per pool label decides: a pool_alert_fired restores the latch
// with its original id and start, so the eventual rearm pairs with it. Takes the view's lock.
func (s *Reader) ApplyPoolAlertLines(streams []lokiStream) int {
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
			view.RestoreAlert(pool, l.id, started)
			restored++
		}
	})
	return restored
}

// ApplyIncidentLines restores open incidents (per-host and pool-wide) from the
// incident-feed streams, each one Loki stream's [ts,line] values. The most recent
// line per host, and the most recent pool-scoped line, decides current state,
// judged across streams by timestamp rather than stream order. Separate from the
// fetch in Incidents so it is testable without Loki. Takes the view's lock.
// See https://yuruna.link/42c29d04-001a.
func (s *Reader) ApplyIncidentLines(streams [][][2]string, now time.Time) int {
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
					view.RestorePoolIncident(id, started, e.AffectedHostCount, e.Class)
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
			view.RestoreIncident(e.HostId, id, started, e.FailCount, e.ClassHistogram, e.DominantClass)
			restored++
		}
	})
	return restored
}

// Presence re-seeds the collector's VOLATILE in-memory host
// view from the {src=presence} beacon feed on startup, so a host discovered before
// a restart is re-probed at its last-known IP even when it is generating no fresh
// proxy traffic (a paused runner, or a stash-only host that runs no test cycles and
// so emits no {src=cycle} transition for Cycles to seed from). Without
// this a restart drops such a host from the dashboard until it next pulls through
// the proxy -- the discovery-liveness gap. Best-effort: any Loki error leaves the
// view to rebuild from the squid log.
func (s *Reader) Presence(lokiPushURL, pool string, window time.Duration, now time.Time) {
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
	if n := s.ApplyPresenceLines(streams, now); n > 0 {
		log.Print(operatorMessage("aggregator.log_rehydrate_re_seeded_value1_host_s_from_the_presence_fe_b6c9e59f", map[string]any{"value1": fmt.Sprintf("%d", n)}))
	}
}

// ApplyPresenceLines seeds unreachable host stubs from the presence-beacon streams
// -- each element is one Loki stream's [ts,line] values, newest-first. A host has a
// single presence stream, so the FIRST line seen per hostId is its newest address.
// Split from the HTTP fetch (like ApplyIncidentLines) so it is unit-testable without
// a live Loki. Takes the view's lock.
func (s *Reader) ApplyPresenceLines(streams [][][2]string, now time.Time) int {
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
				if SeedHostStub(view, e.HostId, e.BaseUrl, now) {
					seeded++
				}
			}
		}
	})
	return seeded
}

// Announces restores self-announced extensions from the
// {src=announce} feed on startup, so a collector restart keeps the Extension
// hosts rows of services whose beacons are alive -- WITHOUT waiting up to one
// beacon period for the next hello. The query window is announceTtl, not the
// full rehydrate window: any line older than the TTL is stale by definition.
// Best-effort: on any Loki error the entries rebuild from live beacons.
func (s *Reader) Announces(lokiPushURL, pool string, now time.Time) {
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
	if n := s.ApplyAnnounceLines(streams, now); n > 0 {
		log.Print(operatorMessage("aggregator.log_rehydrate_restored_value1_self_announced_extension_s_f_e79d2b5f", map[string]any{"value1": fmt.Sprintf("%d", n)}))
	}
}

// ApplyAnnounceLines restores announce entries from {src=announce} streams --
// each element one Loki stream's [ts,line] values, newest-first. The newest
// line per (hostId, area) decides: active restores the entry with the LINE's
// timestamp as its freshness (so the TTL reap stays truthful), a goodbye
// leaves it absent. Values are re-validated with the same gates as a live
// announce -- Loki retention is not a trust boundary. Split from the HTTP
// fetch so it is unit-testable without a live Loki. Takes the view's lock.
func (s *Reader) ApplyAnnounceLines(streams [][][2]string, now time.Time) int {
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
				if !e.Active {
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
				if view.RestoreAnnounce(e.HostId, e.Area, target, ts, maxAnnounce) {
					restored++
				}
			}
		}
	})
	return restored
}
