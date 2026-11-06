// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 424a1887-3370-4e5c-bc2b-056db32ad039

// Package extensions resolves where each extension area is served in the pool:
// the one merge of the hosts' registrations and the services' own announces,
// and this aggregator's verdict on every address either source names. The
// poll, the routes and the metrics all read the same merge.
package extensions

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/localization"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// Names from the packages the merge reads; they keep the merge code readable.
type extHealthView = poolstate.ExtHealthView

var (
	announceKey       = poolstate.AnnounceKey
	hostIPFromBaseURL = hostpoll.HostIPFromBaseURL
	operatorMessage   = localization.OperatorMessage
)

const probeTimeout = hostpoll.ProbeTimeout

const (
	MaxAnnounce = 512 // distinct (hostId,area) announce entries kept in memory
	// --- REGION: https://yuruna.link/42fffc2c-0016
	// A confirmed address that goes quiet is kept for HealthGrace, then refused for
	// resolution whichever source named it; the entry survives, suppressed, so the
	// refused address stays visible. A beacon period must stay shorter than this
	// grace. Code-only knobs by design, with no per-pool override.
	// See https://yuruna.link/42c29d04-0010.
	HealthPath  = "/healthz"
	HealthGrace = 5 * time.Minute
	MaxProbe    = 8 // bounded concurrent health probes per poll
)

// AnnounceHostIDRE / AnnounceAreaRE gate what an unauthenticated announce may
// inject into metric labels and Loki lines: an opaque host identifier
// (existing hostIds are 32 hex chars; dashes tolerate GUID formatting) and a
// lowercase extension-area slug.
var (
	AnnounceHostIDRE = regexp.MustCompile(`^[A-Za-z0-9-]{8,64}$`)
	AnnounceAreaRE   = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
)

// The two ways an area's address reaches the aggregator, as they appear in
// Entry.Source and in /api/v1/extension-hosts.
const (
	SourceRegistration = "registration"
	SourceAnnounce     = "announce"
)

// Entry is one resolved extension service in the
// /api/v1/extension-hosts answer: where the pool currently believes an area is
// served, and on whose word. Host is the bare address a consumer builds its own
// URLs from ("192.168.7.227"); Target is the advertised base URL verbatim.
type Entry struct {
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
	// it has stopped reaching for longer than HealthGrace. Target and
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
	// Confirmed marks an announce this aggregator received itself, whose target
	// was derived from the sender's own source address. False for a
	// registration (a value the owning host computed and wrote to a file we
	// read) and for an announce rehydrated out of Loki (history, not a live
	// sender). Ranking, not serialization -- it is a property of how we learned
	// the address, not of the service.
	Confirmed bool `json:"-"`
}

// advertised is the address this entry's source named, suppressed or not: what
// to probe, and what to report as refused.
func (e Entry) advertised() string {
	if e.Suppressed {
		return e.SuppressedTarget
	}
	return e.Target
}

// TargetProblem reports why an advertised extension address can never be a pool
// service address, or "" when it is at least plausible: anything that is not an
// http(s) URL, and any address no other machine could route to. It is the cheap
// half of the check; the reachability probe is the other half, and the only
// judge of a name.
// See https://yuruna.link/42c29d04-0010.
func TargetProblem(target string) string {
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

// Probe confirms an advertised address answers as a service: GET
// <target>/healthz, 200. The same gate the host-side pre-flight
// (Test-StashServiceHost) and the guest workloads apply, asked from the POOL's
// vantage point -- which is the whole point, since a host confirming its own VM
// proves only that the host can reach it.
func Probe(client *http.Client, target string) error {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(target, "/")+HealthPath, nil)
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
		return fmt.Errorf("%s answered HTTP %d", HealthPath, resp.StatusCode)
	}
	return nil
}

// Confirm probes one address and records the verdict, unless the
// pool already has a verdict for that exact address. Called from the announce
// handler so a service that just came up is resolvable immediately instead of
// after the next poll -- and, for the same reason, is NOT re-run on the steady
// re-announces of an address already confirmed. Takes the view's lock itself;
// the probe runs unlocked.
func Confirm(st *poolstate.State, client *http.Client, key, target string, now time.Time) {
	if client == nil || target == "" || TargetProblem(target) != "" {
		return
	}
	known := false
	st.Do(func(view *poolstate.View) {
		h := view.ExtHealth[key]
		known = h != nil && h.Target == target
	})
	if known {
		return
	}
	err := Probe(client, target)
	st.Do(func(view *poolstate.View) { view.RecordExtensionProbe(key, target, err, now) })
}

// Refresh re-confirms every advertised extension address and refuses the ones
// silent past HealthGrace. Runs once per poll: the address list is snapshotted
// under the lock, the probes run unlocked and concurrently (a black-holed
// address costs probeTimeout each), and the verdicts are applied under the lock
// again. Neither source is removed here: suppression stops an unreachable
// address being handed out.
// See https://yuruna.link/42c29d04-0010.
func Refresh(st *poolstate.State, client *http.Client, announceTTL time.Duration, now time.Time) {
	if client == nil {
		return
	}
	type probeTarget struct {
		key, target string
		health      *extHealthView
	}
	var targets []probeTarget
	st.Do(func(view *poolstate.View) {
		live := map[string]bool{}
		for key, cand := range Candidates(view, announceTTL, now) {
			live[key] = true
			raw := cand.advertised()
			if raw == "" || TargetProblem(raw) != "" {
				continue
			}
			targets = append(targets, probeTarget{key: key, target: raw, health: view.ExtHealth[key]})
		}
		view.PruneExtensionVerdicts(live)
	})

	errs := make([]error, len(targets))
	sem := make(chan struct{}, MaxProbe)
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func(i int, t probeTarget) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			errs[i] = Probe(client, t.target)
		}(i, t)
	}
	wg.Wait()

	st.Do(func(view *poolstate.View) {
		for i, t := range targets {
			// An announce may confirm a new address while this old probe is out.
			if h := view.ExtHealth[t.key]; h != nil && h != t.health && h.Target != t.target && h.Confirmed {
				continue
			}
			view.RecordExtensionProbe(t.key, t.target, errs[i], now)
		}
		for key, h := range view.ExtHealth {
			if h.FirstFailUnixMs == 0 || now.UnixMilli()-h.FirstFailUnixMs <= HealthGrace.Milliseconds() {
				continue
			}
			if h.RefusedLogged {
				continue
			}
			h.RefusedLogged = true
			log.Print(operatorMessage("aggregator.log_extension_value1_refusing_value2_for_resolution_unansw_14b41da9", map[string]any{"value1": fmt.Sprintf("%s", key), "value2": fmt.Sprintf("%s", h.Target), "value3": fmt.Sprintf("%s", HealthGrace), "value4": fmt.Sprintf("%s", h.LastError)}))
		}
	})
}

// SourceRank orders the ways an area's address reaches the
// aggregator by the strength of the evidence behind it: 0 a live announce, 1 a
// registration, 2 a rehydrated announce. See https://yuruna.link/42c29d04-0006.
func SourceRank(e Entry) int {
	switch {
	case e.Source == SourceAnnounce && e.Confirmed:
		return 0
	case e.Source == SourceRegistration:
		return 1
	default:
		return 2
	}
}

// Better reports whether a should replace b as an area's
// answer: usable (reached, and carrying an address) first, then source rank,
// recency and hostId, so the choice is deterministic. See https://yuruna.link/42c29d04-0006.
func Better(a, b Entry) bool {
	if a.Suppressed != b.Suppressed {
		return !a.Suppressed
	}
	// Only ever compares two UNSUPPRESSED candidates: a suppressed one already
	// lost above, and two suppressed ones both carry a blank Target (suppression
	// moves it to SuppressedTarget), so this is a no-op for them.
	if (a.Target == "") != (b.Target == "") {
		return a.Target != ""
	}
	if ra, rb := SourceRank(a), SourceRank(b); ra != rb {
		return ra < rb
	}
	if a.LastSeenUnixMs != b.LastSeenUnixMs {
		return a.LastSeenUnixMs > b.LastSeenUnixMs
	}
	return a.HostId < b.HostId
}

// applyHealth decides whether one candidate's address may be handed out, and
// records why when it may not, in the locked view. The rule has no exceptions:
// the pool advertises an address only after this aggregator has reached it, and
// a confirmed address is refused again only after HealthGrace of silence.
// See https://yuruna.link/42c29d04-0010.
func applyHealth(view *poolstate.View, e *Entry, now time.Time) {
	if e.Target == "" {
		return // presence without an address: nothing to judge, nothing to hand out
	}
	suppress := func(reason string) {
		e.Suppressed, e.SuppressedTarget, e.SuppressReason, e.Target = true, e.Target, reason, ""
	}
	if why := TargetProblem(e.Target); why != "" {
		suppress(why)
		return
	}
	h := view.ExtHealth[announceKey(e.HostId, e.Area)]
	switch {
	case h == nil || h.Target != e.Target:
		suppress("not yet confirmed by the pool")
	case !h.Confirmed:
		suppress("never answered " + HealthPath + " from the pool: " + h.LastError)
	case h.FirstFailUnixMs != 0 && now.UnixMilli()-h.FirstFailUnixMs > HealthGrace.Milliseconds():
		e.LastOkUnixMs = h.LastOkUnixMs
		suppress("unanswered for more than " + HealthGrace.String() + ": " + h.LastError)
	default:
		e.Healthy, e.LastOkUnixMs, e.LastError = h.FirstFailUnixMs == 0, h.LastOkUnixMs, h.LastError
	}
}

// Candidates returns the pool's answer for each (hostId, area)
// it knows about, keyed by announceKey, from the locked view. It is the one merge
// of the registration and announce sources that every consumer reads; entries
// with no target, and suppressed entries the pool cannot reach, are kept.
// See https://yuruna.link/42c29d04-0006.
func Candidates(view *poolstate.View, announceTTL time.Duration, now time.Time) map[string]Entry {
	best := map[string]Entry{}
	consider := func(cand Entry) {
		if cand.Area == "" || cand.HostId == "" {
			return
		}
		applyHealth(view, &cand, now)
		cand.Host = hostIPFromBaseURL(cand.Target)
		key := announceKey(cand.HostId, cand.Area)
		cur, ok := best[key]
		if !ok {
			best[key] = cand
			return
		}
		winner, loser := cur, cand
		if Better(cand, cur) {
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
			consider(Entry{
				Area: area, Target: hv.ExtensionTargets[area], HostId: hostID,
				Source: SourceRegistration, LastSeenUnixMs: hv.LastSeenUnixMs,
			})
		}
	}
	for _, av := range view.Announce {
		if av == nil {
			continue
		}
		if announceTTL > 0 && now.UnixMilli()-av.LastSeenUnixMs > announceTTL.Milliseconds() {
			continue
		}
		consider(Entry{
			Area: av.Area, Target: av.Target, HostId: av.HostId,
			Source: SourceAnnounce, LastSeenUnixMs: av.LastSeenUnixMs,
			// A rehydrated entry carries no source address: it came out of Loki,
			// not off a live connection, so it is not first-hand evidence yet.
			Confirmed: av.SourceIP != "",
		})
	}
	return best
}

// ResolveHosts returns the pool's current best address per extension area, from
// the locked view: the read side of the presence data, so a host that knows only
// the caching proxy can find every other service the pool offers. A candidate
// whose target yields no host is dropped, since an area is an address question.
// See https://yuruna.link/42c29d04-0006.
func ResolveHosts(view *poolstate.View, announceTTL time.Duration, now time.Time) map[string]Entry {
	best := map[string]Entry{}
	for _, cand := range Candidates(view, announceTTL, now) {
		if cand.Host == "" {
			continue
		}
		if cur, ok := best[cand.Area]; !ok || Better(cand, cur) {
			best[cand.Area] = cand
		}
	}
	return best
}

// TargetFor is the address the pool would send a consumer to for
// one host's area, or "" when it knows none, from the locked view. The single
// lookup behind /go/stash and pool-status's stashBaseUrl, so a redirect and the
// stash UI's own hostId->URL map cannot disagree with each other or with the
// dashboard cell.
func TargetFor(view *poolstate.View, announceTTL time.Duration, hostID, area string, now time.Time) string {
	return Candidates(view, announceTTL, now)[announceKey(hostID, area)].Target
}
