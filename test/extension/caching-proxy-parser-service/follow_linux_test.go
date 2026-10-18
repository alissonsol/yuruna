// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//go:build linux

package main

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestPartialLogAppendIsRetainedUntilNewline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access.log")
	if err := os.WriteFile(path, []byte("first partial"), 0600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	pending := ""
	if line, err := readLogLine(reader, &pending); err != io.EOF || line != "" {
		t.Fatalf("incomplete read: %q %v", line, err)
	}
	writer, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.WriteString(" remainder\nsecond\n"); err != nil {
		writer.Close()
		t.Fatal(err)
	}
	writer.Close()
	if line, err := readLogLine(reader, &pending); err != nil || line != "first partial remainder\n" {
		t.Fatalf("completed read: %q %v", line, err)
	}
	if line, err := readLogLine(reader, &pending); err != nil || line != "second\n" {
		t.Fatalf("next read: %q %v", line, err)
	}
	if pending != "" {
		t.Fatalf("completed prefix retained: %q", pending)
	}
}
