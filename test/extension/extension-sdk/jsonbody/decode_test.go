// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 428aac13-c858-4744-b505-1e9886927bd5

package jsonbody

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestBoundaries(t *testing.T) {
	for _, c := range []struct {
		body  string
		limit int64
		empty bool
		want  error
	}{
		{"{}", 2, false, nil}, {"{} ", 2, false, ErrOversize}, {"{} junk", 20, false, ErrTrailing}, {"{} {}", 20, false, ErrTrailing}, {"", 20, true, nil}, {"  ", 20, true, nil}, {"", 20, false, ErrMalformed}, {"[]", 20, false, ErrMalformed}, {"{", 20, false, ErrMalformed},
	} {
		var dst struct{}
		err := Decode(strings.NewReader(c.body), &dst, c.limit, c.empty)
		if !errors.Is(err, c.want) {
			t.Errorf("%q: %v want %v", c.body, err, c.want)
		}
	}
}

// shortBodyTimeout lowers the body read timeout for one test.
func shortBodyTimeout(t *testing.T, d time.Duration) {
	t.Helper()
	saved := bodyReadTimeout
	bodyReadTimeout = d
	t.Cleanup(func() { bodyReadTimeout = saved })
}

// A client that sends its headers and then stalls is cut off at the body read
// timeout instead of holding the connection for as long as it likes.
func TestDecodeRequestCutsOffAStalledBody(t *testing.T) {
	shortBodyTimeout(t, 200*time.Millisecond)
	result := make(chan error, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var dst map[string]any
		result <- DecodeRequest(w, r, &dst, 1024, false)
	}))
	t.Cleanup(srv.Close)
	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	fmt.Fprintf(conn, "POST / HTTP/1.1\r\nHost: fixture\r\nContent-Type: application/json\r\nContent-Length: 64\r\n\r\n{\"a\":")
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("a body that never finished arriving decoded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the stalled body was never cut off")
	}
}

// The deadline ends with the body: a handler still working after it is not
// canceled, which a deadline left to fire would do to the request.
func TestDecodeRequestClearsTheDeadlineOnceTheBodyIsIn(t *testing.T) {
	shortBodyTimeout(t, 100*time.Millisecond)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var dst map[string]any
		if err := DecodeRequest(w, r, &dst, 1024, false); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		select {
		case <-r.Context().Done():
			http.Error(w, "canceled", http.StatusInternalServerError)
		case <-time.After(500 * time.Millisecond):
			_, _ = io.WriteString(w, "done")
		}
	}))
	t.Cleanup(srv.Close)
	resp, err := srv.Client().Post(srv.URL, "application/json", strings.NewReader(`{"a":1}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || string(body) != "done" {
		t.Fatalf("handler past the body deadline answered %d %q, want 200 done", resp.StatusCode, body)
	}
}

// ReadRequest hands back the raw bytes under the same deadline and limit, for a
// handler that parses the body itself.
func TestReadRequestCutsOffAStalledBodyAndRefusesAnOversizeOne(t *testing.T) {
	shortBodyTimeout(t, 200*time.Millisecond)
	type outcome struct {
		data []byte
		err  error
	}
	result := make(chan outcome, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, err := ReadRequest(w, r, 8)
		result <- outcome{data, err}
	}))
	t.Cleanup(srv.Close)
	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	fmt.Fprintf(conn, "POST / HTTP/1.1\r\nHost: fixture\r\nContent-Length: 8\r\n\r\nabc")
	select {
	case got := <-result:
		if got.err == nil {
			t.Fatalf("a body that never finished arriving was read: %q", got.data)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the stalled body was never cut off")
	}
	resp, err := srv.Client().Post(srv.URL, "application/json", strings.NewReader("123456789"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := <-result; !errors.Is(got.err, ErrOversize) {
		t.Fatalf("a body past the limit = %q, %v; want ErrOversize", got.data, got.err)
	}
}
