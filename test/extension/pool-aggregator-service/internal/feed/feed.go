// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42d5ce46-6c68-4527-82ad-229e68f96ba3

// Package feed builds and sends the collector's Loki lines: the cycle
// transitions, the presence and announce beacons, the forwarded host events
// and the incident lifecycle. A best-effort line goes through the outbox when
// the collector has one; an announce line reports its outcome to the caller.
package feed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/incident"
	"yuruna.com/test/extension/pool-aggregator-service/internal/localization"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
)

// Names from the packages the lines are built from; they keep the builders
// readable.
type (
	hostStatus    = hostpoll.HostStatus
	incidentEvent = incident.Event
)

var operatorMessage = localization.OperatorMessage

const pushTimeout = loki.RequestTimeout

const (
	EventsFile    = "cycle.events.ndjson" // per-cycle NDJSON event log on each host
	MaxEventFetch = 4 << 20               // bytes read from a host's events file per poll
	MaxEventPush  = 1000                  // NDJSON lines shipped per host per poll (catch-up is bounded)
)

// Sender sends the best-effort lines: through Outbox when the collector has
// one, else straight to Loki.
type Sender struct {
	Outbox *loki.Outbox
}

// Post marshals payload, POSTs it to lokiURL under the shared pushTimeout,
// drains and closes the body, and logs (prefixed by logPrefix) a build error, a
// transport error or a non-2xx status. It returns nil once Loki has accepted the
// line, else why it did not: best-effort callers ignore it, and the announce
// paths answer for it.
// See https://yuruna.link/42c29d04-0019.
func Post(client *http.Client, lokiURL string, payload map[string]any, logPrefix string) error {
	buf, _ := json.Marshal(payload)
	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	err := loki.Push(ctx, client, lokiURL, buf)
	var status *loki.PushError
	switch {
	case errors.As(err, &status):
		log.Print(operatorMessage("aggregator.log_value1_http_value2_eb0cd24f", map[string]any{"value1": fmt.Sprintf("%s", logPrefix), "value2": fmt.Sprintf("%d", status.Status)}))
		return fmt.Errorf("%s: HTTP %d", logPrefix, status.Status)
	case err != nil:
		log.Print(operatorMessage("aggregator.log_value1_value2_efae3eb9", map[string]any{"value1": fmt.Sprintf("%s", logPrefix), "value2": fmt.Sprintf("%v", err)}))
	}
	return err
}

// Queue hands one best-effort line to the outbox, which sends it once Loki
// is ready to take it, and returns nil once the line is held; with no outbox it
// sends the line directly. No Loki endpoint is nothing to deliver. A caller that
// keeps its own record of what it sent (seen, an event file's cursor) advances
// it only on nil, so a line that could not be held is built and sent again.
func (s Sender) Queue(client *http.Client, lokiURL string, payload map[string]any, what string) error {
	if lokiURL == "" {
		return nil
	}
	if s.Outbox == nil {
		if client == nil {
			return nil
		}
		return Post(client, lokiURL, payload, what)
	}
	buf, _ := json.Marshal(payload)
	if err := s.Outbox.Enqueue(buf); err != nil {
		if !errors.Is(err, loki.ErrFull) {
			log.Print(operatorMessage("aggregator.log_loki_outbox_enqueue_failed", map[string]any{"what": what, "reason": err.Error()}))
		}
		return err
	}
	return nil
}

// CycleTransitionPayload snapshots one cycle-status transition for Loki. Labels are strictly
// {pool,hostId,cycleStartUtc} (low cardinality); the variable fields -- including the
// CURRENT baseURL for the dashboard's drill-down deep-link -- live in the line.
// The value timestamp is the proxy-side INGEST clock, not the host cycleStartUtc.
func CycleTransitionPayload(pool string, st *hostStatus, baseURL string, ingest time.Time) map[string]any {
	// hostname is omitted (pool view is hostname-free). cycleFolderUrl IS carried:
	// the /go/cycle redirect resolves a PAST cycle's results folder by time off this
	// line (the in-memory view only knows the current cycle). The folder name is the
	// opaque hostId (Format-CycleFolderBaseName), so the line stays hostname-free;
	// baseUrl is the host IP at transition time (the drill-down fallback for a host
	// that has since aged out of the live view).
	m := map[string]string{
		"hostId": st.HostId, "hostType": st.Host,
		"cycleStartUtc": st.CycleStartUtc, "overallStatus": st.OverallStatus,
		"startedAt": st.StartedAt, "finishedAt": st.FinishedAt,
		"baseUrl": baseURL, "cycleFolderUrl": st.CycleFolderUrl,
	}
	if st.OverallStatus == "fail" {
		// failureClass is carried on the fail transition so the startup restore
		// (rehydrate's Reader.Cycles) can put each fail's class into the fail window.
		m["failureClass"] = st.FailClassOf()
	}
	line, _ := json.Marshal(m)
	return map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": pool, "hostId": st.HostId, "cycleStartUtc": st.CycleStartUtc, "src": "cycle"},
		"values": [][]string{{fmt.Sprintf("%d", ingest.UnixNano()), string(line)}},
	}}}
}

// PushStream POSTs one line to Loki under the given stream labels --
// the shared body of the single-line beacon pushes (presence, announce).
// Any error is logged under `what` and also returned, for the callers that
// have to answer for durability rather than drop it.
//
// No Loki endpoint (or no client) is NOT an error: a pool can legitimately run
// without one, and reporting that as a push failure would turn "this lab keeps
// no log store" into a permanent fault in every caller that checks.
func PushStream(client *http.Client, lokiURL, what string, stream map[string]string, line []byte, now time.Time) error {
	if client == nil || lokiURL == "" {
		return nil
	}
	return Post(client, lokiURL, LinePayload(stream, line, now), what+" push")
}

// LinePayload is the push payload of one line on one stream.
func LinePayload(stream map[string]string, line []byte, now time.Time) map[string]any {
	return map[string]any{"streams": []map[string]any{{
		"stream": stream,
		"values": [][]string{{fmt.Sprintf("%d", now.UnixNano()), string(line)}},
	}}}
}

// PushPresence records a host's last-known address in Loki under {pool,hostId,
// src=presence} when it is first discovered or its IP changes -- on change, not
// per poll -- so a restart can re-seed the host view from it (rehydrate's
// Reader.Presence). Hostname-free: hostId and baseUrl only. The line goes
// through Queue: the outbox holds it when the collector has one, else it is
// sent directly. A line that cannot be held or sent is dropped; presence is
// pushed again only when the host's address changes.
// See https://yuruna.link/42c29d04-0013.
func (s Sender) PushPresence(client *http.Client, lokiURL, pool, hostID, baseURL string, now time.Time) {
	if lokiURL == "" || hostID == "" || baseURL == "" {
		return
	}
	line, _ := json.Marshal(map[string]string{"hostId": hostID, "baseUrl": baseURL})
	_ = s.Queue(client, lokiURL, LinePayload(map[string]string{"pool": pool, "hostId": hostID, "src": "presence"}, line, now), "presence push")
}

// PushAnnounce records one accepted extension-presence announce, or goodbye, in
// Loki under {pool,hostId,src=announce}; every accepted hello is pushed, so the
// freshest line's age is the entry's age. The caller passes the collector's own
// pool label, the one the startup restore queries. Not best-effort: the error is
// returned for the handler to answer with.
// See https://yuruna.link/42c29d04-0019.
func PushAnnounce(client *http.Client, lokiURL, pool, hostID, area, target string, active bool, now time.Time) error {
	if lokiURL == "" || hostID == "" {
		return nil
	}
	line, _ := json.Marshal(map[string]any{"hostId": hostID, "area": area, "target": target, "active": active})
	return PushStream(client, lokiURL, "announce",
		map[string]string{"pool": pool, "hostId": hostID, "src": "announce"}, line, now)
}

// hostnameEventKeys are the NDJSON event fields scrubbed from each forwarded
// event line: the literal `hostname`, and `cycleFolder`. New cycle folders are
// named with the opaque hostId, so cycleFolder is hostname-free at the source;
// scrubbing it is defense-in-depth that also covers a legacy folder name (created
// before a host adopted hostId naming, which embedded the hostname). Keeps the
// unauthenticated pool dashboard's event drill-down hostname-free; the host's own
// status page keeps the full detail.
var hostnameEventKeys = []string{"hostname", "cycleFolder"}

// RedactEventLine removes hostnameEventKeys from one NDJSON event line before it
// is shipped to Loki. It unmarshals, deletes the keys, and re-marshals; Go sorts
// map keys, so the output is deterministic and re-forwarding the same source line
// stays an exact Loki duplicate (idempotent dedup across collector restarts is
// preserved). A line that is not a JSON object -- or that carries none of the
// keys -- is forwarded byte-for-byte unchanged (host events are well-formed JSON;
// this only guards a truncated tail and avoids needless reformatting).
func RedactEventLine(ln string) string {
	var m map[string]any
	if err := json.Unmarshal([]byte(ln), &m); err != nil {
		return ln
	}
	changed := false
	for _, k := range hostnameEventKeys {
		if _, ok := m[k]; ok {
			delete(m, k)
			changed = true
		}
	}
	if !changed {
		return ln
	}
	b, err := json.Marshal(m)
	if err != nil {
		return ln
	}
	return string(b)
}

// PushEvents ships NDJSON event lines for one host to Loki under
// {pool,hostId,src=event}. Each Loki entry timestamp is the event's own
// `timestamp` field, so re-pushing an identical line is an exact-duplicate no-op
// (idempotent across collector restarts). Within-second events share a Loki
// timestamp (distinct lines, both retained) -- second resolution is fine for
// drill-down, and the precise time stays in the line. Falls back to the ingest
// clock for any line whose timestamp won't parse.
func (s Sender) PushEvents(client *http.Client, lokiURL, pool, hostID string, lines []string, ingest time.Time) error {
	if len(lines) == 0 {
		return nil
	}
	values := make([][]string, 0, len(lines))
	for _, ln := range lines {
		values = append(values, []string{strconv.FormatInt(EventNano(ln, ingest), 10), ln})
	}
	payload := map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": pool, "hostId": hostID, "src": "event"},
		"values": values,
	}}}
	return s.Queue(client, lokiURL, payload, "event push")
}

// EventNano returns the event's own timestamp in unix-nanoseconds, or the
// fallback (ingest clock) when the line has no parseable RFC3339 `timestamp`.
func EventNano(line string, fallback time.Time) int64 {
	var e struct {
		Timestamp string `json:"timestamp"`
	}
	if json.Unmarshal([]byte(line), &e) == nil && e.Timestamp != "" {
		if t, perr := time.Parse(time.RFC3339, e.Timestamp); perr == nil {
			return t.UnixNano()
		}
	}
	return fallback.UnixNano()
}

// PushIncident ships one incident lifecycle line to Loki under
// {pool,hostId,src=incident} -- the feed behind the dashboard incident strip.
func (s Sender) PushIncident(client *http.Client, lokiURL, pool string, ev incidentEvent) {
	stream, line := incident.StreamLine(pool, ev)
	payload := map[string]any{"streams": []map[string]any{{
		"stream": stream,
		"values": [][]string{{strconv.FormatInt(ev.Now.UnixNano(), 10), string(line)}},
	}}}
	_ = s.Queue(client, lokiURL, payload, "incident push")
}

// PushHostAnnounce records a host self-announce in Loki so a collector restart
// restores the host's address immediately instead of waiting for it to show up
// in the squid log again. Use the presence stream that startup already reads.
func PushHostAnnounce(client *http.Client, lokiURL, pool, hostID, baseURL string, now time.Time) error {
	if lokiURL == "" || hostID == "" {
		return nil
	}
	line, _ := json.Marshal(map[string]any{"hostId": hostID, "baseUrl": baseURL})
	return PushStream(client, lokiURL, "presence",
		map[string]string{"pool": pool, "hostId": hostID, "src": "presence"}, line, now)
}
