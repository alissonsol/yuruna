// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42215d39-bbfd-4798-be0d-1d297abb4184

package httpsrv

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"pool-control-service/internal/config"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/state"
)

// Pool-wide host control: one selector drives every member of a pool the way
// the operator would drive one host from its own status page.
//
// A durable configured pause also holds the outer runner at a cycle boundary.
// Continue must release that hold as well as the live pause switches; otherwise
// the page reports Continue while every member refuses to start another cycle.
// Drain remains a separate operation that ends the runner process.
//
// Membership comes from the configuration store and the addresses from the aggregator,
// for the same reason the board joins them that way: the aggregator's notion of
// a pool is a label a host self-advertises, so it cannot say who BELONGS.

// hostControlConcurrency bounds the fan-out. A pool is tens of hosts at most,
// and every call here is one short request, so this exists to keep a large pool
// from opening one socket per member at once rather than to pace anything.
const hostControlConcurrency = 8

// One budget for a whole fan-out, not per host: a lab where half the members
// are powered off must not hold the page (or the operator) for the sum of their
// timeouts. Whatever is still outstanding when the budget runs out is reported
// as a host that did not answer, which is what it is.
const (
	hostReadBudget  = 6 * time.Second
	hostApplyBudget = 30 * time.Second
)

// hostControlRow is one member's outcome, whether the call was a read or a
// write. Hosts are reported individually because they fail individually: a
// member that was never enrolled must not make the other nine look unset.
type hostControlRow struct {
	HostID string `json:"hostId"`
	State  string `json:"state,omitempty"`
	OK     bool   `json:"ok"`
	Error  string `json:"error,omitempty"`
}

// poolControlView is one pool's members and the single state they add up to.
type poolControlView struct {
	State           string           `json:"state"`
	Hosts           []hostControlRow `json:"hosts"`
	ConfiguredState string           `json:"configuredState"`
}

// aggregate collapses member states into what the pool's selector shows.
//
// A pool speaks with one voice only when every member answered and every answer
// agreed. A silent member makes it "mixed", never the state the others are in:
// the selector's whole job is to say what the pool is doing, and a host nobody
// reached is not evidence of anything.
func aggregate(rows []hostControlRow) string {
	known, state := 0, ""
	for _, row := range rows {
		if !row.OK {
			continue
		}
		known++
		switch {
		case state == "":
			state = row.State
		case state != row.State:
			return hostctl.StateMixed
		}
	}
	switch {
	case known == 0:
		return hostctl.StateUnknown
	case known < len(rows):
		return hostctl.StateMixed
	}
	return state
}

// memberAddresses resolves every member of the named pools to the address the
// aggregator last saw it on. A member with no entry maps to "", which each call
// site reports as its own per-host failure rather than dropping the row --
// a member the pool cannot locate is exactly what an operator needs to see.
func (s *Server) memberAddresses(ctx context.Context, members []string) (map[string]string, string) {
	status, err := s.pool.Status(ctx)
	statusErr := ""
	if err != nil {
		statusErr = err.Error()
	}
	known := map[string]string{}
	for _, h := range status.Hosts {
		known[h.HostID] = h.BaseURL
	}
	addr := make(map[string]string, len(members))
	for _, m := range members {
		addr[m] = known[m]
	}
	return addr, statusErr
}

// eachMember runs work over members with bounded concurrency and returns the
// rows in members order, so a page's host list does not reshuffle between
// loads for no reason.
func eachMember[T any](members []string, work func(hostID string) T) []T {
	rows := make([]T, len(members))
	sem := make(chan struct{}, hostControlConcurrency)
	var wg sync.WaitGroup
	for i, hostID := range members {
		wg.Add(1)
		go func(i int, hostID string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			rows[i] = work(hostID)
		}(i, hostID)
	}
	wg.Wait()
	return rows
}

// handleHostControlState reports, per pool, what its members are currently
// doing. Open like every other read: it exposes no more than each host's own
// status page already serves to the LAN.
func (s *Server) handleHostControlState(w http.ResponseWriter, r *http.Request) {
	doc, err := s.readConfigurationDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var all []string
	for _, p := range doc.Pools {
		all = append(all, p.Members...)
	}
	addr, statusErr := s.memberAddresses(r.Context(), all)
	ctx, cancel := context.WithTimeout(r.Context(), hostReadBudget)
	defer cancel()

	byHost := map[string]hostControlRow{}
	for _, row := range eachMember(all, func(hostID string) hostControlRow {
		st, err := s.hostctl.State(ctx, addr[hostID])
		if err != nil {
			return hostControlRow{HostID: hostID, State: hostctl.StateUnknown, Error: err.Error()}
		}
		return hostControlRow{HostID: hostID, State: st, OK: true}
	}) {
		byHost[row.HostID] = row
	}

	pools := map[string]poolControlView{}
	for _, p := range doc.Pools {
		rows := make([]hostControlRow, 0, len(p.Members))
		for _, m := range p.Members {
			rows = append(rows, byHost[m])
		}
		current := aggregate(rows)
		if p.ConfiguredState == "paused" {
			switch current {
			case hostctl.ActionContinue:
				current = hostctl.ActionPauseAfterCycle
			case hostctl.ActionPauseAfterStep:
				current = hostctl.StateBoth
			}
		}
		pools[p.PoolID] = poolControlView{State: current, Hosts: rows, ConfiguredState: p.ConfiguredState}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "pools": pools, "statusError": statusErr})
}

// handleHostControlApply drives every member of one pool into one state.
//
// The response is 200 with per-host rows even when hosts refused: the fan-out
// itself ran, and "3 of 4 hosts paused, this one is not enrolled" is the answer
// the operator needs. Only a failure to fan out AT ALL -- unreadable configuration, an
// unknown pool, no way to prove control -- is an error status.
func (s *Server) handleHostControlApply(w http.ResponseWriter, r *http.Request) {
	var body struct{ PoolID, Action string }
	if !decode(w, r, &body) {
		return
	}
	if body.PoolID == "" || body.Action == "" {
		writeErr(w, http.StatusBadRequest, "poolId and action are required")
		return
	}
	// Checked independently of hostctl.KnownAction, and ahead of it: a refresh
	// belongs to one explicitly authorized host, never to this pool-wide
	// fan-out. It is the separate typed per-host method hostctl.Refresh behind
	// POST /api/host/refresh and its own credential gate, and it is never a
	// KnownAction, so this refusal does not depend on that list staying as it
	// is. This handler also backs the MCP pool-control tool (same func, no
	// separate input-schema enforcement at dispatch time), so both entry
	// points are covered by the one check.
	if strings.EqualFold(body.Action, "refresh") {
		writeErr(w, http.StatusBadRequest, "action 'refresh' is not available through pool-wide control")
		return
	}
	if !hostctl.KnownAction(body.Action) {
		writeErr(w, http.StatusBadRequest, "action must be one of continue, pause-after-cycle, pause-after-step")
		return
	}
	doc, err := s.readConfigurationDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	members, found := membersOf(doc, body.PoolID)
	if !found {
		writeErr(w, http.StatusNotFound, "pool '"+body.PoolID+"' not found")
		return
	}
	resumePool := func() bool {
		if body.Action != hostctl.ActionContinue {
			return true
		}
		for _, p := range doc.Pools {
			if p.PoolID != body.PoolID || p.ConfiguredState != "paused" {
				continue
			}
			res := s.configuration.SetConfiguredState(r.Context(), body.PoolID, "run")
			if s.state != nil {
				detail := "configuredState: paused -> run"
				if !res.OK {
					detail = firstNonEmpty(res.Error, res.Stderr, "operation failed")
				}
				s.state.Record(time.Now(), state.AuditEntry{
					Publish: true, TimeUTC: time.Now().UTC().Format(time.RFC3339),
					Action: "configured-state", Target: body.PoolID, OK: res.OK, Detail: detail,
				})
			}
			if !res.OK {
				relayResult(w, res)
				return false
			}
		}
		return true
	}
	if len(members) == 0 {
		if !resumePool() {
			return
		}
		s.recordHostControl(body.PoolID, body.Action, 0, 0)
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "poolId": body.PoolID, "action": body.Action,
			"applied": 0, "failed": 0, "hosts": []hostControlRow{},
		})
		return
	}
	addr, statusErr := s.memberAddresses(r.Context(), members)
	ctx, cancel := context.WithTimeout(r.Context(), hostApplyBudget)
	defer cancel()

	// One proof per member: a proof names the host it opens. A member left
	// without one is refused on its own row.
	proofs, perr := s.controlProofs(ctx, members, addr, hostctl.ScopePause)
	if perr != nil {
		writeErr(w, http.StatusServiceUnavailable, perr.Error())
		return
	}
	if !resumePool() {
		return
	}

	rows := eachMember(members, func(hostID string) hostControlRow {
		err := s.hostctl.Apply(ctx, addr[hostID], body.Action, proofs[hostID])
		// A host that predates scoped proofs refuses a pause-scoped one as
		// proof-invalid; its own full proof still opens it, so that one is
		// asked for and the call made once more.
		if err != nil && hostctl.Scoped(proofs[hostID]) && hostctl.RefusedProof(err) {
			if full := s.fullControlProof(ctx, hostID); full != "" {
				err = s.hostctl.Apply(ctx, addr[hostID], body.Action, full)
			}
		}
		if err != nil {
			return hostControlRow{HostID: hostID, Error: err.Error()}
		}
		return hostControlRow{HostID: hostID, State: body.Action, OK: true}
	})
	applied, failed := 0, 0
	for _, row := range rows {
		if row.OK {
			applied++
		} else {
			failed++
		}
	}
	s.recordHostControl(body.PoolID, body.Action, applied, failed)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "poolId": body.PoolID, "action": body.Action,
		"applied": applied, "failed": failed, "hosts": rows, "statusError": statusErr,
	})
}

// controlProofs obtains the proof each member is sent, keyed by host id. A
// non-empty scope narrows each one to that class of the host's routes: the
// pool-wide action calls only the pause and resume routes, so its proofs open
// nothing else on the host, while a refresh needs the host's full proof.
//
// Two sources, in order. The internal authentication key this service already
// holds needs no round trip and binds each proof to its host -- but it is opt-in
// on a service VM (nothing bakes that file into the seed), so without it the
// aggregator is asked through /go/host: the identical proof a browser gets by
// following a dashboard host link. That fallback is what lets pool-wide control
// work on a lab that never placed the token file by hand.
//
// The aggregator binds each proof to the host it was asked about, so it is
// asked once per member. An aggregator that predates audiences answers with an
// unbound proof; that one answer is still sent to the whole fan-out, and every
// member refuses it as proof-invalid. Asking stops once proofAttemptLimit
// members in a row have been refused with nothing obtained: an aggregator that
// will not mint for those will not mint for the rest either, and an operator
// should not wait out one round trip per member to be told so.
func (s *Server) controlProofs(ctx context.Context, members []string, addr map[string]string, scope string) (map[string]string, error) {
	proofs := make(map[string]string, len(members))
	if hostctl.Mint(s.opts.AuthToken, hostctl.ProofTTL) != "" {
		for _, hostID := range members {
			proof := hostctl.MintFor(s.opts.AuthToken, hostID, hostctl.ProofTTL)
			if scope == hostctl.ScopePause {
				proof = hostctl.MintPause(s.opts.AuthToken, hostID, hostctl.ProofTTL)
			}
			if proof != "" {
				proofs[hostID] = proof
			}
		}
		return proofs, nil
	}
	base := s.pool.BaseURL()
	if base == "" {
		return nil, &controlProofError{reason: controlProofNoInternalKey,
			text: fmt.Sprintf("no control proof: this service holds no internal authentication key (%s) and has no pool aggregator to ask for one", s.authTokenFile())}
	}
	var lastErr error
	refused := 0
	for _, hostID := range orderByReachable(members, addr) {
		if len(proofs) == 0 && refused >= proofAttemptLimit {
			break
		}
		proof, err := s.hostctl.ProofFromAggregator(ctx, base, hostID, scope)
		if err != nil {
			lastErr = err
			refused++
			continue
		}
		if !hostctl.Bound(proof) {
			for _, member := range members {
				proofs[member] = proof
			}
			return proofs, nil
		}
		proofs[hostID] = proof
	}
	if len(proofs) == 0 {
		return nil, &controlProofError{reason: controlProofAggregatorRefused,
			text: fmt.Sprintf("no control proof: this service holds no internal authentication key (%s) and the pool aggregator would not mint one (%v)", s.authTokenFile(), lastErr)}
	}
	return proofs, nil
}

// fullControlProof is hostID's unscoped proof, from the same source
// controlProofs used, or "" when none can be had. A host that predates scoped
// proofs needs it.
func (s *Server) fullControlProof(ctx context.Context, hostID string) string {
	if proof := hostctl.MintFor(s.opts.AuthToken, hostID, hostctl.ProofTTL); proof != "" {
		return proof
	}
	base := s.pool.BaseURL()
	if base == "" {
		return ""
	}
	proof, err := s.hostctl.ProofFromAggregator(ctx, base, hostID, "")
	if err != nil {
		return ""
	}
	return proof
}

// Why no control proof could be obtained, as bounded tokens.
const (
	controlProofNoInternalKey     = "no_internal_key"
	controlProofAggregatorRefused = "aggregator_refused"
	controlProofUnavailable       = "control_proof_unavailable"
)

// controlProofError is a failure to obtain the legacy transport proof. Its
// text is for an operator reading the pool-wide reply or the log: it names the
// token file to provision and quotes the aggregator's failure. A localized
// reply carries reason instead, because that quoted failure comes from a
// service this one reads without authentication.
type controlProofError struct {
	reason, text string
}

func (e *controlProofError) Error() string { return e.text }

// controlProofFailureReason is the bounded token for a controlProof error.
func controlProofFailureReason(err error) string {
	var cpe *controlProofError
	if errors.As(err, &cpe) && cpe.reason != "" {
		return cpe.reason
	}
	return controlProofUnavailable
}

// proofAttemptLimit caps how many members are asked about before the aggregator
// is taken at its word.
const proofAttemptLimit = 3

// authTokenFile names the file an operator drops the shared token into: the one
// this daemon was launched with, falling back to the documented default when it
// was launched without the flag at all.
func (s *Server) authTokenFile() string {
	if f := strings.TrimSpace(s.opts.AuthTokenFile); f != "" {
		return f
	}
	return config.DefaultAuthTokenFile
}

// orderByReachable puts the members the pool has an address for first.
func orderByReachable(members []string, addr map[string]string) []string {
	out := make([]string, 0, len(members))
	for _, m := range members {
		if strings.TrimSpace(addr[m]) != "" {
			out = append(out, m)
		}
	}
	for _, m := range members {
		if strings.TrimSpace(addr[m]) == "" {
			out = append(out, m)
		}
	}
	return out
}

// recordHostControl audits one fan-out. Every other mutation is audited through
// relay(); this one does not go through the configuration CLIs, so it records its own.
func (s *Server) recordHostControl(poolID, action string, applied, failed int) {
	if s.state == nil {
		return
	}
	s.state.Record(time.Now(), state.AuditEntry{
		TimeUTC: time.Now().UTC().Format(time.RFC3339),
		Action:  "host-control", Target: poolID, OK: failed == 0,
		Detail: fmt.Sprintf("%s: %d applied, %d failed", action, applied, failed),
	})
}

// membersOf returns a pool's members and whether the pool exists at all. The
// two are distinct answers: an empty pool has no live hosts to drive but can
// still release a configured pause; an unknown pool is a bad request.
func membersOf(doc configurationDoc, poolID string) ([]string, bool) {
	for _, p := range doc.Pools {
		if p.PoolID == poolID {
			return p.Members, true
		}
	}
	return nil, false
}

// readConfigurationDoc runs the configuration read and decodes it, with the messages every
// caller here surfaces verbatim.
func (s *Server) readConfigurationDoc(ctx context.Context) (configurationDoc, error) {
	var doc configurationDoc
	res := s.configuration.State(ctx)
	if !res.OK {
		return doc, fmt.Errorf("%s", firstNonEmpty(res.Error, res.Stderr, "pool configuration read failed"))
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(res.Stdout)), &doc); err != nil {
		return doc, fmt.Errorf("could not parse pool configuration: %s", err.Error())
	}
	return doc, nil
}
