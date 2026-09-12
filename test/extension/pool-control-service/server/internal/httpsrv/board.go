// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"unicode/utf8"

	"pool-control-service/internal/intent"
	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/pool"
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
// pool whose hosts are all silent still renders ("N hosts - 0 reporting"),
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
	// AssignAllowed is false for the auto-enrollment target pool, which is
	// structurally forbidden from carrying a test-set. The UI disables the
	// control and shows AssignDisabledDetail, rather than silently omitting it.
	// This is prose, deliberately not the `reason` machine token used by error
	// envelopes. Keeping the two fields distinct prevents a browser from ever
	// branching on a sentence or rendering a code as if it were a sentence.
	AssignAllowed        bool   `json:"assignAllowed"`
	AssignDisabledDetail string `json:"assignDisabledDetail"`
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
	// Request-local merge state, never serialized. A translated label learned
	// from the project must not be replaced by an English-only library fallback.
	displayLocalized     bool
	descriptionLocalized bool
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
		Name                 string            `json:"name"`
		DisplayName          string            `json:"displayName"`
		DisplayNameLocalized map[string]string `json:"displayNameLocalized"`
		Description          string            `json:"description"`
		DescriptionLocalized map[string]string `json:"descriptionLocalized"`
		FrameworkURL         string            `json:"frameworkUrl"`
		ProjectURL           string            `json:"projectUrl"`
		Sequences            []string          `json:"sequences"`
	} `json:"testSets"`
	AutoEnrollment struct {
		Enabled      bool     `json:"enabled"`
		TargetPoolID string   `json:"targetPoolId"`
		Excluded     []string `json:"excluded"`
	} `json:"autoEnrollment"`
}

// hostRegistration is the part of a host's self-report the board uses.
type hostRegistration struct {
	HostID string `json:"hostId"`
	// Hostname is the machine name the host's own status page shows. It comes
	// from the host itself and never from the pool: the aggregator drops it, so
	// its unauthenticated pool view stays hostname-free.
	Hostname string `json:"hostname"`
	// HostType is the prefixed form ("host.ubuntu.kvm"), the same value the
	// aggregator carries in pool-status.
	HostType   string `json:"hostType"`
	ProjectURL string `json:"projectUrl"`
	TestSets   []struct {
		Name                 string            `json:"name"`
		DisplayName          string            `json:"displayName"`
		DisplayNameLocalized map[string]string `json:"displayNameLocalized"`
		Description          string            `json:"description"`
		DescriptionLocalized map[string]string `json:"descriptionLocalized"`
		Sequences            []string          `json:"sequences"`
	} `json:"testSets"`
	ProjectAccess *struct {
		URL    string `json:"url"`
		Status string `json:"status"`
		Detail string `json:"detail"`
	} `json:"projectAccess"`
}

const (
	projectDisplayNameMax = 160
	projectDescriptionMax = 2000
	projectLocaleMapMax   = 16
)

// The manifest is the spelling authority for the pseudo tags too. Plocm is a
// deliberately manifest-declared five-letter subtag, so the generic BCP 47
// casing algorithm alone would spell it qps-plocm and reject the generated
// Wave-1 fixture. Build this immutable lookup once, not once per board read.
var declaredProjectLocaleTags = func() map[string]string {
	manifest := i18n.DefaultManifest()
	result := make(map[string]string, len(manifest.Data))
	for tag := range manifest.Data {
		result[strings.ToLower(tag)] = tag
	}
	return result
}()

func canonicalProjectLocaleTag(tag string) string {
	canonical := i18n.CanonicalTag(tag, 35)
	if canonical == "" {
		return ""
	}
	if declared, ok := declaredProjectLocaleTags[strings.ToLower(canonical)]; ok {
		return declared
	}
	return canonical
}

func validProjectText(value string, maxRunes int) bool {
	return utf8.ValidString(value) && strings.TrimSpace(value) != "" &&
		utf8.RuneCountInString(value) <= maxRunes
}

func validProjectLocaleMap(values map[string]string, maxRunes int) bool {
	if len(values) < 1 || len(values) > projectLocaleMapMax {
		return false
	}
	for tag, value := range values {
		canonical := canonicalProjectLocaleTag(tag)
		if canonical == "" || tag != canonical || canonical == "en-US" ||
			!validProjectText(value, maxRunes) {
			return false
		}
	}
	return true
}

// localizedProjectText applies the additive project-map read rule. Only an
// exact resolved tag wins; the required English scalar remains the fallback
// for an old project, a missing translation, and the default locale. Both the
// scalar and map came from an unauthenticated host registration, so this is a
// trust boundary as well as a locale lookup: an invalid scalar invalidates its
// additive map, and one invalid map entry invalidates the complete map.
func localizedProjectText(fallback string, values map[string]string, maxRunes int, locale i18n.Context) (string, bool) {
	if !validProjectText(fallback, maxRunes) {
		return "", false
	}
	if locale.ResolvedTag != "" && locale.ResolvedTag != "en-US" {
		if validProjectLocaleMap(values, maxRunes) {
			value, ok := values[locale.ResolvedTag]
			if !ok {
				return fallback, false
			}
			return value, true
		}
	}
	return fallback, false
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
	locale := i18n.FromRequest(r)
	if locale.ResolvedTag == "" {
		locale = s.negotiator().Resolve(r)
	}
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

	// Stats are best-effort. A dead aggregator grays the NUMBERS; it must never
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
	//
	// Fanned out under one shared read budget, like every other pool-wide read
	// here. Served one host at a time, a lab holding a few unreachable machines
	// makes this wait out each connect timeout in turn -- and the board's first
	// paint is blocked on exactly this read.
	ids := make([]string, 0, len(baseURLOf))
	for hid, burl := range baseURLOf {
		if burl != "" {
			ids = append(ids, hid)
		}
	}
	// Sorted, so two hosts declaring the same test-set name resolve to the same
	// winner on every read: the merge below is last-writer-wins, and map order
	// is not an order.
	sort.Strings(ids)
	regCtx, cancelRegs := context.WithTimeout(r.Context(), hostReadBudget)
	defer cancelRegs()
	regs := eachMember(ids, func(hostID string) *hostRegistration {
		var reg hostRegistration
		if err := s.pool.GetURL(regCtx, strings.TrimSuffix(baseURLOf[hostID], "/")+"/runtime/host.registration.json", &reg); err != nil {
			// A host that did not answer offers nothing; its pool still renders,
			// with the numbers the aggregator already reported for it.
			return nil
		}
		return &reg
	})

	offers := map[string]boardOffer{}
	accessDenied := map[string]bool{} // hostId -> cannot read its assigned project
	labelFor := map[string]string{}   // library key -> human label
	for i, reg := range regs {
		if reg == nil {
			continue
		}
		if reg.ProjectAccess != nil && reg.ProjectAccess.Status == "denied" {
			accessDenied[ids[i]] = true
		}
		slug := projectSlug(reg.ProjectURL)
		if slug == "" {
			continue
		}
		for _, ts := range reg.TestSets {
			key := slug + "." + ts.Name
			label, displayLocalized := localizedProjectText(ts.DisplayName, ts.DisplayNameLocalized, projectDisplayNameMax, locale)
			if label == "" {
				label = key
			}
			description, descriptionLocalized := localizedProjectText(ts.Description, ts.DescriptionLocalized, projectDescriptionMax, locale)
			offers[key] = boardOffer{
				Name: key, DisplayName: label, Description: description,
				ProjectURL: reg.ProjectURL, Sequences: ts.Sequences,
				displayLocalized: displayLocalized, descriptionLocalized: descriptionLocalized,
			}
		}
	}
	// Library entries an operator authored are offers too, and they carry the
	// framework url the discovered ones cannot know.
	for _, ts := range doc.TestSets {
		o := offers[ts.Name]
		o.Name = ts.Name
		libraryDisplay, libraryDisplayLocalized := localizedProjectText(ts.DisplayName, ts.DisplayNameLocalized, projectDisplayNameMax, locale)
		if libraryDisplay != "" && (libraryDisplayLocalized || !o.displayLocalized) {
			o.DisplayName = libraryDisplay
			o.displayLocalized = libraryDisplayLocalized
		} else if o.DisplayName == "" {
			o.DisplayName = ts.Name
		}
		libraryDescription, libraryDescriptionLocalized := localizedProjectText(ts.Description, ts.DescriptionLocalized, projectDescriptionMax, locale)
		if libraryDescription != "" && (libraryDescriptionLocalized || !o.descriptionLocalized) {
			o.Description = libraryDescription
			o.descriptionLocalized = libraryDescriptionLocalized
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
	for name, offer := range offers {
		labelFor[name] = offer.DisplayName
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
			c.AssignDisabledDetail = "Hosts land here automatically and keep running their own project."
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

	// The project labels in this representation were selected from the request's
	// locale maps. Keep a shared cache from handing those selected values to a
	// reader in another language; no-store remains the stricter storage policy,
	// while these headers still describe the response correctly to every client.
	i18n.Apply(w.Header(), locale)
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
	// Hostname is the host's own machine name, as its status page shows it, and
	// is empty on an unauthenticated read -- see handleHosts.
	Hostname string `json:"hostname"`
	// Type is the host type WITHOUT its "host." prefix ("ubuntu.kvm"). The
	// prefix is on every value and so distinguishes none of them.
	Type string `json:"type"`
	// Control is the WIRE value (ready/none/mismatch/skew/unknown), not the
	// dashboard's two-way collapse: `mismatch` (wrong token) and `skew` (clock)
	// need different fixes and must not be shown as the same thing.
	Control string `json:"control"`
	// Access is the pool's question -- can this member read the project its
	// POOL assigned (ok/denied/unreachable) -- from the host's registration
	// record. The page's repository columns come from each host's own live
	// answer instead (/api/hosts/facts); this is carried alongside because
	// denied is an operator's problem and no other column would name it.
	Access string `json:"access"`
	Pool   string `json:"pool"`
	// Discovered marks a host this daemon found by scanning the network rather
	// than one the aggregator reported. Such a host is monitored, not enrolled:
	// it belongs to no pool, and its control and access columns are blank
	// because both are the pool's reading of a member. What the host says about
	// itself still fills in -- hardware and its repositories, read from the
	// address it answered on.
	Discovered bool `json:"discovered,omitempty"`
	// Address is where a discovered host answered, and the only identity it has
	// when its registration record could not be read.
	Address string `json:"address,omitempty"`
	// BaseURL is that host's own status service, which for a discovered host is
	// the ONLY way in: the aggregator's /go/host redirect resolves hosts it
	// knows about, and a host that never registered is not one of them. Carried
	// from the probe rather than rebuilt in the page, so the link points at the
	// port the daemon actually got an answer on.
	BaseURL string `json:"baseUrl,omitempty"`
	// LastSeen is when a sweep last confirmed a discovered host, which is the
	// only liveness signal this page has for one.
	LastSeen string `json:"lastSeen,omitempty"`
	// SupersededBy names the host id that answers at this row's address now,
	// and is set only on a row whose id no longer does. It marks the one case
	// where two rows are one machine and the operator has to act: the id here
	// may still hold the pool membership, while the work is being done under
	// the id named. Empty on every ordinary row.
	SupersededBy string `json:"supersededBy,omitempty"`
}

// hostTypeLabel drops the "host." prefix a host serializes its type with, for
// the registration record's copy of it (pool.Host.HostType already does this
// for the aggregator's).
func hostTypeLabel(raw string) string {
	return strings.TrimPrefix(strings.TrimSpace(raw), "host.")
}

// hostBase normalizes a status-service base for use as a map key.
func hostBase(raw string) string {
	return strings.TrimSuffix(strings.TrimSpace(raw), "/")
}

// currentHostByBase maps each status-service base to the ONE host id that
// answers there now, and is only interesting where that is not the only id the
// aggregator holds for it.
//
// A host's id is minted into its runtime directory, so a reimage or a re-clone
// gives the same machine a new one. The aggregator keys hosts by id and keeps
// each for its own TTL, so for a day afterwards two ids describe one machine at
// one address -- and the pool membership sits on the one that went quiet, which
// is how a re-keyed host silently leaves its pool while still doing the work.
//
// One address:port holds one status service, so the ids sharing a base are
// provably one machine and the newest sighting is the id it reports now.
// Reachability outranks the stamp: an unreachable entry's stamp is the last
// probe that worked, and a host that answers now is the one to believe. The id
// itself is the final tiebreak, so a lab where the aggregator reports two
// equally-live entries still gets ONE answer per read rather than a page that
// disagrees with itself between refreshes.
func currentHostByBase(hosts []pool.Host) map[string]string {
	current := map[string]pool.Host{}
	for _, h := range hosts {
		base := hostBase(h.BaseURL)
		if base == "" || h.HostID == "" {
			continue
		}
		best, seen := current[base]
		if !seen || preferredHost(h, best) {
			current[base] = h
		}
	}
	out := make(map[string]string, len(current))
	for base, h := range current {
		out[base] = h.HostID
	}
	return out
}

// preferredHost reports whether a should be believed over b as the occupant of
// the address they share.
func preferredHost(a, b pool.Host) bool {
	if a.Reachable != b.Reachable {
		return a.Reachable
	}
	if a.LastSeenUnixMs != b.LastSeenUnixMs {
		return a.LastSeenUnixMs > b.LastSeenUnixMs
	}
	return a.HostID < b.HostID
}

// handleHosts lists every host the aggregator knows, with its current pool.
//
// Deliberately ALL hosts, not just members: an operator needs to see WHY a host
// was not auto-enrolled, and "it never enrolled a lab token" is only visible if
// the host appears at all.
//
// The read itself stays open like every other one here, but the hostname is
// carried ONLY to a request that is through the write gate, and the answer says
// which of the two it is (hostnamesVisible) so the page can explain a blank
// column instead of looking broken. Every other field is already public on the
// LAN through the aggregator; a machine name is not -- the pool view drops it by
// design, and this page renders on the same kind of unattended wall display.
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

	hostnamesVisible := s.gate.Authed(r)

	// Access, hostname and the type fallback come from each host's own
	// registration record, so building this table is a pool-wide fan-out: one
	// shared read budget and bounded concurrency, or the page waits out every
	// silent host's timeout in turn before it can paint a single row.
	ids := make([]string, 0, len(status.Hosts))
	baseOf := make(map[string]string, len(status.Hosts))
	for _, h := range status.Hosts {
		ids = append(ids, h.HostID)
		baseOf[h.HostID] = strings.TrimSuffix(strings.TrimSpace(h.BaseURL), "/")
	}
	regCtx, cancelRegs := context.WithTimeout(r.Context(), hostReadBudget)
	defer cancelRegs()
	regs := eachMember(ids, func(hostID string) *hostRegistration {
		if baseOf[hostID] == "" {
			return nil
		}
		var reg hostRegistration
		if err := s.pool.GetURL(regCtx, baseOf[hostID]+"/runtime/host.registration.json", &reg); err != nil {
			return nil
		}
		return &reg
	})

	// Which id actually answers at each address, so a machine the aggregator
	// holds under more than one can say which of its rows is the live one.
	currentBy := currentHostByBase(status.Hosts)

	seen := map[string]bool{}
	seenBase := map[string]bool{}
	rows := make([]boardHost, 0, len(status.Hosts))
	for i, h := range status.Hosts {
		seen[h.HostID] = true
		base := hostBase(h.BaseURL)
		if base != "" {
			seenBase[base] = true
		}
		row := boardHost{HostID: h.HostID, Type: h.HostType(), Control: h.Control, Pool: poolOf[h.HostID], Address: h.CurrentIP}
		if row.Control == "" {
			row.Control = "unknown"
		}
		if cur := currentBy[base]; cur != "" && cur != h.HostID {
			row.SupersededBy = cur
		}
		if reg := regs[i]; reg != nil {
			if reg.ProjectAccess != nil {
				row.Access = reg.ProjectAccess.Status
			}
			if hostnamesVisible {
				row.Hostname = strings.TrimSpace(reg.Hostname)
			}
			// A host whose status.json the aggregator could not read still
			// names its own type here, and the two values have one source.
			if row.Type == "" {
				row.Type = hostTypeLabel(reg.HostType)
			}
		}
		rows = append(rows, row)
	}
	// Members the aggregator has not heard from still belong to a pool, and an
	// operator needs to see them -- a silent member is the interesting case.
	for hid, pid := range poolOf {
		if !seen[hid] {
			rows = append(rows, boardHost{HostID: hid, Control: "unknown", Pool: pid})
			seen[hid] = true
		}
	}
	// Hosts this daemon found by scanning the network. They are here, and not on
	// a page of their own, because "which machines does this lab have" is one
	// question: a host that answers on the subnet but registered with nobody is
	// the one an operator most needs to see next to the ones that did.
	rows = append(rows, discoveredRows(s.discovered.List(), seen, seenBase)...)
	// Address, not host id, for the discovered rows that have no id: sorting on
	// an empty string would herd them all to one end regardless of where they
	// live on the network.
	sort.Slice(rows, func(i, j int) bool { return hostSortKey(rows[i]) < hostSortKey(rows[j]) })

	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "hosts": rows, "pools": pools,
		"targetPoolId":     strings.TrimSpace(doc.AutoEnrollment.TargetPoolID),
		"statusError":      statusErr,
		"hostnamesVisible": hostnamesVisible,
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
		// Out of every pool. Remove-HostFromPool against the auto-enrollment
		// target records the exclusion, so the sweep does not undo this.
		if t := strings.TrimSpace(doc.AutoEnrollment.TargetPoolID); t != "" && current != t {
			_ = s.intent.RemoveHost(r.Context(), t, body.HostID)
		}
		s.relay(w, "move-host", body.HostID, intent.Result{OK: true})
		return
	}
	s.relay(w, "move-host", body.HostID, s.intent.AddHost(r.Context(), body.PoolID, body.HostID))
}

// handleAdoptRekey hands a re-keyed machine's pool membership to the id it now
// reports, and forgets the id it stopped reporting.
//
// A host mints its id into its runtime directory, so a reimage or a re-clone
// leaves the machine running under a new one. Pool membership is keyed by id in
// the intent store, so it stays on the id that went quiet: the pool loses a
// member that is sitting right there doing work, and the operator sees two rows
// where there is one machine. Repairing that by hand means reading two ids off
// a table, removing one member and adding the other, in the right pool -- an
// error at any step moves the wrong machine.
//
// The relation is re-derived HERE from the aggregator rather than taken from
// the request: the pair the browser sends is only its reading of a table it
// last loaded minutes ago, and acting on a stale reading would move a live
// host's membership to an id that is no longer the one answering. So the
// service confirms, now, that both ids share an address and that the new one is
// the id that address answers with.
func (s *Server) handleAdoptRekey(w http.ResponseWriter, r *http.Request) {
	var body struct{ OldHostID, NewHostID string }
	if !decode(w, r, &body) {
		return
	}
	oldID, newID := strings.TrimSpace(body.OldHostID), strings.TrimSpace(body.NewHostID)
	if oldID == "" || newID == "" {
		writeErr(w, http.StatusBadRequest, "oldHostId and newHostId are both required")
		return
	}
	if oldID == newID {
		writeErr(w, http.StatusBadRequest, "oldHostId and newHostId are the same host")
		return
	}

	status, err := s.pool.Status(r.Context())
	if err != nil {
		// Without the aggregator there is nothing to confirm the pair against,
		// and this is the one route that must not proceed on the client's word.
		writeErr(w, http.StatusServiceUnavailable, "the aggregator could not be read, so the two ids cannot be confirmed to be one machine: "+err.Error())
		return
	}
	oldHost, oldKnown := status.Host(oldID)
	newHost, newKnown := status.Host(newID)
	if !oldKnown || !newKnown {
		writeErr(w, http.StatusNotFound, "the aggregator does not report both of those hosts")
		return
	}
	base := hostBase(newHost.BaseURL)
	if base == "" || base != hostBase(oldHost.BaseURL) {
		writeErr(w, http.StatusConflict, "those two hosts do not answer at the same address, so they are not one machine that re-keyed")
		return
	}
	if currentHostByBase(status.Hosts)[base] != newID {
		writeErr(w, http.StatusConflict, "that address does not answer as the new host id; reload the page and read the pair again")
		return
	}

	doc, err := s.readIntentDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	oldPool, newPool := "", ""
	for _, p := range doc.Pools {
		for _, m := range p.Members {
			switch m {
			case oldID:
				oldPool = p.PoolID
			case newID:
				newPool = p.PoolID
			}
		}
	}

	// Remove first, always. A host belongs to at most one pool, so adding the
	// new id while the old one is still a member would put one machine in a
	// pool twice under two names -- the very state this repairs.
	if oldPool != "" {
		if res := s.intent.RemoveHost(r.Context(), oldPool, oldID); !res.OK {
			writeErr(w, http.StatusInternalServerError, firstNonEmpty(res.Error, res.Stderr, "the old host id could not be removed from "+oldPool))
			return
		}
	}
	// The new id keeps the pool it is already in: it is the live host, and an
	// operator who has since placed it somewhere deliberately must not have
	// that undone by a repair.
	moved := ""
	if oldPool != "" && newPool == "" {
		if res := s.intent.AddHost(r.Context(), oldPool, newID); !res.OK {
			writeErr(w, http.StatusInternalServerError, firstNonEmpty(res.Error, res.Stderr, "the new host id could not be added to "+oldPool))
			return
		}
		moved = oldPool
	}
	// The scan's own list is keyed by id too, so the retired id would go on
	// showing there as a host of its own. Best-effort: it may never have been
	// discovered, and a monitored-list entry is not worth failing a repair the
	// intent store has already accepted.
	forgot := s.discovered.Forget(oldID)

	s.auditScan("adopt-rekey", oldID+" -> "+newID)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "oldHostId": oldID, "newHostId": newID,
		"movedToPool": moved, "keptPool": newPool, "forgotten": forgot,
	})
}
