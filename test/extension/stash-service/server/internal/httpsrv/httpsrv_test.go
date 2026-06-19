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
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"stash-server/internal/config"
	"stash-server/internal/id"
	"stash-server/internal/meta"
	"stash-server/internal/sshsrv"
	"stash-server/internal/store"
)

const testHostID = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 32 hex, hostId-shaped

func newTestUI(t *testing.T) (*httptest.Server, *Server, string) {
	return newTestUIHost(t, testHostID)
}

func newTestUIHost(t *testing.T, hostID string) (*httptest.Server, *Server, string) {
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
	ids := id.New(st.FilesRoot(), buf.FilesRoot())
	ssh, err := sshsrv.New(st, buf, m, ids)
	if err != nil {
		t.Fatalf("sshsrv.New: %v", err)
	}
	ssh.ShareOnline = func() bool { return true } // force the share path in tests
	ui := New(ssh, Options{Addr: "127.0.0.1:0", PoolWindowDays: 30})
	ts := httptest.NewServer(ui.routes())
	t.Cleanup(ts.Close)
	return ts, ui, stashRoot
}

func tail(permalink string) string { return strings.TrimPrefix(permalink, "/s/") }

func TestCreateListGetRawDeleteText(t *testing.T) {
	ts, _, _ := newTestUI(t)

	// Create via form text (§5.1).
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

	// List (§4) — should contain it, marked local.
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

	// Get metadata (§6).
	var meta1 struct {
		Stash StashView `json:"stash"`
	}
	getJSON(t, ts.URL+"/api/stashes/"+tail(created.Permalink), &meta1)
	if meta1.Stash.ID != created.ID {
		t.Fatalf("meta id mismatch: %+v", meta1.Stash)
	}

	// Raw inline (§7): bytes + safety headers + text content type.
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

	// Download is an attachment (§7.5).
	rdl, err := http.Get(ts.URL + "/download/" + tail(created.Permalink))
	if err != nil {
		t.Fatal(err)
	}
	rdl.Body.Close()
	if cd := rdl.Header.Get("Content-Disposition"); !strings.HasPrefix(cd, "attachment") {
		t.Fatalf("download disposition = %q", cd)
	}

	// Delete local (§8) → then 404.
	req, _ := http.NewRequest(http.MethodDelete, ts.URL+"/api/stashes/"+tail(created.Permalink), nil)
	dresp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
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

func TestDeleteRemoteForbidden(t *testing.T) {
	ts, _, _ := newTestUI(t)
	remote := "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	req, _ := http.NewRequest(http.MethodDelete, ts.URL+"/api/stashes/"+remote+"/2026/06/16/abcd", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var body struct {
		OK          bool   `json:"ok"`
		OwnerHostID string `json:"ownerHostId"`
	}
	decode(t, resp, &body)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", resp.StatusCode)
	}
	if body.OK || body.OwnerHostID != remote {
		t.Fatalf("forbidden body = %+v", body)
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
		t.Fatalf("html class = %q, want other (download-only §7.4)", got.Stash.ContentClass)
	}
	// Raw must NOT serve text/html (would execute) — served as text/plain.
	r, err := http.Get(ts.URL + "/raw/" + tail(permalink))
	if err != nil {
		t.Fatal(err)
	}
	r.Body.Close()
	if ct := r.Header.Get("Content-Type"); strings.Contains(ct, "html") {
		t.Fatalf("html stash served as %q — must not be executable", ct)
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

	// Short alias resolves to the same local stash (§4.4).
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
// hostId, and a serverIps STRING (newline-separated lines, possibly empty in a
// sandboxed CI with no non-loopback interface — the contract is the shape, not
// a specific address).
func TestHostInfo(t *testing.T) {
	ts, _, _ := newTestUI(t)
	var info struct {
		OK          bool   `json:"ok"`
		LocalHostID string `json:"localHostId"`
		ServerIps   string `json:"serverIps"`
	}
	getJSON(t, ts.URL+"/api/hostinfo", &info)
	if !info.OK || info.LocalHostID != testHostID {
		t.Fatalf("hostinfo: %+v", info)
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

// TestIndexServesFooter verifies the home page carries the shared footer
// markup and that the footer module ships in common.js — i.e. the footer is
// actually wired end-to-end, not just defined.
func TestIndexServesFooter(t *testing.T) {
	ts, _, _ := newTestUI(t)
	home := getText(t, ts.URL+"/")
	for _, want := range []string{`id="footer-bar"`, `id="footer-ip-list"`, `id="last-loaded"`, `id="countdown"`} {
		if !strings.Contains(home, want) {
			t.Fatalf("home page missing footer element %q", want)
		}
	}
	js := getText(t, ts.URL+"/assets/common.js")
	if !strings.Contains(js, "initFooter") {
		t.Fatalf("common.js missing initFooter module")
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
