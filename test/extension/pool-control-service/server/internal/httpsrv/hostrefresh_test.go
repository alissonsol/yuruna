// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"pool-control-service/internal/discovery"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/intent"
	"pool-control-service/internal/state"
	"yuruna.com/test/extension/extension-sdk/hostrefresh"
	"yuruna.com/test/extension/extension-sdk/pool"
)

// Per-host remote refresh: the route and its MCP tool, the two gates in front
// of them, the strict body, the capability check, the two proofs sent to the
// host, the reply mapping and the audit. What a wrong implementation gets
// wrong here is authorization: a lab session or the lab key must never reach a
// host, whichever door it comes through.

const (
	rfHost      = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	rfOtherHost = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	rfRequest   = "4242aaaa-0000-4000-8000-000000000001"
)

var (
	rfAuthority     = bytes.Repeat([]byte{0x5a}, hostrefresh.SecretBytes)
	rfCredential    = hostrefresh.FormatSecret(hostrefresh.CredentialPrefix, bytes.Repeat([]byte{0x3c}, hostrefresh.SecretBytes))
	rfAuthorityText = base64.RawURLEncoding.EncodeToString(rfAuthority)
)

// rfTarget is a host status service's refresh route: it records every call and
// answers with what the test supplies.
type rfTarget struct {
	mu      sync.Mutex
	calls   int
	headers []http.Header
	bodies  []string
	status  int
	body    string
	hangup  bool
	srv     *httptest.Server
}

func newRFTarget(t *testing.T) *rfTarget {
	t.Helper()
	h := &rfTarget{status: http.StatusAccepted,
		body: `{"ok":true,"requestId":"` + rfRequest + `","action":"spawned","ceiling":"start-if-stopped","stateUrl":"/runtime/host-refresh.state.json"}`}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.calls++
		h.headers = append(h.headers, r.Header.Clone())
		h.bodies = append(h.bodies, string(b))
		status, body, hangup := h.status, h.body, h.hangup
		h.mu.Unlock()
		if r.URL.Path != "/control/host-refresh" {
			http.NotFound(w, r)
			return
		}
		if hangup {
			if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
				_ = conn.Close()
			}
			return
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *rfTarget) count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.calls
}

// rfAggregator serves pool-status with one entry per host and the given
// refresh object (raw JSON; empty omits the field, as an old aggregator does),
// plus the lab-token check the session tests need.
func rfAggregator(t *testing.T, hosts map[string]string, refresh string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pool-status"):
			var rows []string
			for id, base := range hosts {
				row := `{"hostId":"` + id + `","baseUrl":"` + base + `","control":"ready"`
				if refresh != "" {
					row += `,"refresh":` + refresh
				}
				rows = append(rows, row+"}")
			}
			_, _ = w.Write([]byte(`{"pool":"default","hosts":[` + strings.Join(rows, ",") + `]}`))
		case r.URL.Path == "/api/v1/lab-token":
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

const rfUsable = `{"protocol":1,"availability":"available","ceiling":"start-if-stopped","remote":"provisioned","state":"idle","observedUnixMs":1,"ageSeconds":3}`

type rfOpts struct {
	authority  []byte
	credential string
	refresh    string
	store      *state.Store
	noHost     bool
}

// rfServer builds a pool-control server whose aggregator knows rfHost at the
// target's address. The internal authentication key is set, so the legacy
// transport proof is minted locally.
func rfServer(t *testing.T, target *rfTarget, o rfOpts) (*Server, *httptest.Server) {
	t.Helper()
	hosts := map[string]string{rfHost: target.srv.URL, rfOtherHost: ""}
	if o.noHost {
		hosts = map[string]string{}
	}
	agg := rfAggregator(t, hosts, o.refresh)
	s := New(ctlIntent(rfHost), Options{AggregatorURL: agg.URL, AuthToken: testBearer, Store: o.store,
		RefreshAuthority: o.authority, RefreshCredential: o.credential, RefreshAuthorityFile: "/etc/yuruna/host-refresh/authority.key"})
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	return s, srv
}

func configured(refresh string) rfOpts {
	return rfOpts{authority: rfAuthority, credential: rfCredential, refresh: refresh}
}

func rfPost(t *testing.T, url, body string, headers map[string]string, cookies ...*http.Cookie) (*http.Response, map[string]any, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	for _, c := range cookies {
		req.AddCookie(c)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	return resp, m, string(raw)
}

func bothCredentials() map[string]string {
	return map[string]string{"Authorization": "Bearer " + testBearer, hostrefresh.CredentialHeader: rfCredential}
}

func rfBody(extra string) string {
	return `{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `","tier":"restart","maxRung":"start-if-stopped"` + extra + `}`
}

// Without a signing authority the route answers a named 503 after both gates;
// without a credential the refresh gate itself answers its own 503. Neither
// reaches a host.
func TestRefreshRouteIsDisabledWithoutEitherSecret(t *testing.T) {
	target := newRFTarget(t)
	_, noSigner := rfServer(t, target, rfOpts{credential: rfCredential, refresh: rfUsable})
	resp, m, _ := rfPost(t, noSigner.URL+"/api/host/refresh", rfBody(""), bothCredentials())
	if resp.StatusCode != http.StatusServiceUnavailable || m["code"] != "pool.host_refresh_signing_unconfigured" {
		t.Fatalf("no signer: %d %v", resp.StatusCode, m)
	}
	_, noCredential := rfServer(t, target, rfOpts{authority: rfAuthority, refresh: rfUsable})
	resp, m, _ = rfPost(t, noCredential.URL+"/api/host/refresh", rfBody(""), bothCredentials())
	if resp.StatusCode != http.StatusServiceUnavailable || m["reason"] != hostrefresh.ReasonGateUnconfigured {
		t.Fatalf("no credential: %d %v", resp.StatusCode, m)
	}
	// A 31-byte authority is not an authority.
	_, weak := rfServer(t, target, rfOpts{authority: rfAuthority[:31], credential: rfCredential, refresh: rfUsable})
	if resp, m, _ = rfPost(t, weak.URL+"/api/host/refresh", rfBody(""), bothCredentials()); resp.StatusCode != http.StatusServiceUnavailable || m["code"] != "pool.host_refresh_signing_unconfigured" {
		t.Fatalf("weak authority: %d %v", resp.StatusCode, m)
	}
	if target.count() != 0 {
		t.Fatalf("a disabled route reached the host %d times", target.count())
	}
}

// The chain from anonymous Grafana through the enrollment code to the lab key
// ends at the refresh gate: the lab key as a bearer, or presented as the
// refresh credential, is refused, on HTTP and on MCP.
func TestTheLabKeyCannotRefresh(t *testing.T) {
	target := newRFTarget(t)
	s, srv := rfServer(t, target, configured(rfUsable))
	for name, headers := range map[string]map[string]string{
		"bearer only":             {"Authorization": "Bearer " + testBearer},
		"lab key as credential":   {"Authorization": "Bearer " + testBearer, hostrefresh.CredentialHeader: testBearer},
		"credential as bearer":    {"Authorization": "Bearer " + rfCredential},
		"authority as credential": {"Authorization": "Bearer " + testBearer, hostrefresh.CredentialHeader: hostrefresh.FormatSecret(hostrefresh.AuthorityPrefix, rfAuthority)},
	} {
		resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), headers)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
	}
	res := mcpCall(t, srv.URL, s, `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"restart"}`, map[string]string{"Authorization": "Bearer " + testBearer})
	if reason := refusalReason(res); reason != hostrefresh.ReasonCredentialRequired {
		t.Errorf("MCP with the lab key only: %v", res)
	}
	if target.count() != 0 {
		t.Fatalf("the lab key reached the host %d times", target.count())
	}
}

// The chain from a public legacy proof through /api/unlock-proof to a lab
// session also ends at the refresh gate: the session opens ordinary writes
// but never a refresh, on HTTP or MCP.
func TestALegacyProofSessionCannotRefresh(t *testing.T) {
	target := newRFTarget(t)
	s, srv := rfServer(t, target, configured(rfUsable))
	expiry := strconv.FormatInt(time.Now().Add(15*time.Minute).Unix(), 10)
	mac := hmac.New(sha256.New, []byte(testBearer))
	mac.Write([]byte("yuruna-control|proof|" + expiry))
	proof := expiry + "." + base64.StdEncoding.EncodeToString(mac.Sum(nil))
	resp, _, _ := rfPost(t, srv.URL+"/api/unlock-proof", `{"proof":"`+proof+`"}`, nil)
	var cookie *http.Cookie
	for _, c := range resp.Cookies() {
		if c.Name == sessionCookie {
			cookie = c
		}
	}
	if resp.StatusCode != http.StatusOK || cookie == nil {
		t.Fatalf("the legacy proof did not unlock a session: %d", resp.StatusCode)
	}
	resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), nil, cookie)
	if resp.StatusCode != http.StatusUnauthorized || m["reason"] != hostrefresh.ReasonCredentialRequired {
		t.Fatalf("session on the route: %d %v", resp.StatusCode, m)
	}
	res := mcpCall(t, srv.URL, s, `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"restart"}`, nil, cookie)
	if refusalReason(res) != hostrefresh.ReasonCredentialRequired {
		t.Fatalf("session on MCP: %v", res)
	}
	if target.count() != 0 {
		t.Fatalf("a legacy session reached the host %d times", target.count())
	}
}

// The body is strict: only the four string keys, each once, nothing after the
// object, and no spelling of force or hard-stop.
func TestRefreshBodyIsStrict(t *testing.T) {
	target := newRFTarget(t)
	_, srv := rfServer(t, target, configured(rfUsable))
	cases := map[string]struct {
		body   string
		status int
		code   string
	}{
		"force":            {rfBody(`,"force":"true"`), 400, "pool.host_refresh_field_unsupported"},
		"Force":            {rfBody(`,"Force":"true"`), 400, "pool.host_refresh_field_unsupported"},
		"allowHardStop":    {rfBody(`,"allowHardStop":"true"`), 400, "pool.host_refresh_field_unsupported"},
		"hardStop":         {rfBody(`,"hardStop":"yes"`), 400, "pool.host_refresh_field_unsupported"},
		"hard_stop":        {rfBody(`,"hard_stop":"yes"`), 400, "pool.host_refresh_field_unsupported"},
		"configPath":       {rfBody(`,"configPath":"/tmp/x"`), 400, "pool.host_refresh_field_unsupported"},
		"HOSTID duplicate": {rfBody(`,"HOSTID":"` + rfOtherHost + `"`), 400, "pool.host_refresh_body_invalid"},
		"duplicate key":    {rfBody(`,"tier":"restart"`), 400, "pool.host_refresh_body_invalid"},
		"non-string value": {`{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `","tier":"restart","maxRung":4}`, 400, "pool.host_refresh_body_invalid"},
		"boolean value":    {`{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `","tier":true}`, 400, "pool.host_refresh_body_invalid"},
		"trailing garbage": {rfBody("") + `x`, 400, "pool.host_refresh_body_invalid"},
		"second object":    {rfBody("") + `{}`, 400, "pool.host_refresh_body_invalid"},
		"array":            {`[` + rfBody("") + `]`, 400, "pool.host_refresh_body_invalid"},
		"too large":        {`{"hostId":"` + rfHost + `","pad":"` + strings.Repeat("x", 4097) + `"}`, 413, "pool.host_refresh_body_invalid"},
		"tier full":        {`{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `","tier":"full"}`, 400, "pool.host_refresh_tier_unsupported"},
		"no tier":          {`{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `"}`, 400, "pool.host_refresh_tier_unsupported"},
		"bad uuid":         {`{"hostId":"` + rfHost + `","requestId":"` + strings.ToUpper(rfRequest) + `","tier":"restart"}`, 400, "pool.host_refresh_request_id_invalid"},
		"no request id":    {`{"hostId":"` + rfHost + `","tier":"restart"}`, 400, "pool.host_refresh_request_id_invalid"},
		"bad host id":      {`{"hostId":"42","requestId":"` + rfRequest + `","tier":"restart"}`, 400, "pool.host_refresh_host_id_invalid"},
		"rung reboot":      {`{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `","tier":"restart","maxRung":"reboot"}`, 400, "pool.host_refresh_rung_unsupported"},
		"rung reinstall":   {`{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `","tier":"restart","maxRung":"reinstall"}`, 400, "pool.host_refresh_rung_unsupported"},
	}
	for name, c := range cases {
		resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", c.body, bothCredentials())
		if resp.StatusCode != c.status || m["code"] != c.code || m["ok"] != false {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
	}
	// A body of exactly the cap is read, then judged on its content.
	exact := `{"hostId":"` + rfHost + `","requestId":"` + rfRequest + `","tier":"restart","maxRung":"probe"}`
	exact += strings.Repeat(" ", 4096-len(exact))
	if resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", exact, bothCredentials()); resp.StatusCode != http.StatusAccepted {
		t.Errorf("a 4096-byte body: %d %v", resp.StatusCode, m)
	}
	if target.count() != 1 {
		t.Fatalf("refused bodies reached the host: %d calls", target.count())
	}
	// A dashed or uppercase host id names the same host.
	if resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", `{"hostId":"42AAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","requestId":"`+rfRequest+`","tier":"restart"}`, bothCredentials()); resp.StatusCode != http.StatusAccepted || m["hostId"] != rfHost {
		t.Errorf("dashed host id: %d %v", resp.StatusCode, m)
	}
}

// A host the aggregator does not know, has no address for, or does not
// advertise as remotely usable is refused with zero outbound calls -- whatever
// the reason, including an aggregator that predates the capability.
func TestRefreshNeedsAnAdvertisedCapability(t *testing.T) {
	cases := map[string]struct {
		opts   rfOpts
		host   string
		status int
		code   string
		reason string
	}{
		"unknown host":        {configured(rfUsable), "42cccccccccccccccccccccccccccccc", 404, "pool.host_refresh_host_unknown", ""},
		"no address":          {configured(rfUsable), rfOtherHost, 409, "pool.host_refresh_host_address_unknown", ""},
		"old aggregator":      {configured(""), rfHost, 409, "pool.host_refresh_unavailable", pool.RefreshReasonNeverObserved},
		"expired observation": {configured(`{"protocol":1,"availability":"unavailable","reason":"observation_expired","ceiling":"reclaim","remote":"provisioned","state":"idle"}`), rfHost, 409, "pool.host_refresh_unavailable", pool.RefreshReasonObservationExpired},
		"no qualified rung":   {configured(`{"protocol":1,"availability":"unavailable","reason":"no_qualified_rung","remote":"provisioned","state":"idle"}`), rfHost, 409, "pool.host_refresh_unavailable", "no_qualified_rung"},
		"no verifier key":     {configured(`{"protocol":1,"availability":"available","ceiling":"reclaim","remote":"missing","state":"idle"}`), rfHost, 409, "pool.host_refresh_unavailable", "refresh_remote_unprovisioned"},
		"unqualified host":    {configured(`{"protocol":1,"availability":"available","ceiling":"reclaim","remote":"unqualified","state":"idle"}`), rfHost, 409, "pool.host_refresh_unavailable", "refresh_remote_unqualified"},
		"other protocol":      {configured(`{"protocol":2,"availability":"available","ceiling":"reclaim","remote":"provisioned","state":"idle"}`), rfHost, 409, "pool.host_refresh_unavailable", pool.RefreshReasonProtocolUnsupported},
	}
	for name, c := range cases {
		target := newRFTarget(t)
		_, srv := rfServer(t, target, c.opts)
		body := `{"hostId":"` + c.host + `","requestId":"` + rfRequest + `","tier":"restart"}`
		resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", body, bothCredentials())
		if resp.StatusCode != c.status || m["code"] != c.code {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
		if c.reason != "" && m["hostReason"] != c.reason {
			t.Errorf("%s: hostReason = %v, want %s", name, m["hostReason"], c.reason)
		}
		if target.count() != 0 {
			t.Errorf("%s: %d outbound calls", name, target.count())
		}
	}
	// An aggregator that cannot be read refuses the same way.
	dead := New(ctlIntent(rfHost), Options{AggregatorURL: "http://127.0.0.1:1", AuthToken: testBearer,
		RefreshAuthority: rfAuthority, RefreshCredential: rfCredential})
	srv := httptest.NewServer(dead.Handler())
	defer srv.Close()
	if resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), bothCredentials()); resp.StatusCode != http.StatusConflict || m["hostReason"] != "aggregator_unreadable" {
		t.Errorf("dead aggregator: %d %v", resp.StatusCode, m)
	}
}

// The success path: one POST to the host, carrying a refresh proof the host's
// derived key verifies for exactly this request and a legacy proof for its
// transport gate, relayed back as 202 with an absolute state URL.
func TestRefreshCarriesBothProofsToTheHost(t *testing.T) {
	target := newRFTarget(t)
	_, srv := rfServer(t, target, configured(rfUsable))
	resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), bothCredentials())
	if resp.StatusCode != http.StatusAccepted || m["ok"] != true || m["action"] != hostctl.RefreshActionSpawned ||
		m["requestId"] != rfRequest || m["hostId"] != rfHost || m["stateUrl"] != target.srv.URL+"/runtime/host-refresh.state.json" {
		t.Fatalf("reply: %d %v", resp.StatusCode, m)
	}
	if target.count() != 1 {
		t.Fatalf("host calls = %d", target.count())
	}
	hdr := target.headers[0]
	key, _ := hostrefresh.DeriveHostKey(rfAuthority, rfHost)
	claims, reason := hostrefresh.Verify(key, hdr.Get(hostrefresh.ProofHeader),
		hostrefresh.Claims{HostID: rfHost, RequestID: rfRequest, Tier: "restart", MaxRung: "start-if-stopped"}, time.Now(), hostrefresh.MaxLifetime, hostrefresh.Skew)
	if reason != hostrefresh.ReasonOK || claims.ExpiryUnix-claims.IssuedUnix != int64(hostrefresh.ProofTTL/time.Second) {
		t.Fatalf("the host could not verify the refresh proof: %s %+v", reason, claims)
	}
	other, _ := hostrefresh.DeriveHostKey(rfAuthority, rfOtherHost)
	if _, r := hostrefresh.Verify(other, hdr.Get(hostrefresh.ProofHeader), hostrefresh.Claims{HostID: rfHost, RequestID: rfRequest,
		Tier: "restart", MaxRung: "start-if-stopped"}, time.Now(), hostrefresh.MaxLifetime, hostrefresh.Skew); r != hostrefresh.ReasonProofInvalid {
		t.Fatalf("another host's key verified the proof: %s", r)
	}
	legacy := hdr.Get("X-Yuruna-Control")
	dot := strings.IndexByte(legacy, '.')
	if dot <= 0 || hostctl.Proof(testBearer, mustInt(t, legacy[:dot])) != legacy || hdr.Get("X-Yuruna") != "1" {
		t.Fatalf("the legacy transport proof is wrong: %q", legacy)
	}
	if hdr.Get(hostrefresh.CredentialHeader) != "" || hdr.Get("Authorization") != "" {
		t.Fatal("the operator's credentials were forwarded to the host")
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(target.bodies[0]), &body); err != nil || len(body) != 3 || body["maxRung"] != "start-if-stopped" {
		t.Fatalf("host body = %s", target.bodies[0])
	}
	// No ceiling defaults to the highest remote rung, which the proof binds.
	target2 := newRFTarget(t)
	_, srv2 := rfServer(t, target2, configured(rfUsable))
	rfPost(t, srv2.URL+"/api/host/refresh", `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"restart"}`, bothCredentials())
	if target2.count() != 1 || !strings.Contains(target2.headers[0].Get(hostrefresh.ProofHeader), ".restart.restart-broker.") {
		t.Fatalf("default ceiling: %v", target2.headers)
	}
}

func mustInt(t *testing.T, s string) int64 {
	t.Helper()
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// The host's answers map to typed replies that keep the request id, the busy
// request's id and the state URL; a host that never answers is a retryable
// 504 for the same request id.
func TestRefreshMapsTheHostReply(t *testing.T) {
	cases := map[string]struct {
		status   int
		body     string
		hangup   bool
		want     int
		code     string
		retry    bool
		check    string
		expected any
	}{
		"busy":      {409, `{"ok":false,"reason":"busy","activeKind":"host_refresh","activeRequestId":"4242aaaa-0000-4000-8000-000000000009","stateUrl":"/runtime/host-refresh.state.json"}`, false, 409, "pool.host_refresh_busy", false, "activeRequestId", "4242aaaa-0000-4000-8000-000000000009"},
		"conflict":  {409, `{"ok":false,"reason":"request_conflict","requestId":"` + rfRequest + `"}`, false, 409, "pool.host_refresh_request_conflict", false, "requestId", rfRequest},
		"closed":    {409, `{"ok":false,"reason":"request_closed","requestId":"` + rfRequest + `","state":"refused","verdict":"refused"}`, false, 409, "pool.host_refresh_request_closed", false, "state", "refused"},
		"launcher":  {503, `{"ok":false,"reason":"launcher_failed","requestId":"` + rfRequest + `","stateUrl":"/runtime/host-refresh.state.json"}`, false, 503, "pool.host_refresh_host_unavailable", true, "hostReason", "launcher_failed"},
		"408":       {408, `{"ok":false,"reason":"body_timeout"}`, false, 503, "pool.host_refresh_host_unavailable", true, "hostStatus", float64(408)},
		"proof 403": {403, `{"ok":false,"reason":"refresh_proof_expired"}`, false, 502, "pool.host_refresh_host_refused", false, "hostReason", "refresh_proof_expired"},
		"odd 403":   {403, `{"ok":false,"reason":"<b>Nope</b>"}`, false, 502, "pool.host_refresh_host_refused", false, "hostReason", "unrecognized"},
		"204":       {204, ``, false, 502, "pool.host_refresh_reply_invalid", false, "hostStatus", float64(204)},
		"wrong id":  {202, `{"ok":true,"requestId":"4242aaaa-0000-4000-8000-00000000000f","action":"spawned"}`, false, 502, "pool.host_refresh_reply_invalid", false, "requestId", rfRequest},
		"dropped":   {0, ``, true, 504, "pool.host_refresh_host_unreachable", true, "requestId", rfRequest},
	}
	for name, c := range cases {
		target := newRFTarget(t)
		target.status, target.body, target.hangup = c.status, c.body, c.hangup
		_, srv := rfServer(t, target, configured(rfUsable))
		resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), bothCredentials())
		if resp.StatusCode != c.want || m["code"] != c.code || m["retryable"] != c.retry || m[c.check] != c.expected {
			t.Errorf("%s: %d %v", name, resp.StatusCode, m)
		}
	}
	replay := newRFTarget(t)
	replay.status, replay.body = 200, `{"ok":true,"requestId":"`+rfRequest+`","action":"completed","state":"completed","verdict":"repaired","stateUrl":"/runtime/host-refresh.state.json"}`
	_, srv := rfServer(t, replay, configured(rfUsable))
	resp, m, _ := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), bothCredentials())
	if resp.StatusCode != http.StatusOK || m["replay"] != true || m["verdict"] != "repaired" || m["action"] != "completed" {
		t.Fatalf("replay: %d %v", resp.StatusCode, m)
	}
}

// Every outcome is audited with bounded tokens only; no reply, audit entry or
// log line carries the credential, the authority, the legacy proof or the
// refresh proof.
func TestRefreshAuditCarriesNoSecret(t *testing.T) {
	var logBuf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&logBuf)
	defer log.SetOutput(prev)

	dir := filepath.Join(t.TempDir(), "pc")
	store := state.New(dir, time.Now())
	target := newRFTarget(t)
	o := configured(rfUsable)
	o.store = store
	_, srv := rfServer(t, target, o)
	var replies []string
	for _, body := range []string{rfBody(""), rfBody(`,"force":"yes"`), `{"hostId":"42cccccccccccccccccccccccccccccc","requestId":"` + rfRequest + `","tier":"restart"}`} {
		_, _, raw := rfPost(t, srv.URL+"/api/host/refresh", body, bothCredentials())
		replies = append(replies, raw)
	}
	_, _, raw := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), map[string]string{"Authorization": "Bearer " + testBearer, hostrefresh.CredentialHeader: "yhrc1.wrong"})
	replies = append(replies, raw)
	if target.count() != 1 {
		t.Fatalf("host calls = %d", target.count())
	}
	audit, err := os.ReadFile(filepath.Join(dir, "audit.jsonl"))
	if err != nil {
		t.Fatalf("no audit log: %v", err)
	}
	if !strings.Contains(string(audit), `"action":"host-refresh"`) || !strings.Contains(string(audit), "outcome=spawned") ||
		!strings.Contains(string(audit), "request="+rfRequest) || !strings.Contains(string(audit), "outcome=host_unknown") ||
		!strings.Contains(string(audit), "outcome=body_invalid") || !strings.Contains(string(audit), `"action":"refresh-credential"`) {
		t.Fatalf("audit is missing an outcome:\n%s", audit)
	}
	sentRefresh := target.headers[0].Get(hostrefresh.ProofHeader)
	sentLegacy := target.headers[0].Get("X-Yuruna-Control")
	credBody := strings.TrimPrefix(rfCredential, "yhrc1.")
	everything := string(audit) + logBuf.String() + strings.Join(replies, "\n")
	for name, secret := range map[string]string{"credential": credBody, "authority": rfAuthorityText, "refresh proof": sentRefresh,
		"refresh mac": sentRefresh[strings.LastIndexByte(sentRefresh, '.')+1:], "legacy proof": sentLegacy, "lab key": testBearer} {
		if secret != "" && strings.Contains(everything, secret) {
			t.Errorf("the %s leaked into a reply, the audit or the log", name)
		}
	}
}

// The pool-wide fan-out keeps refusing refresh, over HTTP and MCP, with zero
// calls to any member -- on a server that has refresh fully configured.
func TestPoolWideControlStillRefusesRefreshWhenConfigured(t *testing.T) {
	target := newRFTarget(t)
	h := newCtlHost(t, "")
	agg := rfAggregator(t, map[string]string{rfHost: h.srv.URL}, rfUsable)
	s := New(ctlIntent(rfHost), Options{AggregatorURL: agg.URL, AuthToken: testBearer, RefreshAuthority: rfAuthority, RefreshCredential: rfCredential})
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()
	resp, m, _ := rfPost(t, srv.URL+"/api/pool/host-control", `{"poolId":"lab","action":"refresh"}`, bothCredentials())
	if resp.StatusCode != http.StatusBadRequest || !strings.Contains(m["error"].(string), "not available through pool-wide control") {
		t.Fatalf("HTTP: %d %v", resp.StatusCode, m)
	}
	tool, _ := s.mcpRegistry().Get("pool_control_set_host_control")
	if _, err := tool.Handler(context.Background(), json.RawMessage(`{"poolId":"lab","action":"refresh"}`)); err == nil ||
		!strings.Contains(err.Error(), "not available through pool-wide control") {
		t.Fatalf("MCP: %v", err)
	}
	if len(h.recorded()) != 0 || target.count() != 0 {
		t.Fatalf("the fan-out reached a host: %v %d", h.recorded(), target.count())
	}
}

// mcpCall invokes the refresh tool over the MCP endpoint with the given
// credentials.
func mcpCall(t *testing.T, base string, _ *Server, args string, headers map[string]string, cookies ...*http.Cookie) map[string]any {
	t.Helper()
	body := `{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"pool_control_refresh_host","arguments":` + args + `}}`
	_, m, _ := rfPost(t, base+"/mcp", body, headers, cookies...)
	return m
}

func refusalReason(res map[string]any) string {
	e, _ := res["error"].(map[string]any)
	d, _ := e["data"].(map[string]any)
	r, _ := d["reason"].(string)
	return r
}

// The tool is listed only when both secrets are provisioned; it is mutating,
// destructive and idempotent; it refuses unknown arguments by name; and with
// both credentials it answers what the route answers.
func TestRefreshToolIsGatedLikeTheRoute(t *testing.T) {
	target := newRFTarget(t)
	s, srv := rfServer(t, target, configured(rfUsable))
	got := mcpPost(t, srv.URL, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	var found map[string]any
	for _, raw := range got["result"].(map[string]any)["tools"].([]any) {
		if m := raw.(map[string]any); m["name"] == "pool_control_refresh_host" {
			found = m
		}
	}
	if found == nil {
		t.Fatal("a configured server does not list the refresh tool")
	}
	ann := found["annotations"].(map[string]any)
	if ann["readOnlyHint"] != false || ann["destructiveHint"] != true || ann["idempotentHint"] != true {
		t.Fatalf("annotations = %v", ann)
	}
	for _, unconfigured := range []rfOpts{{refresh: rfUsable}, {authority: rfAuthority, refresh: rfUsable}, {credential: rfCredential, refresh: rfUsable}} {
		plain, _ := rfServer(t, target, unconfigured)
		if _, ok := plain.mcpRegistry().Get("pool_control_refresh_host"); ok {
			t.Fatalf("the refresh tool is listed without both secrets: %+v", unconfigured)
		}
	}

	res := mcpCall(t, srv.URL, s, `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"restart","force":"true"}`, bothCredentials())
	if refusalReason(res) != "invalid-arguments" {
		t.Fatalf("force argument: %v", res)
	}
	res = mcpCall(t, srv.URL, s, `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"restart","maxRung":2}`, bothCredentials())
	if refusalReason(res) != "invalid-arguments" {
		t.Fatalf("non-string argument: %v", res)
	}
	res = mcpCall(t, srv.URL, s, `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"full","tier":"restart"}`, bothCredentials())
	if refusalReason(res) != "invalid-arguments" {
		t.Fatalf("repeated argument: %v", res)
	}
	res = mcpCall(t, srv.URL, s, `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"restart","maxRung":"start-if-stopped"}`,
		map[string]string{hostrefresh.CredentialHeader: rfCredential})
	if refusalReason(res) != "unauthorized" {
		t.Fatalf("refresh credential without the write credential: %v", res)
	}
	if target.count() != 0 {
		t.Fatalf("a refused tool call reached the host %d times", target.count())
	}
	res = mcpCall(t, srv.URL, s, `{"hostId":"`+rfHost+`","requestId":"`+rfRequest+`","tier":"restart","maxRung":"start-if-stopped"}`, bothCredentials())
	result, ok := res["result"].(map[string]any)
	if !ok || result["isError"] != false {
		t.Fatalf("both credentials: %v", res)
	}
	var viaTool map[string]any
	if err := json.Unmarshal([]byte(result["content"].([]any)[0].(map[string]any)["text"].(string)), &viaTool); err != nil {
		t.Fatal(err)
	}
	_, viaRoute, _ := rfPost(t, srv.URL+"/api/host/refresh", rfBody(""), bothCredentials())
	for _, k := range []string{"ok", "action", "hostId", "requestId", "stateUrl", "retryable"} {
		if viaTool[k] != viaRoute[k] {
			t.Errorf("%s: tool %v, route %v", k, viaTool[k], viaRoute[k])
		}
	}
	if target.count() != 2 {
		t.Fatalf("host calls = %d, want 2", target.count())
	}
}

// Host rows carry the capability; a silent member and a discovered host carry
// the never-observed value; and no read route reports either secret.
func TestReadRoutesCarryRefreshButNoSecret(t *testing.T) {
	target := newRFTarget(t)
	s, srv := rfServer(t, target, configured(rfUsable))
	s.discovered.Add(discovery.Host{Address: "192.0.2.77", BaseURL: "http://192.0.2.77:8080", HostID: "42dddddddddddddddddddddddddddddd"}, time.Now())
	s.intent = &fakeIntent{stateRes: intent.Result{OK: true, Stdout: `{"ok":true,"pools":[{"poolId":"lab","members":["` + rfHost + `","42eeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]}]}`}}
	resp, err := http.Get(srv.URL + "/api/hosts")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	var doc struct {
		Hosts []struct {
			HostID     string           `json:"hostId"`
			Discovered bool             `json:"discovered"`
			Refresh    pool.HostRefresh `json:"refresh"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("hosts: %v %s", err, raw)
	}
	seen := map[string]pool.HostRefresh{}
	for _, h := range doc.Hosts {
		seen[h.HostID] = h.Refresh
	}
	if !seen[rfHost].RemoteUsable() || seen["42eeeeeeeeeeeeeeeeeeeeeeeeeeeeee"] != pool.UnobservedRefresh() ||
		seen["42dddddddddddddddddddddddddddddd"] != pool.UnobservedRefresh() {
		t.Fatalf("refresh per row: %+v", seen)
	}
	for _, path := range []string{"/api/diagnostics", "/api/state", "/api/hostinfo", "/api/session", "/healthz", "/api/hosts"} {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		for _, secret := range []string{rfAuthorityText, strings.TrimPrefix(rfCredential, "yhrc1."), "yhrc1", "yhra1"} {
			if strings.Contains(string(body), secret) {
				t.Errorf("%s carries refresh secret material", path)
			}
		}
	}
	if s.opts.RefreshAuthority != nil || s.opts.RefreshCredential != "" {
		t.Fatal("the server kept the raw secrets in its options")
	}
}

// The loader enables remote refresh only for two distinct, owner-only secrets
// that are not the legacy key, and its refusal never carries file content.
func TestLoadRefreshSecrets(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string, mode os.FileMode) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}
		return p
	}
	authorityLine := hostrefresh.FormatSecret(hostrefresh.AuthorityPrefix, rfAuthority)
	authority := write("authority.key", authorityLine+"\n", 0o600)
	credential := write("operator.credential", rfCredential+"\n", 0o600)

	a, c, err := LoadRefreshSecrets(authority, credential, testBearer)
	if err != nil || !bytes.Equal(a, rfAuthority) || c != rfCredential {
		t.Fatalf("valid secrets: %v", err)
	}
	sameAsAuthority := write("same.credential", hostrefresh.FormatSecret(hostrefresh.CredentialPrefix, rfAuthority)+"\n", 0o600)
	refusals := map[string][3]string{
		"no files configured":      {"", "", testBearer},
		"missing authority":        {filepath.Join(dir, "absent"), credential, testBearer},
		"missing credential":       {authority, filepath.Join(dir, "absent"), testBearer},
		"swapped files":            {credential, authority, testBearer},
		"legacy key is authority":  {authority, credential, authorityLine},
		"legacy key is credential": {authority, credential, rfCredential},
		"credential is authority":  {authority, sameAsAuthority, testBearer},
	}
	if runtime.GOOS != "windows" {
		refusals["open authority"] = [3]string{write("open.key", authorityLine+"\n", 0o644), credential, testBearer}
	}
	for name, args := range refusals {
		a, c, err := LoadRefreshSecrets(args[0], args[1], args[2])
		if err == nil || a != nil || c != "" {
			t.Errorf("%s: loaded (%v)", name, err)
			continue
		}
		for _, secret := range []string{rfAuthorityText, strings.TrimPrefix(rfCredential, "yhrc1.")} {
			if strings.Contains(err.Error(), secret) {
				t.Errorf("%s: the refusal carries secret material", name)
			}
		}
	}
}

// A failure before anything reaches the host is relayed as a bounded token,
// never as the error's own text: that text names this service's token file
// and quotes the aggregator's failure, which comes from a service read without
// authentication. The text still reaches the log. The same holds for an
// unusable host address, which the pool client already drops, so the token
// mapping for it is pinned in TestRefreshFailureTokens.
func TestRefreshFailureDetailIsABoundedToken(t *testing.T) {
	var logBuf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&logBuf)
	defer log.SetOutput(prev)

	// No internal key here, and an aggregator that mints nothing: the legacy
	// transport proof is unavailable. The handler is called past its gates,
	// which need the key this case withholds.
	target := newRFTarget(t)
	agg := rfAggregator(t, map[string]string{rfHost: target.srv.URL}, rfUsable)
	s := New(ctlIntent(rfHost), Options{AggregatorURL: agg.URL, AuthTokenFile: "/etc/yuruna/token-file-marker",
		RefreshAuthority: rfAuthority, RefreshCredential: rfCredential})
	rec := httptest.NewRecorder()
	s.handleHostRefresh(rec, httptest.NewRequest(http.MethodPost, "/api/host/refresh", strings.NewReader(rfBody(""))))
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	body := rec.Body.String()
	if rec.Code != http.StatusServiceUnavailable || strings.Contains(body, "token-file-marker") || strings.Contains(body, "internal authentication key") {
		t.Fatalf("control proof: %d %s", rec.Code, body)
	}
	// The rendered text is the key until the catalogs are compiled; once they
	// are, it must carry the token.
	const key = "pool.host_refresh_control_proof_unavailable"
	if text, _ := got["error"].(string); got["code"] != key || (text != key && !strings.Contains(text, controlProofAggregatorRefused)) {
		t.Errorf("control proof: code %v, error %q", got["code"], text)
	}
	if target.count() != 0 {
		t.Fatalf("a refresh without a control proof reached the host %d times", target.count())
	}
	if !strings.Contains(logBuf.String(), "token-file-marker") {
		t.Errorf("the log lost the control-proof failure: %s", logBuf.String())
	}
}

// Each failure class maps to its own token, and anything unrecognized to a
// generic one, so no error text can ride through.
func TestRefreshFailureTokens(t *testing.T) {
	c := hostctl.New(hostctl.Options{})
	req := hostctl.RefreshRequest{RequestID: rfRequest, Tier: hostrefresh.TierRestart, MaxRung: pool.RungStartIfStopped}
	for name, want := range map[string]string{
		"gopher://evil.example/<b>": refreshNotSentAddressInvalid,
		"":                          refreshNotSentAddressInvalid,
	} {
		_, err := c.Refresh(context.Background(), name, req, "p", "r")
		if got := refreshNotSentReason(err); got != want {
			t.Errorf("address %q: %s, want %s (%v)", name, got, want, err)
		}
	}
	_, err := c.Refresh(context.Background(), "http://127.0.0.1:1", hostctl.RefreshRequest{RequestID: "NOT-A-UUID", Tier: "restart", MaxRung: "probe"}, "p", "r")
	if got := refreshNotSentReason(err); got != refreshNotSentInvalidClaim {
		t.Errorf("bad claim: %s (%v)", got, err)
	}
	_, err = c.Refresh(context.Background(), "http://127.0.0.1:1", req, "", "r")
	if got := refreshNotSentReason(err); got != refreshNotSentProofMissing {
		t.Errorf("no control proof: %s (%v)", got, err)
	}
	_, err = c.Refresh(context.Background(), "http://127.0.0.1:1", req, "p", "")
	if got := refreshNotSentReason(err); got != refreshNotSentProofMissing {
		t.Errorf("no refresh proof: %s (%v)", got, err)
	}
	if got := refreshNotSentReason(errors.New("<script>anything</script>")); got != refreshNotSentOther {
		t.Errorf("unrecognized: %s", got)
	}

	// Without the internal key and without an aggregator to ask, the error
	// keeps its operator text for the pool-wide route and names its token.
	s := New(ctlIntent(rfHost), Options{AuthTokenFile: "/etc/yuruna/token-file-marker"})
	_, err = s.controlProof(context.Background(), []string{rfHost}, map[string]string{})
	if err == nil || !strings.Contains(err.Error(), "token-file-marker") {
		t.Fatalf("controlProof error text: %v", err)
	}
	if got := controlProofFailureReason(err); got != controlProofNoInternalKey {
		t.Errorf("no aggregator: %s", got)
	}
	if got := controlProofFailureReason(errors.New("other")); got != controlProofUnavailable {
		t.Errorf("foreign error: %s", got)
	}
}
