// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42e70339-38e1-4075-aae1-a09826872298

// Package poll is the collector's poll: it finds the pool's hosts in the squid
// log and the pool view, probes each one, and merges what the probes return
// into the view under its lock. Network and disk work stays outside the lock,
// and the Loki lines a poll produces are sent after the lock is released.
package poll

import (
	"bufio"
	"crypto/hmac"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"sync"
	"time"

	sdkpool "yuruna.com/test/extension/extension-sdk/pool"
	"yuruna.com/test/extension/pool-aggregator-service/internal/extensions"
	"yuruna.com/test/extension/pool-aggregator-service/internal/feed"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
	"yuruna.com/test/extension/pool-aggregator-service/internal/localization"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// Names from the packages the poll reads and merges; they keep the merge code
// readable.
type (
	hostStatus    = hostpoll.HostStatus
	failRec       = incident.FailRec
	gatingPolicy  = incident.GatingPolicy
	incidentEvent = incident.Event
	controlStatus = hostpoll.ControlStatus
)

var (
	operatorMessage        = localization.OperatorMessage
	cycleTransitionPayload = feed.CycleTransitionPayload
)

const (
	probeTimeout       = hostpoll.ProbeTimeout
	controlProofTTL    = hostpoll.ControlProofTTL
	controlProofMaxTTL = hostpoll.ControlProofMaxTTL
)

const (
	defaultDiscoverWin = 35 * time.Minute // just over a 30-min DHCP lease
	maxProbe           = 8                // bounded concurrent probes per tick
	logTailBytes       = 512 * 1024       // bytes scanned from EOF for recent client IPs
	// The lab-wide address scan reads a day of log rather than a fixed tail, so
	// it is far more expensive than discovery's and must not run every poll.
	// Five minutes is well inside any useful reaction time for a pool that
	// takes hours to drain, and the answer barely moves between scans.
	AddrScanWindow   = 24 * time.Hour
	addrScanInterval = 5 * time.Minute
	AddrScanMaxBytes = 64 << 20 // 64 MiB: a day of lab squid traffic with headroom
)

// squid yuruna logformat: field 1 = %ts.%03tu (epoch.ms), field 3 = %>a (client
// IP). Capture both; the response-time field (%6tr) sits between them.
var clientIPRE = regexp.MustCompile(`^(\d+\.\d+)\s+\S+\s+(\S+)`)

// Config is what a poll reads from the collector's settings. EventCursors is
// the collector's own map, which the event tail keeps across polls.
type Config struct {
	State          *poolstate.State
	Pool           string // the collector's default pool label
	StatusPort     int
	HostTTL        time.Duration
	SeenTTL        time.Duration
	AnnounceTTL    time.Duration
	IncidentN      int
	IncidentWindow time.Duration
	CrossN         int
	CrossWindow    time.Duration
	EventCursors   map[string]*EventCursor
	ProxyTag       string // this proxy's control tag; empty when it holds no internal authentication key
	Outbox         *loki.Outbox
	Ring           Ring
}

// RingRows records one host's completed cycles into the view it is handed,
// which is locked, and reports whether anything new was recorded.
type RingRows func(view *poolstate.View) bool

// Ring is the canary ring's part in a poll, which the collector keeps:
// ReadRows reads a status body in the probe goroutine, the rows are recorded
// under the view's lock, Snapshot encodes the facts under it and Persist
// writes them after it is released.
type Ring struct {
	ReadRows func(hostID string, body []byte) RingRows
	Snapshot func(view *poolstate.View) []byte
	Persist  func(data []byte)
}

// Poller runs polls over one Config.
type Poller struct {
	feed.Sender
	st          *poolstate.State
	pool        string
	statusPort  int
	hostTtl     time.Duration
	seenTTL     time.Duration
	announceTtl time.Duration
	incidentN   int
	incidentWin time.Duration
	crossN      int
	crossWin    time.Duration
	eventCur    map[string]*EventCursor
	proxyTag    string
	ring        Ring
}

// New returns a Poller over cfg.
func New(cfg Config) *Poller {
	return &Poller{
		Sender: feed.Sender{Outbox: cfg.Outbox},
		st:     cfg.State, pool: cfg.Pool, statusPort: cfg.StatusPort, hostTtl: cfg.HostTTL, seenTTL: cfg.SeenTTL,
		announceTtl: cfg.AnnounceTTL, incidentN: cfg.IncidentN, incidentWin: cfg.IncidentWindow,
		crossN: cfg.CrossN, crossWin: cfg.CrossWindow, eventCur: cfg.EventCursors, proxyTag: cfg.ProxyTag, ring: cfg.Ring,
	}
}

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

// cycleTransition is one cycle status change captured under the lock: the seen
// key, what seen held before (known=false when nothing), the new status, and the
// Loki line that records it.
type cycleTransition struct {
	key, prev, status string
	known             bool
	payload           map[string]any
}

// presenceTarget is one host whose last-known address Poller.Once beacons to Loki
// (src=presence) this tick because it was newly discovered or changed IP. Captured
// under the view's lock (with its pool label) and pushed after the unlock, so a slow Loki
// never stalls the handlers -- the same snapshot-then-push shape as evTarget.
type presenceTarget struct{ hostID, baseURL, pool string }

// PoolFor returns the host's advertised poolId (derived by the runner from
// pools.yml members[]) when known, else the aggregator's -pool flag default. This
// is the per-host telemetry label, so each host's data accumulates under its real
// pool from first probe. view is the locked pool view.
func (s *Poller) PoolFor(view *poolstate.View, hostID string) string {
	return view.PoolLabel(hostID, s.pool)
}

// EvaluateIncidents applies the incident rules to this view's fail windows and
// open incidents, under the view's lock; the returned events are pushed to Loki
// after it is released.
func (s *Poller) EvaluateIncidents(view *poolstate.View, now time.Time) []incidentEvent {
	return view.EvaluateIncidents(incident.Rules{HostN: s.incidentN, HostWindow: s.incidentWin,
		CrossN: s.crossN, CrossWindow: s.crossWin, PoolLabel: s.pool},
		func(hostID string) string { return s.PoolFor(view, hostID) }, now)
}

// EvaluatePoolGate judges each host's own health for the pool gate and applies
// the gate, under the view's lock; the returned alert events are pushed to Loki
// after it is released.
func (s *Poller) EvaluatePoolGate(view *poolstate.View, now time.Time) []incidentEvent {
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
		members = append(members, incident.Member{HostID: hv.HostId, Pool: s.PoolFor(view, hid), Healthy: healthy})
	}
	return view.EvaluateGate(members, now)
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

// DistinctClientIPs returns the DIFFERENT addresses seen over a window, and
// reports whether the whole window was covered: false means the count is a
// floor. It counts observations only and returns the set so callers can union
// it without double-counting. See https://yuruna.link/42c29d04-0002.
func DistinctClientIPs(logPath string, window time.Duration, now time.Time, maxBytes int64) (map[string]bool, bool) {
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

// Once discovers + refreshes the pool. Candidate IPs = recent squid-log
// client IPs UNION the last-known IP of every host already in the view (so an
// idle host stays live). Each candidate is probed for /runtime/status.json;
// responders are keyed by their stable hostId. Hosts not refreshed this tick are
// marked unreachable but kept until hostTtl.
func (s *Poller) Once(client *http.Client, squidLog, lokiURL string, now time.Time) {
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
		seen, complete := DistinctClientIPs(squidLog, AddrScanWindow, now, AddrScanMaxBytes)
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
		ring       RingRows             // completed cycles the framework canary ring counts, parsed from the same body
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
	// which ClassifyControl reads as "nothing to compare".
	proxyTag := s.proxyTag
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
				pr := &probeResult{ip: ip, st: st, ring: s.ring.ReadRows(st.HostId, body)}
				// Best-effort: learn the host's pool + gating policy from its
				// registration record. A transient miss keeps the prior poolId +
				// gating (handled at apply time).
				if pid, pguid, g, ext, tgt, rerr := FetchRegistration(client, base); rerr == nil {
					pr.regOK, pr.poolID, pr.poolGuid, pr.gating, pr.activeExt, pr.extTargets = true, pid, pguid, g, ext, tgt
				}
				// Best-effort: learn the host's framework version from VERSION. A
				// transient miss leaves pr.version "" and keeps the prior value.
				if v, verr := hostpoll.FetchVersion(client, base); verr == nil {
					pr.version = v
				}
				// Best-effort: can this host be driven from the dashboard? A transport
				// failure leaves pr.control "" and keeps the prior verdict; a host that
				// answers, even an older build with no such route, replaces it. Classified
				// here against the poll's clock so the skew reading excludes the poll's own
				// duration. The refresh capability rides the same answer but is demoted, not
				// kept, on a failed or oversize read.
				// See https://yuruna.link/42c29d04-000e.
				if cs, cerr := hostpoll.FetchControlStatus(client, base); cerr == nil {
					pr.control = ClassifyControl(proxyTag, cs, now)
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
	// re-seed its volatile view from Loki on a restart (rehydrate's Reader.Presence).
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
			hv := view.EnsureHost(hid)
			if hv == nil {
				continue // a retired identity: it never regains a live row after handover
			}
			base := fmt.Sprintf("http://%s:%d", r.ip, s.statusPort)
			prevBase := hv.BaseURL
			hv.CurrentIP, hv.BaseURL, hv.Reachable, hv.LastError = r.ip, base, true, ""
			// New host (prevBase "") or an IP change -> re-beacon its address. A
			// re-probe of a Loki-seeded stub at the SAME IP leaves base == prevBase, so
			// it does NOT churn a presence line every restart. Streamed under s.pool (the
			// aggregator's -pool default) so rehydrate's Reader.Presence, which queries
			// that same pool label, finds it on restart; pushed after the unlock.
			if base != prevBase {
				presence = append(presence, presenceTarget{hostID: hid, baseURL: base, pool: s.pool})
			}
			hv.LastSeenUnixMs = now.UnixMilli()
			hv.Status = r.st
			if r.ring(view) {
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
					view.SetGating(r.poolID, *r.gating)
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
						payload: cycleTransitionPayload(s.PoolFor(view, hid), cycleStatus, base, now),
					})
				}
				passed := cycleStatus.OverallStatus == "pass"
				if hostpoll.IsTerminal(cycleStatus.OverallStatus) && view.CountTerminal(key, hid, passed) && !passed {
					// status.json carries lastFailure (failureClass) in the same doc that
					// flipped overallStatus to "fail" (Complete-Run flushes both), so the
					// class is available at count time; "unknown" when unclassified.
					view.RecordFail(hid, failRec{At: now, Class: cycleStatus.FailClassOf()})
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
					view.DropHost(hid)
					deleted = append(deleted, hid)
				}
			}
		}
		view.ReapCycles(now, s.seenTTL)
		// Reap self-announced extensions whose beacon stopped refreshing (the
		// service died without a goodbye).
		if s.announceTtl > 0 {
			view.ReapAnnounces(now, s.announceTtl)
		}
		for hid, hv := range view.Hosts {
			if hv.Reachable && hv.Status != nil && hv.Status.CycleStartUtc != "" && hv.Status.CycleFolderUrl != "" {
				// Capture the pool label here under the lock; TailEvents runs unlocked.
				targets = append(targets, evTarget{hid, hv.BaseURL, hv.Status.CycleStartUtc, hv.Status.CycleFolderUrl, s.PoolFor(view, hid)})
			}
		}
		// Incident correlation: prune fail windows and open/resolve per-host
		// incidents; the Loki open/resolve events are pushed after the unlock.
		incEvents = s.EvaluateIncidents(view, now)
		// Pool gating: compute each pool's advisory degraded/alert latch (read-side;
		// drives alerting + dashboard de-noise, never a cycle). Runs AFTER incidents so
		// "healthy" can exclude a host currently in an open incident.
		gateEvents = s.EvaluatePoolGate(view, now)
		if ringChanged {
			ringSnapshot = s.ring.Snapshot(view)
		}
		view.MarkPolled(now)
	})
	s.ring.Persist(ringSnapshot)

	// seen records a transition as delivered. One that could not be queued is
	// put back as unseen, so the next poll builds and sends it again instead of
	// losing it.
	for _, tr := range cycleTransitions {
		if err := s.Queue(client, lokiURL, tr.payload, "loki push"); err != nil {
			s.st.Do(func(view *poolstate.View) { view.RevertCycle(tr.key, tr.status, tr.prev, tr.known) })
		}
	}

	// Confirm every advertised extension address from the POOL's vantage point,
	// and drop the ones that have stayed silent past the grace. Runs after the
	// unlock and takes the lock itself: each probe costs up to probeTimeout
	// against an address that may be black-holed, which is exactly the case this
	// exists to catch, and the handlers must stay answerable meanwhile.
	extensions.Refresh(s.st, client, s.announceTtl, now)

	// Tail each reachable host's current-cycle NDJSON events into Loki.
	// eventCur is only touched here (single poll goroutine), so no lock needed.
	for _, hid := range deleted {
		delete(s.eventCur, hid)
	}
	for _, ev := range incEvents {
		s.PushIncident(client, lokiURL, ev.PoolLabel, ev)
	}
	for _, ev := range gateEvents {
		s.PushIncident(client, lokiURL, ev.PoolLabel, ev)
	}
	// Beacon each newly-discovered / IP-changed host's address to Loki so a restart
	// can re-seed the volatile view (rehydrate's Reader.Presence). On-change only,
	// so this is a low-volume feed -- a steady pool pushes nothing here per poll.
	for _, p := range presence {
		s.PushPresence(client, lokiURL, p.pool, p.hostID, p.baseURL, now)
	}
	for _, t := range targets {
		s.TailEvents(client, lokiURL, t.poolLabel, t.hostID, t.baseURL, t.cycleID, t.cycleFolderURL, now)
	}
}

// WithFreshConnections runs one poll on connections of its own and closes
// them when it ends.
func (s *Poller) WithFreshConnections(squidLog, lokiURL string, now time.Time) {
	client := hostpoll.NewPollHTTPClient(probeTimeout)
	defer client.CloseIdleConnections()
	s.Once(client, squidLog, lokiURL, now)
}

// FetchRegistration reads a host's poolId, poolGuid, optional gating policy,
// active extension areas and per-area extension targets from
// /runtime/host.registration.json. Any failure returns zero values and the
// error; poolId "" is a successful read of an unpooled host. Gating is nil when
// the pool authored none, and a partial block is completed with the schema
// defaults.
// See https://yuruna.link/42c29d04-0017.
func FetchRegistration(client *http.Client, base string) (string, string, *gatingPolicy, []string, map[string]string, error) {
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

// ClassifyControl decides one host's control state from its control-status
// answer. The skew band is not a guess: routes.HandleGoHost mints at controlProofTTL
// and Test-YurunaControlProof accepts up to controlProofMaxTTL, so a host clock
// reading H against proxy time P is accepted exactly while
// H-P is within [-(MaxTTL-TTL), +TTL] -- it may run ahead by the full mint, but
// may trail by only the surplus the verifier holds above it.
func ClassifyControl(proxyTag string, cs controlStatus, now time.Time) string {
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
