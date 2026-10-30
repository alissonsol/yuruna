// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42c61769-2140-41a4-ac36-c2619b2cdc7f

package httpsrv

import (
	"bytes"
	"encoding/json"
	"io"
	"io/fs"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"stash-service/internal/config"
)

// An internal failure is reported by its code and a catalog sentence, never by
// the error text: the causes name share paths and database state, and these
// replies are served on open routes. The cause still reaches the daemon log.

// readFailure decodes one localized error reply and fails the test when it is
// not a 500 carrying wantCode, or when it repeats any of the leaked strings.
func readFailure(t *testing.T, resp *http.Response, wantCode string, leaked ...string) {
	t.Helper()
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	var body struct {
		OK    bool   `json:"ok"`
		Code  string `json:"code"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("reply is not JSON: %v: %s", err, raw)
	}
	if resp.StatusCode != http.StatusInternalServerError || body.OK || body.Code != wantCode || body.Error == "" {
		t.Fatalf("reply = %d %+v, want 500 with code %s and a sentence", resp.StatusCode, body, wantCode)
	}
	for _, s := range leaked {
		if strings.Contains(string(raw), s) {
			t.Fatalf("reply repeats the internal cause %q: %s", s, raw)
		}
	}
}

// skipAsRoot skips a case whose fault is a permission the superuser ignores.
func skipAsRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("permission faults do not apply to the superuser")
	}
}

func TestASearchFailureNamesNoCause(t *testing.T) {
	ts, ui, _ := newTestUI(t)
	if err := ui.meta().Close(); err != nil {
		t.Fatal(err)
	}
	resp, err := http.Get(ts.URL + "/api/stashes")
	if err != nil {
		t.Fatal(err)
	}
	readFailure(t, resp, "stash.api_search_failed", "sql:", "closed")
}

func TestAResolveFailureNamesNoSharePath(t *testing.T) {
	ts, _, stashRoot := newTestUI(t)
	remote := "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC()
	y, mo, d := now.Date()
	dir := filepath.Join(stashRoot, remote, config.FilesDirName, pad4(y), pad2(int(mo)), pad2(d))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	// A sidecar that does not parse is a resolve error, not a missing stash.
	if err := os.WriteFile(filepath.Join(dir, "rr02"+config.SidecarExtension), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	resp, err := http.Get(ts.URL + "/api/stashes/" + remote + "/" + pad4(y) + "/" + pad2(int(mo)) + "/" + pad2(d) + "/rr02")
	if err != nil {
		t.Fatal(err)
	}
	readFailure(t, resp, "stash.api_resolve_failed", stashRoot, "invalid character")
}

func TestAnArchiveOpenFailureNamesNoSharePath(t *testing.T) {
	skipAsRoot(t)
	ts, _, stashRoot := newTestUI(t)
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for _, name := range []string{"a.txt", "b.txt"} {
		fw, _ := mw.CreateFormFile("files", name)
		_, _ = fw.Write([]byte(name))
	}
	_ = mw.Close()
	resp, err := http.Post(ts.URL+"/api/stashes", mw.FormDataContentType(), &buf)
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		OK        bool   `json:"ok"`
		ID        string `json:"id"`
		Permalink string `json:"permalink"`
	}
	decode(t, resp, &created)
	if !created.OK {
		t.Fatal("archive create failed")
	}
	id := created.Permalink[strings.LastIndex(created.Permalink, "/")+1:]
	var artifact string
	_ = filepath.WalkDir(stashRoot, func(p string, e fs.DirEntry, err error) error {
		if err == nil && !e.IsDir() && strings.HasPrefix(e.Name(), id+".") && filepath.Ext(p) == ".zip" {
			artifact = p
		}
		return nil
	})
	if artifact == "" {
		t.Fatal("archive artifact not found on the share")
	}
	if err := os.Chmod(artifact, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(artifact, 0o600) })
	resp, err = http.Get(ts.URL + "/api/stashes/" + tail(created.Permalink) + "/archive")
	if err != nil {
		t.Fatal(err)
	}
	readFailure(t, resp, "stash.api_open_archive_failed", stashRoot, "permission denied")
}

func TestACreateFailureNamesNoSharePath(t *testing.T) {
	skipAsRoot(t)
	ts, ui, stashRoot := newTestUI(t)
	files := ui.store().FilesRoot()
	if err := os.Chmod(files, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(files, 0o700) })
	resp, err := http.Post(ts.URL+"/api/stashes", "application/x-www-form-urlencoded", strings.NewReader("title=n.txt&text=body"))
	if err != nil {
		t.Fatal(err)
	}
	readFailure(t, resp, "stash.api_create_failed", stashRoot, "permission denied")
}

func TestADeleteFailureNamesNoSharePath(t *testing.T) {
	skipAsRoot(t)
	ts, ui, stashRoot := newTestUI(t)
	remote := "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC()
	y, mo, d := now.Date()
	dir := filepath.Join(stashRoot, remote, config.FilesDirName, pad4(y), pad2(int(mo)), pad2(d))
	if err := writeRemoteStash(dir, "rr03", "peer.txt", "peer bytes", now); err != nil {
		t.Fatal(err)
	}
	ui.pool.Refresh()
	// A folder the daemon cannot write keeps the sidecar from being removed.
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	c := unlocked(t, ts)
	resp := deleteStash(t, c, ts.URL+"/api/stashes/"+remote+"/"+pad4(y)+"/"+pad2(int(mo))+"/"+pad2(d)+"/rr03")
	readFailure(t, resp, "stash.api_delete_failed", stashRoot, "permission denied")

	body := `{"stashes":[{"hostId":"` + remote + `","year":"` + pad4(y) + `","month":"` + pad2(int(mo)) + `","day":"` + pad2(d) + `","id":"rr03"}]}`
	resp, err := c.Post(ts.URL+"/api/stashes/delete", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out struct {
		Results []struct {
			OK    bool   `json:"ok"`
			Code  string `json:"code"`
			Error string `json:"error"`
		} `json:"results"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Results) != 1 || out.Results[0].OK || out.Results[0].Code != "stash.api_delete_failed" || out.Results[0].Error == "" {
		t.Fatalf("bulk verdict = %s, want one failure with code stash.api_delete_failed", raw)
	}
	if strings.Contains(string(raw), stashRoot) || strings.Contains(string(raw), "permission denied") {
		t.Fatalf("bulk verdict repeats the internal cause: %s", raw)
	}
}

// A stash no host holds is still a plain 404 with its own code, singly and in
// a bulk verdict.
func TestADeleteOfNothingKeepsTheNotFoundCode(t *testing.T) {
	ts, _, _ := newTestUI(t)
	c := unlocked(t, ts)
	resp := deleteStash(t, c, ts.URL+"/api/stashes/"+testHostID+"/2026/06/16/abcd")
	defer resp.Body.Close()
	var body struct {
		Code string `json:"code"`
	}
	decode(t, resp, &body)
	if resp.StatusCode != http.StatusNotFound || body.Code != "stash.api_stash_not_found" {
		t.Fatalf("delete of nothing = %d %+v, want 404 stash.api_stash_not_found", resp.StatusCode, body)
	}
	bulk := `{"stashes":[{"hostId":"` + testHostID + `","year":"2026","month":"06","day":"16","id":"abcd"}]}`
	resp2, err := c.Post(ts.URL+"/api/stashes/delete", "application/json", strings.NewReader(bulk))
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Results []struct {
			Code string `json:"code"`
		} `json:"results"`
	}
	decode(t, resp2, &out)
	if len(out.Results) != 1 || out.Results[0].Code != "stash.api_stash_not_found" {
		t.Fatalf("bulk verdict for nothing = %+v, want stash.api_stash_not_found", out)
	}
}
