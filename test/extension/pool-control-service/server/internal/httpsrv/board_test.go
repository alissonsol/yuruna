// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"pool-control-service/internal/intent"
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
func (f *boardIntent) RemovePool(context.Context, string, bool) intent.Result { return f.res(true, "RemovePool") }
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

// --- passcode gate ---------------------------------------------------------

func TestGateOpenWhenNoPasscode(t *testing.T) {
	// The existing posture: no passcode configured means nothing changes.
	s := New(&boardIntent{doc: intentTwoPools}, Options{})
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/hosts", nil))
	if rec.Code == http.StatusUnauthorized {
		t.Error("an unconfigured gate must not block anything")
	}
}

func TestGateBlocksReadsAndWrites(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{Passcode: "let-me-in"})
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/api/board"},
		{http.MethodGet, "/api/hosts"},
		{http.MethodPost, "/api/pool/testset"},
		{http.MethodPost, "/api/pool/move-host"},
	} {
		rec := httptest.NewRecorder()
		s.routes().ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, strings.NewReader("{}")))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s = %d, want 401", tc.method, tc.path, rec.Code)
		}
	}
	// /healthz must stay open: the launcher polls it to decide the daemon is up.
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code == http.StatusUnauthorized {
		t.Error("/healthz must not be gated -- bring-up depends on it")
	}
}

func TestPublicReadOpensReadsOnly(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{Passcode: "x", PublicRead: true})
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/hosts", nil))
	if rec.Code == http.StatusUnauthorized {
		t.Error("--public-read should open reads")
	}
	rec = httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/pool/move-host", strings.NewReader("{}")))
	if rec.Code != http.StatusUnauthorized {
		t.Error("--public-read must NEVER open mutations")
	}
}

func TestLoginIssuesUsableSessionAndThrottles(t *testing.T) {
	s := New(&boardIntent{doc: intentTwoPools}, Options{Passcode: "let-me-in"})

	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"passcode":"let-me-in"}`)))
	if rec.Code != http.StatusOK {
		t.Fatalf("login = %d: %s", rec.Code, rec.Body.String())
	}
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("login issued no cookie")
	}
	c := cookies[0]
	if !c.HttpOnly {
		t.Error("session cookie must be HttpOnly")
	}
	if c.SameSite != http.SameSiteLaxMode {
		// Strict would suppress the cookie on the Grafana deep-link, which is
		// the primary way an operator arrives, re-prompting every time.
		t.Errorf("SameSite = %v, want Lax", c.SameSite)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/hosts", nil)
	req.AddCookie(c)
	rec = httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code == http.StatusUnauthorized {
		t.Error("a freshly issued session should be accepted")
	}

	// A forged/edited cookie must not pass.
	req = httptest.NewRequest(http.MethodGet, "/api/hosts", nil)
	req.AddCookie(&http.Cookie{Name: passcodeCookie, Value: "9999999999.deadbeef"})
	rec = httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Error("a forged session cookie was accepted")
	}

	for i := 0; i < passcodeMaxFails+2; i++ {
		r := httptest.NewRecorder()
		s.routes().ServeHTTP(r, httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"passcode":"nope"}`)))
		if i >= passcodeMaxFails && r.Code != http.StatusTooManyRequests {
			t.Errorf("attempt %d = %d, want 429 (a short shared code must be throttled)", i, r.Code)
		}
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

	s.sweepOnce(context.Background(), agg.URL)

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
	s.sweepOnce(context.Background(), agg.URL)
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
	s.sweepOnce(context.Background(), agg.URL)
	if len(f.calls) != 0 {
		t.Errorf("sweep acted while disabled: %v", f.calls)
	}
}

func TestSweepSkipsTickWhenAggregatorDown(t *testing.T) {
	f := &boardIntent{doc: intentTwoPools}
	s := New(f, Options{AggregatorURL: "http://127.0.0.1:1"})
	s.sweepOnce(context.Background(), "http://127.0.0.1:1")
	if len(f.calls) != 0 {
		t.Errorf("sweep wrote intent despite an unreachable aggregator: %v", f.calls)
	}
}

