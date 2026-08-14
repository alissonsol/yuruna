// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"net/http"
	"strings"
)

// hostFactsRow is what a host says about itself, as its own status service
// reports it (GET /control/host-facts): RAM, physical cores, the totals of the
// storage that stays with the machine, and the two repositories it runs on --
// each host counts every space pool once and leaves out what is merely
// attached to it, so these are figures a pool can be planned against and can
// be compared between hosts. Raw
// bytes/counts on the wire -- the page picks display units, so the rounding
// rule lives in one place. A host that did not answer keeps ok=false with the
// reason, because "unknown" and "zero" must render differently.
type hostFactsRow struct {
	OK                bool  `json:"ok"`
	MemoryBytes       int64 `json:"memoryBytes,omitempty"`
	Cores             int64 `json:"cores,omitempty"`
	StorageTotalBytes int64 `json:"storageTotalBytes,omitempty"`
	StorageFreeBytes  int64 `json:"storageFreeBytes,omitempty"`
	// FrameworkAccess and ProjectAccess are the host's answer about the two
	// repositories it runs on: the repository NAME it holds ("yuruna",
	// "amisad.dev"), "No access" when it was configured with one it cannot
	// read, or empty when it has neither a clone nor a configured url.
	//
	// Not the same value as hostRegistration.ProjectAccess, which is the
	// pool's question -- can this member read what its POOL assigned -- and
	// is answered once per cycle in the host's registration record. These
	// two are the host's own, read live, and answer for every host including
	// one in no pool at all.
	FrameworkAccess string `json:"frameworkAccess,omitempty"`
	ProjectAccess   string `json:"projectAccess,omitempty"`
	// Where each of those repositories lives, already normalized by the host
	// into a form a browser can be pointed at (and with any credential written
	// into the remote stripped there, before it reached this relay). Empty when
	// the host reported no url, or reports none at all -- the page then renders
	// the name as plain text, so an older host build stays readable.
	FrameworkURL string `json:"frameworkUrl,omitempty"`
	ProjectURL   string `json:"projectUrl,omitempty"`
	Error        string `json:"error,omitempty"`
}

// handleHostFacts fans out to every host the Hosts page can list -- the ones the
// aggregator reports AND the ones this daemon found by scanning -- and relays
// each one's hardware and repository facts.
//
// Keyed the way the page keys its rows: the host id when there is one, the
// address otherwise. A discovered host that would not name itself has only the
// address to be known by, and a row the answer cannot be matched to renders as
// if the host never replied.
//
// A discovered host is asked at the base URL the probe reached it on, which is
// the only way in: the aggregator resolves the address of hosts it knows about,
// and a discovered host is by definition one it does not. Everything served
// here is a host's own account of itself, so a discovered host answers it in
// full -- unlike control state, which is the pool's reading of a member.
//
// A separate endpoint rather than a field on /api/hosts on purpose: the Hosts
// page re-reads the host list on a timer, but the facts here change on the
// scale of an upgrade or a re-clone, so the page fetches this only on load and
// on an explicit refresh -- and a host list read must not pay this fan-out's
// latency.
//
// Open like every other read: it exposes no more than each host's own status
// service already serves to the LAN.
func (s *Server) handleHostFacts(w http.ResponseWriter, r *http.Request) {
	status, err := s.pool.Status(r.Context())
	statusErr := ""
	if err != nil {
		statusErr = err.Error()
	}
	keys := make([]string, 0, len(status.Hosts))
	base := map[string]string{}
	seenBase := map[string]bool{}
	for _, h := range status.Hosts {
		b := strings.TrimSuffix(strings.TrimSpace(h.BaseURL), "/")
		keys = append(keys, h.HostID)
		base[h.HostID] = b
		if b != "" {
			seenBase[b] = true
		}
	}
	// Same two-way de-duplication the Hosts table renders by (id, then base
	// URL), so a machine that is both discovered and registered is asked once.
	// A find with no base URL is skipped rather than carried as an error row:
	// there is nothing to ask, and the page's blank already says so.
	for _, d := range s.discovered.List() {
		b := strings.TrimSuffix(strings.TrimSpace(d.BaseURL), "/")
		key := d.Key()
		if key == "" || b == "" {
			continue
		}
		if known, dup := base[key]; dup {
			// The aggregator reported this host but holds no address for it,
			// and the sweep reached one. Ask there instead of recording "no
			// address" for a machine this daemon spoke to minutes ago.
			if known == "" {
				base[key] = b
				seenBase[b] = true
			}
			continue
		}
		if seenBase[b] {
			continue
		}
		keys = append(keys, key)
		base[key] = b
		seenBase[b] = true
	}
	ctx, cancel := context.WithTimeout(r.Context(), hostReadBudget)
	defer cancel()

	facts := make(map[string]hostFactsRow, len(keys))
	for i, row := range eachMember(keys, func(key string) hostFactsRow {
		if base[key] == "" {
			return hostFactsRow{Error: "no address for this host"}
		}
		var f hostFactsRow
		if err := s.pool.GetURL(ctx, base[key]+"/control/host-facts", &f); err != nil {
			// An older host build without the route lands here too (404); the
			// page renders the same "unknown" either way.
			return hostFactsRow{Error: err.Error()}
		}
		return f
	}) {
		facts[keys[i]] = row
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "hosts": facts, "statusError": statusErr})
}
