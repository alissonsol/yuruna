// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"stash-service/internal/config"
	"stash-service/internal/id"
	"stash-service/internal/meta"
	"stash-service/internal/sshsrv"
	"stash-service/internal/store"

	"yuruna.com/test/extension/extension-sdk/labgate"
)

const testHostID = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 32 hex, hostId-shaped

// testVersion stands in for the framework version the guest build stamps in
// through -ldflags. A daemon that loses that wiring reports the zero value and
// the UI footer shows nothing, which no other assertion here would notice.
const testVersion = "2026.09.08"

func newTestUI(t *testing.T) (*httptest.Server, *Server, string) {
	return newTestUIHost(t, testHostID)
}

func newTestUIHost(t *testing.T, hostID string) (*httptest.Server, *Server, string) {
	t.Helper()
	// Every test UI is wired to a fake aggregator that accepts any well-shaped
	// lab token, because that is the only way through the delete gate: this
	// service holds no token of its own, by design.
	return newTestUIWith(t, hostID, fakeAggregator(t))
}

// newTestUIWith builds the UI against a given aggregator URL. Empty is the
// shape of a daemon launched without --aggregator-url, which can check no
// credential at all -- the gate must then refuse rather than open.
func newTestUIWith(t *testing.T, hostID, aggregatorURL string) (*httptest.Server, *Server, string) {
	t.Helper()
	tmp := t.TempDir()
	stashRoot := filepath.Join(tmp, "stash")
	shareFolder := filepath.Join(stashRoot, hostID)
	st, err := store.New(shareFolder)
	if err != nil {
		t.Fatalf("store.New: %v", err)
	}
	buf, err := store.NewFilesOnly(filepath.Join(tmp, "buffer"))
	if err != nil {
		t.Fatalf("buffer: %v", err)
	}
	m, err := meta.Open(filepath.Join(tmp, "meta.sqlite"))
	if err != nil {
		t.Fatalf("meta.Open: %v", err)
	}
	t.Cleanup(func() { _ = m.Close() })
	ids := id.New(m.Exists, st.FilesRoot(), buf.FilesRoot())
	ssh, err := sshsrv.New(st, buf, m, ids)
	if err != nil {
		t.Fatalf("sshsrv.New: %v", err)
	}
	ssh.ShareOnline = func() bool { return true } // force the share path in tests
	ui := New(ssh, Options{Addr: "127.0.0.1:0", Version: testVersion, PoolWindowDays: 30, AggregatorURL: aggregatorURL})
	ts := httptest.NewServer(ui.routes())
	t.Cleanup(ts.Close)
	return ts, ui, stashRoot
}

// fakeAggregator stands in for the pool aggregator's lab-token exchange,
// answering 200 (valid) to any code the gate forwards. It is the credential
// authority, not the gate: what these tests exercise is what the stash daemon
// does with a verdict, not how the aggregator reaches one.
func fakeAggregator(t *testing.T) string {
	t.Helper()
	agg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(agg.Close)
	return agg.URL
}

// unlocked returns a client holding a delete session for ts, obtained the way a
// browser does: POST the lab token, keep the cookie. Tests that delete use it;
// a plain http.DefaultClient is the locked browser.
func unlocked(t *testing.T, ts *httptest.Server) *http.Client {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatalf("cookiejar: %v", err)
	}
	c := &http.Client{Jar: jar}
	resp, err := c.Post(ts.URL+"/api/login", "application/json", strings.NewReader(`{"labToken":"abc123"}`))
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("login = %d, want 200: %s", resp.StatusCode, body)
	}
	return c
}

// deleteStash issues one DELETE through c and returns the response.
func deleteStash(t *testing.T, c *http.Client, url string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodDelete, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func tail(permalink string) string { return strings.TrimPrefix(permalink, "/s/") }

func TestCreateListGetRawDeleteText(t *testing.T) {
	ts, _, _ := newTestUI(t)

	// Create via form text (section 5.1).
	form := "title=notes.txt&author=alice&text=" + "hello+stash+world"
	resp, err := http.Post(ts.URL+"/api/stashes", "application/x-www-form-urlencoded", strings.NewReader(form))
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		OK        bool   `json:"ok"`
		ID        string `json:"id"`
		HostID    string `json:"hostId"`
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)
	if !created.OK || created.ID == "" || created.HostID != testHostID {
		t.Fatalf("create: %+v", created)
	}

	// List (section 4) -- should contain it, marked local.
	var list struct {
		Stashes []StashView `json:"stashes"`
		Total   int         `json:"total"`
	}
	getJSON(t, ts.URL+"/api/stashes?limit=50", &list)
	if list.Total != 1 || len(list.Stashes) != 1 {
		t.Fatalf("list total=%d len=%d", list.Total, len(list.Stashes))
	}
	v := list.Stashes[0]
	if !v.Local || v.ContentClass != config.ClassText || !v.IsText || v.Source != config.SourceUI {
		t.Fatalf("view: %+v", v)
	}
	if v.OriginalFilename != "notes.txt" || v.Username != "alice" {
		t.Fatalf("metadata not captured: %+v", v)
	}

	// Get metadata (section 6).
	var meta1 struct {
		Stash StashView `json:"stash"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+tail(created.Permalink), &meta1)
	if meta1.Stash.ID != created.ID {
		t.Fatalf("meta id mismatch: %+v", meta1.Stash)
	}

	// Raw inline (section 7): bytes + safety headers + text content type.
	rraw, err := http.Get(ts.URL + "/raw/" + tail(created.Permalink))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(rraw.Body)
	rraw.Body.Close()
	if string(body) != "hello stash world" {
		t.Fatalf("raw body = %q", body)
	}
	if got := rraw.Header.Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("missing nosniff: %q", got)
	}
	if csp := rraw.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") {
		t.Fatalf("missing CSP: %q", csp)
	}
	if ct := rraw.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("raw text content-type = %q", ct)
	}

	// Download is an attachment (section 7.5).
	rdl, err := http.Get(ts.URL + "/download/" + tail(created.Permalink))
	if err != nil {
		t.Fatal(err)
	}
	rdl.Body.Close()
	if cd := rdl.Header.Get("Content-Disposition"); !strings.HasPrefix(cd, "attachment") {
		t.Fatalf("download disposition = %q", cd)
	}

	// Delete local (section 8), through an unlocked session -> then 404.
	dresp := deleteStash(t, unlocked(t, ts), ts.URL+"/api/stashes/"+tail(created.Permalink))
	dresp.Body.Close()
	if dresp.StatusCode != http.StatusOK {
		t.Fatalf("delete status = %d", dresp.StatusCode)
	}
	g, _ := http.Get(ts.URL + "/api/stashes/" + tail(created.Permalink))
	g.Body.Close()
	if g.StatusCode != http.StatusNotFound {
		t.Fatalf("post-delete get = %d, want 404", g.StatusCode)
	}
}

// The dev/local-fallback host id ("share-local") is not hostId-shaped; the
// detail/raw/delete routes must still resolve it (regression guard for the
// over-strict hostId shape check).
func TestLocalNonHexHostIDResolves(t *testing.T) {
	ts, _, _ := newTestUIHost(t, "share-local")
	resp, err := http.Post(ts.URL+"/api/stashes", "application/x-www-form-urlencoded",
		strings.NewReader("title=n.txt&text=hi"))
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		OK        bool   `json:"ok"`
		HostID    string `json:"hostId"`
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)
	if !created.OK || created.HostID != "share-local" {
		t.Fatalf("create on non-hex host: %+v", created)
	}
	var got struct {
		Stash StashView `json:"stash"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+tail(created.Permalink), &got)
	if got.Stash.HostID != "share-local" || !got.Stash.Local {
		t.Fatalf("non-hex host detail did not resolve: %+v", got.Stash)
	}
}

// The delete gate. A locked browser is refused (401) and the stash survives;
// the same request through an unlocked session succeeds. Reads and creates are
// never gated, which is the whole point of gating only this one verb.
func TestDeleteRequiresSession(t *testing.T) {
	ts, _, _ := newTestUI(t)
	permalink := postText(t, ts.URL, "keepme")

	locked := deleteStash(t, http.DefaultClient, ts.URL+"/api/stashes/"+tail(permalink))
	locked.Body.Close()
	if locked.StatusCode != http.StatusUnauthorized {
		t.Fatalf("locked delete = %d, want 401", locked.StatusCode)
	}
	g, _ := http.Get(ts.URL + "/api/stashes/" + tail(permalink))
	g.Body.Close()
	if g.StatusCode != http.StatusOK {
		t.Fatalf("stash gone after a refused delete: get = %d, want 200", g.StatusCode)
	}

	// A locked browser can still read and create: gating those would make a
	// credential a prerequisite for a guest pushing a diagnostic.
	if p2 := postText(t, ts.URL, "still open"); p2 == "" {
		t.Fatal("create was refused without a session")
	}

	ok := deleteStash(t, unlocked(t, ts), ts.URL+"/api/stashes/"+tail(permalink))
	ok.Body.Close()
	if ok.StatusCode != http.StatusOK {
		t.Fatalf("unlocked delete = %d, want 200", ok.StatusCode)
	}
	g2, _ := http.Get(ts.URL + "/api/stashes/" + tail(permalink))
	g2.Body.Close()
	if g2.StatusCode != http.StatusNotFound {
		t.Fatalf("post-delete get = %d, want 404", g2.StatusCode)
	}
}

// With no aggregator configured there is no way to check any credential, so the
// daemon refuses rather than running the delete ungated -- and it says WHICH of
// the two refusals this is, because "nothing is configured here" and "your code
// was wrong" call for opposite actions from an operator.
func TestDeleteUnconfiguredGate(t *testing.T) {
	ts, _, _ := newTestUIWith(t, testHostID, "")
	permalink := postText(t, ts.URL, "keepme")

	resp := deleteStash(t, http.DefaultClient, ts.URL+"/api/stashes/"+tail(permalink))
	var body struct {
		OK     bool   `json:"ok"`
		Reason string `json:"reason"`
	}
	decode(t, resp, &body)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("ungated delete = %d, want 503", resp.StatusCode)
	}
	if body.OK || body.Reason != labgate.ReasonUnconfigured {
		t.Fatalf("body = %+v, want ok:false + reason:%s", body, labgate.ReasonUnconfigured)
	}
	g, _ := http.Get(ts.URL + "/api/stashes/" + tail(permalink))
	g.Body.Close()
	if g.StatusCode != http.StatusOK {
		t.Fatalf("stash gone after an unconfigured refusal: get = %d, want 200", g.StatusCode)
	}
}

// /api/session is what the UI reads to decide whether to render a Delete
// control at all, so it has to track the gate: locked before the login, authed
// after it, on the same browser.
func TestSessionReportsTheGate(t *testing.T) {
	ts, _, _ := newTestUI(t)
	type session struct {
		OK         bool `json:"ok"`
		LabToken   bool `json:"labToken"`
		Authed     bool `json:"authed"`
		Configured bool `json:"configured"`
	}
	var before session
	getJSON(t, ts.URL+"/api/session", &before)
	if !before.OK || !before.LabToken || !before.Configured || before.Authed {
		t.Fatalf("session before unlock = %+v, want a configured lab-token gate this browser is not through", before)
	}

	c := unlocked(t, ts)
	resp, err := c.Get(ts.URL + "/api/session")
	if err != nil {
		t.Fatal(err)
	}
	var after session
	decode(t, resp, &after)
	if !after.Authed {
		t.Fatalf("session after unlock = %+v, want authed", after)
	}
}

// A stash another host received is deleted on the share -- artifact AND sidecar
// -- and drops out of this daemon's pool view at once rather than lingering
// until the next rescan. Reclaiming that disk must not need the owning VM.
func TestDeleteRemoteOnShare(t *testing.T) {
	ts, ui, stashRoot := newTestUI(t)
	remote := "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC()
	y, mo, d := now.Date()
	dir := filepath.Join(stashRoot, remote, config.FilesDirName,
		pad4(y), pad2(int(mo)), pad2(d))
	if err := writeRemoteStash(dir, "rr01", "peer.txt", "peer bytes"); err != nil {
		t.Fatalf("seed remote: %v", err)
	}
	artifact := filepath.Join(dir, "rr01.txt")
	sidecar := filepath.Join(dir, "rr01"+config.SidecarExtension)
	ui.pool.Refresh()

	var list struct {
		Total int `json:"total"`
	}
	getJSON(t, ts.URL+"/api/stashes?limit=50", &list)
	if list.Total != 1 {
		t.Fatalf("pool list before delete = %d rows, want the peer's 1", list.Total)
	}

	url := ts.URL + "/api/stashes/" + remote + "/" + pad4(y) + "/" + pad2(int(mo)) + "/" + pad2(d) + "/rr01"
	resp := deleteStash(t, unlocked(t, ts), url)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("cross-host delete = %d, want 200", resp.StatusCode)
	}
	if _, err := os.Stat(artifact); !os.IsNotExist(err) {
		t.Fatalf("the peer's artifact survived the delete (stat err = %v)", err)
	}
	if _, err := os.Stat(sidecar); !os.IsNotExist(err) {
		t.Fatalf("the peer's sidecar survived the delete (stat err = %v)", err)
	}
	// Evicted from the cache, not merely absent from the next rescan: the
	// browser that just deleted it must not be shown it again.
	getJSON(t, ts.URL+"/api/stashes?limit=50", &list)
	if list.Total != 0 {
		t.Fatalf("pool list after delete = %d rows, want 0", list.Total)
	}
}

// An id no host holds is a 404, not a silent success -- on the local index and
// on the share alike.
func TestDeleteMissingIs404(t *testing.T) {
	ts, _, _ := newTestUI(t)
	c := unlocked(t, ts)
	for _, url := range []string{
		ts.URL + "/api/stashes/" + testHostID + "/2026/06/16/abcd",
		ts.URL + "/api/stashes/42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/2026/06/16/abcd",
	} {
		resp := deleteStash(t, c, url)
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("delete of a missing stash at %s = %d, want 404", url, resp.StatusCode)
		}
	}
}

// The bulk route: one request, one verdict per stash. A refusal in the middle
// must not hide the deletes that worked, and must not abort the rest.
func TestDeleteBatchPartialFailure(t *testing.T) {
	ts, _, _ := newTestUI(t)
	first := postText(t, ts.URL, "one")
	second := postText(t, ts.URL, "two")

	body := `{"stashes":[` +
		batchItem(t, first) + `,` +
		`{"hostId":"` + testHostID + `","year":"2026","month":"06","day":"16","id":"zzzz"},` +
		batchItem(t, second) + `]}`
	resp, err := unlocked(t, ts).Post(ts.URL+"/api/stashes/delete", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		OK        bool `json:"ok"`
		Requested int  `json:"requested"`
		Deleted   int  `json:"deleted"`
		Failed    int  `json:"failed"`
		Results   []struct {
			ID    string `json:"id"`
			OK    bool   `json:"ok"`
			Error string `json:"error"`
		} `json:"results"`
	}
	decode(t, resp, &out)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("bulk delete = %d, want 200 even with a failure inside", resp.StatusCode)
	}
	if out.Requested != 3 || out.Deleted != 2 || out.Failed != 1 {
		t.Fatalf("bulk counts = %+v, want 3 requested / 2 deleted / 1 failed", out)
	}
	if len(out.Results) != 3 || !out.Results[0].OK || out.Results[1].OK || !out.Results[2].OK {
		t.Fatalf("per-stash verdicts = %+v, want ok/failed/ok in request order", out.Results)
	}
	if out.Results[1].Error == "" {
		t.Fatal("the failed stash carries no reason")
	}
	// Both real stashes are gone: the middle refusal did not abort the run.
	for _, p := range []string{first, second} {
		g, _ := http.Get(ts.URL + "/api/stashes/" + tail(p))
		g.Body.Close()
		if g.StatusCode != http.StatusNotFound {
			t.Fatalf("stash %s survived the bulk delete: get = %d", p, g.StatusCode)
		}
	}
}

// The bulk route is behind the same gate as the single one, and validates its
// body through the same path key rules -- a laxer parser for stashes named in a
// body is how a traversal gets in.
func TestDeleteBatchGuards(t *testing.T) {
	ts, _, _ := newTestUI(t)
	locked, err := http.Post(ts.URL+"/api/stashes/delete", "application/json",
		strings.NewReader(`{"stashes":[{"hostId":"`+testHostID+`","year":"2026","month":"06","day":"16","id":"abcd"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	locked.Body.Close()
	if locked.StatusCode != http.StatusUnauthorized {
		t.Fatalf("locked bulk delete = %d, want 401", locked.StatusCode)
	}

	c := unlocked(t, ts)
	for name, body := range map[string]string{
		"empty":    `{"stashes":[]}`,
		"not json": `nonsense`,
		"too many": `{"stashes":[` + strings.Repeat(`{"hostId":"h","year":"2026","month":"06","day":"16","id":"abcd"},`, maxBatchDelete) + `{"hostId":"h","year":"2026","month":"06","day":"16","id":"abcd"}]}`,
	} {
		resp, perr := c.Post(ts.URL+"/api/stashes/delete", "application/json", strings.NewReader(body))
		if perr != nil {
			t.Fatal(perr)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("bulk delete with a %s body = %d, want 400", name, resp.StatusCode)
		}
	}

	// A traversal in the hostId is refused per stash, not acted on.
	resp, err := c.Post(ts.URL+"/api/stashes/delete", "application/json",
		strings.NewReader(`{"stashes":[{"hostId":"../../etc","year":"2026","month":"06","day":"16","id":"abcd"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Deleted int `json:"deleted"`
		Failed  int `json:"failed"`
	}
	decode(t, resp, &out)
	if out.Deleted != 0 || out.Failed != 1 {
		t.Fatalf("traversal in a bulk body = %+v, want it refused", out)
	}
}

func TestPoolWideRemoteSidecar(t *testing.T) {
	ts, ui, stashRoot := newTestUI(t)
	remote := "42cccccccccccccccccccccccccccccc"
	now := time.Now().UTC()
	y, mo, d := now.Date()
	dayDir := filepath.Join(stashRoot, remote, config.FilesDirName,
		pad4(y), pad2(int(mo)), pad2(d))
	if err := writeRemoteStash(dayDir, "ef12", "remote.txt", "remote body"); err != nil {
		t.Fatalf("seed remote: %v", err)
	}
	ui.pool.Refresh()

	var list struct {
		Stashes []StashView `json:"stashes"`
	}
	getJSON(t, ts.URL+"/api/stashes?limit=50", &list)
	var found *StashView
	for i := range list.Stashes {
		if list.Stashes[i].HostID == remote {
			found = &list.Stashes[i]
		}
	}
	if found == nil {
		t.Fatalf("remote stash not in pool list: %+v", list.Stashes)
	}
	if found.Local {
		t.Fatal("remote stash marked local")
	}
	// Filter by remote host facet returns only it.
	getJSON(t, ts.URL+"/api/stashes?host="+remote, &list)
	if len(list.Stashes) != 1 || list.Stashes[0].HostID != remote {
		t.Fatalf("host facet: %+v", list.Stashes)
	}
}

func TestCreateHTMLServedAsText(t *testing.T) {
	ts, _, _ := newTestUI(t)
	permalink := postFile(t, ts.URL, "page.html", "<script>alert(1)</script>")

	var got struct {
		Stash StashView `json:"stash"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+tail(permalink), &got)
	if got.Stash.ContentClass != config.ClassOther {
		t.Fatalf("html class = %q, want other (download-only section 7.4)", got.Stash.ContentClass)
	}
	// Raw must NOT serve text/html (would execute) -- served as text/plain.
	r, err := http.Get(ts.URL + "/raw/" + tail(permalink))
	if err != nil {
		t.Fatal(err)
	}
	r.Body.Close()
	if ct := r.Header.Get("Content-Type"); strings.Contains(ct, "html") {
		t.Fatalf("html stash served as %q -- must not be executable", ct)
	}
}

func TestCreateMultiFileArchive(t *testing.T) {
	ts, _, _ := newTestUI(t)
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for _, f := range []struct{ name, body string }{{"a.txt", "aaa"}, {"b.txt", "bbb"}} {
		fw, _ := mw.CreateFormFile("files", f.name)
		_, _ = fw.Write([]byte(f.body))
	}
	_ = mw.Close()
	resp, err := http.Post(ts.URL+"/api/stashes", mw.FormDataContentType(), &buf)
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		OK        bool   `json:"ok"`
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)
	if !created.OK {
		t.Fatal("multi-file create failed")
	}
	var got struct {
		Stash StashView `json:"stash"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+tail(created.Permalink), &got)
	if !got.Stash.IsArchive || got.Stash.ContentClass != config.ClassArchive {
		t.Fatalf("multi-file should be an archive: %+v", got.Stash)
	}
	// Archive listing returns both entries.
	var arch struct {
		Entries []struct {
			Name string `json:"name"`
		} `json:"entries"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+tail(created.Permalink)+"/archive", &arch)
	if len(arch.Entries) < 2 {
		t.Fatalf("archive entries = %+v", arch.Entries)
	}
}

func TestShortAliasAndDateScoping(t *testing.T) {
	ts, _, _ := newTestUI(t)
	resp, err := http.Post(ts.URL+"/api/stashes", "application/x-www-form-urlencoded",
		strings.NewReader("title=n.txt&text=alias body"))
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)
	full := tail(created.Permalink)            // <host>/<y>/<m>/<d>/<id>
	short := full[strings.Index(full, "/")+1:] // <y>/<m>/<d>/<id>

	// Short alias resolves to the same local stash (section 4.4).
	var got struct {
		Stash StashView `json:"stash"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+short, &got)
	if got.Stash.OriginalFilename != "n.txt" {
		t.Fatalf("short alias did not resolve: %+v", got.Stash)
	}
	// Raw via short alias works too.
	r, err := http.Get(ts.URL + "/raw/" + short)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(r.Body)
	r.Body.Close()
	if string(body) != "alias body" {
		t.Fatalf("short-alias raw = %q", body)
	}

	// A fabricated date 404s (local resolve is date-scoped).
	seg := strings.Split(full, "/") // host y m d id
	bad := seg[0] + "/1999/01/01/" + seg[4]
	b, _ := http.Get(ts.URL + "/api/stashes/" + bad)
	b.Body.Close()
	if b.StatusCode != http.StatusNotFound {
		t.Fatalf("fabricated-date get = %d, want 404", b.StatusCode)
	}
}

func TestDateToInclusiveSameDay(t *testing.T) {
	ts, _, _ := newTestUI(t)
	resp, err := http.Post(ts.URL+"/api/stashes", "application/x-www-form-urlencoded",
		strings.NewReader("title=today.txt&text=x"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	today := time.Now().UTC().Format("2006-01-02")
	var list struct {
		Total int `json:"total"`
	}
	getJSON(t, ts.URL+"/api/stashes?to="+today, &list)
	if list.Total != 1 {
		t.Fatalf("to=<today> should include today's stash, got total=%d", list.Total)
	}
}

func TestShortURLRedirect(t *testing.T) {
	ts, _, _ := newTestUI(t)
	resp, err := http.Post(ts.URL+"/api/stashes", "application/x-www-form-urlencoded",
		strings.NewReader("title=s.txt&text=short"))
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		ID        string `json:"id"`
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)

	noFollow := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for _, p := range []string{"/" + created.ID, "/v/" + created.ID} {
		r, err := noFollow.Get(ts.URL + p)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		if r.StatusCode != http.StatusFound {
			t.Fatalf("GET %s = %d, want 302", p, r.StatusCode)
		}
		if loc := r.Header.Get("Location"); loc != created.Permalink {
			t.Fatalf("GET %s redirected to %q, want %q", p, loc, created.Permalink)
		}
	}

	// Unknown (but valid-format) id 404s; literal routes still win over /{id}.
	r404, _ := noFollow.Get(ts.URL + "/zzzz")
	r404.Body.Close()
	if r404.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown short id = %d, want 404", r404.StatusCode)
	}
	rNew, _ := noFollow.Get(ts.URL + "/new")
	rNew.Body.Close()
	if rNew.StatusCode != http.StatusOK {
		t.Fatalf("/new = %d, want 200 (literal must win over /{id})", rNew.StatusCode)
	}
}

func TestStaticPagesAndAssets(t *testing.T) {
	ts, _, _ := newTestUI(t)
	for _, p := range []string{"/", "/new", "/s/anything", "/assets/style.css", "/assets/common.js", "/healthz"} {
		resp, err := http.Get(ts.URL + p)
		if err != nil {
			t.Fatalf("GET %s: %v", p, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s = %d, want 200", p, resp.StatusCode)
		}
	}
	// A bogus asset 404s and cannot traverse out of web/.
	resp, _ := http.Get(ts.URL + "/assets/../../secret")
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatal("asset path traversal returned 200")
	}
}

// --- helpers -------------------------------------------------------------

func writeRemoteStash(dayDir, id, name, body string) error {
	if err := os.MkdirAll(dayDir, 0o700); err != nil {
		return err
	}
	artifact := filepath.Join(dayDir, id+".txt")
	if err := os.WriteFile(artifact, []byte(body), 0o600); err != nil {
		return err
	}
	now := time.Now().UTC()
	rec := &meta.Record{
		ID:               id,
		StoredPath:       artifact,
		OriginalFilename: name,
		Username:         "remoteuser",
		CreatedAt:        now,
		ReceivedAt:       &now,
		Status:           meta.StatusComplete,
		SizeBytes:        int64(len(body)),
		MimeType:         "text/plain",
		ContentClass:     config.ClassText,
		IsText:           true,
		Source:           config.SourceSCP,
	}
	return meta.WriteSidecar(rec)
}

// postText creates a text stash and returns its permalink.
func postText(t *testing.T, base, body string) string {
	t.Helper()
	resp, err := http.Post(base+"/api/stashes", "application/x-www-form-urlencoded",
		strings.NewReader("title=n.txt&text="+url.QueryEscape(body)))
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		OK        bool   `json:"ok"`
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)
	if !created.OK {
		t.Fatalf("postText %q failed", body)
	}
	return created.Permalink
}

// batchItem renders a permalink as one entry of a bulk-delete body.
func batchItem(t *testing.T, permalink string) string {
	t.Helper()
	parts := strings.Split(strings.TrimPrefix(permalink, "/s/"), "/") // host/y/m/d/id
	if len(parts) != 5 {
		t.Fatalf("permalink %q is not host/y/m/d/id", permalink)
	}
	return `{"hostId":"` + parts[0] + `","year":"` + parts[1] + `","month":"` + parts[2] +
		`","day":"` + parts[3] + `","id":"` + parts[4] + `"}`
}

func postFile(t *testing.T, base, name, body string) string {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormFile("files", name)
	_, _ = fw.Write([]byte(body))
	_ = mw.Close()
	resp, err := http.Post(base+"/api/stashes", mw.FormDataContentType(), &buf)
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		OK        bool   `json:"ok"`
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)
	if !created.OK {
		t.Fatalf("postFile %s failed", name)
	}
	return created.Permalink
}

// TestHostInfo covers the footer's host-facts endpoint: ok=true, the local
// hostId, the daemon version, and a serverIps STRING (newline-separated lines,
// possibly empty in a sandboxed CI with no non-loopback interface -- the
// contract is the shape, not a specific address). What this browser may DO is
// deliberately not here; that is /api/session's answer, and it changes under a
// page these facts do not.
func TestHostInfo(t *testing.T) {
	ts, _, _ := newTestUI(t)
	var info struct {
		OK          bool   `json:"ok"`
		LocalHostID string `json:"localHostId"`
		Version     string `json:"version"`
		ServerIps   string `json:"serverIps"`
	}
	getJSON(t, ts.URL+"/api/hostinfo", &info)
	if !info.OK || info.LocalHostID != testHostID || info.Version != testVersion {
		t.Fatalf("hostinfo should carry the host id and version; got %+v", info)
	}
	// Every reported line must be a comma-list of parseable IPs (no stray
	// whitespace, no link-local/loopback leaking through).
	if info.ServerIps != "" {
		for _, line := range strings.Split(info.ServerIps, "\n") {
			for _, addr := range strings.Split(line, ",") {
				ip := net.ParseIP(addr)
				if ip == nil {
					t.Fatalf("serverIps has non-IP token %q in %q", addr, info.ServerIps)
				}
				if ip.IsLoopback() || ip.IsLinkLocalUnicast() {
					t.Fatalf("serverIps leaked loopback/link-local %q", addr)
				}
			}
		}
	}
}

// TestIndexServesFooter verifies the home page carries the shared footer markup
// and that the module driving it is actually served -- i.e. the footer is wired
// end-to-end, not just defined.
//
// That module lives in the SDK's shared runtime rather than in this service's
// common.js, so this also covers the asset fallback: the file is embedded in
// another module and reaches the browser only if this service hands it over.
func TestIndexServesFooter(t *testing.T) {
	ts, _, _ := newTestUI(t)
	home := getText(t, ts.URL+"/")
	for _, want := range []string{`id="footer-bar"`, `id="footer-ip-list"`, `id="last-loaded"`, `id="countdown"`} {
		if !strings.Contains(home, want) {
			t.Fatalf("home page missing footer element %q", want)
		}
	}
	if !strings.Contains(home, "/assets/yuruna.core.js") {
		t.Fatalf("home page does not load the shared runtime, so it has no footer to wire")
	}
	js := getText(t, ts.URL+"/assets/yuruna.core.js")
	for _, module := range []string{"initFooter", "initMenu", "initHeader"} {
		if !strings.Contains(js, module) {
			t.Errorf("the shared runtime is served but does not define %s", module)
		}
	}
}

func TestCommaJoinUnique(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{nil, ""},
		{[]string{}, ""},
		{[]string{"10.0.0.2", "10.0.0.1", "10.0.0.2"}, "10.0.0.1,10.0.0.2"},
		{[]string{"192.168.7.15"}, "192.168.7.15"},
	}
	for _, c := range cases {
		if got := commaJoinUnique(c.in); got != c.want {
			t.Fatalf("commaJoinUnique(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func getJSON(t *testing.T, url string, v any) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	decode(t, resp, v)
}

func getText(t *testing.T, url string) string {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read %s: %v", url, err)
	}
	return string(b)
}

func decode(t *testing.T, resp *http.Response, v any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(v); err != nil {
		t.Fatalf("decode: %v", err)
	}
}
