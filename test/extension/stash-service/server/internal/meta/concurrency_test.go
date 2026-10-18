// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
package meta

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestEveryMetadataConnectionHasBusyTimeoutAndWAL(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the database file name carries a question mark, which Windows file names cannot hold")
	}
	m, err := Open(filepath.Join(t.TempDir(), "stash #?.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var connections []*sql.Conn
	defer func() {
		for _, conn := range connections {
			_ = conn.Close()
		}
	}()
	for i := 0; i < 3; i++ {
		conn, err := m.db.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		connections = append(connections, conn)
		var timeout int
		var journal string
		if err := conn.QueryRowContext(ctx, "PRAGMA busy_timeout").Scan(&timeout); err != nil {
			t.Fatal(err)
		}
		if err := conn.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&journal); err != nil {
			t.Fatal(err)
		}
		if timeout < 5000 || journal != "wal" {
			t.Fatalf("connection %d: timeout=%d journal=%s", i, timeout, journal)
		}
	}
}

func TestMetadataWriterWaitsForConcurrentTransaction(t *testing.T) {
	m, err := Open(filepath.Join(t.TempDir(), "stash.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := m.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		t.Fatal(err)
	}
	defer conn.ExecContext(context.Background(), "ROLLBACK")
	done := make(chan error, 1)
	go func() {
		done <- m.InsertPending(&Record{ID: "concurrent", Username: "u", CreatedAt: time.Now(), Status: StatusPending})
	}()
	select {
	case err := <-done:
		t.Fatalf("writer returned before transaction released: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	if _, err := conn.ExecContext(ctx, "COMMIT"); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("writer did not resume after commit")
	}
}

func TestMetadataRelativePath(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	if err := os.Mkdir("metadata", 0700); err != nil {
		t.Fatal(err)
	}
	m, err := Open(filepath.Join("metadata", "stash.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if err := m.InsertPending(&Record{ID: "relative", Username: "u", CreatedAt: time.Now(), Status: StatusPending}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "metadata", "stash.sqlite")); err != nil {
		t.Fatal(err)
	}
}
