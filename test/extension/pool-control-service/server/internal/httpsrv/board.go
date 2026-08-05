// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http"
	"net/url"
	"sort"
	"strings"

	"pool-control-service/internal/intent"
)

// The operator board's server side.
//
// The board answers two questions for a less technical operator: how is each
// pool doing, and give this pool a ready-made test set. Everything here exists
// to serve those, on a phone.
//
// The join lives HERE, not in the aggregator, because the two halves of the
// answer live in different places:
//
//   - Cycle counts live in Loki, which only the aggregator can reach (it is
//     bound to 127.0.0.1 on the proxy). It returns per-HOST rows.
//   - Membership lives in the intent store, which only this service reads. The
//     aggregator's sole notion of a pool is the poolId a host self-advertises,
//     which falls back to the literal "default" for an unidentified host -- so
//     attributing cycles by that label would fold non-members into a pool.
//
// Cards are therefore enumerated from INTENT and the stats joined onto them. A
// pool whose hosts are all silent still renders ("N hosts · 0 reporting"),
// instead of vanishing because no Loki stream mentioned it -- which is exactly
// the pool that most needs looking at.

// boardRanges is the closed set of windows the board offers, mirroring the
// aggregator's own allowlist. Anything else is refused before it is forwarded.
var boardRanges = map[string]bool{"1h": true, "24h": true, "7d": true, "30d": true}

// aggHostStat is one per-host row from the aggregator's /api/v1/pool-stats.
type aggHostStat struct {
	HostID string `json:"hostId"`
	Passed int64  `json:"passed"`
	Failed int64  `json:"failed"`
}

// aggPoolStats is the aggregator's pool-stats envelope.
type aggPoolStats struct {
	Range      string        `json:"range"`
	ComputedAt string        `json:"computedAt"`
	Hosts      []aggHostStat `json:"hosts"`
}

// boardCard is one pool as the board renders it.
type boardCard struct {
	PoolID         string `json:"poolId"`
	PoolGUID       string `json:"poolGuid"`
	Display        string `json:"displayName"`
	HostsTotal     int    `json:"hostsTotal"`
	HostsReporting int    `json:"hostsReporting"`
	Passed         int64  `json:"passed"`
	Failed         int64  `json:"failed"`
	Total          int64  `json:"total"`
	// SuccessPct is a POINTER so "no terminal cycle in range" serializes as
	// null and the UI can render n/a. A float 0 would render as 0.00%, and an
	// idle pool must never read as catastrophically failing -- nor as a
	// reassuring 100%.
	SuccessPct *float64 `json:"successPct"`
	// TestSet is the assigned set's key; TestSetLabel is what a human reads,
	// resolved from the discovery cache when a project declared a displayName.
	TestSet      string `json:"testSet"`
	TestSetLabel string `json:"testSetLabel"`
	// AssignAllowed is false for the auto-enrolment target pool, which is
	// structurally forbidden from carrying a test-set. The UI disables the
	// control and shows Reason, rather than silently omitting it.
	AssignAllowed bool   `json:"assignAllowed"`
	Reason        string `json:"reason"`
	// Blocked lists members that cannot read the assigned project. Advisory:
	// the board flags the pool, nothing changes state automatically.
	Blocked []string `json:"blocked"`
}

// boardOffer is one assignable test set, as the picker shows it.
type boardOffer struct {
	Name         string   `json:"name"`
	DisplayName  string   `json:"displayName"`
	Description  string   `json:"description"`
	FrameworkURL string   `json:"frameworkUrl"`
	ProjectURL   string   `json:"projectUrl"`
	Sequences    []string `json:"sequences"`
}

// intentDoc is the shape Get-PoolIntent.ps1 emits.
type intentDoc struct {
	OK    bool `json:"ok"`
	Pools []struct {
		PoolID   string   `json:"poolId"`
		PoolGUID string   `json:"poolGuid"`
		Display  string   `json:"displayName"`
		Members  []string `json:"members"`
		TestSet  *struct {
			Name         string   `json:"name"`
			FrameworkURL string   `json:"frameworkUrl"`
			ProjectURL   string   `json:"projectUrl"`
			Sequences    []string `json:"sequences"`
		} `json:"testSet"`
	} `json:"pools"`
	TestSets []struct {
		Name         string   `json:"name"`
		DisplayName  string   `json:"displayName"`
		Description  string   `json:"description"`
		FrameworkURL string   `json:"frameworkUrl"`
		ProjectURL   string   `json:"projectUrl"`
		Sequences    []string `json:"sequences"`
	} `json:"testSets"`
	AutoEnrollment struct {
		Enabled      bool     `json:"enabled"`
		TargetPoolID string   `json:"targetPoolId"`
		Excluded     []string `json:"excluded"`
	} `json:"autoEnrollment"`
}

// hostRegistration is the part of a host's self-report the board uses.
type hostRegistration struct {
	HostID     string `json:"hostId"`
	ProjectURL string `json:"projectUrl"`
	TestSets   []struct {
		Name        string   `json:"name"`
		DisplayName string   `json:"displayName"`
		Description string   `json:"description"`
		Sequences   []string `json:"sequences"`
	} `json:"testSets"`
	ProjectAccess *struct {
		URL    string `json:"url"`
		Status string `json:"status"`
		Detail string `json:"detail"`
	} `json:"projectAccess"`
}

// projectSlug turns a projectUrl into the library-name prefix. Discovered set
// names are project-scoped by construction (`<slug>.<setName>`) because the
// library upserts on `name` ALONE and every project reports an implicit set
// called "all" -- a bare name would have one project's "all" overwrite another's,
// silently retargeting a library row at an unrelated repo.
func projectSlug(projectURL string) string {
	s := strings.TrimSuffix(strings.TrimSpace(projectURL), ".git")
	if u, err := url.Parse(s); err == nil && u.Path != "" {
		s = strings.Trim(u.Path, "/")
	}
	s = strings.ToLower(s)
	var b strings.Builder
	prevDash := false
	for _, r := range s {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
			prevDash = false
		default:
			if !prevDash && b.Len() > 0 {
				b.WriteByte('-')
				prevDash = true
			}
		}
	}
	return strings.Trim(b.String(), "-")
}

// handleBoard serves the board's whole payload: the cards, the offers, and the
// range actually used. One request so a phone does a single round trip.
func (s *Server) handleBoard(w http.ResponseWriter, r *http.Request) {
	window := r.URL.Query().Get("range")
	if window == "" {
		window = "24h"
	}
	if !boardRanges[window] {
		writeErr(w, http.StatusBadRequest, "unsupported range; use 1h, 24h, 7d or 30d")
		return
	}

	// Intent first: it is the authority for which cards exist, and the board is
	// still useful (and still assignable) when the aggregator is unreachable.
	doc, err := s.readIntentDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Stats are best-effort. A dead aggregator greys the NUMBERS; it must never
	// stop an operator assigning work, because assignment goes through the
	// intent CLIs and has no aggregator dependency at all.
	var stats aggPoolStats
	statsErr := ""
	if err := s.pool.Get(r.Context(), "/api/v1/pool-stats?range="+url.QueryEscape(window), &stats); err != nil {
		statsErr = err.Error()
	}
	status, _ := s.pool.Status(r.Context())

	passedBy := map[string]int64{}
	failedBy := map[string]int64{}
	for _, h := range stats.Hosts {
		passedBy[h.HostID] = h.Passed
		failedBy[h.HostID] = h.Failed
	}
	reporting := map[string]bool{}
	baseURLOf := map[string]string{}
	for _, h := range status.Hosts {
		reporting[h.HostID] = true
		baseURLOf[h.HostID] = h.BaseURL
	}

	// Discovery: read each reporting host's registration DIRECTLY. The
	// aggregator decodes that record into a closed struct and would discard
	// testSets[] at unmarshal, so relaying through it is not an option.
	offers := map[string]boardOffer{}
	accessDenied := map[string]bool{} // hostId -> cannot read its assigned project
	labelFor := map[string]string{}   // library key -> human label
	for hid, burl := range baseURLOf {
		if burl == "" {
			continue
		}
		var reg hostRegistration
		if err := s.pool.GetURL(r.Context(), strings.TrimSuffix(burl, "/")+"/runtime/host.registration.json", &reg); err != nil {
			continue
		}
		if reg.ProjectAccess != nil && reg.ProjectAccess.Status == "denied" {
			accessDenied[hid] = true
		}
		slug := projectSlug(reg.ProjectURL)
		if slug == "" {
			continue
		}
		for _, ts := range reg.TestSets {
			key := slug + "." + ts.Name
			label := ts.DisplayName
			if label == "" {
				label = key
			}
			labelFor[key] = label
			offers[key] = boardOffer{
				Name: key, DisplayName: label, Description: ts.Description,
				ProjectURL: reg.ProjectURL, Sequences: ts.Sequences,
			}
		}
	}
	// Library entries an operator authored are offers too, and they carry the
	// framework url the discovered ones cannot know.
	for _, ts := range doc.TestSets {
		o := offers[ts.Name]
		o.Name = ts.Name
		if ts.DisplayName != "" {
			o.DisplayName = ts.DisplayName
			labelFor[ts.Name] = ts.DisplayName
		} else if o.DisplayName == "" {
			o.DisplayName = ts.Name
		}
		if ts.Description != "" {
			o.Description = ts.Description
		}
		if ts.FrameworkURL != "" {
			o.FrameworkURL = ts.FrameworkURL
		}
		if ts.ProjectURL != "" {
			o.ProjectURL = ts.ProjectURL
		}
		if len(ts.Sequences) > 0 {
			o.Sequences = ts.Sequences
		}
		offers[ts.Name] = o
	}

	target := strings.TrimSpace(doc.AutoEnrollment.TargetPoolID)
	cards := make([]boardCard, 0, len(doc.Pools))
	for _, p := range doc.Pools {
		c := boardCard{
			PoolID: p.PoolID, PoolGUID: p.PoolGUID, Display: p.Display,
			HostsTotal: len(p.Members), AssignAllowed: true,
		}
		if c.Display == "" {
			c.Display = p.PoolID
		}
		for _, m := range p.Members {
			if reporting[m] {
				c.HostsReporting++
			}
			c.Passed += passedBy[m]
			c.Failed += failedBy[m]
			if accessDenied[m] {
				c.Blocked = append(c.Blocked, m)
			}
		}
		c.Total = c.Passed + c.Failed
		if c.Total > 0 {
			pct := 100 * float64(c.Passed) / float64(c.Total)
			c.SuccessPct = &pct
		}
		if p.TestSet != nil {
			c.TestSet = p.TestSet.Name
			c.TestSetLabel = labelFor[p.TestSet.Name]
			if c.TestSetLabel == "" {
				c.TestSetLabel = p.TestSet.Name
			}
		}
		if target != "" && p.PoolID == target {
			c.AssignAllowed = false
			c.Reason = "Hosts land here automatically and keep running their own project."
		}
		cards = append(cards, c)
	}
	sort.Slice(cards, func(i, j int) bool { return cards[i].PoolID < cards[j].PoolID })

	names := make([]string, 0, len(offers))
	for n := range offers {
		names = append(names, n)
	}
	sort.Strings(names)
	offerList := make([]boardOffer, 0, len(names))
	for _, n := range names {
		offerList = append(offerList, offers[n])
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":         true,
		"range":      window,
		"computedAt": stats.ComputedAt,
		"statsError": statsErr,
		"cards":      cards,
		"offers":     offerList,
	})
}

// boardHost is one row of the Hosts page.
type boardHost struct {
	HostID string `json:"hostId"`
	// Control is the WIRE value (ready/none/mismatch/skew/unknown), not the
	// dashboard's two-way collapse: `mismatch` (wrong token) and `skew` (clock)
	// need different fixes and must not be shown as the same thing.
	Control string `json:"control"`
	Access  string `json:"access"`
	Pool    string `json:"pool"`
}

// handleHosts lists every host the aggregator knows, with its current pool.
//
// Deliberately ALL hosts, not just members: an operator needs to see WHY a host
// was not auto-enrolled, and "it never enrolled a lab token" is only visible if
// the host appears at all.
func (s *Server) handleHosts(w http.ResponseWriter, r *http.Request) {
	doc, err := s.readIntentDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	poolOf := map[string]string{}
	for _, p := range doc.Pools {
		for _, m := range p.Members {
			poolOf[m] = p.PoolID
		}
	}
	pools := make([]string, 0, len(doc.Pools))
	for _, p := range doc.Pools {
		pools = append(pools, p.PoolID)
	}
	sort.Strings(pools)

	status, err := s.pool.Status(r.Context())
	statusErr := ""
	if err != nil {
		statusErr = err.Error()
	}

	seen := map[string]bool{}
	rows := make([]boardHost, 0, len(status.Hosts))
	for _, h := range status.Hosts {
		seen[h.HostID] = true
		row := boardHost{HostID: h.HostID, Control: h.Control, Pool: poolOf[h.HostID]}
		if row.Control == "" {
			row.Control = "unknown"
		}
		if h.BaseURL != "" {
			var reg hostRegistration
			if err := s.pool.GetURL(r.Context(), strings.TrimSuffix(h.BaseURL, "/")+"/runtime/host.registration.json", &reg); err == nil && reg.ProjectAccess != nil {
				row.Access = reg.ProjectAccess.Status
			}
		}
		rows = append(rows, row)
	}
	// Members the aggregator has not heard from still belong to a pool, and an
	// operator needs to see them -- a silent member is the interesting case.
	for hid, pid := range poolOf {
		if !seen[hid] {
			rows = append(rows, boardHost{HostID: hid, Control: "unknown", Pool: pid})
		}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].HostID < rows[j].HostID })

	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "hosts": rows, "pools": pools,
		"targetPoolId": strings.TrimSpace(doc.AutoEnrollment.TargetPoolID),
		"statusError":  statusErr,
	})
}

// handleMoveHost moves a host to a pool, or out of every pool.
//
// A host is in at most one pool, so "move" is the only correct semantic for a
// picker: remove from the current pool, then add to the chosen one.
//
// Choosing "(none)" ALSO records the host in autoEnrollment.excluded[] -- via
// Remove-HostFromPool against the target pool, which owns that list. Without
// that write the sweep would put the host straight back within a minute and the
// UI would look broken.
func (s *Server) handleMoveHost(w http.ResponseWriter, r *http.Request) {
	var body struct{ HostID, PoolID string }
	if !decode(w, r, &body) {
		return
	}
	if body.HostID == "" {
		writeErr(w, http.StatusBadRequest, "hostId is required")
		return
	}
	doc, err := s.readIntentDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	current := ""
	for _, p := range doc.Pools {
		for _, m := range p.Members {
			if m == body.HostID {
				current = p.PoolID
			}
		}
	}
	if current == body.PoolID {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "unchanged": true})
		return
	}
	if current != "" {
		if r2 := s.intent.RemoveHost(r.Context(), current, body.HostID); !r2.OK {
			writeErr(w, http.StatusInternalServerError, firstNonEmpty(r2.Error, r2.Stderr, "remove failed"))
			return
		}
	}
	if body.PoolID == "" {
		// Out of every pool. Remove-HostFromPool against the auto-enrolment
		// target records the exclusion, so the sweep does not undo this.
		if t := strings.TrimSpace(doc.AutoEnrollment.TargetPoolID); t != "" && current != t {
			_ = s.intent.RemoveHost(r.Context(), t, body.HostID)
		}
		s.relay(w, "move-host", body.HostID, intent.Result{OK: true})
		return
	}
	s.relay(w, "move-host", body.HostID, s.intent.AddHost(r.Context(), body.PoolID, body.HostID))
}
