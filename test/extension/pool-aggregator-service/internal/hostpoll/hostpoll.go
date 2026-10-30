// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 423a1885-d68b-43e5-95b4-4e97e0bad8a9

// Package hostpoll is the host-facing half of the collector's poll: the bounded
// reads of each pool host's status service and the wire types they decode. It
// holds no pool state; the poll merges what these reads return into the pool
// view under the view's own lock.
package hostpoll

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/pool"
)

const (
	// ProbeTimeout bounds one LAN status probe (refused is instant; filtered times out).
	ProbeTimeout = 3 * time.Second
	// MaxControlStatusBytes caps the control-status document. It is read one
	// byte past the cap so an oversize answer is refused as oversize rather
	// than truncated into JSON that fails to parse and leaves every verdict at
	// its previous value.
	MaxControlStatusBytes = 4096
)

// Registration is a host's /runtime/host.registration.json as the pool reads it:
// poolId (derived by the runner from pools.yml, the single source of truth), the
// optional gating block as authored, the active extension areas and the
// per-area extension deep-links. PoolID may be "" for an unpooled host -- a
// successful read, not an error.
type Registration struct {
	PoolID           string
	PoolGuid         string
	ActiveExtensions []string
	ExtensionTargets map[string]string
	// Gating is nil when the pool authored no gating block.
	Gating *GatingSpec
}

// GatingSpec is a pool's gating block exactly as authored: a nil field was not
// set, so a reader can tell "absent" from "authored as zero" and fill only the
// missing knobs from its defaults.
type GatingSpec struct {
	FailuresBeforeAlert  *int
	SuccessesBeforeRearm *int
	HealthyThreshold     *float64
	DegradedAfterSeconds *int
}

// FetchRegistration reads /runtime/host.registration.json. activeExtensions is
// the RUNTIME list of extension areas the host is actively running (e.g.
// stash-service) -- the host sets it (Write-HostRegistrationRecord) only when the
// corresponding service is up, distinct from the static capabilities list.
func FetchRegistration(client *http.Client, base string) (Registration, error) {
	status, body, err := Get(client, base, "/runtime/host.registration.json", 1<<20)
	if err != nil {
		return Registration{}, err
	}
	if status != http.StatusOK {
		return Registration{}, fmt.Errorf("host.registration.json HTTP %d", status)
	}
	var reg struct {
		PoolID           string            `json:"poolId"`
		PoolGuid         string            `json:"poolGuid"`
		ActiveExtensions []string          `json:"activeExtensions"`
		ExtensionTargets map[string]string `json:"extensionTargets"`
		Gating           *struct {
			FailuresBeforeAlert  *int `json:"failuresBeforeAlert"`
			SuccessesBeforeRearm *int `json:"successesBeforeRearm"`
			Quorum               *struct {
				HealthyThreshold     *float64 `json:"healthyThreshold"`
				DegradedAfterSeconds *int     `json:"degradedAfterSeconds"`
			} `json:"quorum"`
		} `json:"gating"`
	}
	if err := json.Unmarshal(body, &reg); err != nil {
		return Registration{}, fmt.Errorf("host.registration.json parse: %w", err)
	}
	out := Registration{PoolID: reg.PoolID, PoolGuid: reg.PoolGuid, ActiveExtensions: reg.ActiveExtensions, ExtensionTargets: reg.ExtensionTargets}
	if reg.Gating != nil {
		out.Gating = &GatingSpec{FailuresBeforeAlert: reg.Gating.FailuresBeforeAlert, SuccessesBeforeRearm: reg.Gating.SuccessesBeforeRearm}
		if reg.Gating.Quorum != nil {
			out.Gating.HealthyThreshold = reg.Gating.Quorum.HealthyThreshold
			out.Gating.DegradedAfterSeconds = reg.Gating.Quorum.DegradedAfterSeconds
		}
	}
	return out, nil
}

// GitCommitRef is one status.json gitCommits entry: the machine-routable sha +
// repoUrl (hostname-free, so it stays safe on the unauthenticated pool surface).
type GitCommitRef struct {
	Sha               string   `json:"sha"`
	RepoURL           string   `json:"repoUrl"`
	Source            string   `json:"source,omitempty"`
	Verification      string   `json:"verification,omitempty"`
	Repository        string   `json:"repository,omitempty"`
	Ref               string   `json:"ref,omitempty"`
	SelectedSHA       string   `json:"selectedSha,omitempty"`
	FetchRef          string   `json:"fetchRef,omitempty"`
	OriginCheckedAt   string   `json:"originCheckedAt,omitempty"`
	RefreshAgeSeconds *float64 `json:"refreshAgeSeconds,omitempty"`
	MirrorVersion     string   `json:"mirrorVersion,omitempty"`
	KeyID             string   `json:"keyId,omitempty"`
	FallbackReason    string   `json:"fallbackReason,omitempty"`
	FailureClass      string   `json:"failureClass,omitempty"`
}

// GitCommitRefs is the gitCommits array. Its decoder accepts the flat and the
// double-wrapped shape and yields an empty list for anything else, so one
// malformed field never drops a host. See https://yuruna.link/42c29d04-000a.
type GitCommitRefs []GitCommitRef

func (g *GitCommitRefs) UnmarshalJSON(b []byte) error {
	var flat []GitCommitRef
	if err := json.Unmarshal(b, &flat); err == nil {
		*g = flat
		return nil
	}
	var nested [][]GitCommitRef
	if err := json.Unmarshal(b, &nested); err == nil {
		out := GitCommitRefs{}
		for _, inner := range nested {
			out = append(out, inner...)
		}
		*g = out
		return nil
	}
	*g = nil
	return nil
}

// HostStatus mirrors the subset of each host's /runtime/status.json the pool
// view needs. Unknown fields ignored; missing fields tolerated.
type HostStatus struct {
	HostId string `json:"hostId"`
	Host   string `json:"host"` // hostType, e.g. host.windows.hyper-v
	// Hostname is deliberately NOT parsed or emitted (json:"-"): the pool view --
	// including the unauthenticated /api/v1/pool-status JSON snapshot, which
	// serializes this struct -- is hostname-free, so it stays safe to expose
	// without auth. Hosts are identified by hostId; the hostname lives only on the
	// host's own (separately authenticated) status page. The field is retained
	// (not deleted) to document that status.json carries a hostname we drop.
	Hostname       string `json:"-"`
	CycleStartUtc  string `json:"cycleStartUtc"`
	OverallStatus  string `json:"overallStatus"`
	StartedAt      string `json:"startedAt"`
	FinishedAt     string `json:"finishedAt"`
	CycleFolderUrl string `json:"cycleFolderUrl"`
	// Only verdict fields are accepted from history: host diagnostics and names
	// must not escape through the unauthenticated pool snapshot.
	History []CycleVerdict `json:"history,omitempty"`
	// CyclePaused mirrors the host's control.cycle-pause flag (status.json sets it on
	// every write + the status service flips it on the pause toggle). Surfaces a paused
	// host as its own "paused" status, the same effective-pause signal the host status
	// page shows -- see statusLabel.
	CyclePaused bool `json:"cyclePaused"`
	// StepPaused mirrors the host's control.step-pause flag, written the same way.
	// Armed, it stops the runner at the NEXT step boundary, so on its own it means
	// "pausing", not "paused"; whether that boundary has actually been reached is
	// visible only in the current-action sidecar (hostView.StepPauseReached). Both
	// flags are surfaced as their own status rather than hidden inside a "running"
	// cycle, so the pool view never shows a plain "running" for a host an operator
	// has already told to stop -- see statusLabel.
	StepPaused bool `json:"stepPaused"`
	// GitCommits mirrors status.json's gitCommits array (framework FIRST, project
	// SECOND by the runner's convention -- see Test.RunnerInnerLoop's
	// GitCommitsList): the source-tree commit(s) the current cycle ran. Drives the
	// pool table's Commit column -- short SHAs plus a per-repo deep-link. Only the
	// machine-routable sha + repoUrl are parsed; a commit id and a repo URL are
	// hostname-free, so they stay safe on the unauthenticated pool surface this
	// struct serializes.
	GitCommits GitCommitRefs `json:"gitCommits"`
	// LastFailure is parsed DELIBERATELY NARROW: only the machine-routable
	// failureClass + severity, never the host's richer lastFailure (errorMessage,
	// vmName, reproCommand, relPath) which would leak host detail onto the
	// unauthenticated /api/v1/pool-status this struct serializes. status.json sets
	// lastFailure at failure time (Test.Status Set-LastFailureSummary); null on pass.
	LastFailure struct {
		FailureClass string `json:"failureClass"`
		Severity     string `json:"severity"`
	} `json:"lastFailure"`
	// RunnerFault describes an attempt that failed outside a completed cycle.
	// Keep the public snapshot free of transcripts, paths and diagnostic text.
	RunnerFault *RunnerFault `json:"RunnerFault,omitempty"`
}

type RunnerFault struct {
	FailureClass string `json:"failureClass"`
	Severity     string `json:"severity"`
	Stage        string `json:"stage,omitempty"`
}

type CycleVerdict struct {
	CycleStartUtc string `json:"cycleStartUtc"`
	OverallStatus string `json:"overallStatus"`
	FinishedAt    string `json:"finishedAt"`
	LastFailure   struct {
		FailureClass string `json:"failureClass"`
		Severity     string `json:"severity"`
	} `json:"lastFailure"`
}

// The outer runner overlays host faults on the live verdict even when the next
// attempt died before creating a cycle. Completed history still describes the
// actual cycle; counting the overlay would turn a prior pass into a second fail.
func (st *HostStatus) CycleStatus() *HostStatus {
	for _, row := range st.History {
		if row.CycleStartUtc == st.CycleStartUtc && row.CycleStartUtc != "" && (IsTerminal(row.OverallStatus) || row.OverallStatus == "skipped") {
			completed := *st
			completed.OverallStatus = row.OverallStatus
			completed.FinishedAt = row.FinishedAt
			completed.LastFailure = row.LastFailure
			return &completed
		}
	}
	return st
}

// FailClassOf returns the (terminal-fail) cycle's failure class, defaulting to
// "unknown" when status.json carries no classified lastFailure.
func (s *HostStatus) FailClassOf() string {
	if s == nil || s.LastFailure.FailureClass == "" {
		return "unknown"
	}
	return s.LastFailure.FailureClass
}

// IsTerminal reports whether a cycle status is a finished verdict.
func IsTerminal(status string) bool { return status == "pass" || status == "fail" }

// NormalizeRefreshCapability clamps the refresh object a host put in its
// control-status answer. The host is read without authentication, so every
// field is held to its vocabulary: a wrong type or an unknown availability is
// capability_malformed, another protocol is protocol_unsupported, and a
// ceiling that is not a rung is dropped. An explicit null reads as absent.
func NormalizeRefreshCapability(raw json.RawMessage) *pool.HostRefresh {
	if len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		return nil
	}
	malformed := &pool.HostRefresh{Availability: pool.RefreshUnavailable, Reason: pool.RefreshReasonCapabilityMalformed,
		Remote: pool.RefreshRemoteUnknown, State: pool.RefreshStateUnknown}
	var in struct {
		Protocol     *int    `json:"protocol"`
		Availability *string `json:"availability"`
		Ceiling      *string `json:"ceiling"`
		Reason       *string `json:"reason"`
		Remote       *string `json:"remote"`
		State        *string `json:"state"`
	}
	if err := json.Unmarshal(raw, &in); err != nil || in.Availability == nil || *in.Availability == "" {
		return malformed
	}
	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	r := pool.HostRefresh{Availability: *in.Availability, Ceiling: str(in.Ceiling), Reason: str(in.Reason),
		Remote: str(in.Remote), State: str(in.State)}
	if in.Protocol != nil {
		r.Protocol = *in.Protocol
	}
	n := r.Normalized()
	return &n
}

// NewPollHTTPClient is the client one poll runs on. A poll asks each host five
// to seven questions in a row (status, registration, version, control status,
// runner status, and the step sidecar while a step pause is armed), so the
// connection to a host is kept for the poll instead of opened per question. The
// caller closes the connections when the poll ends, which keeps what
// newInternalHTTPClient's DisableKeepAlives protects: no pooled connection lives
// on into the next poll to go stale and fail a live host's probe.
func NewPollHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			Proxy:               nil,
			DialContext:         (&net.Dialer{Timeout: timeout}).DialContext,
			MaxIdleConnsPerHost: 2,
			IdleConnTimeout:     timeout,
		},
	}
}

// Get is the bounded GET every host probe shares: one ProbeTimeout, one request
// and a read capped at limit bytes. It returns the HTTP status beside the body,
// which it reads only on 200, and leaves to the caller what a status means.
// See https://yuruna.link/42c29d04-000b.
func Get(client *http.Client, base, path string, limit int64) (int, []byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), ProbeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+path, nil)
	if err != nil {
		return 0, nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return resp.StatusCode, nil, nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, body, nil
}

// FetchStatus reads /runtime/status.json. It returns the raw body beside the
// parsed subset, so a reader of fields the public status deliberately leaves out
// (the canary ring's history rows) parses them without widening HostStatus.
func FetchStatus(client *http.Client, base string) (*HostStatus, []byte, error) {
	status, body, err := Get(client, base, "/runtime/status.json", 1<<20)
	if err != nil {
		return nil, nil, err
	}
	if status != http.StatusOK {
		return nil, nil, fmt.Errorf("status.json HTTP %d", status)
	}
	var st HostStatus
	if err := json.Unmarshal(body, &st); err != nil {
		return nil, nil, fmt.Errorf("status.json parse: %w", err)
	}
	return &st, body, nil
}

// FetchRunnerStopped reads /control/runner-status and reports whether the host's
// outer test runner is verifiably not alive: only an explicit running:false
// counts; a 404 or a missing field is "cannot tell", and a transport failure
// returns the error. See https://yuruna.link/42c29d04-000c.
func FetchRunnerStopped(client *http.Client, base string) (bool, error) {
	status, body, err := Get(client, base, "/control/runner-status", 64<<10)
	if err != nil {
		return false, err
	}
	if status == http.StatusNotFound {
		return false, nil
	}
	if status != http.StatusOK {
		return false, fmt.Errorf("runner-status HTTP %d", status)
	}
	// A pointer, so an answer that omits the field is told apart from one that says
	// false -- the difference between "cannot tell" and "the runner is gone".
	var rs struct {
		Running *bool `json:"running"`
	}
	if err := json.Unmarshal(body, &rs); err != nil {
		return false, fmt.Errorf("runner-status parse: %w", err)
	}
	return rs.Running != nil && !*rs.Running, nil
}

// StepPauseCode is what Invoke-Sequence writes into the current-action sidecar's
// `code` field while it is blocked at a step boundary. The host's own status page
// branches on the same code (yuruna.common.js isWaitingForResume), so both
// surfaces flip from "pausing" to "paused" together.
const StepPauseCode = "sequence_paused_waiting_resume"

// FetchCurrentAction reads /runtime/current-action.json and reports ONLY whether
// the runner is parked at a step boundary. The sidecar also carries the in-progress
// step's text and the guest VM name; neither is decoded into anything this process
// stores or exports, because /api/v1/pool-status is unauthenticated by
// design and a step line is host detail -- the same deliberately narrow read as
// HostStatus.LastFailure. A missing sidecar (404: no sequence has written one this
// cycle) is a definite "not parked" rather than an error, so a host whose flag is
// armed between sequences reports "pausing" instead of inheriting a stale reading.
func FetchCurrentAction(client *http.Client, base string) (bool, error) {
	status, body, err := Get(client, base, "/runtime/current-action.json", 64<<10)
	if err != nil {
		return false, err
	}
	if status == http.StatusNotFound {
		return false, nil
	}
	if status != http.StatusOK {
		return false, fmt.Errorf("current-action.json HTTP %d", status)
	}
	var doc struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return false, fmt.Errorf("current-action.json parse: %w", err)
	}
	return doc.Code == StepPauseCode, nil
}

// FetchVersion reads the first line of /yuruna-repo/VERSION, capped at 64
// characters; ("", err) on any failure, so the caller keeps its prior value.
// See https://yuruna.link/42c29d04-000d.
func FetchVersion(client *http.Client, base string) (string, error) {
	status, body, err := Get(client, base, "/yuruna-repo/VERSION", 4096)
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("VERSION HTTP %d", status)
	}
	v := strings.TrimSpace(string(body))
	if i := strings.IndexAny(v, "\r\n"); i >= 0 { // first line only
		v = strings.TrimSpace(v[:i])
	}
	if len(v) > 64 {
		v = v[:64]
	}
	return v, nil
}

// ControlStatus is one host's answer to GET /control/control-status. Present
// false means the route did not answer usably, not "no token"; TokenTag names
// the token without carrying it; UtcNow is the host's clock; Refresh is nil when
// the answer carried no refresh capability. See https://yuruna.link/42c29d04-000e.
type ControlStatus struct {
	Present         bool
	TokenConfigured bool
	TokenTag        string
	UtcNow          time.Time
	Refresh         *pool.HostRefresh
}

// ErrControlStatusOversize is a control-status answer larger than the cap.
// It is an error, not a truncation, so the caller treats it like any other
// unusable read.
var ErrControlStatusOversize = errors.New("control-status answer exceeds the size cap")

// FetchControlStatus reads /control/control-status. The route is open and
// read-only, so this needs no credential -- which is the point: the aggregator
// must be able to ask a host it may share nothing with. A 404 is reported as a
// definite absence (Present=false, err=nil) rather than an error: the host
// answered, it simply predates the route, and the caller must show "unknown"
// instead of inheriting a stale verdict forever. A transport failure returns the
// error so the caller can keep what it last knew.
func FetchControlStatus(client *http.Client, base string) (ControlStatus, error) {
	status, body, err := Get(client, base, "/control/control-status", MaxControlStatusBytes+1)
	if err != nil {
		return ControlStatus{}, err
	}
	if len(body) > MaxControlStatusBytes {
		return ControlStatus{}, ErrControlStatusOversize
	}
	if status == http.StatusNotFound {
		return ControlStatus{}, nil
	}
	if status != http.StatusOK {
		return ControlStatus{}, fmt.Errorf("control-status HTTP %d", status)
	}
	var cs struct {
		TokenConfigured bool            `json:"tokenConfigured"`
		TokenTag        string          `json:"tokenTag"`
		UtcNow          string          `json:"utcNow"`
		Refresh         json.RawMessage `json:"refresh"`
	}
	if err := json.Unmarshal(body, &cs); err != nil {
		return ControlStatus{}, fmt.Errorf("control-status parse: %w", err)
	}
	out := ControlStatus{Present: true, TokenConfigured: cs.TokenConfigured, TokenTag: cs.TokenTag,
		Refresh: NormalizeRefreshCapability(cs.Refresh)}
	// An unparseable clock leaves UtcNow zero, which the classifier reads as
	// "no skew evidence" rather than as an enormous skew.
	if t, perr := time.Parse(time.RFC3339, cs.UtcNow); perr == nil {
		out.UtcNow = t.UTC()
	}
	return out, nil
}
