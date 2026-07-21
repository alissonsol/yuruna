// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package meta owns the SQLite metadata store (§8). One row per
// upload. Status moves pending -> {complete | truncated | partial}.
//
// The driver is modernc.org/sqlite (pure-Go), so the daemon builds
// without CGO_ENABLED=1. Substring search on originalFilename /
// pathMetadata uses LIKE %x% with no FTS index in v1; the
// in-VM UI may add FTS5 if the corpus grows beyond what LIKE handles.
package meta

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"stash-server/internal/config"
	"stash-server/internal/fsutil"
)

// Status values (§8.1).
const (
	StatusPending   = "pending"
	StatusComplete  = "complete"
	StatusPartial   = "partial"
	StatusTruncated = "truncated"
)

// Record mirrors §8.1's metadata fields.
type Record struct {
	ID               string
	StoredPath       string
	OriginalFilename string
	IsArchive        bool
	Username         string
	PathMetadata     string
	ClientAddress    string
	CreatedAt        time.Time
	ReceivedAt       *time.Time
	Status           string
	SizeBytes        int64
	// LocallyBuffered is true while the artifact sits in the VM-local
	// buffer awaiting flush to the share (§8.4). Committed (on-share)
	// records are false.
	LocallyBuffered bool

	// UI fields (stash-service-ui.md §10). Populated by server-side
	// detection at upload/flush time; carried on the durable sidecar so a
	// stash classified on one host renders the same when viewed from
	// another, and survives a reimage rebuild.
	MimeType     string  // detected MIME type
	ContentClass string  // text|image|pdf|audio|video|archive|other
	IsText       bool    // convenience flag for the text viewer
	TypeLabel    string  // detector label (optional, diagnostics)
	TypeScore    float64 // detector confidence 0..1 (optional)
	Source       string  // "scp" or "ui" (config.SourceSCP / SourceUI)
}

// Store wraps a *sql.DB scoped to one stash.sqlite.
type Store struct {
	db *sql.DB
}

// Open creates / opens stash.sqlite at dbPath, applies the schema, and
// returns a ready-to-use Store. Callers must Close when done.
func Open(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	if err := migrate(db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate schema: %w", err)
	}
	return &Store{db: db}, nil
}

// migrate adds the UI columns (stash-service-ui.md §10) to an uploads table
// created by an earlier schema. CREATE TABLE IF NOT EXISTS does not alter an
// existing table, so the columns are added here. It reads the current columns
// via PRAGMA table_info and issues ADD COLUMN only for those missing, so it is
// idempotent (a brand-new DB from `schema` above already has them all; a
// re-run adds nothing) without inferring "already present" from a driver-
// specific error string, which varies between SQLite bindings.
func migrate(db *sql.DB) error {
	have, err := tableColumns(db, "uploads")
	if err != nil {
		return err
	}
	adds := []struct{ col, stmt string }{
		{"mimeType", `ALTER TABLE uploads ADD COLUMN mimeType     TEXT NOT NULL DEFAULT ''`},
		{"contentClass", `ALTER TABLE uploads ADD COLUMN contentClass TEXT NOT NULL DEFAULT ''`},
		{"isText", `ALTER TABLE uploads ADD COLUMN isText       INTEGER NOT NULL DEFAULT 0`},
		{"typeLabel", `ALTER TABLE uploads ADD COLUMN typeLabel    TEXT NOT NULL DEFAULT ''`},
		{"typeScore", `ALTER TABLE uploads ADD COLUMN typeScore    REAL NOT NULL DEFAULT 0`},
		{"source", `ALTER TABLE uploads ADD COLUMN source       TEXT NOT NULL DEFAULT ''`},
	}
	for _, a := range adds {
		if have[a.col] {
			continue
		}
		if _, err := db.Exec(a.stmt); err != nil {
			return err
		}
	}
	return nil
}

// tableColumns returns the set of column names on table via PRAGMA table_info.
// table is an internal constant (never client input), so it is interpolated
// directly -- PRAGMA does not accept a bound parameter for the table name.
func tableColumns(db *sql.DB, table string) (map[string]bool, error) {
	rows, err := db.Query("PRAGMA table_info(" + table + ")")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var (
			cid       int
			name      string
			ctype     string
			notNull   int
			dfltValue sql.NullString
			pk        int
		)
		if err := rows.Scan(&cid, &name, &ctype, &notNull, &dfltValue, &pk); err != nil {
			return nil, err
		}
		cols[name] = true
	}
	return cols, rows.Err()
}

// Close releases the underlying connection pool.
func (s *Store) Close() error { return s.db.Close() }

const schema = `
CREATE TABLE IF NOT EXISTS uploads (
    id               TEXT PRIMARY KEY,
    storedPath       TEXT NOT NULL,
    originalFilename TEXT NOT NULL,
    isArchive        INTEGER NOT NULL DEFAULT 0,
    username         TEXT NOT NULL DEFAULT '',
    pathMetadata     TEXT NOT NULL DEFAULT '',
    clientAddress    TEXT NOT NULL DEFAULT '',
    createdAt        TEXT NOT NULL,
    receivedAt       TEXT,
    status           TEXT NOT NULL CHECK (status IN ('pending','complete','partial','truncated')),
    sizeBytes        INTEGER NOT NULL DEFAULT 0,
    locallyBuffered  INTEGER NOT NULL DEFAULT 0,
    mimeType         TEXT NOT NULL DEFAULT '',
    contentClass     TEXT NOT NULL DEFAULT '',
    isText           INTEGER NOT NULL DEFAULT 0,
    typeLabel        TEXT NOT NULL DEFAULT '',
    typeScore        REAL NOT NULL DEFAULT 0,
    source           TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_uploads_username     ON uploads(username);
CREATE INDEX IF NOT EXISTS idx_uploads_createdAt    ON uploads(createdAt);
CREATE INDEX IF NOT EXISTS idx_uploads_receivedAt   ON uploads(receivedAt);
CREATE INDEX IF NOT EXISTS idx_uploads_contentClass ON uploads(contentClass);
`

// InsertPending writes the up-front pending record per §8.2 step 2.
// storedPath is the operator's best-known intended location at this
// point; FinalizeStaging will rewrite it via UpdateOnComplete.
func (s *Store) InsertPending(r *Record) error {
	if r.Status == "" {
		r.Status = StatusPending
	}
	_, err := s.db.Exec(`
INSERT INTO uploads
    (id, storedPath, originalFilename, isArchive, username, pathMetadata, clientAddress, createdAt, status, sizeBytes, locallyBuffered, source)
VALUES (?,  ?,         ?,                ?,         ?,        ?,            ?,             ?,         ?,      ?,         ?,               ?)`,
		r.ID, r.StoredPath, r.OriginalFilename, boolInt(r.IsArchive),
		r.Username, r.PathMetadata, r.ClientAddress,
		r.CreatedAt.UTC().Format(time.RFC3339Nano), r.Status, r.SizeBytes, boolInt(r.LocallyBuffered), r.Source,
	)
	return err
}

// UpdateType writes the §10 detection fields onto an existing row. Called
// by the ingest path after the artifact is on disk (commit / flush) and
// by the UI's on-demand backfill for a locally-owned typeless record.
func (s *Store) UpdateType(id, mimeType, contentClass string, isText bool, typeLabel string, typeScore float64) error {
	_, err := s.db.Exec(`
UPDATE uploads
   SET mimeType = ?, contentClass = ?, isText = ?, typeLabel = ?, typeScore = ?
 WHERE id = ?`,
		mimeType, contentClass, boolInt(isText), typeLabel, typeScore, id,
	)
	return err
}

// UpdateOnComplete writes §8.2 step 4's terminal state (complete or
// truncated) AND the final storedPath / originalFilename / isArchive
// that FinalizeStaging produced.
func (s *Store) UpdateOnComplete(id string, storedPath, originalFilename string, isArchive bool, status string, sizeBytes int64, receivedAt time.Time) error {
	if status != StatusComplete && status != StatusTruncated {
		return fmt.Errorf("UpdateOnComplete: unexpected status %q", status)
	}
	_, err := s.db.Exec(`
UPDATE uploads
   SET storedPath = ?, originalFilename = ?, isArchive = ?,
       status     = ?, sizeBytes = ?, receivedAt = ?
 WHERE id = ?`,
		storedPath, originalFilename, boolInt(isArchive),
		status, sizeBytes, receivedAt.UTC().Format(time.RFC3339Nano),
		id,
	)
	return err
}

// UpdateOnPartial writes §8.2 step 5 — the client disconnected mid-
// transfer or the SCP wire protocol broke. The partial bytes already
// on disk are kept; we record what we saw.
func (s *Store) UpdateOnPartial(id string, sizeBytes int64, receivedAt time.Time) error {
	_, err := s.db.Exec(`
UPDATE uploads
   SET status = ?, sizeBytes = ?, receivedAt = ?
 WHERE id = ?`,
		StatusPartial, sizeBytes, receivedAt.UTC().Format(time.RFC3339Nano), id,
	)
	return err
}

// UpdateOnFlushed records that a previously buffered artifact reached the
// share (§8.4): the storedPath moves from the VM-local buffer to the
// share, and locallyBuffered clears. Status is untouched.
func (s *Store) UpdateOnFlushed(id, storedPath string) error {
	_, err := s.db.Exec(`
UPDATE uploads
   SET storedPath = ?, locallyBuffered = 0
 WHERE id = ?`,
		storedPath, id,
	)
	return err
}

// Delete removes the row with the given id. Used only on the §5.5
// empty-filename path where the spec requires "no metadata record"
// even though we already inserted a pending row up front.
func (s *Store) Delete(id string) error {
	_, err := s.db.Exec(`DELETE FROM uploads WHERE id = ?`, id)
	return err
}

// uploadColumns is the full 18-column uploads projection, in the exact order
// scanRow's Scan expects. Kept in one place so Get / ListBuffered / Search and
// scanRow share a single column-order source of truth -- a column add is one
// edit, not four, and cannot silently misalign the Scan-to-column mapping.
const uploadColumns = `id, storedPath, originalFilename, isArchive, username, pathMetadata, clientAddress,
       createdAt, receivedAt, status, sizeBytes, locallyBuffered,
       mimeType, contentClass, isText, typeLabel, typeScore, source`

// Get returns one record by exact id, or sql.ErrNoRows if absent.
func (s *Store) Get(id string) (*Record, error) {
	row := s.db.QueryRow(`
SELECT `+uploadColumns+`
  FROM uploads WHERE id = ?`, id)
	return scanRow(row)
}

// Count returns the number of rows in the index. main uses it to decide
// whether to rebuild from on-share sidecars on a fresh VM (§8.5).
func (s *Store) Count() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM uploads`).Scan(&n)
	return n, err
}

// ListBuffered returns every record still in the VM-local buffer, oldest
// first, so the flush worker drains the backlog in arrival order (§8.4).
func (s *Store) ListBuffered() ([]*Record, error) {
	rows, err := s.db.Query(`
SELECT ` + uploadColumns + `
  FROM uploads WHERE locallyBuffered = 1 ORDER BY createdAt ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Record
	for rows.Next() {
		r, err := scanRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// SearchFilter mirrors §8.3. Empty fields are ignored. Username and
// originalFilename / pathMetadata accept substrings (LIKE %x%);
// createdAt / receivedAt accept range bounds.
type SearchFilter struct {
	ID                string
	UsernameExact     string
	UsernameSubstring string
	OriginalSubstring string
	PathMetaSubstring string
	ContentClass      string
	StatusExact       string
	CreatedAtFrom     *time.Time
	CreatedAtTo       *time.Time
	ReceivedAtFrom    *time.Time
	ReceivedAtTo      *time.Time
	Limit             int
}

// Search returns matching records ordered by createdAt DESC.
func (s *Store) Search(f *SearchFilter) ([]*Record, error) {
	var (
		clauses []string
		args    []any
	)
	add := func(sql string, vals ...any) {
		clauses = append(clauses, sql)
		args = append(args, vals...)
	}
	if f.ID != "" {
		add("id = ?", f.ID)
	}
	if f.UsernameExact != "" {
		add("username = ?", f.UsernameExact)
	}
	if f.UsernameSubstring != "" {
		add("username LIKE ?", "%"+escapeLike(f.UsernameSubstring)+"%")
	}
	if f.OriginalSubstring != "" {
		add("originalFilename LIKE ?", "%"+escapeLike(f.OriginalSubstring)+"%")
	}
	if f.PathMetaSubstring != "" {
		add("pathMetadata LIKE ?", "%"+escapeLike(f.PathMetaSubstring)+"%")
	}
	if f.ContentClass != "" {
		add("contentClass = ?", f.ContentClass)
	}
	if f.StatusExact != "" {
		add("status = ?", f.StatusExact)
	}
	if f.CreatedAtFrom != nil {
		add("createdAt >= ?", f.CreatedAtFrom.UTC().Format(time.RFC3339Nano))
	}
	if f.CreatedAtTo != nil {
		add("createdAt <= ?", f.CreatedAtTo.UTC().Format(time.RFC3339Nano))
	}
	if f.ReceivedAtFrom != nil {
		add("receivedAt >= ?", f.ReceivedAtFrom.UTC().Format(time.RFC3339Nano))
	}
	if f.ReceivedAtTo != nil {
		add("receivedAt <= ?", f.ReceivedAtTo.UTC().Format(time.RFC3339Nano))
	}
	q := `
SELECT ` + uploadColumns + `
  FROM uploads`
	if len(clauses) > 0 {
		q += " WHERE " + strings.Join(clauses, " AND ")
	}
	q += " ORDER BY createdAt DESC"
	if f.Limit > 0 {
		q += fmt.Sprintf(" LIMIT %d", f.Limit)
	}
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Record
	for rows.Next() {
		r, err := scanRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func escapeLike(s string) string {
	// LIKE special chars in SQLite: % and _. Escape with \, then add
	// ESCAPE '\\' to the LIKE call... but we use the simpler form
	// "LIKE ?" without ESCAPE. For v1 we accept that a literal % in a
	// search term is treated as a wildcard. Trusted-network tradeoff;
	// the in-VM UI controls the search input shape.
	return s
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

type scanner interface {
	Scan(dest ...any) error
}

func scanRow(s scanner) (*Record, error) {
	var (
		r            Record
		isArchiveInt int
		createdStr   string
		receivedStr  sql.NullString
		bufferedInt  int
		isTextInt    int
	)
	if err := s.Scan(
		&r.ID, &r.StoredPath, &r.OriginalFilename, &isArchiveInt,
		&r.Username, &r.PathMetadata, &r.ClientAddress,
		&createdStr, &receivedStr, &r.Status, &r.SizeBytes, &bufferedInt,
		&r.MimeType, &r.ContentClass, &isTextInt, &r.TypeLabel, &r.TypeScore, &r.Source,
	); err != nil {
		return nil, err
	}
	r.IsArchive = isArchiveInt != 0
	r.LocallyBuffered = bufferedInt != 0
	r.IsText = isTextInt != 0
	t, err := time.Parse(time.RFC3339Nano, createdStr)
	if err != nil {
		return nil, fmt.Errorf("parse createdAt: %w", err)
	}
	r.CreatedAt = t
	if receivedStr.Valid {
		rt, err := time.Parse(time.RFC3339Nano, receivedStr.String)
		if err != nil {
			return nil, fmt.Errorf("parse receivedAt: %w", err)
		}
		r.ReceivedAt = &rt
	}
	return &r, nil
}

// Sidecar is the on-disk JSON record written next to each committed
// artifact on the share (§8.5). It is the durable, reimage-surviving form
// of a metadata record, deliberately decoupled from the SQLite schema so
// the on-disk format and the index can evolve independently. The
// UI and the rebuild path (RebuildFromSidecars) both read it.
type Sidecar struct {
	ID               string     `json:"id"`
	StoredPath       string     `json:"storedPath"`
	OriginalFilename string     `json:"originalFilename"`
	IsArchive        bool       `json:"isArchive"`
	Username         string     `json:"username"`
	PathMetadata     string     `json:"pathMetadata"`
	ClientAddress    string     `json:"clientAddress"`
	CreatedAt        time.Time  `json:"createdAt"`
	ReceivedAt       *time.Time `json:"receivedAt"`
	Status           string     `json:"status"`
	SizeBytes        int64      `json:"sizeBytes"`
	// LocallyBuffered is always false in a sidecar: sidecars are only
	// written for artifacts already committed to the share. The field is
	// carried for §8.1 completeness and forward-compatibility.
	LocallyBuffered bool `json:"locallyBuffered"`
	// UI detection fields (stash-service-ui.md §10). omitempty so a sidecar
	// from before the UI shipped round-trips unchanged; an empty
	// contentClass signals "not yet classified" to the reader, which then
	// detects on-the-fly (remote) or backfills (local owner).
	MimeType     string  `json:"mimeType,omitempty"`
	ContentClass string  `json:"contentClass,omitempty"`
	IsText       bool    `json:"isText,omitempty"`
	TypeLabel    string  `json:"typeLabel,omitempty"`
	TypeScore    float64 `json:"typeScore,omitempty"`
	Source       string  `json:"source,omitempty"`
}

// WriteSidecar serializes r and writes <id>.yuruna.meta.json next to the
// artifact (derived from r.StoredPath). It must be called LAST, after the
// artifact is on the share and the DB row is terminal — its presence
// marks a fully committed upload (§8.5). The write is atomic (temp file
// in the same dir, fsync, rename) so a torn write never leaves a partial
// sidecar that the rebuild path would mis-read.
func WriteSidecar(r *Record) error {
	sc := toSidecar(r)
	data, err := json.MarshalIndent(&sc, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal sidecar: %w", err)
	}
	dst := filepath.Join(filepath.Dir(r.StoredPath), r.ID+config.SidecarExtension)
	return atomicWriteFile(dst, data, 0o600)
}

// ReadSidecar reads and parses one <id>.yuruna.meta.json file into a
// Record. Used by the pool-wide UI to read OTHER hosts' sidecars off the
// share (stash-service-ui.md §3.1) without going through any host's local
// index. Returns an error for an unreadable / malformed / empty-id file.
func ReadSidecar(path string) (*Record, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var sc Sidecar
	if err := json.Unmarshal(data, &sc); err != nil {
		return nil, fmt.Errorf("parse sidecar %s: %w", path, err)
	}
	if sc.ID == "" {
		return nil, fmt.Errorf("sidecar %s: empty id", path)
	}
	return sc.toRecord(), nil
}

// RebuildFromSidecars repopulates the index by scanning every
// *.yuruna.meta.json under filesRoot. Used on a fresh VM whose VM-local
// SQLite index is empty (the metadata-loss-on-reimage recovery, §8.5).
// Idempotent (INSERT OR REPLACE); a corrupt individual sidecar is skipped
// rather than aborting the whole rebuild. Returns the count restored.
func (s *Store) RebuildFromSidecars(filesRoot string) (int, error) {
	if _, err := os.Stat(filesRoot); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil // brand-new share, nothing to rebuild
		}
		return 0, err
	}
	count := 0
	walkErr := filepath.WalkDir(filesRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), config.SidecarExtension) {
			return nil
		}
		data, rerr := os.ReadFile(path)
		if rerr != nil {
			// Skip a sidecar we cannot read (transient share I/O, permission) rather than
			// aborting the whole rebuild: on a fresh reimage one unreadable file must not leave
			// the remaining (possibly thousands of) sidecars unindexed and invisible. Matches
			// the corrupt/empty-JSON skip below.
			return nil
		}
		var sc Sidecar
		if json.Unmarshal(data, &sc) != nil || sc.ID == "" {
			return nil // skip a corrupt/empty sidecar; don't abort
		}
		if ierr := s.insertFull(sc.toRecord()); ierr != nil {
			return ierr
		}
		count++
		return nil
	})
	return count, walkErr
}

func toSidecar(r *Record) Sidecar {
	sc := Sidecar{
		ID:               r.ID,
		StoredPath:       r.StoredPath,
		OriginalFilename: r.OriginalFilename,
		IsArchive:        r.IsArchive,
		Username:         r.Username,
		PathMetadata:     r.PathMetadata,
		ClientAddress:    r.ClientAddress,
		CreatedAt:        r.CreatedAt.UTC(),
		Status:           r.Status,
		SizeBytes:        r.SizeBytes,
		LocallyBuffered:  false,
		MimeType:         r.MimeType,
		ContentClass:     r.ContentClass,
		IsText:           r.IsText,
		TypeLabel:        r.TypeLabel,
		TypeScore:        r.TypeScore,
		Source:           r.Source,
	}
	if r.ReceivedAt != nil {
		t := r.ReceivedAt.UTC()
		sc.ReceivedAt = &t
	}
	return sc
}

func (sc *Sidecar) toRecord() *Record {
	r := &Record{
		ID:               sc.ID,
		StoredPath:       sc.StoredPath,
		OriginalFilename: sc.OriginalFilename,
		IsArchive:        sc.IsArchive,
		Username:         sc.Username,
		PathMetadata:     sc.PathMetadata,
		ClientAddress:    sc.ClientAddress,
		CreatedAt:        sc.CreatedAt.UTC(),
		Status:           sc.Status,
		SizeBytes:        sc.SizeBytes,
		MimeType:         sc.MimeType,
		ContentClass:     sc.ContentClass,
		IsText:           sc.IsText,
		TypeLabel:        sc.TypeLabel,
		TypeScore:        sc.TypeScore,
		Source:           sc.Source,
	}
	if sc.ReceivedAt != nil {
		t := sc.ReceivedAt.UTC()
		r.ReceivedAt = &t
	}
	return r
}

// insertFull writes a fully-formed record (all terminal fields set), used
// by the sidecar rebuild. INSERT OR REPLACE so a re-run is idempotent.
func (s *Store) insertFull(r *Record) error {
	_, err := s.db.Exec(`
INSERT OR REPLACE INTO uploads
    (id, storedPath, originalFilename, isArchive, username, pathMetadata, clientAddress, createdAt, receivedAt, status, sizeBytes, locallyBuffered, mimeType, contentClass, isText, typeLabel, typeScore, source)
VALUES (?,  ?,         ?,                ?,         ?,        ?,            ?,             ?,         ?,          ?,      ?,         ?,               ?,        ?,            ?,      ?,         ?,         ?)`,
		r.ID, r.StoredPath, r.OriginalFilename, boolInt(r.IsArchive),
		r.Username, r.PathMetadata, r.ClientAddress,
		r.CreatedAt.UTC().Format(time.RFC3339Nano), nullableTime(r.ReceivedAt),
		r.Status, r.SizeBytes, boolInt(r.LocallyBuffered),
		r.MimeType, r.ContentClass, boolInt(r.IsText), r.TypeLabel, r.TypeScore, r.Source,
	)
	return err
}

func nullableTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}

// atomicWriteFile writes data to dst via a temp file in the same directory
// followed by fsync + rename, so a reader never observes a partial file.
func atomicWriteFile(dst string, data []byte, perm os.FileMode) error {
	return fsutil.AtomicCommit(dst, ".sidecar-*.tmp", perm, func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	})
}
