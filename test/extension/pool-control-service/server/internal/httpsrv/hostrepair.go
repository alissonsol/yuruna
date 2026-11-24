// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42012f8d-3e09-49a0-af0d-216792697912

package httpsrv

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"
	"yuruna.com/test/extension/extension-sdk/strictjson"

	"pool-control-service/internal/config"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/state"
	"yuruna.com/test/extension/extension-sdk/hostrepair"
	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/jsonbody"
	"yuruna.com/test/extension/extension-sdk/pool"
)

// Per-host repair: one operator request, for one host, carried to that host's
// status service with two proofs -- the legacy control proof its transport
// gate checks, and a repair proof bound to this host, this request id, this
// tier and ceiling, minted here from the provisioned signing authority.
//
// It is deliberately NOT an action of the pool-wide host-control fan-out: a
// repair can stop a runner and restart a hypervisor, so it is authorized per
// host by a credential of its own, never by membership in a pool. That route
// keeps refusing "repair" before it makes any outbound call.

// hostRepairBudget bounds the whole route: the aggregator read, a legacy
// proof that may come from the aggregator, and one request to the host with
// its single same-id resend.
const hostRepairBudget = 25 * time.Second

// defaultRemoteRung is the ceiling a request that names none asks for: the
// highest rung a remote request may name. The host only ever lowers it to what
// it can actually execute.
const defaultRemoteRung = pool.RungRestartBroker

// Audit outcomes. Each is a bounded token, so the audit line never carries
// text a caller supplied.
const (
	repairOutcomeBodyInvalid         = "body_invalid"
	repairOutcomeSigningUnconfigured = "signing_unconfigured"
	repairOutcomeHostUnknown         = "host_unknown"
	repairOutcomeHostAddressUnknown  = "host_address_unknown"
	repairOutcomeUnavailable         = pool.RepairUnavailable
	repairOutcomeControlProofMissing = "control_proof_unavailable"
	repairOutcomeMintFailed          = "mint_failed"
	repairOutcomeHostRefused         = "host_refused"
	repairOutcomeHostUnavailable     = "host_unavailable"
	repairOutcomeHostUnreachable     = pool.RepairReasonHostUnreachable
	repairOutcomeReplyInvalid        = "reply_invalid"
	repairOutcomeBusy                = hostctl.RepairReasonBusy
	repairOutcomeRequestConflict     = hostctl.RepairReasonRequestConflict
	repairOutcomeRequestClosed       = hostctl.RepairReasonRequestClosed
	repairReasonAggregatorUnreadable = "aggregator_unreadable"
	repairReasonUnrecognized         = "unrecognized"
	repairFieldInvalidPlaceholder    = "-"
	repairFieldNamePlaceholder       = "field"
)

// hostReasonRE bounds a reason code a host returned before it is relayed or
// audited: a host is read without authentication, and its reply must not be
// able to put arbitrary text into this service's replies or audit log.
var hostReasonRE = regexp.MustCompile(`^[a-z][a-z0-9_.-]{0,63}$`)

// fieldNameRE bounds a rejected field name echoed back to the caller.
var fieldNameRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

// LoadRepairSecrets reads the repair signing authority and the
// operator credential for this service. Remote repair needs both, and each
// must be a secret of its own: a file that is missing, malformed or readable
// by other users, an authority or credential equal to the legacy internal
// authentication key, or a credential whose key material equals the
// authority, is refused. The legacy key is reachable from the lab-token
// exchange and the dashboard's enrollment code, so a repair secret equal to
// it would inherit that whole trust path. The error names files, never
// content; the credential is returned as its canonical line.
func LoadRepairSecrets(authorityFile, credentialFile, legacyToken string) ([]byte, string, error) {
	if strings.TrimSpace(authorityFile) == "" || strings.TrimSpace(credentialFile) == "" {
		return nil, "", errors.New("no repair authority or credential file configured")
	}
	authority, err := hostrepair.LoadSecretFile(authorityFile, hostrepair.AuthorityPrefix)
	if err != nil {
		return nil, "", err
	}
	credential, err := hostrepair.LoadSecretFile(credentialFile, hostrepair.CredentialPrefix)
	if err != nil {
		return nil, "", err
	}
	credentialLine := hostrepair.FormatSecret(hostrepair.CredentialPrefix, credential)
	authorityLine := hostrepair.FormatSecret(hostrepair.AuthorityPrefix, authority)
	legacy := []byte(strings.TrimSpace(legacyToken))
	same := func(a, b []byte) bool { return len(a) > 0 && subtle.ConstantTimeCompare(a, b) == 1 }
	switch {
	case same(legacy, authority) || same(legacy, []byte(authorityLine)):
		return nil, "", fmt.Errorf("the repair authority in %s equals the internal authentication key", authorityFile)
	case same(legacy, credential) || same(legacy, []byte(credentialLine)):
		return nil, "", fmt.Errorf("the operator credential in %s equals the internal authentication key", credentialFile)
	case same(credential, authority):
		return nil, "", fmt.Errorf("the operator credential in %s is the signing authority itself", credentialFile)
	}
	return authority, credentialLine, nil
}

// repairEnabled reports whether both halves of remote repair are
// provisioned: the credential that admits a caller and the authority that
// signs for a host.
func (s *Server) repairEnabled() bool {
	return s.operatorGate.Configured() && s.repairSigner != nil
}

// repairBody is the validated request.
type repairBody struct {
	HostID, RequestID, Tier, MaxRung string
}

// repairRefusal is one validation failure: the catalog key, its arguments,
// and the field it concerns when there is one.
type repairRefusal struct {
	status int
	key    string
	args   map[string]any
	field  string
}

// decodeRepairBody reads the body strictly: at most MaxRepairRequestBytes,
// one JSON object whose only keys are hostId, requestId, tier and maxRung,
// each once and each a string, and nothing after it. Every other key --
// including every spelling of force or hard-stop -- is refused rather than
// ignored, so no option can ride in unnoticed. A key that differs from an
// allowed one only in case or punctuation counts as that key for the
// duplicate check.
//
// The body must arrive within the shared body read timeout, like every other
// small JSON body here.
func decodeRepairBody(w http.ResponseWriter, r *http.Request) (repairBody, *repairRefusal) {
	raw, err := jsonbody.ReadRequest(w, r, config.MaxRepairRequestBytes)
	if errors.Is(err, jsonbody.ErrOversize) {
		return repairBody{}, &repairRefusal{status: http.StatusRequestEntityTooLarge, key: "pool.host_repair_body_invalid", args: map[string]any{"detail": "too_large"}}
	}
	if err != nil {
		return repairBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_body_invalid", args: map[string]any{"detail": "unreadable"}}
	}
	invalid := func(detail string) (repairBody, *repairRefusal) {
		return repairBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_body_invalid", args: map[string]any{"detail": detail}}
	}
	var body repairBody
	values, refusal := strictjson.Strings(raw, map[string]bool{"hostId": true, "requestId": true, "tier": true, "maxRung": true}, normalizeFieldName)
	if refusal != nil {
		if refusal.Detail != "unsupported_field" {
			return invalid(refusal.Detail)
		}
		shown := refusal.Field
		if !fieldNameRE.MatchString(shown) {
			shown = repairFieldNamePlaceholder
		}
		return repairBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_field_unsupported", args: map[string]any{"field": shown}, field: shown}
	}
	body.HostID, body.RequestID, body.Tier, body.MaxRung = values["hostId"], values["requestId"], values["tier"], values["maxRung"]

	hostID, ok := hostrepair.CanonicalHostID(body.HostID)
	if !ok {
		return repairBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_host_id_invalid", field: "hostId"}
	}
	body.HostID = hostID
	if !hostrepair.ValidRequestID(body.RequestID) {
		return repairBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_request_id_invalid", field: "requestId"}
	}
	if body.Tier != hostrepair.TierRestart {
		return repairBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_tier_unsupported", field: "tier"}
	}
	if body.MaxRung == "" {
		body.MaxRung = defaultRemoteRung
	}
	if !hostrepair.ValidRemoteRung(body.MaxRung) {
		return repairBody{}, &repairRefusal{status: http.StatusBadRequest, key: "pool.host_repair_rung_unsupported", field: "maxRung"}
	}
	return body, nil
}

// normalizeFieldName folds case and drops everything but letters and digits,
// so hostId, HOSTID and host_id are one key for the duplicate check.
func normalizeFieldName(name string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// handleHostRepair admits one remote repair for one host. It runs behind the
// ordinary write gate AND the operator credential gate; the MCP tool reaches it
// raw, after the same two gates ran on the incoming request.
func (s *Server) handleHostRepair(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), hostRepairBudget)
	defer cancel()
	locale := s.requestLocale(r)

	if s.repairSigner == nil {
		s.recordHostRepair(repairBody{}, repairOutcomeSigningUnconfigured, 0, "")
		s.writeRepairReply(w, locale, http.StatusServiceUnavailable, "pool.host_repair_signing_unconfigured",
			map[string]any{"path": s.repairAuthorityFile()}, nil)
		return
	}
	body, refusal := decodeRepairBody(w, r)
	if refusal != nil {
		s.recordHostRepair(repairBody{}, repairOutcomeBodyInvalid, 0, "")
		extra := map[string]any{}
		if refusal.field != "" {
			extra["field"] = refusal.field
		}
		s.writeRepairReply(w, locale, refusal.status, refusal.key, refusal.args, extra)
		return
	}
	ids := map[string]any{"hostId": body.HostID, "requestId": body.RequestID}

	status, err := s.pool.Status(ctx)
	if err != nil {
		s.recordHostRepair(body, repairOutcomeUnavailable, 0, repairReasonAggregatorUnreadable)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_repair_unavailable",
			map[string]any{"hostId": body.HostID, "reason": repairReasonAggregatorUnreadable},
			mergeFields(ids, map[string]any{"hostReason": repairReasonAggregatorUnreadable}))
		return
	}
	host, found := status.Host(body.HostID)
	if !found {
		s.recordHostRepair(body, repairOutcomeHostUnknown, 0, "")
		s.writeRepairReply(w, locale, http.StatusNotFound, "pool.host_repair_host_unknown", map[string]any{"hostId": body.HostID}, ids)
		return
	}
	if strings.TrimSpace(host.BaseURL) == "" {
		s.recordHostRepair(body, repairOutcomeHostAddressUnknown, 0, "")
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_repair_host_address_unknown", map[string]any{"hostId": body.HostID}, ids)
		return
	}
	if !host.Repair.RemoteUsable() {
		reason := capabilityRefusalReason(host.Repair)
		s.recordHostRepair(body, repairOutcomeUnavailable, 0, reason)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_repair_unavailable",
			map[string]any{"hostId": body.HostID, "reason": reason}, mergeFields(ids, map[string]any{"hostReason": reason}))
		return
	}

	proofs, err := s.controlProofs(ctx, []string{body.HostID}, map[string]string{body.HostID: host.BaseURL}, "")
	controlProof := proofs[body.HostID]
	if err == nil && controlProof == "" {
		err = &controlProofError{reason: controlProofAggregatorRefused, text: "no control proof for " + body.HostID}
	}
	if err != nil {
		log.Printf("pool-control-service: host-repair %s: %v", body.HostID, err)
		s.recordHostRepair(body, repairOutcomeControlProofMissing, 0, "")
		s.writeRepairReply(w, locale, http.StatusServiceUnavailable, "pool.host_repair_control_proof_unavailable",
			map[string]any{"hostId": body.HostID, "detail": controlProofFailureReason(err)}, ids)
		return
	}
	repairProof, _, err := s.repairSigner.Mint(body.HostID, body.RequestID, body.Tier, body.MaxRung, time.Now())
	if err != nil {
		s.recordHostRepair(body, repairOutcomeMintFailed, 0, "")
		s.writeRepairReply(w, locale, http.StatusInternalServerError, "pool.host_repair_mint_failed", map[string]any{"hostId": body.HostID}, ids)
		return
	}

	reply, err := s.hostctl.Repair(ctx, host.BaseURL, hostctl.RepairRequest{RequestID: body.RequestID, Tier: body.Tier, MaxRung: body.MaxRung},
		controlProof, repairProof)
	if err == nil {
		out := mergeFields(ids, map[string]any{"ok": true, "action": reply.Action, "stateUrl": reply.StateURL, "retryable": false})
		code := http.StatusAccepted
		if reply.Replay {
			code = http.StatusOK
			out["replay"] = true
			out["verdict"] = reply.Verdict
			out["state"] = reply.State
		}
		if reply.Ceiling != "" {
			out["ceiling"] = reply.Ceiling
		}
		s.recordHostRepair(body, reply.Action, reply.Status, "")
		writeJSON(w, code, out)
		return
	}
	var herr *hostctl.RepairError
	if !errors.As(err, &herr) {
		log.Printf("pool-control-service: host-repair %s: nothing sent: %v", body.HostID, err)
		s.recordHostRepair(body, repairOutcomeReplyInvalid, 0, "")
		s.writeRepairReply(w, locale, http.StatusBadGateway, "pool.host_repair_reply_invalid",
			map[string]any{"hostId": body.HostID, "detail": repairNotSentReason(err)}, ids)
		return
	}
	hostReason := boundedHostReason(herr.Reason)
	switch {
	case herr.Status == 0:
		s.recordHostRepair(body, repairOutcomeHostUnreachable, 0, "")
		s.writeRepairReply(w, locale, http.StatusGatewayTimeout, "pool.host_repair_host_unreachable",
			map[string]any{"hostId": body.HostID, "requestId": body.RequestID}, mergeFields(ids, map[string]any{"retryable": true}))
	case herr.Reason == hostctl.RepairReasonReplyInvalid:
		s.recordHostRepair(body, repairOutcomeReplyInvalid, herr.Status, "")
		s.writeRepairReply(w, locale, http.StatusBadGateway, "pool.host_repair_reply_invalid",
			map[string]any{"hostId": body.HostID, "detail": fmt.Sprintf("HTTP %d", herr.Status)}, mergeFields(ids, map[string]any{"hostStatus": herr.Status}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RepairReasonBusy:
		s.recordHostRepair(body, repairOutcomeBusy, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_repair_busy",
			map[string]any{"hostId": body.HostID, "activeRequestId": herr.ActiveRequestID},
			mergeFields(ids, map[string]any{"activeRequestId": herr.ActiveRequestID, "activeKind": herr.ActiveKind, "stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RepairReasonRequestConflict:
		s.recordHostRepair(body, repairOutcomeRequestConflict, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_repair_request_conflict",
			map[string]any{"requestId": body.RequestID},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RepairReasonRequestClosed:
		s.recordHostRepair(body, repairOutcomeRequestClosed, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusConflict, "pool.host_repair_request_closed",
			map[string]any{"hostId": body.HostID, "requestId": body.RequestID, "state": boundedHostReason(herr.State), "verdict": boundedHostReason(herr.Verdict)},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "state": boundedHostReason(herr.State), "verdict": boundedHostReason(herr.Verdict),
				"hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Retryable:
		s.recordHostRepair(body, repairOutcomeHostUnavailable, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusServiceUnavailable, "pool.host_repair_host_unavailable",
			map[string]any{"hostId": body.HostID, "status": herr.Status, "hostReason": hostReason, "requestId": body.RequestID},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason, "retryable": true}))
	default:
		s.recordHostRepair(body, repairOutcomeHostRefused, herr.Status, hostReason)
		s.writeRepairReply(w, locale, http.StatusBadGateway, "pool.host_repair_host_refused",
			map[string]any{"hostId": body.HostID, "status": herr.Status, "hostReason": hostReason},
			mergeFields(ids, map[string]any{"hostStatus": herr.Status, "hostReason": hostReason}))
	}
}

// capabilityRefusalReason names why a host's capability is not remotely
// usable, as a bounded code: the capability's own reason when it is
// unavailable, otherwise the state of the host's verifier key.
func capabilityRefusalReason(r pool.HostRepair) string {
	switch {
	case r.Protocol != pool.RepairProtocolVersion && r.Availability == pool.RepairAvailable:
		return pool.RepairReasonProtocolUnsupported
	case r.Availability != pool.RepairAvailable:
		if r.Reason != "" {
			return r.Reason
		}
		return pool.RepairUnavailable
	}
	switch r.Remote {
	case pool.RepairRemoteInvalid:
		return hostrepair.ReasonRemoteKeyInvalid
	case pool.RepairRemoteUnqualified:
		return hostrepair.ReasonRemoteUnqualified
	}
	return hostrepair.ReasonRemoteUnprovisioned
}

// Why hostctl.Repair sent nothing, as bounded tokens.
const (
	repairNotSentInvalidClaim   = "invalid_claim"
	repairNotSentProofMissing   = "proof_missing"
	repairNotSentAddressInvalid = "host_address_unusable"
	repairNotSentOther          = "request_not_sent"
)

// repairNotSentReason names why hostctl.Repair refused before sending. Its
// error text can quote the host address the aggregator reported, which this
// service reads without authentication, so only this token reaches a reply;
// the text goes to the log.
func repairNotSentReason(err error) string {
	switch {
	case errors.Is(err, hostrepair.ErrInvalidClaim):
		return repairNotSentInvalidClaim
	case errors.Is(err, hostctl.ErrNoProof), errors.Is(err, hostctl.ErrNoRepairProof):
		return repairNotSentProofMissing
	case errors.Is(err, hostctl.ErrHostAddress):
		return repairNotSentAddressInvalid
	}
	return repairNotSentOther
}

// boundedHostReason relays a host's reason code only when it has the shape of
// one.
func boundedHostReason(reason string) string {
	if reason == "" {
		return ""
	}
	if hostReasonRE.MatchString(reason) {
		return reason
	}
	return repairReasonUnrecognized
}

func mergeFields(maps ...map[string]any) map[string]any {
	out := map[string]any{}
	for _, m := range maps {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}

// requestLocale is the negotiated locale, which the MCP tool's synthesized
// request does not carry.
func (s *Server) requestLocale(r *http.Request) i18n.Context {
	locale := i18n.FromRequest(r)
	if locale.ResolvedTag == "" {
		locale = s.negotiator().Resolve(r)
	}
	return locale
}

// writeRepairReply writes a refusal: the catalog key as code, its localized
// text as error, and the structured fields a caller branches on.
func (s *Server) writeRepairReply(w http.ResponseWriter, locale i18n.Context, status int, key string, args, extra map[string]any) {
	out := map[string]any{"ok": false, "code": key, "error": Translate(locale, key, args), "retryable": false}
	for k, v := range extra {
		out[k] = v
	}
	i18n.Apply(w.Header(), locale)
	writeJSON(w, status, out)
}

// repairAuthorityFile names the authority file for an operator: the one this
// daemon was launched with, else the default.
func (s *Server) repairAuthorityFile() string {
	if f := strings.TrimSpace(s.opts.RepairAuthorityFile); f != "" {
		return f
	}
	return config.DefaultRepairAuthorityFile
}

// recordHostRepair audits one per-host repair. Only validated tokens reach
// the entry -- never a credential, a proof, a key or caller-supplied text --
// so the audit log is safe to read from the shared state directory.
func (s *Server) recordHostRepair(b repairBody, outcome string, hostStatus int, hostReason string) {
	field := func(v string) string {
		if v == "" {
			return repairFieldInvalidPlaceholder
		}
		return v
	}
	detail := fmt.Sprintf("request=%s tier=%s maxRung=%s outcome=%s hostStatus=%d hostReason=%s",
		field(b.RequestID), field(b.Tier), field(b.MaxRung), outcome, hostStatus, field(boundedHostReason(hostReason)))
	target := field(b.HostID)
	ok := outcome == hostctl.RepairActionSpawned || outcome == hostctl.RepairActionAlreadyClaimed || outcome == hostctl.RepairActionCompleted
	log.Printf("pool-control-service: host-repair %s: %s", target, detail)
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		TimeUTC: now.UTC().Format(time.RFC3339),
		Action:  "host-repair", Target: target, OK: ok, Detail: detail,
	})
}

// auditOperatorGate records a refused operator credential check with the source
// address. A lab-key holder probing the repair route is exactly who an
// operator wants to see; successful checks are not audited here.
func (s *Server) auditOperatorGate(ip, outcome string) {
	if outcome == hostrepair.AuditOK {
		return
	}
	log.Printf("pool-control-service: operator credential %s from %s", outcome, ip)
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		TimeUTC: now.UTC().Format(time.RFC3339),
		Action:  "operator-credential", Target: outcome, OK: false, Detail: "from " + ip,
	})
}
