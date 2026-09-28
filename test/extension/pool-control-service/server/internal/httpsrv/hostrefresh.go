// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"pool-control-service/internal/config"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/state"
	"yuruna.com/test/extension/extension-sdk/hostrefresh"
	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/pool"
)

// Per-host refresh: one operator request, for one host, carried to that host's
// status service with two proofs -- the legacy control proof its transport
// gate checks, and a refresh proof bound to this host, this request id, this
// tier and ceiling, minted here from the provisioned signing authority.
//
// It is deliberately NOT an action of the pool-wide host-control fan-out: a
// refresh can stop a runner and restart a hypervisor, so it is authorized per
// host by a credential of its own, never by membership in a pool. That route
// keeps refusing "refresh" before it makes any outbound call.

// hostRefreshBudget bounds the whole route: the aggregator read, a legacy
// proof that may come from the aggregator, and one request to the host with
// its single same-id resend.
const hostRefreshBudget = 25 * time.Second

// defaultRemoteRung is the ceiling a request that names none asks for: the
// highest rung a remote request may name. The host only ever lowers it to what
// it can actually execute.
const defaultRemoteRung = pool.RungRestartBroker

// Audit outcomes. Each is a bounded token, so the audit line never carries
// text a caller supplied.
const (
	refreshOutcomeBodyInvalid         = "body_invalid"
	refreshOutcomeSigningUnconfigured = "signing_unconfigured"
	refreshOutcomeHostUnknown         = "host_unknown"
	refreshOutcomeHostAddressUnknown  = "host_address_unknown"
	refreshOutcomeUnavailable         = pool.RefreshUnavailable
	refreshOutcomeControlProofMissing = "control_proof_unavailable"
	refreshOutcomeMintFailed          = "mint_failed"
	refreshOutcomeHostRefused         = "host_refused"
	refreshOutcomeHostUnavailable     = "host_unavailable"
	refreshOutcomeHostUnreachable     = pool.RefreshReasonHostUnreachable
	refreshOutcomeReplyInvalid        = "reply_invalid"
	refreshOutcomeBusy                = hostctl.RefreshReasonBusy
	refreshOutcomeRequestConflict     = hostctl.RefreshReasonRequestConflict
	refreshOutcomeRequestClosed       = hostctl.RefreshReasonRequestClosed
	refreshReasonAggregatorUnreadable = "aggregator_unreadable"
	refreshReasonUnrecognized         = "unrecognized"
	refreshFieldInvalidPlaceholder    = "-"
	refreshFieldNamePlaceholder       = "field"
)

// hostReasonRE bounds a reason code a host returned before it is relayed or
// audited: a host is read without authentication, and its reply must not be
// able to put arbitrary text into this service's replies or audit log.
var hostReasonRE = regexp.MustCompile(`^[a-z][a-z0-9_.-]{0,63}$`)

// fieldNameRE bounds a rejected field name echoed back to the caller.
var fieldNameRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

// LoadRefreshSecrets reads the refresh signing authority and the operator
// refresh credential for this service. Remote refresh needs both, and each
// must be a secret of its own: a file that is missing, malformed or readable
// by other users, an authority or credential equal to the legacy internal
// authentication key, or a credential whose key material equals the
// authority, is refused. The legacy key is reachable from the lab-token
// exchange and the dashboard's enrollment code, so a refresh secret equal to
// it would inherit that whole trust path. The error names files, never
// content; the credential is returned as its canonical line.
func LoadRefreshSecrets(authorityFile, credentialFile, legacyToken string) ([]byte, string, error) {
	if strings.TrimSpace(authorityFile) == "" || strings.TrimSpace(credentialFile) == "" {
		return nil, "", errors.New("no refresh authority or credential file configured")
	}
	authority, err := hostrefresh.LoadSecretFile(authorityFile, hostrefresh.AuthorityPrefix)
	if err != nil {
		return nil, "", err
	}
	credential, err := hostrefresh.LoadSecretFile(credentialFile, hostrefresh.CredentialPrefix)
	if err != nil {
		return nil, "", err
	}
	credentialLine := hostrefresh.FormatSecret(hostrefresh.CredentialPrefix, credential)
	authorityLine := hostrefresh.FormatSecret(hostrefresh.AuthorityPrefix, authority)
	legacy := []byte(strings.TrimSpace(legacyToken))
	same := func(a, b []byte) bool { return len(a) > 0 && subtle.ConstantTimeCompare(a, b) == 1 }
	switch {
	case same(legacy, authority) || same(legacy, []byte(authorityLine)):
		return nil, "", fmt.Errorf("the refresh authority in %s equals the internal authentication key", authorityFile)
	case same(legacy, credential) || same(legacy, []byte(credentialLine)):
		return nil, "", fmt.Errorf("the refresh credential in %s equals the internal authentication key", credentialFile)
	case same(credential, authority):
		return nil, "", fmt.Errorf("the refresh credential in %s is the signing authority itself", credentialFile)
	}
	return authority, credentialLine, nil
}

// refreshEnabled reports whether both halves of remote refresh are
// provisioned: the credential that admits a caller and the authority that
// signs for a host.
func (s *Server) refreshEnabled() bool {
	return s.refreshGate.Configured() && s.refreshSigner != nil
}

// refreshBody is the validated request.
type refreshBody struct {
	HostID, RequestID, Tier, MaxRung string
}

// refreshRefusal is one validation failure: the catalog key, its arguments,
// and the field it concerns when there is one.
type refreshRefusal struct {
	status int
	key    string
	args   map[string]any
	field  string
}

// decodeRefreshBody reads the body strictly: at most MaxRefreshRequestBytes,
// one JSON object whose only keys are hostId, requestId, tier and maxRung,
// each once and each a string, and nothing after it. Every other key --
// including every spelling of force or hard-stop -- is refused rather than
// ignored, so no option can ride in unnoticed. A key that differs from an
// allowed one only in case or punctuation counts as that key for the
// duplicate check.
func decodeRefreshBody(r *http.Request) (refreshBody, *refreshRefusal) {
	raw, err := io.ReadAll(io.LimitReader(r.Body, config.MaxRefreshRequestBytes+1))
	if err != nil {
		return refreshBody{}, &refreshRefusal{status: http.StatusBadRequest, key: "pool.host_refresh_body_invalid", args: map[string]any{"detail": "unreadable"}}
	}
	if len(raw) > config.MaxRefreshRequestBytes {
		return refreshBody{}, &refreshRefusal{status: http.StatusRequestEntityTooLarge, key: "pool.host_refresh_body_invalid", args: map[string]any{"detail": "too_large"}}
	}
	invalid := func(detail string) (refreshBody, *refreshRefusal) {
		return refreshBody{}, &refreshRefusal{status: http.StatusBadRequest, key: "pool.host_refresh_body_invalid", args: map[string]any{"detail": detail}}
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	if err != nil || tok != json.Delim('{') {
		return invalid("not_an_object")
	}
	allowed := map[string]*string{}
	var body refreshBody
	allowed["hostId"], allowed["requestId"], allowed["tier"], allowed["maxRung"] = &body.HostID, &body.RequestID, &body.Tier, &body.MaxRung
	seen := map[string]bool{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return invalid("malformed_json")
		}
		name, _ := tok.(string)
		norm := normalizeFieldName(name)
		if seen[norm] {
			return invalid("duplicate_key")
		}
		seen[norm] = true
		dst, ok := allowed[name]
		if !ok {
			shown := name
			if !fieldNameRE.MatchString(shown) {
				shown = refreshFieldNamePlaceholder
			}
			return refreshBody{}, &refreshRefusal{status: http.StatusBadRequest, key: "pool.host_refresh_field_unsupported",
				args: map[string]any{"field": shown}, field: shown}
		}
		val, err := dec.Token()
		if err != nil {
			return invalid("malformed_json")
		}
		str, isString := val.(string)
		if !isString {
			return invalid("value_not_a_string")
		}
		*dst = str
	}
	if tok, err := dec.Token(); err != nil || tok != json.Delim('}') {
		return invalid("malformed_json")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return invalid("trailing_data")
	}

	hostID, ok := hostrefresh.CanonicalHostID(body.HostID)
	if !ok {
		return refreshBody{}, &refreshRefusal{status: http.StatusBadRequest, key: "pool.host_refresh_host_id_invalid", field: "hostId"}
	}
	body.HostID = hostID
	if !hostrefresh.ValidRequestID(body.RequestID) {
		return refreshBody{}, &refreshRefusal{status: http.StatusBadRequest, key: "pool.host_refresh_request_id_invalid", field: "requestId"}
	}
	if body.Tier != hostrefresh.TierRestart {
		return refreshBody{}, &refreshRefusal{status: http.StatusBadRequest, key: "pool.host_refresh_tier_unsupported", field: "tier"}
	}
	if body.MaxRung == "" {
		body.MaxRung = defaultRemoteRung
	}
	if !hostrefresh.ValidRemoteRung(body.MaxRung) {
		return refreshBody{}, &refreshRefusal{status: http.StatusBadRequest, key: "pool.host_refresh_rung_unsupported", field: "maxRung"}
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

// handleHostRefresh admits one remote refresh for one host. It runs behind the
// ordinary write gate AND the refresh credential gate; the MCP tool reaches it
// raw, after the same two gates ran on the incoming request.
func (s *Server) handleHostRefresh(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), hostRefreshBudget)
	defer cancel()
	locale := s.requestLocale(r)

	if s.refreshSigner == nil {
		s.recordHostRefresh(refreshBody{}, refreshOutcomeSigningUnconfigured, 0, "")
		s.writeRefreshReply(w, locale, http.StatusServiceUnavailable, "pool.host_refresh_signing_unconfigured",
			map[string]any{"path": s.refreshAuthorityFile()}, nil)
		return
	}
	body, refusal := decodeRefreshBody(r)
	if refusal != nil {
		s.recordHostRefresh(refreshBody{}, refreshOutcomeBodyInvalid, 0, "")
		extra := map[string]any{}
		if refusal.field != "" {
			extra["field"] = refusal.field
		}
		s.writeRefreshReply(w, locale, refusal.status, refusal.key, refusal.args, extra)
		return
	}
	ids := map[string]any{"hostId": body.HostID, "requestId": body.RequestID}

	status, err := s.pool.Status(ctx)
	if err != nil {
		s.recordHostRefresh(body, refreshOutcomeUnavailable, 0, refreshReasonAggregatorUnreadable)
		s.writeRefreshReply(w, locale, http.StatusConflict, "pool.host_refresh_unavailable",
			map[string]any{"hostId": body.HostID, "reason": refreshReasonAggregatorUnreadable},
			mergeFields(ids, map[string]any{"hostReason": refreshReasonAggregatorUnreadable}))
		return
	}
	host, found := status.Host(body.HostID)
	if !found {
		s.recordHostRefresh(body, refreshOutcomeHostUnknown, 0, "")
		s.writeRefreshReply(w, locale, http.StatusNotFound, "pool.host_refresh_host_unknown", map[string]any{"hostId": body.HostID}, ids)
		return
	}
	if strings.TrimSpace(host.BaseURL) == "" {
		s.recordHostRefresh(body, refreshOutcomeHostAddressUnknown, 0, "")
		s.writeRefreshReply(w, locale, http.StatusConflict, "pool.host_refresh_host_address_unknown", map[string]any{"hostId": body.HostID}, ids)
		return
	}
	if !host.Refresh.RemoteUsable() {
		reason := capabilityRefusalReason(host.Refresh)
		s.recordHostRefresh(body, refreshOutcomeUnavailable, 0, reason)
		s.writeRefreshReply(w, locale, http.StatusConflict, "pool.host_refresh_unavailable",
			map[string]any{"hostId": body.HostID, "reason": reason}, mergeFields(ids, map[string]any{"hostReason": reason}))
		return
	}

	controlProof, err := s.controlProof(ctx, []string{body.HostID}, map[string]string{body.HostID: host.BaseURL})
	if err != nil {
		log.Printf("pool-control-service: host-refresh %s: %v", body.HostID, err)
		s.recordHostRefresh(body, refreshOutcomeControlProofMissing, 0, "")
		s.writeRefreshReply(w, locale, http.StatusServiceUnavailable, "pool.host_refresh_control_proof_unavailable",
			map[string]any{"hostId": body.HostID, "detail": controlProofFailureReason(err)}, ids)
		return
	}
	refreshProof, _, err := s.refreshSigner.Mint(body.HostID, body.RequestID, body.Tier, body.MaxRung, time.Now())
	if err != nil {
		s.recordHostRefresh(body, refreshOutcomeMintFailed, 0, "")
		s.writeRefreshReply(w, locale, http.StatusInternalServerError, "pool.host_refresh_mint_failed", map[string]any{"hostId": body.HostID}, ids)
		return
	}

	reply, err := s.hostctl.Refresh(ctx, host.BaseURL, hostctl.RefreshRequest{RequestID: body.RequestID, Tier: body.Tier, MaxRung: body.MaxRung},
		controlProof, refreshProof)
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
		s.recordHostRefresh(body, reply.Action, reply.Status, "")
		writeJSON(w, code, out)
		return
	}
	var herr *hostctl.RefreshError
	if !errors.As(err, &herr) {
		log.Printf("pool-control-service: host-refresh %s: nothing sent: %v", body.HostID, err)
		s.recordHostRefresh(body, refreshOutcomeReplyInvalid, 0, "")
		s.writeRefreshReply(w, locale, http.StatusBadGateway, "pool.host_refresh_reply_invalid",
			map[string]any{"hostId": body.HostID, "detail": refreshNotSentReason(err)}, ids)
		return
	}
	hostReason := boundedHostReason(herr.Reason)
	switch {
	case herr.Status == 0:
		s.recordHostRefresh(body, refreshOutcomeHostUnreachable, 0, "")
		s.writeRefreshReply(w, locale, http.StatusGatewayTimeout, "pool.host_refresh_host_unreachable",
			map[string]any{"hostId": body.HostID, "requestId": body.RequestID}, mergeFields(ids, map[string]any{"retryable": true}))
	case herr.Reason == hostctl.RefreshReasonReplyInvalid:
		s.recordHostRefresh(body, refreshOutcomeReplyInvalid, herr.Status, "")
		s.writeRefreshReply(w, locale, http.StatusBadGateway, "pool.host_refresh_reply_invalid",
			map[string]any{"hostId": body.HostID, "detail": fmt.Sprintf("HTTP %d", herr.Status)}, mergeFields(ids, map[string]any{"hostStatus": herr.Status}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RefreshReasonBusy:
		s.recordHostRefresh(body, refreshOutcomeBusy, herr.Status, hostReason)
		s.writeRefreshReply(w, locale, http.StatusConflict, "pool.host_refresh_busy",
			map[string]any{"hostId": body.HostID, "activeRequestId": herr.ActiveRequestID},
			mergeFields(ids, map[string]any{"activeRequestId": herr.ActiveRequestID, "activeKind": herr.ActiveKind, "stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RefreshReasonRequestConflict:
		s.recordHostRefresh(body, refreshOutcomeRequestConflict, herr.Status, hostReason)
		s.writeRefreshReply(w, locale, http.StatusConflict, "pool.host_refresh_request_conflict",
			map[string]any{"requestId": body.RequestID},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Status == http.StatusConflict && herr.Reason == hostctl.RefreshReasonRequestClosed:
		s.recordHostRefresh(body, refreshOutcomeRequestClosed, herr.Status, hostReason)
		s.writeRefreshReply(w, locale, http.StatusConflict, "pool.host_refresh_request_closed",
			map[string]any{"hostId": body.HostID, "requestId": body.RequestID, "state": boundedHostReason(herr.State), "verdict": boundedHostReason(herr.Verdict)},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "state": boundedHostReason(herr.State), "verdict": boundedHostReason(herr.Verdict),
				"hostStatus": herr.Status, "hostReason": hostReason}))
	case herr.Retryable:
		s.recordHostRefresh(body, refreshOutcomeHostUnavailable, herr.Status, hostReason)
		s.writeRefreshReply(w, locale, http.StatusServiceUnavailable, "pool.host_refresh_host_unavailable",
			map[string]any{"hostId": body.HostID, "status": herr.Status, "hostReason": hostReason, "requestId": body.RequestID},
			mergeFields(ids, map[string]any{"stateUrl": herr.StateURL, "hostStatus": herr.Status, "hostReason": hostReason, "retryable": true}))
	default:
		s.recordHostRefresh(body, refreshOutcomeHostRefused, herr.Status, hostReason)
		s.writeRefreshReply(w, locale, http.StatusBadGateway, "pool.host_refresh_host_refused",
			map[string]any{"hostId": body.HostID, "status": herr.Status, "hostReason": hostReason},
			mergeFields(ids, map[string]any{"hostStatus": herr.Status, "hostReason": hostReason}))
	}
}

// capabilityRefusalReason names why a host's capability is not remotely
// usable, as a bounded code: the capability's own reason when it is
// unavailable, otherwise the state of the host's verifier key.
func capabilityRefusalReason(r pool.HostRefresh) string {
	switch {
	case r.Protocol != pool.RefreshProtocolVersion && r.Availability == pool.RefreshAvailable:
		return pool.RefreshReasonProtocolUnsupported
	case r.Availability != pool.RefreshAvailable:
		if r.Reason != "" {
			return r.Reason
		}
		return pool.RefreshUnavailable
	}
	switch r.Remote {
	case pool.RefreshRemoteInvalid:
		return hostrefresh.ReasonRemoteKeyInvalid
	case pool.RefreshRemoteUnqualified:
		return hostrefresh.ReasonRemoteUnqualified
	}
	return hostrefresh.ReasonRemoteUnprovisioned
}

// Why hostctl.Refresh sent nothing, as bounded tokens.
const (
	refreshNotSentInvalidClaim   = "invalid_claim"
	refreshNotSentProofMissing   = "proof_missing"
	refreshNotSentAddressInvalid = "host_address_unusable"
	refreshNotSentOther          = "request_not_sent"
)

// refreshNotSentReason names why hostctl.Refresh refused before sending. Its
// error text can quote the host address the aggregator reported, which this
// service reads without authentication, so only this token reaches a reply;
// the text goes to the log.
func refreshNotSentReason(err error) string {
	switch {
	case errors.Is(err, hostrefresh.ErrInvalidClaim):
		return refreshNotSentInvalidClaim
	case errors.Is(err, hostctl.ErrNoProof), errors.Is(err, hostctl.ErrNoRefreshProof):
		return refreshNotSentProofMissing
	case errors.Is(err, hostctl.ErrHostAddress):
		return refreshNotSentAddressInvalid
	}
	return refreshNotSentOther
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
	return refreshReasonUnrecognized
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

// writeRefreshReply writes a refusal: the catalog key as code, its localized
// text as error, and the structured fields a caller branches on.
func (s *Server) writeRefreshReply(w http.ResponseWriter, locale i18n.Context, status int, key string, args, extra map[string]any) {
	out := map[string]any{"ok": false, "code": key, "error": Translate(locale, key, args), "retryable": false}
	for k, v := range extra {
		out[k] = v
	}
	i18n.Apply(w.Header(), locale)
	writeJSON(w, status, out)
}

// refreshAuthorityFile names the authority file for an operator: the one this
// daemon was launched with, else the default.
func (s *Server) refreshAuthorityFile() string {
	if f := strings.TrimSpace(s.opts.RefreshAuthorityFile); f != "" {
		return f
	}
	return config.DefaultRefreshAuthorityFile
}

// recordHostRefresh audits one per-host refresh. Only validated tokens reach
// the entry -- never a credential, a proof, a key or caller-supplied text --
// so the audit log is safe to read from the shared state directory.
func (s *Server) recordHostRefresh(b refreshBody, outcome string, hostStatus int, hostReason string) {
	field := func(v string) string {
		if v == "" {
			return refreshFieldInvalidPlaceholder
		}
		return v
	}
	detail := fmt.Sprintf("request=%s tier=%s maxRung=%s outcome=%s hostStatus=%d hostReason=%s",
		field(b.RequestID), field(b.Tier), field(b.MaxRung), outcome, hostStatus, field(boundedHostReason(hostReason)))
	target := field(b.HostID)
	ok := outcome == hostctl.RefreshActionSpawned || outcome == hostctl.RefreshActionAlreadyClaimed || outcome == hostctl.RefreshActionCompleted
	log.Printf("pool-control-service: host-refresh %s: %s", target, detail)
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		TimeUTC: now.UTC().Format(time.RFC3339),
		Action:  "host-refresh", Target: target, OK: ok, Detail: detail,
	})
}

// auditRefreshGate records one refresh credential check with the address that
// made it. Refusals matter most: a lab-key holder probing the refresh route is
// exactly who an operator wants to see.
func (s *Server) auditRefreshGate(ip, outcome string) {
	if outcome == hostrefresh.AuditOK {
		return
	}
	log.Printf("pool-control-service: refresh credential %s from %s", outcome, ip)
	if s.state == nil {
		return
	}
	now := time.Now()
	s.state.Record(now, state.AuditEntry{
		TimeUTC: now.UTC().Format(time.RFC3339),
		Action:  "refresh-credential", Target: outcome, OK: false, Detail: "from " + ip,
	})
}
