// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package meta owns the SQLite metadata store (§8). One row per
// upload. Status moves pending -> {complete | truncated | partial}.
//
// The driver is modernc.org/sqlite (pure-Go), so the daemon builds
// without CGO_ENABLED=1. Substring search on originalFilename /
// pathMetadata uses LIKE %x% with no FTS index in v1; the future
// in-VM UI may add FTS5 if the corpus grows beyond what LIKE handles.
package meta

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
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
	return &Store{db: db}, nil
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
    sizeBytes        INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_uploads_username   ON uploads(username);
CREATE INDEX IF NOT EXISTS idx_uploads_createdAt  ON uploads(createdAt);
CREATE INDEX IF NOT EXISTS idx_uploads_receivedAt ON uploads(receivedAt);
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
    (id, storedPath, originalFilename, isArchive, username, pathMetadata, clientAddress, createdAt, status, sizeBytes)
VALUES (?,  ?,         ?,                ?,         ?,        ?,            ?,             ?,         ?,      ?)`,
		r.ID, r.StoredPath, r.OriginalFilename, boolInt(r.IsArchive),
		r.Username, r.PathMetadata, r.ClientAddress,
		r.CreatedAt.UTC().Format(time.RFC3339Nano), r.Status, r.SizeBytes,
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

// Delete removes the row with the given id. Used only on the §5.5
// empty-filename path where the spec requires "no metadata record"
// even though we already inserted a pending row up front.
func (s *Store) Delete(id string) error {
	_, err := s.db.Exec(`DELETE FROM uploads WHERE id = ?`, id)
	return err
}

// Get returns one record by exact id, or sql.ErrNoRows if absent.
func (s *Store) Get(id string) (*Record, error) {
	row := s.db.QueryRow(`
SELECT id, storedPath, originalFilename, isArchive, username, pathMetadata, clientAddress,
       createdAt, receivedAt, status, sizeBytes
  FROM uploads WHERE id = ?`, id)
	return scanRow(row)
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
SELECT id, storedPath, originalFilename, isArchive, username, pathMetadata, clientAddress,
       createdAt, receivedAt, status, sizeBytes
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
	// the future in-VM UI controls the search input shape.
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
	)
	if err := s.Scan(
		&r.ID, &r.StoredPath, &r.OriginalFilename, &isArchiveInt,
		&r.Username, &r.PathMetadata, &r.ClientAddress,
		&createdStr, &receivedStr, &r.Status, &r.SizeBytes,
	); err != nil {
		return nil, err
	}
	r.IsArchive = isArchiveInt != 0
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

// ErrNotFound is returned by Get when no row matches.
var ErrNotFound = errors.New("meta: record not found")
