// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
package scp

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSkippedFileHandshake(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	_ = client.SetDeadline(time.Now().Add(2 * time.Second))
	directory := t.TempDir()
	done := make(chan error, 1)
	go func() { _, err := Receive(server, server, directory); done <- err }()
	ack := func() {
		t.Helper()
		b := []byte{9}
		if _, err := io.ReadFull(client, b); err != nil || b[0] != 0 {
			t.Fatalf("ack: %v %v", b, err)
		}
	}
	ack()
	for _, file := range []struct{ name, body string }{{"   ", "x"}, {"ok.txt", "ok"}} {
		header := "C0600 1 " + file.name + "\n"
		if file.name == "ok.txt" {
			header = "C0600 2 ok.txt\n"
		}
		if _, err := io.WriteString(client, header); err != nil {
			t.Fatal(err)
		}
		ack()
		if _, err := io.WriteString(client, file.body+"\x00"); err != nil {
			t.Fatal(err)
		}
		ack()
	}
	client.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(directory, "ok.txt"))
	if err != nil || string(data) != "ok" {
		t.Fatalf("stored: %q %v", data, err)
	}
	files, _ := os.ReadDir(directory)
	if len(files) != 1 {
		t.Fatalf("unexpected files: %v", files)
	}
}
func TestPartialControlAndDirectoryEOF(t *testing.T) {
	for _, suffix := range []string{"C0600 999 missing", "D0700 0 missing", "T123 0", "D0700 0 dir\n"} {
		t.Run(suffix, func(t *testing.T) {
			result, err := Receive(bytes.NewBufferString("C0600 1 ok.txt\nx\x00"+suffix), io.Discard, t.TempDir())
			if !errors.Is(err, io.ErrUnexpectedEOF) {
				t.Fatalf("expected truncated session, got %v", err)
			}
			if len(result.FileNames) != 1 {
				t.Fatalf("lost partial result: %+v", result)
			}
		})
	}
	_, err := Receive(bytes.NewBufferString("C0600 1 ok.txt\nx\x00"), io.Discard, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
}

func TestStrictHeaders(t *testing.T) {
	for _, h := range []string{"", "C600 0 x", "C0800 0 x", "C0600 -1 x", "C0600 +1 x", "C0600 1oops x", "C0600 9223372036854775808 x", "C0600  1 x", "C0600 \t1 x", "D0700 1 x"} {
		if _, _, _, err := parseCLine(h); err == nil {
			t.Errorf("accepted %q", h)
		}
	}
	for _, h := range []string{"C0600 0 x", "C0644 123 x", "D0755 0 dir"} {
		if _, _, _, err := parseCLine(h); err != nil {
			t.Errorf("rejected %q: %v", h, err)
		}
	}
}
