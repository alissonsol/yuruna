// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42a37827-f82f-44ec-abbb-5c6d391280d4

package routes

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/extensions"
	"yuruna.com/test/extension/pool-aggregator-service/internal/feed"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/httpserve"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The event feed's bounds and scrub, the announce gates and the presence and
// announce lines; these names keep the write surfaces readable.
const (
	maxEventFetch = feed.MaxEventFetch
	maxEventPush  = feed.MaxEventPush
	maxAnnounce   = extensions.MaxAnnounce
)

var (
	redactEventLine  = feed.RedactEventLine
	pushHostAnnounce = feed.PushHostAnnounce
	pushAnnounce     = feed.PushAnnounce
	announceHostIDRE = extensions.AnnounceHostIDRE
	announceAreaRE   = extensions.AnnounceAreaRE
)

const maxAnnounceBody = 4 << 10 // bytes read from one announce POST

// ingestLineHostID extracts the hostId field from one pushed NDJSON event line, or
// "" when absent/unparseable. Used to reject a line whose claimed hostId disagrees
// with the IP-resolved sender identity (a member may push only its own events).
func ingestLineHostID(ln string) string {
	var e struct {
		HostId string `json:"hostId"`
	}
	if json.Unmarshal([]byte(ln), &e) == nil {
		return e.HostId
	}
	return ""
}

// HandleIngest is the push surface: a runner-side forwarder POSTs its cycle's
// NDJSON event lines so they reach Loki before the next pull, whose copy Loki
// drops as an exact duplicate. Disabled (503) with no internal key; the bearer is
// checked in constant time before the body is read; {pool,hostId} are bound from
// the sender's source address, never the body, and a body hostId that disagrees
// is refused; lines are redacted and capped as on the pull side. Telemetry only.
// See https://yuruna.link/42c29d04-0021.
func (s *Server) HandleIngest(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.ingest_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.RequireInternalBearer(w, r) {
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxEventFetch))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	// Scan the body incrementally (NOT strings.Split, which would materialize every line
	// before the cap can fire): stop the moment the running line count would exceed
	// maxEventPush, so a million-tiny-line body can't burn parse/alloc work past the cap
	// (mirrors the pull-side TailEvents scan). Collect the batch's body hostId for identity
	// binding; a batch that mixes hostIds is rejected.
	var lines []string
	bodyHostID := ""
	mixed := false
	consumed := 0
	for consumed < len(body) {
		var ln string
		if nl := bytes.IndexByte(body[consumed:], '\n'); nl < 0 {
			ln = strings.TrimRight(string(body[consumed:]), "\r")
			consumed = len(body)
		} else {
			ln = strings.TrimRight(string(body[consumed:consumed+nl]), "\r")
			consumed += nl + 1
		}
		if ln == "" {
			continue
		}
		if len(lines) >= maxEventPush {
			localizedHTTPError(w, r, "aggregator.too_many_lines", http.StatusRequestEntityTooLarge)
			return
		}
		if bid := ingestLineHostID(ln); bid != "" {
			if bodyHostID == "" {
				bodyHostID = bid
			} else if bodyHostID != bid {
				mixed = true
			}
		}
		lines = append(lines, redactEventLine(ln))
	}
	if mixed {
		localizedHTTPError(w, r, "aggregator.batch_mixes_multiple_hostids", http.StatusForbidden)
		return
	}
	if len(lines) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// Identity binding (the anti-forgery control): resolve {pool,hostId} from the SOURCE IP
	// against the pull-discovered view, NOT the body. Hosts currently at this IP:
	//   * a body hostId MUST be one of them (else the IP doesn't own that hostId -> reject);
	//   * with no body hostId, bind only when exactly one host sits at this IP (a shared IP
	//     without a hostId is ambiguous -> reject). Empty CurrentIP never matches.
	hostID := ""
	poolLabel := ""
	s.st.Do(func(view *poolstate.View) {
		var atIP []string
		for hid, hv := range view.Hosts {
			if hv.CurrentIP != "" && hv.CurrentIP == srcIP {
				atIP = append(atIP, hid)
			}
		}
		if bodyHostID != "" {
			for _, hid := range atIP {
				if hid == bodyHostID {
					hostID = hid
					break
				}
			}
		} else if len(atIP) == 1 {
			hostID = atIP[0]
		}
		if hostID != "" {
			poolLabel = s.poolFor(view, hostID)
		}
	})
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.sender_identity_could_not_be_bound_undiscovered_ip_hostid_not_own", http.StatusForbidden)
		return
	}
	// 202 means held, not merely received: the pusher advances its own cursor on
	// it. A full outbox is backpressure the pusher waits out; a line the outbox
	// could not write is a fault on this machine, answered under its own code so the
	// two are told apart at the pusher and in its log.
	if err := s.PushEvents(s.httpClient, s.lokiURL, poolLabel, hostID, lines, time.Now().UTC()); err != nil && s.outbox != nil {
		if errors.Is(err, loki.ErrFull) {
			localizedHTTPError(w, r, "aggregator.ingest_queue_full", http.StatusServiceUnavailable)
		} else {
			localizedHTTPError(w, r, "aggregator.ingest_not_recorded", http.StatusServiceUnavailable)
		}
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// HandleHostAnnounce is the host-presence write surface: a host POSTs its own
// hostId when its address changes, on service start and on a periodic beacon,
// so the pool view follows it across a DHCP renumber. The address comes from
// the connection and the claim is confirmed against that address's
// /runtime/status.json before any host row moves. See https://yuruna.link/42c29d04-0003.
func (s *Server) HandleHostAnnounce(w http.ResponseWriter, r *http.Request) {
	if s.announceTtl <= 0 {
		localizedHTTPError(w, r, "aggregator.announce_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAnnounceBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var a struct {
		HostId     string `json:"hostId"`
		StatusPort int    `json:"statusPort"`
	}
	if err := json.Unmarshal(body, &a); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_announce", http.StatusBadRequest)
		return
	}
	if !announceHostIDRE.MatchString(a.HostId) {
		localizedHTTPError(w, r, "aggregator.invalid_hostid", http.StatusBadRequest)
		return
	}
	if a.StatusPort <= 0 || a.StatusPort > 65535 {
		localizedHTTPError(w, r, "aggregator.invalid_statusport", http.StatusBadRequest)
		return
	}
	baseURL := fmt.Sprintf("http://%s:%d", srcIP, a.StatusPort)
	if problem := extensionTargetProblem(baseURL); problem != "" {
		http.Error(w, problem, http.StatusBadRequest)
		return
	}

	// The confirm. Reuses the poll's own fetch so an announced host is admitted
	// on exactly the evidence a discovered one is, and refuses the announce
	// when the identity does not match what that address actually serves.
	st, _, err := hostpoll.FetchStatus(s.httpClient, baseURL)
	if err != nil {
		localizedHTTPError(w, r, "aggregator.announced_address_did_not_serve_status_json", http.StatusBadRequest)
		return
	}
	if st == nil || !strings.EqualFold(st.HostId, a.HostId) {
		localizedHTTPError(w, r, "aggregator.announced_address_serves_a_different_hostid", http.StatusBadRequest)
		return
	}

	now := time.Now().UTC()
	// Startup rehydrates the presence stream using the collector pool label.
	poolLabel := s.pool
	s.st.Do(func(view *poolstate.View) { view.RelocateHost(a.HostId, srcIP, baseURL, now) })

	// 2xx means recorded, not merely received -- the same contract /announce
	// keeps, and for the same reason: a beacon told 2xx waits a whole period
	// before it announces again, so a 2xx for a line that never reached Loki
	// costs the pool up to a beacon period of a host it cannot resolve after
	// the next restart.
	if err := pushHostAnnounce(s.httpClient, s.lokiURL, poolLabel, a.HostId, baseURL, now); err != nil {
		localizedHTTPError(w, r, "aggregator.announce_accepted_but_not_recorded", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":        true,
		"hostId":    a.HostId,
		"currentIp": srcIP,
		"baseUrl":   baseURL,
	})
}

// HandleHostAddress answers "where is this hostId now" for one host, as one flat
// JSON object a guest can parse with sed during bootstrap. Unlike /go/host it
// mints no control proof and redirects nowhere: a guest must not hold a proof
// for its own host. An unknown host is a 404, not an empty 200.
// See https://yuruna.link/42c29d04-0022.
func (s *Server) HandleHostAddress(w http.ResponseWriter, r *http.Request) {
	hostID := strings.TrimSpace(r.URL.Query().Get("hostId"))
	if !announceHostIDRE.MatchString(hostID) {
		localizedHTTPError(w, r, "aggregator.invalid_hostid", http.StatusBadRequest)
		return
	}
	var out struct {
		HostId    string `json:"hostId"`
		BaseURL   string `json:"baseUrl"`
		CurrentIP string `json:"currentIp"`
		Reachable bool   `json:"reachable"`
	}
	found := false
	s.st.Do(func(view *poolstate.View) {
		hv := view.Hosts[hostID]
		found = hv != nil && hv.BaseURL != ""
		if found {
			// Field order is not cosmetic: hostId and baseUrl stay adjacent and
			// ahead of anything nested, because the guest resolver's fallback leg
			// splits pool-status on '{' and requires both keys on one fragment.
			// Reordering hostView's first fields silently breaks that parser.
			out.HostId = hv.HostId
			out.BaseURL = hv.BaseURL
			out.CurrentIP = hv.CurrentIP
			out.Reachable = hv.Reachable
		}
	})
	if !found {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	// An address lookup is the one answer in this framework that must never be
	// served from a cache: the whole point is that it changes.
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(out)
}

// HandleAnnounce is the extension-presence write surface: service VMs POST
// {hostId, area, targetPort, active} beacons so the dashboard's Extension
// hosts row survives the owning host's status service being down. Open by
// design but contained (self-identity binding; goodbyes also match an
// address-less rehydrated entry). See docs/extensions-api.md (POST /announce).
func (s *Server) HandleAnnounce(w http.ResponseWriter, r *http.Request) {
	if s.announceTtl <= 0 {
		localizedHTTPError(w, r, "aggregator.announce_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAnnounceBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var a struct {
		HostId     string `json:"hostId"`
		Area       string `json:"area"`
		Target     string `json:"target"`
		TargetPort int    `json:"targetPort"`
		Active     *bool  `json:"active"`
	}
	if err := json.Unmarshal(body, &a); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_announce", http.StatusBadRequest)
		return
	}
	if a.Area == "" {
		a.Area = StashArea
	}
	if !announceHostIDRE.MatchString(a.HostId) || !announceAreaRE.MatchString(a.Area) {
		localizedHTTPError(w, r, "aggregator.invalid_hostid_or_area", http.StatusBadRequest)
		return
	}
	// Resolve the advertised service URL. An explicit target must point at the
	// SENDER (URL host == source IP) -- the announcer advertises itself, never a
	// third party; otherwise the URL is derived from the source IP + the
	// announced UI port (no port advertised -> presence only, no link).
	target := ""
	switch {
	case strings.TrimSpace(a.Target) != "":
		target = strings.TrimRight(strings.TrimSpace(a.Target), "/")
		u, perr := url.Parse(target)
		if perr != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
			localizedHTTPError(w, r, "aggregator.invalid_target_url", http.StatusBadRequest)
			return
		}
		if u.Hostname() != srcIP {
			localizedHTTPError(w, r, "aggregator.target_host_must_be_the_announcing_address", http.StatusForbidden)
			return
		}
	case a.TargetPort == 80:
		target = "http://" + srcIP
	case a.TargetPort > 0 && a.TargetPort < 65536:
		target = "http://" + net.JoinHostPort(srcIP, strconv.Itoa(a.TargetPort))
	}
	// The address still has to be one the pool could route to. A sender behind a
	// NAT that rewrites the source address, or a proxy header this handler ever
	// learns to trust, is how a loopback or link-local value would arrive here.
	if why := extensionTargetProblem(target); why != "" {
		localizedHTTPErrorArgs(w, r, "aggregator.invalid_target_address_detail", http.StatusBadRequest, map[string]any{"detail": why})
		return
	}
	active := a.Active == nil || *a.Active
	key := announceKey(a.HostId, a.Area)
	poolLabel := s.pool
	now := time.Now().UTC()
	accepted := true
	ignoredGoodbye := false
	s.st.Do(func(view *poolstate.View) {
		if !active {
			_, ignoredGoodbye = view.Goodbye(a.HostId, a.Area, srcIP)
		} else {
			accepted = view.RecordAnnounce(a.HostId, a.Area, target, srcIP, now, maxAnnounce)
		}
	})
	if ignoredGoodbye {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if !accepted {
		localizedHTTPError(w, r, "aggregator.too_many_announced_extensions", http.StatusTooManyRequests)
		return
	}
	// Confirm a NEWLY announced address right here rather than at the next poll:
	// a service that just came up is then resolvable immediately, which is what
	// a lab bringing up its stash and its cycles together depends on. Costs one
	// bounded probe, and only on an address this aggregator has no verdict for --
	// the steady re-announces of a known address skip it. The address
	// is the sender's own (bound above), so this can only ever probe back at the
	// caller: an open route cannot be turned into a scan of the LAN.
	if active {
		extensions.Confirm(s.st, s.httpClient, key, target, now)
	}
	// Push after the unlock so a slow Loki never stalls the state above; goodbyes
	// are pushed too so the latest line decides restart state. The push outcome is
	// the reply, since a 2xx stops the announcer's retries: a line that did not
	// reach Loki is answered 503 while the entry, live now, is kept. With no Loki
	// configured the push reports success.
	// See https://yuruna.link/42c29d04-0019.
	if err := pushAnnounce(s.httpClient, s.lokiURL, poolLabel, a.HostId, a.Area, target, active, time.Now().UTC()); err != nil {
		localizedHTTPError(w, r, "aggregator.announce_accepted_but_not_durably_recorded_retry", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
