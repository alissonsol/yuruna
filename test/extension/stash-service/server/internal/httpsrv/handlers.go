// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// HTTP handlers + routing for the stash UI/API (stash-service-ui.md §9).
package httpsrv

import (
	"archive/zip"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"stash-server/internal/config"
	"stash-server/internal/detect"
	"stash-server/internal/meta"
	"stash-server/internal/sshsrv"
)

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	// JSON API (§9).
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /api/stashes", s.handleList)
	mux.HandleFunc("POST /api/stashes", s.handleCreate)
	mux.HandleFunc("POST /api/refresh", s.handleRefresh)
	mux.HandleFunc("GET /api/host", s.handleHostResolve)
	mux.HandleFunc("GET /api/hostinfo", s.handleHostInfo)
	mux.HandleFunc("GET /api/stashes/{hostId}/{year}/{month}/{day}/{id}", s.handleGetMeta)
	mux.HandleFunc("GET /api/stashes/{hostId}/{year}/{month}/{day}/{id}/archive", s.handleArchive)
	mux.HandleFunc("DELETE /api/stashes/{hostId}/{year}/{month}/{day}/{id}", s.handleDelete)
	mux.HandleFunc("GET /raw/{hostId}/{year}/{month}/{day}/{id}", s.handleRaw)
	mux.HandleFunc("GET /download/{hostId}/{year}/{month}/{day}/{id}", s.handleDownload)
	// Local short-alias routes (§4.4): the hostId wildcard is omitted and
	// defaults to this host in parsePathKey, so /s/<y>/<m>/<d>/<id> works.
	mux.HandleFunc("GET /api/stashes/{year}/{month}/{day}/{id}", s.handleGetMeta)
	mux.HandleFunc("GET /api/stashes/{year}/{month}/{day}/{id}/archive", s.handleArchive)
	mux.HandleFunc("DELETE /api/stashes/{year}/{month}/{day}/{id}", s.handleDelete)
	mux.HandleFunc("GET /raw/{year}/{month}/{day}/{id}", s.handleRaw)
	mux.HandleFunc("GET /download/{year}/{month}/{day}/{id}", s.handleDownload)
	// Static pages + assets (§2.3).
	mux.HandleFunc("GET /assets/", s.handleAsset)
	mux.HandleFunc("GET /new", s.servePage("new.html"))
	mux.HandleFunc("GET /s/", s.servePage("stash.html"))
	mux.HandleFunc("GET /{$}", s.servePage("index.html"))
	// Short URLs: /<id> (and the explicit /v/<id> alias) 302-redirect to the
	// canonical /s/<hostId>/<y>/<m>/<d>/<id>. The bare /{id} is a single-
	// segment wildcard; the literal routes above (/new, /healthz, /assets/,
	// /s/, /{$}) are more specific and still win, and a non-id segment just
	// 404s — so this is the catch-all of last resort.
	mux.HandleFunc("GET /v/{id}", s.handleShortRedirect)
	mux.HandleFunc("GET /{id}", s.handleShortRedirect)
	return mux
}

// handleShortRedirect maps a bare 4-char id to the stash's canonical
// permalink and 302-redirects, so http://stash-server/h775 opens the stash.
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

// --- helpers -------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "error": msg})
}

// pathKey pulls the {hostId}/{year}/{month}/{day}/{id} wildcards and
// validates them: hostId hostId-shaped, date numeric, id 4 alnum. Rejects
// any traversal (".." can't pass the shape checks). Returns the cleaned
// parts and the UTC date.
type pathKey struct {
	hostID     string
	y, m, d    int
	id         string
	yS, mS, dS string
}

func (s *Server) parsePathKey(r *http.Request) (pathKey, bool) {
	hostID := r.PathValue("hostId")
	// The short-alias routes (/s/<y>/<m>/<d>/<id>, §4.4) omit the hostId
	// wildcard; default it to this host, so the alias resolves to a local
	// stash exactly like the canonical full permalink.
	if hostID == "" {
		hostID = s.localHostID
	}
	yS := r.PathValue("year")
	mS := r.PathValue("month")
	dS := r.PathValue("day")
	id := r.PathValue("id")
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
	if !ok1 || !ok2 || !ok3 || m < 1 || m > 12 || d < 1 || d > 31 || y < 1970 || y > 9999 {
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
// or id.<ext>, or id.yuruna.archive.zip) — excluding the sidecar and any
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
// on-the-fly when a record predates the §10 type fields. For a LOCALLY
// owned record it backfills (persists) the result; for a REMOTE record it
// only computes (never writes another host's storage — the §8.1 ownership
// boundary, honored by the on-the-fly detection in §10).
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
		// Backfill our own record + rewrite the sidecar (§10).
		if err := s.meta().UpdateType(rec.ID, res.MimeType, res.ContentClass, res.IsText, res.TypeLabel, res.TypeScore); err == nil {
			if fresh, gerr := s.meta().Get(rec.ID); gerr == nil && !fresh.LocallyBuffered {
				_ = meta.WriteSidecar(fresh)
			}
		}
	}
	return res
}

// --- handlers ------------------------------------------------------------

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
			writeErr(w, http.StatusInternalServerError, "search: "+err.Error())
			return
		}
		for _, rc := range recs {
			views = append(views, s.viewFromRecord(rc, s.localHostID))
		}
	}
	// Remote hosts (unless the host facet pins the local host).
	if f.Host != s.localHostID {
		var items []Item
		if s.pool.fromBeforeWindow(f.From) || s.pool.toBeforeWindow(f.To) {
			items = s.pool.DeepScan(f.From, f.To)
		} else {
			items = s.pool.Recent()
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

	sortViewsDesc(views)
	total := len(views)
	views = page(views, offset, limit)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"stashes":     views,
		"total":       total,
		"limit":       limit,
		"offset":      offset,
		"localHostId": s.localHostID,
		"version":     s.version,
	})
}

func (s *Server) handleGetMeta(w http.ResponseWriter, r *http.Request) {
	k, ok := s.parsePathKey(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid stash path")
		return
	}
	res, found, err := s.resolve(k)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, "stash not found")
		return
	}
	eff := s.effectiveResult(res)
	view := s.viewFromRecord(res.rec, res.hostID)
	view.MimeType, view.ContentClass, view.IsText, view.TypeLabel, view.TypeScore = eff.MimeType, eff.ContentClass, eff.IsText, eff.TypeLabel, eff.TypeScore
	// Remote stash → resolve the owning host's UI deep-link (best-effort).
	if !view.Local {
		if base := s.resolveStashBaseURL(res.hostID); base != "" {
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
	k, ok := s.parsePathKey(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid stash path")
		return
	}
	res, found, err := s.resolve(k)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !found || res.artifact == "" {
		writeErr(w, http.StatusNotFound, "stash not found")
		return
	}
	if !res.rec.IsArchive {
		writeErr(w, http.StatusBadRequest, "not an archive")
		return
	}
	zr, err := zip.OpenReader(res.artifact)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "open archive: "+err.Error())
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
// the active-content safety rules (§7.4) apply: nosniff, a restrictive CSP,
// and text/plain for any non-(image|pdf|audio|video) type so a .html/.svg
// stash can never execute when opened directly.
func (s *Server) serveBytes(w http.ResponseWriter, r *http.Request, attachment bool) {
	k, ok := s.parsePathKey(r)
	if !ok {
		http.Error(w, "invalid stash path", http.StatusBadRequest)
		return
	}
	res, found, err := s.resolve(k)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !found || res.artifact == "" {
		http.Error(w, "stash not found", http.StatusNotFound)
		return
	}
	f, err := os.Open(res.artifact)
	if err != nil {
		http.Error(w, "open artifact", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		http.Error(w, "stat artifact", http.StatusInternalServerError)
		return
	}

	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; img-src 'self'; media-src 'self'; object-src 'self'; sandbox")
	w.Header().Set("Cache-Control", "no-store")

	if attachment {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", "attachment; filename=\""+sanitizeDownloadName(res.rec.OriginalFilename, res.rec.ID, res.rec.IsArchive)+"\"")
	} else {
		w.Header().Set("Content-Type", inlineContentType(s.effectiveResult(res)))
		w.Header().Set("Content-Disposition", "inline")
	}
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

func (s *Server) handleCreate(w http.ResponseWriter, r *http.Request) {
	clientIP := clientIP(r)
	ct := r.Header.Get("Content-Type")
	// Bound the whole request body before any parse so an unauthenticated
	// POST can't fill /tmp or the stash (§ security: multipart spill + the
	// per-file 100 MB cap only bounds individual files, not the request).
	r.Body = http.MaxBytesReader(w, r.Body, config.MaxRequestBytes)

	// JSON paste body: {text, title, author}.
	if strings.HasPrefix(ct, "application/json") {
		var body struct {
			Text   string `json:"text"`
			Title  string `json:"title"`
			Author string `json:"author"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, config.PerFileSizeLimit+1024)).Decode(&body); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		res, err := s.ssh.IngestText(body.Text, body.Title, authorOrWeb(body.Author), clientIP)
		s.respondCreate(w, res, err)
		return
	}

	// multipart/form-data (files[] + fields) OR urlencoded (text fields
	// only). ParseMultipartForm returns ErrNotMultipart for a urlencoded
	// body; fall back to ParseForm so a curl `-d text=...` works too.
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		if !errors.Is(err, http.ErrNotMultipart) {
			writeErr(w, http.StatusBadRequest, "could not parse form")
			return
		}
		if perr := r.ParseForm(); perr != nil {
			writeErr(w, http.StatusBadRequest, "could not parse form")
			return
		}
	}
	author := authorOrWeb(r.FormValue("author"))
	title := r.FormValue("title")

	var headers []*multipart.FileHeader
	if r.MultipartForm != nil {
		headers = r.MultipartForm.File["files"]
	}
	if len(headers) > config.MaxUploadFiles {
		writeErr(w, http.StatusBadRequest, "too many files in one upload")
		return
	}
	switch {
	case len(headers) == 1:
		body, err := headers[0].Open()
		if err != nil {
			writeErr(w, http.StatusBadRequest, "open upload")
			return
		}
		defer body.Close()
		res, ierr := s.ssh.IngestSingle(headers[0].Filename, author, clientIP, "", config.SourceUI, body)
		s.respondCreate(w, res, ierr)
	case len(headers) > 1:
		var named []sshsrv.NamedReader
		var closers []io.Closer
		for _, fh := range headers {
			f, oerr := fh.Open()
			if oerr != nil {
				for _, c := range closers {
					_ = c.Close()
				}
				writeErr(w, http.StatusBadRequest, "open uploads")
				return
			}
			closers = append(closers, f)
			named = append(named, sshsrv.NamedReader{Name: fh.Filename, Body: f})
		}
		res, ierr := s.ssh.IngestMulti(named, author, clientIP, "", config.SourceUI)
		for _, c := range closers {
			_ = c.Close()
		}
		s.respondCreate(w, res, ierr)
	default:
		text := r.FormValue("text")
		if text == "" {
			writeErr(w, http.StatusBadRequest, "nothing to store: provide text or files")
			return
		}
		res, ierr := s.ssh.IngestText(text, title, author, clientIP)
		s.respondCreate(w, res, ierr)
	}
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	k, ok := s.parsePathKey(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid stash path")
		return
	}
	// §8.3: local-host-only. A foreign hostId is refused server-side with a
	// 403 naming the owning host — the ownership boundary is a real contract
	// (and the seam for future per-host auth), not just a disabled button.
	if k.hostID != s.localHostID {
		writeJSON(w, http.StatusForbidden, map[string]any{
			"ok":          false,
			"error":       "this stash is owned by host " + k.hostID + "; delete it from that host's own stash UI",
			"ownerHostId": k.hostID,
		})
		return
	}
	if err := s.ssh.DeleteLocal(k.id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeErr(w, http.StatusNotFound, "stash not found")
			return
		}
		writeErr(w, http.StatusInternalServerError, "delete: "+err.Error())
		return
	}
	// Note: no pool-cache eviction here — the local host is never in the pool
	// cache (scan skips it), so local rows come straight from the live index.
	// A remote delete (done on its owning host) drops out on the next rescan.
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleRefresh(w http.ResponseWriter, _ *http.Request) {
	s.pool.Refresh()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleHostResolve(w http.ResponseWriter, r *http.Request) {
	hostID := r.URL.Query().Get("host")
	if !looksLikeHostID(hostID) {
		writeErr(w, http.StatusBadRequest, "invalid host")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":           true,
		"hostId":       hostID,
		"local":        hostID == s.localHostID,
		"stashBaseUrl": s.resolveStashBaseURL(hostID),
	})
}

func (s *Server) respondCreate(w http.ResponseWriter, res *sshsrv.IngestResult, err error) {
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "create: "+err.Error())
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

// --- static assets -------------------------------------------------------

func (s *Server) servePage(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		data, err := webFS.ReadFile("web/" + name)
		if err != nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		// Restrict the UI pages to same-origin scripts/styles/connections so
		// a stray injected link or attribute can't execute or exfiltrate
		// (the artifact bytes have their own stricter CSP in serveBytes).
		// img-src/media-src 'self' covers the inline /raw image+av viewers.
		// script-src stays strict ('self', no unsafe-inline) — that is the
		// real XSS control. style-src allows 'unsafe-inline' only so the
		// pages' few declarative style="display:none" attributes work;
		// inline style is not an exploitable sink here.
		w.Header().Set("Content-Security-Policy",
			"default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; media-src 'self'; object-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		_, _ = w.Write(data)
	}
}

func (s *Server) handleAsset(w http.ResponseWriter, r *http.Request) {
	clean := filepath.ToSlash(filepath.Clean(strings.TrimPrefix(r.URL.Path, "/")))
	if !strings.HasPrefix(clean, "assets/") {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	data, err := webFS.ReadFile("web/" + clean)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", assetContentType(clean))
	_, _ = w.Write(data)
}

// --- small helpers -------------------------------------------------------

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

// parseTimeBound parses a from/to filter value. A full RFC3339 timestamp is
// used verbatim. A bare date "2006-01-02" is treated as a whole-day bound:
// the lower bound is that day's 00:00:00, the upper bound is that day's
// 23:59:59.999999999 — so `to=2026-06-16` includes the entire 16th rather
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
		// response (§7.4); fall back to octet-stream in that case.
		if res.MimeType != "" && detect.ClassFromMime(res.MimeType) == res.ContentClass {
			return res.MimeType
		}
		return "application/octet-stream"
	case config.ClassText:
		return "text/plain; charset=utf-8"
	default:
		// other/archive served inline → text/plain so active content
		// (html/svg) can never execute when opened directly (§7.4).
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
		if r < 0x20 || r == '"' || r == '\\' || r == '/' {
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
