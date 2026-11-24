// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42858838-24ef-4b6a-86b0-f0c5b9f2a36f

package httpsrv

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"pool-control-service/internal/config"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/state"
	"yuruna.com/test/extension/extension-sdk/hostrepair"
	"yuruna.com/test/extension/extension-sdk/hostupdate"
	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/jsonbody"
	"yuruna.com/test/extension/extension-sdk/pool"
	"yuruna.com/test/extension/extension-sdk/strictjson"
)

// Per-host update: one operator request, for one host, carried to that host's
// status service with two proofs -- the legacy control proof its transport
// gate checks, and a yup1 proof signed here over the host, the request id, the
// scope, the drain bound and the expected commit. The host verifies the
// signature with the public key in its pool-control record, so it keeps no
// secret for this operation.
//
// No body this route accepts can end a running cycle: drain is not a key here
// in any spelling, and the host always waits for the cycle. Ending one is
// asked only from the host's own shell.

// hostUpdateBudget bounds the whole route: the aggregator read, the host's
// capability read, a control proof that may come from the aggregator, and one
// request to the host with its single same-id resend.
const hostUpdateBudget = 25 * time.Second

// hostUpdateDiagnosticsPage is where a host serves its Diagnostics page,
// which follows the update named in the #yhu fragment.
const hostUpdateDiagnosticsPage = "/diagnostics.html"

// Reasons this service gives for a host it will not send an update to, beside
// the host's own capability reasons.
const (
	updateReasonUnsupported      = "update_unsupported"
	updateReasonStatusUnreadable = "control_status_unreadable"
	updateReasonScopeUnavailable = "scope_unavailable"
	updateReasonForbiddenField   = "forbidden_field"
)

// updateEnabled reports whether both halves of remote host update are
// provisioned: the credential that admits a caller and the key that signs for
// a host.
func (s *Server) updateEnabled() bool {
	return s.operatorGate.Configured() && s.updateSigner != nil
}

// updateBody is the validated request with its defaults applied.
type updateBody struct {
	HostID, RequestID, Scope, ExpectCommit string
	DrainSeconds                           int
}

// decodeUpdateBody reads the body strictly: at most MaxUpdateRequestBytes,
// one JSON object whose only keys are hostId, requestId, scope, drainSeconds
// and expectCommit, each once, the first four strings and drainSeconds a JSON
// integer. A key that names drain in any other spelling is forbidden, and
// every other key is unsupported; both are refused before anything is signed.
func decodeUpdateBody(w http.ResponseWriter, r *http.Request) (updateBody, *repairRefusal) {
	raw, err := jsonbody.ReadRequest(w, r, config.MaxUpdateRequestBytes)
	if errors.Is(err, jsonbody.ErrOversize) {
		return updateBody{}, &repairRefusal{status: http.StatusRequestEntityTooLarge, key: "pool.host_update_body_invalid", args: map[string]any{"detail": "too_large"}}
	}
	if err != nil {
		return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_update_body_invalid", args: map[string]any{"detail": "unreadable"}}
	}
	known := map[string]bool{"hostId": true, "requestId": true, "scope": true, "drainSeconds": true, "expectCommit": true}
	values, refusal := strictjson.Scalars(raw, known, normalizeFieldName)
	if refusal != nil {
		if refusal.Detail != "unsupported_field" {
			return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_update_body_invalid", args: map[string]any{"detail": refusal.Detail}}
		}
		shown := refusal.Field
		if !fieldNameRE.MatchString(shown) {
			shown = repairFieldNamePlaceholder
		}
		if strings.Contains(normalizeFieldName(refusal.Field), "drain") {
			return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_update_field_forbidden", args: map[string]any{"field": shown}, field: shown}
		}
		return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_update_field_unsupported", args: map[string]any{"field": shown}, field: shown}
	}
	text := func(name string) (string, bool) {
		v, present := values[name]
		if !present {
			return "", true
		}
		s, ok := v.(string)
		return s, ok
	}
	body := updateBody{Scope: hostupdate.ScopeRestart, DrainSeconds: hostupdate.DefaultDrainSeconds}
	hostID, ok := text("hostId")
	canonical, valid := hostrepair.CanonicalHostID(hostID)
	if !ok || !valid {
		return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_host_id_invalid", field: "hostId"}
	}
	body.HostID = canonical
	if body.RequestID, ok = text("requestId"); !ok || !hostrepair.ValidRequestID(body.RequestID) {
		return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_request_id_invalid", field: "requestId"}
	}
	if scope, present := values["scope"]; present {
		s, isText := scope.(string)
		if !isText || !hostupdate.ValidScope(s) {
			return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_update_scope_invalid", field: "scope"}
		}
		body.Scope = s
	}
	if drain, present := values["drainSeconds"]; present {
		n, isNumber := drain.(json.Number)
		seconds, err := strconv.Atoi(string(n))
		if !isNumber || err != nil || !hostupdate.ValidDrainSeconds(seconds) {
			return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_update_drain_invalid", field: "drainSeconds"}
		}
		body.DrainSeconds = seconds
	}
	if body.ExpectCommit, ok = text("expectCommit"); !ok || !hostupdate.ValidExpectCommit(body.ExpectCommit) {
		return updateBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_update_commit_invalid", field: "expectCommit"}
	}
	return body, nil
}

// updateRefusalReason names why a host's capability, as the host itself
// reports it, does not admit this remote update. Empty means it does.
func updateRefusalReason(cs hostctl.ControlStatus, scope string) string {
	u := cs.Update
	switch {
	case !cs.Present:
		return updateReasonUnsupported
	case u.Availability != "available":
		if r := boundedHostReason(u.Reason); r != "" {
			return r
		}
		return updateReasonUnsupported
	case u.Remote == "invalid":
		return hostupdate.ReasonRemoteInvalid
	case u.Remote != "provisioned":
		return hostupdate.ReasonRemoteUnprovisioned
	case !u.HasScope(scope):
		return updateReasonScopeUnavailable
	}
	return ""
}

// handleHostUpdate admits one remote host update for one host. It runs behind
// the ordinary write gate AND the operator credential gate; the MCP tool
// reaches it raw, after the same two gates ran on the incoming request.
func (s *Server) handleHostUpdate(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), hostUpdateBudget)
	defer cancel()
	locale := s.requestLocale(r)

	if s.updateSigner == nil {
		s.recordHostUpdate(updateBody{}, repairOutcomeSigningUnconfigured, 0, "")
		s.writeRepairReply(w, locale, http.StatusServiceUnavailable, "pool.host_update_signing_unconfigured",
			map[string]any{"path": s.updateSigningKeyFile()}, nil)
		return
	}
	body, refusal := decodeUpdateBody(w, r)
	if refusal != nil {
		s.recordHostUpdate(updateBody{}, repairOutcomeBodyInvalid, 0, "")
		extra := map[string]any{}
		if refusal.field != "" {
			extra["field"] = refusal.field
		}
		if refusal.key == "pool.host_update_field_forbidden" {
			extra["reason"] = updateReasonForbiddenField
		}
		s.writeRepairReply(w, locale, refusal.status, refusal.key, refusal.args, extra)
		return
	}
	ids := map[string]any{"hostId": body.HostID, "requestId": body.RequestID}

	host, ok := s.resolveUpdateHost(ctx, w, locale, body, ids)
	if !ok {
		return
	}
	cs, err := s.hostctl.ControlStatus(ctx, host.BaseURL)
	if err != nil {
		s.refuseUnreadableCapability(w, locale, body, ids, err)
		return
	}
	if reason := updateRefusalReason(cs, body.Scope); reason != "" {
		s.recordHostUpdate(body, repairOutcomeUnavailable, 0, reason)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_update_unavailable",
			map[string]any{"hostId": body.HostID, "reason": reason}, mergeFields(ids, map[string]any{"hostReason": reason}))
		return
	}

	proofs, err := s.controlProofs(ctx, []string{body.HostID}, map[string]string{body.HostID: host.BaseURL}, "")
	controlProof := proofs[body.HostID]
	if err == nil && controlProof == "" {
		err = &controlProofError{reason: controlProofAggregatorRefused, text: "no control proof for " + body.HostID}
	}
	if err != nil {
		log.Printf("pool-control-service: host-update %s: %v", body.HostID, err)
		s.recordHostUpdate(body, repairOutcomeControlProofMissing, 0, "")
		s.writeRepairReply(w, locale, http.StatusServiceUnavailable, "pool.host_repair_control_proof_unavailable",
			map[string]any{"hostId": body.HostID, "detail": controlProofFailureReason(err)}, ids)
		return
	}
	updateProof, _, err := s.updateSigner.Mint(body.HostID, body.RequestID, body.Scope, body.DrainSeconds, body.ExpectCommit, time.Now())
	if err != nil {
		s.recordHostUpdate(body, repairOutcomeMintFailed, 0, "")
		s.writeRepairReply(w, locale, http.StatusInternalServerError, "pool.host_update_mint_failed", map[string]any{"hostId": body.HostID}, ids)
		return
	}

	reply, err := s.hostctl.Update(ctx, host.BaseURL, hostctl.UpdateRequest{RequestID: body.RequestID, Scope: body.Scope,
		DrainSeconds: body.DrainSeconds, ExpectCommit: body.ExpectCommit}, controlProof, updateProof)
	if err == nil {
		out := mergeFields(ids, map[string]any{"ok": true, "action": reply.Action, "scope": body.Scope, "stateUrl": reply.StateURL,
			"diagnosticsUrl": hostDiagnosticsURL(host.BaseURL, body.RequestID), "retryable": false})
		code := http.StatusAccepted
		if reply.Replay {
			code = http.StatusOK
			out["replay"] = true
			out["verdict"] = boundedHostReason(reply.Verdict)
			out["state"] = boundedHostReason(reply.State)
		}
		if reply.Supersedes != "" {
			out["supersedes"] = reply.Supersedes
		}
		s.recordHostUpdate(body, reply.Action, reply.Status, "")
		writeJSON(w, code, out)
		return
	}
	s.relayUpdateRefusal(w, locale, body, ids, err)
}

// resolveUpdateHost finds the host and its address in the aggregator's pool
// status, writing the refusal when it cannot.
func (s *Server) resolveUpdateHost(ctx context.Context, w http.ResponseWriter, locale i18n.Context, body updateBody, ids map[string]any) (pool.Host, bool) {
	status, err := s.pool.Status(ctx)
	if err != nil {
		s.recordHostUpdate(body, repairOutcomeUnavailable, 0, repairReasonAggregatorUnreadable)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_update_unavailable",
			map[string]any{"hostId": body.HostID, "reason": repairReasonAggregatorUnreadable},
			mergeFields(ids, map[string]any{"hostReason": repairReasonAggregatorUnreadable}))
		return pool.Host{}, false
	}
	host, found := status.Host(body.HostID)
	if !found {
		s.recordHostUpdate(body, repairOutcomeHostUnknown, 0, "")
		s.writeRepairReply(w, locale, http.StatusNotFound, "pool.host_repair_host_unknown", map[string]any{"hostId": body.HostID}, ids)
		return pool.Host{}, false
	}
	if strings.TrimSpace(host.BaseURL) == "" {
		s.recordHostUpdate(body, repairOutcomeHostAddressUnknown, 0, "")
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_repair_host_address_unknown", map[string]any{"hostId": body.HostID}, ids)
		return pool.Host{}, false
	}
	return host, true
}

// refuseUnreadableCapability answers a host whose control-status could not be
// read: no answer at all is retryable, any other failure is not.
func (s *Server) refuseUnreadableCapability(w http.ResponseWriter, locale i18n.Context, body updateBody, ids map[string]any, err error) {
	var herr *hostctl.Error
	if errors.Is(err, hostctl.ErrHostAddress) || errors.As(err, &herr) {
		log.Printf("pool-control-service: host-update %s: control status: %v", body.HostID, err)
		s.recordHostUpdate(body, repairOutcomeUnavailable, 0, updateReasonStatusUnreadable)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_update_unavailable",
			map[string]any{"hostId": body.HostID, "reason": updateReasonStatusUnreadable},
			mergeFields(ids, map[string]any{"hostReason": updateReasonStatusUnreadable}))
		return
	}
	log.Printf("pool-control-service: host-update %s: control status: %v", body.HostID, err)
	s.recordHostUpdate(body, repairOutcomeHostUnreachable, 0, "")
	s.writeRepairReply(w, locale, http.StatusGatewayTimeout, "pool.host_repair_host_unreachable",
		map[string]any{"hostId": body.HostID, "requestId": body.RequestID}, mergeFields(ids, map[string]any{"retryable": true}))
}

// relayUpdateRefusal maps a host's refusal of the signed request to this
// route's reply. Nothing redirects: the confirmation page shows the status and
// the reason token.
func (s *Server) relayUpdateRefusal(w http.ResponseWriter, locale i18n.Context, body updateBody, ids map[string]any, err error) {
	var herr *hostctl.RepairError
	if !errors.As(err, &herr) {
		log.Printf("pool-control-service: host-update %s: nothing sent: %v", body.HostID, err)
		s.recordHostUpdate(body, repairOutcomeReplyInvalid, 0, "")
		s.writeRepairReply(w, locale, http.StatusBadGateway, "pool.host_repair_reply_invalid",
			map[string]any{"hostId": body.HostID, "detail": updateNotSentReason(err)}, ids)
		return
	}
	hostReason := boundedHostReason(herr.Reason)
	switch {
	case herr.Status == 0:
		s.recordHostUpdate(body, repairOutcomeHostUnreachable, 0, "")
		s.writeRepairReply(w, locale, http.StatusGatewayTimeout, "pool.host_repair_host_unreachable",
			map[string]any{"hostId": body.HostID, "requestId": body.RequestID}, mergeFields(ids, map[string]any{"retryable": true}))
	case herr.Reason == hostctl.RepairReasonReplyInvalid:
		s.recordHostUpdate(body, repairOutcomeReplyInvalid, herr.Status, "")
		s.writeRepairReply(w, locale, http.StatusBadGateway, "pool.host_repair_reply_invalid",
			map[string]any{"hostId": body.HostID, "detail": fmt.Sprintf("HTTP %d", herr.Status)}, mergeFields(ids, map[string]any{"hostStatus": herr.Status}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RepairReasonBusy:
		active := ""
		if hostrepair.ValidRequestID(herr.ActiveRequestID) {
			active = herr.ActiveRequestID
		}
		s.recordHostUpdate(body, repairOutcomeBusy, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_update_busy",
			map[string]any{"hostId": body.HostID, "activeRequestId": active},
			mergeFields(ids, map[string]any{"activeRequestId": active, "activeKind": boundedHostReason(herr.ActiveKind), "stateUrl": herr.StateURL,
				"hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RepairReasonRequestConflict:
		s.recordHostUpdate(body, repairOutcomeRequestConflict, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_update_request_conflict",
			map[string]any{"requestId": body.RequestID},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Retryable:
		s.recordHostUpdate(body, repairOutcomeHostUnavailable, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusServiceUnavailable, "pool.host_update_host_unavailable",
			map[string]any{"hostId": body.HostID, "status": herr.Status, "hostReason": hostReason, "requestId": body.RequestID},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason, "retryable": true}))
	default:
		s.recordHostUpdate(body, repairOutcomeHostRefused, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusBadGateway, "pool.host_update_host_refused",
			map[string]any{"hostId": body.HostID, "status": herr.Status, "hostReason": hostReason},
			mergeFields(ids, map[string]any{"hostStatus": herr.Status, "hostReason": hostReason}))
	}
}

// updateNotSentReason names why hostctl.Update refused before sending, as a
// bounded token.
func updateNotSentReason(err error) string {
	switch {
	case errors.Is(err, hostupdate.ErrInvalidClaim):
		return repairNotSentInvalidClaim
	case errors.Is(err, hostctl.ErrNoProof), errors.Is(err, hostctl.ErrNoUpdateProof):
		return repairNotSentProofMissing
	case errors.Is(err, hostctl.ErrHostAddress):
		return repairNotSentAddressInvalid
	}
	return repairNotSentOther
}

// hostDiagnosticsURL is where the confirmation page sends the operator once
// the host has queued the update: the host's Diagnostics page at the address
// the aggregator reports, never at an address the browser supplied.
func hostDiagnosticsURL(baseURL, requestID string) string {
	return strings.TrimRight(strings.TrimSpace(baseURL), "/") + hostUpdateDiagnosticsPage + "#yhu=" + requestID
}

// handleHostUpdatePrepare is what the confirmation page renders from: the
// host by id and address, the capability the host reports for itself, and a
// request id minted here. It signs and sends nothing, and takes only host and
// scope from the URL.
func (s *Server) handleHostUpdatePrepare(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), hostUpdateBudget)
	defer cancel()
	locale := s.requestLocale(r)
	if !s.updateEnabled() {
		s.writeRepairReply(w, locale, http.StatusServiceUnavailable, "pool.host_update_signing_unconfigured",
			map[string]any{"path": s.updateSigningKeyFile()}, map[string]any{"reason": "update_disabled"})
		return
	}
	q := r.URL.Query()
	hostID, valid := hostrepair.CanonicalHostID(q.Get("host"))
	if !valid {
		s.writeRepairReply(w, locale, http.StatusBadRequest, "pool.host_repair_host_id_invalid", nil, map[string]any{"field": "host"})
		return
	}
	scope := q.Get("scope")
	if scope == "" {
		scope = hostupdate.ScopeRestart
	}
	if !hostupdate.ValidScope(scope) {
		s.writeRepairReply(w, locale, http.StatusBadRequest, "pool.host_update_scope_invalid", nil, map[string]any{"field": "scope"})
		return
	}
	requestID, err := hostrepair.NewRequestID()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "request id unavailable")
		return
	}
	body := updateBody{HostID: hostID, RequestID: requestID, Scope: scope, DrainSeconds: hostupdate.DefaultDrainSeconds}
	host, ok := s.resolveUpdateHost(ctx, w, locale, body, map[string]any{"hostId": hostID})
	if !ok {
		return
	}
	out := map[string]any{"ok": true, "hostId": hostID, "address": host.BaseURL, "hostType": host.HostType(), "requestId": requestID,
		"scope": scope, "drainSeconds": body.DrainSeconds, "expectCommit": body.ExpectCommit}
	cs, err := s.hostctl.ControlStatus(ctx, host.BaseURL)
	reason := updateReasonStatusUnreadable
	if err == nil {
		reason = updateRefusalReason(cs, scope)
		out["scopes"] = cs.Update.Scopes
		out["state"] = boundedHostReason(cs.Update.State)
	}
	out["offer"] = reason == ""
	out["reason"] = reason
	writeJSON(w, http.StatusOK, out)
}

// serveHostUpdatePage serves the confirmation page. It refuses to be framed,
// so another page cannot dress the credential prompt in its own frame.
func (s *Server) serveHostUpdatePage() http.HandlerFunc {
	page := s.servePage("hostupdate.html")
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		page(w, r)
	}
}

// updateSigningKeyFile names the key file for an operator: the one this
// daemon was launched with, else the default.
func (s *Server) updateSigningKeyFile() string {
	if f := strings.TrimSpace(s.opts.UpdateSigningKeyFile); f != "" {
		return f
	}
	return config.DefaultUpdateSigningKeyFile
}

// recordHostUpdate audits one per-host update. Only validated tokens reach
// the entry -- never a credential, a proof, a key or caller-supplied text.
func (s *Server) recordHostUpdate(b updateBody, outcome string, hostStatus int, hostReason string) {
	field := func(v string) string {
		if v == "" {
			return repairFieldInvalidPlaceholder
		}
		return v
	}
	drain := repairFieldInvalidPlaceholder
	if b.DrainSeconds > 0 {
		drain = strconv.Itoa(b.DrainSeconds)
	}
	detail := fmt.Sprintf("request=%s scope=%s drainSeconds=%s expectCommit=%s outcome=%s hostStatus=%d hostReason=%s",
		field(b.RequestID), field(b.Scope), drain, field(b.ExpectCommit), outcome, hostStatus, field(boundedHostReason(hostReason)))
	target := field(b.HostID)
	ok := outcome == hostctl.UpdateActionQueued || outcome == hostctl.UpdateActionAlreadyQueued ||
		outcome == hostctl.UpdateActionAlreadyClaimed || outcome == hostctl.UpdateActionCompleted
	log.Printf("pool-control-service: host-update %s: %s", target, detail)
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		TimeUTC: now.UTC().Format(time.RFC3339),
		Action:  "host-update", Target: target, OK: ok, Detail: detail,
	})
}
