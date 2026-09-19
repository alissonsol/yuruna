// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// HTTP handlers + routing for the stash UI/API.
package httpsrv

import (
	"archive/zip"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"mime/multipart"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
	"yuruna.com/test/extension/extension-sdk/i18n"

	"stash-service/internal/config"
	"stash-service/internal/detect"
	"stash-service/internal/meta"
	"stash-service/internal/sshsrv"

	"yuruna.com/test/extension/extension-sdk/webui"
)

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	// JSON API (section 9).
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /api/stashes", s.handleList)
	mux.HandleFunc("POST /api/stashes", s.handleCreate)
	mux.HandleFunc("POST /api/refresh", s.handleRefresh)
	mux.HandleFunc("GET /api/host", s.handleHostResolve)
	mux.HandleFunc("GET /api/hostinfo", s.handleHostInfo)
	// MCP over the same surface. A literal /mcp beats the catch-all
	// `GET /{id}` short-redirect below on specificity, so the short URLs are
	// untouched -- see the mount test.
	mux.HandleFunc("POST /mcp", s.mcpServer().Handler())
	mux.HandleFunc("GET /api/stashes/{hostId}/{year}/{month}/{day}/{id}", s.handleGetMeta)
	mux.HandleFunc("GET /api/stashes/{hostId}/{year}/{month}/{day}/{id}/archive", s.handleArchive)
	mux.HandleFunc("GET /raw/{hostId}/{year}/{month}/{day}/{id}", s.handleRaw)
	mux.HandleFunc("GET /download/{hostId}/{year}/{month}/{day}/{id}", s.handleDownload)
	// The gate (gate.go). Its own three routes stay open -- they are how a
	// credential is presented, so gating them would leave the prompt with no way
	// to be answered -- and every delete route sits behind it.
	mux.HandleFunc("GET /api/session", s.handleSession)
	mux.HandleFunc("POST /api/login", s.handleLogin)
	mux.HandleFunc("POST /api/unlock-proof", s.handleUnlockProof)
	mux.HandleFunc("DELETE /api/stashes/{hostId}/{year}/{month}/{day}/{id}", s.gate.Require(s.handleDelete))
	mux.HandleFunc("POST /api/stashes/delete", s.gate.Require(s.handleDeleteBatch))
	// Local short-alias routes (section 4.4): the hostId wildcard is omitted and
	// defaults to this host in parsePathKey, so /s/<y>/<m>/<d>/<id> works.
	mux.HandleFunc("GET /api/stashes/{year}/{month}/{day}/{id}", s.handleGetMeta)
	mux.HandleFunc("GET /api/stashes/{year}/{month}/{day}/{id}/archive", s.handleArchive)
	mux.HandleFunc("DELETE /api/stashes/{year}/{month}/{day}/{id}", s.gate.Require(s.handleDelete))
	mux.HandleFunc("GET /raw/{year}/{month}/{day}/{id}", s.handleRaw)
	mux.HandleFunc("GET /download/{year}/{month}/{day}/{id}", s.handleDownload)
	// Static pages + assets (section 2.3).
	mux.HandleFunc("GET /assets/", s.handleAsset)
	mux.HandleFunc("GET /new", s.servePage("new.html"))
	mux.HandleFunc("GET /s/", s.servePage("stash.html"))
	mux.HandleFunc("GET /{$}", s.servePage("index.html"))
	// Short URLs: /<id> (and the explicit /v/<id> alias) 302-redirect to the
	// canonical /s/<hostId>/<y>/<m>/<d>/<id>. The bare /{id} is a single-
	// segment wildcard; the literal routes above (/new, /healthz, /assets/,
	// /s/, /{$}) are more specific and still win, and a non-id segment just
	// 404s -- so this is the catch-all of last resort.
	mux.HandleFunc("GET /v/{id}", s.handleShortRedirect)
	mux.HandleFunc("GET /{id}", s.handleShortRedirect)
	return mux
}

// handleShortRedirect maps a bare 4-char id to the stash's canonical
// permalink and 302-redirects, so http://stash-service/h775 opens the stash.
func (s *Server) handleShortRedirect(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		http.NotFound(w, r)
		return
	}
	if pl := s.resolvePermalinkByID(id); pl != "" {
		http.Redirect(w, r, pl, http.StatusFound)
		return
	}
	http.NotFound(w, r)
}

// resolvePermalinkByID resolves a bare id to its canonical permalink. The
// local index is authoritative and unique-by-id, so it wins; otherwise the
// newest in-window pool match (a stash owned by another host) is used.
// Returns "" when no stash with that id is known.
func (s *Server) resolvePermalinkByID(id string) string {
	if rec, err := s.meta().Get(id); err == nil {
		y, mo, d := rec.CreatedAt.UTC().Date()
		return permalink(s.localHostID, y, int(mo), d, id)
	}
	var best *Item
	for _, it := range s.pool.Recent() {
		if it.Rec.ID != id {
			continue
		}
		if best == nil || it.Rec.CreatedAt.After(best.Rec.CreatedAt) {
			cp := it
			best = &cp
		}
	}
	if best != nil {
		y, mo, d := best.Rec.CreatedAt.UTC().Date()
		return permalink(best.HostID, y, int(mo), d, id)
	}
	return ""
}

// --- REGION: Helpers
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// pathKey pulls the {hostId}/{year}/{month}/{day}/{id} wildcards and
// validates them: hostId is hostId-shaped, date numeric, id 4 alnum. Rejects
// any traversal (".." can't pass the shape checks). Returns the cleaned
// parts and the UTC date.
type pathKey struct {
	hostID     string
	y, m, d    int
	id         string
	yS, mS, dS string
}

func (s *Server) parsePathKey(r *http.Request) (pathKey, bool) {
	return s.newPathKey(r.PathValue("hostId"), r.PathValue("year"), r.PathValue("month"), r.PathValue("day"), r.PathValue("id"))
}

// newPathKey is the validator itself, split out so a stash named in a REQUEST
// BODY (the bulk delete) passes exactly the checks one named in the URL does.
// A second, laxer parser for the batch route is how a traversal gets in.
func (s *Server) newPathKey(hostID, yS, mS, dS, id string) (pathKey, bool) {
	// The short-alias routes (/s/<y>/<m>/<d>/<id>, section 4.4) omit the hostId
	// wildcard; default it to this host, so the alias resolves to a local
	// stash exactly like the canonical full permalink.
	if hostID == "" {
		hostID = s.localHostID
	}
	// hostID only needs to be a safe single path segment (no traversal): the
	// local-vs-remote branch in resolve keys on == localHostID, and a bogus
	// remote hostId simply 404s. Requiring a hostId SHAPE here would wrongly
	// 400 the dev/local-fallback host (whose id is "share-local", not hex).
	if !safeSegment(hostID) || !validID(id) {
		return pathKey{}, false
	}
	y, ok1 := atoiOK(yS)
	m, ok2 := atoiOK(mS)
	d, ok3 := atoiOK(dS)
	if !ok1 || !ok2 || !ok3 || !validMonth(m) || !validDay(d) || y < 1970 || y > 9999 {
		return pathKey{}, false
	}
	return pathKey{hostID: hostID, y: y, m: m, d: d, id: id, yS: yS, mS: mS, dS: dS}, true
}

func validID(id string) bool {
	if len(id) != config.IDLength {
		return false
	}
	for _, r := range id {
		if !strings.ContainsRune(config.IDAlphabet, r) {
			return false
		}
	}
	return true
}

// safeSegment accepts a single path segment that cannot traverse out of its
// parent dir: non-empty, no separators, and no "." / ".." (so a crafted
// hostId can't escape stashRoot in resolve's filepath.Join).
func safeSegment(s string) bool {
	if s == "" || s == "." || s == ".." {
		return false
	}
	return !strings.ContainsAny(s, "/\\") && !strings.Contains(s, "..")
}

// resolved is a record plus the on-disk artifact path and owning host.
type resolved struct {
	rec      *meta.Record
	hostID   string
	artifact string
}

// resolve locates a stash by path key. Local: the live index (covers
// share + buffer + pending). Remote: the on-share sidecar + a glob for the
// artifact in that day folder. Returns (nil,false,nil) when not found.
func (s *Server) resolve(k pathKey) (*resolved, bool, error) {
	if k.hostID == s.localHostID {
		rec, err := s.meta().Get(k.id)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil, false, nil
			}
			return nil, false, err
		}
		// Verify the record's UTC date matches the path so a fabricated/stale
		// date 404s rather than serving the record, keeping the local path
		// date-scoped like the remote path (and correct if the id key ever
		// becomes per-day).
		if y, mo, d := rec.CreatedAt.UTC().Date(); y != k.y || int(mo) != k.m || d != k.d {
			return nil, false, nil
		}
		return &resolved{rec: rec, hostID: k.hostID, artifact: rec.StoredPath}, true, nil
	}
	dir := filepath.Join(s.stashRoot, k.hostID, config.FilesDirName, k.yS, k.mS, k.dS)
	rec, err := meta.ReadSidecar(filepath.Join(dir, k.id+config.SidecarExtension))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, nil
		}
		return nil, false, err
	}
	art := findArtifact(dir, k.id)
	return &resolved{rec: rec, hostID: k.hostID, artifact: art}, true, nil
}

// findArtifact returns the artifact file for id in dir (the file named id,
// or id.<ext>, or id.yuruna.archive.zip) -- excluding the sidecar and any
// leftover staging dir. Empty when none is found.
func findArtifact(dir, id string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if name != id && !strings.HasPrefix(name, id+".") {
			continue
		}
		if strings.HasSuffix(name, config.SidecarExtension) || strings.HasSuffix(name, ".staging") {
			continue
		}
		return filepath.Join(dir, name)
	}
	return ""
}

// effectiveResult returns the record's stored detection, classifying
// on-the-fly when a record predates the section 10 type fields. For a LOCALLY
// owned record it backfills (persists) the result; for a REMOTE record it
// only computes (never writes another host's storage -- the section 8.1 ownership
// boundary, honored by the on-the-fly detection in section 10).
func (s *Server) effectiveResult(r *resolved) detect.Result {
	rec := r.rec
	if rec.ContentClass != "" {
		return detect.Result{MimeType: rec.MimeType, ContentClass: rec.ContentClass, IsText: rec.IsText, TypeLabel: rec.TypeLabel, TypeScore: rec.TypeScore}
	}
	if rec.IsArchive {
		return detect.Result{MimeType: "application/zip", ContentClass: config.ClassArchive}
	}
	if r.artifact == "" {
		return detect.Result{MimeType: "application/octet-stream", ContentClass: config.ClassOther}
	}
	res := s.detector().DetectFile(r.artifact, rec.OriginalFilename)
	if r.hostID == s.localHostID && rec.Status == meta.StatusComplete {
		// Backfill our own record + rewrite the sidecar (section 10).
		if err := s.meta().UpdateType(rec.ID, res.MimeType, res.ContentClass, res.IsText, res.TypeLabel, res.TypeScore); err == nil {
			if fresh, gerr := s.meta().Get(rec.ID); gerr == nil && !fresh.LocallyBuffered {
				_ = meta.WriteSidecar(fresh)
			}
		}
	}
	return res
}

// --- REGION: Handlers
func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.WriteString(w, "ok")
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	f := parseListFilter(r)
	limit := s.clampLimit(r.URL.Query().Get("limit"))
	offset := atoiDefault(r.URL.Query().Get("offset"), 0)

	var views []StashView
	// Local index (unless the host facet pins a remote host). Fetch ALL
	// matching local rows (no LIMIT): the local index is fast and bounded by
	// this host's own corpus, and a full set is what makes the merged total
	// and pagination correct once remote rows are interleaved.
	if f.Host == "" || f.Host == s.localHostID {
		recs, err := s.meta().Search(f.toMetaFilter(0))
		if err != nil {
			s.writeLocalizedError(w, r, http.StatusInternalServerError, "stash.api_search_detail", "", map[string]any{"detail": err.Error()})
			return
		}
		for _, rc := range recs {
			views = append(views, s.viewFromRecord(rc, s.localHostID))
		}
	}
	// Remote hosts (unless the host facet pins the local host). poolPartial
	// carries through whether the remote scan was incomplete (a directory that
	// should have been readable was not), so the client can tell a genuinely
	// empty remote result from a degraded one.
	poolPartial := false
	if f.Host != s.localHostID {
		var items []Item
		if s.pool.fromBeforeWindow(f.From) || s.pool.toBeforeWindow(f.To) {
			items, poolPartial = s.pool.DeepScan(f.From, f.To)
		} else {
			items = s.pool.Recent()
			poolPartial = s.pool.LastRefreshPartial()
		}
		for _, it := range items {
			if f.Host != "" && it.HostID != f.Host {
				continue
			}
			if !f.match(it.Rec) {
				continue
			}
			views = append(views, s.viewFromRecord(it.Rec, it.HostID))
		}
	}

	// Sort the whole merged set, THEN page it: the window an offset names is
	// only meaningful once the order it indexes into is settled.
	col, asc := parseSort(r)
	sortViews(views, col, asc)
	total := len(views)
	views = page(views, offset, limit)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"stashes":     views,
		"total":       total,
		"limit":       limit,
		"offset":      offset,
		"sort":        col,
		"dir":         dirName(asc),
		"localHostId": s.localHostID,
		"poolPartial": poolPartial,
		"version":     s.version,
	})
}

// parseAndResolve runs the shared handler prologue -- parse the stash path key,
// resolve it, and write the 400 (invalid path) / 500 (resolve error) / 404 (not
// found) JSON error itself -- returning (res, true) only on a resolved, found
// stash. Callers needing extra post-conditions (e.g. handleArchive's
// artifact!="" / IsArchive checks) apply them to the returned res. serveBytes and
// handleDelete are NOT folded: serveBytes writes plain-text http.Error bodies,
// and handleDelete does an ownership check instead of resolve.
func (s *Server) parseAndResolve(w http.ResponseWriter, r *http.Request) (*resolved, bool) {
	k, ok := s.parsePathKey(r)
	if !ok {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_invalid_stash_path", "", nil)
		return nil, false
	}
	res, found, err := s.resolve(k)
	if err != nil {
		s.writeLocalizedError(w, r, http.StatusInternalServerError, "stash.api_detail", "", map[string]any{"detail": err.Error()})
		return nil, false
	}
	if !found {
		s.writeLocalizedError(w, r, http.StatusNotFound, "stash.api_stash_not_found", "", nil)
		return nil, false
	}
	return res, true
}

func (s *Server) handleGetMeta(w http.ResponseWriter, r *http.Request) {
	res, ok := s.parseAndResolve(w, r)
	if !ok {
		return
	}
	eff := s.effectiveResult(res)
	view := s.viewFromRecord(res.rec, res.hostID)
	view.MimeType, view.ContentClass, view.IsText, view.TypeLabel, view.TypeScore = eff.MimeType, eff.ContentClass, eff.IsText, eff.TypeLabel, eff.TypeScore
	// Remote stash -> resolve the owning host's UI deep-link (best-effort).
	if !view.Local {
		if base := s.resolveStashBaseURL(r.Context(), res.hostID); base != "" {
			view.RemoteStashURL = base + view.Permalink
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"stash":         view,
		"inlineTextCap": config.InlineTextPreviewCap,
	})
}

func (s *Server) handleArchive(w http.ResponseWriter, r *http.Request) {
	res, ok := s.parseAndResolve(w, r)
	if !ok {
		return
	}
	if res.artifact == "" {
		s.writeLocalizedError(w, r, http.StatusNotFound, "stash.api_stash_not_found", "", nil)
		return
	}
	if !res.rec.IsArchive {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_not_an_archive", "", nil)
		return
	}
	zr, err := zip.OpenReader(res.artifact)
	if err != nil {
		s.writeLocalizedError(w, r, http.StatusInternalServerError, "stash.api_open_archive_detail", "", map[string]any{"detail": err.Error()})
		return
	}
	defer zr.Close()
	type entry struct {
		Name string `json:"name"`
		Size int64  `json:"size"`
		Dir  bool   `json:"dir"`
	}
	entries := make([]entry, 0, len(zr.File))
	for _, f := range zr.File {
		entries = append(entries, entry{Name: f.Name, Size: int64(f.UncompressedSize64), Dir: f.FileInfo().IsDir()})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "entries": entries})
}

func (s *Server) handleRaw(w http.ResponseWriter, r *http.Request)      { s.serveBytes(w, r, false) }
func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) { s.serveBytes(w, r, true) }

// serveBytes streams an artifact. attachment=true forces a download
// (Content-Disposition: attachment, octet-stream); attachment=false serves
// inline for the UI's <img>/<embed>/<audio>/<video>/text fetch. Either way
// the active-content safety rules (section 7.4) apply: nosniff, a restrictive CSP,
// and text/plain for any non-(image|pdf|audio|video) type so a .html/.svg
// stash can never execute when opened directly.
func (s *Server) serveBytes(w http.ResponseWriter, r *http.Request, attachment bool) {
	k, ok := s.parsePathKey(r)
	if !ok {
		s.writeLocalizedHTTPError(w, r, "stash.api_invalid_stash_path", http.StatusBadRequest)
		return
	}
	res, found, err := s.resolve(k)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !found || res.artifact == "" {
		s.writeLocalizedHTTPError(w, r, "stash.api_stash_not_found", http.StatusNotFound)
		return
	}
	f, err := os.Open(res.artifact)
	if err != nil {
		s.writeLocalizedHTTPError(w, r, "stash.api_open_artifact", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		s.writeLocalizedHTTPError(w, r, "stash.api_stat_artifact", http.StatusInternalServerError)
		return
	}

	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; img-src 'self'; media-src 'self'; object-src 'self'; sandbox")
	w.Header().Set("Cache-Control", "no-store")

	if attachment {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", downloadDisposition(res.rec.OriginalFilename, res.rec.ID, res.rec.IsArchive))
	} else {
		w.Header().Set("Content-Type", inlineContentType(s.effectiveResult(res)))
		w.Header().Set("Content-Disposition", "inline")
	}
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

func (s *Server) handleCreate(w http.ResponseWriter, r *http.Request) {
	clientIP := clientIP(r)
	ct := r.Header.Get("Content-Type")
	// Bound the whole request body before any parse so an unauthenticated POST
	// can't fill /tmp (multipart spill) or the stash: the per-file 100 MB cap
	// bounds individual files, not the whole request.
	r.Body = http.MaxBytesReader(w, r.Body, config.MaxRequestBytes)

	// JSON paste body: {text, title, author}.
	if strings.HasPrefix(ct, "application/json") {
		var body struct {
			Text   string `json:"text"`
			Title  string `json:"title"`
			Author string `json:"author"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, config.PerFileSizeLimit+1024)).Decode(&body); err != nil {
			s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_invalid_json_body", "", nil)
			return
		}
		res, err := s.ssh.IngestText(body.Text, body.Title, authorOrWeb(body.Author), clientIP)
		s.respondCreate(w, r, res, err)
		return
	}

	// multipart/form-data (files[] + fields) OR urlencoded (text fields
	// only). ParseMultipartForm returns ErrNotMultipart for a urlencoded
	// body; fall back to ParseForm so a curl `-d text=...` works too.
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		if !errors.Is(err, http.ErrNotMultipart) {
			s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_could_not_parse_form", "", nil)
			return
		}
		if perr := r.ParseForm(); perr != nil {
			s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_could_not_parse_form", "", nil)
			return
		}
	}
	// ParseMultipartForm spills form parts larger than its in-memory limit to temp files under
	// os.TempDir(); those are only removed by MultipartForm.RemoveAll(). Without this, every
	// multi-megabyte or many-file POST leaves orphaned temp files that accumulate until the disk
	// fills and future ingests silently break.
	defer func() {
		if r.MultipartForm != nil {
			_ = r.MultipartForm.RemoveAll()
		}
	}()
	author := authorOrWeb(r.FormValue("author"))
	title := r.FormValue("title")

	var headers []*multipart.FileHeader
	if r.MultipartForm != nil {
		headers = r.MultipartForm.File["files"]
	}
	if len(headers) > config.MaxUploadFiles {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_too_many_files_in_one_upload", "", nil)
		return
	}
	switch {
	case len(headers) == 1:
		body, err := headers[0].Open()
		if err != nil {
			s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_open_upload", "", nil)
			return
		}
		defer body.Close()
		res, ierr := s.ssh.IngestSingle(headers[0].Filename, author, clientIP, "", config.SourceUI, body)
		s.respondCreate(w, r, res, ierr)
	case len(headers) > 1:
		var named []sshsrv.NamedReader
		var closers []io.Closer
		for _, fh := range headers {
			f, oerr := fh.Open()
			if oerr != nil {
				for _, c := range closers {
					_ = c.Close()
				}
				s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_open_uploads", "", nil)
				return
			}
			closers = append(closers, f)
			named = append(named, sshsrv.NamedReader{Name: fh.Filename, Body: f})
		}
		res, ierr := s.ssh.IngestMulti(named, author, clientIP, "", config.SourceUI)
		for _, c := range closers {
			_ = c.Close()
		}
		s.respondCreate(w, r, res, ierr)
	default:
		text := r.FormValue("text")
		if text == "" {
			s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_nothing_to_store_provide_text_or_files", "", nil)
			return
		}
		res, ierr := s.ssh.IngestText(text, title, author, clientIP)
		s.respondCreate(w, r, res, ierr)
	}
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	k, ok := s.parsePathKey(r)
	if !ok {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_invalid_stash_path", "", nil)
		return
	}
	if err := s.deleteStash(k); err != nil {
		status, msg := deleteStatus(err)
		s.writeLocalizedError(w, r, status, "stash.api_detail", "", map[string]any{"detail": msg})
		return
	}
	log.Printf("delete: host=%s id=%s from %s", k.hostID, k.id, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleDeleteBatch deletes a whole selection in one request. A page's worth of
// per-stash DELETEs would work, but this keeps the operator's action and the
// daemon's record of it one-to-one: one authorization, one audit line, one
// answer describing what happened to every id.
//
// Partial failure is data, not an HTTP status: the response is 200 with a
// per-stash verdict, so one refusal in a selection of fifty cannot hide the
// forty-nine that worked.
func (s *Server) handleDeleteBatch(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Stashes []struct {
			HostID string `json:"hostId"`
			Year   string `json:"year"`
			Month  string `json:"month"`
			Day    string `json:"day"`
			ID     string `json:"id"`
		} `json:"stashes"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, config.MaxRequestBytes)).Decode(&body); err != nil {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_invalid_json_body", "", nil)
		return
	}
	if len(body.Stashes) == 0 {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_no_stashes_given", "", nil)
		return
	}
	if len(body.Stashes) > maxBatchDelete {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_too_many_stashes_in_one_request", "", nil)
		return
	}

	type result struct {
		ID     string `json:"id"`
		HostID string `json:"hostId"`
		OK     bool   `json:"ok"`
		Error  string `json:"error,omitempty"`
		Code   string `json:"code,omitempty"`
	}
	locale := s.pages.Negotiator.Resolve(r)
	i18n.Apply(w.Header(), locale)
	results := make([]result, 0, len(body.Stashes))
	deleted := 0
	for _, want := range body.Stashes {
		k, ok := s.newPathKey(want.HostID, want.Year, want.Month, want.Day, want.ID)
		if !ok {
			results = append(results, result{ID: want.ID, HostID: want.HostID, Code: "stash.api_invalid_stash_path", Error: s.pages.Catalog.Render("stash.api_invalid_stash_path", nil, locale.ResolvedTag)})
			continue
		}
		if err := s.deleteStash(k); err != nil {
			_, msg := deleteStatus(err)
			results = append(results, result{ID: k.id, HostID: k.hostID, Error: msg})
			continue
		}
		deleted++
		results = append(results, result{ID: k.id, HostID: k.hostID, OK: true})
	}
	failed := len(results) - deleted
	log.Printf("delete (bulk): %d requested, %d deleted, %d failed, from %s", len(body.Stashes), deleted, failed, clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":        true,
		"requested": len(body.Stashes),
		"deleted":   deleted,
		"failed":    failed,
		"results":   results,
	})
}

func (s *Server) handleRefresh(w http.ResponseWriter, _ *http.Request) {
	s.pool.Refresh()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleHostResolve(w http.ResponseWriter, r *http.Request) {
	hostID := r.URL.Query().Get("host")
	if !looksLikeHostID(hostID) {
		s.writeLocalizedError(w, r, http.StatusBadRequest, "stash.api_invalid_host", "", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":           true,
		"hostId":       hostID,
		"local":        hostID == s.localHostID,
		"stashBaseUrl": s.resolveStashBaseURL(r.Context(), hostID),
	})
}

func (s *Server) respondCreate(w http.ResponseWriter, r *http.Request, res *sshsrv.IngestResult, err error) {
	if err != nil {
		s.writeLocalizedError(w, r, http.StatusInternalServerError, "stash.api_create_detail", "", map[string]any{"detail": err.Error()})
		return
	}
	y, mo, d := time.Now().UTC().Date()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":        true,
		"id":        res.ID,
		"hostId":    s.localHostID,
		"buffered":  res.Buffered,
		"permalink": permalink(s.localHostID, y, int(mo), d, res.ID),
	})
}

// --- REGION: Static assets
func (s *Server) servePage(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Restrict the UI pages to same-origin scripts/styles/connections so
		// a stray injected link or attribute can't execute or exfiltrate
		// (the artifact bytes have their own stricter CSP in serveBytes).
		// img-src/media-src 'self' covers the inline /raw image+av viewers.
		// script-src stays strict ('self', no unsafe-inline) -- that is the
		// real XSS control. style-src allows 'unsafe-inline' only so the
		// pages' few declarative style="display:none" attributes work;
		// inline style is not an exploitable sink here.
		w.Header().Set("Content-Security-Policy",
			"default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; media-src 'self'; object-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if !s.pages.Serve(w, r, name) {
			http.NotFound(w, r)
		}
	}
}

func (s *Server) handleAsset(w http.ResponseWriter, r *http.Request) {
	if s.pages.ServeAsset(w, r, strings.TrimPrefix(r.URL.Path, "/assets/")) {
		return
	}
	clean := filepath.ToSlash(filepath.Clean(strings.TrimPrefix(r.URL.Path, "/")))
	if !strings.HasPrefix(clean, "assets/") {
		s.writeLocalizedHTTPError(w, r, "stash.api_not_found", http.StatusNotFound)
		return
	}
	data, err := webFS.ReadFile("web/" + clean)
	if err != nil {
		// Not one of this service's own files, so try the shared ones. The
		// runtime every page loads first lives in the SDK precisely so there is
		// one copy of it; a service overrides a shared name by shipping a file
		// of that name itself, which is why its own directory is searched first.
		shared, ct, ok := webui.Asset(strings.TrimPrefix(clean, "assets/"))
		if !ok {
			s.writeLocalizedHTTPError(w, r, "stash.api_not_found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", ct)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		_, _ = w.Write(shared)
		return
	}
	w.Header().Set("Content-Type", assetContentType(clean))
	_, _ = w.Write(data)
}

// --- REGION: Small helpers
func parseListFilter(r *http.Request) listFilter {
	q := r.URL.Query()
	f := listFilter{
		ID:           q.Get("id"),
		Username:     firstNonEmpty(q.Get("username"), q.Get("q")),
		Filename:     firstNonEmpty(q.Get("filename"), q.Get("q")),
		PathMeta:     firstNonEmpty(q.Get("path"), q.Get("q")),
		ContentClass: q.Get("class"),
		Status:       q.Get("status"),
		Host:         q.Get("host"),
	}
	// A free-text q searches username/filename/path with OR semantics; when
	// q is set we route it through the substring fields and let match()/SQL
	// OR them. The local SQL filter ANDs fields, so for q we only set the
	// filename field (the most useful) to keep local+remote consistent.
	if qv := q.Get("q"); qv != "" {
		f.Username, f.PathMeta = "", ""
		f.Filename = qv
	}
	f.From = parseTimeBound(q.Get("from"), false)
	f.To = parseTimeBound(q.Get("to"), true)
	return f
}

// parseSort reads the ?sort= column and ?dir= direction. Unset or unrecognized
// yields the list's long-standing default, newest first.
//
// Only "asc" turns the order around; every other value (including a missing
// one) is descending. That asymmetry is deliberate -- the default view is a
// descending one, so an unreadable direction should land on it rather than on
// the inverse of what the page showed a moment ago.
func parseSort(r *http.Request) (string, bool) {
	q := r.URL.Query()
	return sortColumn(q.Get("sort")), strings.EqualFold(q.Get("dir"), "asc")
}

// dirName renders the direction for the JSON response, so a client can show
// which way it is actually being served rather than which way it asked for.
func dirName(asc bool) string {
	if asc {
		return "asc"
	}
	return "desc"
}

// parseTimeBound parses a from/to filter value. A full RFC3339 timestamp is
// used verbatim. A bare date "2006-01-02" is treated as a whole-day bound:
// the lower bound is that day's 00:00:00, the upper bound is that day's
// 23:59:59.999999999 -- so `to=2026-06-16` includes the entire 16th rather
// than excluding everything after midnight. Both the SQL path (createdAt <=)
// and the in-memory match (After) honor this identically.
func parseTimeBound(s string, upper bool) time.Time {
	if s == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC()
	}
	if t, err := time.Parse("2006-01-02", s); err == nil {
		t = t.UTC()
		if upper {
			return t.Add(24*time.Hour - time.Nanosecond)
		}
		return t
	}
	return time.Time{}
}

func (s *Server) clampLimit(v string) int {
	n := atoiDefault(v, s.defaultLimit)
	if n <= 0 {
		n = s.defaultLimit
	}
	if n > config.MaxListLimit {
		n = config.MaxListLimit
	}
	return n
}

func atoiDefault(s string, def int) int {
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}

func page(v []StashView, offset, limit int) []StashView {
	if offset < 0 {
		offset = 0
	}
	if offset >= len(v) {
		return []StashView{}
	}
	end := offset + limit
	if end > len(v) {
		end = len(v)
	}
	return v[offset:end]
}

func inlineContentType(res detect.Result) string {
	switch res.ContentClass {
	case config.ClassImage, config.ClassPDF, config.ClassAudio, config.ClassVideo:
		// Honor the stored MIME only when it maps back to the SAME renderable
		// class. A remote sidecar is peer-written, so a mismatch like
		// {class:image, mime:text/html} must not yield an inline text/html
		// response (section 7.4); fall back to octet-stream in that case.
		if res.MimeType != "" && detect.ClassFromMime(res.MimeType) == res.ContentClass {
			return res.MimeType
		}
		return "application/octet-stream"
	case config.ClassText:
		return "text/plain; charset=utf-8"
	default:
		// other/archive served inline -> text/plain so active content
		// (html/svg) can never execute when opened directly (section 7.4).
		return "text/plain; charset=utf-8"
	}
}

func assetContentType(name string) string {
	switch {
	case strings.HasSuffix(name, ".css"):
		return "text/css; charset=utf-8"
	case strings.HasSuffix(name, ".js"):
		return "text/javascript; charset=utf-8"
	case strings.HasSuffix(name, ".svg"):
		return "image/svg+xml"
	case strings.HasSuffix(name, ".html"):
		return "text/html; charset=utf-8"
	}
	return "application/octet-stream"
}

func clientIP(r *http.Request) string {
	if h, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return h
	}
	return r.RemoteAddr
}

func authorOrWeb(a string) string {
	a = strings.TrimSpace(a)
	if a == "" {
		return "web"
	}
	return a
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// sanitizeDownloadName produces a safe Content-Disposition filename: the
// original name with quotes/control/path chars stripped, falling back to the
// id (+ .zip for an archive) when empty.
func sanitizeDownloadName(orig, id string, isArchive bool) string {
	orig = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || r == '"' || r == '\\' || r == '/' {
			return -1
		}
		return r
	}, orig)
	orig = strings.TrimSpace(orig)
	if orig == "" {
		if isArchive {
			return id + ".zip"
		}
		return id
	}
	return orig
}

// The legacy parameter stays ASCII so older clients cannot guess the encoding.
// filename* carries the sanitized original UTF-8 bytes for standards-aware
// clients. Neither path changes the filename stored with the artifact.
func downloadDisposition(orig, id string, isArchive bool) string {
	name := sanitizeDownloadName(orig, id, isArchive)
	fallback := strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e {
			return '_'
		}
		return r
	}, name)
	if strings.Trim(fallback, "_. ") == "" {
		fallback = sanitizeDownloadName("", id, isArchive)
	}
	const hex = "0123456789ABCDEF"
	var encoded strings.Builder
	for _, b := range []byte(name) {
		if b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || strings.ContainsRune("!#$&+-.^_`|~", rune(b)) {
			encoded.WriteByte(b)
		} else {
			encoded.WriteByte('%')
			encoded.WriteByte(hex[b>>4])
			encoded.WriteByte(hex[b&15])
		}
	}
	return "attachment; filename=\"" + fallback + "\"; filename*=UTF-8''" + encoded.String()
}
