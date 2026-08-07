// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"pool-control-service/internal/intent"
	"pool-control-service/internal/yex/labgate"
)

// The board's server side. The properties worth defending are the ones a wrong
// implementation would get subtly wrong: the join is on members[] (not the Loki
// pool label), a silent pool still renders, an empty window is n/a and not 100%,
// the target pool cannot be assigned, and a dead aggregator does not block
// assignment.

// boardIntent serves a canned Get-PoolIntent document and records EVERY write.
// Distinct from handlers_test.go's fakeIntent, which keeps only the last call --
// the sweep tests need the full sequence to prove what was and was not written.
type boardIntent struct {
	doc    string
	calls  []string
	failOn string
}

func (f *boardIntent) res(ok bool, name string) intent.Result {
	f.calls = append(f.calls, name)
	if f.failOn == name {
		return intent.Result{OK: false, Error: "boom"}
	}
	return intent.Result{OK: ok}
}
func (f *boardIntent) State(context.Context) intent.Result {
	return intent.Result{OK: true, Stdout: f.doc}
}
func (f *boardIntent) NewPool(_ context.Context, id, _, _ string) intent.Result {
	return f.res(true, "NewPool:"+id)
}
func (f *boardIntent) RemovePool(context.Context, string, bool) intent.Result {
	return f.res(true, "RemovePool")
}
func (f *boardIntent) SetDesiredState(context.Context, string, string) intent.Result {
	return f.res(true, "SetDesiredState")
}
func (f *boardIntent) AddHost(_ context.Context, pool, host string) intent.Result {
	return f.res(true, "AddHost:"+pool+":"+host)
}
func (f *boardIntent) RemoveHost(_ context.Context, pool, host string) intent.Result {
	return f.res(true, "RemoveHost:"+pool+":"+host)
}
func (f *boardIntent) AssignTestSet(_ context.Context, pool, name, _, _ string) intent.Result {
	return f.res(true, "AssignTestSet:"+pool+":"+name)
}
func (f *boardIntent) SetTestSetDef(context.Context, string, string, string) intent.Result {
	return f.res(true, "SetTestSetDef")
}
func (f *boardIntent) DeleteTestSetDef(context.Context, string) intent.Result {
	return f.res(true, "DeleteTestSetDef")
}

const intentTwoPools = `{"ok":true,
 "autoEnrollment":{"enabled":true,"targetPoolId":"default","excluded":["42ex"]},
 "pools":[
  {"poolId":"default","poolGuid":"42d","members":["42aa","42bb"]},
  {"poolId":"lab","poolGuid":"42l","displayName":"Lab pool","members":["42cc"],
   "testSet":{"name":"proj.smoke","frameworkUrl":"https://f","projectUrl":"https://p"}},
  {"poolId":"silent","poolGuid":"42s","members":["42zz"]}
 ],
 "testSets":[{"name":"proj.smoke","displayName":"Quick smoke","frameworkUrl":"https://f","projectUrl":"https://p"}]}`

// aggStub serves pool-status and pool-stats.
func aggStub(t *testing.T, statusJSON, statsJSON string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pool-status"):
			_, _ = w.Write([]byte(statusJSON))
		case strings.HasSuffix(r.URL.Path, "/pool-stats"):
			_, _ = w.Write([]byte(statsJSON))
		default:
			http.NotFound(w, r)
		}
	}))
}

func boardPayload(t *testing.T, s *Server, query string) map[string]any {
	t.Helper()
	rec := httptest.NewRecorder()
	s.handleBoard(rec, httptest.NewRequest(http.MethodGet, "/api/board"+query, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return out
}

func cardsByID(t *testing.T, payload map[string]any) map[string]map[string]any {
	t.Helper()
	out := map[string]map[string]any{}
	for _, c := range payload["cards"].([]any) {
		m := c.(map[string]any)
		out[m["poolId"].(string)] = m
	}
	return out
}

func TestBoardJoinsStatsOntoMembers(t *testing.T) {
	// 42aa/42bb are in default, 42cc in lab. 42no belongs to NO pool: its cycles
	// must land in no card at all -- attributing by the Loki `pool` label would
	// have folded it into "default", which is exactly the bug this avoids.
	agg := aggStub(t,
		`{"hosts":[{"hostId":"42aa","control":"ready"},{"hostId":"42bb","control":"ready"},
                    {"hostId":"42cc","control":"ready"},{"hostId":"42no","control":"ready"}]}`,
		`{"range":"24h","hosts":[
            {"hostId":"42aa","passed":10,"failed":0},
            {"hostId":"42bb","passed":5,"failed":5},
            {"hostId":"42cc","passed":99,"failed":1},
            {"hostId":"42no","passed":1000,"failed":1000}]}`)
	defer agg.Close()
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	cards := cardsByID(t, boardPayload(t, s, "?range=24h"))

	def := cards["default"]
	if def["total"].(float64) != 20 || def["failed"].(float64) != 5 {
		t.Errorf("default totals = %v/%v, want 20/5 (members only)", def["total"], def["failed"])
	}
	if pct := def["successPct"].(float64); pct < 74.9 || pct > 75.1 {
		t.Errorf("default successPct = %v, want 75", pct)
	}
	lab := cards["lab"]
	if lab["total"].(float64) != 100 {
		t.Errorf("lab total = %v, want 100", lab["total"])
	}
	// The unpooled host's 2000 cycles must appear nowhere.
	for id, c := range cards {
		if c["total"].(float64) >= 2000 {
			t.Errorf("pool %s absorbed the unpooled host's cycles: %v", id, c["total"])
		}
	}
}

func TestBoardSilentPoolStillRenders(t *testing.T) {
	// "silent" has a member the aggregator has never heard from and no Loki
	// rows. It must still render -- that is the pool most worth looking at.
	agg := aggStub(t, `{"hosts":[]}`, `{"range":"24h","hosts":[]}`)
	defer agg.Close()
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	cards := cardsByID(t, boardPayload(t, s, ""))
	sil, ok := cards["silent"]
	if !ok {
		t.Fatal("the silent pool vanished from the board")
	}
	if sil["hostsTotal"].(float64) != 1 || sil["hostsReporting"].(float64) != 0 {
		t.Errorf("silent hosts = %v total / %v reporting, want 1/0", sil["hostsTotal"], sil["hostsReporting"])
	}
	// No terminal cycle in range -> null, which the UI renders n/a. NOT 100.
	if sil["successPct"] != nil {
		t.Errorf("successPct = %v, want null (n/a) for a pool with no cycles", sil["successPct"])
	}
}

func TestBoardTargetPoolCannotBeAssigned(t *testing.T) {
	agg := aggStub(t, `{"hosts":[]}`, `{"range":"24h","hosts":[]}`)
	defer agg.Close()
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	cards := cardsByID(t, boardPayload(t, s, ""))
	if cards["default"]["assignAllowed"].(bool) {
		t.Error("the auto-enrolment target pool must not be assignable")
	}
	if cards["default"]["reason"].(string) == "" {
		t.Error("a disabled control must carry a reason, not be silently omitted")
	}
	if !cards["lab"]["assignAllowed"].(bool) {
		t.Error("an ordinary pool must remain assignable")
	}
}

func TestBoardSurvivesDeadAggregator(t *testing.T) {
	// Numbers grey out; the cards -- and therefore assignment -- keep working,
	// because assignment goes through the intent CLIs, not the aggregator.
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: "http://127.0.0.1:1"})
	p := boardPayload(t, s, "")
	if p["statsError"].(string) == "" {
		t.Error("a dead aggregator should be reported in statsError")
	}
	if len(p["cards"].([]any)) != 3 {
		t.Errorf("cards = %d, want 3 even with no stats", len(p["cards"].([]any)))
	}
}

func TestBoardRejectsUnknownRange(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{})
	rec := httptest.NewRecorder()
	s.handleBoard(rec, httptest.NewRequest(http.MethodGet, "/api/board?range=99d", nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}

func TestProjectSlugIsProjectScoped(t *testing.T) {
	// Every project reports an implicit set called "all", and the library key is
	// the NAME alone -- so the slug is what stops one project's "all"
	// overwriting another's.
	cases := map[string]string{
		"https://github.com/alius-git/amisad.dev":     "alius-git-amisad-dev",
		"https://github.com/alissonsol/yurunadev.git": "alissonsol-yurunadev",
	}
	seen := map[string]bool{}
	for in, want := range cases {
		got := projectSlug(in)
		if got != want {
			t.Errorf("projectSlug(%q) = %q, want %q", in, got, want)
		}
		if seen[got] {
			t.Errorf("two projects collided on slug %q", got)
		}
		seen[got] = true
	}
}

// --- the Hosts page --------------------------------------------------------

// hostsAggStub answers BOTH hops handleHosts makes: the aggregator's pool-status
// and the registration record each host serves for itself. 42aa's status was
// readable at poll time and 42bb's was not, which is the case that decides where
// a type may come from.
func hostsAggStub(t *testing.T) *httptest.Server {
	t.Helper()
	// Unstarted, because pool-status has to quote this stub's OWN address as each
	// host's baseUrl: the listener exists before Start, so the address is known
	// before the first request can read it.
	base := ""
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/pool-status"):
			_, _ = w.Write([]byte(`{"hosts":[
                {"hostId":"42aa","control":"ready","baseUrl":"` + base + `/42aa","status":{"host":"host.ubuntu.kvm"}},
                {"hostId":"42bb","control":"none","baseUrl":"` + base + `/42bb"}]}`))
		case r.URL.Path == "/42aa/runtime/host.registration.json":
			_, _ = w.Write([]byte(`{"hostname":"syzor202607a","hostType":"host.ubuntu.kvm","projectAccess":{"status":"granted"}}`))
		case r.URL.Path == "/42bb/runtime/host.registration.json":
			_, _ = w.Write([]byte(`{"hostname":"syzor202607b","hostType":"host.windows.hyper-v"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	base = "http://" + srv.Listener.Addr().String()
	srv.Start()
	t.Cleanup(srv.Close)
	return srv
}

// hostsPayload reads /api/hosts through the mux, with or without the bearer, and
// returns the whole answer plus its rows keyed by host id.
func hostsPayload(t *testing.T, s *Server, bearer string) (map[string]any, map[string]map[string]any) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/hosts", nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/hosts = %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	rows := map[string]map[string]any{}
	for _, h := range out["hosts"].([]any) {
		m := h.(map[string]any)
		rows[m["hostId"].(string)] = m
	}
	return out, rows
}

// The hostname is the one field on this open read that the pool itself refuses
// to publish, so it travels only to a request that is through the write gate --
// and the answer says which kind of read it was, or the page could not tell a
// withheld name from a host that has never reported one.
func TestHostsCarryTheHostnameOnlyToAnUnlockedRead(t *testing.T) {
	const labAuthToken = "shared-lab-auth-token"
	agg := hostsAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL, AuthToken: labAuthToken})

	openRead, openRows := hostsPayload(t, s, "")
	if openRead["hostnamesVisible"] != false {
		t.Errorf("hostnamesVisible = %v on an uncredentialed read, want false", openRead["hostnamesVisible"])
	}
	if got := openRows["42aa"]["hostname"]; got != "" {
		t.Errorf("hostname = %q on an uncredentialed read, want it withheld", got)
	}
	// Withholding the name must not cost the row the rest of that same record.
	if got := openRows["42aa"]["access"]; got != "granted" {
		t.Errorf("access = %v, want granted even while the hostname is withheld", got)
	}

	unlocked, rows := hostsPayload(t, s, labAuthToken)
	if unlocked["hostnamesVisible"] != true {
		t.Errorf("hostnamesVisible = %v for an unlocked read, want true", unlocked["hostnamesVisible"])
	}
	if got := rows["42aa"]["hostname"]; got != "syzor202607a" {
		t.Errorf("hostname = %v, want syzor202607a", got)
	}
}

// Type is public -- it names a platform, not a machine -- and reaches the page
// with the "host." prefix already off, from whichever of the two sources could
// answer for that host.
func TestHostsTypeDropsThePrefixAndFallsBackToTheHostsOwnRecord(t *testing.T) {
	agg := hostsAggStub(t)
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: agg.URL})

	_, rows := hostsPayload(t, s, "")
	if got := rows["42aa"]["type"]; got != "ubuntu.kvm" {
		t.Errorf("type = %v from the aggregator's poll, want ubuntu.kvm", got)
	}
	// The aggregator could not read 42bb's status, so its own record is the only
	// thing that names its type -- and a blank column would read as "unknown"
	// for a host that answered perfectly well.
	if got := rows["42bb"]["type"]; got != "windows.hyper-v" {
		t.Errorf("type = %v from the host's own record, want windows.hyper-v", got)
	}
	// A member the aggregator has never heard from has no source for either, and
	// still has to appear: that is the row worth looking at.
	if _, ok := rows["42zz"]; !ok {
		t.Error("a member the aggregator has not seen must still be listed")
	}
}

// --- the write gate --------------------------------------------------------
//
// The gate's own semantics live in the SDK's labgate suite. What is covered here
// is which of THIS service's routes sit behind it: every route that rewrites pool
// configuration, and nothing else.

func TestReadsAreOpenAndPoolConfigWritesAreNot(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{AuthToken: "shared-lab-auth-token"})

	// Reads render on a wall display with no credential, matching the
	// aggregator's own pool-status posture.
	for _, path := range []string{"/healthz", "/api/session", "/api/board", "/api/hosts", "/api/state", "/api/diagnostics"} {
		rec := httptest.NewRecorder()
		s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code == http.StatusUnauthorized {
			t.Errorf("GET %s = 401; reads are open", path)
		}
	}

	// Every mutation rewrites pool configuration, so every one of them is gated.
	for _, tc := range []struct{ method, path string }{
		{http.MethodPost, "/api/pool"},
		{http.MethodDelete, "/api/pool"},
		{http.MethodPost, "/api/pool/desired-state"},
		{http.MethodPost, "/api/pool/host"},
		{http.MethodDelete, "/api/pool/host"},
		{http.MethodPost, "/api/pool/move-host"},
		{http.MethodPost, "/api/pool/testset"},
		{http.MethodPost, "/api/testset"},
		{http.MethodDelete, "/api/testset"},
	} {
		rec := httptest.NewRecorder()
		s.routes().ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, strings.NewReader("{}")))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s = %d with no credential, want 401", tc.method, tc.path, rec.Code)
		}
	}
}

func TestTheBearerOpensThePoolConfigWrites(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{AuthToken: "shared-lab-auth-token"})

	req := httptest.NewRequest(http.MethodPost, "/api/pool/move-host", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer wrong")
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong bearer = %d, want 401", rec.Code)
	}

	req = httptest.NewRequest(http.MethodPost, "/api/pool/move-host", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer shared-lab-auth-token")
	rec = httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code == http.StatusUnauthorized {
		t.Error("the shared lab auth token must open a pool-config write")
	}
}

// An operator who reached this UI by clicking it out of the Yuruna hosts
// dashboard arrives holding a control proof in the URL fragment instead of a
// code, and the page spends it on /api/unlock-proof. What is covered here is the
// wiring -- that the route is mounted and its session opens the same writes; the
// proof's own rules (window, ceiling, forgery, who verifies it) live in the SDK.
func TestAControlProofFromTheDashboardOpensThePoolConfigWrites(t *testing.T) {
	const labAuthToken = "shared-lab-auth-token"
	s := New(&boardIntent{doc: intentTwoPools}, Options{AuthToken: labAuthToken})

	expiry := strconv.FormatInt(time.Now().Add(15*time.Minute).Unix(), 10)
	mac := hmac.New(sha256.New, []byte(labAuthToken))
	mac.Write([]byte("yuruna-control|proof|" + expiry))
	proof := expiry + "." + base64.StdEncoding.EncodeToString(mac.Sum(nil))

	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/unlock-proof",
		strings.NewReader(`{"proof":`+strconv.Quote(proof)+`}`)))
	if rec.Code != http.StatusOK {
		t.Fatalf("unlock with a fresh proof = %d, want 200", rec.Code)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/pool/move-host", strings.NewReader("{}"))
	for _, c := range rec.Result().Cookies() {
		req.AddCookie(c)
	}
	rec2 := httptest.NewRecorder()
	s.routes().ServeHTTP(rec2, req)
	if rec2.Code == http.StatusUnauthorized {
		t.Error("the proof session must open a pool-config write")
	}
}

// With no aggregator to validate a lab token and no bearer configured, a write
// is refused with a machine-readable reason. It is never allowed through because
// there is no gate to fail: this service rewrites the whole lab's assignment.
func TestAnUnconfiguredGateRefusesPoolConfigWrites(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{})
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/pool/move-host", strings.NewReader("{}")))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("write with nothing configured = %d, want 503", rec.Code)
	}
	var body struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body.Reason != labgate.ReasonUnconfigured {
		t.Fatalf("reason = %q, want %q", body.Reason, labgate.ReasonUnconfigured)
	}
}

// The session route tells the UI which prompt to render; it must answer without
// a credential, or the prompt could never appear.
func TestSessionReportsTheWaysIn(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{AggregatorURL: "http://aggregator.invalid", AuthToken: "t"})
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/session", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/session = %d", rec.Code)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("session body %q: %v", rec.Body.String(), err)
	}
	for _, key := range []string{"labToken", "bearer", "configured"} {
		if body[key] != true {
			t.Errorf("session %s = %v, want true", key, body[key])
		}
	}
	if body["authed"] != false || body["mutationsOpen"] != false {
		t.Errorf("a request with no credential reported authed: %+v", body)
	}
}

// --- auto-enrolment sweep --------------------------------------------------

func TestSweepOnlyEnrolsReadyUnpooledHosts(t *testing.T) {
	agg := aggStub(t, `{"hosts":[
        {"hostId":"42aa","control":"ready"},
        {"hostId":"42new","control":"ready"},
        {"hostId":"42ex","control":"ready"},
        {"hostId":"42skew","control":"skew"},
        {"hostId":"42mis","control":"mismatch"},
        {"hostId":"42none","control":"none"},
        {"hostId":"42blank"}]}`, `{}`)
	defer agg.Close()
	f := &boardIntent{doc: intentTwoPools}
	s := New(f, Options{AggregatorURL: agg.URL})

	s.sweepOnce(context.Background())

	var added []string
	for _, c := range f.calls {
		if strings.HasPrefix(c, "AddHost:") {
			added = append(added, c)
		}
	}
	if len(added) != 1 || added[0] != "AddHost:default:42new" {
		// 42aa is already pooled; 42ex is excluded; skew/mismatch/none/absent
		// are not ready. Only 42new qualifies.
		t.Errorf("added = %v, want exactly [AddHost:default:42new]", added)
	}
}

func TestSweepDoesNothingWhenNoCandidates(t *testing.T) {
	agg := aggStub(t, `{"hosts":[{"hostId":"42aa","control":"ready"}]}`, `{}`)
	defer agg.Close()
	f := &boardIntent{doc: intentTwoPools}
	s := New(f, Options{AggregatorURL: agg.URL})
	s.sweepOnce(context.Background())
	for _, c := range f.calls {
		if strings.HasPrefix(c, "AddHost") || strings.HasPrefix(c, "NewPool") {
			t.Errorf("sweep wrote intent with nothing to do: %v", f.calls)
		}
	}
}

func TestSweepInertWhenNotOptedIn(t *testing.T) {
	// enabled:false must make the sweep a complete no-op even with candidates.
	doc := strings.Replace(intentTwoPools, `"enabled":true`, `"enabled":false`, 1)
	agg := aggStub(t, `{"hosts":[{"hostId":"42new","control":"ready"}]}`, `{}`)
	defer agg.Close()
	f := &boardIntent{doc: doc}
	s := New(f, Options{AggregatorURL: agg.URL})
	s.sweepOnce(context.Background())
	if len(f.calls) != 0 {
		t.Errorf("sweep acted while disabled: %v", f.calls)
	}
}

func TestSweepSkipsTickWhenAggregatorDown(t *testing.T) {
	f := &boardIntent{doc: intentTwoPools}
	s := New(f, Options{AggregatorURL: "http://127.0.0.1:1"})
	s.sweepOnce(context.Background())
	if len(f.calls) != 0 {
		t.Errorf("sweep wrote intent despite an unreachable aggregator: %v", f.calls)
	}
}
