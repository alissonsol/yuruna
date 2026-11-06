// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 420035d9-10b4-46c2-878c-47f33a868b8a

package hostcheck

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

// testHostname is what the injected os.Hostname answers: a VM named the way
// the service seeds name theirs, inside a domain, so the first label is a
// second name it answers to.
const testHostname = "Yuruna-Stash-Service.lab.example"

func newTestCheck(names ...string) *Check {
	return New(Options{Names: names, hostname: func() (string, error) { return testHostname, nil }})
}

// serve runs one request through the check and reports the answer and whether
// the wrapped handler ran.
func serve(t *testing.T, check *Check, host, peer string, forwarded ...string) (*httptest.ResponseRecorder, bool) {
	t.Helper()
	reached := false
	handler := check.Handler(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		reached = true
		w.WriteHeader(http.StatusOK)
	}))
	r := httptest.NewRequest(http.MethodPost, "/api/stashes", strings.NewReader(`{"text":"x"}`))
	r.Host = host
	if peer != "" {
		r.RemoteAddr = peer
	}
	for _, value := range forwarded {
		r.Header.Add("X-Forwarded-Host", value)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w, reached
}

func assertRefused(t *testing.T, w *httptest.ResponseRecorder, reached bool, named string) {
	t.Helper()
	if reached {
		t.Fatalf("the handler ran for a request naming %q", named)
	}
	if w.Code != http.StatusMisdirectedRequest {
		t.Fatalf("a request naming %q = %d, want 421", named, w.Code)
	}
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("the refusal is not JSON: %v (%s)", err, w.Body.String())
	}
	if body["ok"] != false || body["code"] != "auth.host_not_served" {
		t.Fatalf("refusal body = %v, want ok:false and code auth.host_not_served", body)
	}
	if text, _ := body["error"].(string); !strings.Contains(text, named) || !strings.Contains(text, "vmStart.serviceHostNames") {
		t.Fatalf("refusal text %q does not name %q and the setting that serves it", text, named)
	}
	if got := w.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
}

// A page on another site whose name resolves to this service is same-origin
// with it, so only the name it carries gives it away.
func TestARequestNamingAnotherHostIsRefused(t *testing.T) {
	check := newTestCheck("cache.lab")
	for _, host := range []string{
		"rebind.example",
		"rebind.example:80",
		"yuruna-stash-service.rebind.example",
		"cache.lab.rebind.example",
		"localhost.rebind.example",
	} {
		t.Run(host, func(t *testing.T) {
			w, reached := serve(t, check, host, "")
			assertRefused(t, w, reached, host)
		})
	}
}

func TestTheServiceAnswersToItsOwnNames(t *testing.T) {
	check := newTestCheck("cache.lab", "CACHE.LAB.")
	for _, host := range []string{
		"localhost",
		"LOCALHOST:8080",
		"localhost.",
		"yuruna-stash-service.lab.example",
		"Yuruna-Stash-Service.lab.example.:80",
		"yuruna-stash-service",
		"cache.lab",
		"CACHE.LAB.",
		"127.0.0.1:80",
		"[::1]:80",
		"[::1]",
		"192.168.7.50",
		"10.0.0.9:8082",
		"[fd00::5]:8082",
		"",
	} {
		t.Run(host, func(t *testing.T) {
			if w, reached := serve(t, check, host, ""); !reached || w.Code != http.StatusOK {
				t.Fatalf("a request naming %q = %d (handler ran: %v), want it served", host, w.Code, reached)
			}
		})
	}
}

// The proxy VM's Apache forwards the client's Host and appends it to
// X-Forwarded-Host, so the daemon behind it is asked about every name the
// browser used. A client reaching the daemon directly is judged by its own
// Host alone: its X-Forwarded-Host is a header it wrote itself.
func TestALocalProxyIsAskedAboutTheNameTheBrowserUsed(t *testing.T) {
	check := newTestCheck("cache.lab")
	for _, tc := range []struct {
		name      string
		host      string
		peer      string
		forwarded []string
		refused   string
	}{
		{"a rebound name through the proxy", "127.0.0.1:9310", "127.0.0.1:41234", []string{"rebind.example"}, "rebind.example"},
		{"a configured name through the proxy", "127.0.0.1:9310", "127.0.0.1:41234", []string{"cache.lab"}, ""},
		{"a chain that holds a rebound name", "127.0.0.1:9310", "127.0.0.1:41234", []string{"192.168.7.42, rebind.example"}, "rebind.example"},
		{"a second header line that holds a rebound name", "127.0.0.1:9310", "[::1]:41234", []string{"cache.lab", "rebind.example"}, "rebind.example"},
		{"an address through the proxy", "127.0.0.1:9310", "[::1]:41234", []string{"192.168.7.42:80"}, ""},
		{"a remote client's own header", "192.168.7.42", "192.0.2.7:51000", []string{"rebind.example"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w, reached := serve(t, check, tc.host, tc.peer, tc.forwarded...)
			if tc.refused != "" {
				assertRefused(t, w, reached, tc.refused)
				return
			}
			if !reached || w.Code != http.StatusOK {
				t.Fatalf("= %d (handler ran: %v), want it served", w.Code, reached)
			}
		})
	}
}

func TestParseNames(t *testing.T) {
	if got, want := ParseNames(" Cache.Lab ,stash.lab.,, "), []string{"cache.lab", "stash.lab"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("ParseNames = %q, want %q", got, want)
	}
	if got := ParseNames(""); len(got) != 0 {
		t.Fatalf("ParseNames of an empty list = %q, want none", got)
	}
}

func TestTheRefusalIsLocalized(t *testing.T) {
	check := newTestCheck()
	handler := check.Handler(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("the handler ran for a rebound name")
	}))
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Host = "rebind.example"
	r.Header.Set("Accept-Language", "pt-BR")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if got := w.Header().Get("Content-Language"); got != "pt-BR" {
		t.Fatalf("Content-Language = %q, want pt-BR", got)
	}
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	args := map[string]any{"host": "rebind.example", "setting": "vmStart.serviceHostNames"}
	want := messages().Render("auth.host_not_served", args, "pt-BR")
	if body["error"] != want || want == messages().Render("auth.host_not_served", args, "en-US") {
		t.Fatalf("refusal text = %v, want the pt-BR text %q", body["error"], want)
	}
	if missing := messages().MissingKeys(); len(missing) != 0 {
		t.Fatalf("the refusal fell back to a missing key: %v", missing)
	}
}
