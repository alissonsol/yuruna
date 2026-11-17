// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42c2977a-2698-4ec7-9baf-00a9327e1392

package poll

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/feed"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The event feed's file, bounds and scrub, and the view's record of a host's
// address footprint; these names keep the event tail readable.
const (
	eventsFile    = feed.EventsFile
	maxEventFetch = feed.MaxEventFetch
	maxEventPush  = feed.MaxEventPush
)

var redactEventLine = feed.RedactEventLine

type addressFootprintView = poolstate.AddressFootprintView

// EventCursor tracks how far a host's current-cycle NDJSON event file has been
// shipped to Loki, so a poll only forwards new lines. Reset when the cycleStartUtc
// changes (a new cycle = a new file).
type EventCursor struct {
	CycleStartUtc string
	Offset        int64 // bytes of the events file already shipped
	// LastStamp is the Loki timestamp (Unix nanoseconds) of the last line shipped,
	// which the next line without a timestamp of its own takes; 0 before the
	// first, which takes the cycle's start.
	LastStamp int64
}

// TailEvents pulls a host's current-cycle NDJSON event file
// (<baseUrl>/<cycleFolderUrl>cycle.events.ndjson) and ships the complete lines
// past the per-host byte cursor to Loki under {pool,hostId,src=event}, each
// stamped with the event's own timestamp, and a line without one with the
// timestamp of the line before it in the file (feed.EventStamps). The cursor
// resets when cycleStartUtc changes and advances only once the lines are held.
// Best-effort and bounded; it never blocks the poll.
// See https://yuruna.link/42c29d04-0018.
func (s *Poller) TailEvents(client *http.Client, lokiURL, poolLabel, hostID, baseURL, cycleID, cycleFolderURL string, now time.Time) {
	u := strings.TrimRight(baseURL, "/") + "/" + strings.TrimLeft(cycleFolderURL, "/")
	if !strings.HasSuffix(u, "/") {
		u += "/"
	}
	u += eventsFile

	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return
	}
	cur := s.eventCur[hostID]
	if cur == nil || cur.CycleStartUtc != cycleID {
		cur = &EventCursor{CycleStartUtc: cycleID}
		s.eventCur[hostID] = cur
	}
	if cur.Offset > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", cur.Offset))
	}
	resp, err := client.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusRequestedRangeNotSatisfiable {
		cur.Offset, cur.LastStamp = 0, 0 // the same-cycle file shrank; retry from its current beginning
		return
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		return
	}
	if resp.StatusCode == http.StatusPartialContent {
		if !strings.HasPrefix(resp.Header.Get("Content-Range"), fmt.Sprintf("bytes %d-", cur.Offset)) {
			return
		}
	} else if cur.Offset > 0 {
		// The host may not support Range. Discard the old prefix without retaining
		// it, so the bounded fetch still reaches events past the first 4 MiB.
		if _, err := io.CopyN(io.Discard, resp.Body, cur.Offset); err != nil {
			if err == io.EOF {
				cur.Offset, cur.LastStamp = 0, 0
			}
			return
		}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxEventFetch))
	if err != nil {
		return
	}

	if len(body) == 0 {
		return
	}
	chunk := body
	// Ship only COMPLETE lines (ending in \n); keep any trailing partial for the
	// next poll by advancing the cursor exactly past the bytes we forward.
	var lines []string
	consumed := 0
	for consumed < len(chunk) {
		nl := bytes.IndexByte(chunk[consumed:], '\n')
		if nl < 0 {
			break
		}
		ln := strings.TrimRight(string(chunk[consumed:consumed+nl]), "\r")
		consumed += nl + 1
		if ln != "" {
			lines = append(lines, redactEventLine(ln))
		}
		if len(lines) >= maxEventPush {
			break
		}
	}
	if len(lines) == 0 {
		cur.Offset += int64(consumed)
		return
	}
	s.applyFootprintLines(hostID, lines, now)
	prev := cur.LastStamp
	if prev == 0 {
		prev = now.UnixNano()
		if t, err := time.Parse(time.RFC3339, cycleID); err == nil {
			prev = t.UnixNano()
		}
	}
	stamps := feed.EventStamps(lines, prev)
	// The cursor moves past these bytes only once their lines are held for Loki;
	// otherwise the next poll reads and sends them again (Loki drops the exact
	// duplicates a partial earlier attempt may have delivered).
	if err := s.PushEventsAt(client, lokiURL, poolLabel, hostID, lines, stamps); err != nil {
		return
	}
	cur.Offset += int64(consumed)
	cur.LastStamp = stamps[len(stamps)-1]
}

// applyFootprintLines picks this host's address-footprint verdict out of the
// event lines already being forwarded, so the reading costs one extra pass over
// bytes that were fetched anyway rather than a second request per host.
//
// Last line wins: the cycle emits one of these at close, so within a chunk the
// newest is the current answer. Takes the view's lock.
func (s *Poller) applyFootprintLines(hostID string, lines []string, now time.Time) {
	var latest *addressFootprintView
	for _, ln := range lines {
		var e struct {
			Event    string `json:"event"`
			Verdict  string `json:"verdict"`
			Severity string `json:"severity"`
			Changes  *int   `json:"changes"`
			Distinct *int   `json:"distinctAddresses"`
			Backend  string `json:"identityBackend"`
			// Pointer, so the tri-state survives the wire: absent/null is "the
			// bridge could not be read", which is a different fact from false
			// and picks a different remedy. A plain bool would silently fold
			// the unreadable case onto "not pinned" and send an operator to fix
			// something that may already be correct.
			Pinned *bool `json:"identityPinned"`
		}
		if json.Unmarshal([]byte(ln), &e) != nil || e.Event != "host_address_footprint" {
			continue
		}
		v := &addressFootprintView{
			Verdict: e.Verdict, Severity: e.Severity, Backend: e.Backend,
			Changes: -1, Distinct: 0, Pinned: -1, Observed: now,
		}
		if e.Changes != nil {
			v.Changes = *e.Changes
		}
		if e.Distinct != nil {
			v.Distinct = *e.Distinct
		}
		if e.Pinned != nil {
			if *e.Pinned {
				v.Pinned = 1
			} else {
				v.Pinned = 0
			}
		}
		latest = v
	}
	if latest == nil {
		return
	}
	s.st.Do(func(view *poolstate.View) { view.SetFootprint(hostID, *latest) })
}

// UnreachableGrace is how long a host the poll has reached may go without
// answering before host_unreachable records it: longer than a status service
// takes to restart, and far inside the host TTL.
const UnreachableGrace = 5 * time.Minute

// observedEvent is one line the poll writes from its own observation of a host
// (feed.ObservedEventPayload), captured under the view's lock and queued after
// it is released. rearm, when set, takes back the record that the line went
// out, so a line that could not be queued is built and queued again by a later
// poll. See https://yuruna.link/42c29d04-0025.
type observedEvent struct {
	hostID  string
	payload map[string]any
	rearm   func(hv *poolstate.HostView)
}

// runnerLostEvent records a runner that died mid-cycle while its host kept
// answering, once per runner: the episode key names the runner by its pid and
// its start time from the host's exit report, or by its pid and the cycle start
// in the host's status when the host reports none, and hv.LostEpisode holds the
// key already queued. The line names a cycle only while status.json shows one
// in progress; the fallback key still uses the status's cycle start, which
// nothing rewrites while the runner stays dead.
// See https://yuruna.link/42c29d04-0025. Called under the view's lock.
func runnerLostEvent(pool, hostID string, hv *poolstate.HostView, rs runnerStatus, st *hostStatus, now time.Time) (observedEvent, bool) {
	start := st.CycleStartUtc
	fields := map[string]any{"pid": rs.Pid, "runnerStartedUtc": nil, "signal": nil, "signalAtUtc": nil,
		"hostRestarted": nil, "terminalProgram": nil, "sshSession": nil, "cycleStartUtc": nil, "cycleFolderUrl": nil}
	if x := rs.LastExit; x != nil {
		start = x.StartedUtc
		fields["runnerStartedUtc"], fields["signal"], fields["signalAtUtc"] = x.StartedUtc, x.Signal, x.SignalAtUtc
		fields["hostRestarted"], fields["terminalProgram"], fields["sshSession"] = x.HostRestarted, x.TerminalProgram, x.SSHSession
	}
	key := fmt.Sprintf("%s/%d/%s", hostID, rs.Pid, start)
	if key == hv.LostEpisode {
		return observedEvent{}, false
	}
	fields["episodeKey"] = key
	if st.OverallStatus == "running" && st.CycleFolderUrl != "" {
		fields["cycleStartUtc"], fields["cycleFolderUrl"] = st.CycleStartUtc, st.CycleFolderUrl
	}
	hv.LostEpisode = key
	return observedEvent{hostID: hostID, payload: feed.ObservedEventPayload(pool, hostID, "runner_lost", fields, now),
		rearm: func(hv *poolstate.HostView) {
			if hv.LostEpisode == key {
				hv.LostEpisode = ""
			}
		}}, true
}

// hostUnreachableEvent records, once per stretch without an answer, a host the
// poll reached in this run that has not answered for UnreachableGrace. A host
// only seeded from Loki has no status and is never reported: when it was last
// seen is not known here. Called under the view's lock.
func hostUnreachableEvent(pool, hostID string, hv *poolstate.HostView, now time.Time) (observedEvent, bool) {
	if hv.Status == nil || hv.UnreachableReported || now.UnixMilli()-hv.LastSeenUnixMs < UnreachableGrace.Milliseconds() {
		return observedEvent{}, false
	}
	hv.UnreachableReported = true
	fields := map[string]any{"lastSeenUtc": unixMsUTC(hv.LastSeenUnixMs), "lastIp": hv.CurrentIP, "lastError": hv.LastError}
	return observedEvent{hostID: hostID, payload: feed.ObservedEventPayload(pool, hostID, "host_unreachable", fields, now),
		rearm: func(hv *poolstate.HostView) { hv.UnreachableReported = false }}, true
}

// hostDroppedEvent records a host the host TTL removes from the view. lastSeenUtc
// is null for a host only seeded from Loki that never answered in this run: its
// record's time is the seed's, not a sighting. The record leaves with the drop,
// so the line is not rebuilt when it cannot be queued. Called under the view's
// lock.
func hostDroppedEvent(pool, hostID string, hv *poolstate.HostView, ttl time.Duration, now time.Time) observedEvent {
	fields := map[string]any{"lastSeenUtc": nil, "ttlSeconds": int64(ttl / time.Second)}
	if hv.Status != nil {
		fields["lastSeenUtc"] = unixMsUTC(hv.LastSeenUnixMs)
	}
	return observedEvent{hostID: hostID, payload: feed.ObservedEventPayload(pool, hostID, "host_dropped", fields, now)}
}

func unixMsUTC(ms int64) string { return time.UnixMilli(ms).UTC().Format(time.RFC3339) }

// queueObserved queues the observed lines after the view's lock is released and
// re-arms each one that could not be queued.
func (s *Poller) queueObserved(client *http.Client, lokiURL string, events []observedEvent) {
	for _, ev := range events {
		if err := s.Queue(client, lokiURL, ev.payload, "event push"); err != nil && ev.rearm != nil {
			s.st.Do(func(view *poolstate.View) {
				if hv := view.Hosts[ev.hostID]; hv != nil {
					ev.rearm(hv)
				}
			})
		}
	}
}
