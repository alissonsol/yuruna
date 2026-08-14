// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"pool-control-service/internal/discovery"
	"pool-control-service/internal/state"
)

// The network scan and the hosts it discovers.
//
// A host reaches the pool's UIs by registering with the aggregator, and a host
// nobody registered is invisible even when it is sitting on the same subnet
// answering probes. The scan asks the network directly and keeps what it finds
// in this daemon's own list, so the Hosts page shows the machines that EXIST
// and not only the ones some other component was told about.
//
// Discovery never touches pool intent: a discovered host is monitored, not
// enrolled. Putting it in a pool stays an operator's decision, made on the
// Hosts page, and the row is there for them to make it on.

// discoveredHostsFile is the discovered list's name under the state dir, beside
// the audit log and status.json.
const discoveredHostsFile = "discovered-hosts.json"

// discoveredHostsPath places the list in the state dir, or returns "" when
// there is none -- which the store reads as "memory only".
func discoveredHostsPath(stateDir string) string {
	if strings.TrimSpace(stateDir) == "" {
		return ""
	}
	return filepath.Join(stateDir, discoveredHostsFile)
}

// scanCIDR is the range this daemon sweeps: the operator's configured value, or
// the /24 around this service's own address when none was configured. Resolved
// per call rather than at launch so a service that moved subnets sweeps the one
// it is on now.
func (s *Server) scanCIDR() string {
	if c := strings.TrimSpace(s.opts.ScanCIDR); c != "" {
		return c
	}
	return discovery.DefaultCIDR()
}

// knownElsewhere lists the hosts the aggregator already monitors, so a scan can
// tell a genuine addition from a machine the pool has known all along.
//
// An aggregator that cannot be reached yields an empty set, which is the safe
// direction: the worst case is that an already-known host is added to this
// daemon's list too, and the Hosts page renders one row for it either way
// because the merge keys on host id.
func (s *Server) knownElsewhere(ctx context.Context) map[string]struct{} {
	out := map[string]struct{}{}
	status, err := s.pool.Status(ctx)
	if err != nil {
		return out
	}
	for _, h := range status.Hosts {
		if h.HostID != "" {
			out[h.HostID] = struct{}{}
		}
		if base := strings.TrimSpace(h.BaseURL); base != "" {
			out[base] = struct{}{}
		}
	}
	return out
}

// RunDiscovery sweeps the configured range on a timer until ctx is done.
// Started unconditionally by the caller and inert when the interval is zero, so
// "how often" is one launch flag rather than a branch at the call site.
func (s *Server) RunDiscovery(ctx context.Context, interval time.Duration) {
	s.scan.RunSweep(ctx, interval, s.scanCIDR)
}

// handleScanStatus reports the current (or last) scan plus everything the page
// needs to render itself cold: the default range to offer, the sweep cadence,
// and the hosts discovered so far.
//
// Open like every other read on this service. It exposes the addresses of
// machines on the lab's own network to the lab's own network, which is what a
// scan of that network found by asking it.
func (s *Server) handleScanStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":           true,
		"scan":         s.scan.Progress(),
		"hosts":        s.discovered.List(),
		"defaultCidr":  s.scanCIDR(),
		"port":         s.opts.ScanPort,
		"sweepSeconds": int(s.opts.ScanInterval / time.Second),
		"maxAddresses": discovery.MaxAddresses,
		"storeError":   s.discovered.LastError(),
	})
}

// handleScanStart begins a scan of the requested range.
//
// Gated like every other change: it adds hosts to what this daemon monitors,
// and it points a burst of connection attempts at a network of the caller's
// choosing. Reading the result stays open; asking for it does not.
func (s *Server) handleScanStart(w http.ResponseWriter, r *http.Request) {
	var body struct{ CIDR string }
	if !decode(w, r, &body) {
		return
	}
	cidr := strings.TrimSpace(body.CIDR)
	if cidr == "" {
		cidr = s.scanCIDR()
	}
	progress, err := s.scan.Start(r.Context(), cidr, "scan")
	if err != nil {
		if err == discovery.ErrScanning {
			// Not a failure: the page asked for what is already happening, and
			// showing it that scan is a better answer than an error it would
			// have to explain away.
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "scan": progress, "alreadyRunning": true})
			return
		}
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.auditScan("scan-start", cidr)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "scan": progress})
}

// handleScanForget drops one discovered host from the monitored list. The way
// out for a machine that has been retired: without it a decommissioned address
// stays on the page until the next sweep fails to find it, and then forever,
// because a silent host is exactly what a monitored list is meant to keep
// showing.
func (s *Server) handleScanForget(w http.ResponseWriter, r *http.Request) {
	var body struct{ Key string }
	if !decode(w, r, &body) {
		return
	}
	key := strings.TrimSpace(body.Key)
	if key == "" {
		writeErr(w, http.StatusBadRequest, "key is required (a discovered host's id or address)")
		return
	}
	if !s.discovered.Forget(key) {
		writeErr(w, http.StatusNotFound, "no discovered host with that id or address")
		return
	}
	s.auditScan("scan-forget", key)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// auditScan records a discovery action in the same append-only log every intent
// mutation lands in: what this daemon monitors is operator-visible state, and a
// row that appeared on its own needs the same trail as one somebody added.
func (s *Server) auditScan(action, target string) {
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		TimeUTC: now.UTC().Format(time.RFC3339),
		Action:  action, Target: target, OK: true,
	})
}

// hostSortKey orders the Hosts table. A host id when there is one, the address
// otherwise, so a discovered host that could not name itself still lands
// somewhere meaningful instead of being sorted as a blank.
func hostSortKey(h boardHost) string {
	if h.HostID != "" {
		return h.HostID
	}
	return h.Address
}

// discoveredRows turns the discovered list into Hosts-page rows, dropping any
// host the aggregator already reported (matched by id, then by base URL) so a
// machine that is both discovered and registered renders once.
//
// Control state and access stay blank: both are the POOL's reading of a member
// -- whether the host holds this lab's token, and how its last probe of the
// project its pool assigned went -- and a discovered host has not been made a
// member of anything. Blank is the honest answer, and the page already renders
// one for every other host it cannot reach. Hardware is not in that class: it
// is the host's own answer about itself, served on the address the sweep
// reached it at, so /api/hosts/facts asks a discovered host directly.
func discoveredRows(hosts []discovery.Host, seen map[string]bool, seenBase map[string]bool) []boardHost {
	rows := make([]boardHost, 0, len(hosts))
	for _, h := range hosts {
		if h.HostID != "" && seen[h.HostID] {
			continue
		}
		if seenBase[strings.TrimSuffix(h.BaseURL, "/")] {
			continue
		}
		rows = append(rows, boardHost{
			HostID:     h.HostID,
			Hostname:   h.Hostname,
			Type:       h.HostType,
			Control:    "unknown",
			Discovered: true,
			Address:    h.Address,
			BaseURL:    h.BaseURL,
			LastSeen:   h.LastSeenUTC,
		})
	}
	return rows
}
