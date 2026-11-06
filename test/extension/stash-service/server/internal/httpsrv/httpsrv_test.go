// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 425936b7-4539-4686-bdd4-71efdac0e882

package httpsrv

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
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
const testVersion = "2026.11.05"

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
	return newTestUIOptions(t, hostID, Options{AggregatorURL: aggregatorURL})
}

// newTestUIOptions builds the UI with the caller's options; the listen
// address, version and pool window are always the test's own.
func newTestUIOptions(t *testing.T, hostID string, opts Options) (*httptest.Server, *Server, string) {
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
	opts.Addr, opts.Version, opts.PoolWindowDays = "127.0.0.1:0", testVersion, 30
	ui := New(ssh, opts)
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

	// Create via form text, the browser's paste path (see
	// https://yuruna.link/429e934f-0015).
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

	// The listing includes the created item, marked local.
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

	// Metadata describes the created item.
	var meta1 struct {
		Stash StashView `json:"stash"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+tail(created.Permalink), &meta1)
	if meta1.Stash.ID != created.ID {
		t.Fatalf("meta id mismatch: %+v", meta1.Stash)
	}

	// Raw inline reads preserve the bytes, safety headers and text content type.
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

	// Download is always available and is served as an attachment, never
	// inline (see https://yuruna.link/429e934f-0017).
	rdl, err := http.Get(ts.URL + "/download/" + tail(created.Permalink))
	if err != nil {
		t.Fatal(err)
	}
	rdl.Body.Close()
	if cd := rdl.Header.Get("Content-Disposition"); !strings.HasPrefix(cd, "attachment") {
		t.Fatalf("download disposition = %q", cd)
	}

	// Deleting a local item through an unlocked session makes later reads return 404.
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
	if err := writeRemoteStash(dir, "rr01", "peer.txt", "peer bytes", time.Now().UTC()); err != nil {
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
	if err := writeRemoteStash(dayDir, "ef12", "remote.txt", "remote body", time.Now().UTC()); err != nil {
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
		t.Fatalf("html class = %q, want other (an HTML stash is download-only, never rendered)", got.Stash.ContentClass)
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

	// The short alias without the hostId resolves to the same local stash
	// (see https://yuruna.link/429e934f-0014).
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

// --- REGION: Helpers
func writeRemoteStash(dayDir, id, name, body string, createdAt time.Time) error {
	if err := os.MkdirAll(dayDir, 0o700); err != nil {
		return err
	}
	artifact := filepath.Join(dayDir, id+".txt")
	if err := os.WriteFile(artifact, []byte(body), 0o600); err != nil {
		return err
	}
	rec := &meta.Record{
		ID:               id,
		StoredPath:       artifact,
		OriginalFilename: name,
		Username:         "remoteuser",
		CreatedAt:        createdAt,
		ReceivedAt:       &createdAt,
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

// postCreate posts a text create and returns the response. header adds or
// overrides request headers; a negative length sends the body chunked.
func postCreate(t *testing.T, ts *httptest.Server, contentType, body string, length int64, header map[string]string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/stashes", io.NopCloser(strings.NewReader(body)))
	if err != nil {
		t.Fatal(err)
	}
	req.ContentLength = length
	req.Header.Set("Content-Type", contentType)
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /api/stashes: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// A page on another site can make the operator's browser POST here; such a
// request is refused, while the service's own pages and every non-browser
// client (hosts, scripts, guests) are not affected.
func TestACrossSiteCreateIsRefused(t *testing.T) {
	ts, _, _ := newTestUI(t)
	body := `{"text":"hello"}`
	for _, c := range []struct {
		header map[string]string
		want   int
	}{
		{map[string]string{"Sec-Fetch-Site": "cross-site", "Origin": "http://elsewhere.example"}, http.StatusForbidden},
		{map[string]string{"Origin": "http://elsewhere.example"}, http.StatusForbidden},
		{map[string]string{"Sec-Fetch-Site": "same-origin"}, http.StatusOK},
		{nil, http.StatusOK},
	} {
		if r := postCreate(t, ts, "application/json", body, int64(len(body)), c.header); r.StatusCode != c.want {
			t.Errorf("create with %v = %d, want %d", c.header, r.StatusCode, c.want)
		}
	}
}

// requestNaming sends one request to ts that names host in its Host header,
// the way a browser does once a page's own name resolves to this service.
func requestNaming(t *testing.T, ts *httptest.Server, method, path, host, body string, header map[string]string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, ts.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Host = host
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("%s %s naming %s: %v", method, path, host, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// A page whose own name was made to resolve to this service (DNS rebinding) is
// same-origin with it, so the cross-origin check passes its requests; the name
// it carries is what refuses them, before any handler reads or stores a thing.
func TestARequestNamingAnotherHostIsRefused(t *testing.T) {
	ts, _, _ := newTestUI(t)
	if r := requestNaming(t, ts, http.MethodGet, "/api/stashes", "rebind.example", "", nil); r.StatusCode != http.StatusMisdirectedRequest {
		t.Errorf("GET /api/stashes naming rebind.example = %d, want 421", r.StatusCode)
	}
	rebound := map[string]string{"Content-Type": "application/json", "Origin": "http://rebind.example", "Sec-Fetch-Site": "same-origin"}
	r := requestNaming(t, ts, http.MethodPost, "/api/stashes", "rebind.example", `{"text":"planted"}`, rebound)
	if r.StatusCode != http.StatusMisdirectedRequest {
		t.Errorf("a create from a rebound page = %d, want 421", r.StatusCode)
	}
	var refusal map[string]any
	decode(t, r, &refusal)
	if refusal["code"] != "auth.host_not_served" {
		t.Errorf("refusal = %v, want code auth.host_not_served", refusal)
	}
	var list struct {
		Total int `json:"total"`
	}
	getJSON(t, ts.URL+"/api/stashes", &list)
	if list.Total != 0 {
		t.Fatalf("the refused create stored %d stash(es)", list.Total)
	}
	local := "localhost:" + ts.URL[strings.LastIndex(ts.URL, ":")+1:]
	if r := requestNaming(t, ts, http.MethodGet, "/api/stashes", local, "", nil); r.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/stashes naming %s = %d, want 200", local, r.StatusCode)
	}
}

// A name an operator configured for this VM is served; a name nobody
// configured still is not.
func TestConfiguredNamesAreServed(t *testing.T) {
	ts, _, _ := newTestUIOptions(t, testHostID, Options{AggregatorURL: fakeAggregator(t), AllowedHostNames: []string{"stash.lab"}})
	if r := requestNaming(t, ts, http.MethodGet, "/api/stashes", "stash.lab", "", nil); r.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/stashes naming the configured stash.lab = %d, want 200", r.StatusCode)
	}
	if r := requestNaming(t, ts, http.MethodGet, "/api/stashes", "other.lab", "", nil); r.StatusCode != http.StatusMisdirectedRequest {
		t.Fatalf("GET /api/stashes naming other.lab = %d, want 421", r.StatusCode)
	}
}

// Only one large text body is read at a time: while one is arriving, a second
// is refused with a retry hint, a small paste is not held up, and a body that
// stalls is cut off so the next one can be read.
func TestLargeTextBodiesAreReadOneAtATime(t *testing.T) {
	// The refusal can only be observed while the server still holds the
	// stalled body, so the read timeout is the whole window the probe below
	// has: it must outlast the scheduling delays of a loaded host (a gate run
	// with browsers and suites beside it), where half a second was missed.
	saved := textBodyReadTimeout
	textBodyReadTimeout = 4 * time.Second
	t.Cleanup(func() { textBodyReadTimeout = saved })
	// The probe is a large text too and takes the slot whenever it is free,
	// so one holding it when the stalled body's handler starts would get the
	// stalled body refused instead. The probe is sent only once the stalled
	// body holds the slot. Cleanups run last in, first out: registered before
	// the server exists, this reset runs after the server has closed, when no
	// handler can still read the hook.
	held := make(chan struct{}, 1)
	largeTextHeld = func() {
		select {
		case held <- struct{}{}:
		default:
		}
	}
	t.Cleanup(func() { largeTextHeld = nil })
	ts, _, _ := newTestUI(t)
	form := "application/x-www-form-urlencoded"
	stalled, err := net.Dial("tcp", ts.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stalled.Close() })
	fmt.Fprintf(stalled, "POST /api/stashes HTTP/1.1\r\nHost: %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\ntext=",
		ts.Listener.Addr(), form, config.InlineTextPreviewCap+1)
	select {
	case <-held:
	case <-time.After(10 * time.Second):
		t.Fatal("the stalled large text body never took the slot")
	}
	busy := postCreate(t, ts, form, "text=waiting", -1, nil)
	if busy.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("a second large text body while the first stalled = %d, want 503", busy.StatusCode)
	}
	if busy.Header.Get("Retry-After") == "" {
		t.Error("a refused large text carries no Retry-After")
	}
	if r := postCreate(t, ts, form, "text=small", int64(len("text=small")), nil); r.StatusCode != http.StatusOK {
		t.Fatalf("a small paste behind a large one = %d, want 200", r.StatusCode)
	}
	_ = stalled.SetReadDeadline(time.Now().Add(3 * textBodyReadTimeout))
	answer, err := http.ReadResponse(bufio.NewReader(stalled), nil)
	if err != nil {
		t.Fatalf("the stalled body was not cut off: %v", err)
	}
	answer.Body.Close()
	// The cut-off answer is written before the handler returns and releases
	// the slot, so the next large text can still meet the refusal for a
	// moment; it must be accepted once the slot is free, never stay refused.
	deadline := time.Now().Add(5 * time.Second)
	for {
		r := postCreate(t, ts, form, "text=after", -1, nil)
		if r.StatusCode == http.StatusOK {
			break
		}
		if r.StatusCode != http.StatusServiceUnavailable || time.Now().After(deadline) {
			t.Fatalf("a large text after the stalled one was cut off = %d, want 200", r.StatusCode)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// multipartPaste is the body the web UI posts for a paste: a multipart form
// whose text field holds what was pasted (web/assets/new.js).
func multipartPaste(t *testing.T, text string) (contentType, body string) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if err := mw.WriteField("text", text); err != nil {
		t.Fatal(err)
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	return mw.FormDataContentType(), buf.String()
}

// Every multipart create can hold its parsed parts in memory until it returns,
// so only a few are received at once: past the budget a create, a web UI
// paste included, is refused with a retry hint; a text body is not counted
// against it; and a slot is free again once its upload ends.
func TestMultipartCreatesAreCapped(t *testing.T) {
	// Each stalled upload signals once it holds a slot, so the refused create
	// is sent only when every slot is taken. Cleanups run last in, first out:
	// registered before the server exists, this reset runs after the server
	// has closed, when no handler can still read the hook.
	held := make(chan struct{}, config.MaxConcurrentMultipartCreates)
	multipartHeld = func() {
		select {
		case held <- struct{}{}:
		default:
		}
	}
	t.Cleanup(func() { multipartHeld = nil })
	ts, _, _ := newTestUI(t)
	var stalled []net.Conn
	for i := 0; i < config.MaxConcurrentMultipartCreates; i++ {
		conn, err := net.Dial("tcp", ts.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		fmt.Fprintf(conn, "POST /api/stashes HTTP/1.1\r\nHost: %s\r\nContent-Type: multipart/form-data; boundary=stalled\r\nContent-Length: %d\r\n\r\n"+
			"--stalled\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\npartial", ts.Listener.Addr(), 1<<20)
		stalled = append(stalled, conn)
	}
	for i := 0; i < config.MaxConcurrentMultipartCreates; i++ {
		select {
		case <-held:
		case <-time.After(10 * time.Second):
			t.Fatalf("only %d of %d stalled uploads took a slot", i, config.MaxConcurrentMultipartCreates)
		}
	}
	contentType, paste := multipartPaste(t, "waiting")
	busy := postCreate(t, ts, contentType, paste, int64(len(paste)), nil)
	if busy.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("a web UI paste while every upload slot is taken = %d, want 503", busy.StatusCode)
	}
	if busy.Header.Get("Retry-After") == "" {
		t.Error("a refused upload carries no Retry-After")
	}
	var refusal map[string]any
	decode(t, busy, &refusal)
	if refusal["code"] != "stash.api_uploads_busy" {
		t.Errorf("refusal = %v, want code stash.api_uploads_busy", refusal)
	}
	if r := postCreate(t, ts, "application/json", `{"text":"small"}`, int64(len(`{"text":"small"}`)), nil); r.StatusCode != http.StatusOK {
		t.Fatalf("a JSON paste while the upload slots are taken = %d, want 200", r.StatusCode)
	}
	// The slot is released when the handler returns, a moment after the
	// closed upload's connection is gone, so the next create can still meet
	// the refusal briefly; it must be accepted once the slot is free.
	stalled[0].Close()
	deadline := time.Now().Add(5 * time.Second)
	for {
		contentType, paste := multipartPaste(t, "after")
		r := postCreate(t, ts, contentType, paste, int64(len(paste)), nil)
		if r.StatusCode == http.StatusOK {
			break
		}
		if r.StatusCode != http.StatusServiceUnavailable || time.Now().After(deadline) {
			t.Fatalf("a paste after one upload ended = %d, want 200", r.StatusCode)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// A text body is bounded like the one file it becomes, not like a multi-file
// upload: a urlencoded body past one file is refused instead of being read
// into memory whole.
func TestATextBodyIsBoundedLikeOneFile(t *testing.T) {
	ts, _, _ := newTestUI(t)
	conn, err := net.Dial("tcp", ts.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	n := int64(config.PerFileSizeLimit) + 1<<20
	go func() {
		fmt.Fprintf(conn, "POST /api/stashes HTTP/1.1\r\nHost: %s\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\ntext=",
			ts.Listener.Addr(), n+5)
		_, _ = io.Copy(conn, io.LimitReader(repeatByte('a'), n))
	}()
	_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("no answer to an oversized text body: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("a urlencoded body past one file = %d, want 400", resp.StatusCode)
	}
}

type repeatByte byte

func (b repeatByte) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = byte(b)
	}
	return len(p), nil
}

// A control character in a stash path is refused as an invalid path, and the
// reply never carries the file system error that would name the share.
func TestAControlCharacterInAStashPathIsRefused(t *testing.T) {
	ts, _, stashRoot := newTestUI(t)
	resp, err := http.Get(ts.URL + "/raw/foo%00bar/2026/10/20/aaaa")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("a NUL in the host segment = %d, want 400", resp.StatusCode)
	}
	if bytes.Contains(body, []byte(stashRoot)) {
		t.Fatalf("the reply names the share: %s", body)
	}
}
