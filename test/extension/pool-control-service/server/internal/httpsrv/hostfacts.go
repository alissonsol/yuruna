// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"net/http"
	"strings"
)

// hostFactsRow is one host's hardware facts as its own status service reports
// them (GET /control/host-facts): RAM, physical cores, and local fixed-disk
// totals. Raw bytes/counts on the wire -- the page picks display units, so the
// rounding rule lives in one place. A host that did not answer keeps ok=false
// with the reason, because "unknown" and "zero" must render differently.
type hostFactsRow struct {
	OK                bool   `json:"ok"`
	MemoryBytes       int64  `json:"memoryBytes,omitempty"`
	Cores             int64  `json:"cores,omitempty"`
	StorageTotalBytes int64  `json:"storageTotalBytes,omitempty"`
	StorageFreeBytes  int64  `json:"storageFreeBytes,omitempty"`
	Error             string `json:"error,omitempty"`
}

// handleHostFacts fans out to every host the aggregator knows and relays each
// one's hardware facts, keyed by host id.
//
// A separate endpoint rather than a field on /api/hosts on purpose: the Hosts
// page re-reads the host list on a timer, but hardware facts change on the
// scale of an upgrade, so the page fetches this only on load and on an explicit
// refresh -- and a host list read must not pay this fan-out's latency.
//
// Open like every other read: it exposes no more than each host's own status
// service already serves to the LAN.
func (s *Server) handleHostFacts(w http.ResponseWriter, r *http.Request) {
	status, err := s.pool.Status(r.Context())
	statusErr := ""
	if err != nil {
		statusErr = err.Error()
	}
	ids := make([]string, 0, len(status.Hosts))
	base := map[string]string{}
	for _, h := range status.Hosts {
		ids = append(ids, h.HostID)
		base[h.HostID] = strings.TrimSuffix(strings.TrimSpace(h.BaseURL), "/")
	}
	ctx, cancel := context.WithTimeout(r.Context(), hostReadBudget)
	defer cancel()

	facts := make(map[string]hostFactsRow, len(ids))
	for i, row := range eachMember(ids, func(hostID string) hostFactsRow {
		if base[hostID] == "" {
			return hostFactsRow{Error: "no address for this host"}
		}
		var f hostFactsRow
		if err := s.pool.GetURL(ctx, base[hostID]+"/control/host-facts", &f); err != nil {
			// An older host build without the route lands here too (404); the
			// page renders the same "unknown" either way.
			return hostFactsRow{Error: err.Error()}
		}
		return f
	}) {
		facts[ids[i]] = row
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "hosts": facts, "statusError": statusErr})
}
