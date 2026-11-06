// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428cad7e-445a-4c60-bc6c-1bbce4351a19

package main

import (
	"net/http"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/extensions"
	"yuruna.com/test/extension/pool-aggregator-service/internal/feed"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
	"yuruna.com/test/extension/pool-aggregator-service/internal/localization"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/metrics"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
	"yuruna.com/test/extension/pool-aggregator-service/internal/rehydrate"
	"yuruna.com/test/extension/pool-aggregator-service/internal/routes"
)

// The names this package's tests reach the collector's internal packages by:
// the wire types, the constants they pin, and the poll, route, restore and
// extension code they drive through a poolState. Production code in this
// package uses none of them.
type (
	runnerFault          = hostpoll.RunnerFault
	controlStatus        = hostpoll.ControlStatus
	gatingPolicy         = incident.GatingPolicy
	hostView             = poolstate.HostView
	announceView         = poolstate.AnnounceView
	extHealthView        = poolstate.ExtHealthView
	addressFootprintView = poolstate.AddressFootprintView
	lokiStream           = loki.Stream
	extensionHostEntry   = extensions.Entry
	promTargetGroup      = routes.PromTargetGroup
	eventCursor          = poll.EventCursor
)

const (
	stepPauseCode          = hostpoll.StepPauseCode
	maxControlStatusBytes  = hostpoll.MaxControlStatusBytes
	controlProofTTL        = hostpoll.ControlProofTTL
	controlProofMaxTTL     = hostpoll.ControlProofMaxTTL
	extSourceRegistration  = extensions.SourceRegistration
	extSourceAnnounce      = extensions.SourceAnnounce
	extensionHealthPath    = extensions.HealthPath
	extensionHealthGrace   = extensions.HealthGrace
	maxEventFetch          = feed.MaxEventFetch
	maxEventPush           = feed.MaxEventPush
	stashArea              = routes.StashArea
	poolControlServiceArea = routes.PoolControlServiceArea
	labKeepCodes           = routes.LabKeepCodes
	labFailLimit           = routes.LabFailLimit
	labFailWindow          = routes.LabFailWindow
	maxLabFailKeys         = routes.MaxLabFailKeys
	labEnvelopeLabel       = routes.LabEnvelopeLabel
	labEnvelopeIters       = routes.LabEnvelopeIters
	addrScanWindow         = poll.AddrScanWindow
	addrScanMaxBytes       = poll.AddrScanMaxBytes
	controlReady           = poolstate.ControlReady
	controlNone            = poolstate.ControlNone
	controlMismatch        = poolstate.ControlMismatch
	controlSkew            = poolstate.ControlSkew
	controlUnknown         = poolstate.ControlUnknown
)

var (
	errControlStatusOversize = hostpoll.ErrControlStatusOversize
	commitCells              = metrics.CommitCells
	announceKey              = poolstate.AnnounceKey
	localizedPages           = localization.Pages
	hostIPFromBaseURL        = hostpoll.HostIPFromBaseURL
	extensionTargetProblem   = extensions.TargetProblem
	probeExtensionTarget     = extensions.Probe
	extensionSourceRank      = extensions.SourceRank
	postToLoki               = feed.Post
	pushHostAnnounce         = feed.PushHostAnnounce
	eventNano                = feed.EventNano
	normalizeHostID          = poolstate.NormalizeHostID
	scanListingForHost       = routes.ScanListingForHost
	pickFolderFromListing    = routes.PickFolderFromListing
	labThrottleKey           = routes.LabThrottleKey
	newLabCode               = routes.NewLabCode
	mintControlProof         = routes.MintControlProof
	verifyControlProof       = routes.VerifyControlProof
	labTokenRE               = routes.LabTokenRE
	distinctClientIPs        = poll.DistinctClientIPs
	fetchRegistration        = poll.FetchRegistration
	classifyControl          = poll.ClassifyControl
)

func (s *poolState) extensionCandidatesLocked(view *poolstate.View, now time.Time) map[string]extensionHostEntry {
	return extensions.Candidates(view, s.announceTtl, now)
}

func (s *poolState) resolveExtensionHostsLocked(view *poolstate.View, now time.Time) map[string]extensionHostEntry {
	return extensions.ResolveHosts(view, s.announceTtl, now)
}

func (s *poolState) refreshExtensionHealth(client *http.Client, now time.Time) {
	extensions.Refresh(s.st, client, s.announceTtl, now)
}

func (s *poolState) pushPresence(client *http.Client, lokiURL, pool, hostID, baseURL string, now time.Time) {
	feed.Sender{Outbox: s.outbox}.PushPresence(client, lokiURL, pool, hostID, baseURL, now)
}

func (s *poolState) applyIncidentLines(streams [][][2]string, now time.Time) int {
	return s.rehydrator().ApplyIncidentLines(streams, now)
}

func (s *poolState) applyPresenceLines(streams [][][2]string, now time.Time) int {
	return s.rehydrator().ApplyPresenceLines(streams, now)
}

func (s *poolState) applyAnnounceLines(streams [][][2]string, now time.Time) int {
	return s.rehydrator().ApplyAnnounceLines(streams, now)
}

func (s *poolState) applyPoolAlertLines(streams []lokiStream) int {
	return s.rehydrator().ApplyPoolAlertLines(streams)
}

func (s *poolState) seedHostStubLocked(view *poolstate.View, hostID, baseURL string, now time.Time) bool {
	return rehydrate.SeedHostStub(view, hostID, baseURL, now)
}

func historyBucketsNewestFirst(body string, limit int) []string {
	return routes.HistoryBucketsNewestFirst(parseListing, body, limit)
}

func (s *poolState) resolveHostBase(hostID, pool string) (base, resolvedPool string) {
	return s.routeServer().ResolveHostBase(hostID, pool)
}

func (s *poolState) lastKnownBaseURL(pool, hostID string) string {
	return s.routeServer().LastKnownBaseURL(pool, hostID)
}

func (s *poolState) archiveCommitted(hostID, cycle string) bool {
	return s.routeServer().ArchiveCommitted(hostID, cycle)
}

func (s *poolState) resolveFolderByArchive(hostID string, t time.Time) string {
	return s.routeServer().ResolveFolderByArchive(hostID, t)
}

func (s *poolState) resolveFolderByListing(baseURL, hostID string, t time.Time) string {
	return s.routeServer().ResolveFolderByListing(baseURL, hostID, t)
}

func (s *poolState) forgetHost(hid string) bool { return s.routeServer().ForgetHost(hid) }

func (s *poolState) handleMetricsBody(w http.ResponseWriter) { s.routeServer().MetricsBody(w) }

func (s *poolState) handleMetricsWithArchiveProbe(w http.ResponseWriter, readable func(string) bool) {
	s.routeServer().MetricsWithArchiveProbe(w, readable)
}

func (s *poolState) pollOnce(client *http.Client, squidLog, lokiURL string, now time.Time) {
	s.poller().Once(client, squidLog, lokiURL, now)
}

func (s *poolState) tailEvents(client *http.Client, lokiURL, poolLabel, hostID, baseURL, cycleID, cycleFolderURL string, now time.Time) {
	s.poller().TailEvents(client, lokiURL, poolLabel, hostID, baseURL, cycleID, cycleFolderURL, now)
}

func (s *poolState) evaluateIncidents(view *poolstate.View, now time.Time) []incidentEvent {
	return s.poller().EvaluateIncidents(view, now)
}

func (s *poolState) evaluatePoolGate(view *poolstate.View, now time.Time) []incidentEvent {
	return s.poller().EvaluatePoolGate(view, now)
}

func (s *poolState) poolFor(view *poolstate.View, hostID string) string {
	return s.poller().PoolFor(view, hostID)
}
