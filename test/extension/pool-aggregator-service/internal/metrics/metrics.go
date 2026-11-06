// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42f3a9c1-8b4d-4e62-97d5-2c6e0a1f7b38

// Package metrics renders the collector's Prometheus exposition from the pool
// view. It reads the view under the lock its caller holds and produces one
// text body, so the caller can release the lock before writing to the scraper.
package metrics

import (
	"fmt"
	"maps"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	sdkpool "yuruna.com/test/extension/extension-sdk/pool"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// Inputs are the collector's settings and the facts outside the view that the
// exposition carries.
type Inputs struct {
	Pool        string        // the collector's default pool label
	Now         time.Time     // the scrape's clock
	RefreshTTL  time.Duration // how long a refresh capability reading stays current
	CrossWindow time.Duration // the cross-host incident window
	// ArchiveConfigured says an archive root is set; ArchiveAvailable says it
	// was readable just before the view was locked.
	ArchiveConfigured bool
	ArchiveAvailable  bool
	// Outbox is the Loki outbox's state, nil when lines go to Loki directly.
	Outbox *OutboxState
	// LabTokenLive says the lab-token exchange is enabled, so the current code
	// and the exchange counters are exported.
	LabTokenLive bool
	// Extensions are the pool's resolved extension services, one per
	// (hostId, area), sorted by that key so a scrape is byte-stable across
	// polls holding the same facts.
	Extensions []ExtensionRow
}

// OutboxState is what the exposition says about the Loki outbox.
type OutboxState struct {
	Pending int  // lines waiting for Loki
	Durable bool // the lines survive a restart of the collector
}

// ExtensionRow is one resolved extension service as the exposition reads it.
type ExtensionRow struct {
	HostID         string
	Area           string
	Target         string // the address handed out; "" when there is none or it is suppressed
	LastSeenUnixMs int64
	// SupersededTarget is the address the losing source claimed, "" when the
	// sources agreed or only one spoke.
	SupersededTarget string
	// Suppressed rows carry an address the pool could not reach, kept in
	// SuppressedTarget with SuppressReason saying why.
	Suppressed       bool
	SuppressedTarget string
	SuppressReason   string
}

// Render writes the exposition of view. The caller holds the view's lock.
func Render(view *poolstate.View, in Inputs) string {
	pool := func(hostID string) string { return view.PoolLabel(hostID, in.Pool) }
	archiveAvailable := 0
	if in.ArchiveAvailable {
		archiveAvailable = 1
	}
	total := len(view.Hosts)
	reachable := 0
	for _, h := range view.Hosts {
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
	for h := range view.Hosts {
		hostIDs[h] = true
	}
	passTotals, failTotals := view.CycleTotals()
	for h := range passTotals {
		hostIDs[view.CanonicalHostID(h)] = true
	}
	for h := range failTotals {
		hostIDs[view.CanonicalHostID(h)] = true
	}
	ids := slices.Sorted(maps.Keys(hostIDs))

	var b strings.Builder
	fmt.Fprintf(&b, "# HELP yuruna_pool_collector_up pool-aggregator service is serving.\n# TYPE yuruna_pool_collector_up gauge\nyuruna_pool_collector_up 1\n")
	fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_total Pool hosts discovered (within hostTtl).\n# TYPE yuruna_pool_hosts_total gauge\nyuruna_pool_hosts_total %d\n", total)
	// Archive availability, exported only when an archive root is configured. This is
	// how "the dashboard's cycle links stopped working" becomes visible without a
	// human noticing dead links: the CIFS mount is nofail, so when it goes away every
	// archived cycle silently stops resolving and nothing else says so.
	if in.ArchiveConfigured {
		fmt.Fprintf(&b, "# HELP yuruna_pool_archive_available The pool share's archive root is readable on the collector (0 = the NAS mount is away; archived cycle links fall back to the hosts).\n# TYPE yuruna_pool_archive_available gauge\nyuruna_pool_archive_available %d\n", archiveAvailable)
	}
	fmt.Fprintf(&b, "# HELP yuruna_pool_hosts_reachable Pool hosts answering status.json on the last poll.\n# TYPE yuruna_pool_hosts_reachable gauge\nyuruna_pool_hosts_reachable %d\n", reachable)
	if !view.LastPoll().IsZero() {
		fmt.Fprintf(&b, "# HELP yuruna_pool_last_poll_timestamp_seconds Unix time of the last completed poll.\n# TYPE yuruna_pool_last_poll_timestamp_seconds gauge\nyuruna_pool_last_poll_timestamp_seconds %d\n", view.LastPoll().Unix())
	}

	// host_info carries the pool table's label cells; its value is the host's
	// last-seen time, so a reader can take the newest of two series while the
	// labels churn. See https://yuruna.link/42c29d04-0014.
	b.WriteString("# HELP yuruna_pool_host_info Per-host descriptive labels for the pool table; the value is the host's last-seen Unix time, so a reader can select the newest series per host while the labels churn.\n# TYPE yuruna_pool_host_info gauge\n")
	for _, h := range ids {
		hv := view.Hosts[h]
		if hv == nil {
			continue
		}
		hostType, cycleStartUtc, cfu := "", "", ""
		commitDisplay, commitURLVal, projectCommitURL := "", "", ""
		if hv.Status != nil {
			hostType, cycleStartUtc, cfu = hv.Status.Host, hv.Status.CycleStartUtc, hv.Status.CycleFolderUrl
			// commit is the current cycle's short SHAs (framework, project); the two
			// URL labels are the per-repo deep-links the table's Commit cell resolves.
			commitDisplay, commitURLVal, projectCommitURL = CommitCells(hv.Status)
		}
		// The labels stay hostname-free, and control is the state name only.
		// See https://yuruna.link/42c29d04-0014.
		fmt.Fprintf(&b, "yuruna_pool_host_info{pool=%q,poolGuid=%q,hostId=%q,hostIdDashed=%q,hostType=%q,version=%q,commit=%q,commitUrl=%q,projectCommitUrl=%q,baseUrl=%q,cycleStartUtc=%q,cycleFolderUrl=%q,status=%q,control=%q} %d\n",
			pool(h), hv.PoolGuid, h, poolstate.DashedHostID(h), hostType, hv.Version, commitDisplay, commitURLVal, projectCommitURL, hv.BaseURL, cycleStartUtc, cfu, hv.StatusLabel(), hv.ControlLabel(), hv.LastSeenUnixMs/1000)
	}
	// Grafana joins the original Loki hostId on this mapping, then groups the
	// cycle counts by canonicalHostId. Include the identity row for every live
	// host so unaliased hosts take the same path. A timestamp value makes the
	// newest mapping win while Prometheus still retains a stale prior series.
	b.WriteString("# HELP yuruna_pool_host_canonical_info Maps a current or retired host ID to its live identity for dashboard history grouping.\n# TYPE yuruna_pool_host_canonical_info gauge\n")
	canonicalAt := in.Now.Unix()
	for _, h := range ids {
		if view.Hosts[h] != nil {
			fmt.Fprintf(&b, "yuruna_pool_host_canonical_info{hostId=%q,canonicalHostId=%q} %d\n", h, h, canonicalAt)
		}
	}
	for old := range view.Aliases() {
		canonical := view.CanonicalHostID(old)
		if view.Hosts[canonical] != nil {
			fmt.Fprintf(&b, "yuruna_pool_host_canonical_info{hostId=%q,canonicalHostId=%q} %d\n", old, canonical, canonicalAt)
		}
	}
	// Suppress the retired host_info series during Prometheus's staleness
	// window; its identity mapping above remains so older Loki counts join.
	b.WriteString("# HELP yuruna_pool_host_retired A host ID transferred to another live identity.\n# TYPE yuruna_pool_host_retired gauge\n")
	for old := range view.Aliases() {
		fmt.Fprintf(&b, "yuruna_pool_host_retired{hostId=%q} 1\n", old)
	}
	// host_status: the numeric twin of host_info's status, keyed on hostId so it
	// forms one continuous series per host -- the input the state-timeline panel
	// needs. No hostname label (pool view is hostname-free). 0=unreachable
	// 1=running 2=pass 3=fail 4=idle 5=paused 6=pausing-cycle 7=pausing-step
	// 8=stopped 9=preflight-failed.
	b.WriteString("# HELP yuruna_pool_host_status Per-host state code (0=unreachable 1=running 2=pass 3=fail 4=idle 5=paused 6=pausing-cycle 7=pausing-step 8=stopped 9=preflight-failed).\n# TYPE yuruna_pool_host_status gauge\n")
	for _, h := range ids {
		hv := view.Hosts[h]
		if hv == nil {
			continue
		}
		fmt.Fprintf(&b, "yuruna_pool_host_status{pool=%q,hostId=%q,hostIdDashed=%q} %d\n", pool(h), h, poolstate.DashedHostID(h), hv.StatusCode())
	}
	// host_refresh_available: whether each host currently advertises a
	// refresh it could run, under the single expiry rule. A gauge of its own
	// rather than a host_info label, because every host_info label becomes a
	// dashboard column. Its labels are bounded enums only -- never a request
	// id, a reason string or a rung list.
	b.WriteString("# HELP yuruna_pool_host_refresh_available Whether the host currently advertises a refresh capability (1 = available, 0 = unavailable), with its request state.\n# TYPE yuruna_pool_host_refresh_available gauge\n")
	refreshNow := in.Now
	for _, h := range ids {
		hv := view.Hosts[h]
		if hv == nil {
			continue
		}
		availability, state := hv.RefreshLabels(refreshNow, in.RefreshTTL)
		value := 0
		if availability == sdkpool.RefreshAvailable {
			value = 1
		}
		fmt.Fprintf(&b, "yuruna_pool_host_refresh_available{pool=%q,hostId=%q,hostIdDashed=%q,state=%q} %d\n", pool(h), h, poolstate.DashedHostID(h), state, value)
	}
	// host_last_seen: unix seconds of last successful probe; the table shows age
	// as `time() - this`. Keeps climbing for an unreachable-but-not-yet-evicted
	// host, which is exactly the "last seen 5m ago" signal an operator wants.
	b.WriteString("# HELP yuruna_pool_host_last_seen_seconds Unix time of the last successful status probe for this host.\n# TYPE yuruna_pool_host_last_seen_seconds gauge\n")
	for _, h := range ids {
		hv := view.Hosts[h]
		if hv == nil {
			continue
		}
		fmt.Fprintf(&b, "yuruna_pool_host_last_seen_seconds{pool=%q,hostId=%q} %d\n", pool(h), h, hv.LastSeenUnixMs/1000)
	}

	// Address footprint gauges: numbers rather than log lines, with -1 (no
	// record) kept apart from 0 (bounded). See https://yuruna.link/42c29d04-0015.
	b.WriteString("# HELP yuruna_pool_host_address_changes Address changes this host recorded in its beacon lookback window (-1 = no record; the beacon is not running there).\n# TYPE yuruna_pool_host_address_changes gauge\n")
	for _, h := range ids {
		if fp, ok := view.Footprint(h); ok && view.Hosts[h] != nil {
			fmt.Fprintf(&b, "yuruna_pool_host_address_changes{pool=%q,hostId=%q,hostIdDashed=%q} %d\n", pool(h), h, poolstate.DashedHostID(h), fp.Changes)
		}
	}
	b.WriteString("# HELP yuruna_pool_host_address_distinct Distinct addresses this host held in its beacon lookback window; 1 is a bounded host.\n# TYPE yuruna_pool_host_address_distinct gauge\n")
	for _, h := range ids {
		if fp, ok := view.Footprint(h); ok && view.Hosts[h] != nil {
			fmt.Fprintf(&b, "yuruna_pool_host_address_distinct{pool=%q,hostId=%q,hostIdDashed=%q} %d\n", pool(h), h, poolstate.DashedHostID(h), fp.Distinct)
		}
	}
	// The verdict rides as a LABEL rather than an encoded number: its four
	// values name four different faults, and an operator reading a panel should
	// not have to hold a code table to tell "renewal-churn" from "stable".
	b.WriteString("# HELP yuruna_pool_host_address_footprint Per-host address-footprint verdict and DHCP identity pin (value always 1).\n# TYPE yuruna_pool_host_address_footprint gauge\n")
	for _, h := range ids {
		fp, ok := view.Footprint(h)
		if !ok || view.Hosts[h] == nil {
			continue
		}
		pinned := "unknown"
		switch fp.Pinned {
		case 1:
			pinned = "yes"
		case 0:
			pinned = "no"
		}
		fmt.Fprintf(&b, "yuruna_pool_host_address_footprint{pool=%q,hostId=%q,hostIdDashed=%q,verdict=%q,severity=%q,pinned=%q,backend=%q} 1\n",
			pool(h), h, poolstate.DashedHostID(h), fp.Verdict, fp.Severity, pinned, fp.Backend)
	}
	// The lab-wide number, and the one that actually predicts exhaustion: a
	// per-host count can look healthy on every host while the fleet still
	// drains the pool, because what runs out is shared. Summed over the hosts
	// that HAVE a reading -- a host with none is unmeasured, and adding a zero
	// for it would understate the total in the one direction that matters.
	labDistinct, measured := 0, 0
	for _, h := range ids {
		if fp, ok := view.Footprint(h); ok && view.Hosts[h] != nil {
			labDistinct += fp.Distinct
			measured++
		}
	}
	fmt.Fprintf(&b, "# HELP yuruna_pool_address_distinct_total Distinct addresses held across all reporting hosts in their beacon lookback windows.\n# TYPE yuruna_pool_address_distinct_total gauge\nyuruna_pool_address_distinct_total %d\n", labDistinct)
	fmt.Fprintf(&b, "# HELP yuruna_pool_address_hosts_measured Hosts reporting an address footprint; below hosts_total, the lab-wide figure understates the truth.\n# TYPE yuruna_pool_address_hosts_measured gauge\nyuruna_pool_address_hosts_measured %d\n", measured)
	// The one that predicts exhaustion. Every guest reaches the internet through
	// this proxy, so its client addresses ARE the lab's address consumption --
	// hosts, service VMs and the guest fleet together, which no host-reported
	// figure covers. Multiply by the lease in days to get the pool size this
	// lab needs; if that exceeds the scope, it runs dry on a schedule.
	addr := view.AddressCounts()
	scanComplete := 0
	if addr.Complete {
		scanComplete = 1
	}
	fmt.Fprintf(&b, "# HELP yuruna_pool_lab_addresses_in_use Measured count of addresses the lab is holding: caching-proxy clients seen in the scan window UNION every known host's current address (deduplicated). A floor, not a ceiling -- anything that neither proxies nor registers as a host is invisible here. Says nothing about the DHCP pool: free leases and scope size live on the server.\n# TYPE yuruna_pool_lab_addresses_in_use gauge\nyuruna_pool_lab_addresses_in_use %d\n", addr.InUse)
	fmt.Fprintf(&b, "# HELP yuruna_pool_lab_addresses_in_use_hosts The host-record half of yuruna_pool_lab_addresses_in_use -- addresses known from host registrations rather than from the proxy log, so this half survives the proxy being down and covers statically-addressed hosts that hold no lease at all.\n# TYPE yuruna_pool_lab_addresses_in_use_hosts gauge\nyuruna_pool_lab_addresses_in_use_hosts %d\n", addr.InUseHosts)
	fmt.Fprintf(&b, "# HELP yuruna_pool_lab_distinct_addresses_24h Distinct client addresses seen by the caching proxy in the scan window. A rate of address use, NOT a pool forecast: converting it into one needs the lease period and scope size, which this service is not given.\n# TYPE yuruna_pool_lab_distinct_addresses_24h gauge\nyuruna_pool_lab_distinct_addresses_24h %d\n", addr.Distinct)
	fmt.Fprintf(&b, "# HELP yuruna_pool_lab_distinct_addresses_complete 1 when the 24h scan reached the far end of its window; 0 means the count above is a floor, not a measurement.\n# TYPE yuruna_pool_lab_distinct_addresses_complete gauge\nyuruna_pool_lab_distinct_addresses_complete %d\n", scanComplete)

	// Extension hosts: one row per (hostId, area) actively running an extension
	// function, from host registrations and service announces. target rides as
	// a label (a hidden URL column the dashboard links); baseUrl rides unlinked.
	// See https://yuruna.link/42c29d04-0007.
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
	// The rows come from the one merge of the registration and announce
	// sources; an announce-only row still carries baseUrl when the host is at
	// least known. See https://yuruna.link/42c29d04-0007.
	extRows := make([]extRow, 0, len(in.Extensions))
	for _, c := range in.Extensions {
		baseURL := ""
		if hv := view.Hosts[c.HostID]; hv != nil {
			baseURL = hv.BaseURL
		}
		extRows = append(extRows, extRow{
			host: c.HostID, area: c.Area, baseURL: baseURL, target: c.Target,
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
			fmt.Fprintf(&b, "yuruna_pool_extension_unreachable{pool=%q,hostId=%q,area=%q,target=%q,reason=%q} 1\n", pool(e.host), e.host, e.area, e.refused, e.reason)
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
			// goPath is the dashboard's link for this row, ready-made. The Extension
			// cell cannot build it from the columns beside it: a Grafana data link
			// interpolates a field's DISPLAYED value, and that column is value-mapped
			// to prose ("Download-agent service"), so ${__data.fields.Extension} would
			// put the label where the area slug belongs. Precomputing it here is the
			// same answer the hidden baseUrl and target columns already are.
			goPath := "/go/stash?host=" + url.QueryEscape(e.host) + "&area=" + url.QueryEscape(e.area)
			fmt.Fprintf(&b, "yuruna_pool_host_extension{pool=%q,hostId=%q,hostIdDashed=%q,area=%q,baseUrl=%q,target=%q,goPath=%q} 1\n", pool(e.host), e.host, poolstate.DashedHostID(e.host), e.area, e.baseURL, e.target, goPath)
		}
		b.WriteString("# HELP yuruna_pool_host_extension_last_seen_seconds Unix time this extension host was last confirmed (host probe or service announce).\n# TYPE yuruna_pool_host_extension_last_seen_seconds gauge\n")
		for _, e := range extRows {
			fmt.Fprintf(&b, "yuruna_pool_host_extension_last_seen_seconds{pool=%q,hostId=%q,area=%q} %d\n", pool(e.host), e.host, e.area, e.lastSeen)
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
				fmt.Fprintf(&b, "yuruna_pool_extension_target_disagreement{pool=%q,hostId=%q,area=%q,target=%q,superseded=%q} 1\n", pool(e.host), e.host, e.area, e.target, e.superseded)
			}
		}
	}

	// Lab connection token: the dashboard's "Lab token" tile reads the CURRENT
	// code as a label (the info-metric pattern host_extension uses -- the only
	// channel the provisioned Prometheus/Loki datasources offer for a string).
	// How many lines wait for Loki: zero in a steady pool, climbing while Loki is
	// away. durable says whether they survive a restart of this daemon.
	if in.Outbox != nil {
		durable := 0
		if in.Outbox.Durable {
			durable = 1
		}
		fmt.Fprintf(&b, "# HELP yuruna_pool_loki_outbox_pending Lines the collector holds until Loki accepts them.\n# TYPE yuruna_pool_loki_outbox_pending gauge\nyuruna_pool_loki_outbox_pending{pool=%q,durable=\"%d\"} %d\n", in.Pool, durable, in.Outbox.Pending)
	}
	// Exported only while the exchange is live, so a disabled feature shows
	// "No data" rather than a stale, unredeemable code. Label churn is one tiny
	// series per rotation.
	if labCodes := view.LabCodes(); in.LabTokenLive && len(labCodes) > 0 {
		fmt.Fprintf(&b, "# HELP yuruna_pool_lab_token Current lab connection token for enrolling a host (value always 1).\n# TYPE yuruna_pool_lab_token gauge\nyuruna_pool_lab_token{pool=%q,token=%q} 1\n", in.Pool, labCodes[0])
		b.WriteString("# HELP yuruna_pool_lab_token_exchanges_total Lab-token exchange attempts by outcome.\n# TYPE yuruna_pool_lab_token_exchanges_total counter\n")
		for _, oc := range []string{"ok", "refused", "throttled"} {
			fmt.Fprintf(&b, "yuruna_pool_lab_token_exchanges_total{pool=%q,outcome=%q} %d\n", in.Pool, oc, view.LabExchangeCount(oc))
		}
	}

	// Incident correlation signals (N-failures-in-M-minutes).
	fmt.Fprintf(&b, "# HELP yuruna_pool_incidents_active Hosts currently in an incident (>= incidentN fails within the window).\n# TYPE yuruna_pool_incidents_active gauge\nyuruna_pool_incidents_active %d\n", len(view.Incident))
	b.WriteString("# HELP yuruna_pool_host_incident 1 if the host is currently in an incident, else 0.\n# TYPE yuruna_pool_host_incident gauge\n")
	for _, h := range ids {
		v := 0
		if view.Incident[h] != nil {
			v = 1
		}
		fmt.Fprintf(&b, "yuruna_pool_host_incident{pool=%q,hostId=%q} %d\n", pool(h), h, v)
	}
	// host_incident_info carries the dominant failure class of an active incident as a
	// label (the 0/1 gauge above stays class-free so its sum() tile is unaffected);
	// emitted only for hosts currently in an incident. Mirrors host_info.
	b.WriteString("# HELP yuruna_pool_host_incident_info Dominant failure class of a host's active incident (value always 1).\n# TYPE yuruna_pool_host_incident_info gauge\n")
	for _, h := range ids {
		if inc := view.Incident[h]; inc != nil {
			cls := inc.DominantClass
			if cls == "" {
				cls = "unknown"
			}
			fmt.Fprintf(&b, "yuruna_pool_host_incident_info{pool=%q,hostId=%q,class=%q} 1\n", pool(h), h, cls)
		}
	}
	b.WriteString("# HELP yuruna_pool_host_recent_fail_count Failed cycles for this host within the incident window.\n# TYPE yuruna_pool_host_recent_fail_count gauge\n")
	for _, h := range ids {
		fmt.Fprintf(&b, "yuruna_pool_host_recent_fail_count{pool=%q,hostId=%q} %d\n", pool(h), h, len(view.FailWindow[h]))
	}
	// Cross-host (pool-wide) incident: _wide_incident is the hysteresis state set
	// by View.EvaluateIncidents; _wide_incident_hosts is the instantaneous count of
	// distinct hosts that failed within crossWin.
	poolInc := 0
	if view.PoolIncident != nil {
		poolInc = 1
	}
	// Window this count against the last completed poll's clock (not scrape
	// time) so it stays consistent with the latched yuruna_pool_wide_incident
	// above: View.EvaluateIncidents decides that flag at the poll using the same
	// window, so a scrape-time cut would let hosts age out and disagree with a
	// still-set flag between polls. Before the first poll LastPoll is zero, but a
	// Loki rehydrate can already have seeded failWindow and restored the
	// incident, so fall back to scrape time there to report the true recent
	// count rather than a forced zero that would disagree with the restored flag.
	ref := view.LastPoll()
	if ref.IsZero() {
		ref = in.Now.UTC()
	}
	crossCut := ref.Add(-in.CrossWindow)
	recentHosts := 0
	for _, fw := range view.FailWindow {
		if len(fw) > 0 && fw[len(fw)-1].At.After(crossCut) {
			recentHosts++
		}
	}
	fmt.Fprintf(&b, "# HELP yuruna_pool_wide_incident 1 if a pool-wide (cross-host) incident is active.\n# TYPE yuruna_pool_wide_incident gauge\nyuruna_pool_wide_incident %d\n", poolInc)
	fmt.Fprintf(&b, "# HELP yuruna_pool_wide_incident_hosts Distinct hosts that failed within the cross-host window.\n# TYPE yuruna_pool_wide_incident_hosts gauge\nyuruna_pool_wide_incident_hosts %d\n", recentHosts)
	// wide_incident_info carries the pinned same-class of an active pool-wide incident
	// as a label (the 0/1 gauge above stays class-free); emitted only when active.
	b.WriteString("# HELP yuruna_pool_wide_incident_info Pinned failure class of the active pool-wide incident (value always 1).\n# TYPE yuruna_pool_wide_incident_info gauge\n")
	if view.PoolIncident != nil {
		cls := view.PoolIncident.Class
		if cls == "" {
			cls = "unknown"
		}
		fmt.Fprintf(&b, "yuruna_pool_wide_incident_info{pool=%q,class=%q} 1\n", in.Pool, cls)
	}
	// Pool gating: advisory degraded/alert latch + the quorum inputs (keyed by pool
	// only -- low cardinality). _members_*/_healthy_fraction/_healthy_threshold/
	// _degraded are emitted for every pool with a member (observability); _alert_active
	// only for pools that authored a gating block (the host-side notifier reads ==1 to
	// deliver), so an un-configured pool is observed but never paged.
	gatePools := make([]string, 0, len(view.PoolGate))
	for p := range view.PoolGate {
		gatePools = append(gatePools, p)
	}
	sort.Strings(gatePools)
	b.WriteString("# HELP yuruna_pool_members_total Pool members currently in the view (within hostTtl).\n# TYPE yuruna_pool_members_total gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_members_total{pool=%q} %d\n", p, view.PoolGate[p].LastTotal)
	}
	b.WriteString("# HELP yuruna_pool_members_healthy Pool members counted healthy (reachable, not in an incident, and running, pass, idle, stopped or pending a pause).\n# TYPE yuruna_pool_members_healthy gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_members_healthy{pool=%q} %d\n", p, view.PoolGate[p].LastHealthy)
	}
	b.WriteString("# HELP yuruna_pool_healthy_fraction Fraction of pool members counted healthy on the last poll.\n# TYPE yuruna_pool_healthy_fraction gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_healthy_fraction{pool=%q} %g\n", p, view.PoolGate[p].LastFraction)
	}
	b.WriteString("# HELP yuruna_pool_healthy_threshold Configured healthy-fraction threshold (default 0.5); a Grafana rule needs no hardcode.\n# TYPE yuruna_pool_healthy_threshold gauge\n")
	for _, p := range gatePools {
		fmt.Fprintf(&b, "yuruna_pool_healthy_threshold{pool=%q} %g\n", p, view.PoolGate[p].LastThreshold)
	}
	b.WriteString("# HELP yuruna_pool_degraded 1 if the healthy fraction stayed below the threshold for >= degradedAfterSeconds (advisory).\n# TYPE yuruna_pool_degraded gauge\n")
	for _, p := range gatePools {
		v := 0
		if view.PoolGate[p].Degraded {
			v = 1
		}
		fmt.Fprintf(&b, "yuruna_pool_degraded{pool=%q} %d\n", p, v)
	}
	b.WriteString("# HELP yuruna_pool_alert_active 1 if the pool's degraded alert is latched (authored-gating pools only).\n# TYPE yuruna_pool_alert_active gauge\n")
	for _, p := range gatePools {
		if !view.PoolGate[p].Authored {
			continue
		}
		v := 0
		if view.PoolGate[p].AlertFired {
			v = 1
		}
		fmt.Fprintf(&b, "yuruna_pool_alert_active{pool=%q} %d\n", p, v)
	}

	b.WriteString("# HELP yuruna_pool_cycles_pass_total Terminal passing cycles observed.\n# TYPE yuruna_pool_cycles_pass_total counter\n")
	for _, h := range ids {
		var total int64
		for source, n := range passTotals {
			if view.CanonicalHostID(source) == h {
				total += n
			}
		}
		fmt.Fprintf(&b, "yuruna_pool_cycles_pass_total{pool=%q,hostId=%q} %d\n", pool(h), h, total)
	}
	b.WriteString("# HELP yuruna_pool_cycles_fail_total Terminal failing cycles observed.\n# TYPE yuruna_pool_cycles_fail_total counter\n")
	for _, h := range ids {
		var total int64
		for source, n := range failTotals {
			if view.CanonicalHostID(source) == h {
				total += n
			}
		}
		fmt.Fprintf(&b, "yuruna_pool_cycles_fail_total{pool=%q,hostId=%q} %d\n", pool(h), h, total)
	}
	// Materialize the metrics text and release the lock before writing to the client, so a slow
	// scraper connection cannot hold the view's lock across the network write and stall the
	// poll goroutine (mirrors handlePoolStatus).
	return b.String()
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

// CommitCells derives the pool table's Commit column from a host's status.json
// gitCommits (framework first, project second by the runner's convention).
// Returns the display string (8-char short SHAs, comma-joined, both repos) plus
// the framework and project commit deep-link URLs the table's two data-links
// resolve; any return is "" when the host has not reported that piece. The
// short-SHA + link policy mirrors the host status page's Commit block
// (renderCommitLinks in yuruna.common.js) so the pool view and the host page
// agree on what a commit looks like and when it is clickable.
func CommitCells(st *hostpoll.HostStatus) (display, frameworkURL, projectURL string) {
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
		// Keep persisted verification codes compatible with older hosts while
		// presenting the same concise labels as the host status page.
		label := ""
		switch c.Verification {
		case "origin-direct":
			label = "remote.origin"
		case "mirror-confirmed":
			label = "mirror.origin"
		case "mirror-stale":
			label = "mirror.stale"
		case "mirror-fresh":
			label = "mirror.fresh"
		case "not-applicable":
			label = "not.applicable"
		}
		if label != "" {
			short += " [" + label + "]"
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
